# VoltShare — Design Notes

Working notes behind [SCOPE.md](SCOPE.md). The scope document states *what* the system does; this file keeps *why*, the reasoning that has to survive questioning at the presentation, the edge cases, and the things we deliberately decided not to do.

Written in English so the passages that belong in the final document can be reused directly. Parameters quoted throughout (15-minute lease, 350 kW site budget, and so on) are placeholders until the real ones are fixed.

---

## 1. Why this domain holds up

The project needs contention that is intrinsic to the problem rather than manufactured. The argument, in the form it should be defended:

**The operator has no authority over the agents.** A delivery platform can assign a courier to an order — couriers are workers and the system knows their position, so the dispatch becomes an optimisation problem and contention disappears. A driver of a private car cannot be assigned anywhere: they have their own destination and can ignore any suggestion. The system can only *arbitrate the requests drivers make*. Centralising the decision does not remove the contention, because the central decider has no power to decide in the drivers' place.

**The exclusivity is physical, not conventional.** One outlet, one vehicle, for thirty to forty minutes. It is not a lock that a smarter assignment could avoid, and the long, imprecisely known occupancy is what makes the contention observable rather than lost in the noise.

**The partitioning is not a didactic device.** Charging sites are in different places, and dynamic load management is normally done by a controller installed on site, because it must react quickly and keep working when the link to the operator's cloud is down. Our station node *is* that site controller. The edge/cloud split mirrors a real deployment, which is also what justifies the station-autonomy requirement.

### What was considered before this

- *Delivery dispatch.* Rejected: with rider positions known, push assignment is both the industry norm and the better solution, and a competitive-claim model would be a step backwards that invites the question "why don't you assign?".
- *Seat/slot booking.* Works, but collapses into a single database transaction; the real-time side is thin.
- *Real-time auctions.* Structurally identical to a card-game project (a room process, participants, phases, money) and would reproduce the same balance-contention problem.

---

## 2. Two exclusions, not one

This distinction runs through the whole design and is worth stating early in the final document.

| | Object protected | Contended by | Scope |
|---|---|---|---|
| **P1** | the connector | drivers, among themselves | inside one station |
| **P2** | the vehicle | **stations, among themselves** | across nodes |

A connector belongs to exactly one station, always: no other node can grant it, so no remote agreement is needed. The vehicle is the only entity that can appear at two stations at once — the driver opens two browser tabs and presses *reserve* on both. Each station checks *its own* connector, finds it free, and grants: both are locally correct, both respected P1, and the network-wide invariant is broken. Neither can detect this alone, because the missing fact lives in neither of them.

**The connector is stationary and belongs to a node; the vehicle moves and belongs to the network.** The first is settled in-house, the second is not.

Consequence for algorithm choice: the textbook mutual-exclusion algorithms assume *one* critical section, whereas here there is one per vehicle, and they are independent — reservations for two different vehicles have no reason to wait for each other. This is what makes arbitration (or partitioning) a better fit than Ricart-Agrawala, despite the latter being the more elegant algorithm in the syllabus.

---

## 3. Claim and reservation

A **reservation** is what the driver sees: this connector, held for me, until this time; owned by the connector process. A **claim** is the permission that made it possible: an entry at the coordinator recording that this *vehicle* is committed, and to which station. Local and about a connector, versus network-wide and about a vehicle.

### Claim first, commit after

The station obtains the claim **before** creating the reservation, never the reverse.

- Wrong order: a crash between the two leaves a reservation that no other node knows about, and the vehicle can reserve elsewhere. The invariant is broken silently.
- Right order: the same crash leaves a granted but unused claim. Nobody can reserve for that vehicle for a few minutes, then the claim expires. The system errs towards refusing, not towards double-granting.

Same reasoning as a write-ahead log — record the commitment before acting — applied to a permission instead of a balance.

### Two nested expiries

- The **reservation lease** protects against a driver who never shows up.
- The **claim expiry** protects against a station that dies without releasing it. Without it, a crashed node would lock its vehicles out of the whole network indefinitely.

---

## 4. The coordinator

### Why it is replicated

A single coordinator is a defensible design — the failure is only partial, because it sits outside the critical path: sessions in progress keep running, only new reservations and the live station list are lost. It was rejected because it leaves an avoidable single point of failure on the one guarantee the system is built around.

Note honestly that MySQL remains a single point of failure for durable data. The point is not to eliminate every one of them, which is out of reach here, but to choose which ones to keep and to know what happens when they fail.

### Election (bully)

