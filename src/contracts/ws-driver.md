# Contract — Driver channel (browser ↔ station)

**Status: owned by A.** Both ends are implemented by A — the `vs_driver_ws` handler on the station and the JavaScript of the live views — so this file changes without a PR. It is written down because it is the interface the emulated drivers of the load generator also speak, and because the report needs it.

The channel carries everything the driver does at a station: reserve, cancel, stop, join the waiting list, and watch state change. It is a WebSocket rather than HTTP because P6 requires the station to *push* — a page that polled would show a power allocation that is already wrong.

---

## 1. Who talks to whom

```
ws://<station-host>:8080/ws/driver?station_id=<id>
```

The URL is not built by the browser: it comes from `stations.ws_url` in the database, is rendered into the page by `StationPageServlet`, and reaches the JavaScript as the constant `WS_URL` (jwt.md §2). A station never assumes it knows its own public address.

**The query string is the client's half.** `stations.ws_url` is what the station announced about itself — `ws://host:9101/ws/driver` — and carries no query string, while the handler closes `4400` when `station_id` is missing from it, and again when it names a station this node does not serve. `js/ws.js` appends `?station_id=` from the `STATION` constant already on the page. The split is deliberate: the station publishes an address, the page says which station it believes it is talking to, and a page pointed at the wrong one is a bug that shows itself instead of being quietly absorbed.

One connection per open page. A driver with two tabs has two connections and receives every push twice, which is harmless: pushes are complete snapshots (§7.1).

Frames are **text**, one JSON object per frame. Binary frames are rejected with close code `4400`.

---

## 2. Envelope

Every frame in both directions carries a type, an optional correlation identifier and a payload. Nothing is ever sent as a bare string.

```jsonc
// browser → station
{ "action": "reserve", "request_id": "3f2c…", "payload": { } }

// station → browser
{ "type": "ack", "request_id": "3f2c…", "payload": { } }
```

| Field | Direction | Rule |
|---|---|---|
| `action` | → station | one of §4; unknown actions answer `BAD_REQUEST` |
| `request_id` | → station | UUID v4, `crypto.randomUUID()`. Mandatory on every action |
| `type` | → browser | `ack` \| `error` \| `state` \| `session` \| `notification` |
| `request_id` | → browser | echoed on `ack` and `error`; **`null`** on server-initiated frames |
| `payload` | both | object; `{}` when there is nothing to say, never absent |

`request_id` is what makes the channel safe to retry (P7). The station keeps, per connection, the last `REQUEST_CACHE_SIZE` identifiers with the reply it produced: a repeated identifier is answered with **the stored reply**, and the command is not executed a second time. A reservation that times out on a flaky link can therefore be retried by the client without any risk of double-booking, which is the whole point of at-most-once semantics.

---

## 3. Handshake

The socket opens unauthenticated and is useless until the first frame:

```json
{ "action": "join", "request_id": "…", "payload": { "token": "eyJhbGciOi…" } }
```

1. The station verifies the JWT locally, per jwt.md §3 — no call to Tomcat.
2. It binds `user_id` and `vehicle_id` from the token to the connection. **The client never sends its own identity**: a driver cannot reserve on behalf of someone else by editing a payload.
3. It replies `ack` and immediately pushes a first `state` (§5.1), so the page can render without asking.

| Close code | Cause |
|---|---|
| `4400` | binary frame, malformed JSON, or `station_id` missing from the query string |
| `4401` | invalid token, wrong issuer, or no `join` within `JOIN_TIMEOUT_MS` (5 s) |
| `4408` | token expired |
| `1001` | station shutting down — the client reconnects with backoff |

Any action other than `join` before authentication is answered `error / UNAUTHENTICATED` and the socket is closed with `4401`.

---

## 4. Actions

### 4.1 `reserve`

```jsonc
{ "action": "reserve", "request_id": "…",
  "payload": { "connector_id": 3 } }
```

The station: checks the connector is `free`, asks the coordinator for the claim (claim.md §3.1), and only on `{ok, …}` moves the connector to `held` and arms the lease. Claim first, commit after — a reservation is never granted on the station's own authority.

```jsonc
{ "type": "ack", "request_id": "…",
  "payload": { "connector_id": 3, "expires_at": 1755792000000, "lease_seconds": 900 } }
```

`expires_at` is epoch milliseconds, the same unit the claim contract uses. The client displays a countdown from it and never computes the deadline itself.

