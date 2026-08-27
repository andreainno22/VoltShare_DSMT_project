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

---

## 9. Il canale driver (`vs_driver_ws`) — M1

### 9.1 Tre moduli invece di uno

`vs_jwt` (verifica del token), `vs_driver_proto` (il protocollo di `ws-driver.md`), `vs_driver_ws` (le sole callback di cowboy).

**Perché**: un handler cowboy non si esercita in EUnit senza tirare su un listener *e* un client WebSocket — cioè `gun`, una quarta dipendenza portata per i soli test. Separando, ogni regola del contratto diventa una chiamata di funzione su una mappa: i 31 test del protocollo non aprono un socket, non avviano il manager e non toccano un coordinatore. In `vs_driver_ws` resta codice senza rami da decidere.

È la stessa mossa già fatta nel connettore con `claim_mod`/`db_mod` (§4.3): `conn_mod`, `mgr_mod` e `claim_mod` stanno nella mappa di sessione con i default di produzione, e i test li sostituiscono con `vs_driver_stub`. Ed è ciò che tiene la proprietà — verificata, non assunta — che **`rebar3 eunit` non apra la porta 8080**: nessuna fixture avvia l'applicazione.

*Scartata:* un handler unico con le funzioni pure esportate. Meno file, ma i test avrebbero costruito a mano lo stato interno di un processo di cowboy, cioè avrebbero dipeso dalla forma di cowboy invece che dal contratto.

### 9.2 Firma → `iss` → `exp`, e nessun controllo su `iat`

L'ordine di `jwt.md` §3 è vincolante, e non per eleganza. Nei fixture di `sample-tokens.md` il token "firma errata" ha `exp` = 2026-08-22: **è anche scaduto**. Verificando la scadenza per prima, una falsificazione risponderebbe `4408` e il test più importante del lotto — quello che dimostra che non si può impersonare un altro driver — passerebbe per il motivo sbagliato, e comincerebbe ad accettare falsificazioni il giorno in cui qualcuno rigenerasse il fixture con una scadenza più in là. Un test dedicato (`the_forged_fixture_really_is_expired_too`) fissa la premessa, così se un domani i fixture cambiano è quel test a rompersi, non la sicurezza in silenzio.

Simmetricamente, `iat` e `nbf` **non** si controllano: il token valido ha `iat` = 2027-12-31, emesso nel futuro rispetto all'orologio della demo, e un verificatore che lo guardasse rifiuterebbe l'unico token che deve funzionare. `jwt.md` §3 elenca tre controlli e tre soltanto.

`jose_jwt:verify/2` valida **solo la firma** — la trappola con cui `sample-tokens.md` si chiude. `iss` ed `exp` sono claim ordinari e si controllano a mano: un token che verifica non è un token da accettare. Misurato sul posto, `jose` risponde `{false, _, _}` anche a `alg: none` e a un header `RS256` contro la nostra chiave simmetrica (due test lo fissano), mentre su un token illeggibile **solleva un'eccezione** invece di restituire un valore: da qui il `try` in `vs_jwt:signature/2`, che è contratto della funzione e non imbottitura difensiva.

### 9.3 La cache dei `request_id`: at-most-once per connessione

Lista `[{RequestId, FramesDiRisposta, InseritoAMs}]` nella mappa di sessione, `REQUEST_CACHE_SIZE` (64) voci, `REQUEST_CACHE_TTL_MS` (60000), consultata **prima** di eseguire qualunque cosa.

**Perché**: §7.2 esiste perché un WebSocket può perdere un frame in silenzio, quindi il client *deve* poter ritentare; e un `reserve` ritentato che prenotasse due volte sarebbe peggio del frame perso. La prova non può stare nelle risposte — una risposta dalla cache e una appena calcolata sono identiche per definizione — quindi il test conta le chiamate ricevute dal connettore finto: due `reserve` con lo stesso `request_id`, **una** chiamata al connettore.