Rule: the highest live UID wins. A node that notices the leader is unresponsive sends `ELECTION` to the nodes above it; silence for T means it is the highest alive and it announces `LEADER` downwards; an `ANSWER` means someone more senior is handling it, and it waits for a `LEADER` within T', restarting the election if none arrives. A node receiving `ELECTION` answers and starts its own.

With three nodes this resolves in two message rounds. The name comes from a restarting node with the top UID proclaiming itself leader even when a healthy one exists.

**Bully alone does not prevent split brain**: in a partition each side happily elects its own local maximum. The quorum does — see below.

### Quorum

A coordinator serves requests only while it can see a majority of the coordinator cluster (two of three). A node in the minority suspends itself. This is why the cluster has three members and not two: with an even number a partition can split into halves that both consider themselves entitled to grant claims, and two authorities issuing claims breaks exactly the invariant the coordinator exists to protect.

### Why there is no replicated log

**The coordinator does not own the state; it is an index over it.** The original information — who holds which connector — lives in the stations, which own their connectors. The coordinator holds derived information: "vehicle 88 is committed somewhere". Derived data can be rebuilt from its sources, which is why no replication protocol is needed.

Rebuild protocol:

1. Newly elected leader enters `rebuilding` and announces the change to all stations. Claim requests are refused in this state.
2. It asks every station `who_do_you_hold`.
3. Each station walks its connectors and replies with those in `held` or `charging`: vehicle, connector, expiry. Data it already has in memory.
4. It switches to `serving` once every reachable station has answered, or a collection timeout fires.

Takes seconds. Reservations are refused during the window; charging sessions never notice, because they do not go through the coordinator.

**This works only because the coordinator was designed as an index.** If it held information derivable from nowhere else, a replicated log would be unavoidable. That is a design choice, not luck, and it should be stated as such.

### Edge cases of the rebuild

- *Claim granted, reservation not yet created, leader dies.* The station does not report it, the claim vanishes. Benign: the in-flight request fails and the driver retries.
- *Station unreachable during the rebuild.* Its claims are missing from the table, so in principle its vehicles could obtain a second claim elsewhere. In practice a vehicle plugged in there cannot be in another city, and the conflict is detected when the station returns and re-announces. There is nonetheless a window in which the invariant is not formally guaranteed — **declare it as an accepted limitation rather than hoping it goes unnoticed**.
- *Leader dies during the rebuild.* No special handling: a new election starts and the next leader begins again. The rebuild is idempotent because it always reads current station state.

---

## 4b. The no-show penalty, and why its concurrency is already handled

Repeated no-shows are penalised: N consecutive expired reservations suspend the account's right to reserve for K days, and turning up resets the counter. It closes a real abuse — without it, nothing stops a driver from reserving over and over and keeping outlets blocked fifteen minutes at a time.

Three decisions worth defending:

- **Enforced at claim time.** The coordinator already sits on the path of every reservation, and it is already the point that serialises decisions per vehicle. Refusing a claim for a suspended account therefore costs nothing extra: no new query, no new round trip. The alternative — the station querying MySQL on every reservation — would put a synchronous database call in the interactive path and couple the station to the database for an operation that has nothing to do with charging.
- **The counter is durable state, the check is not.** The counter and the suspension deadline live in MySQL with the rest of the account. The coordinator caches what it needs and reloads it; this does not break the "coordinator as an index" principle, because the authoritative copy is still elsewhere and the cache can be rebuilt like everything else it holds.
- **Suspension removes the privilege, not the service.** A suspended driver can still walk in and charge on a free connector.

**The interesting part is what is *not* a problem here.** A counter of consecutive no-shows is state written from several nodes: the vehicle can fail to show up at station A today and at station B tomorrow. Two concurrent increments would normally risk a lost update, exactly like the shared balance in [[dsmt-reference-project-blacknet]].

It cannot happen here, and the reason is P2: **an account holds at most one active reservation network-wide**, so at most one no-show event can be in flight for it at any time. The invariant we introduced for a different purpose serialises this one for free.

Two caveats to keep in mind, since they are what would break the argument:

1. It holds only while an account maps to a single concurrent reservation. If we ever allowed one account several vehicles reserving at once, the counter would become genuinely contended and would need an atomic increment.
2. The expiry of a lease (no-show) and a late arrival for the same reservation are concurrent events, but both are handled by the connector process that owns them, so they are serialised locally.

Worth stating plainly in the presentation: this feature adds domain credibility rather than a new class of distributed problem. Its contention is already covered by an invariant we have.

