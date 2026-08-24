# Scelte di progetto — lato Erlang

Decisioni prese sul codice Erlang, con la motivazione e le alternative scartate. È materiale per l'orale: ogni voce è scritta per rispondere a un "perché così e non altrimenti". La versione inglese di queste motivazioni confluisce nella relazione finale.

Aggiornare questo file quando si aggiunge un modulo, non dopo.

---

## 1. Struttura

### 1.1 Un progetto umbrella con due applicazioni

`apps/vs_common`, `apps/vs_station` (parte A), `apps/vs_coord` (parte B) in un solo progetto rebar3.

**Perché**: stazione e coordinatore condividono tipi e helper (timestamp, lettura della configurazione) e vanno compilati insieme per accorgersi subito se un contratto cambia. Un unico `rebar3 compile` costruisce tutto il cluster, e un'unica immagine Docker serve entrambi i ruoli.

*Perché non due progetti separati?* Avrebbe reso `vs_common` una dipendenza pubblicata su hex o una git dependency: due passaggi in più per ogni modifica, su un progetto in cui i due sviluppatori lavorano in parallelo e le firme si assestano nelle prime settimane.

### 1.2 `vs_common` come app condivisa, non come libreria copiata

**Perché**: è l'unico punto in cui il codice dei due sviluppatori si sovrappone davvero. Averlo come applicazione OTP dichiarata rende esplicito che modificarlo tocca entrambi — infatti è una delle tre eccezioni alla regola "ognuno tocca solo i propri file".

### 1.3 M0 senza dipendenze esterne

`rebar.config` ha `{deps, []}`; cowboy, jsx, jose e mysql entrano in M1.

**Perché**: la M0 esiste per disinnescare il rischio "configurazione distribuita" (nomi nodo, cookie, DNS fra container). Se il primo `docker compose up` dovesse anche scaricare mezzo hex, un fallimento di rete diventerebbe indistinguibile da un errore di configurazione — cioè esattamente ciò che la milestone deve isolare. Con zero dipendenze la build è offline e istantanea, e se qualcosa non va la causa è una sola.

---

## 2. Configurazione

### 2.1 Tutto da variabili d'ambiente, con default nel codice (`vs_env`)

**Perché**: gli stessi parametri devono valere in tre contesti — shell di sviluppo, container, demo — e la demo ha bisogno di accorciare i timer (lease da 900 s a 30 s) senza ricompilare. Le variabili d'ambiente sono l'unico canale che Docker Compose, `rebar3 shell` e un `erl` a mano parlano tutti nativamente.

*Perché non `sys.config`?* Perché il valore andrebbe comunque parametrizzato per container, e si finirebbe a generare `sys.config` da variabili d'ambiente: un livello in più per lo stesso risultato. `sys.config` resta l'opzione giusta se in M3 servirà configurazione strutturata (liste annidate), e in quel caso convivrà con `vs_env`.

### 2.2 Un valore malformato non impedisce il boot

`vs_env:get_int/2` su `"abc"` restituisce il default invece di sollevare un'eccezione.

**Perché**: un refuso in `docker-compose.yml` non deve trasformarsi in un nodo che non parte durante la presentazione. È una deviazione consapevole dal "let it crash": il principio vale per gli errori di programmazione a runtime, non per la validazione dell'input esterno al boot, dove un default sensato è più utile di un crash loop.

---

## 3. Supervisione

### 3.1 `one_for_one` sulla radice della stazione

**Perché**: i figli sono indipendenti. Se muore il client dei claim, le sessioni in corso devono continuare a erogare potenza — è il requisito di autonomia della stazione (SCOPE §4). Con `one_for_all` un crash del client dei claim spegnerebbe anche i connettori, cioè trasformerebbe un guasto di coordinazione in un'interruzione di servizio.

### 3.2 `intensity => 5, period => 10`

Cinque riavvii in dieci secondi, poi il supervisore si arrende e il nodo termina.