Dettagli scelti e fissati da un test: un *hit* non rinfresca il TTL (misura l'età della risposta, non la frequenza dei tentativi); le voci scadute si eliminano quando la cache viene toccata, non con un timer, perché una connessione ferma non ha lavoro da fare; oltre `REQUEST_CACHE_SIZE` esce la più vecchia; le chiusure non si mettono in cache, perché la connessione che possiede la cache sta per sparire. Lo `state` che segue l'`ack` di `join` **non** fa parte della risposta memorizzata: è uno snapshot, e ripeterlo un minuto dopo significherebbe rimandare al browser una fotografia vecchia.

### 9.4 Ogni chiamata al connettore dentro `try … catch exit:_`

Catena misurata sul codice, non ricordata: `vs_connector:reserve/3` è una `gen_statem:call/2` col timeout implicito di **5000 ms**, e dentro `vs_claim_client:acquire/4` gira un giro di discovery di al massimo 3 nodi × `CLAIM_CALL_TIMEOUT_MS` (2000) più un tentativo dopo `unknown_station` — **circa 8 s**. Senza il `catch`, il chiamante esce, il processo WebSocket muore con lui e il browser vede una disconnessione al posto della risposta a una domanda che aveva fatto.

La risposta è `NO_CLAIM`, che è la riga che §4.1 riserva a "unreachable, timeout, no leader". Il connettore può completare la prenotazione **dopo** che la risposta è partita: il push `state` successivo la mostrerà e il client la accetterà senza discutere, perché §7.1 dice che la verità è del server. Meglio un "riprova" smentito da uno stato, che un socket che cade.

*Scartata:* allargare il timeout della call. Vorrebbe una `vs_connector:reserve/4` e un numero scelto a occhio più grande di una somma che cambierà quando cambieranno i coordinatori; il `try/catch` è corretto per qualunque valore. Un test lo esercita facendo sollevare allo stub esattamente l'`exit({timeout, ...})` che `gen_statem` solleverebbe.

### 9.5 `offline` → `out_of_service`

Il manager inventa lo stato `offline` quando nessun processo risponde per un connettore (§7.4); l'enum di `ws-driver.md` §5.1 ammette `free | held | charging | closing | suspended | out_of_service` e non lo contiene.

**Perché la traduzione e non un nome nuovo nel contratto**: `out_of_service` è *precisamente* ciò che `offline` significa per chi guarda la pagina — c'è, non si può usare — e il contratto descrive quello che il driver vede, non come la stazione ci sia arrivata. La voce `offline` arriva per giunta con **tre chiavi soltanto** (niente `held_by`, `expires_at`, `power_kw`), quindi ogni lettura in `wire_state/3` ha un default: è la stessa riga di codice che regge i due casi, ed è il caso che un test copre per primo.

`suspended` resta non producibile fino all'allocazione di potenza di M2, ed è dichiarato nel contratto invece che taciuto.

### 9.6 `coordinator_reachable`: una ETS pubblica scritta dal claim client

`vs_claim_reach`, una riga sola, scritta nei punti in cui l'esito di un giro di renew è già noto e letta sporca da `vs_claim_client:coordinator_reachable/0`.

**Perché così**: è esattamente il pattern già argomentato per `vs_station_mgr:lookup_pid/1` (§7.1) — lettura sporca invece di una call sincrona, per non mettere il claim client sul percorso critico di ogni push di stato e per non chiudere cicli fra gen_server. Il claim client, per regola strutturale (§8.2), non chiama nessuno dentro la stazione; farsi chiamare da un processo foglia sarebbe lecito, ma la ETS costa meno ed è coerente col resto.

**Semantica dichiarata**: *"l'ultimo giro di renew ha trovato un coordinatore"*, non *"il nodo risponde al ping"*. Prima del primo tick il valore è `true`, e lo è anche quando la tabella non esiste: ottimistico per scelta, perché finché nulla è stato tentato nulla è fallito, e chi decide davvero è `acquire`. Rifiutare prenotazioni per un coordinatore che nessuno ha ancora provato a raggiungere sarebbe un guasto inventato dalla stazione.

I punti di scrittura sono **tre**, non due: `{renew_result, error}` scrive `false`; sia `{renew_result, {ok, _, {renewed, ...}}}` sia `{renew_result, {ok, _, Altro}}` scrivono `true` — un coordinatore che risponde una cosa incomprensibile è comunque un coordinatore che c'è, e la raggiungibilità riguarda se qualcuno è vivo, non se la risposta avesse senso.

**Nota sulle fixture**: la tabella è `named_table` e creata in `init/1`, mentre tre fixture di EUnit avviano un client nella stessa VM e il loro teardown aspetta che sparisca il *nome registrato* — che un processo morente rilascia in un momento leggermente diverso dalle proprie tabelle ETS (`vs_station_mgr_tests` aspetta anche `ets:info/1`, `vs_claim_client_tests` no: le due fixture non sono simmetriche). `init_reach_table/0` assorbe il residuo distruggendo e ricreando; la tabella è `public` proprio perché così può cancellarla anche chi non la possiede. Un test riproduce la sequenza di proposito.

*Scartata:* rimandare a M3 lasciando il campo a `true`. La pagina mentirebbe proprio nello scenario che P4/P8 devono mostrare alla commissione.
*Scartata:* `net_adm:ping` sul leader dal WebSocket. Misura la raggiungibilità del *nodo*, non del *servizio*, e aggiunge una call sincrona verso il claim client per sapere chi sia il leader.

### 9.7 Il listener parte in `vs_station_app`, non sotto `vs_station_sup`

`cowboy:start_clear/3` consegna il listener all'albero di **ranch**. Dichiararlo anche fra i figli di `vs_station_sup` darebbe un supervisore che nomina un figlio che non supervisiona: un diagramma che mente, ed è la prima cosa che si chiede all'orale. Si avvia in `start/2` dopo `vs_station_sup:start_link/0` — l'ordine conta, così un browser che si collega nello stesso millisecondo del boot trova già un manager a cui abbonarsi — e si chiude con `cowboy:stop_listener/1` in `stop/1`.

Conseguenza accettata: un listener che muore lo rialza ranch, non noi. È il verso giusto: ranch sa come ricostruire un pool di acceptor, noi no.

Se la porta è occupata il nodo **non** si rifiuta di partire: `logger:error` e avanti. Una stazione con la porta presa deve comunque continuare a caricare le auto già attaccate — è §7.6 del contratto, la stazione degrada e non si ferma — e far fallire il boot porterebbe giù i connettori insieme alla pagina web.

Prima di chiudere il listener, `stop/1` manda un `station_shutdown` a ogni connessione viva (`ranch:procs/2`), che diventa la chiusura `1001` di §3: la pagina sa di dover tornare col backoff invece di mostrare un errore.

### 9.8 Il tick di stato rilegge, e porta con sé un `ping`

Due cose che sembrano ridondanti e non lo sono.

**Il tick rilegge dal manager** invece di ripetere l'ultimo snapshot ricevuto: le letture del contatore arrivano al connettore come `cast` che cambiano `power_kw` **senza** produrre un evento (`vs_connector`, ramo `charging`/`meter`), quindi un canale guidato dai soli eventi mostrerebbe una sessione viva a potenza congelata. È precisamente il buco che `STATE_TICK_MS` esiste per tappare.

**Il tick porta un `ping`** perché cowboy chiude un WebSocket dopo `idle_timeout` (60 s di default) **senza dati ricevuti**, e non conta ciò che il server manda: una pagina che ha fatto `join` e sta solo guardando verrebbe scollegata ogni minuto, e il backoff di §7.5 trasformerebbe una stazione sana in un ciclo di riconnessioni. Il browser risponde `pong` da solo, e quel frame in entrata rimette a zero il timer. `idle_timeout => infinity` avrebbe curato il sintomo buttando via la medicina: col ping, un peer che se n'è andato davvero smette di rispondere e il timeout fa il suo mestiere.

### 9.9 Cosa non c'è in M1, e perché è scritto nel contratto

`join_waitlist`/`leave_waitlist` (§4.4) vogliono una coda per stazione che non esiste in nessun processo, e il frame `session` (§5.2) vuole le letture del contatore che arrivano col canale colonnina in M2. Le due azioni cadono nel ramo "azione sconosciuta" e rispondono `BAD_REQUEST`; `waitlist` è la costante `{length: 0, my_position: null}` — una chiave dichiarata, mai una chiave mancante, così la pagina rende sempre la stessa forma.

Il canale driver è **di proprietà di A** (intestazione di `ws-driver.md`): la limitazione si dichiara nel contratto stesso, senza PR. Va dichiarata e non taciuta — un contratto che descrive azioni che il server non implementa è peggio di un contratto che dice quando arriveranno. Un test (`the_waiting_list_is_out_of_m1`) fissa il perimetro: chi implementerà la coda troverà quel test a dirgli di tornare a cancellarlo.

**Le due righe di §4.1 restano distinte, perché nascono in due posti distinti.** `already_held` lo solleva `vs_connector` stesso (`held/3`, `charging/3`): *questo connettore* è preso, il prossimo forse no. `vehicle_committed` arriva invece dal **coordinatore** — nel suo vocabolario `already_held` parla del *veicolo*, perché i claim sono per veicolo — e `vs_claim_client:map_refusal/1` lo rinomina in entrata proprio per non far collidere due fatti diversi sulla stessa parola. Il connettore non matcha né l'uno né l'altro: rimbalza ciò che `claim_mod` ha risposto, quindi la distinzione costa una parola nella dichiarazione `-type refusal()` e nessun ramo.

Non è cosmetica: a un driver a cui si dice "connettore occupato" prova quello accanto, e lì fallisce identicamente, perché il problema non era il connettore ma la sua auto prenotata altrove. Il messaggio giusto — *"your vehicle already holds a reservation elsewhere"*, testuale dalla colonna "Meaning shown" di §4.1 — lo manda invece a cancellare l'altra prenotazione. Era l'unico punto del sistema in cui la pagina diceva al driver una cosa falsa.

### 9.10 Le dipendenze, il lock e `warnings_as_errors`

Prime dipendenze esterne del progetto: `cowboy 2.18.0`, `jsx 3.1.0`, `jose 1.11.12` — le più recenti su hex, verificate con `rebar3 pkgs` invece che copiate da una nota di progetto, e compilate davvero su OTP 29.0.5.

`warnings_as_errors` di primo livello **si propaga alle dipendenze**: `jose` usa ancora la forma `catch Expr` che OTP 29 ha deprecato, e il build moriva su un warning in sorgente altrui. Rimedio: `{overrides, [{del, [{erl_opts, [warnings_as_errors]}]}]}`, che abbassa la severità **solo** per le deps. Sul nostro codice resta: è una regola per ciò che scriviamo noi, non per ciò che scaricano gli altri.

`rebar.lock` si committa (la riga in `.gitignore` è stata tolta) e il `Dockerfile.erlang` lo copia accanto a `rebar.config`: senza, due macchine e il container possono risolvere versioni diverse — esattamente la classe di problema per cui esisteva il pin di OTP 29.0.5. `vs_station.app.src` elenca le tre app fra le `applications`, altrimenti `application:ensure_all_started(vs_station)` le lascia ferme e il listener parte su una libreria non avviata.

Misurato per inciso: su OTP 29 `jose` sceglie da solo `jose_json_otp`, cioè il modulo `json` della OTP, **non** `jsx`. Nessuna conseguenza — `jsx` resta il codec del nostro filo, `jose` usa quello che preferisce per i suoi — ma va scritto perché la nota di progetto assumeva il contrario.

---

## 10. Il client del canale driver (`ws.js`, `station.js`) — M1 passo 4

### 10.1 Due file: trasporto e rendering

`js/ws.js` è il **trasporto**: connessione, `?station_id=`, handshake, generazione dei `request_id`, timeout e ritentativo, backoff, smistamento dei frame. `js/station.js` è il **rendering**: prende un payload `state` e disegna la griglia. Nessuna libreria, nessun bundler.

**Perché il taglio.** Il trasporto è identico per ogni pagina che parla il contratto del driver — la vista stazione, la vista sessione di M2, e i driver emulati del generatore di carico, che `ws-driver.md` nomina esplicitamente in intestazione. Il rendering è l'unica parte che cambia da una pagina all'altra. In un file solo, la seconda pagina lo copierebbe: è la stessa ragione per cui il protocollo lato Erlang sta in `vs_driver_proto` e non dentro l'handler di cowboy (§9.1).

### 10.2 Il client non tiene stato — ed è il punto da difendere all'orale

§7.1: il client rende `state` e nient'altro. Ogni frame ridisegna la griglia intera. L'`ack` di una `reserve` **non colora niente**: il connettore diventa `held` quando lo dice il `state` che arriva subito dopo. Il gestore dell'`ack` in `station.js` è deliberatamente vuoto, con un commento che spiega perché.

Sembra uno spreco — perché non colorare la casella che so di aver appena prenotato? Perché un client che applica delta ha un modello suo, e un modello suo può divergere dal server dopo **un solo frame perso**: è esattamente il guasto per cui P6 esiste. Il payload sono quattro connettori: mandarlo intero non costa nulla e chiude un'intera classe di bug.

Le uniche due cose che sopravvivono fra un frame e l'altro non sono un modello della stazione: la **scadenza scritta sul nodo DOM** (perché il conto alla rovescia possa battere ogni secondo senza chiedere niente al server), riancorata a ogni frame; e l'**ultimo errore** che il server ha mandato per un connettore, che è una risposta indirizzata a questo utente, non un fatto sulla stazione.

### 10.3 Il ritentativo con lo stesso `request_id` è metà della dimostrazione di P7

§7.2 esiste perché un WebSocket può perdere un frame in silenzio. La cache dei `request_id` lato stazione (§9.3) serve a questo — ma **senza un client che ritenta, è codice che nessuno esercita**, e l'at-most-once resta una tabella in un file di test.

Regola implementata: `crypto.randomUUID()` una volta per **azione dell'utente**, non per invio; timeout di 5 s per tentativo; due ritentativi con lo **stesso** id; poi errore visibile. Misurato contro un nodo stazione vero, buttando via il primo frame: due trasmissioni, **un solo** `request_id`, 5015 ms di attesa, e **una sola** prenotazione sul connettore.

**La cache è per connessione**, non per pagina (§2: *"keeps, per connection"*). Alla chiusura del socket ogni `request_id` in volo muore con lui, quindi nessuno può essere rigiocato sulla connessione successiva: la nuova cache è vuota e il comando verrebbe eseguito una seconda volta. Le promesse pendenti vengono perciò **rifiutate** alla chiusura, e l'utente decide se richiedere — cosa comunque sicura, perché §7.1 fa del `state` successivo la verità in entrambi i casi.

### 10.4 Riconnessione selettiva: il codice di chiusura decide

§7.5 chiede backoff esponenziale da 500 ms fino a 10 s con un `join` nuovo. Ma riconnettere ha senso solo dove serve:

| Chiusura | Cosa fa il client |
|---|---|
| `1001` (stazione che si spegne), `1006` (rete), altro | riconnette col backoff |
| `4401` / `4408` | **si ferma**: il token sta nella pagina (`jwt.md` §2), rimandarlo manderebbe lo stesso identico token. Messaggio e invito a ricaricare |
| `4400` | **si ferma**: è un bug nostro, e un loop lo nasconderebbe |

Il backoff si azzera su un **`join` riuscito**, non su una `open` TCP: una stazione che accetta il socket e poi lo chiude `4401` non ci ha dato una connessione funzionante, e azzerare sulla `open` la ritenterebbe a piena velocità per sempre.

**Una corsa misurata, e la riga che la chiude.** La `join` non parte dentro `onopen` ma dopo un giro di event loop (`setTimeout(…, 0)`). La stazione rifiuta uno `station_id` sbagliato nel suo primo atto (chiusura `4400`), quindi il frame di chiusura è spesso già nel buffer di ricezione quando scatta `open`. Scrivere sul socket in quell'istante fa perdere alla scrittura la corsa con la lettura: il peer è già andato, la connessione si resetta, e la chiusura arriva come un `1006` nudo **con il 4400 buttato via** — cioè proprio il loop di riconnessione che §7.5 vieta per il 4400. Osservato: `["connecting","reconnecting","connecting","reconnecting",…]` all'infinito. Con lo yield: `["connecting","refused"]` e codice 4400. Una riga, e la regola torna a valere.

La misura è stata fatta con un client Node, che usa la stessa classe `WebSocket` del browser; che un browser vero si comporti identicamente è coerente col fatto che la corsa è a livello TCP/WebSocket e non nell'API, ma **non è stato osservato in un browser** — l'estensione non era disponibile. È l'unica cosa del passo 4 che resta da guardare con gli occhi.

**Dopo una chiusura fatale il canale è finito, e `send()` lo dice subito.** Non è un caso limite: il token dura 60 minuti e la scadenza si controlla **solo** al `join` (`jwt.md` §1), quindi qualunque sessione più lunga del token finisce lì — con la griglia ancora disegnata dall'ultimo snapshot e non più viva. Accodare l'azione lascerebbe il pulsante disabilitato per sempre senza dire niente; `send()` rifiuta invece all'istante (misurato: 7 ms) con la frase che il driver può usare, *"your session has expired — reload the page"*. Trovato dalla verifica, non dalla lettura.

### 10.5 `?station_id=` lo appende il client

`stations.ws_url` è quello che la stazione ha annunciato di sé e che il coordinatore ha memorizzato — `ws://localhost:9101/ws/driver`, **senza query string** — mentre `vs_driver_ws` chiude `4400` se `station_id` manca o nomina un'altra stazione. Appenderlo è quindi compito del client, ed è commentato nel punto in cui avviene: è il dettaglio che, al passo successivo, nessuno ricorda.

### 10.6 Il conto alla rovescia si legge, non si calcola

L'`ack` di `reserve` porta `expires_at` in millisecondi epoch. Il client mostra il tempo restante **da quello**, mai da un `Date.now() + lease` calcolato in proprio: §4.1 lo dice, e la ragione è che l'orologio del browser non è quello della stazione. Il valore viene parcheggiato sul nodo (`data-expires-at`), così la ripittura al secondo non ha bisogno di nient'altro che del DOM — e viene riancorato a ogni `state`, quindi non può restare indietro.

### 10.7 Quello che non si può fare non si disegna

Il pulsante `Reserve` compare solo su `free`, `Cancel` solo se `held_by_me`, `Stop` solo su `charging` con `mine`. Niente pulsanti grigi: un pulsante disabilitato dice comunque *"questa è una cosa che potresti avere"*, mentre un pulsante assente dice la verità, cioè che quel connettore è affare di qualcun altro. `held_by_me` e `mine` non li calcola la pagina — arrivano già decisi dal server (§7.3, §9.5).

### 10.8 `textContent`, mai `innerHTML`

`name` arriva dall'ambiente della stazione e attraversa il coordinatore; `message` degli errori arriva dal server. Nessuno dei due è ostile oggi, ma una pagina che costruisce HTML da stringhe ricevute è una pagina che aspetta solo il giorno in cui una di quelle stringhe cambia sorgente. Tutti i nodi si costruiscono con `createElement`.

### 10.9 Nessun codice per il ping, e un commento che lo dice

La stazione manda un `ping` insieme a ogni tick di stato (§9.8). Il browser risponde `pong` da solo, sotto l'API JavaScript — RFC 6455 §5.5.2 lo rende obbligatorio e la WebSocket API non espone alcun aggancio. Quel pong è traffico in entrata, ed è ciò che impedisce a `WS_IDLE_TIMEOUT_MS` di chiudere una pagina che ha fatto `join` e sta solo guardando. **Non c'è niente da scrivere**, e il commento esiste perché è la prima cosa che qualcuno verrà a cercare.

### 10.10 Gli stili stanno nella pagina, non in `app.css`

`css/app.css` e `page.tag` sono di B e sono condivisi da tutte le viste. `app.css` definisce già `.connectors` come griglia e i colori come variabili su `:root`; le caselle dei connettori sono nuove e appartengono alla pagina di A. Un blocco `<style>` dentro `station.jsp`, che usa solo le variabili già dichiarate, tiene la proprietà pulita e non tocca un file condiviso per una funzionalità di uno solo.

### 10.11 Cosa la pagina non fa

Niente lista d'attesa (§4.4) e niente riquadro di sessione (§5.2, richiede il canale colonnina di M2), coerentemente con §9.9. Il campo `waitlist` arriva come costante dichiarata e viene semplicemente ignorato dal rendering.

---

## 11. Il canale colonnina (`vs_cp_ws`, `vs_cp_proto`) — M2-A passo 1

Contratto: `contracts/ws-chargepoint.md`. È il confine del sistema: sopra c'è logica di
produzione, sotto c'è hardware emulato, e l'emulatore è credibile solo se questa interfaccia
è una che una colonnina vera potrebbe implementare. Le cinque decisioni D1-D5 del piano
stanno qui con le alternative scartate.

### 11.1 Lo stesso taglio del canale driver: protocollo e trasporto separati

`vs_cp_proto` tiene tutte le decisioni (handshake, envelope, dispatch, autorizzazione del
`plugged`, costruzione dei frame), `vs_cp_ws` solo le callback cowboy. È la stessa mossa
già motivata in §9.1 e vale per la stessa ragione, misurata: un handler cowboy non si
esercita da EUnit senza far partire un listener e un client WebSocket, e un client
significherebbe `gun` come quarta dipendenza portata solo per i test. Con lo split, i 29
test del canale colonnina sono chiamate di funzione su mappe ordinarie e `rebar3 eunit` non
apre la porta 8081.

I collaboratori iniettati sono tre, come di là: `conn_mod`, `mgr_mod`, `db_mod`.

### 11.2 D1 — l'utente della sessione: dall'hold se c'è, dal veicolo se è walk-in

Il payload `plugged` identifica il **veicolo** (§4.2), `session_from/2` pretende un
`user_id`, e il mapping è 1:1 nello schema (`vehicles.user_id UNIQUE`).

- **Con prenotazione**: la sessione si apre sull'utente dell'**hold**, non su quello che il
  payload nomina. È lui che viene fatturato, e §7.1 dice che la colonnina riferisce e non
  decide — quindi il payload non ha voce in capitolo. Il test
  `a_reserved_session_is_billed_to_the_holder_test` manda apposta un `user_id` sbagliato.
- **Walk-in**: `vs_cp_proto` risolve `vehicle → user` con la nuova callback
  `db_mod:user_for_vehicle/1`. Lo stub in `vs_station_db` risponde l'identità e **lo dichiara
  nel log a ogni chiamata**; il passo 3 sostituisce il corpo con la SELECT e l'interfaccia
  non cambia.

*Alternativa scartata:* chiedere al coordinatore. Il coordinatore non possiede la tabella
`vehicles`, e si aggiungerebbe una chiamata remota su un percorso che deve funzionare anche
a sito isolato (autonomia di stazione, SCOPE §4). La risoluzione è locale per lo stesso
motivo per cui il walk-in non chiede un claim.

### 11.3 D2 — `out_of_service` è un quinto stato del `gen_statem`, non un flag

"Non prenotabile, invisibile come libero, sessione chiusa" è esattamente ciò che uno stato
esprime e che un flag lascerebbe a un `case` in ogni ramo. Il guadagno concreto:
`handle_common` risponde già `invalid_state` alle call che non gestisce, quindi un `reserve`
su un connettore fuori servizio **si rifiuta da solo**, senza una riga scritta per l'occasione
(`an_out_of_service_connector_cannot_be_reserved_test`).

La catena verso la pagina regge senza modifiche a `vs_driver_proto`: `wire_connector_state/1`
ha la clausola passante `Other -> Other` e l'enum di `ws-driver.md` §5.1 contiene già
`out_of_service`. Verificato anche il secondo consumatore, che il piano non elencava:
`vs_claim_client:count_stats/1` conta gli stati per le `station_stats` e ha un catch-all `_`
che assorbe il nuovo atomo contandolo come niente — la stessa semantica di `offline`, che è
quella giusta (non libero, non usabile).

Ingressi: `{cp_status, faulted|unavailable}` e la perdita del CP oltre la grazia (D3).
La stazione non decide **mai** da sola che un connettore è guarito — §7.2 dice che sul fisico
l'autorità è l'hardware — quindi entrambe le uscite le apre la colonnina:

1. **`status: available`** → `free`. Il caso semplice: l'apparato è tornato e non ha nessuno
   attaccato.
2. **`plugged` (riconciliazione §6)** → `charging`, sessione adottata dai numeri riportati.

La seconda è quella che è facile lasciare fuori, ed è quella che serve davvero. Una colonnina
che ha smesso di farsi sentire **mentre erogava** non torna dicendo `available`: torna dicendo
`occupied` — che non solleva niente — e poi riannuncia il cavo. Senza questa clausola il
`plugged` verrebbe rifiutato `invalid_state`, l'ack del `boot` avrebbe già consegnato
`limit_kw: 0`, e un'auto fisicamente attaccata resterebbe sospesa per sempre ad aspettare un
`available` che un apparato occupato non manda mai. La sessione precedente qui non c'è più —
è stata chiusa con l'ultima energia misurata all'ingresso in `out_of_service` — quindi il
connettore adotta ciò che l'hardware riporta, esattamente come `free` fa per un walk-in.
Senza claim, di proposito: §6 dice che ricostruire la prenotazione non si tenta, "l'auto
continua a caricare, la sessione viene fatturata, la prenotazione non c'è più".

### 11.4 D3 — tre heartbeat persi = `idle_timeout` del socket **più** una grazia sul distacco

Il contratto dà una regola sola (§3.2, "tre heartbeat persi") e i modi di non farsi sentire
sono due, quindi l'implementazione è in due pezzi che scadono sullo stesso numero:

- **il socket tace**: `idle_timeout` di cowboy = `CP_HEARTBEAT_MISSED × CP_HEARTBEAT_INTERVAL_S`
  (90 s). Conta solo il traffico in ingresso (misurato in M1, §9.8), quindi "nessun frame di
  alcun tipo per 90 s" implementa "non si fa sentire" — e una colonnina in carica che manda
  `meter` ogni 5 s non scade mai, che è la semantica voluta. Su questo canale **non c'è
  ping**, all'opposto del canale driver: lì il timeout andava aggirato perché una pagina che
  guarda tace legittimamente, qui il timeout *è* la regola.
- **il socket muore**: il connettore riceve il `DOWN` e **non** va subito fuori servizio.
  Arma `{timeout, cp_grace}` della stessa durata e lo cancella se un CP si riattacca.

*Perché la grazia:* §1 del contratto prevede esplicitamente il blip di rete con riconnessione
in 1 s. Marcare fuori servizio all'istante rilascerebbe una prenotazione viva per un guasto
durato un secondo. Alla scadenza: `held` → release + `session_interrupted` + `out_of_service`;
`charging` → chiusura con l'ultima energia (riga scritta) + `out_of_service`; `free` →
`out_of_service`.

Due dettagli che sono bug se sbagliati, e hanno un test ciascuno:

1. È un timeout **generico** (`{timeout, Name}`), non uno `state_timeout`: quest'ultimo viene
   cancellato da qualsiasi cambio di stato, e la grazia deve sopravvivere al passaggio
   `charging → closing`.
2. `attach_cp/2` fa `demonitor(..., [flush])` sul vecchio pid **prima** di monitorare il
   nuovo. Senza il flush, il `DOWN` del socket che abbiamo appena sostituito è già in
   mailbox e armerebbe la grazia di un connettore la cui colonnina sta benissimo
   (`the_death_of_a_replaced_socket_is_not_a_fault_test`).

### 11.5 D4 — `closing` parametrico sull'uscita, e la bandierina è di sola andata

`closing` era l'unica uscita di ogni sessione che finisce e usciva sempre verso `free`. Il
percorso guasto deve uscire verso `out_of_service`, quindi `#data.after_closing` (default
`free`) viene letto dal timeout di `closing`.

**Viene rimesso a `free` nello stesso passo in cui è letto.** Se restasse impostato, la
sessione *successiva* — chiusa normalmente da un `unplugged` — uscirebbe anch'essa verso
`out_of_service`: un difetto latente che nessun test del percorso guasto avrebbe visto.
`available_brings_it_back_and_the_next_session_ends_free_test` esiste per questo.

I tre percorsi esistenti (`stop_session`, `unplugged`, `revoke`) non toccano il campo, quindi
il loro comportamento è invariato per costruzione, non per verifica.

### 11.6 D5 — `set_limit` interinale al posto dell'allocatore

Il contratto vuole un limite dopo l'autorizzazione e legge `limit_kw: 0` come "sospeso":
senza un valore vero l'emulatore non caricherebbe mai. Il passo 1 introduce l'API definitiva
`vs_connector:set_limit/2` (cast: memorizza in `#session.limit_kw` e inoltra al CP) e la
invoca **una volta sola**, all'ingresso in `charging`, con `min(rated_kw, max_kw)` — la presa
non dà più di quanto è tarata, l'auto non prende più di quanto è costruita.

Il passo 2 sposta il **calcolo** nell'allocatore del manager e richiama la stessa API a ogni
arrivo, partenza e tick; il **trasporto** non cambia più. È l'unico punto del passo 1
dichiaratamente provvisorio, e con più auto può sommare oltre `SITE_POWER_KW`: è lo status
quo di oggi (nessuno alloca niente), non una regressione.

*Bordo dichiarato:* un `plugged` senza `max_kw` parte sospeso, perché `min(150, 0) = 0`. È la
lettura onesta di `min`, il contratto rende il campo obbligatorio (§4.2), e inventare un
limite per un'auto che non ha dichiarato niente sarebbe la stazione che decide cosa può
prendere l'hardware — esattamente la divisione che §7.2 vieta. Il `set_limit` successivo
(un tick, dal passo 2) lo corregge.

### 11.7 Il campo `#data.cp` **è** il registro

Una connessione per connettore (§1) significa che l'unico posto dove una lookup potrebbe
guardare è lo stato del connettore stesso. Il socket appena connesso fa
`vs_connector:attach_cp(Pid, self())`; il connettore monitora il nuovo e manda al vecchio
`{cp_replaced}`, che chiude 4409. Niente gproc, niente seconda ETS, nessun processo in più
da tenere coerente con la realtà.

La direzione delle chiamate resta quella di M1: socket → connettore in call/cast, connettore
→ socket **solo** con `!`. Un socket occupato o morto non deve poter bloccare il processo che
possiede una presa fisica, e la regola "i connettori non fanno chiamate remote" resta intatta.

### 11.8 `attach_cp` sul `boot`, non sull'upgrade

Il legame si crea alla prima frase del protocollo, non all'apertura del socket. §3.1 rende
`boot` il primo frame "prima di qualsiasi altra cosa", quindi una riconnessione vera sfratta
comunque il socket stantìo entro un millisecondo dall'arrivo. Legare all'upgrade invece
lascerebbe che una connessione TCP mezza aperta — una scansione di porte, un probe di un
proxy — buttasse fuori una colonnina funzionante dal proprio connettore prima di aver detto
una parola.

Conseguenza dichiarata: un socket che si connette e non manda mai `boot` viene raccolto
dall'`idle_timeout` (90 s) senza aver disturbato nessuno.

### 11.9 Niente cache di dedup, niente frame `error`, niente ack sugli eventi

Tre assenze, ognuna richiesta dal contratto e ognuna facile da "migliorare" per sbaglio:

- **Nessuna cache dei `request_id`.** §2 è esplicito: qui non è una chiave di deduplicazione,
  "gli eventi dei due lati sono naturalmente idempotenti o naturalmente ordinati". Un `meter`
  ripetuto lo assorbe il massimo monotòno, un `plugged` ripetuto la macchina a stati. Il
  canale driver ha bisogno dell'at-most-once perché un `reserve` ripetuto prenderebbe un
  secondo connettore; qui niente ha quella forma.
- **Nessun frame `error`.** §2 dà a questo canale esattamente due tipi stazione → colonnina,
  `ack` e `command`. Un envelope illeggibile viene **loggato e scartato**, non risposto con
  un frame che il contratto non definisce: il contratto è di A, e non si allarga dal lato
  dell'implementazione. Resta rumoroso, che è ciò che §7.6 chiede.
- **Nessun ack sugli eventi.** La scaletta di §9 risponde a `plugged`, `meter` e `unplugged`
  con un comando o con niente; solo `boot` e `heartbeat` portano un `ack` (§3.1, §3.2).

Conseguenza sui test: metà delle asserzioni del canale guardano cosa è stato chiesto al
connettore, non cosa è tornato sul filo — perché sul filo non torna niente.

### 11.10 Il connettore si rilegge a ogni evento, il pid non si memorizza

`vs_station_mgr:lookup_pid/1` è una dirty read della ETS del manager, lo stesso idioma di
`vs_claim_client` e per la stessa ragione: il socket non deve accodarsi dietro un manager che
sta bootando. Tenersi il pid dell'handshake sarebbe più veloce e sbagliato: un connettore che
crasha riparte con un pid nuovo, e il socket continuerebbe a castare `meter` in una mailbox
morta invece che nel processo vivo — dove il log "meter senza sessione" di §4.3 è proprio ciò
che dice che i due lati hanno divergito.

Il rifiuto dell'handshake (4404) usa la stessa lettura: "il registro non c'è ancora" e "non è
mio" meritano la stessa risposta, cioè riprova più tardi.

### 11.11 Due listener e due porte, non due rotte su una

`vs_driver_listener` su 8080 e `vs_cp_listener` su 8081, listener ranch distinti con router
distinti. Non sono due rotte dello stesso server perché sono due **confini** diversi: il
canale driver guarda internet attraverso un JWT, il canale colonnina guarda una rete di sito
senza autenticazione alcuna (§2, dichiarato come assunzione invece che finto risolto). Due
porte significa che il link di sito si può chiudere in firewall sulla VLAN degli apparati
senza toccare quella pubblica.

Stessa politica del primo listener se la porta è occupata: **rumoroso ma non fatale**. Qui
con più forza che di là, non con meno — le sessioni già in corso sono la cosa che si sta
proteggendo.

### 11.12 L'emulatore: Node puro, zero dipendenze, e la rampa del limite

`src/emulator/cp.js` non ha `package.json` e non ne avrà: il client `WebSocket` è un globale
di Node da 22 in poi (misurato: 24.18.0, `typeof WebSocket === "function"`). Niente da
installare significa niente che possa essere rotto sulla macchina dove si mostra la demo.

Due scelte di modellazione che non sono decorazione:

- **Il limite si applica a rampa**, non a gradino, su `LIMIT_APPLY_SECONDS` (§5: "real
  hardware ramps"). Un emulatore che salta al valore nuovo istantaneamente farebbe sembrare
  lo scenario della potenza migliore di quanto è.
- **`stop` con reason `station_shutdown` non stacca il cavo.** La stazione se ne va, l'auto
  no: l'emulatore smette di erogare, tiene il contatore e si riconnette — che è esattamente
  la riconciliazione di §6, e il modo in cui la si dimostra senza staccare niente a mano.
  Ogni altra reason termina la sessione con un `unplugged` che riporta il totale, perché qui
  non c'è nessuno che possa tirare fisicamente il cavo.

---

## 12. Il riparto della potenza (`vs_power`) — M2-A passo 2

Il passo 1 aveva lasciato il *trasporto* completo e il *calcolo* dichiaratamente provvisorio
(§11.6): un limite deciso una volta all'ingresso in `charging`, mai più toccato, che con due
auto sulla stazione 2 sommava 150 + 50 = 200 kW su un sito da 180. Questo passo chiude quel
buco. Le decisioni che seguono sono quelle da difendere all'orale.

### 12.1 La politica: quota equa con travaso, non proporzionale né prenotati-prima

SCOPE §3.5 chiede che la politica sia una decisione esplicita fra tre. È la quota equa con
travaso — il max-min fair share dei libri di reti:

> si parte da `budget / N`; chi non riesce ad assorbire la propria quota prende solo quello
> che gli serve e **restituisce l'avanzo**, che viene ridiviso fra i rimanenti; si ripete
> finché nessuno avanza più niente.

Le tre ragioni, in ordine di peso:

- **All'orale si difende in una riga.** "A ciascuno la stessa quota, e chi non la usa la
  restituisce." Il proporzionale-alla-domanda va difeso come scelta *politica* — "le auto
  grandi contano di più" — che è una posizione scomoda da tenere; i prenotati-prima
  affamerebbero un walk-in fino alla sospensione, in contraddizione con §3.3, dove la
  penalità toglie il prenotare, non il caricare.
- **La resa non discrimina fra le prime due.** Il travaso è ciò che impedisce a un kW di
  restare inutilizzato mentre qualcuno potrebbe assorbirlo, ed è il difetto della quota equa
  *senza* travaso — l'unica variante davvero poco performante. Il proporzionale non eroga di
  più: satura lo stesso budget, cambia solo chi prende cosa.
- **È più semplice, non più complicato.** Un giro su una lista, una ventina di righe pure. Il
  proporzionale sembra più semplice finché non si aggiungono i cap: appena una domanda satura
  il proprio `max_kw` serve comunque il giro di ridistribuzione — lo stesso ciclo, con in più
  una moltiplicazione da spiegare.

### 12.2 `vs_power` è un modulo puro: nessun processo, nessuna env, nessun orologio

`allocate(Budget, Sessioni, MinChargeKw) -> #{conn_id => kW}` e `demand_kw/3` sono funzioni
dei loro argomenti e basta. Le soglie arrivano come parametri: le legge il manager, una volta,
dall'ambiente. Costa una firma a tre argomenti invece che a due, e in cambio la parte del
progetto che vale la pena mostrare si prova con una lista e un numero — i sei scenari attesi
sono sei test da tre righe, senza stazione, senza ETS, senza `timer:sleep`.

La divisione del lavoro è la stessa di sempre: il manager è il solo processo che conosce
insieme il budget del sito e tutte le sessioni, e distribuisce con `vs_connector:set_limit/2`;
il connettore continua a non sapere niente dei suoi vicini.

### 12.3 La soglia del taper è sul SoC, non su "assorbe meno di quanto gli ho dato"

`demand_i` non è `max_kw`: §3.5 vuole che il tick tenga conto della curva di carica. Sotto
`TAPER_SOC_PCT` (80) la domanda è `min(rated_kw, max_kw)`; da lì in su è
`min(rated_kw, max_kw, power_kw + TAPER_MARGIN_KW)`, con margine 5 kW.

**La regola alternativa si morde la coda, ed è il motivo per cui non è quella.** "Chiedi
quanto stai assorbendo, più un margine" sembra più diretta, ma il `meter` subito dopo il
`plugged` riporta `power_kw = 0`: la domanda diventerebbe 0 + 5, e l'auto resterebbe strozzata
a salire di 5 kW per tick — una sessione affamata da un algoritmo che si credeva prudente. La
soglia sul SoC non ha questo lock-in, perché a inizio sessione il SoC è basso, e coincide con
la fisica che l'emulatore già riproduce (taper sopra l'80%, §11.12).

Il **margine** ha un compito preciso e uno solo: far risalire la domanda da sola se l'auto
riprende ad assorbire. Senza, l'allocatore registrerebbe il minimo che ha visto e non lo
lascerebbe più tornare indietro.

**Il lock-in ha un gemello, e la soglia sul SoC da sola non lo chiude.** Trovato in revisione,
non dai test, dopo che il passo era già scritto. Una sessione sospesa sta a `limit_kw = 0`,
quindi il suo `meter` successivo riporta `power_kw = 0` — perché le abbiamo tolto la corrente,
non perché la batteria sia piena. Sopra la soglia il ramo del taper leggeva quello zero e
rispondeva 5 kW: sotto `MIN_CHARGE_KW`, quindi `demand`-bound, quindi la prima che `victim/1`
sceglie. Sospesa di nuovo a ogni ricalcolo, **a qualunque budget, per sempre** — un'auto lasciata
a zero su un sito vuoto.

Perciò il ramo del taper chiede due cose invece di una: **sopra la soglia e con potenza
concessa**, cioè `limit_kw =/= 0.0`. Un contatore letto mentre il limite è zero misura la
decisione della stazione, non la curva dell'auto, e la lettura onesta di una sessione che non
stiamo alimentando è che vuole tutto quello che può prendere.

È lo stesso errore della regola scartata sopra — dedurre la domanda da un `power_kw` che non
parla della batteria — rientrato da un'altra porta. La differenza fra i due casi è che il primo
si vedeva a inizio sessione e questo solo dopo una sospensione, che con i budget veri non
capita mai: per questo nessun test lo aveva preso. Adesso ce ne sono due, e il secondo è il
ciclo completo (sospendi, gli altri se ne vanno, deve risalire), perché il test unitario sulla
domanda da solo non descrive il difetto — descrive un numero.

### 12.4 La sospensione: l'ultimo arrivato se manca il budget, chi non è aiutabile se manca la domanda

§3.5 chiede una potenza minima sotto la quale una sessione è **sospesa** invece che affamata.
Sospesa significa `set_limit 0`: la sessione resta aperta e non eroga, che è esattamente come
la esprime ws-chargepoint.md §5.

*Chi* viene sospeso dipende da cosa ha causato la fame, e sono due cose diverse:

- **manca il budget** — la quota è sotto soglia perché ci sono troppe auto per il sito. Va
  l'**ultimo arrivato** (`started_at` maggiore, id del connettore a rompere la parità sul
  millisecondo). Stabile per costruzione: `started_at` non cambia nel tempo, quindi l'insieme
  dei sospesi non oscilla fra un tick e l'altro finché nessuno arriva o parte. Una regola
  basata sul SoC cambierebbe idea da sola a ogni lettura del contatore.