## 4c. Fault tolerance as a whole: what can fail, how it is noticed, what happens next

§4 covers the coordinator. This section covers the rest, because fault tolerance in this
system is not one mechanism but **five different ones, chosen per failure**, and the
interesting claim to defend is that each was picked for a specific reason rather than
applied uniformly.

The organising idea: **every component keeps only the state it owns, and every other
component treats that state as recoverable from its owner.** Tolerance follows from
ownership, not from replication.

### The failure model

We assume crash-stop and partition, not Byzantine behaviour. Concretely, five things can
fail, and each gets a different answer:

| What fails | How it is noticed | What happens | What is lost |
|---|---|---|---|
| a coordinator (crash) | `nodedown`, immediately | election; the new leader rebuilds from the stations | nothing; reservations refused for ~2 s |
| a coordinator (partition) | heartbeat, 3 s | the minority suspends itself | new reservations, on the minority side only |
| a station node (crash) | `monitor_node`, immediately | the coordinator drops that station's claims | sessions in progress there |
| a station's uplink (partition) | `monitor_node`, on the tick | the coordinator drops the station; **the site keeps charging**, but can start nothing new | the operator's view of it |
| a charge point | its socket closes; 30 s grace | session closed with the last measured energy; connector `out_of_service` | nothing measured |
| the back office (JVM) | nothing — it is a hidden node | the cluster is unaffected; on restart it re-reads and re-pushes | nothing durable |
| MySQL | connection errors | **not tolerated** — see §7 | writes, until it returns |

### Two failure detectors, because there are two failures

This is the design decision most worth defending, and it is documented at
`vs_coord_membership`.

Erlang gives us `net_kernel:monitor_nodes/1` for free, and it fires the instant a TCP
connection breaks — which is exactly what a killed container looks like. It is immediate
and costs nothing.

But **a node that stops answering without closing its socket is invisible to it**. A
network partition, a frozen VM, a host that is swapping: the connection is still open, so
no `nodedown` is delivered until the distribution's own tick expires, and `net_ticktime`
defaults to **60 seconds**. Sixty seconds of a minority leader still granting claims is
precisely the failure the quorum exists to prevent.

So liveness is decided by an **explicit heartbeat**: one announcement per second, three
missed in a row and a peer is treated as gone. Three seconds instead of sixty.
`monitor_nodes` is subscribed to as well, purely to react faster when it *does* fire — it
can only ever confirm what the heartbeat would conclude later.

Measured on 1 September, isolating the leader with `docker network disconnect`:

- `QUORUM LOST (1 of 3) … abdicating` at **2.12 s**
- a new leader serving with both claims at **2.29 s**
- the distribution's own `nodedown` only at **64.6 s**

That last number is the argument. Without the heartbeat the system would have been
incorrect for a minute, and no test would have shown it, because `docker kill` — the
obvious way to simulate a failure — closes the socket and therefore never exercises this
path. **Two kinds of failure need two experiments**, which is why the demo shows both
`kill` and `disconnect`.

### A site keeps working while the operator goes blind

The failure above is a station *dying*. The more interesting one — and the one with a
meaning outside this room — is a station that is **alive and unreachable**: the car park is
delivering power, and the operator cannot see it. `docker network disconnect
voltshare_voltshare station2` produces it, and unlike `kill` it has a plain real-world
reading: the site's uplink is down.

Measured on 3 September, with the station isolated:

- **the cars keep charging.** Energy climbing inside the isolated station across the
  partition: 0.248 → 0.403 → 0.558 kWh on one connector, 14.069 → 14.139 → 14.208 on
  another.
- **the coordinator drops it**: `** Node vs@station2 not responding **` followed by
  `node vs@station2 is down, dropping stations [2] and their claims`, and the leader down
  to one known station.
- **the lobby empties**, because the lobby is drawn from what the coordinator pushes.
- on reconnect, the station re-announced, the leader was back to two, and neither session
  was interrupted.

Two details make the story sharper rather than weaker.

**The published ports survive.** Port 9102 still answers `426 Upgrade Required` while the
station is isolated, so a driver physically at the site can still open its page and use it.
What is lost is the operator's view. That is the honest shape of this failure — everything
works except the party that needs to know — and it is exactly why reservations expire on
their own instead of depending on someone to cancel them.

**But no new session can start.** Authorising a car means resolving vehicle → owner, and
that is a MySQL query across the severed link. `vs_cp_proto` logs `no account for vehicle N`
and opens nothing; charges already running are untouched, because they never touch the
database. An isolated site therefore finishes what it started and accepts nobody new —
which is what a real site controller does with an unknown card and no uplink, and is worth
saying out loud rather than discovering on stage.

