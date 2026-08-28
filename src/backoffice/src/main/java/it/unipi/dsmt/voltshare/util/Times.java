package it.unipi.dsmt.voltshare.util;

import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;

/**
 * Turns the instants stored in MySQL into something a driver can read.
 *
 * <h2>The rule</h2>
 *
 * <p><b>Stored in UTC, displayed in local time.</b> The station writes UTC explicitly, the JDBC
 * URL carries {@code serverTimezone=UTC}, and both containers run with their clock on UTC — so
 * a {@code LocalDateTime} read back from a row is a UTC wall-clock reading with no zone
 * attached to say so.
 *
 * <p>Rendering it as-is is what the history page did until this class existed, and it was
 * wrong in the quiet way: a session charged at 12:00 in Pisa appeared as 10:00. Nothing looks
 * broken — the number is plausible, the date is right, and only someone who remembers when they
 * plugged in would notice.
 *
 * <p>Storing UTC is the right choice and stays: it survives daylight saving, and it is what
 * makes rows from stations in different places comparable. The conversion belongs at the edge,
 * which is here.
 *
 * <h2>Which zone</h2>
 *
 * <p>{@code APP_TIMEZONE}, defaulting to Europe/Rome — where the stations in the seed are.
 * A real deployment would render in the viewer's own zone, which server-side rendering cannot
 * know without asking the browser; that is a limitation of the choice made in SCOPE §6, not an
 * oversight, and one configured zone is the honest version of it for a network in one country.
 */
public final class Times {

    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm");

    /** Read once: a mistyped zone should fail loudly at start-up, not per row. */
    private static final ZoneId DISPLAY_ZONE = resolveZone();

    private Times() {
    }

    /** Formats a UTC timestamp from the database in the display zone. */
    public static String format(LocalDateTime storedUtc) {
        return storedUtc == null ? "" : STAMP.format(toDisplay(storedUtc));
    }

    /** The same conversion, when a caller needs the value rather than the text. */
    public static ZonedDateTime toDisplay(LocalDateTime storedUtc) {
        return storedUtc.atZone(ZoneId.of("UTC")).withZoneSameInstant(DISPLAY_ZONE);
    }

    public static ZoneId displayZone() {
        return DISPLAY_ZONE;
    }

    private static ZoneId resolveZone() {
        String configured = Env.get("APP_TIMEZONE", "Europe/Rome");
        try {
            return ZoneId.of(configured);
        } catch (Exception e) {
            // A bad zone must not take the application down, but it must be visible: falling
            // back to UTC silently would reproduce exactly the bug this class fixes.
            System.getLogger(Times.class.getName())
                    .log(System.Logger.Level.WARNING,
                            "Unknown APP_TIMEZONE '" + configured + "', falling back to UTC");
            return ZoneId.of("UTC");
        }
    }
}