- **manca la domanda** — la sessione chiede da sola meno della soglia (`max_kw` piccolo, o
  taper a fine carica). Sospendere qualcun altro non può aiutarla: nessun budget liberato
  alza una sessione sopra quello che sta chiedendo. Quindi va lei, indipendentemente da
  quando è arrivata.

Il secondo caso è un **raffinamento della regola del piano**, deciso prima di scrivere il
codice. Con la regola letterale ("sempre l'ultimo arrivato") domande di 3 e 50 kW su un budget
di 180 sospendono prima la 50, lasciano la 3 ancora sotto soglia, sospendono anche quella, e
il sito finisce per non allocare niente con 180 kW liberi: la parte sbagliata punita, e poi
tutte. I sei scenari attesi del piano sono identici sotto le due letture; cambia solo questo
angolo. La proprietà che ne esce — **nessuna allocazione sta fra 0 e `MIN_CHARGE_KW` esclusi**
— è un test, non un commento.

**Con i budget veri la sospensione non è raggiungibile**, e va detto invece di lasciar credere
che il caso sia stato visto girare: 350/4 = 87.5 e 180/3 = 60 sono entrambi molto sopra i 6 kW.
Resta dimostrata da test unitari con budget forzato; per mostrarla nella demo serve un
`SITE_POWER_KW` ridotto via ambiente, non una modifica al codice.

