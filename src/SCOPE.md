# VoltShare - Functional Scope

*Distributed Systems and Middleware Technologies - project proposal, A.Y. 2025/26*

## 1. Overview

VoltShare is a distributed coordination system for a network of electric-vehicle charging stations.

Charging points are physically exclusive resources: one connector serves one vehicle for a long and only partially predictable amount of time. Contention is intrinsic to the domain, since drivers are **autonomous agents**: the operator cannot assign a driver to a station, it can only arbitrate the requests drivers make.

The system coordinates three things: which vehicle gets which connector, how the limited electrical capacity of a site is shared among the vehicles currently charging, and what happens to both when a node fails.

The service is open to anyone driving an electric vehicle. Users hold an account, as they do with every charging application, because a session has to be attributed to someone and billed — so drivers are identified even though the network is public.

**On reservations.** Most public networks do not offer them today, and the reason is economic rather than technical: an outlet held for someone who has not arrived yet earns nothing, which lowers the utilisation of an already scarce resource. That objection is exactly what two mechanisms in this system answer. A reservation is a **short lease** (§3.3), so the idle window is bounded and closes itself rather than staying open indefinitely; and **repeated abuse suspends the privilege** (§3.3), so no one can hoard outlets at zero cost. Reserving is treated here as a feature that has to earn its keep.

## 2. Actors

| Actor | Description |
|---|---|
| **Driver** | Registered user with one associated vehicle profile. Searches for stations, reserves a connector, charges, is billed. |
| **Charging station** | A physical site with N connectors and a maximum site power. Modelled as one node of the distributed system. |
| **Connector** | A single physical outlet. The exclusive resource of the system. |
| **Charging point (EVSE)** | The equipment itself. It is a *peer of the system*, not a user of it: it reports its own status (cable plugged, charging, fault), reports meter readings, and obeys commands such as "limit this connector to 30 kW". It communicates over its own channel, distinct from the driver's. |
| **Operator (back office)** | Read-only in the initial scope: station registry, session history, billing records. |

Note that **driver and charging point are two separate parties** reaching the system through two different channels. The driver reserves a connector from an app, over the internet; the charging point independently reports that a cable has been plugged in. Correlating the two — establishing that the vehicle now physically connected is the one holding the reservation — is part of the system's job, and is described in §3.4.

## 3. Functional requirements

### 3.1 Account and vehicle

- Register and log in; session persisted through JWT access/refresh tokens.
- Vehicle profile: battery capacity (kWh) and maximum accepted charging power (kW). Both feed the power-allocation logic.
- View and edit profile; delete account.

### 3.2 Station discovery

- List stations with, for each: number of connectors, how many are free / reserved / charging, connector power rating, site power, current tariff.
- Availability figures reflect the live state of the cluster.
- Filter by connector power and availability.

### 3.3 Reservation

- A driver reserves a **specific connector** at a station.
- A reservation is granted with a **lease**: the driver has a fixed window (e.g. 15 minutes) to plug in. When the window expires the connector is automatically released - no operator action, no client cooperation required.
- The driver may cancel early, releasing the connector immediately.
- **A vehicle holds at most one active reservation across the entire network.** This must hold even when the driver issues concurrent requests to two different stations.

> **Reservation and claim.** These name the two halves of the same act, and the distinction matters throughout this document. A **reservation** is what the driver sees: connector 3 at this station, held for me until 18:07, recorded by the process that owns that connector. A **claim** is the permission that made it possible: an entry at the coordinator stating that *this vehicle* is now committed, and to which station. The reservation is local and is about a connector; the claim is network-wide and is about a vehicle. A station must obtain the claim **before** committing a reservation — never the other way round — so that a failure in between leaves an unused claim, which expires, rather than a reservation nobody knows about. Claims carry an expiry of their own, so that a station dying without releasing one does not lock a vehicle out of the network permanently.
- If every connector at a station is busy, the driver may join a **waiting list** for that station and is notified when a connector frees up; the notification itself carries a short lease, after which the offer passes to the next in line.
- **Repeated no-shows are penalised.** After **N** consecutive expired reservations (default N = 2) the account loses the right to reserve for **K** days (default K = 1). Turning up resets the counter. Both parameters are configuration, not constants in the code.
  - The penalty suspends **reserving**, not charging: a suspended driver can still walk in and plug into a free connector. Losing the privilege is proportionate; being left stranded with an empty battery is not.
  - It applies to the **account**, not to the vehicle, so that it cannot be avoided by registering a second vehicle.
  - It is enforced at claim time: the coordinator refuses the claim for a suspended account, which places the check on a path the reservation already takes rather than adding one.

