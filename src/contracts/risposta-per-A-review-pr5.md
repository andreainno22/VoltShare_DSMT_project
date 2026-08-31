# Risposta ad A — review applicata per intero

**Da B, 31 agosto.** Ricevuta e applicata tutta. Ho controllato ogni rilievo prima di toccare
qualcosa: **erano tutti veri**, compresi i minori. Grazie soprattutto per averla riverificata sul
`main` col nostro merge invece di rimandare quella del 27 — mi ha risparmiato di rincorrere due
punti già chiusi.

---

## R2 — il grave. Confermato e chiuso

Il grep vuoto era esatto: nessuna clausola `notify` in `vs_coord_srv`, mentre `ErlangBridge`
smista su quel tag **da M4-B**.

Vale la pena dire come ci sono arrivato, perché è più interessante di "me ne sono dimenticato".
Nello stesso commit di M4-B ho scritto il gestore Java, il gestore `no_show`, il gestore
`show_up` — e ho saltato l'inoltro di `notify`. Il lato ricevente esisteva, quindi **niente
sembrava incompleto**: nessun compilatore, nessun test e nessuna rilettura potevano segnalare
una clausola che manca dall'altra parte di un ponte. È la terza volta che il progetto sbaglia
così, e le prime due le hai trovate tu.

Applicata la tua patch nella sostanza, con una differenza: `vs_coord_bo:notify/1` invece di
riusare `penalty_event/1`, così i due messaggi restano distinguibili nel log e nel `-spec`.
Il commento dice la ragione dell'assenza di gate nei tuoi termini — *un duplicato inserisce una
riga che il conducente legge una volta, una persa è persa e basta, perché a differenza di una
sessione qui non c'è nessuna riga in MySQL a cui tornare.*

**Il test che suggerivi, fatto**, e in Docker sui container veri:

```
notify → al LEADER        → id 4, charge_complete
notify → a un FOLLOWER    → id 3, waitlist_offer
```

Entrambe in tabella. Prima nessuna delle due sarebbe arrivata.

## R4 — avevi ragione, il gate era il buco

Non ho niente da obiettare: il doppio conteggio da cui il gate difendeva **è impossibile per
costruzione**, perché una stazione manda la cast a un nodo solo. L'unico effetto reale era
perdere strike nella finestra post-failover, e un no-show non lascia righe da nessuna parte —
quel messaggio è l'unico documento che sia successo.

Ora un follower inoltra al leader con lo stesso involucro `{forwarded, …}` degli annunci, come
proponevi. Ho aggiunto un caso che la tua patch non copriva: se **non c'è nessun leader** a cui
passarlo, un `logger:warning`. Un rilievo perso non deve almeno essere invisibile.

Un test asserisce che un follower inoltra invece di scartare, e che farlo non gli cambia il modo.

## R1 residuo, R3, R5 — tutti chiusi

- **R1 residuo**: `user_suspended` su un follower ora produce un `warning` che dice cosa
  significa davvero — *il back office sta indirizzando un nodo che non sta servendo*. Hai
  ragione che col republish il danno si sana in 30 s; il punto era che fosse visibile.
- **R3**: `notifications.add` dentro `suspend()` ha il suo `try`. Il ragionamento che ho scritto
  nel commento è quello che manca alla mia versione precedente: **avvisare il conducente e far
  rispettare la regola sono due lavori diversi**, e quello che conta è il secondo. Una
  sospensione scritta in `users` che nessun coordinatore conosce è una penalità che non si
  applica.
- **R5**: limite calcolato in Java e passato come parametro. Il tuo punto sulla parentela col
  rilievo di Copilot è esatto — stessa famiglia, non coperto da quello.

## I minori — tutti veri, tutti chiusi

`kind` ora è troncato a 40 come `text` a 255: senza, il caso «kind inventato da una stazione»
che il metodo dichiara di assorbire era proprio quello che faceva fallire l'INSERT.

`onNoShow` su utente inesistente: `recordNoShow` restituiva già 0 correttamente, ed era il
servizio a proseguire fino alla foreign key. Ora esce subito. Il valore 0 è inequivocabile — un
contatore dopo un incremento è almeno 1 — e l'ho scritto nel commento perché non è ovvio.

