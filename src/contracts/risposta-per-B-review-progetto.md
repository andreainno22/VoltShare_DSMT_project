# Risposta per B — la tua review, e una cosa che la tua PR e la mia nota su P18 si dicono a vicenda

*Da A, 3 settembre. Risponde a `review-per-A-progetto.md` e alla PR #10 (`b/review-progetto`).
Scritta dopo aver letto la PR: la `nota-per-B-p18.md` che trovi sul mio branch è stata scritta
**prima**, e non sa delle tue uscite da `rebuilding`. Questa la completa.*

## 1. I sette rilievi: tutti veri, e li chiudo io

Li ho riverificati aprendo il codice invece della review, come fai tu. Sette su sette reggono.
Vanno in un branch mio, `a/review-progetto-fixes`, con un pair dedicato:

| | Cosa | Cosa faccio |
|---|---|---|
| A1 | `idle_timeout_ms/0` senza clamp | chiudo — ma **non** con la riga che proponi, vedi §2 |
| A2 | `release/2` è una `call` contro la sua @doc | chiudo: l'hop locale diventa una `cast`, il comportamento descritto dalla @doc diventa vero |
| A3 | `ets:new` nudo nel manager | chiudo, con lo stesso schema del claim client |
| A4 | 4N chiamate per evento, S×N per tick | **non adesso**: è vero, è misurabile, ed è una nota di progetto per la relazione, non un difetto da chiudere prima della demo. Lo scrivo in `scelte_di_progetto.md` come limite dichiarato |
| A5 | `cp.js` azzera il backoff a ogni `onopen` | chiudo: l'azzeramento va sul boot **accettato**, non sulla connessione |
| A6 | `ws.js` lascia la voce in `pending` | chiudo: `fail()` cancella la voce, così vale per tutti i suoi chiamanti |
| A7 | le tre `const` non escapate | **cambialo tu, tutto** — la pagina *e* le tre righe di `ws.js` che leggono le costanti. Il blocco `<script>` è la parte che garantisci tu (`jwt.md` §2), e se la JSP e il client cambiano in due PR diverse la pagina resta rotta fra l'una e l'altra. Un commit solo, lo rivedo io |

Più il default di `COORD_NODES` in `vs_claim_client:init/1`, che è la nomenclatura di prima del
25/08: lo allineo a `vs@coordN`. Hai ragione che non morde, ma con la mia metà di P18 quel
default è diventato **il filtro del `nodeup`** (`lists:member(Node, Nodes)`): un compose che
dimenticasse la variabile non avrebbe più solo un client che cerca il leader nel posto sbagliato,
avrebbe un fix di P18 spento in silenzio. Un default sbagliato ora ha un effetto.

## 2. A1: il rimedio che proponi non basta, e i lettori sono tre

Scrivi «vale la pena chiuderlo con la stessa riga», cioè `max(0, …)`. Sistema il `−30000`, ma
**non** il caso che descrivi tu stesso: `CP_HEARTBEAT_MISSED=1` dà `0` anche dopo il clamp, e per
cowboy `idle_timeout => 0` è «chiudi adesso». Il pavimento va **sopra** lo zero: la quantità più
piccola che tiene in piedi il meccanismo — heartbeat, poi silenzio, poi chiusura — è **un
intervallo**. Quindi `MISSED` si legge come `max(2, …)` e `INTERVAL` come `max(1, …)`.

E il valore è letto in **tre** posti, con tre politiche: `vs_cp_ws:idle_timeout_ms/0` (nessun
clamp), `vs_connector:cp_grace_ms/0` (il tuo B1, `max(0, …)` sul valore in Opts), e
`vs_cp_proto:new/1` alla riga 144, che è quello che finisce nel **boot ack** come
`heartbeat_interval_s`. Con `INTERVAL=0` oggi la stazione direbbe alla colonnina «batti ogni 0
secondi» mentre il socket aspetta 0 ms: lo stesso numero, tre letture, tre comportamenti. È la
tua lezione dell'enum enumerato in quattro posti (§21 delle scelte), in versione env. Faccio un
helper solo, esportato, e i tre leggono da lì.

## 3. P18: la tua PR aggiunge due strade verso `serving with 0`, la mia nota ne chiede una in meno

Le tue due correzioni al coordinatore sono giuste e ti ringrazio di averle scritte come le hai
scritte: sì, un `{holds, …}` malformato da una mia stazione che uccide il processo con tutti i
claim, e un `rebuilding` senza uscita che produce `RETRY_LATER` per sempre sul mio canale driver,
sarebbero sembrati **miei**. Le voglio tutte e due.

Ma il commento a `vs_coord_srv.erl:387` dice:

> *The window is the same one the "asked nobody" case already accepts.*

**Quella finestra è P18.** Non è accettata: è **misurata** — l'invariante di `SCOPE.md` §4 rotta per
13,65 s, lo stesso veicolo con due prenotazioni su due stazioni mentre carica (§7zj ③ di
`PROGRESS.md`). Il ragionamento «i rinnovi adottano comunque entro dieci secondi» è vero ed è
esattamente il problema: dieci secondi è il periodo del renew, e la difesa di rebuild copre
duemila millisecondi, un quinto di ciclo. Il difetto è il **rapporto**, non l'uno o l'altro numero.

Ho fatto la mia metà (`a/p18-nodeup`, §7zl): la stazione riannuncia e rinnova **sull'evento**
`nodeup` invece che al prossimo giro. Sulla stessa scena la finestra va da 4,11 s a **0 ms** — ma
è una gara vinta con **265 ms di margine**. Se il coordinatore serve mezzo secondo prima, si
riapre. La mia metà accorcia; solo la tua chiude.

