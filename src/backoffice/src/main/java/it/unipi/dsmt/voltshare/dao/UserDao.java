package it.unipi.dsmt.voltshare.dao;

import it.unipi.dsmt.voltshare.model.User;
import it.unipi.dsmt.voltshare.util.PasswordUtil;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;

/**
 * Accounts and their single vehicle.
 *
 * <p>This DAO owns {@code users} and {@code vehicles}: nothing else in the system writes
 * them, and in particular the stations never touch the penalty columns (contracts/schema.sql).
 */
public class UserDao {

    private static final String SELECT_BASE = """
            SELECT u.id, u.username, u.password_hash, u.no_show_count, u.suspended_until,
                   v.id AS vehicle_id, v.battery_kwh, v.max_kw
              FROM users u
              LEFT JOIN vehicles v ON v.user_id = u.id
            """;

    /** Creates the account and its vehicle atomically: an account without a vehicle cannot reserve. */
    public User register(String username, String plainPassword, double batteryKwh, int maxKw)
            throws SQLException, DuplicateUsernameException {
        try (Connection c = Db.getConnection()) {
            c.setAutoCommit(false);
            try {
                int userId;
                try (PreparedStatement ps = c.prepareStatement(
                        "INSERT INTO users (username, password_hash) VALUES (?, ?)",
                        Statement.RETURN_GENERATED_KEYS)) {
                    ps.setString(1, username);
                    ps.setString(2, PasswordUtil.hash(plainPassword));
                    ps.executeUpdate();
                    try (ResultSet keys = ps.getGeneratedKeys()) {
                        keys.next();
                        userId = keys.getInt(1);
                    }
                } catch (SQLException e) {
                    // The rollback is left to the outer catch: doing it here too
                    // would roll back an already rolled-back transaction.
                    if (isDuplicateKey(e)) {
                        throw new DuplicateUsernameException(username);
                    }
                    throw e;
                }

                int vehicleId;
                try (PreparedStatement ps = c.prepareStatement(
                        "INSERT INTO vehicles (user_id, battery_kwh, max_kw) VALUES (?, ?, ?)",
                        Statement.RETURN_GENERATED_KEYS)) {
                    ps.setInt(1, userId);
                    ps.setDouble(2, batteryKwh);
                    ps.setInt(3, maxKw);
                    ps.executeUpdate();
                    try (ResultSet keys = ps.getGeneratedKeys()) {
                        keys.next();
                        vehicleId = keys.getInt(1);
                    }
                }

                c.commit();
                return new User(userId, username, vehicleId, batteryKwh, maxKw, 0, null);
            } catch (SQLException | DuplicateUsernameException e) {
                c.rollback();
                throw e;
            } finally {
                c.setAutoCommit(true);
            }
        }
    }

