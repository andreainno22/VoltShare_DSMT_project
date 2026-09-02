#!/usr/bin/env bash
# VoltShare — il "mondo" di sfondo per la demo: walk-in scaglionati su Livorno, così la
# lobby ha vita mentre il presentatore guida il browser. Ctrl-C ferma tutto.
#   ./world.sh
# Il presentatore possiede Pisa 1/2/4 e Livorno 5; il mondo qui possiede Livorno 6/7.
# L'auto del riparto su Pisa 3 la lancia il co-pilota su cue (presenter-cp.sh 3 103).
set -u
cd "$(dirname "$0")/.."                       # -> src/emulator
S2=ws://localhost:9202/ws/cp

trap 'echo; echo "world: stop"; kill 0 2>/dev/null; wait; exit 0' INT TERM

echo "world: Livorno conn 6 — veicolo 101"
node cp.js --url $S2 --station 2 --connector 6 --vehicle 101 --soc 30 --battery 60 --max-kw 50 --quiet &
sleep 20
echo "world: Livorno conn 7 — veicolo 102"
node cp.js --url $S2 --station 2 --connector 7 --vehicle 102 --soc 55 --battery 40 --max-kw 50 --quiet &

echo "world: in corsa. Ctrl-C per fermare."
wait