Refusals — the mapping from the coordinator's answer to what the driver sees:

| Coordinator replied | Driver receives | Meaning shown |
|---|---|---|
| — (connector not `free` locally) | `ALREADY_HELD` | someone else got this connector first |
| `{error, _, already_held}` | `NO_CLAIM` | your vehicle already holds a reservation elsewhere |
| `{error, _, suspended}` | `SUSPENDED` | the account is serving a no-show penalty; walk-in charging still works |
| `{error, _, rebuilding}` | `RETRY_LATER` | a new leader is rebuilding; try again in a few seconds |
| unreachable, timeout, no leader | `NO_CLAIM` | reservations are unavailable right now |

The last row is the deliberate one: with no coordinator the station refuses **new reservations** and keeps everything already running (claim.md §4). Availability is sacrificed exactly where safety demands it and nowhere else.

### 4.2 `cancel_reservation`

```jsonc
{ "action": "cancel_reservation", "request_id": "…",
  "payload": { "connector_id": 3 } }
```

Frees the connector immediately and releases the claim. Cancelling a reservation held by someone else is `NOT_YOURS`; cancelling a connector that is not `held` is `INVALID_STATE`. A no-show costs a penalty, an explicit cancellation does not — which is the incentive the rule is meant to create.

### 4.3 `stop_session`

```jsonc
{ "action": "stop_session", "request_id": "…",
  "payload": { "connector_id": 3 } }
```

Stops charging on a connector the caller owns. The session then closes on its own: the station tells the charge point to stop, writes the session row, releases the claim and returns the power to the pool. `INVALID_STATE` if the connector is not `charging`, `NOT_YOURS` if the session belongs to another account.

Stopping does **not** end the overstay clock: the cable is still in the car. The grace period starts when charging ends, however it ended (§5.2).

### 4.4 `join_waitlist` / `leave_waitlist`

```jsonc
{ "action": "join_waitlist", "request_id": "…", "payload": {} }
```

The waiting list is per **station**, not per connector: a driver waiting for "a connector here" is what the domain actually means. Joining twice is idempotent and returns the current position; joining when a connector is free is `INVALID_STATE`.

```jsonc
{ "type": "ack", "request_id": "…", "payload": { "position": 2 } }
```

When a connector frees up, the head of the list receives a `notification` of kind `waitlist_offer` carrying `connector_id` and `offer_expires_at`. The offer is accepted by sending a normal `reserve` for that connector before the deadline; ignoring it passes the offer to the next in line. A `reserve` for a connector under offer to somebody else is `NOT_YOUR_TURN`.

The offer is a lease like every other hold in this system: the same mechanism that stops a no-show from freezing a connector stops an absent waiter from freezing the queue.

> **Not implemented in M1.** The waiting list needs a per-station queue that no process owns yet. Until it exists, `join_waitlist` and `leave_waitlist` fall into the unknown-action branch and are answered `BAD_REQUEST`, and `waitlist` in the `state` payload is the constant of §5.1's note. The station says "I do not know how to do that" rather than pretending to queue somebody it will never call back. Arrives with the power allocation work.

---

## 5. Server-initiated frames

`request_id` is `null` on all of them.

### 5.1 `state` — the station snapshot

Sent on join, on every change, and on a `STATE_TICK_MS` heartbeat. It is a **complete** snapshot: the client replaces its whole view of the station with it.

```json
{
  "type": "state",
  "request_id": null,
  "payload": {
    "station_id": 1,
    "name": "Pisa Centro",
    "site_power_kw": 350,
    "allocated_kw": 210.5,
    "tariff_cents_kwh": 45,
    "coordinator_reachable": true,
    "connectors": [
      { "connector_id": 1, "rated_kw": 150, "state": "charging",
        "held_by_me": false, "mine": false, "expires_at": null, "power_kw": 120.0 },
      { "connector_id": 2, "rated_kw": 150, "state": "held",
        "held_by_me": true,  "mine": true,  "expires_at": 1755792000000, "power_kw": 0 },
      { "connector_id": 3, "rated_kw": 150, "state": "free",
        "held_by_me": false, "mine": false, "expires_at": null, "power_kw": 0 },
      { "connector_id": 4, "rated_kw": 50, "state": "out_of_service",
        "held_by_me": false, "mine": false, "expires_at": null, "power_kw": 0 }
    ],
    "waitlist": { "length": 3, "my_position": 2 }
  }
}
```

