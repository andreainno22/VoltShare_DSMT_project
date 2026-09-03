#!/usr/bin/env bash
# Attacca una colonnina "vuota" a un connettore e ce la tiene.
#   ./socket.sh 2            Pisa, connettore 2
#   ./socket.sh 5            Livorno (la porta la ricava dal numero)
#   ./socket.sh 2 3 4        più connettori insieme
#
# ## A cosa serve
#
# A rimettere in servizio una presa `out_of_service`, e a tenercela.
#
# Un connettore va `out_of_service` quando la sua colonnina smette di rispondere
# per trenta secondi: dal lato della stazione un emulatore che è uscito e un
# caricatore che si è rotto sono indistinguibili, e in nessuno dei due casi la
# presa è utilizzabile. Ci esce quando una colonnina fa `boot` dichiarandosi
# `available` (`vs_connector`: "out_of_service ──boots available──▶ free").
#
# Questo script è esattamente quel `boot`, reso permanente: `--plug-after`
# enorme, quindi nessuna auto viene mai infilata, e `--stay`, quindi il processo
# non esce. È la controparte di `world.sh` — quello porta le **auto**, questo
# porta l'**apparecchiatura**.
#
# ## Perché serve anche senza guasti
#
# Una presa a cui non si è mai collegata una colonnina resta `free` e si può
# prenotare, ma **non** ci si può attaccare: il `plugged` arriva dal canale
# colonnina, e se non c'è colonnina non arriva niente. Nella demo i connettori
# 2, 4 e 5 servono solo per prenotazioni che scadono, quindi non hanno bisogno
# di nulla; ma se durante le prove ci si è attaccato qualcosa e poi se n'è
# andato, la presa resta morta e la lobby ne offre una di meno.
#
# ## Perché è supervisionato
#
# Per la stessa ragione di `world.sh`: un guaritore che muore lascia il problema
# che doveva risolvere, e in più fa credere di averlo risolto. Il 3/09 ne sono
# morti due di fila perché li avevo lanciati con `timeout`, e ogni volta la
# presa è tornata fuori servizio qualche minuto dopo.
#
# Ctrl-C ferma tutto e le prese tornano `out_of_service` dopo trenta secondi:
# è corretto, l'hardware l'hai staccato tu.
set -u
cd "$(dirname "$0")/.."                       # -> src/emulator
RESTART_DELAY=${RESTART_DELAY:-3}
VEHICLE=${VEHICLE:-107}                       # mai usato: non si attacca nulla

[ $# -ge 1 ] || { echo "uso: ./socket.sh <connettore> [<connettore>...]"; exit 2; }

trap 'echo; echo "socket: stop"; kill 0 2>/dev/null; wait 2>/dev/null; exit 0' INT TERM

keep_socket() {
  local conn=$1 port=9201 st=1
  case "$conn" in 5|6|7) port=9202; st=2;; esac
  while :; do
    node cp.js --url "ws://localhost:${port}/ws/cp" --station "$st" --connector "$conn" \
               --vehicle "$VEHICLE" --plug-after 999999 --stay --quiet
    local code=$?
    if [ "$code" = "2" ]; then
      echo "socket: conn ${conn} rifiutato dalla stazione (uscita 2) — leggi l'errore sopra."
      return 2
    fi
    echo "socket: conn ${conn} uscito (codice ${code}), riattacco fra ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
  done
}

for c in "$@"; do
  echo "socket: colonnina vuota sul connettore ${c}"
  keep_socket "$c" &
done

echo "socket: in corsa. Ctrl-C per staccare."
wait
