package it.unipi.dsmt.voltshare.model;

import java.time.LocalDateTime;
import it.unipi.dsmt.voltshare.util.Times;

/**
 * Something the system needs to tell a driver who is not looking right now.
 *
 * <p>The counterpart of the WebSocket push: a driver watching the station page sees events as
 * they happen, one who closed the browser finds them here. That split is a stated limitation
 * of the client channel (DESIGN-NOTES): with no mobile push, a notification only reaches
 * someone who comes back to the application.
 *
 * <p>A bean, not a record — JSP expression language resolves {@code ${n.text}} through
 * {@code getText()}.
 */
public class Notification {

    /** The kinds `schema.sql` documents. Kept as constants so a typo fails at compile time. */
    public static final String RESERVATION_EXPIRED = "reservation_expired";
    public static final String CHARGE_COMPLETE = "charge_complete";
    public static final String WAITLIST_OFFER = "waitlist_offer";
    public static final String SESSION_INTERRUPTED = "session_interrupted";
    public static final String SUSPENDED = "suspended";

    private final long id;
    private final String kind;
    private final String text;
    private final boolean read;
    private final LocalDateTime createdAt;

    public Notification(long id, String kind, String text, boolean read, LocalDateTime createdAt) {
        this.id = id;
        this.kind = kind;
        this.text = text;
        this.read = read;
        this.createdAt = createdAt;
    }

    public long getId() {
        return id;
    }

    public String getKind() {
        return kind;
    }

    public String getText() {
        return text;
    }

    /** EL resolves {@code ${n.read}} through this. */
    public boolean isRead() {
        return read;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    /** Stored in UTC, shown in local time — see {@link Times}. */
    public String getCreatedText() {
        return Times.format(createdAt);
    }

    /** A suspension is the one notice the driver must not scroll past. */
    public boolean isImportant() {
        return SUSPENDED.equals(kind) || SESSION_INTERRUPTED.equals(kind);
    }

    @Override
    public String toString() {
        return "Notification{" + id + " " + kind + "}";
    }
}