**Perché**: un processo che crasha in loop non si sta riprendendo, sta mascherando un bug. Meglio che il container muoia e Docker lo riavvii pulito (o che si veda il fallimento) piuttosto che un nodo semivivo continui a rispondere male al coordinatore.

### 3.3 Un processo per connettore, `simple_one_for_one` con `restart => transient` (da M1)

**Perché**: `transient` riavvia solo in caso di terminazione anomala. Un connettore che chiude la sessione e termina volontariamente non va riavviato; uno che crasha per un bug sì, e riparte in stato `free` — che è lo stato sicuro, perché senza claim non concede nulla.

Questa è anche la risposta a P1: le richieste concorrenti sullo stesso connettore sono serializzate dalla mailbox di un unico processo proprietario. Nessun lock, nessuna sezione critica esplicita — è il modello ad attori applicato a una risorsa fisica.

---

## 4. Il connettore (`vs_connector`)

### 4.1 `gen_statem` e non `gen_server`

**Perché**: il connettore *è* una macchina a stati, e con `state_functions` ogni stato è una funzione: un evento che non ha senso in quello stato semplicemente non fa match. Non esiste un ramo di codice che possa avviare una sessione su un connettore prenotato da un altro, perché da `held` con il veicolo sbagliato non si arriva a `charging`. Con un `gen_server` la stessa garanzia sarebbe un `case` su un campo di stato, cioè una convenzione che si può dimenticare in una `handle_call` aggiunta sei settimane dopo.

Vale anche per i timer: `state_timeout` viene annullato automaticamente a ogni cambio di stato, quindi il lease non può sopravvivere alla prenotazione a cui appartiene. Con un timer manuale servirebbe cancellarlo su ogni uscita — e la dimenticanza si manifesterebbe come una prenotazione liberata a caso mezz'ora dopo.

### 4.2 `callback_mode` con `state_enter`

**Perché**: il lease viene armato entrando in `held` e in nessun altro punto, quindi nessun percorso può raggiungere `held` senza scadenza. Allo stesso modo tutto ciò che deve accadere esattamente una volta a fine sessione (scrittura della riga, rilascio del claim, notifica) sta nell'ingresso in `closing`, invece di essere ripetuto in ognuna delle transizioni che ci arrivano — stop del conducente, cavo staccato, claim revocato.

### 4.3 `claim_mod` e `db_mod` iniettati come opzioni

**Perché**: il connettore conosce l'interfaccia del claim, non il suo trasporto. Con un modulo iniettabile la macchina a stati si testa contro tutti i rifiuti previsti dal contratto senza coordinatore, senza rete e senza MySQL — 22 test in 150 ms. È anche ciò che permette di sviluppare la parte A prima che esista `vs_coord`.

*Perché non una libreria di mock?* Perché aggiungerebbe una dipendenza per ottenere ciò che due opzioni già danno, e perché un modulo stub scritto a mano è leggibile in dieci righe.

### 4.4 Il default `vs_claim_null` concede sempre, ma lo urla nel log

**Perché**: la stazione deve essere avviabile e giocabile dalla shell prima che il claim client esista. Il rischio è che un default permissivo resti per errore e violi P2 in silenzio: per questo ogni concessione emette un `logger:warning` con scritto che il claim non è coordinato. Un difetto che si vede nel log è un difetto che si trova.

### 4.5 Il rifiuto arriva come atomo, non come codice del protocollo

Il connettore restituisce `already_held`, `no_claim`, `suspended`…; è `vs_driver_ws` a trasformarli nei codici maiuscoli di `ws-driver.md`.

**Perché**: la macchina a stati non deve sapere che esiste un WebSocket. Lo stesso connettore risponde identicamente a un comando che arrivasse dalla colonnina o da un test, e cambiare la formattazione del protocollo non tocca la logica.

### 4.6 Walk-in senza claim

