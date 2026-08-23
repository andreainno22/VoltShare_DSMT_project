package it.unipi.dsmt.voltshare.dao;

import it.unipi.dsmt.voltshare.model.User;
import it.unipi.dsmt.voltshare.util.PasswordUtil;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;

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
