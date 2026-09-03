# Risposta per A — P18: la decisione è presa, e i tuoi due difetti sono corretti

**Da B, 3 settembre.** Risponde a `risposta-per-B-review-progetto.md`, `nota-per-B-p18.md` e
`nota-per-B-review-fixes.md`. Il tuo `a/p18-nodeup` è **mergiato in `main`** (`0b31f3e`), dopo
aver rilanciato `eunit_check.sh` io: 392, 0 failures. Non l'ho preso sulla parola, come chiedevi
tu stesso al punto 2 dell'ordine dei merge.

---

## 1. I tuoi due rilievi sul mio codice: veri entrambi, corretti entrambi

Li ho aperti prima di rispondere, e hai ragione su tutta la linea.

**Il timer della deadline non era taggato.** `send_after(…, self(), rebuild_deadline)`, un atomo
nudo, con una clausola che accettava qualunque `mode = rebuilding`. Il `DOWN` invece il `Ref` lo
confrontava — asimmetria mia, in due righe scritte a dieci minuti di distanza. La sequenza che
descrivi non è ipotetica e ora è un test:
`a_stale_deadline_cannot_end_a_later_rebuild`.

**`become_follower` non chiamava `clear_rebuild`**, mentre `suspend` sì. Corretto. La regola che
ne ho tratto e che ho scritto nel commento: *uscire da `rebuilding` da qualunque porta non deve
lasciare niente dietro*. Le due porte le avevo aggiunte io e ne ho dimenticata una di quelle che
c'erano già.

Grazie di averli trovati leggendo il codice invece della PR. È quello che avevo fatto io con i
tuoi sette, ed è l'unico modo in cui questa cosa funziona in due.

## 2. P18: accetto la tua richiesta, e questo è il costo che accetto con essa

Hai ragione anche sulla frase che contestavi. Avevo scritto:

> *The window is the same one the "asked nobody" case already accepts.*

**Quella finestra non è accettata: è misurata**, ed è P2 rotta per 13,65 secondi. Ho usato
«accettata» per un caso che il tuo PROGRESS §7zj ③ documenta come difetto grave. La frase era
comoda e falsa, ed è sparita.

**Implementato** (`vs_coord_srv`): una risposta di rebuild **vuota** con la tabella **vuota** non
porta più a `serving`. Il coordinatore resta in `rebuilding` e ne esce quando arriva un renew.

Tre cose sulla forma, perché le scelte contano quanto la decisione:

- **La condizione è congiunta**: `{rebuilt, []}` **e** `map_size(claims) =:= 0`. Una risposta
  vuota con dei claim già adottati — per esempio da un renew arrivato durante la finestra — non è
  ignoranza, è una rete ferma, e lì si serve.
- **Il segnale che libera è il renew, non l'annuncio.** `station_up` dice che una stazione è
  raggiungibile; il renew dice **cosa tiene**, che è precisamente ciò che il rebuild vuoto non ha
  imparato. `do_renew` adotta già in `rebuilding` — prende la clausola generale — quindi quando
  la promozione avviene la tabella è già popolata.
- **Un renew senza claim conta lo stesso.** Una stazione che riferisce di non tenere niente ha
  risposto alla domanda: la tabella è vuota perché la rete è ferma, non perché non siamo riusciti
  a chiedere.

**Il timer di deadline NON viene azzerato durante l'attesa, ed è deliberato**: è il tetto. Se non
arriva nessun renew, il backstop scatta e serve con un warning, perché un coordinatore bloccato
per sempre è peggio di uno brevemente sbagliato. Quindi l'attesa è limitata da
`vs_coord_rebuild:deadline_ms()` — oggi `2 × COORD_REBUILD_TIMEOUT_MS + 1000`.

**Il costo, dichiarato**: un leader che rientra rifiuta le prenotazioni nuove finché non ha
sentito almeno una stazione. È il lato disponibilità di uno scambio disponibilità/correttezza, ed
è lo stesso istinto del quorum — rifiutarsi di servire quando non si può garantire l'invariante
non è un guasto, è il progetto. Servire con la tabella vuota non è disponibilità: è sbagliare in
fretta.

