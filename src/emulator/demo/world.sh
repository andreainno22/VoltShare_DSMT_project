#!/usr/bin/env bash
# VoltShare — il "mondo" di sfondo per la demo: walk-in scaglionati su Livorno, così la
# lobby ha vita mentre il presentatore guida il browser. Ctrl-C ferma tutto.
#   ./world.sh
# Il presentatore possiede Pisa 1/2/4 e Livorno 5; il mondo qui possiede Livorno 6/7.
# L'auto del riparto su Pisa 3 la lancia il co-pilota su cue (presenter-cp.sh 3 103).
#
# ## Perché ogni auto ha un supervisore, e non è pedanteria
#
# La prima versione lanciava i due `cp.js` con `&` e poi `wait`. Se una delle due
# moriva — il processo terminato, il socket chiuso, un errore qualunque — `wait`
# restava ad aspettare l'altra e **quella morta non ripartiva mai**.
#
# La conseguenza non è che manca un'auto: è che il connettore va `out_of_service`.
# Trenta secondi dopo che la colonnina smette di rispondere la stazione chiude la
# sessione con l'ultima energia misurata e dichiara la presa fuori servizio
# (`vs_connector`: "any ──gone past the grace──▶ out_of_service"), perché una presa
# senza apparecchiatura non è una presa libera. In lobby Livorno si spegne a metà,
# e il presentatore non ha modo di capire perché.
#
# È successo il 3/09 durante una prova: `world.sh` fermato venti secondi dopo
# l'avvio, connettore 6 `out_of_service`, connettore 7 mai partito.
#
# Quindi ogni auto gira dentro un ciclo che la rilancia quando esce, con una pausa
# breve perché un errore di configurazione — connettore sbagliato, veicolo non nel
# seed — non diventi un ciclo di riavvii a piena velocità. È la stessa forma di un
# supervisore OTP `one_for_one` con un `restart => permanent`, e per la stessa
# ragione: il figlio che muore è un incidente, non una decisione.
set -u
cd "$(dirname "$0")/.."                       # -> src/emulator
S2=ws://localhost:9202/ws/cp
RESTART_DELAY=${RESTART_DELAY:-3}

# `kill 0` colpisce l'intero process group, quindi i cicli e i loro `node` figli
# muoiono insieme. Senza, un Ctrl-C fermerebbe i cicli e lascerebbe due emulatori
# vivi e invisibili — che è il modo in cui un connettore resta occupato da un
# processo che nessuno sa di avere.
trap 'echo; echo "world: stop"; kill 0 2>/dev/null; wait 2>/dev/null; exit 0' INT TERM

# Una macchina: il ciclo che la tiene viva.
keep() {
  local conn=$1 veh=$2 soc=$3 batt=$4 maxkw=$5
  while :; do
    # `--stay`: quando l'auto arriva al 100% e stacca, la colonnina resta
    # collegata e il connettore torna `free`. Senza, il processo uscirebbe e la
    # presa andrebbe `out_of_service` — lo sfondo si spegnerebbe da solo a metà
    # demo, proprio mentre nessuno lo sta guardando.
    node cp.js --url "$S2" --station 2 --connector "$conn" --vehicle "$veh" \
               --soc "$soc" --battery "$batt" --max-kw "$maxkw" --stay --quiet
    local code=$?
    # exit 2 è `die()`: argomento sbagliato, connettore inesistente (4404), oppure
    # un altro socket che ha preso il connettore (4409). Rilanciare non aiuta —
    # sono tutte cose che si ripeteranno identiche — e nasconderebbe l'errore.
    if [ "$code" = "2" ]; then
      echo "world: conn ${conn} rifiutato dalla stazione (uscita 2). Non rilancio: leggi l'errore qui sopra."
      return 2
    fi
    echo "world: conn ${conn} uscito (codice ${code}), rilancio fra ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
  done
}

echo "world: Livorno conn 6 — veicolo 101"
keep 6 101 30 60 50 &

sleep 20

echo "world: Livorno conn 7 — veicolo 102"
keep 7 102 55 40 50 &

echo "world: in corsa. Ctrl-C per fermare."
wait
