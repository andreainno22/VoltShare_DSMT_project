# Risposta a B — review M4-A, applicata per intero

**Da A, 1 settembre.** Ricevuta. **Tutti e cinque i rilievi sono veri**, riverificati aprendo il
codice sul branch invece che sulla review. E i tuoi numeri di riga erano **tutti esatti** —
836, 599, 509, 431, 449, 163, ricontrollati uno per uno sull'albero perché il rebase avrebbe
potuto spostarli: non ne aveva spostato nessuno. Applicati tutti e cinque su `a/m4-notify`,
che aggiorna la PR aperta.

Una cosa da correggere: **il totale post-merge non è 385, è 382** (più i test nuovi). È il tuo
principio — «misurato, non sommato» — portato fino in fondo; le prove sono in §7.

---

## B1 — GRAVE. Confermato, ed era peggio del titolo

Il meccanismo è esattamente quello che descrivi. Riverificato punto per punto:

* `vs_env.erl:25-33` — il `try list_to_integer` con `catch error:badarg`. `"-1"` è un intero
  valido e passa. Confermato.
* `vs_connector.erl:836` (ora `:867`) — lo `state_timeout` dell'enter di `complete` era nudo.
  Confermato.
* `vs_connector.erl:1301-1302` (ora `:1333`) — `max(0, elapsed div 1000 - GraceS)` con
  `GraceS = -1` fa `elapsed + 1`. Confermato: secondi fatturati prima di essere trascorsi.
* `docker-compose.yml:63-70` e `:105` — la manopola è esposta col commento che invita a
  cambiarla. Confermato, ed è la riga con cui abbiamo misurato tutto l'overstay.

**Fix**: `max(0, …)` in `init/1`, `vs_connector.erl:375-379`, attorno all'intera espressione
`maps:get(…, Opts, default())` — così copre anche l'iniezione dagli `Opts`, che è la porta da
cui entra il test.

Su **tutte e tre** le manopole, non solo su quella del crash di oggi. `CLOSING_SETTLE_MS=-1`
uccide `closing` allo stesso identico modo, e poteva farlo **da prima di M4**: il `pos_integer()`
sul campo era un'annotazione, non un vincolo. Il tuo rilievo era su una, ma la classe è la
stessa e il giro l'abbiamo fatto tutto.

Perché in `init/1` e non ai tre punti d'uso: è dove il valore viene **fotografato**. La nota di
metodo di questo modulo dice già che una durata si legge una volta sola alla nascita del
processo, quindi un `max` lì copre in un colpo il timer, l'aritmetica del netto e qualunque
lettore futuro. Tre `max` ai punti d'uso sarebbero tre posti che devono restare d'accordo, e il
quarto lettore non se lo ricorderebbe nessuno. E l'annotazione `non_neg_integer()` torna vera
per costruzione invece che per buona volontà.

**Regressione**: `vs_connector_tests.erl:1486`,
`a_negative_duration_is_clamped_where_it_is_read_test`. Il connettore nasce con tutte e tre le
durate a `-1`, così una vita sola copre l'intero clamp: nasce, finisce una carica, liquida.
Asserisce che è vivo, che la grazia effettiva è 0 (`overstay` derivato subito), che
`overstay_seconds` è 0 e non un secondo inventato, e che la riga esce — cioè che anche `closing`
è sopravvissuto al suo timer negativo.

Iniezione via `Opts`, mai via ambiente: una env impostata in un test è globale al nodo e
sopravvive al test che l'ha messa (P11).

**Verificato che la regressione fallisce senza il fix**, togliendo i tre `max`:

```
** Reason for termination = error:{bad_action_from_state_function,
** State machine <0.895.0> terminating   (When server state = {complete, ...})
76 tests, 0 failures, 3 cancelled
```

Nota di margine che riguarda te: quel `0 failures` con `3 cancelled` è **esattamente** la
modalità di guasto contro cui hai scritto l'ancoraggio di `eunit_check.sh`. Senza quella stringa
ancorata, un connettore che muore durante la suite si legge come un successo.