Un'auto collegata a un connettore libero avvia la sessione senza chiedere nulla al coordinatore.

**Perché**: la prenotazione è una promessa sul futuro, non un permesso a caricare. Rifiutare un'auto già collegata a una presa libera perché il coordinatore è irraggiungibile sarebbe assurdo, e disallineerebbe il sistema dalla realtà fisica (l'auto è lì). È anche il motivo per cui la penalità da no-show sospende il prenotare e non il caricare (SCOPE §3.3): la sanzione toglie un privilegio, non lascia a piedi nessuno.

### 4.7 L'energia è cumulativa e monotòna

Il connettore conserva `max(memorizzato, riportato)`.

**Perché**: un contatore che si azzera per un glitch del firmware non deve sottrarre energia già erogata — che è denaro. Il costo di questa scelta è che una lettura anomala verso l'alto resta: accettato, perché sovrastimare una volta è un errore correggibile a mano, mentre perdere energia già fatturata è un errore che non si vede.

### 4.8 La revoca vince, anche a sessione avviata

**Perché**: lo dice il contratto (claim.md §5.4), ed è la conseguenza logica del fatto che l'autorità sui claim è il coordinatore. È il percorso più raro del sistema e quello che conviene di più avere giusto: la sessione viene chiusa, l'energia già erogata è comunque scritta e fatturata, il conducente riceve il motivo. Una revoca che riguarda un claim mai posseduto viene ignorata, così un messaggio in ritardo da un leader precedente non libera il connettore di qualcun altro.

### 4.9 Se la scrittura su MySQL fallisce, il connettore si libera lo stesso

**Perché**: l'auto ha già caricato. Perdere la riga è un problema di fatturazione, perdere il connettore è un problema di servizio: si registra l'errore e si prosegue. È anche il motivo per cui la scrittura avviene a fine sessione e non durante — il database non sta sul percorso critico dell'erogazione.

---

## 5. Comunicazione fra nodi

### 4.1 Erlang distribuito nativo fra stazione e coordinatore, non un broker

**Perché**: il messaggio di claim è una tupla Erlang spedita a un `gen_server` registrato; il linguaggio offre già trasporto affidabile e ordinato, monitor sui nodi e rilevamento dei guasti. Aggiungere un broker introdurrebbe un nodo in più da tenere vivo — e sarebbe un secondo punto di fallimento centralizzato in un progetto che esiste per rimuoverne uno.

### 4.2 Nomi corti (`-sname`) invece di lunghi (`-name`)

**Perché**: sulla rete di Docker Compose ogni container risolve gli altri per nome di servizio; i nomi lunghi pretenderebbero un FQDN e un DNS configurato senza dare nulla in cambio. Il deploy su più host previsto in M5 è l'unico caso in cui la scelta andrà rivista, e va rivista lì, non ora.

### 4.3 Ogni chiamata remota ha un timeout esplicito e non solleva mai eccezioni al chiamante

`vs_ping:call_remote/2`, e in M1 `vs_claim_client`, avvolgono `gen_server:call/3` in un `try ... catch` che restituisce `{error, timeout | noproc | nodedown}`.

**Perché**: `gen_server:call/2` con timeout infinito appende il processo chiamante a un nodo morto. Con timeout esplicito e risultato come valore, il connettore decide cosa fare (rifiutare la prenotazione) invece di crashare, e la stazione degrada senza fermarsi. È il presupposto della regola "niente coordinatore, niente prenotazioni nuove, ma le sessioni continuano".

Il valore (2000 ms, `CLAIM_CALL_TIMEOUT_MS`) è la parte assunta del sistema sincrono: come dice DESIGN-NOTES §6, sbagliare il timeout costa un failover inutile, non una doppia prenotazione — la correttezza la garantisce il quorum, non il timer.

### 4.4 Chiamate remote delegate a un processo effimero, mai eseguite nel `gen_server`