### 3.4 Charging session

- The charging point reports that a cable has been plugged in. The system authorises the session by matching the connector against its current reservation: the holder of the lease starts charging, anyone else is refused. On a free connector, a walk-in session is authorised against the driver's account.
- Session starts once authorised.
- Live session state pushed to the client: power currently delivered (kW), energy delivered (kWh), estimated state of charge, estimated completion time.
- The driver stops the session explicitly, or it terminates when the target charge is reached.
- **Overstay**: a vehicle still connected after the session ends occupies the resource without using it. When charging completes, the driver is notified; if the vehicle is not unplugged within a **grace period of 5 minutes**, the connector is flagged as overstaying and a per-minute charge accrues until it is freed. Unplugging inside the grace period costs nothing.
  - This is the one charge in the system, and it is deliberate: unlike a missed reservation, an overstay cannot be resolved by the software. No timer moves a parked car, so the system can only notice, notify, and make waiting expensive. A suspension served days later would not free the connector now.

### 3.5 Power allocation

- Each station has a **maximum site power** lower than the sum of its connectors' nominal ratings.
- Power is distributed dynamically among active sessions and recomputed on every arrival, every departure, and on a periodic tick that accounts for the vehicle's charging curve (absorption drops as the battery fills).
- Each session is told its current allocation, and the client sees it change in real time.
- Allocation policy is an explicit design decision (fair share / proportional to demand / reservation-holders first), including a minimum viable power below which a session is suspended rather than starved.

### 3.6 Billing and history

- Cost computed at the end of a session from energy delivered and tariff, plus any overstay charge.
- **A missed reservation costs no money.** It is answered by the suspension described in §3.3, not by a fee: the abuse being prevented is the hoarding of a scarce physical resource, and denying the privilege addresses it directly, while a charge would merely price it — leaving a driver willing to pay free to keep doing it.
- Per-user session history and receipts.
- Billing is settled after the fact: it is deliberately **not** a contended resource, to avoid duplicating the connector-contention problem on a second object.

### 3.7 Notifications

- Reservation expiring soon; reservation expired.
- Connector freed (waiting list offer).
- Charging complete; session interrupted by a station failure.

## 4. Non-functional requirements

- **Exclusive use**: a connector serves at most one session at a time; a vehicle holds at most one reservation network-wide. Neither invariant may be broken by concurrent requests, by node failures, or by network partitions.
- **No resource is lost to a failure**: a crashed station must not leave connectors reserved forever, nor drivers holding phantom reservations that block them elsewhere.
- **Station autonomy**: a station keeps serving the vehicles already plugged in even when the rest of the network is unreachable.
- **Real time**: state changes reach connected clients by server push, without polling.
- **Horizontal growth**: adding a station means adding a node, with no change to the existing ones.

## 5. Synchronization, coordination and communication problems

This section states the problems the project sets out to solve; it is the core of the proposal.

| # | Problem | Where it arises | Intended solution |
|---|---|---|---|
| **P1** | Several drivers request the same connector simultaneously | Within one station | The connector is owned by a single Erlang process; concurrent requests are serialised by its mailbox - actor model, no locks |
| **P2** | The same vehicle attempts to hold reservations at two different stations at once | **Across nodes** | A claim granted by the coordinator before any station commits a reservation; see §9 |
| **P2b** | The coordinator itself fails, or a partition leaves two of them believing they are in charge | **Across nodes** | Leader election among replicated coordinators, with a majority quorum required to serve — a second authority would break the very invariant P2 protects |
| **P3** | A driver reserves and never shows up, or disappears mid-session | Between client and station | **Leasing**: reservations are granted with an expiry that decays automatically; the resource is never held hostage by an unreachable party |
| **P4** | A station node crashes, or is partitioned from the rest of the network | Across nodes | Node monitoring detects the failure; the coordinator drops that station's claims at once, so drivers are freed to reserve elsewhere instead of waiting out their lease. Sessions in progress on the dead node are **lost** — the process metering them is gone and no row is written. Energy is not lost on a *restart*, because the charge point is the side that counts it and brings its total back in the `plugged` it re-sends on reconnect; that is recovery of the measurement, not of the session |
| **P5** | Active sessions jointly exceed the site's electrical capacity | Within one station | A divisible resource allocated by quota, renegotiated on every event - a permit/semaphore problem rather than mutual exclusion |
| **P6** | Clients must all see a consistent view of a connector's state despite concurrent updates | Between station and clients | The server holds the single source of truth and pushes complete state; clients never compute state locally |
| **P7** | A command is retried after a timeout and risks being applied twice (double reservation, double session start) | Client to station | At-most-once semantics: commands carry a request identifier, duplicates are filtered instead of re-executed |