    /** Returns the user when the password matches, otherwise null. */
    public User authenticate(String username, String plainPassword) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(SELECT_BASE + " WHERE u.username = ?")) {
            ps.setString(1, username);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return null;
                }
                if (!PasswordUtil.matches(plainPassword, rs.getString("password_hash"))) {
                    return null;
                }
                return map(rs);
            }
        }
    }

    public User findById(int id) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(SELECT_BASE + " WHERE u.id = ?")) {
            ps.setInt(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? map(rs) : null;
            }
        }
    }

    // ---- penalty state (SCOPE §3.3) ---------------------------------------------
    //
    // These two columns are written here and nowhere else in the system. A station
    // observes a no-show and says so; it never counts, and never suspends.

    /**
     * Counts one missed reservation and returns the new consecutive total.
     *
     * <p>Increment and read-back run in one transaction with the row locked. Two no-shows for
     * the same driver arriving at the same moment is not a scenario worth assuming away: the
     * strikes are what decides a suspension, and reading a count that a concurrent increment is
     * about to change would let the second strike be counted as the first.
     */
    public int recordNoShow(int userId) throws SQLException {
        try (Connection c = Db.getConnection()) {
            c.setAutoCommit(false);
            try {
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT no_show_count FROM users WHERE id = ? FOR UPDATE")) {
                    ps.setInt(1, userId);
                    try (ResultSet rs = ps.executeQuery()) {
                        if (!rs.next()) {
                            c.rollback();
                            return 0;   // the account is gone; nothing to punish
                        }
                    }
                }
                int count;
                try (PreparedStatement ps = c.prepareStatement(
                        "UPDATE users SET no_show_count = no_show_count + 1 WHERE id = ?")) {
                    ps.setInt(1, userId);
                    ps.executeUpdate();
                }
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT no_show_count FROM users WHERE id = ?")) {
                    ps.setInt(1, userId);
                    try (ResultSet rs = ps.executeQuery()) {
                        rs.next();
                        count = rs.getInt(1);
                    }
                }
                c.commit();
                return count;
            } catch (SQLException e) {
                c.rollback();
                throw e;
            } finally {
                c.setAutoCommit(true);
            }
        }
    }

    /**
     * The driver turned up: the streak resets.
     *
     * <p>"Consecutive" is the whole point of the rule — someone who reserves ten times, shows up
     * nine and misses one is not the behaviour the suspension is aimed at.
     */
    public void clearNoShowStreak(int userId) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(
                     "UPDATE users SET no_show_count = 0 WHERE id = ? AND no_show_count > 0")) {
            ps.setInt(1, userId);
            ps.executeUpdate();
        }
    }

    /** Suspends the account and resets the streak: the penalty has been served on it. */
    public void suspendUntil(int userId, LocalDateTime until) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(
                     "UPDATE users SET suspended_until = ?, no_show_count = 0 WHERE id = ?")) {
            ps.setTimestamp(1, Timestamp.valueOf(until));
            ps.setInt(2, userId);
            ps.executeUpdate();
        }
    }

    /**
     * Every suspension still running, for pushing to a newly elected coordinator.
     *
     * <p>Claims can be rebuilt by asking the stations, because the stations hold them.
     * Suspensions cannot: they live only here, so a new leader starts with none and would let a
     * suspended driver reserve until someone told it otherwise. This is what tells it.
     */
    public List<long[]> activeSuspensions() throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(
                     // The cut-off is computed here, not with MySQL's NOW().
                     //
                     // The column is written with this JVM's clock, so filtering it with the
                     // database's own clock compares two readings that need not agree. In the
                     // compose both run on UTC and it happens to work; on a developer machine
                     // in another zone the suspension would silently stretch or shrink by the
                     // offset. Reported by A, R5 of the review of PR #5 — related to the
                     // truncation fix, but not covered by it.
                     "SELECT id, suspended_until FROM users "
                             + "WHERE suspended_until IS NOT NULL AND suspended_until > ?")) {
            ps.setTimestamp(1, Timestamp.valueOf(LocalDateTime.now(ZoneOffset.UTC)));
            try (ResultSet rs = ps.executeQuery()) {
                List<long[]> out = new ArrayList<>();
                while (rs.next()) {
                    long epochSeconds = rs.getTimestamp("suspended_until")
                            .toLocalDateTime()
                            .toEpochSecond(ZoneOffset.UTC);
                    // long, not int: an epoch in seconds outgrows an int in 2038, and a
                    // silent truncation there would lift every suspension at once.
                    out.add(new long[]{rs.getLong("id"), epochSeconds});
                }
                return out;
            }
        }
    }

    private User map(ResultSet rs) throws SQLException {
        Timestamp until = rs.getTimestamp("suspended_until");
        return new User(
                rs.getInt("id"),
                rs.getString("username"),
                rs.getInt("vehicle_id"),
                rs.getDouble("battery_kwh"),
                rs.getInt("max_kw"),
                rs.getInt("no_show_count"),
                until == null ? null : until.toLocalDateTime());
    }

    private boolean isDuplicateKey(SQLException e) {
        return e.getErrorCode() == 1062 || "23000".equals(e.getSQLState());
    }

    /** Thrown instead of surfacing a vendor error code to the servlet. */
    public static class DuplicateUsernameException extends Exception {
        public DuplicateUsernameException(String username) {
            super("Username already taken: " + username);
        }
    }
}
