# Contract — JInterface bridge (coordinator ↔ back office)

**Status: internal to B.** Both ends belong to the same developer, so this file does not need
a joint review to change — it is here because the report has to describe the protocol, and
because a contract that lives only in two implementations is a contract nobody can check.

Owners: **B** on both sides — `vs_coord_bo` in Erlang, `erlang.ErlangBridge` in Java.

The back office does not poll the cluster. It joins it: Java opens an `OtpNode`, registers a
mailbox, and receives Erlang terms as they are produced. Every page that lists stations then
reads from memory, so a browser refresh never reaches Erlang.

---

## 1. Topology

| | |
|---|---|
| Java node | `voltshare_bo@<host>`, overridable with `JINTERFACE_NODE` |
| Mailbox | registered as **`backoffice`**, overridable with `JINTERFACE_MBOX` |
| Erlang process | `gen_server` registered as **`vs_coord_srv`** on each coordinator node |
| Cookie | `VOLTSHARE_ERLANG_COOKIE`, the same on every node of the cluster |
| Coordinators | `COORD_NODES=vs@coord1,vs@coord2,vs@coord3`; Java addresses the first entry until told otherwise |

Note the Erlang node names: every node in the cluster uses the short name **`vs`** and is told
apart by its hostname (`deploy/docker-compose.yml`). The Java node is the one exception — it is
`voltshare_bo`, so that it is recognisable in a log and never mistaken for a cluster member.
| Library | **JInterface 1.16**, the one shipped with OTP 29, from `backoffice/libs/` |

**On the library version.** The `org.erlang.otp:jinterface` artifact on Maven Central is
version 1.6.1, from 2011, and it cannot complete the distribution handshake with an OTP 29
node — `OtpNode.ping` simply returns false, with no exception to point at the cause. The jar
we use is built from the sources of the OTP release we run; see `backoffice/libs/README.md`.
Keep it in step with `deploy/Dockerfile.erlang` whenever the OTP version moves.

Java is a **hidden node**: it takes part in the distribution protocol and can be addressed by
name, but it does not appear in `nodes()` and is not part of the coordinators' quorum. That is
the correct arrangement — the back office must never influence who is elected leader.

The bridge runs on its own daemon thread and reconnects every 3 seconds after a failure: a
coordinator restart must not require restarting Tomcat.

---

## 2. Erlang → Java

Sent by the leader to `{backoffice, 'voltshare_bo@host'}`.

### 2.1 `stations_update` — implemented

The full station list, pushed whenever anything visible changes and at least every 30 s.

```erlang
{stations_update, [
  {StationId      :: integer(),
   Node           :: atom(),      %% e.g. 'vs@station1'
   Name           :: binary(),    %% <<"Pisa Centro">>
   Free           :: integer(),
   Held           :: integer(),
   Charging       :: integer(),
   Total          :: integer(),
   SitePowerKw    :: integer(),
   TariffCentsKwh :: integer(),
   WsUrl          :: binary()}    %% <<"ws://localhost:9101/ws/driver">>
]}
```

Three points the Java side depends on:

- **Always a complete snapshot, never a delta.** `StationDirectory` replaces the whole list
  atomically. A partial update would leave a station on the page after its node went down.
- **Text is sent as `binary()`, node names as `atom()`.** The parser also accepts atoms and
  strings where it expects text, to be forgiving, but binaries are what the contract says.
- **`WsUrl` is produced by the coordinator**, not assembled by Java. The back office does not
  know the deployment topology, and must not have to: publishing the reachable address is the
  cluster's job.

A malformed tuple is logged and skipped, never fatal: one broken station must not blank the
whole list.

### 2.2 `leader` — implemented

```erlang
{leader, Node :: atom()}
```

Announces who is serving now. Java records it and sends everything there afterwards. Until the
first announcement it uses the first entry of `COORD_NODES`.

### 2.3 `session_closed` — M2, implemented

```erlang
{session_closed, SessionId :: integer(), UserId :: integer(),
                 StationId :: integer(), ConnId :: integer(),
                 EnergyKwh :: float(), OverstaySeconds :: integer(),
                 StartedAt :: epoch_ms(), EndedAt :: epoch_ms()}
```

**Milliseconds, like everything else on this boundary.** An earlier draft said epoch *seconds*
here, and A was right to push back: `GrantedAt`, `ExpiresAt`, `NewExpiresAt` and `expires_at` are
all milliseconds, all of them from `vs_time:epoch_ms/0`. One message changing unit in the middle
of eight fields that do not is precisely the invisible error this contract keeps warning about —
a factor of 1000 breaks no type, fails no test, and shows up as a date in 1970 on a page nobody
looks at straight away. `OverstaySeconds` keeps its unit in its name, which is why it is allowed
to be seconds.

