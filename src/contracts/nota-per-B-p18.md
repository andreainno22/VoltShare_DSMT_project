# Nota per B — P18: la nostra metà è fatta, la tua è una decisione da prendere insieme (2 settembre)

Questa nota **chiede una decisione**, e non è una richiesta di correzione: il difetto sta nel
rapporto fra due numeri, non in un errore di nessuno dei due lati, e la direzione che
raccomandiamo costa disponibilità. È materia da orale per entrambi, quindi va decisa in due.

Nessun file condiviso toccato: né `claim.md`, né `erlang-java.md`, né `jwt.md`, né `schema.sql`,
e **nemmeno una riga** sotto `src/erlang/apps/vs_coord/` o `src/backoffice/`. Branch
`a/p18-nodeup`.

---

## 1. Che cos'è P18, con i log di una corsa sola

Misurato l'1/09 (pair 2 di M3-A) e riprodotto oggi al primo colpo. `vs@coord3` è il leader, viene
partizionato con `docker network disconnect`, `vs@coord2` prende la corona e adotta i due claim
di station1 in 1,67 s. Poi coord3 rientra:

```
host      14:05:42.511   docker network connect voltshare_voltshare coord3
coord2    14:05:42.903   election: following vs@coord3
coord3    14:05:42.904   coordinator vs@coord3 elected: rebuilding before serving
coord3    14:05:42.904   rebuild: asked 0 station node(s), waiting up to 2000 ms
coord3    14:05:44.821   rebuild: 0 station(s) answered with 0 claim(s) in total
coord3    14:05:44.821   coordinator vs@coord3 serving with 0 adopted claim(s)   <-- la finestra si apre
osserv.   14:05:48.932   i claim di station1 compaiono nella tabella di coord3   <-- si chiude, 4,11 s dopo
coord3    14:06:08.671   station 1 announced from vs@station1
```

In quei secondi il connettore 3 di station1 stava **caricando** il veicolo 88 con un claim vivo.
L'1/09, con la stessa scena, un conducente ha chiesto una prenotazione dentro la finestra e
station2 gliel'ha **concessa**: stesso veicolo, due prenotazioni, due stazioni — l'invariante di
`SCOPE.md` §4, per **13,65 s**, finché il primo renew di station1 non ha ripresentato il claim
più vecchio e «oldest wins» ha revocato il nuovo.

## 2. Perché è la **taratura**, e non l'uno o l'altro numero

`vs_coord_rebuild` conosce il pericolo e lo scrive per esteso:

> *Zero answers is when we know least, so that is the one case that waits out the full window —
> the stations reconnect and renew during it, and adoption catches what the query could not
> reach.*

La difesa è giusta come idea e sbagliata come misura: aspetta `COORD_REBUILD_TIMEOUT_MS` = **2000
ms** contando sui renew, ma il periodo di renew è `CLAIM_RENEW_INTERVAL_MS` = **10 000 ms**. La
finestra copre al più **un quinto** di un ciclo, e la fase è uniforme: nelle tre corse misurate i
claim sono rientrati dopo **5,40 s**, **13,9 s** e **4,11 s**.

**Nessuno dei due numeri è sbagliato da solo.** 2000 ms è tarato sul *rilevamento* del guasto,
che il tuo heartbeat fa benissimo in ~2,3 s; 10 000 ms è tarato sul costo del traffico di renew a
regime. Il difetto è che il primo viene usato per difendersi dal secondo. Alzare il 2000 a 10 000
sposta lo stesso errore più in là e costa dieci secondi di cecità a **ogni** rientro, anche a
quelli in cui nessuno tiene niente — per questo non è la strada che ti proponiamo.

## 3. `station_nodes/0` misura i conoscenti, non le stazioni

```erlang
station_nodes() ->
    Coords = lists:usort([node() | vs_env:get_nodes("COORD_NODES", [])]),
    [N || N <- nodes(), not lists:member(N, Coords)].
```

`asked 0 station node(s)` **non** vuol dire «le stazioni non rispondono»: vuol dire «in questo
istante non conosco nessuno che non sia un coordinatore». Un leader che rientra da una partizione
ha avuto le connessioni dist smontate e non le ha ancora ristabilite quando si elegge — e si
elegge **subito**, perché il tuo heartbeat riconnette prima i coordinatori fra loro (1 s) di
quanto la mesh si ricucia verso le stazioni. La riga dice che la domanda non è partita, non che
non ha avuto risposta, e le due cose meritano parole diverse in un log.

