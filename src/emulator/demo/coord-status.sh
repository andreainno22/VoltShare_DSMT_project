#!/usr/bin/env bash
# mode + numero di claim di un coordinatore.  ./coord-status.sh coord2
#   ./coord-status.sh            tutti e tre, uno per riga
#
# Nota (B, 2/09): la prima versione usava `erl -remsh` con il comando su stdin.
# Non stampa niente — la shell remota legge l'EOF e termina prima di emettere il
# risultato: si vede solo `*** Shell process terminated! Read EOF ***`. Qui invece
# si avvia un nodo effimero che fa una `rpc:call` e chiude: nessuna shell di mezzo,
# nessun EOF da cui dipendere, e l'uscita è una riga sola.
set -u

status_of() {
  local node=$1
  timeout 20 docker exec "$node" erl -sname "probe$RANDOM" -setcookie voltshare -noshell -eval "
      N = 'vs@${node}',
      case rpc:call(N, vs_coord_srv, mode, []) of
          {badrpc, R} ->
              io:format(\"~-8s  irraggiungibile (~p)~n\", [\"${node}\", R]);
          Mode ->
              C = rpc:call(N, vs_coord_srv, claims, []),
              S = rpc:call(N, vs_coord_srv, suspensions, []),
              io:format(\"~-8s  mode=~-10s claims=~p  suspensions=~p~n\",
                        [\"${node}\", atom_to_list(Mode), length(C), length(S)])
      end,
      halt()." 2>/dev/null
}

if [ $# -ge 1 ]; then
  status_of "$1"
else
  for n in coord1 coord2 coord3; do status_of "$n"; done
fi