*A note on how this was established, because the method matters more than the result.* The
first attempt appeared to show the opposite: the isolated station reported `charging` while
the energy sat frozen at 34.523 kWh. That reading produced a whole redesign — a second
network per site, the emulators containerised onto it — on the theory that a published port
could not survive the disconnect. It could. The frozen number was a reconnect window
sampled three times in six seconds against a five-second meter tick. The redesign was
reverted the same day; **what survived is the measurement, taken slowly.**

### A station dies: the coordinator frees its vehicles

`vs_coord_srv` takes an `erlang:monitor_node/2` on each station it has heard from, and on
`nodedown` erases that station's claims.

Doing nothing here would be the intuitive choice and would be wrong. A claim is a promise
that a vehicle is committed *somewhere*; if the somewhere no longer exists, the promise
locks the driver out of the entire network until the lease expires — up to fifteen minutes
of being unable to reserve anywhere because of a failure they did not cause. Dropping the
claims converts a station failure into a local one.

The cost is stated rather than hidden: charging sessions on that station are lost, since
the process that was metering them is gone. That is a partial failure, and §7 declares it.

Note the asymmetry with the rebuild. Claims are recovered by **asking**, because the
stations hold them; suspensions are recovered by **pushing**, because nobody in the cluster
holds them — they live in MySQL, and the back office repeats them on every leader
announcement. State is recovered from whoever owns it, in whichever direction that is.

### A charge point dies: grace, then honesty

The connector does not react to a lost socket immediately. A `DOWN` arms a 30 s grace
timer, because a socket blip is not a broken charger and a car that is charging perfectly
well should not be stopped by our own reconnection.

If the grace expires mid-session, the session is closed **with the last measured energy**
rather than discarded: the charge point is the only side that counted it, so its last
report is the best available truth. The connector then becomes `out_of_service`, not
`free` — an outlet with no hardware attached is not an outlet a driver can be offered, and
saying otherwise would send someone to a socket that cannot work.

It recovers by itself: a charge point that boots reporting `available` lifts the connector
back to `free`. No operator action, no restart.

### Supervision inside a node: three strategies, three reasons

OTP supervision is not decoration here; each strategy encodes a claim about dependencies.

- **`vs_coord_sup` — `rest_for_one`.** The children are in dependency order, so restarting
  one restarts everything downstream of it. When the claim table dies, everything derived
  from it must die too; a survivor holding references into a table that has been recreated
  is worse than a clean restart.
- **`vs_station_sup` — `one_for_one`.** The children are genuinely independent: the manager
  crashing must not take down connectors that are delivering power to real cars.
- **`vs_connector_sup` — `simple_one_for_one`, `restart => transient`.** Every child is the
  same kind of process, one per connector, and a connector that terminates normally stays
  terminated.

Two bugs found in review (PROGRESS §7zk) show that this only works if the code cooperates,
and both were failures of supervision rather than of logic:

1. `vs_coord_rebuild:run/1` used `spawn_link` while `vs_coord_srv` does not trap exits, so
   **any** exception in the rebuild worker — a malformed reply from any station — would
   have killed the process holding every claim in the network, and `rest_for_one` would
   have taken the whole subtree with it. Now `spawn_monitor`.
2. The `rebuilding` state had no exit other than the success message. A worker that died
   before sending it left the coordinator refusing every reservation in the network,
   forever, silently. Now a `DOWN` handler and a deadline, both of which fall through to
   `serving` with a warning — because renewals re-present the missing claims within ten
   seconds, and staying stuck is strictly worse.

The general lesson, worth stating in the presentation: **a supervision tree protects you
from the failures you routed through it.** A linked process and a state with no timeout are
both ways of routing a failure around the tree.

### Three delivery guarantees on one wire, on purpose

The coordinator→Java bridge carries three kinds of event, and they do **not** get the same
guarantee, because the cost of a duplicate differs:

- **The session row → at-least-once, over an idempotent write.** `BillingService` prices
  with `UPDATE sessions SET cost_cents = ? WHERE id = ? AND cost_cents IS NULL`. A repeat
  updates zero rows and is not an error: that is the idempotence working. At-least-once
  over an idempotent write is the standard way to obtain effectively-once, and it is why
  billing is also driven by a periodic sweep — the event only makes the sweep run sooner,
  so a lost message costs promptness, never money.