### 12.5 `allocated_kw` cambia significato: allocato, non erogato

Fino a M1 era la somma dei `power_kw` misurati — un numero su cui i contatori erano d'accordo,
in mancanza di qualcuno che allocasse davvero. Adesso qualcuno alloca, e il campo dice quello:
**la somma dei limiti concessi**.

La conseguenza da accettare: la pagina mostra un numero più alto di quanto le auto stanno
realmente prendendo, e la differenza è tutta quando un'auto è in taper o in rampa. È la
lettura giusta per chi guarda quanto sito è impegnato — l'alternativa direbbe che il sito è
libero mentre ogni presa è occupata. In cambio si ottiene l'invariante del passo, vera per
costruzione e non per fortuna: `allocated_kw =< site_power_kw`.

Il valore si legge dall'allocazione **memorizzata** nel manager, non risommando gli snapshot:
`station_state` e `subscribe` restano letture pure, e una `build_state` che ricalcolasse
sarebbe una lettura con un effetto collaterale su ogni connettore.

### 12.6 `suspended` è derivato nello snapshot, non un sesto stato del `gen_statem`

`build_snapshot` riporta `suspended` per uno stato `charging` con `limit_kw =:= 0.0`. Al
contrario di `out_of_service` (§11.3, dove lo stato vero era la scelta giusta), qui non cambia
**nessuna** risposta del connettore: l'autorizzazione è la stessa, la sessione è viva, gli
eventi che accetta sono gli stessi. Cambia solo quanto scorre.