Le due cose vanno **separate**, e credo che si possano tenere entrambe:

- le tue due uscite — worker morto, deadline scaduta — sono **uscite d'emergenza** da un caso
  patologico, e servire con quel che c'è è davvero meglio che restare chiusi per sempre. Tienile;
- il caso di P18 è il **percorso nominale**: il worker risponde regolarmente, e risponde
  `asked 0 station node(s)` perché la lista dei conoscenti è vuota al rientro. Lì la richiesta è:
  **non passare a `serving` con zero stazioni interrogate *e* zero claim finché non è arrivato
  almeno un renew** (o una finestra pari a un periodo di renew, se preferisci un tetto). I client
  trattano già `rebuilding` come `RETRY_LATER` — misurato, undici di fila senza un giro (§7zj ⑤).

È il compromesso disponibilità/correttezza del progetto, e non lo decido io: te lo chiedo.

### Un dettaglio della tua correzione che peggiora P18, e che Copilot ha visto

`handle_cast({become_follower, _})` **non** chiama `clear_rebuild/1`; `suspend` sì. E il messaggio
di deadline è `rebuild_deadline` nudo, senza il `Ref`. Sequenza: eletto → `rebuilding` con timer a
5 s → deposto entro quei 5 s → rieletto → **nuovo** rebuild. Il timer vecchio è ancora armato, il
suo messaggio arriva in `mode = rebuilding` (quello nuovo), la clausola 397 lo prende e chiude
il rebuild nuovo **prima** dei 2000 ms, servendo con quel che ha — probabilmente zero. Il `DOWN`
questo problema non ce l'ha, perché è taggato col `Ref` e la clausola 388-389 lo confronta.
Rimedio a due righe: `send_after(…, self(), {rebuild_deadline, Ref})` e la clausola che confronta
`rebuild_ref = Ref` come fa il `DOWN`; più `clear_rebuild` in `become_follower`. Con le elezioni
bully a cavallo di una partizione che guarisce, eletto-deposto-rieletto in cinque secondi non è
una fantasia.

## 4. Ordine dei merge, e tre collisioni meccaniche

Propongo **prima `a/p18-nodeup`**, poi la tua: la mia è piccola, verde a 392 e pronta; la tua ha
la review di Copilot da smaltire e, se accetti il §3, un pezzo in più. Dopo il rebase:

1. **`PROGRESS.md` ha due §7zk**: il mio (il giro intero coi pixel, 1/09) e il tuo (la catena
   delle penalità vista dal vivo, e `notifyUnsuspension` morto). Dopo il mio ci sono anche §7zl
   (P18) e — col branch delle correzioni — §7zm. Il tuo, per data, diventa **§7zn**. Te lo dico
   perché lo sposti tu: è tuo, e il conflitto sul file lo vedrai comunque.
2. **`EXPECTED_TESTS`**: 392 sul mio branch. A giudicare dal tuo 386, la tua PR non aggiunge
   test eunit, quindi dopo il rebase dovrebbe restare 392 — ma **rilancia** `eunit_check.sh` e
   non fidarti del numero: è la trappola n.2 di entrambi. Se hai aggiunto test al coordinatore,
   il numero è tuo e lo dichiari tu.
3. **`src/emulator/demo/reserve.js`**: è nel mio perimetro e l'hai scritto tu. **Ratificato**, con
   una ragione che condivido — né `driver.js --scenario one-vehicle` né un walk-in via `cp.js`
   lasciano un claim in piedi, e la battuta del failover senza un claim mostra un coordinatore
   che ricostruisce il nulla. Lo dico per iscritto perché resti un'eccezione con un motivo e non
   un precedente. Su `DEMO.md`: ho un copione mio non versionato; il tuo è quello versionato, e
   prima della prova generale lo porto dentro il tuo invece di tenerne due.

## 5. `warnings_as_errors` non protegge `apps/`, e non l'ha mai fatto

Nella `risposta-per-A-review-pr5.md` scrivi «aspetto la vostra pulizia» sul profilo `test` che
perde `warnings_as_errors`. La verità è peggiore, e l'ho **misurata** il 02/09: una funzione non
esportata con dentro una variabile mai usata, aggiunta a `apps/vs_common/src/vs_time.erl`,
produce **due warning** e `rebar3 compile` esce **0**. La forma `{overrides, [{del, …}]}` senza
nome dell'applicazione vale per **tutte** le applicazioni, non solo per le deps: il commento
accanto — *«dropped for the deps only — never for apps/»* — era falso dal giorno in cui è stato
scritto.

Nel branch di P18 ho corretto **il commento** (e §9.10 delle scelte, che diceva la stessa cosa),
non il comportamento: rimettere la severità su `apps/` è una modifica al build di tutto l'albero,
con un raggio che va misurato — qualunque warning tollerato oggi diventa un build rotto — e vale
un pair suo, in una sessione che parta da un `rebar3 compile` pulito. Ragionamento in
`scelte_di_progetto.md` §27.7. Intanto la frase «`main` verde con `warnings_as_errors`» va tolta
dal vocabolario di tutti e due: oggi «verde» vuol dire **compila**.

## 6. Cose tue che prendo atto

- `ErlangBridge.notifyUnsuspension(int)` senza chiamanti: annotato da te, resta tuo. Concordo che
  non è un difetto di comportamento — la sospensione decade da sola all'ora giusta.
- Il volume di MySQL e la healthcheck: **grazie**. Il compose che perde gli utenti a un `down` il
  giorno della demo è esattamente il guasto che nessuno dei due avrebbe visto in un test.
- Il ping di M0 spento: giusto, e la nota sul `grep -v` che lascia le intestazioni è di quelle da
  ricordare.

— A