- **The no-show strike → at-most-once.** A counter cannot recognise a duplicate, so a
  doubled strike would suspend an innocent driver. One send, no retry: a lost strike is a
  smaller wrong than an invented one.
- **The notification → at-most-once.** A duplicate is a row a person reads twice; a loss is
  a row they never see. Neither is good, and we chose the quieter failure.

Choosing the guarantee per message rather than per channel is the point. A single "reliable
messaging" layer would have forced one answer onto three questions with different answers.

### What tolerates nothing, and is declared

- **MySQL is a single point of failure** for durable data. Replicating it was out of reach
  here; the honest position is to choose which single points to keep and know what happens
  when they fail. Note what does *not* depend on it: charging continues, power sharing
  continues, and the coordinator keeps granting claims, because none of them reads the
  database on the interactive path.
- **Sessions on a dead station are lost.** The process that was metering them is gone.
- **P18**: a coordinator that rejoins elects itself before the stations have reconnected,
  rebuilds from zero stations, and serves with an empty table for up to one renewal cycle.
  The defect is the ratio between two numbers: the rebuild window is 2 000 ms and the renew
  cycle is 10 000 ms, so the leader starts granting long before the claims come back. In
  the measured run a vehicle obtained a **second** reservation on another station 272 ms
  after the new leader began serving, and P2 stayed broken for **13.65 s** until the first
  renewal re-presented the older claim. Measured 1 September, written up in PROGRESS §7zj.
  Not fixed; mitigated in the demo by a ten-second pause after any coordinator rejoins. It
  is a real hole in P2 and is declared as one.

---

## 5. Rejected alternatives, with the reasons

Ready to be reused in the design-decisions section. Every one of these was considered and set aside deliberately.

| Alternative | Why not |
|---|---|
| Uniqueness via a `UNIQUE` database constraint | Would work and cost almost nothing, but: the coordinator must exist anyway for cluster mapping and monitoring; a claim that expires on its own is a timer in a process, while in the database it becomes a cleanup job or a filter on every read, i.e. polling — which this architecture avoids everywhere else; and it moves the single point of failure onto the database rather than removing it |
| Ricart-Agrawala between stations | No central authority, but `2(n-1)` messages per reservation, delicate handling of dead nodes, and it serialises access to *one* critical section while here each vehicle is an independent one |
| Token ring | The token would grant the right to issue one reservation at a time network-wide, serialising reservations of vehicles that do not conflict at all |
| Partitioning the vehicle space (`hash(vehicle)`) | Technically the cleanest and the natural direction for growth, but every node must agree on the same partition map, the map must be rebalanced on membership change, and each shard still needs its own failover — it *composes with* the chosen design rather than replacing it. Kept as future work |
| Session wallet / pre-authorised credit | Would remove the billing contention we do not want anyway; not applicable, since billing here is settled after the fact by design |
| Single-page app replaced by JSP | Server-side rendering cannot push state; the live session view would require polling |

---

## 6. Assumptions we are making

To be declared explicitly in the document — an unstated assumption is a question at the exam.

- **Synchronous system.** Failure detection uses timeouts, which are only legitimate under an assumed upper bound on response times. Without it, a slow node is indistinguishable from a dead one — which is precisely where split brain comes from.

  **Safety does not depend on this assumption; liveness does.** The timeout can be wrong: a garbage-collection pause, a frozen container or a saturated link can make a healthy leader look dead, and a second one gets elected. What keeps the system correct in that case is not the timeout but the quorum — the old leader, finding itself in the minority, stops serving, so two authorities never grant claims at the same time. Tuning the timeout badly costs an unnecessary failover, or a slow one; it never costs a double reservation. This separation should be stated explicitly: *we assume synchrony in order to detect failures, but we do not rely on it being right in order to stay correct.*

  In practice the assumption is made concrete by choosing numbers — heartbeat every second, leader declared dead after three missed ones — and by a deployment where those numbers are generously conservative: containers on a local network, where latency is measured in milliseconds. On a geographic network with mobile links the same assumption would be far more fragile, and that is worth acknowledging rather than glossing over.
- **Crash / fail-stop processes.** No byzantine behaviour: a node stops, it does not lie.
- **Reliable, ordered delivery between nodes**, as provided by the underlying transports.
- **Unique, known node identifiers** for the coordinators — leader election is provably unsolvable in an anonymous system with a regular topology.
- **A vehicle belongs to exactly one account** and cannot be charging in two places at once physically.

---

## 7. Known limits, accepted on purpose

