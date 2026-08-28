package it.unipi.dsmt.voltshare.dao;

import it.unipi.dsmt.voltshare.model.SessionView;
import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * The one thing about {@link SessionDao} that a unit test cannot check: how JDBC reports SQL
 * NULL.
 *
 * <p>Written after a bug that no amount of reasoning about the code would have caught, because
 * the code read correctly. {@code map} called {@code rs.wasNull()} at the end of a nine-argument
 * constructor call, and {@code wasNull()} answers about the <em>last column read</em> — by then
 * {@code overstay_seconds}, which is NOT NULL. So it always said false, and every session the
 * sweep had not priced yet was rendered as "€ 0.00" instead of "pending". The comment two lines
 * above described the intended behaviour exactly while the code did the opposite.
 *
 * <p>Hence this test asserts the distinction directly against a real driver, with a row whose
 * {@code cost_cents} is NULL. Reported by A on 28/08 — see contracts/nota-per-B-m2a.md §5.
 *
 * <p>Needs the compose MySQL on localhost:3306. Without it the test skips rather than fails: a
 * red build every time nobody has the stack up would train everyone to ignore it.
 */
class SessionDaoIT {

    private final SessionDao sessions = new SessionDao();

    @Test
    void anUnbilledSessionIsPendingAndNotFree() throws Exception {
        assumeTrue(databaseIsUp(), "no MySQL on localhost:3306");

        int userId = anyUserId();
        assumeTrue(userId > 0, "no user in the database to attach a session to");

        long id = insertUnbilledSession(userId);
        try {
            SessionView row = sessions.findByUser(userId, 100).stream()
                    .filter(s -> s.getId() == id)
                    .findFirst()
                    .orElseThrow(() -> new AssertionError("the inserted session was not read back"));

            assertFalse(row.isBilled(),
                    "a row with cost_cents NULL must read as unbilled, not as costing nothing");
            assertNull(row.getCostCents());
            assertEquals("—", row.getCostEuro(),
                    "the page must say pending, not € 0.00");

            // The column that used to be answering wasNull() by mistake. Asserted so that a
            // future reordering of map() cannot quietly bring the bug back.
            assertEquals(0, row.getOverstaySeconds());
        } finally {
            delete(id);
        }
    }

    @Test
    void aBilledSessionKeepsItsCost() throws Exception {
        assumeTrue(databaseIsUp(), "no MySQL on localhost:3306");

        int userId = anyUserId();
        assumeTrue(userId > 0, "no user in the database to attach a session to");

        long id = insertUnbilledSession(userId);
        try {
            assertTrue(sessions.markBilled(id, 1234));

            SessionView row = sessions.findByUser(userId, 100).stream()
                    .filter(s -> s.getId() == id)
                    .findFirst()
                    .orElseThrow();

            assertTrue(row.isBilled());
            assertEquals(1234, row.getCostCents());
            assertEquals("12.34", row.getCostEuro());

            // Idempotence: the sweep and a session_closed event race routinely, and the second
            // writer must find nothing to do rather than overwrite a settled price.
            assertFalse(sessions.markBilled(id, 9999),
                    "an already billed session must not be repriced");
        } finally {
            delete(id);
        }
    }

    // ---- fixture ----------------------------------------------------------------

    private boolean databaseIsUp() {
        try (Connection c = Db.getConnection()) {
            return c != null;
        } catch (Exception e) {
            return false;
        }
    }

    /** Any account will do: what is under test is the mapping, not who owns the row. */
    private int anyUserId() throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement("SELECT id FROM users ORDER BY id LIMIT 1");
             ResultSet rs = ps.executeQuery()) {
            return rs.next() ? rs.getInt(1) : 0;
        }
    }

    private long insertUnbilledSession(int userId) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement(
                     "INSERT INTO sessions (user_id, station_id, connector_id, started_at, "
                             + "ended_at, energy_kwh, overstay_seconds, cost_cents) "
                             + "VALUES (?, 1, 1, NOW(), NOW(), 1.000, 0, NULL)",
                     Statement.RETURN_GENERATED_KEYS)) {
            ps.setInt(1, userId);
            ps.executeUpdate();
            try (ResultSet keys = ps.getGeneratedKeys()) {
                keys.next();
                return keys.getLong(1);
            }
        }
    }

    /** The test owns the row it made, and leaves the shared database as it found it. */
    private void delete(long id) throws SQLException {
        try (Connection c = Db.getConnection();
             PreparedStatement ps = c.prepareStatement("DELETE FROM sessions WHERE id = ?")) {
            ps.setLong(1, id);
            ps.executeUpdate();
        }
    }
}