**Una correzione a quello che la scheda P18 dava per scontato**, misurata oggi in tre corse: le
connessioni non cadono *sempre* al `net_ticktime`. station1 ha visto sparire coord3 dopo
**47,0 s**, **54,4 s** e **62,7 s**. Nelle prime due, nello stesso millisecondo, coord1 e coord2
scrivevano `'global' … requested disconnect from node vs@coord3 in order to prevent overlapping
partitions` e il tick è arrivato solo 15 s più tardi; nella terza non c'è nessuna riga di
`global` ed è stato il tick (dentro la forchetta `[60, 75]` di `net_ticktime = 60`).

Quindi: **fra i 47 e i 63 secondi, a volte per mano di `global` e a volte del tick.** Per te la
conseguenza è una sola e vale in entrambi i casi: il punto cieco di `station_nodes/0` si apre
**prima** di quanto la scheda supponesse — non serve una partizione più lunga del ticktime.

## 4. Che cosa abbiamo fatto noi, e di quanto è servito

Il meccanismo di ripresentazione **esisteva già ed era corretto**: il `renew_tick` manda il batch
di *tutti* i claim col `granted_at` originale, `try_nodes/4` segue il redirect `not_serving`, e il
tuo `renew_one/4` adotta un claim sconosciuto conservando l'ordinamento. Mancava il **momento**:
la stazione aspettava un orologio per dire una cosa che sapeva già.

Adesso `vs_claim_client` fa `net_kernel:monitor_nodes(true)` e, quando un nodo **in
`COORD_NODES`** torna su, si riannuncia e fa **subito** un giro di renew — gli stessi due
messaggi di prima, mandati prima. Un debounce di 1 s (misurato: una riformazione di mesh sono
quattro `nodeup` in 271 ms) evita di ripeterlo tre volte. Il tick periodico **non è stato
toccato**: nessun `send_after` cancellato o rischedulato, il giro immediato è *in più*.

Quanto arriva presto, misurato sulla stessa scena: il `{nodeup, vs@coord3}` raggiunge station1
**959 ms** dopo il `docker network connect`, cioè **342 ms dentro** la tua finestra di
ricostruzione e **1,7 s prima** che tu cominci a servire.

**Risultato E2E, prima e dopo, corse singole:**

| | finestra di esposizione | la tua riga | `stations` quando cominci a servire |
|---|---|---|---|
| prima | **4,11 s** | `serving with 0 adopted claim(s)` | `[]`, e per altri 19,7 s |
| dopo | **0 ms** | `serving with 2 adopted claim(s)` | `[1,2]`, 1,74 s prima |

La corsa «dopo», per esteso, perché il dettaglio conta:

```
host      14:49:18.360   docker network connect voltshare_voltshare coord3
coord3    14:49:18.754   rebuild: asked 0 station node(s), waiting up to 2000 ms
station1  14:49:19.017   {nodeup, vs@coord3}                              (+657 ms)
station1  14:49:19.018   claim client: coordinator vs@coord3 is back — re-announcing
                         and renewing 2 claim(s) now
coord3    14:49:19.019   station 1 announced from vs@station1
osserv.   14:49:20.003   coord3: mode=rebuilding, vehicles=[88,201], stations=[1,2]
coord3    14:49:20.756   rebuild: 0 station(s) answered with 0 claim(s) in total
coord3    14:49:20.756   coordinator vs@coord3 serving with 2 adopted claim(s)
```

**Nota bene: la tua strada non è cambiata.** `asked 0 station node(s) … 0 station(s) answered
with 0 claim(s)` è identica a prima — il `who_do_you_hold` ha continuato a non trovare nessuno.
I due claim sono entrati dal **renew**, adottati da `renew_one/4` mentre eri ancora
`rebuilding`, ed è per questo che la riga finale dice 2: `Count` è `maps:size(claims)` **dopo**
la piega delle risposte, quindi include ciò che è arrivato durante la finestra. Non abbiamo
toccato niente di tuo: abbiamo riempito la finestra che la tua strada lasciava vuota.

## 5. Due cose che abbiamo scoperto leggendo il tuo lato, e che ti riguardano

Le riportiamo come osservazioni, non come richieste.

