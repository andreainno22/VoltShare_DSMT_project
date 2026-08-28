package it.unipi.dsmt.voltshare.service;

import it.unipi.dsmt.voltshare.dao.NotificationDao;
import it.unipi.dsmt.voltshare.dao.UserDao;
import it.unipi.dsmt.voltshare.erlang.ErlangBridge;
import it.unipi.dsmt.voltshare.model.Notification;
import it.unipi.dsmt.voltshare.util.Env;

import java.sql.SQLException;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * The no-show penalty: N consecutive missed reservations cost K days of the privilege.
 *
 * <h2>Why a suspension and not a fee</h2>
 *
 * <p>The abuse being prevented is the hoarding of a scarce physical resource, and denying the
 * privilege addresses it directly. A charge would merely price it, leaving a driver willing to
 * pay free to go on doing it (SCOPE §3.3). The one charge in the system is the overstay, and
 * that is because no timer can move a parked car.
 *
 * <h2>Where the state lives, and why that matters here</h2>
 *
 * <p>The counter is written here and nowhere else. A station observes a no-show and says so
 * through the coordinator; it never counts and never suspends. The reason is that "two
 * <em>consecutive</em>" needs history, and history in a station is lost when the station
 * restarts — whereas the whole point of the rule is that it accumulates.
 *
 * <p>That choice has a consequence M3 makes visible. Claims survive a coordinator failover
 * because the new leader can ask the stations, which hold them. Suspensions cannot be rebuilt
 * that way: nobody in the cluster has them. So {@link #pushAllSuspensions()} re-sends them
 * whenever a new leader appears, and until it runs a fresh leader would let a suspended driver
 * reserve. Bounded, one-directional, and worth stating rather than hiding.
 *
 * <h2>Concurrency</h2>
 *
 * <p>There is deliberately none to solve. Suspension is decided in one place from a row only
 * this component writes, and the coordinator merely caches the answer — so this does not become
 * a second contended object alongside the connector (DESIGN-NOTES §4b). The only race that can
 * happen is two no-shows for the same driver arriving together, and that is handled where it
 * belongs, in {@link UserDao#recordNoShow} with the row locked.
 */
public final class PenaltyService {

    private static final Logger LOG = Logger.getLogger(PenaltyService.class.getName());
    private static final PenaltyService INSTANCE = new PenaltyService();

    private final UserDao users = new UserDao();
    private final NotificationDao notifications = new NotificationDao();

    /** Defaults from SCOPE §3.3; both configurable so a demo can show the rule in seconds. */
    private final int strikesAllowed = Env.getInt("PENALTY_NO_SHOWS", 2);
    private final int suspensionDays = Env.getInt("PENALTY_DAYS", 1);

    private PenaltyService() {
    }

    public static PenaltyService getInstance() {
        return INSTANCE;
    }

    /**
     * A reservation expired with nobody arriving.
     *
     * <p>Relayed by the coordinator on behalf of a station. Delivery is best-effort: a lost
     * event is a strike never counted, which delays a suspension and corrupts nothing — the
     * rule exists to stop a habit, and a habit produces more events.
     */
    public void onNoShow(int userId, int stationId, int connectorId) {
        try {
            int strikes = users.recordNoShow(userId);
            LOG.log(Level.INFO, "No-show {0} for user {1} at station {2}, connector {3}",
                    new Object[]{strikes, userId, stationId, connectorId});

            if (strikes < strikesAllowed) {
                notifications.add(userId, Notification.RESERVATION_EXPIRED,
                        "Your reservation expired without the vehicle arriving. "
                                + strikes + " of " + strikesAllowed
                                + " — reaching " + strikesAllowed
                                + " suspends reservations for " + suspensionDays + " day(s).");
                return;
            }
            suspend(userId);

        } catch (SQLException e) {
            // Never rethrow into the Erlang bridge thread: a database hiccup must not take
            // down the link to the cluster over an accounting update.
            LOG.log(Level.SEVERE, "Cannot record a no-show for user " + userId, e);
        }
    }

    /** The driver arrived. The streak resets — "consecutive" is the whole rule. */
    public void onShowUp(int userId) {
        try {
            users.clearNoShowStreak(userId);
        } catch (SQLException e) {
            LOG.log(Level.WARNING, "Cannot clear the no-show streak of user " + userId, e);
        }
    }

    /** A message a station wants the driver to see next time they look. */
    public void onNotify(int userId, String kind, String text) {
        try {
            notifications.add(userId, kind, text);
        } catch (SQLException e) {
            LOG.log(Level.WARNING, "Cannot store a notification for user " + userId, e);
        }
    }

    /**
     * Re-sends every running suspension to the coordinator.
     *
     * <p>Called when the bridge learns of a new leader. Cheap, idempotent, and the only way a
     * freshly elected coordinator finds out who may not reserve.
     */
    public void pushAllSuspensions() {
        try {
            List<long[]> active = users.activeSuspensions();
            for (long[] row : active) {
                ErlangBridge.getInstance().notifySuspension((int) row[0], row[1]);
            }
            if (!active.isEmpty()) {
                LOG.log(Level.INFO, "Re-sent {0} suspension(s) to the new leader", active.size());
            }
        } catch (SQLException e) {
            LOG.log(Level.WARNING, "Cannot re-send suspensions to the coordinator", e);
        }
    }

    public int getStrikesAllowed() {
        return strikesAllowed;
    }

    public int getSuspensionDays() {
        return suspensionDays;
    }

    // ---- internal ---------------------------------------------------------------

    private void suspend(int userId) throws SQLException {
        LocalDateTime until = LocalDateTime.now().plusDays(suspensionDays);
        users.suspendUntil(userId, until);

        notifications.add(userId, Notification.SUSPENDED,
                "Reservations are suspended until " + until.withNano(0)
                        + " after " + strikesAllowed + " missed reservations in a row. "
                        + "Charging at a free connector without reserving is still available.");

        // The coordinator is what actually enforces it, on the next claim. Telling it is the
        // last step on purpose: if this message is lost the database still knows, and the next
        // leader change replays it through pushAllSuspensions().
        ErlangBridge.getInstance().notifySuspension(
                userId, until.atZone(ZoneId.systemDefault()).toEpochSecond());

        LOG.log(Level.INFO, "User {0} suspended until {1}", new Object[]{userId, until});
    }
}