Connector `state` is one of `free`, `held`, `charging`, `closing`, `suspended`, `out_of_service`. `suspended` means an active session whose share fell below `MIN_CHARGE_KW` — the session is alive but drawing nothing, which is the honest way to show a starved allocation. `out_of_service` means the charge point is faulted or has not reported in (ws-chargepoint.md §6).

Why the whole snapshot rather than a delta: a client that applies deltas has state of its own, and a client with state of its own can drift from the server after one missed frame — the failure P6 exists to prevent. The payload is a handful of connectors; sending all of it costs nothing and removes an entire class of bug. `held_by_me` and `mine` are computed **server-side** from the token, so the page never has to reason about identity.

`coordinator_reachable: false` is a hint for the interface, not an error: reservations are refused while it is false, but charging carries on and the page should say so.

> **M1 notes.**
> * `waitlist` is the constant `{"length": 0, "my_position": null}` — a declared key, never a missing one, so the page renders the same shape it always will. See §4.4.
> * `suspended` is not producible yet: it means an active session starved below `MIN_CHARGE_KW`, and nothing allocates power until M2. The other five names are all reachable today, `out_of_service` being what the station reports for a connector whose process is not answering.
> * `coordinator_reachable` means precisely **"the last renew round found a coordinator"** — the outcome of work the station actually did, not a ping. It is `true` before the first renew tick: until something has been tried, nothing has failed, and `reserve` is what really decides.

### 5.2 `session` — live progress

Sent every `SESSION_TICK_MS` to the owner of a running session, on every meter reading that changes the picture, and once more when it ends.

```json
{
  "type": "session",
  "request_id": null,
  "payload": {
    "connector_id": 2,
    "phase": "charging",
    "power_kw": 89.4,
    "energy_kwh": 12.317,
    "soc_pct": 58,
    "eta_seconds": 1560,
    "started_at": 1755790000000,
    "overstay_seconds": 0
  }
}
```

`phase` is `charging` \| `suspended` \| `complete` \| `overstay` \| `closed`. `eta_seconds` is an estimate derived from the current allocation and the vehicle's charging curve; it is advisory and may jump when another car arrives and the allocation is recomputed — that jump is the visible proof of P5 and should not be smoothed away.

Money never appears here. Cost is computed by the back office after the session row is written (schema.sql, ownership rules): the station knows energy and time, not tariffs applied to an account.

> **Not implemented in M1.** This frame carries meter readings, which reach the station over the charge point channel (ws-chargepoint.md) — and that channel arrives with M2. Until then the driver channel sends `state` only, and a running session is visible there through the connector's `state` and `power_kw`. No `session` frame is emitted, rather than one filled with zeroes.

### 5.3 `notification`

```json
{
  "type": "notification",
  "request_id": null,
  "payload": {
    "kind": "waitlist_offer",
    "text": "Connector 3 is free. Reserve it within 2 minutes.",
    "connector_id": 3,
    "offer_expires_at": 1755792120000
  }
}
```

Kinds: `reservation_expiring`, `reservation_expired`, `claim_revoked`, `waitlist_offer`, `charge_complete`, `overstay_started`, `session_interrupted`.

This frame is the **live** copy, delivered to a driver who happens to be connected. The durable copy is a different path: the station reports the event to the coordinator, which forwards it to the back office, which writes the `notifications` row (erlang-java.md). The station never writes that table — one writer per table, as the schema requires. A driver with the page closed sees it later in `notifications.jsp`; that limitation is stated in DESIGN-NOTES §7 rather than hidden.

`claim_revoked` deserves its own mention: it is not an error the client caused, it is the coordinator having resolved a conflict against this reservation (claim.md §3.2). The page says the reservation was cancelled and why, and the connector returns to `free` in the same breath.

---

## 6. Errors

```json
{ "type": "error", "request_id": "3f2c…",
  "payload": { "code": "ALREADY_HELD", "message": "connector 3 is held by another driver" } }
```

| Code | When |
|---|---|
| `BAD_REQUEST` | malformed frame, unknown action, missing field |
| `UNAUTHENTICATED` | any action before a successful `join` |
| `UNKNOWN_CONNECTOR` | `connector_id` does not belong to this station |
| `ALREADY_HELD` | the connector is held or charging for someone else |
| `NO_CLAIM` | the network refused: vehicle committed elsewhere, or no coordinator |
| `SUSPENDED` | account under a no-show penalty; reserving only, charging still allowed |
| `RETRY_LATER` | a new leader is rebuilding its claim table |
| `NOT_YOUR_TURN` | the connector is under a waiting-list offer to another driver |
| `NOT_YOURS` | the reservation or session belongs to another account |
| `INVALID_STATE` | the action does not apply in the connector's current state |

