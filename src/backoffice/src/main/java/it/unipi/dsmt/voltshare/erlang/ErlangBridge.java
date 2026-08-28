package it.unipi.dsmt.voltshare.erlang;

import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangBinary;
import com.ericsson.otp.erlang.OtpErlangList;
import com.ericsson.otp.erlang.OtpErlangLong;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangString;
import com.ericsson.otp.erlang.OtpErlangTuple;
import com.ericsson.otp.erlang.OtpMbox;
import com.ericsson.otp.erlang.OtpNode;

import it.unipi.dsmt.voltshare.model.StationView;
import it.unipi.dsmt.voltshare.service.BillingService;
import it.unipi.dsmt.voltshare.service.PenaltyService;
import it.unipi.dsmt.voltshare.util.Env;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Makes the back office a member of the Erlang cluster.
 *
 * <p>Java opens an {@link OtpNode} and registers a mailbox named {@code backoffice}; from
 * there it receives Erlang terms directly, without HTTP or polling. The coordinator pushes
 * the station list whenever it changes — see contracts/erlang-java.md, which is the
 * agreement this class implements.
 *
 * <p>The receive loop runs on its own daemon thread and reconnects on failure: a coordinator
 * restart must not require restarting Tomcat.
 */
public final class ErlangBridge {

    private static final Logger LOG = Logger.getLogger(ErlangBridge.class.getName());
    private static final ErlangBridge INSTANCE = new ErlangBridge();

    private final AtomicBoolean started = new AtomicBoolean(false);
    private volatile Thread worker;
    private volatile OtpNode node;
    private volatile OtpMbox mbox;
    /** Last coordinator we heard from: where replies and commands are sent. */
    private volatile String leaderNode;

    private ErlangBridge() {
    }

    public static ErlangBridge getInstance() {
        return INSTANCE;
    }

    public void start() {
        if (!started.compareAndSet(false, true)) {
            return;
        }
        leaderNode = firstCoordinator();
        worker = new Thread(this::runLoop, "voltshare-erlang-bridge");
        worker.setDaemon(true);
        worker.start();
    }

    public void stop() {
        started.set(false);
        Thread t = worker;
        worker = null;
        closeQuietly();
        if (t != null) {
            t.interrupt();
        }
    }

