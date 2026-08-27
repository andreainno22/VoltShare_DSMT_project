package it.unipi.dsmt.voltshare.service;

import it.unipi.dsmt.voltshare.dao.SessionDao;
import it.unipi.dsmt.voltshare.util.Env;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.sql.SQLException;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Prices closed sessions.
 *
 * <h2>Why a sweep and not a handler</h2>
 *
 * <p>The obvious design is to bill inside the {@code session_closed} handler, from the numbers
 * the event carries. It was rejected for three reasons, all of which come from the event being
 * a plain Erlang message:
 *
 * <ul>
 *   <li><b>Delivery is best-effort.</b> {@code {Mbox, Node} ! Msg} to an absent mailbox is
 *       silently dropped — deliberately, so that Tomcat being down cannot disturb the cluster
 *       (vs_coord_bo). A session closed during a back office restart would then never be
 *       priced at all.</li>
 *   <li><b>The event can outrun the row.</b> The station inserts into MySQL and notifies the
 *       coordinator; nothing orders those two. Billing from the event by id can therefore look
 *       for a row that has not been committed yet.</li>
 *   <li><b>The data is already in the database.</b> The event carries what the row carries, so
 *       reading it back costs one query and removes any question of the two disagreeing.</li>
 * </ul>
 *
 * <p>So the event is treated purely as a <em>wake-up</em>: it makes billing prompt, never
 * correct. Correctness comes from the periodic sweep of {@code cost_cents IS NULL}, which the
 * schema indexes for exactly this ({@code idx_unbilled}). Losing every event would delay a
 * receipt by one sweep interval and nothing else.
 *
 * <p>Together with the conditional UPDATE in {@link SessionDao#markBilled}, this is
 * at-least-once delivery over an idempotent write — the standard way to get
 * effectively-once behaviour without an exactly-once channel, which distributed systems do
 * not offer.
 */
public final class BillingService {

    private static final Logger LOG = Logger.getLogger(BillingService.class.getName());
    private static final BillingService INSTANCE = new BillingService();

    /** Bounded so one sweep cannot hold a connection while pricing an unbounded backlog. */
    private static final int BATCH = 200;

    private final SessionDao sessions = new SessionDao();
    private final int sweepSeconds = Env.getInt("BILLING_SWEEP_SECONDS", 60);

    private ScheduledExecutorService scheduler;

    private BillingService() {
    }

    public static BillingService getInstance() {
        return INSTANCE;
    }

    // ---- lifecycle ---------------------------------------------------------------

    /**
     * A single worker thread on purpose: the timer and every event-driven request go through
     * the same queue, so two sweeps can never run at once and no lock is needed.
     */
    public synchronized void start() {
        if (scheduler != null) {
            return;
        }
        scheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "voltshare-billing");
            t.setDaemon(true);   // must never keep Tomcat from shutting down
            return t;
        });
        // The first run is immediate: it settles anything closed while this node was down.
        scheduler.scheduleWithFixedDelay(this::sweepQuietly, 0, sweepSeconds, TimeUnit.SECONDS);
        LOG.log(Level.INFO, "Billing sweep every {0} s", sweepSeconds);
    }

    public synchronized void stop() {
        if (scheduler != null) {
            scheduler.shutdownNow();
            scheduler = null;
        }
    }

    /** Called by the Erlang bridge on {@code session_closed}. Returns at once. */
    public void requestSweep() {
        ScheduledExecutorService s;
        synchronized (this) {
            s = scheduler;
        }
        if (s != null) {
            s.execute(this::sweepQuietly);
        }
    }

    // ---- the sweep ---------------------------------------------------------------

    /** @return how many sessions this pass priced. */
    public int sweep() throws SQLException {
        List<SessionDao.Unbilled> pending = sessions.findUnbilled(BATCH);
        int billed = 0;
        for (SessionDao.Unbilled s : pending) {
            // Both rates come from the station's own row: they are the price at settlement,
            // and overstay is priced per station exactly like energy is.
            int cents = cost(s.energyKwh(), s.tariffCentsKwh(),
                    s.overstaySeconds(), s.overstayCentsPerMinute());
            if (sessions.markBilled(s.id(), cents)) {
                billed++;
            }
            // Not billed means someone else got there first. Nothing to do, and nothing
            // wrong: that is the idempotence doing its job.
        }
        if (billed > 0) {
            LOG.log(Level.INFO, "Billed {0} session(s)", billed);
        }
        return billed;
    }

    private void sweepQuietly() {
        try {
            sweep();
        } catch (SQLException e) {
            // The database being briefly unavailable must not kill the scheduled task:
            // scheduleWithFixedDelay cancels the schedule if the runnable throws.
            LOG.log(Level.WARNING, "Billing sweep failed, retrying next tick: {0}", e.toString());
        } catch (RuntimeException e) {
            LOG.log(Level.SEVERE, "Unexpected failure in billing sweep", e);
        }
    }

    // ---- the price ---------------------------------------------------------------

    /**
     * Energy at the station tariff, plus the overstay charge (SCOPE §3.4, §4).
     *
     * <p>Pure and static so it can be tested without a database — which is most of what
     * there is to get wrong here.
     *
     * <p>{@code overstaySeconds} is what the station wrote, and the station has already
     * subtracted the five-minute grace period: the grace is configured on the station
     * ({@code OVERSTAY_GRACE_SECONDS}) and nowhere else, so the back office must not
     * subtract it a second time. Every second counted here is a billable one.
     *
     * <p>Overstay is charged by started minute, rounded up. It is a deterrent for occupying
     * a connector that someone else is waiting for, not a metered service, and rounding it
     * down would make the first minute free.
     */
    public static int cost(double energyKwh, int tariffCentsKwh,
                           int overstaySeconds, int overstayCentsPerMinute) {
        if (energyKwh < 0 || tariffCentsKwh < 0 || overstaySeconds < 0) {
            throw new IllegalArgumentException(
                    "negative input: kWh=" + energyKwh + " tariff=" + tariffCentsKwh
                            + " overstay=" + overstaySeconds);
        }
        // BigDecimal, not double: energy_kwh is DECIMAL(10,3) and the result is money.
        // 41.2 kWh at 45 c/kWh is 1854.0000000000002 in binary floating point.
        int energyCents = BigDecimal.valueOf(energyKwh)
                .multiply(BigDecimal.valueOf(tariffCentsKwh))
                .setScale(0, RoundingMode.HALF_UP)
                .intValueExact();

        long minutes = (overstaySeconds + 59L) / 60L;
        return energyCents + (int) (minutes * overstayCentsPerMinute);
    }

    /** How often the sweep runs, for the shell and the logs. */
    public int getSweepSeconds() {
        return sweepSeconds;
    }
}
