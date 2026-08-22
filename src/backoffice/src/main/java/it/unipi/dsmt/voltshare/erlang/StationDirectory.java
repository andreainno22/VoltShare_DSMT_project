package it.unipi.dsmt.voltshare.erlang;

import it.unipi.dsmt.voltshare.model.StationView;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The station list as the coordinator last pushed it.
 *
 * <p>Every page that shows stations reads from here, so a lobby refresh never reaches the
 * Erlang cluster: high read volume is absorbed by memory, and the cluster keeps working
 * even when nobody is looking. The same trick BlackNet uses for its table list.
 *
 * <p>The whole list is replaced atomically on each update rather than merged, because the
 * coordinator always sends a complete snapshot: partial merging would leave stale stations
 * behind after one goes down.
 */
public final class StationDirectory {

    private static final StationDirectory INSTANCE = new StationDirectory();

    private final AtomicReference<Snapshot> current =
            new AtomicReference<>(new Snapshot(List.of(), Instant.EPOCH));

    private StationDirectory() {
    }

    public static StationDirectory getInstance() {
        return INSTANCE;
    }

    public void replaceAll(List<StationView> stations) {
        current.set(new Snapshot(List.copyOf(stations), Instant.now()));
    }

    public List<StationView> all() {
        return current.get().stations();
    }

    public Optional<StationView> byId(int id) {
        return all().stream().filter(s -> s.getId() == id).findFirst();
    }

    /** When the last push arrived — used to warn that the cluster may be unreachable. */
    public Instant lastUpdate() {
        return current.get().at();
    }

    public boolean isStale() {
        return lastUpdate().isBefore(Instant.now().minusSeconds(90));
    }

    private record Snapshot(List<StationView> stations, Instant at) {
    }
}