The station sends this to the coordinator after inserting the row into `sessions`; the
coordinator forwards it here untouched (`vs_coord_srv:session_closed/1`).

**Java does not read the payload.** This message is a *wake-up*, not a source of truth, and the
distinction is the whole design of billing:

- delivery is best-effort — `{Mbox, Node} ! Msg` to an absent mailbox is dropped in silence, on
  purpose, so that Tomcat being down cannot disturb the cluster;
- nothing orders the INSERT against this message, so it can arrive before the row it describes;
- everything it carries is already in the row.

So the back office prices sessions by sweeping `cost_cents IS NULL` every 60 seconds (the schema
indexes it as `idx_unbilled`), and the event only makes that sweep run sooner. Losing every
event delays a receipt by one interval and loses nothing. The UPDATE is conditional on
`cost_cents IS NULL`, so a duplicated event cannot bill twice: **at-least-once delivery over an
idempotent write**, which is how effectively-once behaviour is obtained without an
exactly-once channel.

`OverstaySeconds` is the **billable** overstay: the station has already subtracted its
`OVERSTAY_GRACE_SECONDS`. The grace period is configured on the station and nowhere else, so the
back office never subtracts it a second time. **Confirmed by A on 26/08** — the same semantics
also apply to the `overstay_seconds` field of the live `session` frame in `ws-driver.md` §5.2, so
the name means one thing on both channels.

The price of that overstay is **not** here: it is `stations.tariff_cents_min_overstay`, per
station, exactly like the energy tariff. The event carries what happened; what it costs is
decided at settlement from the station's own row.

### 2.4 From M4 — declared, not yet implemented

Listed so both implementations grow in the same direction.

```erlang
%% M4 — penalty accounting, forwarded by the coordinator on behalf of a station
{no_show, UserId :: integer(), StationId :: integer(), ConnId :: integer()}
{show_up, UserId :: integer()}

%% M4 — something to tell the driver next time they look
{notify, UserId :: integer(), Kind :: binary(), Text :: binary()}
```

Note who does what with `no_show`: the station detects it, the coordinator forwards it, and
**only Java writes the counter** (`contracts/schema.sql`). No two components ever write the
same row.

---

## 3. Java → Erlang

Sent to `{vs_coord_srv, LeaderNode}`.

### 3.1 `get_stations` — implemented

```erlang
{From :: pid(), get_stations}
```

Sent once when the bridge connects, so the back office does not start empty and wait up to
30 seconds for the first spontaneous push. The reply is a normal `stations_update` to `From`.

### 3.2 Suspensions — implemented on the Java side, consumed from M4

```erlang
{user_suspended,   UserId :: integer(), UntilEpochSeconds :: integer()}
{user_unsuspended, UserId :: integer()}
```

`PenaltyService` sends these when the no-show counter trips (SCOPE §3.3). The coordinator keeps
the suspended set in memory and refuses those accounts' claims with `{error, ReqId, suspended}`.

Since the set is in memory and the counter is in MySQL, the coordinator asks for it after a
restart:

```erlang
{From :: pid(), get_suspensions}
   → {suspensions, [{UserId :: integer(), UntilEpochSeconds :: integer()}]}
```

The authoritative copy is the database; the coordinator's copy is a cache, like everything
else it holds.

---

## 4. Failure behaviour

| Situation | What happens |
|---|---|
| No coordinator reachable at start-up | The bridge retries every 3 s. Pages show an empty list with "cluster unreachable" — never a stale list presented as current |
| Coordinator dies while Tomcat runs | The last snapshot stays in memory and is marked stale after 90 s. `StationsServlet` shows the warning |
| Tomcat dies | The coordinator keeps working. Stations and reservations are unaffected: the back office is not on the path of any reservation |
| Message lost | Tolerable in both directions. The periodic `stations_update` re-synchronises the list, and suspensions are re-read with `get_suspensions` |

Nothing in this bridge is on the critical path of a reservation or of a charging session. It
carries what the browser needs to *see* and what accounting needs to *record*, which is why
losing it degrades the application without stopping it.

---

## 5. Smoke test

The first thing to verify once Docker and Erlang are installed, because node naming, cookies
and DNS between containers are the classic source of trouble (piano §10):

```erlang
%% from a coordinator shell
(vs@coord1)1> {backoffice, 'voltshare_bo@backoffice'} ! {leader, node()}.
```

The Tomcat log must show `Coordinator leader is now vs@coord1`. Then, from Java, the reverse
direction: the bridge sends `get_stations` on connect, so a coordinator that logs the incoming
request proves both directions work.