    /** Tells the coordinator that an account may not reserve until the given instant. */
    public void notifySuspension(int userId, long untilEpochSeconds) {
        send(new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("user_suspended"),
                new OtpErlangLong(userId),
                new OtpErlangLong(untilEpochSeconds)
        }));
    }

    public void notifyUnsuspension(int userId) {
        send(new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("user_unsuspended"),
                new OtpErlangLong(userId)
        }));
    }

    public boolean isConnected() {
        OtpNode n = node;
        return n != null && leaderNode != null && n.ping(leaderNode, 500);
    }

    // ------------------------------------------------------------------ internals

    private void runLoop() {
        String nodeName = Env.get("JINTERFACE_NODE", "voltshare_bo@localhost");
        // The default must match the Erlang side's, or a developer running both
        // outside Docker gets a handshake that fails with no useful message:
        // rebar.config sets {setcookie, voltshare} and Dockerfile.erlang the same.
        String cookie = Env.get("VOLTSHARE_ERLANG_COOKIE", "voltshare");
        String mboxName = Env.get("JINTERFACE_MBOX", "backoffice");

        while (started.get() && !Thread.currentThread().isInterrupted()) {
            try {
                LOG.log(Level.INFO, "Erlang bridge starting: node={0} mbox={1}",
                        new Object[]{nodeName, mboxName});
                node = new OtpNode(nodeName, cookie);
                mbox = node.createMbox(mboxName);

                requestStations();

                while (started.get()) {
                    OtpErlangObject msg = mbox.receive();
                    if (msg != null) {
                        handle(msg);
                    }
                }
            } catch (Exception e) {
                if (!started.get()) {
                    return;
                }
                LOG.log(Level.WARNING, "Erlang bridge error, retrying in 3 s: {0}", e.toString());
                sleep(3000);
            } finally {
                closeQuietly();
            }
        }
    }

    /** Asks for a full snapshot at start-up, instead of waiting for the next spontaneous push. */
    private void requestStations() {
        OtpMbox m = mbox;
        if (m == null) {
            return;
        }
        send(new OtpErlangTuple(new OtpErlangObject[]{
                m.self(), new OtpErlangAtom("get_stations")
        }));
    }

    private void handle(OtpErlangObject msg) {
        if (!(msg instanceof OtpErlangTuple tuple) || tuple.arity() < 2) {
            return;
        }
        if (!(tuple.elementAt(0) instanceof OtpErlangAtom tag)) {
            return;
        }
        switch (tag.atomValue()) {
            case "stations_update" -> onStationsUpdate(tuple.elementAt(1));
            case "leader" -> onLeader(tuple.elementAt(1));
            case "session_closed" -> onSessionClosed(tuple);
            case "no_show" -> onNoShow(tuple);
            case "show_up" -> onShowUp(tuple);
            case "notify" -> onNotify(tuple);
            default -> LOG.log(Level.FINE, "Ignoring message {0}", tag.atomValue());
        }
    }

    /**
     * {no_show, UserId, StationId, ConnId} — a reservation expired with nobody arriving.
     *
     * <p>Unlike {@code session_closed}, the payload IS read: there is no row in the database to
     * fall back on, because this event is the only record that the reservation was missed. That
     * makes a lost message a strike never counted — accepted deliberately, see PenaltyService.
     */
    private void onNoShow(OtpErlangTuple tuple) {
        if (tuple.arity() < 4) {
            LOG.log(Level.WARNING, "Malformed no_show, ignored: {0}", tuple);
            return;
        }
        try {
            PenaltyService.getInstance().onNoShow(
                    intOf(tuple.elementAt(1)), intOf(tuple.elementAt(2)), intOf(tuple.elementAt(3)));
        } catch (Exception e) {
            LOG.log(Level.WARNING, "Unparsable no_show, ignored: {0}", e.toString());
        }
    }

    /** {show_up, UserId} — the driver arrived, so the consecutive streak resets. */
    private void onShowUp(OtpErlangTuple tuple) {
        try {
            PenaltyService.getInstance().onShowUp(intOf(tuple.elementAt(1)));
        } catch (Exception e) {
            LOG.log(Level.WARNING, "Unparsable show_up, ignored: {0}", e.toString());
        }
    }

    /** {notify, UserId, Kind, Text} — something to tell the driver next time they look. */
    private void onNotify(OtpErlangTuple tuple) {
        if (tuple.arity() < 4) {
            LOG.log(Level.WARNING, "Malformed notify, ignored: {0}", tuple);
            return;
        }
        try {
            PenaltyService.getInstance().onNotify(
                    intOf(tuple.elementAt(1)), textOf(tuple.elementAt(2)), textOf(tuple.elementAt(3)));
        } catch (Exception e) {
            LOG.log(Level.WARNING, "Unparsable notify, ignored: {0}", e.toString());
        }
    }


    /**
     * A station has closed a session and written its row.
     *
     * <p>The payload is deliberately not read. This message is a wake-up, not a source of
     * truth: the row is already in MySQL, delivery here is best-effort, and the event can
     * even overtake the INSERT that produced it. BillingService re-reads what needs pricing
     * and prices it idempotently, so the only thing lost by ignoring an event is promptness.
     * See the class comment there for the full argument.
     */
    private void onSessionClosed(OtpErlangTuple tuple) {
        LOG.log(Level.FINE, "Session closed, waking the billing sweep: {0}", tuple);
        BillingService.getInstance().requestSweep();
    }

    /**
     * A coordinator has announced that it is serving.
     *
     * <p>The suspensions are re-sent on <b>every</b> announcement, not only when the node name
     * changes. That looked like a pointless repetition and was in fact a hole:
     *
     * <ul>
     *   <li>a coordinator that crashes and is restarted comes back with an <em>empty</em>
     *       suspension map, wins the election again, and announces the same node name. Comparing
     *       names, nothing "changed" — so nothing was pushed, and it served indefinitely
     *       letting suspended drivers reserve;</li>
     *   <li>the same on the other side: a back office that restarts while the leader is the
     *       first entry of COORD_NODES starts out already believing that name, so the first
     *       announcement it hears is not a change either.</li>
     * </ul>
     *
     * <p>What the announcement really means is "I have just started serving and my table is
     * whatever I could rebuild" — which is exactly when the suspensions have to be repeated,
     * regardless of who is speaking. The push is idempotent and a handful of messages, so
     * repeating it costs nothing next to the failure it prevents.
     */
    private void onLeader(OtpErlangObject value) {
        if (value instanceof OtpErlangAtom a) {
            leaderNode = a.atomValue();
            LOG.log(Level.INFO, "Coordinator leader is now {0}", leaderNode);

            // Claims are rebuilt by asking the stations, which hold them. Nobody in the
            // cluster holds the suspensions — they live only in MySQL — so they can only
            // arrive from here.
            PenaltyService.getInstance().pushAllSuspensions();
        }
    }

    private void onStationsUpdate(OtpErlangObject value) {
        if (!(value instanceof OtpErlangList list)) {
            return;
        }
        List<StationView> parsed = new ArrayList<>(list.arity());
        for (OtpErlangObject element : list) {
            StationView s = parseStation(element);
            if (s != null) {
                parsed.add(s);
            }
        }
        StationDirectory.getInstance().replaceAll(parsed);
        LOG.log(Level.FINE, "Station directory updated: {0} stations", parsed.size());
    }

    /**
     * {StationId, Node, Name, Free, Held, Charging, Total, SitePowerKw, TariffCentsKwh, WsUrl}
     * as defined in contracts/erlang-java.md.
     */
    private StationView parseStation(OtpErlangObject element) {
        if (!(element instanceof OtpErlangTuple t) || t.arity() < 10) {
            LOG.log(Level.WARNING, "Malformed station tuple, skipped: {0}", element);
            return null;
        }
        try {
            return new StationView(
                    intOf(t.elementAt(0)),
                    textOf(t.elementAt(1)),
                    textOf(t.elementAt(2)),
                    intOf(t.elementAt(3)),
                    intOf(t.elementAt(4)),
                    intOf(t.elementAt(5)),
                    intOf(t.elementAt(6)),
                    intOf(t.elementAt(7)),
                    intOf(t.elementAt(8)),
                    textOf(t.elementAt(9)));
        } catch (Exception e) {
            LOG.log(Level.WARNING, "Unparsable station tuple, skipped: {0}", e.toString());
            return null;
        }
    }

    /** longValue() never throws, unlike intValue(): the values here are small counters. */
    private int intOf(OtpErlangObject o) {
        if (o instanceof OtpErlangLong l) {
            return (int) l.longValue();
        }
        throw new IllegalArgumentException("expected integer, got " + o.getClass().getSimpleName());
    }

    /** Erlang sends binaries for text; atoms and strings are accepted too, to be forgiving. */
    private String textOf(OtpErlangObject o) {
        if (o instanceof OtpErlangBinary b) {
            return new String(b.binaryValue(), StandardCharsets.UTF_8);
        }
        if (o instanceof OtpErlangAtom a) {
            return a.atomValue();
        }
        if (o instanceof OtpErlangString s) {
            return s.stringValue();
        }
        throw new IllegalArgumentException("expected text, got " + o.getClass().getSimpleName());
    }

    private void send(OtpErlangObject message) {
        OtpMbox m = mbox;
        String target = leaderNode;
        if (m == null || target == null) {
            LOG.warning("Erlang bridge not connected, message dropped");
            return;
        }
        try {
            m.send("vs_coord_srv", target, message);
        } catch (Exception e) {
            LOG.log(Level.WARNING, "Send to {0} failed: {1}", new Object[]{target, e.toString()});
        }
    }

    private String firstCoordinator() {
        // Same form as everywhere else in the cluster: short name `vs`, hostname
        // tells the nodes apart (contracts/erlang-java.md §1).
        String nodes = Env.get("COORD_NODES", "vs@coord1");
        return nodes.split(",")[0].trim();
    }

    private void closeQuietly() {
        try {
            OtpMbox m = mbox;
            mbox = null;
            if (m != null) {
                m.close();
            }
        } catch (Exception ignored) {
            // closing a broken mailbox is not worth reporting
        }
        try {
            OtpNode n = node;
            node = null;
            if (n != null) {
                n.close();
            }
        } catch (Exception ignored) {
            // ditto
        }
    }

    private void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
