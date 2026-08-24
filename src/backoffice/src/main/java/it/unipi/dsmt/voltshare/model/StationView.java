package it.unipi.dsmt.voltshare.model;

/**
 * One station as the coordinator last described it (contracts/erlang-java.md).
 *
 * <p>A snapshot held in memory, never read from the database: the cluster is the authority
 * on how many connectors are free right now, and the back office only caches what it is told.
 *
 * <p>Plain getters, so that JSP can reach the fields as {@code ${s.name}}, {@code ${s.free}}.
 */
public class StationView {

    private final int id;
    private final String node;
    private final String name;
    private final int free;
    private final int held;
    private final int charging;
    private final int total;
    private final int sitePowerKw;
    private final int tariffCentsKwh;
    private final String wsUrl;

    public StationView(int id, String node, String name, int free, int held, int charging,
                       int total, int sitePowerKw, int tariffCentsKwh, String wsUrl) {
        this.id = id;
        this.node = node;
        this.name = name;
        this.free = free;
        this.held = held;
        this.charging = charging;
        this.total = total;
        this.sitePowerKw = sitePowerKw;
        this.tariffCentsKwh = tariffCentsKwh;
        this.wsUrl = wsUrl;
    }

    /**
     * Connectors that are in none of the three counted states: offline, restarting or
     * faulted. The station deliberately leaves them out of free/held/charging, so the
     * three do not have to add up to the total — and a connector in {@code closing} is
     * reported as charging, since its session is still finishing.
     */
    public int getUnavailable() {
        return Math.max(0, total - free - held - charging);
    }

    public boolean isBusy() {
        return free == 0;
    }

    public String getTariffEuroKwh() {
        return String.format("%.2f", tariffCentsKwh / 100.0);
    }

    public int getId() {
        return id;
    }

    public String getNode() {
        return node;
    }

    public String getName() {
        return name;
    }

    public int getFree() {
        return free;
    }

    public int getHeld() {
        return held;
    }

    public int getCharging() {
        return charging;
    }

    public int getTotal() {
        return total;
    }

    public int getSitePowerKw() {
        return sitePowerKw;
    }

    public int getTariffCentsKwh() {
        return tariffCentsKwh;
    }

    public String getWsUrl() {
        return wsUrl;
    }
}