An `error` is always correlated to a `request_id`: there is no such thing as a floating error. Conditions that arise on their own — a lease expiring, a claim revoked — are `notification` frames, because they are news, not answers.

---

## 7. Behavioural rules

1. **The server owns the truth.** The client renders `state` and nothing else. It never predicts an outcome optimistically, never keeps a copy it patches, and after any reconnection it simply waits for the first `state`.
2. **At-most-once.** Every action carries a `request_id`; duplicates are answered from cache. The client is free to retry after a timeout, and must, since a WebSocket can drop a frame silently on a broken connection.
3. **Identity comes from the token.** `user_id` and `vehicle_id` are never read from a payload.
4. **A refused action changes nothing.** There is no partial application: either the claim was granted and the connector is held, or nothing happened.
5. **Reconnection is the client's job.** Exponential backoff starting at 500 ms, capped at 10 s, with a fresh `join`. The station keeps no session for a disconnected socket — the reservation lives in the connector process and survives the browser being closed, which is exactly why the client can afford to be stateless.
6. **The station degrades, it does not stop.** With the coordinator unreachable the channel keeps serving sessions and pushing state; only `reserve` fails.

---

## 8. Example — reservation, retry, and a lost race

```
browser                                        station1
   |  join {token}                                |
   |--------------------------------------------->|  JWT ok → user 12, vehicle 88
   |  ack {} + state {…}                          |
   |<---------------------------------------------|
   |                                              |
   |  reserve {connector_id: 3}  req=a1           |
   |--------------------------------------------->|  claim → coordinator → ok
   |  ack {connector_id: 3, expires_at: …}        |  connector 3: free → held
   |<---------------------------------------------|
   |  state {…connector 3 held_by_me: true…}      |
   |<---------------------------------------------|
   |                                              |
   |  (ack lost, client retries the same req=a1)  |
   |  reserve {connector_id: 3}  req=a1           |
   |--------------------------------------------->|  duplicate → cached reply,
   |  ack {connector_id: 3, expires_at: …}        |  no second claim
   |<---------------------------------------------|

another browser                                station1
   |  reserve {connector_id: 3}  req=b7           |
   |--------------------------------------------->|  connector 3 is held
   |  error {code: ALREADY_HELD}                  |
   |<---------------------------------------------|
```

## 9. Example — no-show

```
browser                                        station1
   |  ← state: connector 3 held, expires_at T     |
   |                                              |  T-2 min: notification
   |  notification {kind: reservation_expiring}   |
   |<---------------------------------------------|
   |                                              |  T: state_timeout fires
   |  notification {kind: reservation_expired}    |  claim released,
   |<---------------------------------------------|  {no_show, 12, 1, 3} → coordinator
   |  state {…connector 3 free…}                  |
   |<---------------------------------------------|
```

No operator action, no cooperation from the client: the connector frees itself because the lease decayed. The penalty counter is incremented by the back office, never by the station.

---

## 10. Configuration

| Variable | Default | Meaning |
|---|---|---|
| `DRIVER_WS_PORT` | `8080` | listener port inside the container |
| `JOIN_TIMEOUT_MS` | `5000` | time allowed for the first `join` |
| `STATE_TICK_MS` | `5000` | periodic `state` push, on top of event-driven ones. The station sends a WebSocket `ping` with it: the browser's automatic `pong` is what keeps `WS_IDLE_TIMEOUT_MS` from closing a page that has joined and is only watching |
| `WS_IDLE_TIMEOUT_MS` | `60000` | time with **no frame received** before the station hangs up. Only inbound data counts, so this is what detects a peer that vanished without a FIN; it must stay comfortably above `STATE_TICK_MS` |
| `SESSION_TICK_MS` | `5000` | periodic `session` push to the owner |
| `REQUEST_CACHE_SIZE` | `64` | request ids remembered per connection |
| `REQUEST_CACHE_TTL_MS` | `60000` | how long a cached reply stays replayable |
| `WAITLIST_OFFER_SECONDS` | `120` | lease on a waiting-list offer |
| `LEASE_SECONDS` | `900` | reservation lease; shortened to ~30 for the demo |
| `MIN_CHARGE_KW` | `6` | below this a session is `suspended`, not starved |
