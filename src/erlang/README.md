# VoltShare — Erlang side

Umbrella project holding both Erlang applications.

```
apps/vs_common     helpers shared by the two (config from env, timestamps)
apps/vs_station    station controller — part A
apps/vs_coord      coordinator — part B (added in M1)
```

`vs_common` is shared: changes there go through a PR, like the contracts.

## Build and test

```bash
rebar3 compile
rebar3 eunit
rebar3 shell            # sname vs, cookie voltshare — see rebar.config
```

M0 has **no external dependencies**, so `compile` works offline. Cowboy, jsx,
jose and mysql arrive with M1 (they are listed, commented, in `rebar.config`).

## Two nodes talking, without Docker

The same check the compose file performs, but faster to iterate on. Two
terminals, from this directory:

```bash
# terminal 1 — the node that answers
rebar3 shell --sname vsA --setcookie voltshare

# terminal 2 — the node that probes, every second
PING_TARGET=vsA@$(hostname -s) PING_INTERVAL_MS=1000 \
  rebar3 shell --sname vsB --setcookie voltshare
```

On Windows (Git Bash / PowerShell) replace `$(hostname -s)` with your machine
name, the one that appears in the shell prompt after `@`.

Terminal 2 logs `ping vsA@... -> pong from vsA@...` every second. Kill terminal 1
and it logs `failed: nodedown` without stopping — the station must survive an
unreachable coordinator (claim contract §4). Start it again and the pongs resume.

A one-shot probe from any node's shell:

```erlang
vs_ping:ping('vsA@yourhost').   %% {pong, 'vsA@yourhost'} | {error, nodedown}
vs_ping:status().               %% #{sent => 12, ok => 11, failed => 1, ...}
```

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `STATION_ID` | `1` | which station this node is |
| `COORD_NODES` | `vs@coord1,vs@coord2,vs@coord3` | coordinator cluster (M1) |
| `LEASE_SECONDS` | `900` | reservation lease; shorten to ~30 for the demo |
| `PING_TARGET` | unset | M0 probe target; unset = answer only |
| `PING_INTERVAL_MS` | `3000` | probe period |
| `ERLANG_COOKIE` | `voltshare` | must match on every node |

Everything is read through `vs_env`, which falls back to the default when a
variable is missing or unparsable: a typo in compose must not stop a node from
booting.