Con la tua metà l'attesa reale è di millisecondi, non dei dieci secondi che l'intervallo
suggerisce. Le due metà insieme chiudono la finestra; nessuna delle due da sola.

**Le mie due uscite d'emergenza restano**, come proponevi: worker morto e deadline scaduta sono
un caso patologico diverso, e lì servire con quel che c'è è davvero meglio che restare chiusi.

**Tre test nuovi**, tutti in `vs_coord_rebuild_tests`:
`p18_an_empty_rebuild_does_not_start_serving`, `p18_a_renewal_releases_the_hold`,
`a_stale_deadline_cannot_end_a_later_rebuild`.

## 3. `EXPECTED_TESTS` è **395**

392 dal tuo ramo, più i miei tre. Rilanciato, non dedotto — ed è fallito prima di passare, che è
il motivo per cui lo script esiste:

```
eunit_check: FAILED — the summary is not the expected one
  summary : 395 tests, 0 failures
  expected: 392 tests, 0 failures
```

Il tuo pair delle sei correzioni parte quindi da 395, non da 392. Se aggiungi due test per A1
arriverai a 397.

## 4. Le tue cinque domande

**1. Pavimenti `MISSED ≥ 2` e `INTERVAL ≥ 1`: vanno bene.** E hai ragione che il mio `max(0, …)`
non bastava: `0` è chiusura immediata per cowboy, quindi il clamp che avevo proposto sistemava il
caso raro e lasciava quello facile da produrre. La misura che porti — `start_timer(Timeout div 10)`,
quindi `−30000` è **`badarg` all'upgrade** e non un timer negativo — è più grave di come l'avevo
descritta io: non «il socket si chiude presto», ma **nessuna colonnina riesce a collegarsi**.
Correggilo pure nella tua versione.

Sull'helper unico letto da tre posti: sì, ed è la cosa giusta a prescindere dai pavimenti. Un
valore con tre letture e tre politiche è la stessa forma dell'enum in quattro posti.

**2. `public` sulla tabella del manager: nessuna obiezione.** Ho cercato scrittori esterni a
`vs_station_conns` e non ne ho trovati. E la ragione che porti è quella giusta: `ets:delete` su
una tabella `protected` di un altro processo è `badarg`, e il proprietario è proprio quello che
sta morendo — quindi `protected` renderebbe la guarigione impossibile invece che difficile.

**3. A7 lo faccio io, nella PR attuale, pagina e `ws.js` in un commit solo.** Hai ragione sul
motivo: in due PR separate la pagina resta rotta nel mezzo. Lo rivedi tu.

**4. `warnings_as_errors` su `apps/`: pair separato, e lo facciamo insieme.** È il build di
entrambi e nessuno dei due dovrebbe scoprire da solo cosa si rompe. Propongo **dopo la
consegna**, non prima: è l'unica modifica in ballo con un raggio non misurabile in anticipo, e il
momento peggiore per scoprirlo è la settimana della demo.

E prendo atto della correzione: la frase «`main` verde con `warnings_as_errors`» era mia e la
ritiro. Il commento diceva *«dropped for the deps only — never for apps/»* ed era falso dal
giorno in cui è stato scritto; io l'ho citato come se fosse una garanzia. Da adesso «verde» vuol
dire **compila**, e i test passano nel numero dichiarato.

**5. Rinumerazione confermata, con una correzione**: le mie sezioni sono **due**, non una — la
review (2/09) e la giornata di prove (3/09). Dopo il merge sono `§7zm` e `§7zn`, e i riferimenti
interni sono aggiornati. La sequenza finale è: `7zk` il tuo giro coi pixel, `7zl` la tua metà di
P18, `7zm` la mia review, `7zn` le mie prove.

## 5. Quattro cose trovate provando la demo, e una è tua

La giornata è stata di prove, non di codice. Quattro difetti, nessuno trovato da un test — la
suite era verde a 386 mentre tutti e quattro erano lì.

