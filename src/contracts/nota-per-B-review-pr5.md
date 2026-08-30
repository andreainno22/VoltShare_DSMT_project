# Nota per B — la review della PR #5, finalmente, e cosa è successo lato A

**Da A (Caleb), 29 agosto.** Hai chiesto la review che non ti era mai arrivata: eccola per
intero. Avevi ragione a preoccuparti — **una delle due «serie» è ancora aperta e non è
innocua**, ed è quella che farebbe cadere nel vuoto le notifiche di M4-A.

Tutti i rilievi qui sotto sono stati **riverificati oggi** sul `main` che contiene il tuo
merge, non copiati dalla review del 27: dove il tuo fix ha già chiuso il punto, lo dico e
chiudo.

---

## 1. R1 — l'hai già chiuso, e nel modo giusto

Il tuo fix combacia con quello che la review proponeva, punto per punto: push su **ogni**
`{leader, …}` in Java, e il republish dei 30 s che porta anche `{leader, node()}`
(`vs_coord_bo.erl:162-172`, col commento che spiega esattamente il buco). La prova che hai
scelto — riavvio del **solo** back office, senza elezione, `Re-sent 1 suspension(s)` — è la
prova giusta: isola la variabile che conta.

**Un residuo d'igiene, una riga.** Un `user_suspended` che arriva a un coordinatore
**follower** è ancora assorbito in silenzio (`vs_coord_srv.erl:295-298`, invariato): nessun
gate sul mode, nessun inoltro, nessun log. Col republish il danno si sana entro 30 s, quindi
non è più grave — ma un `logger:warning` lì renderebbe visibile una finestra che oggi è muta.

## 2. R2 — **GRAVE, ancora aperto**: `{notify, …}` non è inoltrato dal coordinatore

Riverificato oggi: in `vs_coord_srv.erl` **non esiste nessuna clausola `notify`** (grep vuoto
sul file; le clausole penalità sono solo `no_show` e `show_up`). Il lato ricevente in
`ErlangBridge` c'è ed è pronto — il dispatch sul tag `notify` è scritto — ma quando la stazione
manderà la cast in M4-A, questa cadrà nel `handle_cast` catch-all: scartata con un log, e la
notifica non arriva mai in tabella.

È la classe di difetti «forma sui due versi del ponte» che ci ha già morso due volte, e
**blocca M4-A**: il frame `notification` di `ws-driver.md` esiste per portare al browser il
`session_interrupted` che il connettore emette già, e senza questo hop non arriva niente.

Patch, scritta sul modello esatto di `session_closed` (il filo stazione→coordinatore è la
4-tupla piatta su cui `ErlangBridge` fa già dispatch):

```erlang
%% vs_coord_srv.erl, accanto alla clausola session_closed (~riga 235)

%% M4 notifications. Same route as session_closed and ungated for the same
%% reason: forwarding a duplicate inserts at worst a second row the driver
%% reads once, dropping one loses the only copy there is — this event has
%% no row in MySQL to fall back on.
handle_cast({notify, _UserId, _Kind, _Text} = Event, State) ->
    vs_coord_bo:notify(Event),
    {noreply, State};
```

```erlang
%% vs_coord_bo.erl — export notify/1, poi:

-spec notify(tuple()) -> ok.
notify(Event) ->
    gen_server:cast(?SERVER, {notify, Event}).

%% Not gated on `serving', exactly like session_closed (and unlike
%% penalty_event, whose gate exists against double counting — a duplicate
%% notification does not double-count anything).
handle_cast({notify, Event}, State) ->
    send(State, Event),
    {noreply, State};
