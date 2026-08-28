package it.unipi.dsmt.voltshare.model;

import java.time.LocalDateTime;

import it.unipi.dsmt.voltshare.util.Times;

/**
 * A driver and the single vehicle bound to the account.
 *
 * <p>One vehicle per account is a deliberate constraint (SCOPE §3.1): it is what keeps the
 * no-show counter free of contention, since an account can hold only one reservation.
 *
 * <p>Plain getters rather than a record: Expression Language in JSP resolves
 * {@code ${user.username}} through the JavaBeans convention, which records do not follow.
 */
public class User {

    private int id;
    private String username;
    private int vehicleId;
    private double batteryKwh;
    private int maxKw;
    private int noShowCount;
    private LocalDateTime suspendedUntil;

    public User() {
    }

    public User(int id, String username, int vehicleId, double batteryKwh, int maxKw,
                int noShowCount, LocalDateTime suspendedUntil) {
        this.id = id;
        this.username = username;
        this.vehicleId = vehicleId;
        this.batteryKwh = batteryKwh;
        this.maxKw = maxKw;
        this.noShowCount = noShowCount;
        this.suspendedUntil = suspendedUntil;
    }

    /**
     * The end of the suspension in local time, for the profile page.
     *
     * <p>Stored in UTC like every other instant, so rendering the raw value would tell a driver
     * in Pisa that their suspension lifts two hours before it does. See {@link Times}.
     */
    public String getSuspendedUntilText() {
        return suspendedUntil == null ? "" : Times.format(suspendedUntil);
    }

    public boolean isSuspended() {
        return suspendedUntil != null && suspendedUntil.isAfter(LocalDateTime.now());
    }

    public int getId() {
        return id;
    }

    public void setId(int id) {
        this.id = id;
    }

    public String getUsername() {
        return username;
    }

    public void setUsername(String username) {
        this.username = username;
    }

    public int getVehicleId() {
        return vehicleId;
    }

    public void setVehicleId(int vehicleId) {
        this.vehicleId = vehicleId;
    }

    public double getBatteryKwh() {
        return batteryKwh;
    }

    public void setBatteryKwh(double batteryKwh) {
        this.batteryKwh = batteryKwh;
    }

    public int getMaxKw() {
        return maxKw;
    }

    public void setMaxKw(int maxKw) {
        this.maxKw = maxKw;
    }

    public int getNoShowCount() {
        return noShowCount;
    }

    public void setNoShowCount(int noShowCount) {
        this.noShowCount = noShowCount;
    }

    public LocalDateTime getSuspendedUntil() {
        return suspendedUntil;
    }

    public void setSuspendedUntil(LocalDateTime suspendedUntil) {
        this.suspendedUntil = suspendedUntil;
    }
}