Uno stato vero oscillerebbe avanti e indietro a ogni ricalcolo che attraversa la soglia, con
`enter`/`exit` a raffica per un valore che è cambiato; un valore derivato non può oscillare
perché non c'è niente che oscilli. `wire_connector_state/1` lo lascia passare con la clausola
`Other -> Other` e l'enum di ws-driver.md §5.1 lo contiene già: nessun contratto si tocca.

**Il tranello, ed è quello che si sbaglierebbe.** Il manager rilegge gli snapshot per costruire
il riparto, e dopo questa modifica vede `suspended` dove prima vedeva `charging`. Un filtro su
`state =:= charging` toglierebbe la sessione dal riparto **nel momento stesso in cui la
sospende**: l'allocatore smetterebbe di vederla, non le riassegnerebbe mai niente, e la fame
diventerebbe permanente invece di durare un tick. `vs_power:demands/3` accetta entrambi gli
stati, ed è la ragione per cui c'è un test che si chiama
`a_suspended_session_still_takes_part_test`.

Stesso motivo, dall'altra parte: `vs_claim_client:count_stats/1` ha adesso una clausola
`suspended` esplicita. Senza, il catch-all esistente l'avrebbe fatta sparire dalle tre
statistiche mandate al coordinatore, e la lobby avrebbe mostrato come disponibile una presa
con dentro la macchina di qualcuno.

