package it.unipi.dsmt.voltshare.model;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/**
 * One completed charging session, as the history page shows it.
 *
 * <p>A plain bean, not a record: JSP expression language resolves {@code ${s.energyKwh}}
 * through {@code getEnergyKwh()}, and record accessors carry no {@code get} prefix — the
 * same trap already met with {@link User} and {@link StationView}.
 *
 * <p>The row is written by the station (contracts/schema.sql: A inserts, B updates
 * {@code cost_cents} and nothing else), so everything here except the cost is read-only
 * as far as the back office is concerned.
 */
public class SessionView {

    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm");

    private final long id;
    private final int stationId;
    private final String stationName;
    private final int connectorId;
    private final LocalDateTime startedAt;
    private final LocalDateTime endedAt;
    private final double energyKwh;
    private final int overstaySeconds;
    /** Null until billed: the station leaves it NULL and BillingService fills it in. */
    private final Integer costCents;

    public SessionView(long id, int stationId, String stationName, int connectorId,
                       LocalDateTime startedAt, LocalDateTime endedAt,
                       double energyKwh, int overstaySeconds, Integer costCents) {
        this.id = id;
        this.stationId = stationId;
        this.stationName = stationName;
        this.connectorId = connectorId;
        this.startedAt = startedAt;
        this.endedAt = endedAt;
        this.energyKwh = energyKwh;
        this.overstaySeconds = overstaySeconds;
        this.costCents = costCents;
    }

    // ---- derived, so that the JSP stays free of formatting logic ----------------

    public boolean isBilled() {
        return costCents != null;
    }

    /** Euro with two decimals, or a dash while the sweep has not run yet. */
    public String getCostEuro() {
        return costCents == null ? "—" : String.format("%.2f", costCents / 100.0);
    }

    public String getEnergyText() {
        return String.format("%.2f", energyKwh);
    }

    public long getDurationMinutes() {
        return Duration.between(startedAt, endedAt).toMinutes();
    }

    /**
     * Billable overstay minutes, rounded up: the grace period is already subtracted by the
     * station, so any second here is a second past it (contracts/ws-chargepoint.md).
     */
    public long getOverstayMinutes() {
        return (overstaySeconds + 59) / 60;
    }

    public boolean isOverstayed() {
        return overstaySeconds > 0;
    }

    public String getStartedText() {
        return STAMP.format(startedAt);
    }

    public String getEndedText() {
        return STAMP.format(endedAt);
    }

    // ---- plain accessors --------------------------------------------------------

    public long getId() {
        return id;
    }

    public int getStationId() {
        return stationId;
    }

    public String getStationName() {
        return stationName;
    }

    public int getConnectorId() {
        return connectorId;
    }

    public LocalDateTime getStartedAt() {
        return startedAt;
    }

    public LocalDateTime getEndedAt() {
        return endedAt;
    }

    public double getEnergyKwh() {
        return energyKwh;
    }

    public int getOverstaySeconds() {
        return overstaySeconds;
    }

    public Integer getCostCents() {
        return costCents;
    }

    @Override
    public String toString() {
        return "SessionView{" + id + " station=" + stationId + " kWh=" + energyKwh
                + " cost=" + costCents + "}";
    }
}