Il tick di `vs_ping` (e in M1 quello di `vs_claim_client`) fa `spawn` di un processo che esegue la chiamata remota e rimanda l'esito al server come messaggio `{ping_result, _}`. Il server aggiorna i contatori quando l'esito arriva.

**Perché**: un `gen_server` è un processo solo e serve una richiesta alla volta. Finché è dentro `handle_info` non può eseguire `handle_call`. Se due nodi si interrogano a vicenda sullo stesso tick, ciascuno resta bloccato in attesa di una risposta che l'altro non può dare — e il timeout non è una via d'uscita, perché entrambi riarmano insieme e restano in fase. È un **deadlock stabile**, non una perdita transitoria.

Non è teoria: in M0 le due stazioni ci sono cadute davvero. Con `docker compose up --build` i container partivano a qualche decina di millisecondi di distanza e i `pong` funzionavano; dopo un `docker compose restart` ripartivano nello stesso istante e il deadlock scattava dal primo tick. La diagnosi che lo ha inchiodato: un nodo terzo avviato dentro lo stesso container faceva `pong` senza problemi — quindi rete, EPMD, cookie e handshake erano sani, e l'unica cosa rotta era la reciprocità fra i due `vs_ping`.

*Perché non basta sfasare gli intervalli con del jitter?* Perché rende il deadlock raro invece che impossibile, e un guasto raro in un sistema distribuito è peggio di uno sistematico: si presenta alla demo e non si riproduce. La delega toglie la condizione, non la probabilità.

La conseguenza vera è su M1: se `vs_claim_client` bloccasse sul coordinatore, un coordinatore lento congelerebbe tutta la stazione, sessioni di ricarica comprese — l'opposto della regola "niente coordinatore, ma le sessioni continuano" di §4.3.

### 4.5 `vs_claim_client` come unico processo che parla col coordinatore

**Perché**: i rinnovi vanno raggruppati (un solo messaggio `renew` per stazione ogni 10 s, non uno per connettore) e il nodo leader corrente è uno stato solo, aggiornato in un posto solo quando arriva un `{not_serving, Leader}`. Se ogni connettore parlasse per conto proprio, ogni connettore dovrebbe scoprire il nuovo leader da sé, moltiplicando i messaggi durante un failover — cioè proprio quando la rete è già in difficoltà.

---

## 6. Verifica

### 6.1 Logica pura separata dai processi, testata con EUnit

Il riparto della potenza e le decisioni di stato sono funzioni pure chiamate dai `gen_server`/`gen_statem`, non logica dentro i callback.

**Perché**: una funzione pura si testa con una tabella di casi e senza avviare nulla. Testare l'algoritmo di riparto attraverso i messaggi di un processo richiederebbe di orchestrare processi per verificare una divisione.

### 6.2 Il probe M0 (`vs_ping`) ha la forma del client dei claim

**Perché**: non è codice usa e getta. Verifica esattamente ciò che rischia di rompersi nel deploy (nomi, cookie, DNS) usando lo stesso schema che userà `vs_claim_client`: gen_server, call remota con timeout, tick con `erlang:send_after/3`, errore trattato come valore. Quando arriva M1, il modulo vero è una riscrittura di qualcosa di già visto funzionare.

---

## 7. Il manager di stazione (`vs_station_mgr`) — M1

### 7.1 Registry in ETS di proprietà del manager; la registrazione è un messaggio, mai una call

Il connettore si annuncia con un evento `{connector_up, Pid}` emesso dal proprio `init`, che il manager riceve come messaggio.

**Perché**: il manager avvia i connettori in modo sincrono dentro `handle_continue`; se l'`init` del figlio facesse una `gen_server:call` verso il manager mentre questo aspetta il ritorno di `start_child`, i due si aspetterebbero a vicenda — la stessa forma del deadlock dei ping documentato in §4.4, solo spostata al boot. Un messaggio non aspetta nessuno.

