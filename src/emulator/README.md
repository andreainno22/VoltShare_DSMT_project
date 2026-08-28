# Emulators

Two Node programs, one per channel of the system's boundary. **Node ≥ 22, zero npm
dependencies** for both — `WebSocket` and `crypto` are Node built-ins, so there is nothing
to install and no lockfile to keep in sync.

| | speaks | plays the part of |
|---|---|---|
| `cp.js` | `contracts/ws-chargepoint.md` | one charge point, one connector |
| `driver.js` | `contracts/ws-driver.md` | N drivers, and the load generator |

---

## `cp.js` — the charge point

The CP end of `ws-chargepoint.md`: boot, heartbeat, plugged, meter, unplugged, and the two
commands.

One process per connector. It reconnects with backoff (1 s → 30 s) and, if a session was
running, re-sends `boot` + `plugged` with the cumulative energy: that is the reconciliation
of §6, and the only way a station restart does not lose what the car already took.

```bash
# walk-in on station 1 / connector 3, charge to 30 % and unplug
node cp.js --url ws://localhost:9201/ws/cp --station 1 --connector 3 \
           --vehicle 88 --soc 22 --battery 58 --max-kw 150 --unplug-at-soc 30

# a 50 kW car on station 2 / connector 6, cable in after 10 s, charging until Ctrl-C
node cp.js --url ws://localhost:9202/ws/cp --station 2 --connector 6 \
           --vehicle 5 --soc 40 --battery 40 --max-kw 50 --plug-after 10
```

`--limit-apply <s>` (default 5) is the LIMIT_APPLY_SECONDS ramp of §5; `--quiet` silences the
per-frame log. Ctrl-C unplugs properly instead of vanishing. The last line printed is
`final energy_kwh = …`, which is the number the station's `session closed` log must match.

---

## `driver.js` — the drivers, and the load

The browser end of `ws-driver.md`: `join`, `reserve`, `cancel_reservation`, `stop_session`,
and the `state` and `session` frames. It is **not** a copy of `js/ws.js` — that file is page
code, with a DOM around it — but the semantics that matter are deliberately identical to it:
one `request_id` per user action reused on every retry (§7.2), nothing but `join` before the
join is acked (§3), 4400/4401/4408 fatal and everything else reconnecting with backoff
(§7.5). Where the two could ever differ, `js/ws.js` is right: it is the one that runs in
front of a user.

### The tokens are signed here, and that is a test convenience

`driver.js` mints its own JWTs, one per emulated driver, each with its own `vehicle_id`. It
can only do that because the **development** secret is published in
`contracts/sample-tokens.md`, and a load generator that needed a running Tomcat to produce
forty logins would not be a load generator.

In service this is impossible and must stay impossible: `VOLTSHARE_JWT_SECRET` is injected
at deploy time and never committed, and the back office is the only issuer (`jwt.md` §1).
The station's own `vs_jwt:secret/0` logs a warning when it finds itself verifying with the
published secret; signing here is the mirror image of that warning.

```bash
node driver.js --self-test
```

re-signs the claims of `sample-tokens.md` §1 and prints whether the result is the published
fixture byte for byte. It is — which is what makes the tokens it hands the station credible
rather than merely accepted.

### Before the first run: users and vehicles

`contracts/schema.sql` seeds `stations` and `connectors` only. `users` and `vehicles` belong
to B and are written at registration, so a fresh database has none, and a `plugged` for a
vehicle nobody owns is refused with `no account for vehicle N (unknown_vehicle)` —
correctly.

`reserve` and `cancel_reservation` need no rows at all (a claim is per `vehicle_id` and never
touches MySQL), so the two contention scenarios run against an empty database. **`plugged`
does**, so a charge point needs its vehicle to exist:

```sql
INSERT IGNORE INTO users (id, username, password_hash)
  VALUES (12, 'andrea', '$2a$10$fixture.not.a.real.hash');
INSERT IGNORE INTO vehicles (id, user_id, battery_kwh, max_kw)
  VALUES (88, 12, 58.00, 150);
```

```bash
docker exec -i mysql mysql -uvoltshare -pvoltshare voltshare < seed.sql
```

### The three scenarios

The point is not big numbers. It is that the invariants hold when things overlap.

```bash
# 1. contention — N drivers race for ONE connector.
#    SCOPE §4, exclusive use: one accepted, N-1 ALREADY_HELD, and the count
#    must close exactly.
node driver.js --scenario contention --connector 1 --drivers 20

# 2. one vehicle, one reservation — the SAME vehicle asks for connectors on
#    both stations at once. No single station can settle it, so this one goes
#    through the coordinator: one accepted, the rest NO_CLAIM.
node driver.js --scenario one-vehicle --connectors "1,2,4" --connectors2 "5,7"

# 3. sustained — M drivers join, reserve and cancel in a loop while the charge
#    points deliver. No crash, and no connector left held by nobody.
node driver.js --scenario sustained --drivers 10 --seconds 150 \
               --charging-connector 3
```

`--charging-connector <n>` adds the one thing a load of anonymous drivers cannot show on its
own: with a `cp.js` delivering on that connector, the run also proves that the `session`
frame reaches its **owner and nobody else** (§5.2) and that `stop_session` on somebody else's
charge is `NOT_YOURS` (§4.3). It ends that charge, which is the demonstration — the station
tells the charge point to stop and writes the row.

Every scenario reports requests, accepted, refused **broken down by code**, and the response
time as **max and mean**. The max is the number that matters: a reservation that takes eight
seconds is a broken experience even when the mean is 200 ms.

`--drivers`, `--seconds`, `--think`, `--first-user`/`--first-vehicle`, `--secret`,
`--issuer`, `--quiet`; `--help` for the whole list. The exit status is 0 only if every
invariant held.

### A word about Docker Desktop

Docker Desktop suspends its VM when nothing is talking to it — pauses of twenty minutes were
observed here between runs. A pause inside a measurement window makes every millisecond in
that report meaningless. Gaps show up as holes in the station's own three-second ping log:

```bash
docker logs --since 5m station1 | grep -B1 "ping vs@" | grep NOTICE
```

Consecutive timestamps more than about six seconds apart mean the VM stopped, and that run
should be discarded rather than explained.