Communication problems addressed: heterogeneous components in different languages and runtimes (Java and Erlang) that must exchange structured data; long-lived low-latency connections towards many clients; asynchronous propagation of state between nodes without polling.

**On failure detection**, one point belongs here rather than only in the design notes, because it shapes what P2b and P4 can promise. Erlang's own `nodedown` fires when a TCP connection breaks — a crashed container — but a node that stops answering *without* closing its socket (a partition, a frozen host) is invisible to it until `net_ticktime` expires, which is sixty seconds by default. Sixty seconds of a minority leader still granting claims would defeat the quorum entirely. Liveness is therefore decided by an explicit heartbeat, one per second with three misses tolerated: three seconds to detect a partition instead of sixty. Both detectors are used, because they detect different failures — and both are demonstrated, `docker kill` for the crash and `docker network disconnect` for the partition. DESIGN-NOTES §4c gives the full account with the measurements.

## 6. Architecture

Deployment is one process per node; nodes are separate containers and are demonstrated on more than one host.

| Node | Technology | Responsibility |
|---|---|---|
| **Back office and web front end** | Java / Tomcat (servlets + JSP) + MySQL | Registration, authentication, station directory, session history, billing; renders every page server-side and hands the browser a JWT for the station WebSocket |
| **Coordinator ×3** | Erlang/OTP | Cluster map, node monitoring, network-wide reservation claims. One leader serves, two stand by; election and quorum per §9. Feeds the back office with live station state |
| **Station controller 1..N** | Erlang/OTP + Cowboy | One process per connector (`gen_statem`), a station manager arbitrating connectors and allocating power, WebSocket endpoints for drivers and for charging points |

The browser is not a node of the system: pages are rendered by the back office and the browser holds no application state of its own, apart from the two live views (§7) which are driven entirely by their WebSocket. The delivered deployment is therefore **seven nodes**: three coordinators, two station controllers, Tomcat, MySQL.

**Why server-side rendering.** The pages that list stations, sessions and notifications are read-mostly and non-interactive; rendering them in a servlet costs less code than shipping a client-side application to draw them, and it keeps the project on the basic Java web technologies the course recommends. Real time is kept where it is actually needed — the driver WebSocket — instead of spreading across the whole front end.

This split mirrors a real deployment. Dynamic load management is normally performed by a **site controller physically located at the station**, because it must react quickly and must keep working when the connection to the operator's cloud is down; registry and back office are central services. Our station node is that site controller, which is why §4 requires a station to keep serving plugged-in vehicles while isolated.

Protocols:

- **HTTP** - browser ↔ back office: form POSTs and server-rendered pages (servlet → forward → JSP), with the login session in `HttpSession`.
- **WebSocket** - browser ↔ station, for reservations, session commands and live state push. The browser authenticates with a JWT minted by the back office and verified locally by the station.
- **WebSocket/JSON** - charging point ↔ station, for status reports, meter readings and power-limit commands. Message set modelled on OCPP (§7).
- **Distributed Erlang** - station ↔ coordinator: node monitoring and coordination.
- **JInterface** - back office ↔ coordinator: Java participates in the Erlang cluster as a hidden node to receive live station state.
- **SQL** - back office (JDBC) and stations (`mysql-otp`) towards MySQL for durable data.

State is split deliberately: **volatile coordination state** (who holds which connector, current power allocation, session progress) lives in Erlang memory, where it is cheap to update at high frequency; **durable state** (users, vehicles, completed sessions, billing) lives in MySQL.

## 7. System boundary: what is built and what is emulated

The system under development is the **coordination backend and its client applications** — in industry terms, a charging-station management system together with the site controllers. This is software in the real world too: it is not a model of something else.

What cannot be present in a university project is the **hardware**: the physical outlet, its contactor, its energy meter and the vehicle attached to it. That part is replaced by an emulator.

| Component | Status | Notes |
|---|---|---|
| Reservation, leases, network-wide uniqueness | **Real** | The logic ships as-is |
| Power allocation among active sessions | **Real** | Issues the same limit commands a real controller issues |
| Failure detection, recovery, reconciliation | **Real** | |
| Driver web application, back office, billing | **Real** | |
| Charging-point emulator | **Emulated** | Stands in for the hardware: reports plug/unplug, produces meter readings, honours power limits |
| Vehicle battery behaviour | **Emulated** | State of charge advances from the allocated power; charging curve approximated |
| Load generator | **Test tool** | Drives many emulated charging points and synthetic drivers concurrently, to exercise contention during the demonstration |