### 12.7 Il ricalcolo non deve poter innescare se stesso

`charging(cast, {set_limit, _})` **non emette `notify`**, e non deve iniziare a farlo. Se lo
facesse, ogni `set_limit` produrrebbe un `connector_event`, che farebbe ricalcolare, che
manderebbe un `set_limit`: un ciclo a piena velocità, non una perdita lenta. Il limite arriva
comunque alla pagina con la rilettura periodica da 5 s del canale driver.

Due momenti di ricalcolo, che sono i due di §3.5:

- **ogni `connector_event`** — arrivi, partenze, cambi di stato. Il gancio esisteva già e
  faceva `broadcast`; adesso ricalcola e poi trasmette. **L'ordine non è casuale**: i cast di
  `set_limit` partono prima che `build_state` rilegga i connettori, e fra due processi l'ordine
  dei messaggi è garantito — quindi ogni connettore ha già applicato il suo limite quando
  risponde alla `snapshot`, e lo stato che i sottoscrittori ricevono porta i valori nuovi,
  `suspended` compreso.
- **un tick `POWER_TICK_MS`** (5000, allineato a `METER_INTERVAL_S`) — l'unica cosa che può
  accorgersi del taper, perché una lettura `meter` non produce eventi di proposito: una per
  connettore ogni 5 s inonderebbe ogni pagina aperta di un cambiamento che non c'è stato.
  Il tick **non fa broadcast**: `vs_driver_ws` rilegge lo stato per conto suo sul proprio
  `STATE_TICK_MS`, quindi un cambio dovuto al taper arriva alla pagina entro gli stessi cinque
  secondi, e spingere da tutte e due le parti raddoppierebbe il traffico per dirlo due volte.

