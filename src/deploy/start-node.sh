#!/bin/bash
# Boots an Erlang node inside a container.
#
#   NODE_SNAME     short node name; the node becomes $NODE_SNAME@$HOSTNAME
#   ERL_APP        OTP application to start (vs_station | vs_coord)
#   ERLANG_COOKIE  must be identical on every node that talks to another
#
# Anything else (STATION_ID, COORD_NODES, PING_TARGET, LEASE_SECONDS...) is
# read from the environment by the application itself — see vs_env.

set -euo pipefail

echo "[start-node] ${NODE_SNAME}@$(hostname) starting application ${ERL_APP}"

exec erl \
    -sname "${NODE_SNAME}" \
    -setcookie "${ERLANG_COOKIE}" \
    -pa /app/lib/*/ebin \
    -noshell \
    -eval "case application:ensure_all_started(${ERL_APP}) of
               {ok, _}         -> ok;
               {error, Reason} -> io:format(\"boot failed: ~p~n\", [Reason]), halt(1)
           end."