**(a) L'adozione riempie `claims`, mai `stations`.** `do_renew/3` non consulta `stations` affatto
(nessuna guardia nemmeno su `rebuilding`, che è la ragione per cui il nostro renew immediato
funziona: arriva *durante* la ricostruzione e viene adottato). Ma `renew_one/4` scrive in
`claims` e `by_id`, e solo `do_station_up/8` popola `stations`. Nella corsa «prima» qui sopra si
vede il costo: coord3 ha servito con **due claim adottati e `stations = []` per altri 19,7 s**,
fino all'`announce_tick` da 30 s — e in quella finestra una `acquire` di station1 sarebbe stata
rifiutata `unknown_station`, che noi mappiamo su `RETRY_LATER`. Il nostro riannuncio sul `nodeup`
chiude anche questo, ma volevamo che lo sapessi: adottare un claim non è conoscere la stazione.

**(b) Il log del rebuild.** `asked 0 station node(s)` è l'unica riga che distingue «non ho
chiesto» da «ho chiesto e nessuno ha risposto», ed è facilissima da leggere al contrario. Se
tocchi quel punto, vale una parola in più.

## 6. Quello che chiediamo, e il suo costo onesto

**La nostra metà accorcia la finestra, non la chiude, e questa nota non finge il contrario.** Il
nostro renew batte i tuoi 2000 ms di ~1,7 s: è un margine buono, ma è una **gara**. Se coord2 non
avesse ancora abdicato quando il nostro renew gli arriva, lui lo rinnoverebbe per conto suo e tu
passeresti a `serving` a tabella vuota lo stesso. E se il coordinatore serve a tabella vuota
*prima* che chiunque abbia potuto parlargli, nessuna prontezza del nostro lato arriva in tempo.

Quindi la raccomandazione, che è la seconda delle due direzioni già scritte nella scheda:

> **non passare a `serving` con zero risposte *e* zero claim finché non è arrivato almeno un
> renew.** Restare `rebuilding`.

Perché questa e non l'altra:

- **i client la trattano già bene.** `map_refusal(rebuilding) -> retry_later`, e non è teoria:
  durante una finestra di rebuild abbiamo misurato **undici rifiuti `RETRY_LATER` di fila** su
  1,85 s, seguiti dalla concessione appena hai finito (§5 di `REPORT_M3A_CODA.md`). Il conducente
  ha visto un ritardo, non un errore;
- **è la risposta onesta.** Il coordinatore non sa chi tiene cosa, e dirlo è meglio che
  indovinare. `serving` con la tabella vuota è un'affermazione di conoscenza che non hai;
- **con la nostra metà la tua attesa è breve.** Se le stazioni parlano appena il nodo torna, il
  «finché non arriva un renew» si risolve in **centinaia di millisecondi**, non in secondi: oggi
  il nostro renew arriverebbe 342 ms dopo l'apertura della tua finestra.

**Il costo, detto per intero:** qualche rifiuto temporaneo in più a ogni rientro *cieco*, cioè
ogni volta che ti eleggi senza vedere nessuna stazione. Se in quel momento nessuna stazione tiene
niente e nessuno chiede una prenotazione, non lo nota nessuno; se qualcuno chiede, prende
`RETRY_LATER` invece di un `ok` — e finché non arriva un renew quell'`ok` sarebbe stato un `ok`
dato al buio. C'è anche un caso in cui l'attesa non finisce da sé: una rete in cui *davvero*
nessuna stazione tiene claim non produrrà mai il renew che sblocca. Serve un tetto — il tuo
`COORD_REBUILD_TIMEOUT_MS` esteso, o un secondo timeout dichiarato — e quale sia è parte di ciò
che c'è da decidere.

**Decidiamo insieme.** È il compromesso disponibilità/correttezza del progetto: una prenotazione
concessa e poi revocata (oggi) contro qualche prenotazione rimandata di qualche centinaio di
millisecondi (dopo). Noi pendiamo per il secondo, ma non è una scelta che uno dei due possa fare
per l'altro.

---

*Riferimenti verificati oggi in sola lettura su `vs_coord_srv.erl`: `unknown_station` solo in
`check_can_grant/4` (`:432`), sul percorso `acquire`; `do_renew/3` (`:472-486`) senza guardia su
`stations` né su `rebuilding`; `renew_one/4` clausola `error ->` (`:524-538`) che adotta col
`granted_at` riportato; `{rebuilt, Holds}` (`:365-370`) che conta `maps:size(claims)`, quindi
include ciò che è stato adottato durante la finestra. `vs_coord_rebuild.erl:68-71` e `:104-113`.*
