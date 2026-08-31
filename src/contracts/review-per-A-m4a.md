# Review di B — `a/m4-notify` (M4-A)

**Da B, 31 agosto.** Cinque commit, 23 file, +3361/-89: overstay, no-show/show-up, il frame
`notification`, più due flaky tolti dal meccanismo. Rivisto contro `origin/main` a `90cbf81`.

Ogni rilievo qui sotto l'ho **verificato aprendo il codice**, non dedotto. Dove ho un dubbio sul
merito e non sul fatto, lo dico.

---

## B1 — GRAVE: una grace negativa uccide il connettore a ogni fine carica

`vs_connector.erl:836`

```erlang
{keep_state, Data1,
 [{state_timeout, Data1#data.overstay_grace_s * 1000, overstay_started}]}
```

`vs_env:get_int/2` torna al default **solo** su `badarg`:

```erlang
try list_to_integer(string:trim(Value))
catch error:badarg -> Default
end
```

`"-1"` è un intero perfettamente valido. Quindi `OVERSTAY_GRACE_SECONDS=-1` dà
`overstay_grace_s = -1`, e la `enter` di `complete` produce `{state_timeout, -1000, …}`.
`gen_statem` valida `Time >= 0` e termina con `bad_action_from_state_function`.

Il connettore muore **entrando in `complete`**, cioè a ogni stop del conducente, a ogni batteria
piena e a ogni revoca a metà sessione. Si perde la sessione viva e la sua riga in `sessions`, e il
supervisore lo fa ripartire in `free` con l'auto ancora attaccata.

Perché non è teorico: `OVERSTAY_GRACE_SECONDS` è una manopola **esposta nel compose** (righe 70 e
105), con un commento che invita esplicitamente a cambiarla —
`OVERSTAY_GRACE_SECONDS=10 docker compose up -d station1`. Un `-1` letto come «disattivato» è la
prima cosa che qualcuno prova in demo.

L'annotazione `non_neg_integer()` su `#data.overstay_grace_s` (riga 219) e il commento che dice
che «è non negativo da M4» sono asserzioni senza nulla che le imponga. Lo stesso rilassamento è
stato applicato a `cp_grace_ms` e `settle_ms`, che il diff ha allargato da `pos_integer()` a
`non_neg_integer()`.

C'è anche un secondo effetto, indipendente dal crash: con grace negativa `overstay_seconds/3`
restituisce `elapsed_s + |Grace|`, cioè fattura secondi mai trascorsi.

**Suggerimento**: `max(0, …)` alla lettura, in `init`, dove il valore viene fotografato. Una riga,
e l'annotazione di tipo torna vera.

## B2 — `phase/2` non copre `closing`

`vs_driver_proto.erl:609`

```erlang
phase(complete, _)  -> complete;
phase(overstay, _)  -> overstay;
phase(_, Soc) when is_number(Soc), Soc >= 100 -> complete;
phase(suspended, _) -> suspended;
phase(_, _)         -> charging.        %% <- closing finisce qui
```

`complete(cast, {cp_status, faulted})` (`vs_connector.erl:898`) emette `session_interrupted` e
passa a `closing`, che tiene la sessione nello snapshot per tutto `settle_ms` — e la notifica
provoca un broadcast del manager, quindi in quella finestra un frame `session` viene davvero
spedito. Lì `phase(closing, Soc)` cade nel catch-all e risponde **`charging`**, con `power_kw` a
zero e un `overstay_seconds` che continua a crescere.

Il conducente che guarda `overstay` da venti minuti vede la fase tornare a "charging" per gli
ultimi due secondi prima di `closed`.

È lo stesso enum enumerato in quattro posti con quattro politiche di catch-all diverse
(`vs_power:is_live/1`, `vs_claim_client:count_stats/1`, `wire_connector_state/1`, `phase/2`), e
`phase/2` è quello che la modifica di M4 ha saltato.

## B3 — le notifiche driver arrivano anche al claim client

`vs_station_mgr.erl:599`

```erlang
live(ConnId, Kind, UserId, #state{subs = Subs}) ->
    Msg = {driver_notification, UserId, Kind, ConnId},
    maps:foreach(fun(Pid, _Ref) -> Pid ! Msg end, Subs),
```

`vs_claim_client.erl:343` fa `gen_server:cast(vs_station_mgr, {subscribe, self()})` per il feed
delle statistiche, quindi sta in `subs` insieme ai socket. Ogni `driver_notification` finisce
anche nella sua mailbox, dove cade in `handle_info(Info, State) -> logger:debug(…)`.

