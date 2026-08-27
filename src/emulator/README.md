# Charge point emulator

`cp.js` is the CP end of `contracts/ws-chargepoint.md`: boot, heartbeat, plugged, meter,
unplugged, and the two commands. **Node ≥ 22, zero npm dependencies** — the `WebSocket`
client is a Node built-in, so there is nothing to install and no lockfile to keep in sync.

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