- P1 and P5 are solved by the actor model and by a single owning process: elegant, but **local** — they do not demonstrate distribution, and we should say so rather than oversell them.
- MySQL is a single point of failure for durable data.
- The rebuild window described in §4. **§4c is the full account**: what can fail, how each
  failure is detected, what happens next, and the three things that tolerate nothing.
- Billing is deliberately not contended, to avoid duplicating the connector-contention problem on a second object.
- **The overstay notice only reaches a driver who is looking.** Charging completes, the driver is notified, and five minutes later the charge starts — but our notifications are pushed over the WebSocket and stored for later retrieval, with no native mobile push. A driver having lunch with the browser closed learns about it when they reopen the application. The grace period therefore assumes an attentive user, which a real deployment would fix with a mobile push notification, out of scope here. Worth stating: it is a limitation of the client channel, not of the coordination logic.
- Site power is coordinated within a station only; sharing a budget across stations is future work.
- The charging curve is approximated; this is not an electrical simulation.

---

## 8. Mapping to the course material

Useful for the oral exam, and for showing the material is actually being used.

| Course topic | Where it appears |
|---|---|
| Actor model, mailbox serialisation (02) | Connector process; P1 solved with no locks |
| OTP behaviours, supervision, "let it crash" (02) | `gen_statem` per connector, `gen_server` for station manager and coordinator, supervision tree |
| Distributed Erlang, EPMD, cookies, monitors (02) | Station ↔ coordinator cluster |
| Resource paired with a manager process (01) | The connector process as the guardian of a physical outlet |
| Semaphore / permits vs mutual exclusion (04) | Power allocation as a divisible resource, against exclusive connector access |
| Request/reply, request identifiers, at-most-once (06) | P7: retried commands filtered by request id |
| Leasing (06, distributed GC) | Reservation lease and claim expiry — the same mechanism as `dirty()` with a renewable lease |
| Distributed mutual exclusion, centralised arbiter (08) | The coordinator granting claims |
| Leader election, bully (08) | Coordinator failover |
| Quorum (08) | Split-brain protection |
| Failure models, synchronous model, timeouts (08) | §6 above |
| Servlets, JWT, three-tier, MVC (07) | Back office |
| JInterface (lab 05) | Back office as a hidden Erlang node |

**Not covered, and worth knowing it**: logical clocks (Lamport, vector timestamps — PDF 05) have no natural use here, because the coordinator serialises the decisions that matter and no causal ordering across independent events needs reconstructing. They would only appear if we adopted Ricart-Agrawala, which we rejected. Better to leave them out than to force them in; if asked, this is the answer.

---

## 9. Minor decisions still open

- Project name (`VoltShare` is a placeholder).
- Language for the charge-point emulator: Erlang reuses the JSON codec and message definitions and adds no toolchain; Python would be quicker to write but is a third language in the build.
- Power allocation policy: fair share, proportional to demand, or reservation-holders first; plus the minimum viable power below which a session is suspended rather than starved.
- Real parameters: lease duration, site budget, connector ratings, tariffs, grace period before overstay.
- Whether the waiting list (§3.3) stays in scope.
- Number of stations to deploy for the demonstration (two is enough to show cross-node claims; three looks better).

---

## 10. Demonstration plan

What has to be visible on screen, since a working deployment across nodes has to be shown:

1. **Contention**: the load generator drives many emulated drivers at one station; reservations are granted to one and refused to the others.
2. **Cross-node claim**: the same vehicle tries to reserve at two stations at once; the second is refused. This is P2, the core of the project.
3. **No-show**: a reservation is left unused; the lease expires and the connector returns to `free` by itself.
4. **Power sharing**: a second vehicle plugs in and the first one's allocation drops in real time, visible in the browser.
5. **Coordinator failover**: kill the leader container; the election runs, the claim table is rebuilt, reservations resume. Charging sessions keep running throughout — this is the most convincing single moment of the demonstration.
6. **Station crash**: kill a station; its reservations decay, drivers are freed to reserve elsewhere, the back office drops it from the list.

---

## 11. Benchmark

[BlackNet](https://github.com/effemuraca/dsmt-blacknet), a 30-cum-laude project from this course, for calibration: ~8,200 lines in total, of which only ~1,300 Erlang and ~1,400 Java — the rest is frontend. Its contention (a shared balance written by both Erlang and Java) was preserved deliberately, giving up a more efficient design in order to have a distributed concurrency problem to solve. Its documentation states, for every technical choice, the alternative that was discarded and why. That is the format to follow.