`set_limit` va a **tutte** le sessioni attive a ogni ricalcolo, anche a valore invariato: è
ws-chargepoint.md §5 alla lettera — idempotenza per ripetizione, non diffing — e significa che
una colonnina che ha perso un frame torna giusta entro un tick invece di restare su un limite
vecchio per sempre.

*Effetto collaterale osservato nell'E2E, lato emulatore — poi corretto.* `cp.js` confrontava il
limite in arrivo con quello **interpolato** in quel momento invece che con il proprio bersaglio,
quindi non riconosceva come ripetizione proprio i comandi che §5 impone di ripetere: la rampa
ripartiva dal punto corrente con una finestra nuova, e si allungava a ogni tick. Convergeva, ma
il tempo di applicazione misurato nella demo sarebbe stato più lungo di quello vero —
l'emulatore che fa sembrare la stazione peggiore di quanto è, che è lo stesso peccato del
farla sembrare migliore.

Il confronto è ora con `limit.target`. Una ripetizione vera esce subito; un valore diverso
riparte da `appliedLimit(now)`, che resta il punto di partenza giusto perché l'hardware è dov'è,
non dove gli era stato detto di arrivare. Misurato dopo la correzione: `20 → 150` e poi quattro
`set_limit 20` a un secondo l'uno dall'altro producono **una sola** riga di log, e il contatore a
+3.4 s legge 36.7 kW — esattamente l'interpolazione da un'unica partenza, cioè la prova che la
rampa non è ripartita.

### 12.8 Le variabili nuove non entrano nei contratti

`MIN_CHARGE_KW` era già in ws-driver.md §10 e resta lì. `POWER_TICK_MS`, `TAPER_SOC_PCT` e
`TAPER_MARGIN_KW` sono interne alla stazione: nessun'altra parte del sistema le osserva, e
metterle in un contratto vorrebbe dire chiedere agli altri di conoscerle. Sono documentate
qui, con il loro default, e sono anche opzioni di `vs_station_mgr:start_link/1` — come
`lease_seconds` — perché altrimenti provare il tick vorrebbe dire dormire cinque secondi.

| Variabile | Default | Significato |
|---|---|---|
| `POWER_TICK_MS` | `5000` | periodo del ricalcolo periodico, quello che vede il taper |
| `TAPER_SOC_PCT` | `80` | sopra questo SoC la domanda segue il contatore invece dei cap |
| `TAPER_MARGIN_KW` | `5` | quanto sopra il misurato si chiede, per poter risalire |
| `MIN_CHARGE_KW` | `6` | già in ws-driver.md §10: sotto, sospeso invece che affamato |
