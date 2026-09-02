#!/usr/bin/env bash
# Helper del co-pilota: una colonnina per un'azione del presentatore.
#   ./presenter-cp.sh <connettore> [<veicolo>] [altri argomenti di cp.js...]
# Esempi:
#   ./presenter-cp.sh 1 "$PV" --soc 45 --battery 60 --max-kw 150 --linger 150
#       carica su Pisa 1; dopo lo Stop tiene il cavo dentro 150 s -> è l'overstay.
#   ./presenter-cp.sh 3 103 --soc 40 --battery 75 --max-kw 150
#       la "seconda auto" che fa calare l'allocazione del presentatore su conn 1.
set -u
cd "$(dirname "$0")/.."                       # -> src/emulator
conn=${1:?connettore richiesto}; veh=${2:-88}
shift $(( $# > 1 ? 2 : 1 ))
port=9201; st=1
case "$conn" in 5|6|7) port=9202; st=2;; esac
exec node cp.js --url ws://localhost:$port/ws/cp --station $st --connector "$conn" \
                --vehicle "$veh" "$@"