The boundary is placed where a real interface already exists. Charging points talk to management systems over **OCPP**, an open protocol carried over WebSocket with JSON payloads, whose message set already includes the operations this project needs: status notifications, meter values, reservation with an expiry date, and charging profiles that cap the power of a connector. Our charging-point channel implements a **reduced message set modelled on OCPP 1.6-J**, not the full specification.

The consequence worth stating: replacing the emulator with real equipment would mean replacing a client that speaks that protocol, not rewriting the system. Everything on the coordination side — which is the entire subject of this project — is production logic.

## 8. Out of scope

Stated explicitly so the boundary is not ambiguous:

- Real payment processing; billing produces records, not transactions with a provider.
- Maps, routing and travel-time estimation.
- Detailed electrical modelling: the charging curve is approximated, not simulated.
- Native mobile application; the driver client is a web application.
- Full OCPP compliance: only the subset of messages the system needs is implemented, and no certification is attempted.
- RFID and plug-and-charge (ISO 15118) authentication: sessions are authorised through the driver's account and the connector's reservation.

## 9. Design decision: how P2 is enforced

The guarantee that one vehicle holds at most one reservation across the whole network is the decision that shapes the rest of the architecture. Four approaches were considered.

**Chosen: a replicated coordinator with leader election.**

Three coordinator nodes form a small cluster. One of them is the leader and is the only node that grants or refuses claims; the other two stand by. Stations always address the leader, and a node that is no longer leader answers with a redirect instead of serving the request.

- **Election.** When the leader stops responding, the survivors elect a new one with the **bully algorithm** over their fixed node identifiers. Failure is detected by timeout, which means the system is assumed to be **synchronous** — an upper bound on response time exists. This assumption is stated explicitly because the correctness of the detection depends on it.
- **Quorum against split brain.** A network partition can leave two coordinators each believing itself the leader; with two authorities granting claims, the invariant this whole mechanism exists to protect would be the first thing to break. A coordinator therefore serves requests only while it can see a **majority of the coordinator cluster** (two out of three). A node in the minority suspends itself and refuses to answer.
- **State after a failover.** The new leader does not inherit a replicated log. It **rebuilds the claim table by asking the stations**, which are the authoritative owners of their own connectors, and only starts serving once they have answered. Reconstruction takes seconds, during which new reservations are refused while charging sessions continue untouched. This trades a short unavailability for the absence of a replication protocol — a deliberate simplification.

**Why not the alternatives**

- *Single coordinator.* Simplest, and the failure is only partial: sessions in progress survive, since the coordinator sits outside the critical path. Rejected because it leaves an avoidable single point of failure on the one guarantee the system is built around.
- *Uniqueness enforced by a database constraint.* A `UNIQUE` constraint on the vehicle would work and costs almost nothing. Rejected for two reasons: the coordinator has to exist anyway for cluster mapping and node monitoring, and a claim that **expires on its own** is a timer in a process, whereas in the database it becomes either a cleanup job or a filter on every read — that is, polling, which this architecture avoids everywhere else. Note also that it would not remove a single point of failure, only move it onto the database.
- *Direct coordination between stations (Ricart-Agrawala).* No central authority by construction, but `2(n-1)` messages per reservation, delicate handling of dead nodes, and — decisively — the algorithm serialises access to **one** critical section, while here every vehicle is an independent one: two reservations for two different vehicles have no reason to wait for each other.
- *Partitioning the vehicle space across nodes.* Technically the cleanest: the node responsible for `hash(vehicle)` decides, no node sees all traffic, and a failure only blocks one shard. Rejected for now because every node must agree on the same partition map, the map must be rebalanced when membership changes, and each shard still needs its own failover — that is, this option *adds to* the chosen one rather than replacing it. Recorded as future work in §10.

**What this costs.** Three additional nodes in the deployment, plus the election and quorum logic. In exchange, the failure of any single coordinator is survivable and demonstrable: killing the leader during the presentation shows the election, and reservations resume by themselves.

## 10. Possible extensions

Declared as future work, not part of the delivered scope:

- **Site power shared across stations** on the same grid connection: a divisible budget coordinated between nodes, with borrowing and return - a lease over a continuous quantity rather than over an exclusive resource.
- Operator dashboard with the ability to take connectors out of service.
- Dynamic pricing driven by demand.
- Predictive suggestion of the station most likely to be free on arrival.
