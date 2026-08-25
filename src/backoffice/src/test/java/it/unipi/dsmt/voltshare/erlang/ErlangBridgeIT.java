package it.unipi.dsmt.voltshare.erlang;

import com.ericsson.otp.erlang.OtpNode;
import it.unipi.dsmt.voltshare.model.StationView;
import org.junit.jupiter.api.Test;

import java.net.InetAddress;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * The one thing the plan flagged as the biggest deployment risk: Java and Erlang actually
 * talking to each other. Node naming, cookies and the distribution handshake are where this
 * goes wrong, and none of it shows up in a unit test.
 *
 * <p>Needs a coordinator running on this machine. Start one with:
 *
 * <pre>
 * cd src/erlang
 * JINTERFACE_NODE="voltshare_bo_test@$(hostname)" \
 *   erl -sname vs -setcookie voltshare -pa _build/default/lib/*&#47;ebin -noshell -eval \
 *   'application:ensure_all_started(vs_coord),
 *    vs_coord_srv:station_up({station_up,1,node(),&lt;&lt;"Pisa Centro"&gt;&gt;,
 *                             &lt;&lt;"ws://localhost:9101/ws/driver"&gt;&gt;,350,45,[1,2,3,4]}).'
 * </pre>
 *
 * <p>Without it the test skips rather than fails: it is an integration check, and a red
 * build every time nobody has a node up would train everyone to ignore it.
 */
class ErlangBridgeIT {

    private static final String COOKIE = "voltshare";

    @Test
    void receivesTheStationListFromARealCoordinator() throws Exception {
        String host = InetAddress.getLocalHost().getHostName();
        String coordinator = "vs@" + host;

        assumeTrue(coordinatorIsUp(coordinator), "no coordinator node at " + coordinator);

        // Env reads system properties as well, so the bridge can be pointed at the
        // node this test expects without touching the environment.
        System.setProperty("JINTERFACE_NODE", "voltshare_bo_test@" + host);
        System.setProperty("JINTERFACE_MBOX", "backoffice");
        System.setProperty("COORD_NODES", coordinator);
        System.setProperty("VOLTSHARE_ERLANG_COOKIE", COOKIE);

        ErlangBridge.getInstance().start();

        List<StationView> stations = awaitStations(Duration.ofSeconds(20));

        assertFalse(stations.isEmpty(),
                "the coordinator pushes on connect: an empty directory means the "
                        + "handshake or the mailbox name is wrong, not that it is slow");

        StationView pisa = stations.stream()
                .filter(s -> s.getId() == 1)
                .findFirst()
                .orElseThrow(() -> new AssertionError("station 1 missing from " + stations));

        // Values come straight from the tuple the coordinator sent: if the parser
        // mixed up two positions, this is where it shows.
        assertEquals("Pisa Centro", pisa.getName());
        assertEquals(4, pisa.getTotal());
        assertEquals(350, pisa.getSitePowerKw());
        assertEquals(45, pisa.getTariffCentsKwh());
        assertEquals("ws://localhost:9101/ws/driver", pisa.getWsUrl());
        assertTrue(pisa.getNode().startsWith("vs@"), "node name should be an atom like vs@host");

        assertFalse(StationDirectory.getInstance().isStale(),
                "a directory just filled in cannot be stale");
    }

    private boolean coordinatorIsUp(String coordinator) {
        try {
            String probeName = "vs_probe_" + System.nanoTime()
                    + "@" + InetAddress.getLocalHost().getHostName();
            OtpNode probe = new OtpNode(probeName, COOKIE);
            try {
                return probe.ping(coordinator, 1500);
            } finally {
                probe.close();
            }
        } catch (Exception e) {
            // No EPMD, no network stack, no Erlang: nothing to integrate with.
            return false;
        }
    }

    private List<StationView> awaitStations(Duration timeout) throws InterruptedException {
        Instant deadline = Instant.now().plus(timeout);
        List<StationView> stations = StationDirectory.getInstance().all();
        while (stations.isEmpty() && Instant.now().isBefore(deadline)) {
            Thread.sleep(250);
            stations = StationDirectory.getInstance().all();
        }
        return stations;
    }
}