```

**Il gate `serving` qui sarebbe un buco**, non una protezione: per `notify` un duplicato è
innocuo e perderla è definitivo. Test suggerito, nel tuo stile: un `notify` castato a un
**follower** arriva comunque al mbox Java — è il caso cold-boot e finestra post-failover.

## 3. R3 — declassato a osservazione

L'ordine in `PenaltyService.suspend()` è rimasto notify-ultimo, ma ora è una **scelta
commentata** (`PenaltyService.java:170-172`) e con R1 corretto il republish la sana davvero
entro 30 s. Resta un nit: il commento copre la *perdita del messaggio*, non l'INSERT della
notifica che **lancia** — in quel caso `suspend()` esce a metà, con la sospensione in `users`
e il coordinatore che non lo saprà. Un try separato attorno a `notifications.add` chiude anche
quello. Nessuna urgenza.

## 4. R4 — BASSO, ancora vero: il gate `serving` su `penalty_event` perde strike reali

`vs_coord_bo.erl:148-154`, invariato: un non-serving droppa l'evento. Il doppio conteggio da
cui il gate protegge è impossibile per costruzione — un evento è una cast verso un nodo solo, e
il wrapper `{forwarded, …}` che già usi per `station_up` impedirebbe il rimbalzo. Nella
finestra post-failover in cui una stazione crede ancora al vecchio leader, gli strike si
perdono. **Fix gratis:** il follower inoltra al leader con `{forwarded, …}`.

## 5. R5 — BASSO, ancora vero: `suspended_until > NOW()` confronta due orologi

`UserDao.java:199`: scrittura con l'orologio della JVM, filtro con `NOW()` di MySQL. In Docker
è tutto UTC e torna; su una macchina dev non-UTC la sospensione si accorcia o si allunga
dell'offset. Imparentato col rilievo di Copilot che hai già chiuso (troncamento alla creazione),
ma non coperto da quello. **Fix:** `WHERE suspended_until > ?` col parametro calcolato in Java.

## 6. Minori, tutti riverificati oggi

- `NotificationDao.add` tronca `text` a 255 ma **non `kind`** (righe 64-65), che è VARCHAR(40):
  un kind lungo fa fallire l'INSERT — proprio nel caso «kind inventato da una stazione» che il
  metodo dichiara di voler assorbire.
- `erlang-java.md` §3.2/§4 promettono ancora il `get_suspensions` **mai implementato** (righe
  181 e 197). Il recovery vero ora è a spinta (push su ogni announce + republish): il documento
  descrive un meccanismo a richiesta che non esiste.
- `unreadCount` e `notifyUnsuspension` restano senza chiamanti.
- `onNoShow` su utente inesistente prosegue fino alla violazione FK con un log fuorviante.

## 7. Cosa è stato controllato ed è a posto

Lo diciamo perché pesa più dei rilievi: forme e arità di `{no_show,…}`/`{show_up,…}`/
`{user_suspended,…}` combaciano su tutti gli hop; `Until` in secondi coerente col contratto;
XSS pulito (`<c:out>` su kind/text/username); JSP sotto `WEB-INF/views/` e `AuthFilter` sulle
rotte nuove; PreparedStatement ovunque; `recordNoShow` transazionale con `FOR UPDATE`;
`pushAllSuspensions` manda solo sospensioni attive e il coordinatore ricontrolla la scadenza.

---

## 8. `claim.md` §3.6 — arrivato, ed è giusto

La correzione dell'envelope è già su `main` e dice la cosa giusta nel modo giusto («Read the
wrapper carefully — it is not decoration», le due forme con l'hop di ciascuna). Grazie.

Una nota di processo, senza drammi: la modifica a un file condiviso è entrata **dentro la
PR #5**, che A non ha mai revisionato — il giro previsto era la PR dedicata che avevi proposto
tu. Questa review vale come review a posteriori del contenuto (verificato: corretto); la regola
resta per la prossima volta. Vale anche per la tua osservazione su Copilot: d'accordo, i suoi
rilievi non passano dal nostro accordo sui contratti.

## 9. Le tue due segnalazioni: entrambe chiuse

**Il test intermittente.** Era il `timeout_ms => 500` del fixture di test (produzione: 2000)
che scattava per starvation quando la suite è sotto carico: `acquire` gira nel processo del
test, la call al mock va in timeout, `call_one` la traduce in `unreachable`, la lista dei nodi
finisce, e il test riceve `{error, no_claim}` — il tuo `{badmatch, {error, no_claim}}`. Curioso:
la tua ricetta zero-`sleep` qui non si applicava, perché non c'è nessun timer da consegnare a
mano — è una richiesta/risposta sincrona, e la cura è un timeout che **non possa** scattare
(60 s). Stessa passata: i tetti di `wait_until` e `holds()`, e un terzo flake della stessa
famiglia beccato *mentre scattava* — un'asserzione che chiedeva a due letture dell'orologio di
cadere nello stesso millisecondo.

**Il conteggio 274 invece di 298 non si è riprodotto** in 10 giri strumentati (liste dei
testcase identiche, stesso md5). Ma abbiamo misurato il meccanismo con tre rotture controllate,
e il risultato riguarda anche te:

| rottura | totale | failures | coda |
|---|---|---|---|
| il `setup` di una fixture solleva | **invariato** | 0 | `, 22 cancelled` |
| `exit` nel processo di un test | 299 | 0 | `, 6 cancelled` |
| un generatore solleva enumerando | 286 | 0 | `, 5 cancelled` |

**Tutte e tre stampano «0 failures».** Il totale non è una costante della suite: è quanto
lontano eunit è arrivato a *enumerarla*. Da qui `src/scripts/eunit_check.sh` (versionato, vale
anche per i tuoi giri): verde solo se rebar3 esce 0 **e** il sommario è esattamente
`<N> tests, 0 failures`, ancorato — così un `, 22 cancelled` non passa. Il tuo giro a 274
sarebbe stato rosso. Aggiornare il numero nello script è parte dell'aggiungere test.

Bonus dallo stesso giro: **il profilo `test` di rebar3 lascia cadere `warnings_as_errors`**
(misurato iniettando una variabile inutilizzata: la suite esce 0 con un warning). La nostra
regola «main verde con warnings_as_errors» copre `src/`, non i test. Ci sono warning
preesistenti in due nostri file di test, li ripuliamo noi.

**`"elsewhere"`**: ricevuto, è nostro, lo togliamo — «your vehicle already holds a reservation»
è vero in entrambi i casi senza affermare niente sul dove.

## 10. Una classe di difetti che vale per la relazione

Abbiamo chiuso oggi il terzo caso dello stesso errore: **un codice permanente dato a un fatto
temporaneo.**

- **P4** — il riaggancio del socket colonnina si arrendeva con `4404` («questa stazione non ha
  quel connettore»), e il nostro emulatore moriva, correttamente. Ora è `1012` (Service
  Restart), che cade da solo nel ramo di backoff di qualunque client: `cp.js` non è stato
  toccato, ed è la prova che il codice nuovo dice quello che intende dire.
- **P10** — lo stesso, un gradino prima: l'**handshake** rispondeva `4404` anche a un
  connettore che *è* della stazione ma in quell'istante non ha un processo (manager che sta
  avviando, connettore fra crash e restart). Ora quei casi sono **ammessi** e risponde il
  `boot` con `accepted: false` e un `reason`. Due frasi in `ws-chargepoint.md` §1 e §3.1 —
  contratto nostro, nessuna PR dovuta, ma te lo segnaliamo perché tocca cose che vedi.
- **P13** — ancora aperto: la stessa confusione sul canale driver, dove un connettore in
  riavvio produce `UNKNOWN_CONNECTOR` invece di `RETRY_LATER`.

Sta bene accanto al tuo «due domande diverse» sul `leaderNode`: lì un nome che non cambia
scambiato per uno stato che non è cambiato; qui una condizione che passa scambiata per una che
non passa mai. Direi che questa coppia va raccontata insieme.

## 11. Anticipazione da M3-A: due difetti nostri che riguardano il tuo coordinatore

Oggi abbiamo cominciato M3-A e la prima cosa fatta è stata **misurare** quello che c'era.
Buone notizie prima: su un failover vero il `granted_at` originale sopravvive all'adozione
(«oldest wins» tiene), il claim resiste alla morte di **tutti e tre** i coordinatori, e la
pastiglia di raggiungibilità non mente mai. Una sorpresa utile: il claim non torna dal ciclo di
renew come credevamo — torna dalla tua `who_do_you_hold` del rebuild, che ri-punta il leader
della stazione in mezzo secondo.

Poi due difetti **nostri**, misurati, che però hanno per vittima il tuo coordinatore:

1. **Se il nostro claim client si riavvia, perde tutti i claim** e risponde `{holds, 1, []}`
   alla tua rebuild. Alla prima elezione successiva, il tuo leader nuovo ricostruisce una
   tabella vuota e concede lo stesso veicolo a un'altra stazione: misurato, due prenotazioni
   per lo stesso veicolo in 53 secondi.
2. **Se muore un connettore mentre tiene una prenotazione**, il claim resta nel nostro client e
   viene rinnovato ogni 10 s contro una prenotazione che non esiste più. E siccome il tuo
   `do_renew` ricalcola `NewExpiry` a ogni giro — giustamente — quel claim **non scade mai**: il
   veicolo resta escluso da tutta la rete, in modo permanente e silenzioso.

**Corretti entrambi in giornata** — te li raccontiamo lo stesso, perché la lezione è comune e
perché il secondo, se fosse capitato in demo, si sarebbe visto come un rifiuto inspiegabile del
*tuo* coordinatore: ora sai che non sarebbe stata colpa sua.

Il rimedio è nella direzione che avevi usato tu per le sospensioni — **chi possiede lo stato lo
ripropone** — in una forma che il vostro `monitor` rende esatta invece che periodica:

- il client **monitora il connettore** che ha chiesto il claim. Il pid era già lì, dentro il
  `From` della `gen_server:call` che registra il claim (l'`acquire` gira nel processo del
  connettore), e per tre milestone l'abbiamo scritto `_From`. Quell'underscore *era* il difetto.
  Ora il `DOWN` rilascia il claim: fuori dalla mappa in **10 ms**, e funziona anche su `kill`,
  cioè proprio dove `terminate/3` non viene eseguito.
- al riavvio il client **chiede** ai connettori cosa tengono, con un cast, e loro ripresentano
  il claim. La prima risposta alla tua `who_do_you_hold` porta già il claim col `granted_at`
  originale, e dopo uno stop del leader la seconda stazione riceve `vehicle_committed` invece
  del veicolo.

Una cosa che potrebbe interessarti perché tocca il tuo `do_renew`: un claim **ripresentato**
porta la scadenza che il connettore aveva copiato alla concessione, mentre tu la sposti avanti
a ogni rinnovo — le due divergono per progetto, e una ricarica supera tranquillamente
lease+grace. Abbiamo dovuto marcare quei claim come "non ancora confermati" e offrirli comunque
in un batch di renew: sei tu l'unico che sa se sono ancora buoni, e ci rispondi adottandoli o
revocandoli. Un giro basta.

E scrivendolo ci siamo accorti che è la **terza** volta che il progetto impara la stessa cosa:
il coordinatore che è un indice e non il registro (e chiede alle stazioni), il back office che
ripropone le sospensioni al leader nuovo, e ora il claim client che riflette invece di
ricordare. Tre livelli diversi, una regola sola: **chi possiede lo stato lo ridice a chi lo
aggrega, e chi aggrega non prova a ricordarselo da solo.** Per la relazione è un paragrafo che
si scrive da sé.

## 12. Demo e database non condivisi — d'accordo su tutto

Misure «sul database» su **una macchina sola** con un solo stato, e `DELETE FROM sessions;`
concordato prima, su quella macchina. Sulle scelte del servlet siamo d'accordo entrambe:
`/session` separato è giusto (chi mette nei preferiti la propria ricarica non deve ritrovarsi
la griglia dei connettori), e il commento sul ramo «stazione sconosciuta» dice una cosa vera —
l'erogazione non passa dal coordinatore né dal back office. Sulla tua offerta di metterlo anche
nel markup: ti mandiamo la frase quando toccheremo quella pagina in M4-A.

---

*Riverifiche del 29/08 su `vs_coord_srv.erl` (nessuna clausola `notify`; `user_suspended` riga
295), `vs_coord_bo.erl:148-154` e `:162-172`, `PenaltyService.java:163-177`, `UserDao.java:199`,
`NotificationDao.java:60-68`, `erlang-java.md:135,181,197`, `claim.md` §3.6. Le misure di §9,
§10 e §11 sono nostre, su compose a 7 container e con test peer multinodo.*

— A