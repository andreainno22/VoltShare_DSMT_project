package it.unipi.dsmt.voltshare.dao;

import it.unipi.dsmt.voltshare.model.Notification;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * The {@code notifications} table, which belongs to the back office alone
 * (contracts/schema.sql): stations never write it, they ask the coordinator to relay a
 * {@code notify} and it lands here.
 */
public class NotificationDao {

    private static final String BY_USER = """
            SELECT id, kind, text, is_read, created_at
              FROM notifications
             WHERE user_id = ?
             ORDER BY created_at DESC, id DESC
             LIMIT ?
            """;

    private static final String INSERT =
            "INSERT INTO notifications (user_id, kind, text) VALUES (?, ?, ?)";

    private static final String MARK_ALL_READ =
            "UPDATE notifications SET is_read = TRUE WHERE user_id = ? AND is_read = FALSE";

    private static final String UNREAD =
            "SELECT COUNT(*) FROM notifications WHERE user_id = ? AND is_read = FALSE";

    public List<Notification> findByUser(int userId, int limit) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(BY_USER)) {
            ps.setInt(1, userId);
            ps.setInt(2, limit);
            try (ResultSet rs = ps.executeQuery()) {
                List<Notification> out = new ArrayList<>();
                while (rs.next()) {
                    out.add(new Notification(
                            rs.getLong("id"),
                            rs.getString("kind"),
                            rs.getString("text"),
                            rs.getBoolean("is_read"),
                            rs.getTimestamp("created_at").toLocalDateTime()));
                }
                return out;
            }
        }
    }

    /**
     * The text is truncated rather than rejected: the column is 255 characters and a
     * notification arriving from a station is not worth losing over its length.
     */
    public void add(int userId, String kind, String text) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(INSERT)) {
            ps.setInt(1, userId);
            ps.setString(2, kind);
            ps.setString(3, text.length() > 255 ? text.substring(0, 255) : text);
            ps.executeUpdate();
        }
    }

    /** Called when the driver opens the page: seeing them is reading them. */
    public int markAllRead(int userId) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(MARK_ALL_READ)) {
            ps.setInt(1, userId);
            return ps.executeUpdate();
        }
    }

    public int unreadCount(int userId) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(UNREAD)) {
            ps.setInt(1, userId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getInt(1) : 0;
            }
        }
    }
}