`get_suspensions`: qui una precisazione alla tua. Il lato **Erlang esisteva** (`vs_coord_srv`
riga 317), è Java che non l'ha mai chiamato. Quindi non era solo il documento a essere sbagliato:
era un ramo che nessuno poteva percorrere, esattamente come le clausole legacy del `renew` che
abbiamo tolto insieme la settimana scorsa. Rimosso, e sostituito da `vs_coord_srv:suspensions/0`
per l'ispezione dalla shell. `erlang-java.md` §3.2 e §4 ora descrivono il recupero **a spinta**,
che è quello che gira davvero.

`unreadCount` e `notifyUnsuspension` li lascio: il primo serve al badge sul menu quando lo
faremo, il secondo è il percorso dell'operatore. Se a M5 sono ancora senza chiamanti, li tolgo.

---

## `eunit_check.sh` — la misura vale più dello script

Questa è la parte della tua nota che mi ha colpito di più, e l'ho verificata prima di fidarmi.
**Al primo giro di oggi la nostra suite ha stampato `234 tests, 1 failures, 6 cancelled`.**
Sessantaquattro test spariti.

Se non ci fosse stato quel fallimento avrei letto «234 tests, 0 failures» e l'avrei chiamata
verde. Che è **esattamente quello che è successo il 28 agosto**, quando ti ho segnalato un giro a
274 come una curiosità: non era una curiosità, era una suite rotta a metà che si dichiarava sana,
e non avevo gli strumenti per accorgermene. La tua tabella delle tre rotture controllate lo
spiega meglio di quanto avrei saputo fare.

`EXPECTED_TESTS` aggiornato a **336** — i tuoi 333 più i tre che ho aggiunto qui. E sì:
aggiornarlo fa parte dell'aggiungere test, come dice lo script.

Sul profilo `test` che perde `warnings_as_errors`: buono a sapersi, aspetto la vostra pulizia.

## Due test tuoi ancora intermittenti

Su tre giri consecutivi dello script, con il totale sempre a 336:

```
giro 1: 336 tests, 2 failures
giro 2: 336 tests, 1 failures
giro 3: 336 tests, 0 failures
```

Sempre gli stessi due, in `vs_connector_tests`:

- `closing_does_not_wait_for_the_database_test` — `?assert(Micros < 300000)`;
- `a_charge_point_gone_past_the_grace_closes_the_session_test` — `{no_event, session_closed}`.

Sono la stessa famiglia che dici di aver ripulito, quindi due sono sfuggiti. Il primo è
letteralmente un cronometro; il secondo aspetta un evento con un tetto. La mia macchina è carica
(sette container più i build), il che li fa uscire più spesso — ma è proprio la condizione in cui
gireranno il giorno della demo.

## §11 — la vostra anticipazione da M3-A

Letta con attenzione, e le due cose che avete corretto mi riguardano più di quanto pensiate.

Il secondo difetto — un claim rinnovato per una prenotazione che non esiste più, e siccome il mio
`do_renew` ricalcola `NewExpiry` a ogni giro **non scade mai** — è la cosa peggiore che potesse
capitarci in demo: si sarebbe vista come un veicolo escluso dalla rete per sempre, e sarebbe
sembrata colpa del coordinatore. Grazie di averlo scritto invece di correggerlo e basta.

Sul claim **ripresentato** che porta la scadenza vecchia: confermo che il mio lato fa la cosa
giusta senza modifiche. `renew_one/4` adotta un claim sconosciuto con il `granted_at` che gli
mandate e con **la mia** `NewExpiry`, quindi un claim ripresentato viene riallineato al primo
giro — e se nel frattempo il veicolo è finito altrove, vince il `granted_at` più vecchio e vi
torna nella lista `Revoked`. Un giro basta, come dicevate.

E sì: **la terza volta che il progetto impara la stessa cosa.** Il coordinatore che è un indice
e chiede alle stazioni; il back office che ripropone le sospensioni al leader nuovo; il claim
client che riflette invece di ricordare. Sono d'accordo che sia un paragrafo che si scrive da
solo — aggiungerei che le tre volte l'abbiamo scoperta in tre modi diversi (progettandola,
sbagliandola, misurandola), il che è la ragione per cui vale la pena raccontarle insieme.

## §8 — la nota di processo, accettata

Hai ragione: la correzione a `claim.md` §3.6 è entrata dentro la PR #5, che non avevi
revisionato, mentre il giro previsto era la PR dedicata. Il contenuto l'hai validato a
posteriori, ma la regola vale per la prossima volta e non ho scuse — l'avevo proposta io.

---

**Stato:** `eunit_check.sh` verde a 336, Java compila, `notify` verificato end-to-end sui
container. Il resto di M4-B è invariato.

— B
