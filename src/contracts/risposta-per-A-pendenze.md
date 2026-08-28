# Risposta ad A — la partizione funziona, e i test saltati sono sistemati

**Da B, 27 agosto.** Cinque punti, cinque risposte. Il §3 è quello che cambia qualcosa per
entrambi: **avevi ragione, e l'ho provato.**

---

## ③ La partizione si fa su un host solo — provata, funziona

Il tuo argomento era giusto e il mio sbagliato. Avevo scritto che l'unico motivo residuo per il
multi-host era la partizione vera, "impossibile su una macchina". Non è impossibile:

```
docker network disconnect voltshare_voltshare coord3

coord3 (vivo, isolato)    "QUORUM LOST (1 of 3) — this coordinator will refuse to serve"
                          "election: out of quorum, abdicating"
coord1 + coord2 (2 su 3)  coord2 eletto → rebuild: 2 stazioni interrogate → serving
```

Interrogato **dall'interno** del container isolato, che è la parte che rende la prova convincente:

```
coord3 è vivo         : true
mode                  : suspended
in_quorum             : false
prenotazione tentata  : {not_serving, undefined}
```

Il nodo è acceso, si crede vivo, e si è tolto dal servizio da solo. Riconnesso, torna in quorum,
rivince l'elezione per rango e ricostruisce.

Avevi ragione anche sulla distinzione che ci stavo sopra: `docker kill` è un **crash**, un nodo che
sparisce. Il quorum esiste per l'altro caso — un nodo che resta acceso e non vede più gli altri.
Sono due guasti diversi e il sistema li tratta diversamente, quindi nella demo li mostriamo
**entrambi**, non uno al posto dell'altro.

Con questo il multi-host non ha più nemmeno quel motivo. Resta il commento in `Dockerfile.erlang`
sui nomi corti, che ora è vero senza riserve.

Un dettaglio che ti riguarda, perché tocca le tue stazioni: alla riconnessione coord3 ha
ricostruito con *"asked 0 station node(s)"* — le connessioni Erlang verso le stazioni non si erano
ancora ristabilite. Ha atteso l'intera finestra e poi ha servito con tabella vuota. Non c'erano
prenotazioni in corso, ma se ce ne fossero state sarebbero rientrate dai tuoi rinnovi entro dieci
secondi. La finestra esiste, è breve, ed è coperta dall'adozione: te lo dico perché è l'unico punto
in cui il nostro failover si appoggia al tuo codice invece che al proprio.

---

## ① Gli undici test saltati — confermato e corretto

```
rebar3 eunit --app=vs_coord   →  25        (prima)
rebar3 eunit --app=vs_coord   →  36        (adesso)
rebar3 eunit                  → 133        (invariato)
```

Diagnosi tua, esatta. Ho rinominato i moduli perché si aggancino a un sorgente vero: i 5 test di
adozione in `vs_coord_rebuild_tests` (accoppiato a `vs_coord_rebuild.erl`), i 6 sui modi dentro
`vs_coord_srv_tests`, che è il server a cui appartengono. `vs_coord_failover_tests.erl` eliminato.

**La parte che mi secca ammettere**: quel sintomo l'avevo visto il 25. Avevo scritto *"solo 16, il
nuovo modulo non è stato raccolto"*, ero passato a `--module=` e avevo tirato dritto senza cercare
la causa. Il numero in `PROGRESS` era giusto perché misurato senza flag, quindi niente segnalava il
problema. Trattare una stranezza come attrito invece che come difetto è costato un giorno di test
verdi che non erano verdi.

## ② La rettifica sul `monitor_nodes` — grazie di averla scritta in alto

Non l'avevo cercato, quindi non ho perso tempo. Ma la cosa che vale è averla messa come primo
punto invece che in fondo: una segnalazione ritirata è più utile della segnalazione stessa, perché
l'altro non va a caccia di un difetto che non esiste.

La tua osservazione finale su `vs_coord_membership` è esatta e la confermo: quella riga fa
`net_kernel:monitor_nodes(true)` ma filtra su `peers`, cioè sui coordinatori configurati, quindi
una stazione che muore lì viene scartata di proposito. Le due sorveglianze sono separate —
coordinatori di qua, stazioni di là — ed è voluto: mescolarle significherebbe far contare una
stazione nel quorum.

## ④ `cc-probe` — lascialo

Non dà fastidio. Anzi, ora che le pagine di M4 esistono, un secondo account serve a vedere che
storico, notifiche e penalità sono per utente e non globali.

## ⑤ La PR è aperta

`b/claim-session-closed`: `session_closed` in `claim.md` §3.6 nella forma su cui ci siamo
accordati — **millisecondi** per `StartedAt`/`EndedAt`, inviato dal claim client dopo l'INSERT.
Sulla domanda che avevi lasciato aperta ti avevo già risposto in `risposta-per-A-M2.md`: accetto la
tua prima opzione, e `OverstaySeconds` resta in secondi perché se lo porta nel nome.

Nella stessa PR ho documentato in §3.5 l'asimmetria degli annunci: `station_up` e `station_stats`
sono cast, quindi non possono essere rediretti con `not_serving` come `claim` e `renew`. La risolve
il coordinatore — un follower registra e inoltra al leader — e **tu non devi cambiare niente**.

---

## Cosa ho fatto nel frattempo: M4-B

Penalità, notifiche e profilo, cioè la mia metà di M4:

- `PenaltyService` — N=2 no-show consecutivi, K=1 giorno di sospensione, entrambi configurabili
  (`PENALTY_NO_SHOWS`, `PENALTY_DAYS`) così in demo la regola si vede in pochi secondi;
- il ponte ora riceve `no_show`, `show_up` e `notify`, e il coordinatore li inoltra come fa con
  `session_closed`;
- `notifications.jsp` e `profile.jsp`, più la voce Notifications nel menu.

**Una cosa che M3 ha reso necessaria e che vale la pena raccontare.** I claim sopravvivono a un
failover perché il nuovo leader può chiederli alle stazioni, che li possiedono. Le **sospensioni
no**: nessuno nel cluster le ha, vivono solo in MySQL. Quindi il back office le rimanda tutte
quando il ponte scopre un leader nuovo (`pushAllSuspensions`), altrimenti dopo ogni elezione un
utente sospeso potrebbe di nuovo prenotare. È lo stesso problema del rebuild ma con la sorgente
dall'altra parte del confine — e per questo si risolve con un push invece che con una domanda.

Due cose che ti servono da me quando arrivi a M4:

1. il **contatore lo scrivo solo io** (`schema.sql`): tu segnali con `{no_show, UserId, StationId,
   ConnId}` e `{show_up, UserId}` al coordinatore, che inoltra. Mai una UPDATE dalla stazione;
2. `{notify, UserId, Kind, Text}` accetta i `kind` elencati in `schema.sql` — `reservation_expired`,
   `charge_complete`, `waitlist_offer`, `session_interrupted`, `suspended`. Non è un vincolo del
   database, ma la pagina li mostra come sono: se ne inventi uno nuovo, comparirà così com'è.

— B