*Perché non `global` o gproc?* Una dipendenza (o un registry cluster-wide) per tenere una mappa locale `conn_id → pid` di quattro elementi: sproporzionato. ETS con owner il manager basta, e la tabella muore con lui — coerente con l'adozione di §7.3.

### 7.2 Al boot i pid vengono dal valore di ritorno di `start_child`; l'evento serve ai riavvii

**Perché**: registrare solo tramite l'evento renderebbe il boot non deterministico — una `station_state()` arrivata prima dei messaggi vedrebbe connettori `offline` mai esistiti. Il ritorno di `start_child` è sincrono e riempie il registry prima che `handle_continue` finisca; l'evento, idempotente, copre il caso che il ritorno non può coprire: il pid nuovo di un connettore riavviato dal supervisore dopo un crash.

### 7.3 Un manager che riparte adotta i connettori vivi, non li riavvia

In `handle_continue` il manager interroga `vs_connector_sup:which_children` e adotta i processi esistenti; avvia solo i mancanti.

**Perché**: la radice è `one_for_one`, quindi un crash del manager non tocca i connettori — ed è giusto così: le sessioni di ricarica devono sopravvivere a un guasto di contorno (autonomia della stazione, SCOPE §4). Ma allora, ripartendo, il manager troverebbe connettori già avviati: riavviarli alla cieca ne creerebbe due per presa.

*Perché non `rest_for_one`?* Ordinando manager prima dei connettori, un suo crash li riavvierebbe tutti: un guasto del contorno diventerebbe un'interruzione dell'erogazione — l'esatto contrario del requisito.

### 7.4 Un connettore morto appare `offline`, non sparisce

Tra il crash e il riavvio da parte del supervisore, la riga del registry perde il pid ma resta nello stato aggregato con `state => offline`.

**Perché**: il connettore esiste fisicamente; toglierlo dalla lista mentirebbe al conducente che ha la pagina aperta. La finestra è di millisecondi, ma il caso in cui il riavvio fallisce del tutto (intensity esaurita) la rende visibile — ed è informazione vera.

### 7.5 Configurazione dei connettori da `CONNECTORS`, allineata al seed

`CONNECTORS="1:150,2:150,3:150,4:50"`, dichiarata per stazione nel compose accanto al seed di `schema.sql` che rispecchia.

**Perché**: in M1 la stazione deve avviarsi senza MySQL — il database entra in M2 e non sta sul percorso critico dell'avvio. Gli id sono globali e fissati dal seed; la corrispondenza è un commento nel compose, un posto solo da tenere allineato.

*Perché non leggere `connectors` dal DB al boot?* Aggiungerebbe la dipendenza `mysql` una milestone in anticipo e metterebbe il database sul percorso di avvio della stazione: un DB giù terrebbe a terra anche le colonnine, che per SCOPE §4 devono funzionare da sole. Da rivalutare in M2, quando il pool esisterà comunque.

Un'entry malformata viene saltata con un warning, mai un boot fallito — stessa regola di §2.2.

### 7.6 Il push ai sottoscrittori è lo stato completo, ricalcolato a ogni evento

**Perché**: è P6 — il server è l'unica fonte di verità e pubblica stato completo, i client non calcolano nulla. Niente diff: con N≤4 connettori il costo è irrilevante e l'assenza di logica incrementale elimina un'intera classe di bug (client che perde un delta e diverge). Il budget di potenza viaggia nello stesso stato come valore (`site_power_kw`); il riparto arriva in M2 come da piano.

Il push parte però **solo da un cambiamento osservabile**: l'ingresso iniziale in `free` (in `gen_statem` l'enter dello stato di partenza ha `Old =:= New`, ed è l'unico modo di entrare in `free` da `free`) non emette `state_changed`, e il `connector_up` duplicato del boot non fa broadcast. Non è pulizia estetica: `handle_continue` gira dopo che `start_link` è già tornato, quindi una sottoscrizione può accodarsi *prima* degli annunci di boot e riceverebbe raffiche di push per cambiamenti mai avvenuti. Scoperto da un test EUnit che falliva o passava a seconda dello scheduling — la definizione operativa di race.