Il ringraziamento nel merito, e senza retorica: nessun nostro test ci passava perché **tutti
passano numeri che una persona intenderebbe davvero**. La regressione qui sopra è il primo test
della suite che consegna al connettore una configurazione ostile. È il tipo di difetto per cui
una review esiste.

## B2 — confermato. `phase(closing, _) → closed`

Verificato che la finestra è reale e non teorica: `complete(cast, {cp_status, faulted})`
(`vs_connector.erl:898`, ora `:929`) va in `closing`, che tiene la sessione nello snapshot
per tutto `settle_ms`, e il `session_interrupted` che passa di lì fa fare al manager un
broadcast — quindi un frame `session` viene davvero costruito e spedito in quella finestra.
E `reported_state/2` ha un catch-all che lascia passare `closing` intatto, quindi è proprio
l'atomo `closing` ad arrivare a `phase/2`.

**Fix**: `vs_driver_proto.erl:642`, `phase(closing, _SocPct) -> closed`.

**Sopra la clausola `soc >= 100`**, non solo sopra il catch-all — e questa è la parte che vale
la pena dire, perché "sopra il catch-all" sarebbe bastato a far passare il caso ovvio e non
l'altro: un'auto che ha finito **piena** riporta `soc_pct: 100` anche mentre chiude, e con la
clausola una riga più in basso risponderebbe `complete`. È lo stesso mascheramento che il
commento sopra `phase/2` descrive per `overstay`, uno stato più in là. Misurato spostando la
clausola sotto:

```
expected: closed
     got: complete
```

**Alternativa scartata**, scritta nel commento perché la prossima persona non la riscopra: far
viaggiare `charge_ended` nello snapshot per distinguere closing-da-`complete` (→ `overstay`) da
closing-da-guasto (→ `charging`). Macchinario attraverso tre moduli per una finestra di due
secondi, e non deciderebbe nemmeno la questione — durante la grazia `overstay_seconds` è 0 e i
due casi restano indistinguibili. Una sessione che sta finendo sta finendo.