Non rompe niente, ma il claim client è il processo sul percorso critico di ogni `acquire`, di ogni
tick di renew e della ricostruzione P14 — e il commento sopra `live/4` («quale socket possa
vederla è una domanda sul token che l'ha aperto, e solo quel socket sa la risposta») è scritto su
una premessa falsa: **non tutti i subscriber sono socket**.

Nella stessa funzione: `live/4` ricopia il fan-out di `broadcast/1` (riga 509) perdendone la
scorciatoia `when map_size(Subs) =:= 0`. Due posti da cambiare quando l'insieme dei subscriber
smetterà di essere una mappa nuda di pid — che è esattamente ciò che servirebbe per il punto qui
sopra.

## B4 — `cp.js`: il timer del linger non viene azzerato prima di riassegnarlo

`src/emulator/cp.js:431`

```js
lingerTimer = setTimeout(() => unplug(`stopped: ${reason}, after the linger`), …);
```

`unplug()` (442) e `finish()` (458) fanno entrambi `if (lingerTimer !== null) { clearTimeout(…) }`,
questo no. Con `--linger 60`: la batteria si riempie, parte il timer A; una revoca a T+10s entra
nello stesso ramo e sovrascrive `lingerTimer` con B, lasciando A vivo e non referenziato. A scatta
per primo e chiama `unplug()`, che cancella **B** — il timer sbagliato — e registra la *prima*
ragione. Il linger non riparte, e l'invariante che il file stesso dichiara («un timer solo,
azzerato in unplug/finish») salta.

Emulatore, quindi non tocca la stazione. Ma è lo strumento con cui misuriamo, e un timer orfano lì
produce misure che non si spiegano.

## B5 — commenti che descrivono un buco che abbiamo già chiuso

`vs_claim_client.erl:449` e `vs_mock_coord.erl:163` dicono, in tre affermazioni separate, che
`vs_coord_srv` non ha una clausola `notify` e che il cast «cade nel catch-all a :279».

Su `origin/main`:

```
274: handle_cast({notify, _UserId, _Kind, _Text} = Event, State) ->
```

È la R2 della tua review, che ho applicato stamattina (PR #8, mergiata). Il **codice è giusto** —
mandare comunque era la scelta corretta — ma i commenti dicono il contrario del vero, e uno di
essi chiede a B di applicare una patch già applicata. In un modulo dove i commenti sono il
documento di progetto, e in un repository dove le note sono il canale di negoziazione, è il tipo
di riga che manda qualcuno a debuggare l'hop giusto.

Stesso testo anche in `vs_claim_client_tests.erl` («today it does not… R2, still open»).

---

## Una cosa su cui non sono sicuro, e la dico come dubbio

`complete` **non ha un limite superiore**. Le uscite sono `unplugged`, un `cp_status`
faulted/unavailable, e il timeout `cp_grace` — che però è armato solo sul `DOWN` del socket
colonnina. Una colonnina che continua a mandare heartbeat con il cavo dentro non ne innesca
nessuna: la scadenza del lease è assorbita di proposito da `complete(cast, {revoke, …})` con
«nothing to stop», e la riga su `sessions` non viene mai scritta.

**Non lo chiamo difetto**, perché credo sia esattamente la semantica che M4 voleva: l'auto è
fisicamente lì, l'outlet è occupato davvero, e SCOPE §3.4 dice che il sistema può solo
«accorgersene, avvisare, e rendere costosa l'attesa». Liberare il connettore dopo `settle_ms` con
una macchina attaccata sarebbe peggio.

Il caso che mi lascia il dubbio è un altro: **una colonnina che non manda mai `unplugged`** —
firmware difettoso, o il nostro emulatore ucciso a metà linger. Lì la sessione resta in RAM per
sempre e non viene mai fatturata. Non so se valga un timer di sicurezza o se sia giusto lasciarlo
al canale colonnina; è roba tua e la giri come credi. Lo segnalo perché la conseguenza — una
sessione mai scritta — è silenziosa.

---

## Quello che ho controllato ed è a posto

Lo scrivo perché pesa più dei rilievi:

- l'overstay è **netto** della grace, come concordato, e `overstay_seconds/3` conta dall'istante
  giusto;
- `no_show`/`show_up` hanno arità e forma che combaciano con quello che il coordinatore accetta e
  con quello che `PenaltyService` legge;
- `notification_text/1` centralizza la frase in un posto solo, e la forma che
  `ErlangBridge.onNotify` legge (`intOf`, `textOf`, `textOf`) è quella che mandate;
- il tuo `{notify, UserId, Kind}` interno viene tradotto in binari prima di uscire dal nodo — che
  è la cosa giusta, `textOf` non accetterebbe un atomo... anzi lo accetta, ma il contratto dice
  binari e voi mandate binari;
- i due flaky di `vs_connector_tests` che ti avevo segnalato sono **spariti**: tre giri di
  `eunit_check.sh` sul tuo branch, `382 tests, 0 failures` tutte e tre le volte. Il writer appeso
  e i due timeout enqueued erano davvero la causa.

## Nota su `eunit_check.sh`

Il tuo branch è a `EXPECTED_TESTS=382`, `main` è a 336 (i miei tre di stamattina). Al merge il
numero va **misurato**, non sommato: 382 è già misurato sul tuo albero, che però non contiene i
miei tre. Attesa 385, da confermare eseguendo.

— B