---

## 8. Il client dei claim (`vs_claim_client`) e il coordinatore finto — M1

### 8.1 La chiamata remota di `acquire` gira nel processo del connettore, non nel client

Il client non esegue mai una chiamata remota nel proprio loop: `acquire` fa il giro dei coordinatori dentro il processo del connettore che prenota, i rinnovi vivono in un worker effimero che riporta l'esito come messaggio (lo schema di `vs_ping`, §4.4), e i cast fire-and-forget partono da uno `spawn`, perché perfino l'auto-connect verso un nodo morto può bloccare chi invia.

**Perché**: il connettore che prenota DEVE aspettare — reserve è sincrona per contratto, non ha altro da fare. Il client invece no: se si bloccasse 2 s × 3 nodi su una claim, un coordinatore lento congelerebbe i rinnovi di tutta la stazione — e un rinnovo mancato a catena diventa revoca, cioè l'opposto di "niente coordinatore, ma le sessioni continuano". Il costo è che lo stato di routing (leader corrente) va letto e aggiornato con piccole call/cast locali dal processo chiamante; accettato, sono microsecondi.

### 8.2 Il client non fa mai call sincrone verso il resto della stazione

Verso il manager legge le ETS con `lookup_pid/connector_specs` (letture "dirty" dichiarate tali); verso i connettori solo cast (`revoke`).

**Perché**: esistono già le catene di call connettore→client (acquire) e manager→connettore (snapshot). Una call client→manager chiuderebbe un anello di tre gen_server che, con il timing giusto, si aspettano a vicenda fino al timeout — la versione a tre del deadlock dei ping di M0 (§4.4). La regola che ne esce è semplice da difendere all'orale: *nel grafo delle chiamate sincrone fra i processi della stazione non devono esistere cicli*; le frecce che chiuderebbero un ciclo diventano messaggi o letture ETS.

### 8.3 La tabella dei claim vive nel client; `GrantedAt` lo emette il coordinatore

**Perché nel client**: acquire e release ci passano già, il batch di renew (§3.2 del contratto: un messaggio per stazione, non uno per connettore) e la risposta a `who_do_you_hold` (§3.4, "immediatamente, dalla memoria") ne hanno bisogno lì. Il connettore resta proprietario della *prenotazione*, il client dei *claim* — due oggetti diversi per il contratto stesso.

**Perché GrantedAt del coordinatore** (evoluzione del 24/08, PR condivisa): la prima versione usava l'ora locale della stazione alla ricezione del grant, perché il contratto non trasportava un timestamp. B ha controproposto — e abbiamo accettato — che lo emetta sempre il coordinatore: `acquire` risponde `{ok, ReqId, ClaimId, GrantedAt, ExpiresAt}` e la stazione lo *ripete* in renew e `who_do_you_hold` senza mai inventare timestamp propri. Il motivo è da esame: oldest-wins (§5.5) confronta claim di **stazioni diverse**, e con timestamp locali l'esito dipenderebbe dallo skew fra macchine su cui non c'è alcuna garanzia (niente clock globale). Con un solo orologio emittente l'ordinamento sopravvive anche al failover. Nella stessa PR il renew è passato a cinque campi `{ClaimId, VehicleId, ConnId, UserId, GrantedAt}`: lo `UserId` costa zero (il client lo ha già in tabella) e permette a un leader che adotta un claim di applicare le sospensioni subito, senza aspettare la `who_do_you_hold` di M3 — il contratto si tocca una volta sola.

### 8.4 Un renew senza risposta non è una revoca

Se nessun coordinatore risponde, i claim restano e si ritenta al tick dopo; revoca solo la lista `Revoked` esplicita.

