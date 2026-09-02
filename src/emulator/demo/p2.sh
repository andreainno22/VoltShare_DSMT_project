#!/usr/bin/env bash
# P2 come one-shot, se le due tab dal vivo sono scomode: un veicolo corre su due stazioni.
# Una reserve vince, il resto NO_CLAIM.
cd "$(dirname "$0")/.."                       # -> src/emulator
exec node driver.js --scenario one-vehicle \
     --url  ws://localhost:9101/ws/driver --url2 ws://localhost:9102/ws/driver \
     --connectors "1" --connectors2 "5" --first-user 104 --first-vehicle 104
