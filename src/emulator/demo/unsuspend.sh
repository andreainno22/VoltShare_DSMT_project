#!/usr/bin/env bash
# Toglie una sospensione, subito e per intero.  ./unsuspend.sh andre
#   ./unsuspend.sh              tutti gli utenti sospesi
#
# Serve perché in profilo demo il lease è di 90 secondi: una prenotazione fatta
# per mostrare P2 e poi dimenticata diventa uno strike, e due strike chiudono
# l'account fuori per un giorno intero (SCOPE §3.3, N=2 K=1). Durante una prova
# succede continuamente — è successo due volte in ventiquattro ore — e non è un
# difetto: è la regola che funziona, applicata a un orologio accelerato.
#
# ## Perché non basta la UPDATE
#
# La sospensione vive in **due** posti, e cancellarne uno solo non la toglie:
#
#   1. la riga in `users`, che è la verità e appartiene al back office;
#   2. una copia nella mappa `suspended` di `vs_coord_srv`, su ogni
#      coordinatore, perché il claim va rifiutato senza interrogare MySQL a ogni
#      richiesta (erlang-java.md §2.4).
#
# La copia non ha scadenza propria: `is_suspended/2` confronta l'epoch salvato
# con l'ora corrente, quindi decade da sola *all'ora giusta* — cioè domani. Per
# toglierla adesso bisogna dirglielo, ed è ciò che fa il messaggio
# `{user_unsuspended, UserId}` che `vs_coord_srv` già sa ricevere.
#
# `ErlangBridge.notifyUnsuspension/1` esiste in Java e fa esattamente questo, ma
# **nessuno la chiama**: non c'è un percorso applicativo per revocare in
# anticipo. Da qui l'`rpc` a mano.
#
# ## E perché l'ordine conta
#
# Prima il database, poi i coordinatori. `vs_coord_bo` ripubblica il leader ogni
# 30 s, e a ogni annuncio il back office ri-spinge **tutte** le sospensioni
# ancora attive (`PenaltyService.pushAllSuspensions`). Se si svuota la mappa
# lasciando la riga, entro mezzo minuto torna com'era.
set -u

cd "$(dirname "$0")/../../deploy"

MYSQL='docker exec mysql mysql -uvoltshare -pvoltshare voltshare -N -e'
COORDS='coord1 coord2 coord3'

if [ $# -ge 1 ]; then
  WHERE="username = '$1'"
else
  WHERE="suspended_until IS NOT NULL"
fi

IDS=$($MYSQL "SELECT id FROM users WHERE $WHERE" 2>/dev/null | tr -d '\r')

if [ -z "$IDS" ]; then
  echo "unsuspend: nessun utente da sbloccare"
  exit 0
fi

# 1. la verità, che è la riga.
$MYSQL "UPDATE users SET no_show_count = 0, suspended_until = NULL WHERE $WHERE" >/dev/null 2>&1

# 2. la copia, su ogni nodo — anche sui follower: uno di loro sarà il prossimo
#    leader, e una sospensione dimenticata lì tornerebbe viva alla prima elezione.
for id in $IDS; do
  for n in $COORDS; do
    docker exec "$n" erl -sname "unsusp$RANDOM" -setcookie voltshare -noshell \
      -eval "rpc:call('vs@${n}', erlang, send, [vs_coord_srv, {user_unsuspended, ${id}}]), halt()." \
      >/dev/null 2>&1
  done
  echo "unsuspend: utente ${id} sbloccato (riga azzerata, revoca inviata ai tre coordinatori)"
done

echo
$MYSQL "SELECT CONCAT(id, '  ', username, '  no_show=', no_show_count, '  suspended_until=', IFNULL(suspended_until,'NULL')) FROM users WHERE id IN ($(echo "$IDS" | tr '\n' ',' | sed 's/,$//'))" 2>/dev/null | tr -d '\r'