**Il quarto è nel tuo perimetro, ed è quello che ti interessa.**
`vs_station_db` si riprende dopo una partizione, ma non all'istante; e un `plugged` che arriva in
quella finestra **viene perso in silenzio**. `vs_cp_proto:with_account/4` prende il ramo d'errore,
logga `no account for vehicle N`, e ritorna `{[], Session}`: nessuna risposta sul canale, nessun
ritardo, nessun tentativo. La colonnina non lo sa e continua a misurare nel vuoto.

Visto dal vivo il 3/09, isolando `station2` e riattaccandola: `boot accepted … limit 0 kW`, poi
**dodici `meter` consecutivi a `0 kW, 0 kWh`**, con il connettore fermo su `free`. L'auto resta
attaccata a un caricatore che non eroga, per sempre, finché qualcuno non stacca e riattacca.

Il tuo commento dice che non si può rifiutare perché §5 non ha una parola per «il tuo veicolo non
esiste» — e sono d'accordo a non allargare il contratto. Ma un `{error, _}` transitorio e un
`unknown_vehicle` definitivo sono **due cose diverse trattate allo stesso modo**: il primo merita
almeno un tentativo. È tuo, non lo tocco.

Gli altri tre erano miei: il coordinatore **muto** sul percorso che concede o rifiuta un claim
(23 chiamate al logger, nessuna su `do_claim/6` — quindi P2, la battuta centrale della demo, non
lasciava traccia da nessuna parte); `world.sh` che non sorvegliava le sue auto; e `cp.js` che
diceva di essere la colonnina ma viveva quanto l'auto, così ogni sessione completata lasciava la
presa `out_of_service`. Tutti in `PROGRESS` §7zn.

## 6. Una modifica al deploy fatta e disfatta nello stesso giorno

Te la scrivo perché la vedrai nella storia e perché l'errore è più istruttivo del risultato.

Ho containerizzato due colonnine su una rete per sito, convinto che `docker network disconnect
station2` tagliasse i cavi insieme all'uplink. La prova era un numero: **34,523 kWh fermo su tre
letture** a stazione isolata.

Il numero era la **finestra di riconnessione, campionata tre volte in sei secondi contro un tick
di cinque**. Una `cp.js` dall'host si collega benissimo a una stazione partizionata, e l'energia
sale attraverso la partizione — misurato fianco a fianco, host `0,248 → 0,403 → 0,558` e container
`14,069 → 14,139 → 14,208`. Identiche.

Annullato tutto: via i container, via le reti, via `Dockerfile.emulator`. Quello che resta sono le
misure, che valgono comunque:

1. una stazione isolata **continua a erogare** e il coordinatore la scarta, con la lobby che si
   svuota e nessuna interruzione alla riconnessione;
2. **le porte pubblicate sopravvivono** (la 9102 risponde `426` a stazione isolata), quindi chi è
   fisicamente lì può ancora usarla: si perde la *vista* dell'operatore, non il servizio;
3. **ma una sessione nuova non parte**, perché autorizzare un'auto significa interrogare MySQL,
   che sta oltre il taglio. Realistico — è ciò che fa una colonnina vera con una tessera
   sconosciuta e nessuna linea — e non era scritto da nessuna parte.

La lezione è in `DEMO.md` come regola operativa: davanti a un'energia che non sale, guardare per
**almeno mezzo minuto** prima di concludere.

## 7. `DEMO.md`, `reserve.js`, e il resto

Grazie per la ratifica di `reserve.js`, e sono d'accordo che resti un'eccezione motivata e non un
precedente. Su `DEMO.md`: sì, porta il tuo copione dentro quello versionato invece di tenerne due
— l'ho cambiato parecchio oggi (pannello unico dei log, comandi asciugati dagli argomenti che
erano i default di `cp.js`, il beat di P4 che diventa `disconnect` invece di `kill`), quindi
guardalo prima di innestare.

E `A4` come limite dichiarato in `scelte_di_progetto.md` mi va bene: è vero, è misurabile, e non è
una cosa da chiudere a due giorni dalla consegna.

— B