**Perché**: lo dice il contratto — la revoca è autoritativa (§5.4) proprio perché è *esplicita*; i fallimenti di discovery "non fermano mai ciò che è già in corso" (§4) e il backstop è la scadenza (§5.6): il lease locale libera il connettore e l'expiry lato coordinatore libera il veicolo, senza bisogno di indovinare dal silenzio. Interpretare il silenzio come revoca trasformerebbe ogni hiccup di rete in prenotazioni cancellate.

### 8.5 Il mock è un'app OTP nell'umbrella, registrata col nome vero

`apps/vs_mock_coord`, gen_server registrato `vs_coord_srv`, deployato con `ERL_APP: vs_mock_coord` sul servizio `coord1`.

**Perché**: il client non deve poter distinguere il finto dal vero — stessa registrazione, stesso trasporto, stesse tuple — così la sostituzione di fine M1 è un cambio di servizio nel compose e zero righe di Erlang. Farne un'app significa che `start-node.sh` lo avvia senza modifiche. In più il mock registra tutto ciò che riceve (`history/0`) e sa rifiutare a comando (`set_reply/1`, `set_renew/1`): è sia il riferimento eseguibile del contratto per B — trasporto incluso: `claim`/`renew` come call, `release`/`station_up`/`station_stats` come cast — sia il banco di prova con cui EUnit esercita il client fino alla revoca end-to-end.

*Perché non trenta righe dentro `vs_station`?* Perché deve girare su un **nodo** separato (è la distribuzione ciò che si sta provando), e un'app dedicata con `ERL_APP` è il modo che il deploy già conosce.

### 8.6 `CLAIM_MOD` come leva di configurazione

Il manager passa ai connettori `claim_mod = vs_claim_client` di default; `CLAIM_MOD=vs_claim_null` degrada allo stub rumoroso.

**Perché**: la stazione resta giocabile dalla shell senza coordinatore (il why di `vs_claim_null`, §4.4) senza ricompilare, e il default di produzione è quello coordinato — l'errore pericoloso (null in produzione) richiede un atto esplicito e si vede comunque nel log a ogni concessione.

### 8.7 `station_stats` derivate dai push del manager, inviate solo al cambiamento

Il client si abbona al manager **via cast** (regola di §8.2: mai call sincrone verso la stazione); il manager risponde a una sottoscrizione via cast inviando subito lo stato corrente — un cast non può combinare iscrizione e lettura, quindi il primo push fa da lettura. Da ogni push il client deriva `{free, held, charging}` e manda `{station_stats, ...}` al coordinatore **solo se i conteggi sono cambiati**.

**Perché event-driven e non a timer**: la lobby del back office mostra questi numeri; con un timer sarebbero vecchi fino al prossimo tick, con l'invio al cambiamento sono aggiornati quando cambia la realtà e silenziosi quando non cambia nulla — coerente con il principio P6 usato ovunque. La deduplica evita che ogni push del manager (che riparte a ogni evento) diventi traffico verso il coordinatore.

**Convenzioni di conteggio**: `closing` conta come `charging` (una sessione sta ancora finendo lì); `offline` non conta in niente — non è libero e non è utilizzabile — quindi i tre numeri possono sommare meno del totale dei connettori, ed è informazione vera, non un bug.

### 7.7 `notify` verso un nome non registrato non crasha il connettore

`vs_connector` fa `whereis` prima di inviare a un atom.

**Perché**: mentre il manager riavvia, il suo nome è momentaneamente non registrato e `Atom ! Msg` solleverebbe `badarg` — nel mezzo di una transizione di stato del connettore. Tutti i connettori notificano gli stessi eventi negli stessi momenti: crasherebbero insieme, esaurendo `intensity` e spegnendo il nodo. Un guasto del solo manager diventerebbe un'interruzione totale. La notifica persa è innocua: il manager, riadottando i connettori (§7.3), ricostruisce lo stato con una `snapshot`.