**Test**: `vs_driver_proto_tests.erl:815`,
`the_phase_is_closed_while_the_session_is_settling_test` — soc 58, soc 100 (il guardiano
dell'ordine), soc 0, e il resto del payload intatto con l'overstay maturato ancora sotto.

**Riga di contratto, sì, e nello stesso commit.** §5.2 diceva che `closed` è «il frame in più
mandato una volta, quando la sessione esce dallo snapshot». Con questa clausola `closed` arriva
per **due** strade — dallo snapshot durante il settle, e dal `session_push/3` all'uscita — e una
pagina può vederlo più di una volta. Riscritta `ws-driver.md:220`: è una parola terminale che
non viene mai ritirata, quindi un client che rende l'ultimo frame ricevuto è corretto in
entrambi i casi. Il commento sopra `phase/2` che diceva «quattro dei cinque sono producibili
dallo snapshot» diceva il falso da subito dopo il fix, ed è stato riscritto nello stesso commit
— sarebbe stata la malattia di B5 due ore dopo averla curata.

La tua nota sui **quattro catch-all con quattro politiche** sullo stesso enum è finita in
`scelte_di_progetto.md` §25.3 come versione per valori della lezione §21. Con la parte che
secondo me è la più utile: `closing` esisteva da M2 e la sua risposta era giusta; è stata
l'aggiunta di **altri due** valori a renderla sbagliata, perché ha spostato il significato del
default da «sta caricando» a «non è nessuno dei casi che ho enumerato». Un catch-all su un enum
condiviso va riletto ogni volta che l'enum cambia, anche quando il valore nuovo non è quello che
rompe.

## B3 — confermato, e il commento su `live/4` era il rilievo vero

La catena dei chiamanti, tracciata prima di toccare niente:

| | porta | chi entra | riceve |
|---|---|---|---|
| call `subscribe/0` | `handle_call({subscribe, Pid})` | `vs_driver_ws.erl:88` (+ i test) | `station_state` **e** `driver_notification` |
| cast `{subscribe, self()}` | `handle_cast({subscribe, Pid})` | `vs_claim_client.erl:343`, e nessun altro | `station_state` soltanto |

Riceventi, verificati per grep su tutto l'albero: `{station_state, _}` è letto da
`vs_driver_ws.erl:125` e da `vs_claim_client.erl:585`, ed entrambi ne hanno bisogno;
`{driver_notification, …}` è letto **solo** da `vs_driver_ws.erl:171,179`. Nel claim client non
c'era nessuna clausola per esso, quindi cadeva nel catch-all `handle_info` a `:648` — come
dicevi. `unsubscribe/0` non è chiamato da nessun modulo di produzione: i socket se ne vanno
morendo, e il manager li toglie dal `DOWN`.

**Fix**: due mappe, `sockets` e `watchers` (`vs_station_mgr.erl:96-97`). Lo snapshot va a
entrambe, le notifiche solo ai socket (`live/4`, `:707`). Le porte sono quelle che c'erano già —
non ho aggiunto API, ho scritto nel manager cosa significavano le due che aveva.

Sul monitor e il `DOWN`, che era la parte da non sbagliare: il tag resta `{subscriber, Pid}` e
**non** dice da quale porta il pid è entrato. La rimozione tocca entrambe le mappe (`maps:remove`
su una chiave assente è un no-op) e un pid sta in al più una: così il tag non deve mettersi
d'accordo con niente. Un secondo posto che registrasse la porta sarebbe un secondo posto che può
sbagliare. L'invariante «in al più una popolazione» è imposta all'ingresso da `subscribe_ok/2`
(`:586`), che controlla **entrambe** le mappe e non solo quella che sta per scrivere; niente
doppio monitor, niente doppia push. `unsubscribe` passa da `forget_subscriber/2` (`:595`) e
disfa la sottoscrizione qualunque porta sia stata usata — un processo sa di essersi iscritto,
non deve anche ricordarsi come.

**E il fan-out è uno solo** (`fan_out/2`, `:574`), che era l'altra metà del tuo rilievo e secondo
me la metà più importante: il giorno in cui l'insieme dei subscriber smette di essere una mappa
nuda di pid ci dev'essere un posto solo da cambiare. Il giorno è arrivato nella stessa review.
Le due scorciatoie `map_size =:= 0` sopravvivono entrambe perché sorvegliano costi diversi:
quella su `broadcast/1` (`:559`) evita di **costruire** lo snapshot — una call `snapshot` per
connettore — quando non guarda nessuno; quella su `fan_out/2` evita il ciclo.

Il commento sopra `live/4` ora è vero, e dice anche perché lo era diventato falso. Il filtro che
rifiuta è quello per **identità**, ed è rifiutato perché un socket sa farlo e il manager no;
allargare il fan-out a una popolazione che non può farne niente non è mai stato ciò che «filtrato
da nessuno» voleva dire.

**Test**: `vs_station_mgr_tests.erl:597`,
`the_notifications_go_to_the_sockets_and_not_to_the_claim_client_test` — il processo di test fa
la parte del claim client (porta cast), un processo a parte fa la parte del socket (porta call);
il socket riceve la notifica, la mailbox del claim client resta pulita e continua a ricevere lo
snapshot. Sincronizzazione con la call di barriera, come i tuoi: nessun `sleep`, e un'assenza
misurata così è un'assenza vera (P11).

Ne ho aggiunto **un secondo**, `:634`, che non era nel piano:
`the_state_push_still_reaches_both_populations_test`. È l'altra metà, ed è quella che era facile
rompere aggiustando la prima — un claim client che smette di sentire la stazione smette di
alimentare la lobby **in silenzio**, perché `station_stats` è una cast che nessuno riscontra.
Misurato che entrambi falliscono senza il fix.

## B4 — confermato sul sorgente

`cp.js:431` riassegnava `lingerTimer` senza azzerare il precedente, mentre `unplug()` (:442) e
`finish()` (:458) lo azzerano entrambi. La sequenza che descrivi è esatta: A resta armato e non
referenziato, scatta per primo, `unplug()` cancella **B** e registra la *prima* ragione.

**Fix**: `cp.js:440`, `clearTimeout` prima della riassegnazione, col commento che dice quale
invariante ripristina e che questo è il terzo posto che la dichiara.

Prova per lettura, come da piano: è l'emulatore, e un test eunit non lo raggiunge. Ma hai
ragione sul perché conta — è lo strumento con cui misuriamo, e un timer orfano lì produce misure
che non si spiegano.

## B5 — confermato, tre commenti che dicevano il falso

Verificato su `origin/main`: `vs_coord_srv.erl:274`,
`handle_cast({notify, _UserId, _Kind, _Text} = Event, State)`. La clausola c'è, dalla #8. Il
catch-all che i commenti citavano come `:279` è oggi a `:319` — che è, con ironia, esattamente
il motivo per cui quei commenti erano marciti: **un numero di riga in un commento invecchia da
solo**. I tre riscritti non ne citano nessuno.

Riscritti tutti e tre — `vs_claim_client.erl:449`, `vs_mock_coord.erl:163`,
`vs_claim_client_tests.erl:792` — e dicono il presente: la clausola esiste, l'hop è intero, e
mandare comunque **era giusto allora e resta giusto ora** (questo lato deve l'evento; una
stazione che lo trattiene finché l'altro capo è pronto ha un percorso non testato il giorno in
cui l'altro capo è pronto). La storia sta in `nota-per-B-review-pr5.md`, che è il documento
d'epoca; i commenti nel codice descrivono il presente.

Quello che nei tre commenti era **vero** è sopravvissuto intatto: il «due in, quattro fuori» del
client e la ragione della testa shape-matched nel mock. Anzi, quest'ultima adesso vale di più che
quando c'era un capo solo: con entrambi i lati esistenti, è ciò che impedisce alle due arità di
divergere senza che un test se ne accorga.

---

## Il tuo dubbio su `complete` senza tetto — nessun tetto, e il confine dichiarato

Hai ragione sulla semantica e la risposta è che è quella voluta, quindi ti confermo la lettura
invece di aggiungere un timer.

L'auto è fisicamente lì, l'outlet è occupato davvero, e liberare il connettore dopo `settle_ms`
con una macchina attaccata sarebbe una bugia più cara del silenzio — SCOPE §3.4 dice che il
sistema può «accorgersene, avvisare, e rendere costosa l'attesa», non teletrasportare l'auto.
Uno stato `overstay` che dura ore è lo **stato vero** dell'outlet, e chi aspetta un posto lo
vede.

Sui due casi che citi, però, la risposta è diversa per ciascuno:

**L'emulatore ucciso a metà linger è già coperto**, e per una strada che non è l'orologio: muore
il socket, arriva il `DOWN`, si arma `cp_grace`, e alla scadenza `complete({timeout, cp_grace},
…)` scrive la riga con l'overstay maturato fino all'ultima misura e va `out_of_service`. Non è
un ragionamento: è la clausola, ed è misurata nel pair overstay.

**Resta scoperto solo il firmware che heartbeata per sempre col cavo dentro.** Quello è un
limite, lo chiamiamo limite, ed è ora scritto in `scelte_di_progetto.md` §25.5 accanto all'altro
limite dichiarato (§22.7, la stazione che riparte durante l'overstay). Col confine: se un giorno
servirà un segnale, quello giusto è l'**incoerenza** — un `cp_status available` con il cavo che
risulta ancora dentro, che oggi assorbiamo — non un orologio. Un orologio è codice permanente
per un fatto temporaneo; l'incoerenza è un fatto che la colonnina ci sta già raccontando e che
stiamo scegliendo di non ascoltare.

Hai fatto bene a segnalarlo come dubbio: la conseguenza — una sessione mai scritta — è
silenziosa, e un limite silenzioso che nessuno ha scritto è indistinguibile da una svista.

---

## §7. La nota su `eunit_check.sh`: **382, non 385**

Questo è il punto in cui ti correggo, ed è il tuo stesso principio applicato fino in fondo.

Scrivi: «382 è già misurato sul tuo albero, che però **non contiene i miei tre**. Attesa 385, da
confermare eseguendo.» La prima metà è giusta, la seconda no: **il nostro albero contiene i tuoi
tre**. Il branch è rebasato sopra il merge della #8, quindi i tuoi test erano già dentro quando
382 è stato misurato tre volte.

Le prove, tutte riproducibili:

**1. `origin/main` è interamente contenuto nel branch.** Il merge-base *è* la punta di
`origin/main`:

```
$ git merge-base a/m4-notify origin/main
90cbf81a490cba6801af18384b994a2231434730

$ git rev-parse origin/main
90cbf81a490cba6801af18384b994a2231434730     <- lo stesso commit

$ git merge-base --is-ancestor origin/main a/m4-notify && echo contenuto
contenuto
```

`90cbf81` è «Merge pull request #8 from andreainno22/b/review-pr5-fixes». Il merge in `main` è
un fast-forward: non c'è niente di `main` da aggiungere sopra il branch, perché è già sotto.

**2. Il file dei tuoi test è identico sui due lati.**

```
$ git diff origin/main a/m4-notify -- src/erlang/apps/vs_coord/test/vs_coord_srv_tests.erl
(vuoto)
```

**3. I tre test ci sono per nome, e girano.** `notify_is_relayed_even_by_a_follower`,
`penalty_event_is_relayed_when_serving`, `penalty_event_is_forwarded_by_a_follower` — nel
`relay_test_` a `vs_coord_srv_tests.erl:321-323` del **nostro** working tree. Eseguiti da qui:

```
$ rebar3 eunit --module=vs_coord_srv_tests
25 tests, 0 failures
```

**4. E il numero lo dice da solo.** Il tuo `c65d0cb` porta `EXPECTED_TESTS` da 333 a 336. Il
nostro branch è a 382, misurato su un albero che contiene `c65d0cb`. 382 include già i tuoi tre:
sommarli di nuovo li conterebbe due volte.

Quindi il conto post-merge parte da **382**, non da 385 — e con i quattro test nuovi di questa
review diventa **386**, che è dove `EXPECTED_TESTS` è ora, nello stesso commit dei test.

Una postilla per anticipare l'obiezione: anche se GitHub creasse un commit di merge invece di
fare fast-forward, `origin/main` resta un antenato e **l'albero mergiato è l'albero del branch**.
Il conteggio è quello che il branch misura, comunque venga chiuso.

Il tuo principio regge; era il presupposto sotto («il tuo albero non contiene i miei tre») a non
reggere. Che è, credo, esattamente il motivo per cui hai scritto «da confermare eseguendo».

## I numeri

Prima: `382 tests, 0 failures`. Dopo: `386 tests, 0 failures`. Quattro test nuovi — la
regressione B1, `phase(closing)`, e i due del manager.

Tre giri consecutivi, col tuo criterio:

```
eunit_check: OK — 386 tests, 0 failures
eunit_check: OK — 386 tests, 0 failures
eunit_check: OK — 386 tests, 0 failures
```

E ciascuno dei quattro test nuovi è stato verificato **rosso senza il suo fix**, non solo verde
con: le prove sono nei paragrafi qui sopra.

---

*Riverifiche del 01/09 sul branch `a/m4-notify`: `vs_env.erl:25-33`; `vs_connector.erl:344-348`,
`:836`, `:898`, `:963`, `:1251-1257`, `:1301-1302`, `:1565-1586`; `vs_driver_proto.erl:562`,
`:578-581`, `:607-611`, `:657-670`; `vs_station_mgr.erl:70-72`, `:264-281`, `:291-300`,
`:350-368`, `:509-513`, `:594-602`; `vs_claim_client.erl:343`, `:449-456`, `:583`, `:646`;
`vs_driver_ws.erl:88`, `:125`, `:171-179`; `vs_mock_coord.erl:163-170`;
`vs_claim_client_tests.erl:792-796`; `cp.js:149`, `:431`, `:442`, `:458`;
`docker-compose.yml:63-70`, `:105`; `ws-driver.md:220`; `origin/main:vs_coord_srv.erl:274`,
`:319`. (In questa coda i numeri di `vs_connector`, `vs_driver_proto`, `vs_station_mgr` e
`vs_claim_client` sono quelli di **prima** dei fix, cioè quelli che ho letto; dopo sono
slittati, e nei paragrafi sopra sono citati quelli di adesso.)*

— A
