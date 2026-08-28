package it.unipi.dsmt.voltshare.dao;

import it.unipi.dsmt.voltshare.model.SessionView;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * Reads {@code sessions}, and writes exactly one of its columns.
 *
 * <p>Ownership is split down the middle (contracts/schema.sql): the station INSERTs the row
 * when a session ends and never comes back to it; the back office only ever sets
 * {@code cost_cents}. Two components touch the table, never the same column, so no locking
 * discipline is needed between them.
 */
public class SessionDao {

    private static final String HISTORY = """
            SELECT s.id, s.station_id, st.name AS station_name, s.connector_id,
                   s.started_at, s.ended_at, s.energy_kwh, s.overstay_seconds, s.cost_cents
              FROM sessions s
              JOIN stations st ON st.id = s.station_id
             WHERE s.user_id = ?
             ORDER BY s.started_at DESC
             LIMIT ?
            """;

    /**
     * Both tariffs come from {@code stations}, not from the closing event and not from the
     * environment: they are the price at settlement, and keeping them in one place means a
     * change does not need every station to be told about it.
     *
     * <p>{@code tariff_cents_min_overstay} is read here because the schema makes it a
     * <em>per-station</em> price. An earlier version of this DAO selected only the energy
     * tariff and let {@link it.unipi.dsmt.voltshare.service.BillingService} take the overstay
     * rate from an environment variable — so one addend of the same formula was per station
     * and the other per deployment, and the column the contract had created for it was read
     * by nobody. Both happened to be 50, so nothing failed; it would have surfaced the day one
     * site priced overstay differently from another.
     */
    private static final String UNBILLED = """
            SELECT s.id, s.energy_kwh, s.overstay_seconds,
                   st.tariff_cents_kwh, st.tariff_cents_min_overstay
              FROM sessions s
              JOIN stations st ON st.id = s.station_id
             WHERE s.cost_cents IS NULL
             ORDER BY s.id
             LIMIT ?
            """;

    /** The IS NULL is what makes billing idempotent — see {@link #markBilled}. */
    private static final String BILL =
            "UPDATE sessions SET cost_cents = ? WHERE id = ? AND cost_cents IS NULL";

    /** Most recent first. The limit keeps a long-lived account from rendering a huge page. */
    public List<SessionView> findByUser(int userId, int limit) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(HISTORY)) {
            ps.setInt(1, userId);
            ps.setInt(2, limit);
            try (ResultSet rs = ps.executeQuery()) {
                List<SessionView> out = new ArrayList<>();
                while (rs.next()) {
                    out.add(map(rs));
                }
                return out;
            }
        }
    }

    /** Sessions the station has closed and nobody has priced yet. */
    public List<Unbilled> findUnbilled(int limit) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(UNBILLED)) {
            ps.setInt(1, limit);
            try (ResultSet rs = ps.executeQuery()) {
                List<Unbilled> out = new ArrayList<>();
                while (rs.next()) {
                    out.add(new Unbilled(
                            rs.getLong("id"),
                            rs.getDouble("energy_kwh"),
                            rs.getInt("overstay_seconds"),
                            rs.getInt("tariff_cents_kwh"),
                            rs.getInt("tariff_cents_min_overstay")));
                }
                return out;
            }
        }
    }

    /**
     * Prices one session, once.
     *
     * <p>Returns false when the row was already billed, which is not a failure: the sweep and
     * a {@code session_closed} event can easily race, and this is how that race is settled —
     * the second writer finds no row to update and moves on. It is the reason the bridge can
     * deliver events at-least-once without ever double-charging anyone.
     */
    public boolean markBilled(long sessionId, int costCents) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(BILL)) {
            ps.setInt(1, costCents);
            ps.setLong(2, sessionId);
            return ps.executeUpdate() == 1;
        }
    }

    private SessionView map(ResultSet rs) throws SQLException {
        // getInt returns 0 for SQL NULL, so wasNull() is the only way to tell an unbilled
        // session from a free one — and it reports on the LAST column read, which is why it
        // is called here and not further down.
        //
        // It used to be evaluated at the end of the constructor call, after eight more
        // columns. By then it was answering about overstay_seconds, which is NOT NULL, so it
        // was always false and every unbilled session rendered as "€ 0.00" instead of
        // "pending" — the exact distinction the comment claimed to be making. Found by A on
        // 28/08; the window is normally one sweep, but it lasts as long as the back office is
        // down, which is when unbilled rows pile up.
        int cost = rs.getInt("cost_cents");
        boolean unbilled = rs.wasNull();

        return new SessionView(
                rs.getLong("id"),
                rs.getInt("station_id"),
                rs.getString("station_name"),
                rs.getInt("connector_id"),
                rs.getTimestamp("started_at").toLocalDateTime(),
                rs.getTimestamp("ended_at").toLocalDateTime(),
                rs.getDouble("energy_kwh"),
                rs.getInt("overstay_seconds"),
                unbilled ? null : cost);
    }

    /**
     * What pricing needs and nothing more. A record is fine here, unlike the view models:
     * this one never reaches a JSP, so no expression language ever looks for getters on it.
     */
    public record Unbilled(long id, double energyKwh, int overstaySeconds,
                           int tariffCentsKwh, int overstayCentsPerMinute) {
    }
}
