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
            default -> LOG.log(Level.FINE, "Ignoring message {0}", tag.atomValue());
        }
    }

    private void onLeader(OtpErlangObject value) {
        if (value instanceof OtpErlangAtom a) {
            leaderNode = a.atomValue();
            LOG.log(Level.INFO, "Coordinator leader is now {0}", leaderNode);
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
