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

---

## 13. La riga su `sessions` (`vs_station_db`) — M2-A passo 3

Fino a qui `vs_station_db` era un modulo senza processo che scriveva la sessione nel log. Adesso
scrive davvero. La parte interessante del passo non è l'INSERT — sono venti righe di SQL — ma
**chi aspetta chi**.

### 13.1 L'INSERT è un cast, e il connettore non aspetta mai il database

`vs_connector:closing/3` chiamava `insert_session/1` **in linea, dentro il gen_statem**. Con
uno stub dietro era un microsecondo; con MySQL dietro sarebbe stato un giro di rete dentro la
macchina a stati che governa una presa fisica. Se il database è lento il connettore resta in
`closing`; se è irraggiungibile ci resta per il timeout, e la stazione smette di liberare le
prese — per il guasto di un componente che non serve a caricare le auto. È esattamente ciò che
SCOPE §4 (autonomia della stazione) vieta, ed è anche la regola strutturale concordata con B:
**i connettori non fanno chiamate remote.**

Quindi `insert_session/1` è un cast: accoda e torna.

```
connettore closing(enter) --cast--> vs_station_db --INSERT--> MySQL
                                          |
                                          +--> vs_claim_client:session_closed/1 --> leader --> Java
```

Tre conseguenze, tutte volute:

- il connettore torna `free` alla velocità della propria macchina a stati, qualunque cosa faccia
  il database — **misurato: 12 µs con MySQL su, 44 µs con MySQL fermo**;
- l'evento `session_closed` verso Java parte **dopo** l'INSERT e lo manda il claim client, mai il
  connettore: la regola di confine si realizza da sé invece di essere una raccomandazione;
- il `SessionId` che l'evento richiede (erlang-java.md §2.3) esiste solo dopo l'INSERT, quindi
  quello è l'unico posto da cui la catena può partire. `insert_session/1` non lo restituisce più
  a nessuno: al connettore non serve, e restituirlo vorrebbe dire farlo aspettare.

**Il prezzo, dichiarato invece che nascosto.** Una riga ancora in coda quando il nodo muore è
persa. La finestra è la durata di un INSERT più quello che c'è in coda davanti: millisecondi con
MySQL sano, quanto dura il guasto quando non lo è. L'alternativa — un write-ahead su disco, o un
INSERT sincrono con conferma — ricomprerebbe una sessione non fatturata in un guasto raro
pagandola con l'autonomia della stazione in **ogni** guasto del database. È lo scambio sbagliato,
ed è il punto del passo.

### 13.2 Coda, ritenta, e il tetto che scarta la più vecchia

Coda in memoria, ritentata ogni `DB_RETRY_MS` (5000). Oltre `DB_QUEUE_MAX` (100) righe si scarta
la **più vecchia**, con un `logger:error` che riporta la riga intera: se il database è giù da
otto minuti la sessione più utile da salvare è l'ultima, e quella riga di log è l'ultima copia
che resta di quella che si butta.

Niente deduplicazione e niente riordino. L'UPDATE di B è condizionato a `cost_cents IS NULL`
(erlang-java.md §2.3), quindi una riga scritta due volte non fattura due volte: **at-least-once
su una scrittura idempotente**, che è il modo di ottenere il comportamento "esattamente una
volta" senza un canale che lo garantisca. All'orale si dice con queste parole.

**Due fallimenti che si somigliano e non sono la stessa cosa.** Se il server *risponde* con un
errore (una foreign key che non risolve, un valore fuori scala) la riga è sbagliata e lo sarà
anche al prossimo tentativo: ritentarla per sempre incastrerebbe dietro di sé ogni sessione
successiva, quindi si scarta lì con un log. Se invece la chiamata *esplode*, la connessione non
c'è più e la riga non è mai arrivata: quella si tiene. La distinzione è una clausola sola e
senza di essa la coda si sarebbe potuta bloccare su una riga difettosa.

**Il difetto che l'E2E ha trovato e i test no.** Il timer del ritenta fa due lavori — svuotare la
coda **e** riaprire la connessione — e nella prima stesura una coda vuota lo cancellava. Una
stazione che aveva scritto tutto quello che aveva e poi perdeva MySQL si trovava con coda vuota e
nessuna connessione: cancellava la propria riconnessione e non ne apriva più un'altra. MySQL
tornava su e la stazione continuava a rifiutare ogni walk-in, perché `user_for_vehicle/1`
rispondeva `no_connection` per sempre, senza un errore da nessuna parte che lo spiegasse. Le due
clausole di `flush/1` sono ora nell'ordine opposto, e c'è un test che tiene il guasto più lungo
del primo ritenta — senza quello il difetto è invisibile.

### 13.3 I tempi: epoch ms dentro, DATETIME fuori, UTC in mezzo

`sessions.started_at`/`ended_at` sono `DATETIME` e il connettore produce epoch in millisecondi.
La conversione si fa **in Erlang, verso UTC** (`calendar:system_time_to_universal_time/2`) e non
con `FROM_UNIXTIME()` in SQL: `FROM_UNIXTIME` lavora sul `time_zone` della sessione MySQL, che è
una variabile d'ambiente del container di qualcun altro invece di una decisione presa da noi — la
stessa classe di errore invisibile della discussione secondi-contro-millisecondi sul confine
Java.

*Verificato, e vale la pena averlo guardato:* il container MySQL gira con `time_zone = SYSTEM` e
`NOW()` uguale a `UTC_TIMESTAMP()`. Cioè oggi `FROM_UNIXTIME` avrebbe dato lo stesso risultato —
ed è esattamente il motivo per cui non la si usa: funzionerebbe finché nessuno cambia il fuso del
container, e il giorno che qualcuno lo cambia le date sbagliano di un'ora senza che niente
fallisca.

UTC è anche quello che fa già B: `Db.java` apre la connessione con `serverTimezone=UTC` e
`SessionDao` legge con `getTimestamp(...).toLocalDateTime()`. È una convenzione già in vigore
dall'altra parte, quindi si rispetta e si verifica, non si concorda di nuovo.

L'evento verso Java tiene invece i **millisecondi**, perché il contratto è esplicito che ogni
cifra su quel confine è in millisecondi e `OverstaySeconds` è l'unica eccezione, con l'unità nel
nome. Riga in DATETIME, evento in ms, dalla stessa mappa.

### 13.4 Una connessione sola, e l'unica funzione sincrona

Un pool sarebbe sovradimensionato per una stazione con quattro prese, e una connessione condivisa
fra più processi vorrebbe un lock. Questo processo ne tiene **una** ed è l'unico che la tocca: la
serializzazione diventa un fatto strutturale invece che una configurazione.

`user_for_vehicle/1` è l'unico ingresso **sincrono**, e può permetterselo: sta sul percorso di un
`plugged`, il chiamante è un processo socket e non un connettore, e senza la risposta non si può
decidere se autorizzare un walk-in. Ha un timeout esplicito, quindi il caso peggiore è un walk-in
rifiutato con una riga di log, mai un socket appeso.

**La conseguenza da sapere, misurata:** con MySQL fermo un walk-in **non può iniziare** — la
risoluzione veicolo→utente non ha risposta e il `plugged` viene rifiutato
(`no account for vehicle 2 (no_connection)`). Le sessioni già in corso invece si chiudono
normalmente e la loro riga si accoda. L'autonomia della stazione vale quindi per *finire* di
caricare, non per *cominciare*: e va detto, perché il commento di D1 sostiene che
`user_for_vehicle` sta alla stazione invece che al coordinatore proprio per non mettere una
chiamata remota sul percorso del walk-in — ma MySQL è remoto quanto il coordinatore. Il beneficio
reale di quella scelta è un altro, ed è comunque vero: `vehicles` è una tabella del back office
che il coordinatore non tiene, quindi chiederla a lui vorrebbe dire farla replicare a un processo
che non la possiede.

### 13.5 Lo stub identità se ne va, e con lui un veicolo che non esisteva

`user_for_vehicle/1` era lo stub-identità del passo 1: rispondeva `{ok, VehicleId}` e lo scriveva
nel log. Adesso è `SELECT user_id FROM vehicles WHERE id = ?`, e un veicolo che la tabella non ha
viene **rifiutato** invece che inventato.

Conseguenza pratica per la demo: il seed ha solo i veicoli 1 e 2, quindi l'emulatore va lanciato
con `--vehicle 1` o `--vehicle 2`. Il `--vehicle 88` degli esempi del passo 1 funzionava solo
perché lo stub mentiva, e adesso produce
`no account for vehicle 88` — che è la risposta giusta, non una regressione.

### 13.6 Dove va nell'albero, e perché per ultimo

`vs_station_db` è ora un figlio di `vs_station_sup`, in coda. Essere ultimo non costa niente:
si connette da un `handle_continue`, quindi un database giù non ritarda nessun fratello, e i
connettori sopra di lui gli mandano solo cast. Sta **dopo** `vs_claim_client` perché è quello che
chiama quando una riga è scritta, e in quest'ordine la sveglia verso Java non trova mai una
mailbox che non c'è ancora.

L'unica cosa che il suo riavvio costa sono le righe ancora in coda dentro di lui: è la finestra
di perdita di §13.1, e il `terminate/2` la scrive nel log riga per riga invece di lasciarla
scoprire dopo.

> **Un limite di questa riga, misurato dopo e poi chiuso.** Per una sessione che attraversava un
> riavvio della stazione l'energia era giusta e la **durata no**: `started_at` finiva per essere
> l'istante dell'adozione, non quello del cavo. Il fatto e il perché stanno in §16.8, la
> correzione — una durata che arriva dall'hardware, mai un istante — in §18.1.

---

## 14. Correzioni lotto 1 — quello che il driver paga (M2-A fix 1)

La review di M2-A (`REVIEW_M2A_ESITO.md`) ha trovato nove difetti. I quattro di questo lotto
hanno in comune una cosa: nessuno rompeva un test, e tutti cambiavano quanto un driver paga o
se paga. Gli altri cinque restano al lotto 2.

### 14.1 La finestra di `closing`, e cosa costa

Fino a qui `closing` scriveva la riga **in entrata**. Su due dei cinque modi di arrivarci —
`stop_session` e `revoke` — quella è una frame troppo presto: entrambi cominciano mandando un
comando `stop` all'hardware, e §5 dice che la colonnina lo applica e *riferisce il risultato*.
Lo riferisce con l'`unplugged` che porta il totale vero (`cp.js`, `onStop` → `unplug`). Il
connettore era già in `closing`, dove i cast tardivi venivano assorbiti senza guardarli, e in
`sessions` finiva l'ultimo `meter`: fino a `METER_INTERVAL_S` di energia regalata, che a
150 kW sono 0,208 kWh — nove centesimi su ogni sessione chiusa dal driver, sistematici.

Ora `closing` non scrive in entrata: arma un `state_timeout` di `CLOSING_SETTLE_MS`
(nuovo, default 2000) e ascolta. Dentro la finestra un `meter` conta ancora, con lo stesso
`max` monotono di `charging`; un `unplugged` chiude l'attesa **subito**, perché è l'ultima
parola dell'hardware e non c'è altro da aspettare. Il principio del passo 3 non cambia — tutto
ciò che deve accadere una volta sola accade in un punto solo, `settle/1` — quel punto si è
spostato dall'entrata all'uscita.

Il percorso più comune non paga niente: `charging(cast, {unplugged, E})` non applica più
l'energia da sé, **posta l'evento in avanti** con `{next_event, cast, {unplugged, E}}`. Così
`closing` lo consuma un istante dopo l'`enter`, liquida immediatamente, e c'è **un solo posto**
che sa leggere un `unplugged` invece di due che devono restare d'accordo.

Il prezzo, dichiarato invece che scoperto dopo:

* l'outlet resta in `closing` fino a `CLOSING_SETTLE_MS` in più — invisibile al driver, che la
  sessione la vede finita comunque;
* il `release` del claim slitta di altrettanto; il claim scade in minuti, quindi non se ne
  accorge nessuno;
* la potenza allocata rientra nel pool entro il `power_tick` successivo, o alla liquidazione
  se la finestra si chiude prima. `closing` non emette nessun evento in entrata, quindi il
  manager non ricalcola *subito*; ma `vs_power:is_live/1` non conta `closing`, quindi un tick
  che cada dentro la finestra libera già la quota. Il caso peggiore è la finestra intera
  senza tick in mezzo: due secondi su un tick da cinque, al più mezzo tick di budget fermo su
  un sito che sta liberando un outlet. Accettato; se un giorno desse fastidio, la risposta è
  un evento sull'entrata in `closing`, non una finestra più corta.

Due secondi non sono un numero tondo scelto a caso: §5 dà all'hardware `LIMIT_APPLY_SECONDS`
(5) per onorare un limite, e `METER_INTERVAL_S` è 5. Due stanno comodamente sotto entrambi,
quindi la finestra non aspetta mai un tick di `meter` che non stava per arrivare.

### 14.2 L'offset dell'energia, e perché due adozioni diverse dietro lo stesso frame

`§4.3` dice che ogni cifra della colonnina è **cumulativa dall'inizio suo**, e la colonnina non
sa niente delle sessioni che finiscono. Quando la stazione chiude una sessione **lasciando il
cavo attaccato** — la grazia scaduta di §3.2, il guasto di §4.1 — l'hardware continua a
contare da dove contava, e il `plugged` con cui riannuncia il cavo (§6.2) porta un cumulativo
che **comprende la riga appena scritta**. Adottarlo intero era il doppio addebito: venti kWh
erogati, trentadue fatturati.

Il punto delicato è che lo **stesso frame** arriva in due situazioni diverse:

* **il nodo è morto** (§6, il caso per cui il contratto prescrive l'adozione): non esiste
  nessuna riga, nessuno ha contato quell'energia tranne la colonnina, e adottare il cumulativo
  intero è giusto;
* **il connettore è vivo e ha già scritto** (la grazia, il guasto): la riga c'è, e riadottare
  il cumulativo la fattura una seconda volta.

Non serve una bandiera per distinguerle, e infatti non ce n'è una. `#data.energy_billed` è il
cumulativo che l'hardware riporterà la prossima volta, scritto da `settle/1` solo sulle due
uscite che finiscono in `out_of_service` — le due che lasciano il cavo dentro. Un processo
appena avviato ha il campo a `0.0`, quindi **dopo un riavvio del nodo l'offset è zero e
l'adozione del contratto si comporta esattamente come prima**: la differenza fra i due casi è
la memoria del processo, che è precisamente ciò che li distingue nella realtà.

Tre dettagli che non sono decorazione:

1. **Si porta avanti il cumulativo, non la fetta.** `carried/2` somma `energy_kwh +
   energy_offset`, così due guasti di fila sullo stesso cavo sottraggono tutta la storia e non
   solo l'ultimo tratto. Con la fetta soltanto, il terzo tratto sarebbe stato rifatturato.
2. **L'offset vive nella sessione, non solo nel seme.** `#session.energy_offset` viene
   sottratto da *ogni* lettura successiva — `meter` e `unplugged` — prima del `max` monotono.
   Sottrarlo solo all'adozione avrebbe rimesso l'intero cumulativo nella riga finale.
3. **Si decide una volta, all'adozione.** Se il cumulativo riportato è **almeno** quanto era
   già stato fatturato, l'hardware sta ancora contando la stessa erogazione e l'offset vale. Se
   riporta **meno**, il suo contatore è ripartito — un'altra auto, un riavvio del firmware, uno
   scollegamento che non abbiamo visto — e un offset che si riferisce a un'erogazione conclusa
   non significa niente: si butta e il payload si prende per quello che dice. Senza questo, i
   2 kWh onesti di un'auto nuova sarebbero stati fatturati zero.

L'offset viene consumato da **tutte e tre** le porte verso `charging` (`free`, `held`,
`out_of_service`), non solo da quella di §6: il percorso `guasto → out_of_service →
available → free → plugged` adotta da `free`, ed è un percorso reale.

**Residuo dichiarato.** `stop_session` e `revoke` non portano avanti nessun offset, perché
finiscono in `free` e la lettura è "alla macchina è stato detto di smettere". Con `cp.js` è
vero — risponde al `stop` staccando — ma un hardware reale potrebbe tenere il cavo dentro e
non azzerare il contatore. In quel caso un `plugged` successivo verrebbe adottato intero. Non
è un difetto dimostrato e nessuna prova della review lo copre; è scritto qui perché sia una
scelta e non una dimenticanza.

### 14.3 `vs_station_db`: tre guasti, tre prezzi, tre risposte

`flush/1` scrive la testa della coda e si ferma se la testa non passa, quindi **come** fallisce
una scrittura decide se tutte le sessioni dietro si muovono. Prima ce n'era una sola risposta
per due guasti diversi, ed è così che una riga sola incastrava la coda per sempre.

* **La riga non si sa codificare** — `insert_params/1` solleva, perché manca un campo o non è
  quello che la colonna prende. Non è partito niente e non partirà mai: la riga solleverà
  uguale fra un'ora. Scartata subito, con il `logger:error` che ne è l'ultima copia. È valutata
  **fuori** dalla `try` attorno alla query, così "non riesco a costruirla" e "non sono riuscito
  a mandarla" smettono di essere lo stesso evento — che è esattamente l'errore che le teneva
  insieme.
* **Il server ha risposto un errore** — torna `{error, _}`. Un `server_reason()` viene scartato
  come prima; qualunque altra forma viene contata sulla riga (`MAX_ROW_ATTEMPTS`, 5) e scartata
  quando i tentativi sono finiti. Non si prova a indovinare quali codici MySQL siano
  permanenti: la lista dipende dalla versione del server e sarebbe sbagliata il giorno dopo.
  Cinque tentativi falliti sono la prova empirica.
* **La scrittura non è partita** — la chiamata solleva. La connessione non c'è e la riga non è
  mai arrivata. Riprovata per sempre e **non contata**: un'interruzione lunga non deve bruciare
  i tentativi di righe che non hanno ancora avuto la loro occasione. Con `conn = undefined`
  `flush/1` non arriva nemmeno a `write/4`, quindi un'interruzione normale non costa niente.

Il contatore vive nella coda (`{Row, Attempts}`) ma **non esce di lì**: `queued_rows` risponde
con le righe nude, perché quello che un test chiede è quali sessioni non sono scritte, mai
quante volte ci si è provato.

### 14.4 L'annuncio non è protetto insieme all'INSERT

`announce/3` stava nel corpo dopo `of`, che in Erlang **non è coperto** dal `catch` della
stessa `try`: è una regola del linguaggio, non una svista. Leggere l'id inserito è a sua volta
una chiamata alla connessione, quindi una connessione che moriva fra l'INSERT riuscito e quella
lettura faceva uscire l'eccezione dal gen_server, e il writer si portava dietro tutta la coda.

I due guasti non valgono lo stesso: un annuncio perso costa **una ricevuta prezzata un minuto
dopo** (B spazza `cost_cents IS NULL`), un writer morto costa **tutte le righe in coda**. La
differenza di prezzo è il motivo per cui adesso hanno una rete per uno.

---

## 15. Correzioni lotto 2 — potenza, tempi, cosmetica (M2-A fix 2)

I cinque difetti restanti della review. Nessuno tocca quanto si paga: due toccano cosa il
driver vede, uno il tempo di reazione a un guasto, uno l'onestà di un log, e il primo è una
regola sbagliata alla radice.

### 15.1 Si sospende solo per scarsità — e perché la versione precedente era sbagliata

`MIN_CHARGE_KW` esiste perché una sessione **strozzata dalla scarsità** è meglio sospesa che
affamata: sotto i 6 kW un'auto non carica in modo utile, e tenere venti sessioni a 3 kW non
serve a nessuno. Quella soglia parla della scarsità, non della domanda.

La versione precedente non faceva questa distinzione. Divideva le affamate in due — a corto di
budget, oppure a corto per domanda propria — e sospendeva per prime le seconde, con
l'argomento che nessun budget liberato può alzare una sessione sopra ciò che chiede.
**L'argomento è vero e la conclusione non ne segue:** una sessione così non ha bisogno di
essere alzata, perché nessuno la sta tenendo giù. Il budget che le si toglie non serviva a
nessun altro, e portarla a zero non libera niente.

Da lì nascevano due difetti, che sono lo stesso visto da due lati:

* **D-3, l'oscillazione.** Un'auto quasi carica che assorbe 0,5 kW ha domanda `0,5 + margine
  = 5,5`, sotto il minimo → sospesa → limite zero → `tapering/2` vede il limite a zero e
  riporta la domanda al massimo → rientra a piena potenza → l'auto torna ad assorbire 0,5 →
  sospesa di nuovo. Due tick, per sempre, **su un sito vuoto con 350 kW liberi.** È la stessa
  dinamica del lock-in già corretto una volta in `demand_kw/3`: la toppa di allora l'aveva
  trasformata da blocco in oscillazione invece di rimuoverla.
* **D-4, la sessione senza `max_kw`.** Domanda zero → sotto il minimo e pari alla domanda →
  `victim/1` la preferiva a chiunque → sospesa a ogni ricalcolo, con qualunque budget.

**La regola adesso.** Una sessione è affamata se la quota è sotto `MIN_CHARGE_KW` **e** sotto
ciò che chiede. Chi riceve tutto quello che domanda non è sospendibile, qualunque cifra sia.
Sparisce la distinzione in `starved/3` e con essa la precedenza in `victim/1`, che torna alla
regola semplice: fra le affamate, l'ultima arrivata, `conn_id` a spezzare la parità.

Il caso limite resta stabile: budget 3 kW e una sola auto → quota 3, sotto il minimo **e**
sotto la domanda → sospesa; al tick dopo il limite è zero, la domanda torna al massimo, la
quota è ancora 3 → sospesa di nuovo. Stessa decisione a ogni giro: con tre kW non si carica
nessuno, ed è la risposta giusta.

Il corner che aveva motivato la vecchia regola — domande di 3 e 50 kW contro 180 di budget —
viene fuori giusto senza di essa: la piccola prende 3, la grande 50, nessuno è sospeso perché
nessuno è a corto. I sei scenari di `PIANO_POTENZA.md` §8 danno numeri **identici** a prima
(150 / 130-50 / 80-50-50 / 100-100-100-50 / 127,5-127,5-45-50 / 7,5-7,5-0): la nuova regola
non cambia i casi ordinari, toglie solo una sospensione che non serviva.

Una proprietà del sweep è stata riformulata di conseguenza. Era «un'allocazione è zero oppure
almeno `MIN_CHARGE_KW`»; ora è «zero, oppure almeno `MIN_CHARGE_KW`, **oppure esattamente ciò
che la sessione ha chiesto**». Non è un indebolimento: è la proprietà detta bene. Nessuno
viene ridotto a un rivolo; chi vuole un rivolo lo ottiene.

`demand_kw/3` non è stata toccata, e il ramo del taper con il suo margine resta com'è: la
correzione non era lì.

### 15.2 `max_kw` è obbligatorio, e si fa rispettare a monte

Con la nuova regola una sessione senza `max_kw` non viene più *sospesa* — ma la sua domanda
resta zero, quindi resta a zero lo stesso, e senza che nessuno lo dica. La regola di
sospensione non era il posto giusto per accorgersene.

`ws-chargepoint.md` §4.2 rende `max_kw` obbligatorio, e il posto per farlo rispettare è la
validazione del payload in `vs_cp_proto`, non l'allocatore: un `plugged` senza `max_kw`, o con
un valore non positivo, è **rifiutato** — `logger:error` con il payload intero, nessuna
sessione aperta, nessun frame di risposta. Rifiutato esattamente come `invalid_state`: §5 non
ha una reason `stop` per «il tuo payload è incompleto», e inventarne una allargherebbe un
contratto che è di A. Il prossimo `status` riconcilia (§7.6).

Il commento di `vs_connector` che prometteva «the next `set_limit' — one tick, in M2 step 2 —
corrects it» è stato corretto: non poteva correggerlo, perché `demand_kw/3` legge lo stesso
campo. Il connettore mantiene la sua difesa (`min` con uno zero è zero, detto onestamente), ma
adesso è una difesa per un payload che non dovrebbe più arrivarci.

### 15.3 Nessuna riga sparisce in silenzio

`insert_session/1` è un cast, e una cast a un nome non registrato ritorna `ok` e sparisce. Era
l'unico punto del sistema in cui una sessione finita poteva svanire **senza lasciare niente**:
il connettore fa match sull'`ok' e prosegue convinto di aver consegnato.

Ora il writer viene cercato prima, e se non c'è la riga finisce in un `logger:error` nella
stessa forma già usata dal cap della coda, dove la riga di log è dichiaratamente l'ultima
copia. Non si tenta di consegnarla comunque — una coda fuori dal writer sarebbe una seconda
coda da tenere allineata alla prima — né di far aspettare il connettore: la regola del passo 3
resta che il connettore non aspetta mai il database, e questo controllo costa un `whereis`.

### 15.4 L'hold sparisce quando la prenotazione è stata consumata

Passando da `held` a `charging` il `#hold` restava nel `#data`, e `build_snapshot/2`
continuava a leggerlo: la pagina vedeva `held_by_me: true` e l'`expires_at` di una
prenotazione ormai consumata su un connettore che stava caricando. Non è cosmetica innocua —
`held_by_me` è uno dei due campi che `ws-driver.md` §5.1 fa calcolare al server *proprio*
perché il client non debba ragionare sull'identità, e dargli un dato falso è peggio che
farglielo dedurre.

Ora `hold` viene azzerato nella transizione. Il claim non si perde con lui: `session_from/3`
ha appena copiato il `claim_id` nella sessione, e `release/2` lo cerca lì quando l'hold è
`undefined` — verificato prima di toccare il codice, perché se fosse stato falso si sarebbe
perso il rilascio dei claim.

### 15.5 I tre heartbeat sono un budget unico, non due

`vs_cp_ws:idle_timeout_ms/0` e `vs_connector:cp_grace_ms/0` calcolavano **lo stesso prodotto**
(`CP_HEARTBEAT_MISSED × CP_HEARTBEAT_INTERVAL_S` = 90 s) e agiscono **in serie**: cowboy
aspetta 90 s di silenzio e chiude il socket, e solo allora il connettore vede il `DOWN` e ne
aspetta altri 90 prima di dichiarare `out_of_service`. Il contratto §3.2 dice tre heartbeat, il
sistema ne faceva sei: una colonnina guasta restava prenotabile per tre minuti. I commenti di
entrambi i moduli affermavano che i due scadevano «sullo stesso orologio» — stessa *durata*,
non stesso *istante*.

Ripartiti: `(CP_HEARTBEAT_MISSED - 1)` intervalli al socket (60 s), l'ultimo intervallo alla
grazia (30 s). Somma 90, come il contratto.

Perché ripartire e non azzerare la grazia: la grazia non è ridondante, serve al blip di rete di
§1 — il socket che cade per un FIN o un errore, **non** per silenzio, con la colonnina che
riconnette in circa un secondo. Trenta secondi bastano per quella riconnessione e restano
dentro il budget.

**L'alternativa scartata, annotata perché è la strada da prendere se questa ripartizione si
rivelasse troppo rigida:** distinguere le due morti del socket. Chiuso per idle timeout → i tre
heartbeat sono già passati e `out_of_service` è dovuto subito; caduto per altro → grazia piena.
Si farebbe passando al connettore il motivo dalla `terminate/3` di cowboy. È più fedele alla
semantica del contratto e costa un messaggio nuovo sul confine più delicato del passo 1. Non è
stata scelta ora per una ragione che vale la pena scrivere: **il lotto 2 chiude difetti, non
introduce meccanismi.**

## 16. Il frame `session` e la pagina della sessione (M2-A passo 4)

`ws-driver.md` §5.2 era dichiarato «non implementato in M1» per una ragione che non vale più:
portava letture del contatore, e il canale colonnina non esisteva. Ora esiste, i `meter`
arrivano ogni cinque secondi e nessuno li mostrava a chi sta caricando. Questo passo aggiunge
un frame al canale driver e una pagina che lo consuma: non tocca connettori, allocatore né
database, perché tutta la materia era già nello stato che il manager pubblica.

### 16.1 Il frame nasce dallo stesso snapshot del `state`, non da una sottoscrizione propria

Ogni socket driver riceve già lo snapshot completo della stazione — per push e per tick — e
conosce l'identità del suo utente dal `join`. La sessione di quel driver **è** la voce di
`connectors` la cui sotto-mappa `session` porta il suo `user_id`: un `lists:search` su un dato
che passava di lì comunque. Nessuna sottoscrizione nuova, nessuna chiamata al manager, nessuna
seconda lettura.

La conseguenza importante è sui **tempi**, non sulle righe risparmiate. `SESSION_TICK_MS` è
dichiarato in §10 con lo stesso default di `STATE_TICK_MS` (5000), e questo permette a un solo
timer di servirli entrambi: i due frame partono dallo stesso `push/2`, nella stessa lista,
nella stessa `send`. Un timer proprio avrebbe voluto dire una seconda sveglia per socket e —
molto peggio — due frame che descrivono **due istanti diversi della stessa stazione**: la
pagina avrebbe mostrato una potenza letta in un momento accanto a un'energia letta in un
altro, e la somma dei due non sarebbe stata vera in nessun istante.

Il prezzo, detto per intero: `SESSION_TICK_MS` **non viene letto**. Finché il default coincide
con quello di `STATE_TICK_MS` la cosa non si vede; se qualcuno lo cambiasse a un valore
diverso non succederebbe niente. È la variabile a essere ridondante, non il codice a
ignorarla, ma sta scritto qui perché il contratto la dichiara e qualcuno la cercherà.

### 16.2 Un driver senza sessione non riceve nulla — e l'unico stato del socket

§5.2 si rivolge «al proprietario di una sessione in corso». Un frame di zeri sarebbe peggio del
silenzio: la pagina non saprebbe distinguere «non stai caricando» da «la tua sessione è ferma»,
che sono due cose opposte per chi guarda. Quindi `session_frame/2` risponde `undefined` e non
parte niente.

Questo però lascia scoperto l'ultimo invio che §5.2 chiede, «once more when it ends»: un socket
si accorge della fine solo perché la sessione che stava riportando **non c'è più** nello
snapshot. Serve dunque ricordare l'ultimo frame mandato — e ne vale la pena, perché senza la
pagina resterebbe ferma sull'ultimo aggiornamento senza sapere di essere finita, che è l'unica
cosa che non può dedurre da sola. È **l'unico stato che il canale driver tiene**, un campo,
`last_session`.

La transizione sta in `vs_driver_proto:session_push/3` e non nel trasporto, per la ragione per
cui esiste tutto il modulo: è una decisione, e una decisione è provabile in EUnit solo se non
c'è un socket di mezzo. `vs_driver_ws` la infila e basta.

Un dettaglio che rende il meccanismo sicuro: quando il manager sta ripartendo, il tick
**ripete lo snapshot precedente** (`last_state`), che contiene ancora la sessione. Un manager
che sbatte le palpebre non può quindi fingere la fine di una ricarica. Non è una difesa
aggiunta apposta: era già così per il `state`, e reggere anche questo caso è ciò che si guadagna
a derivare il frame dallo stesso dato invece che da una fonte propria.

### 16.3 `complete` viene dal SoC, mai dalla potenza

L'enum di §5.2 è `charging | suspended | complete | overstay | closed`. Tre sono producibili
oggi: `charging`, `suspended` (lo stato riportato del connettore, dove il passo 2 lo deriva già
da un limite a zero) e `closed` (§16.2). `overstay` è M4.

`complete` significa «carica finita, cavo ancora attaccato». Si deriva da `soc_pct >= 100`, che
l'emulatore produce e un'auto vera anche. **Non** da una potenza vicina a zero, ed è §5.2 stessa
a dare la ragione: zero potenza è ambiguo fra una sospensione e un taper profondo, e le due cose
significano l'opposto per chi sta aspettando l'auto. Se `soc_pct` non arriva a 100 la fase resta
`charging`: la stazione non sa che un'auto ha smesso di chiedere, e dirlo è meglio che simularlo.

Una precedenza andava scelta, perché i due casi possono coesistere — una batteria piena chiede
poco, e sotto scarsità l'allocatore può comunque azzerarla. **`complete` vince su `suspended`:**
una batteria piena è finita qualunque cosa l'allocatore abbia fatto con gli ultimi kilowatt, e
dire a un driver che la sua auto carica è «in pausa» sarebbe una risposta peggiore di nessuna.

### 16.4 L'ETA non si smussa, e quando non esiste è `null`

`eta_seconds = battery_kwh × (100 − soc_pct) / 100 / power_kw × 3600`, arrotondato.

Nessuno smoothing, nessuna media mobile, nessuna memoria del valore precedente — ed è una
scelta, non una semplificazione. Il contratto: «it is advisory and may jump when another car
arrives and the allocation is recomputed — that jump is the visible proof of P5 and should not
be smoothed away». Il numero che il driver vede è quello che l'allocazione corrente implica, e
salta perché è saltata l'allocazione. Misurato dal vivo: 1044 s a 150 kW, 1189 s a 130 kW un
tick dopo che una seconda auto si è attaccata, con la stessa batteria e un punto di SoC in meno
da fare.

**`null` quando non c'è niente per cui dividere**, e non un numero enorme: una stima che non
esiste non è una stima di infinito. Deve essere l'atomo `null` e non `undefined` — jsx rende il
secondo come la *stringa* "undefined", la stessa trappola che `expires_at` ha in §5.1.

Una batteria di taglia ignota riceve la stessa risposta, e il caso è reale: `ws-chargepoint.md`
§4.2 rende `max_kw` obbligatorio in un modo in cui non rende `battery_kwh`, quindi una
colonnina può legittimamente non mandarlo e `vs_cp_proto` legge lo zero. Applicare comunque la
formula stamperebbe «0 secondi» — cioè «pronta» — sopra un'auto appena attaccata.

**Il divisore è la potenza misurata, non il limite concesso**, e la differenza si vede. Quando
una seconda auto arriva, l'allocatore si muove in un colpo solo — `allocated_kw` passa da 150 a
180 in un unico push e il `set_limit` parte subito — ma il contatore ci mette fino a
`LIMIT_APPLY_SECONDS` (`ws-chargepoint.md` §10, 5 s) ad arrivare al valore nuovo, perché è il
tempo che il contratto concede all'hardware. L'ETA insegue il contatore, quindi in quei cinque
secondi passa per un valore intermedio.

Sembra uno smoothing e non lo è: **misurato con un emulatore configurato ad applicare il limite
di scatto (`--limit-apply 0`), il salto torna in un solo frame** (18 → 21 minuti sulla pagina).
Dividere per `limit_kw` darebbe un salto sempre istantaneo e una stima sbagliata per tutto il
tempo della rampa, cioè prometterebbe una potenza che l'auto non sta ancora prendendo. §5.2
chiede il tempo che ci vuole davvero, e quello lo sa solo il contatore.

`battery_kwh` era in `#session` fin dal primo `plugged` e mancava solo allo snapshot: è
l'unica aggiunta a `vs_connector:build_snapshot/2`, dello stesso tipo di quella fatta al passo
2 per `max_kw`. Additiva: `wire_connector`, `vs_cp_proto` e `vs_power` leggono chiavi che
nominano, quindi la taglia della batteria non trapela nel frame `state` di §5.1, che ha forma
fissa — e c'è un test che lo tiene fermo.

### 16.5 La pagina non conta da sola

`js/ws.js` non è stato riscritto: era stato costruito al passo M1-4 per essere riusato qui, e
l'innesto è quello previsto — un caso `session` nel `switch`, il campo nel letterale degli
handler, un setter accanto agli altri tre. Nove righe. `station.js` non registra `onSession` e
non vede differenza; una pagina della stazione aperta dal proprietario di una sessione riceve
comunque il frame e lo lascia cadere.

`js/session.js` obbedisce a §7.1 nel punto in cui sarebbe stato più comodo non farlo:
**nessun contatore locale.** L'energia non striscia in avanti fra un frame e l'altro, il SoC non
interpola, la stima non viene mediata con quella di prima. Ogni numero cambia quando arriva un
frame e in nessun altro momento. Con un frame ogni cinque secondi la pagina è viva abbastanza, e
un client che avanza per conto suo ha un modello della stazione — che è esattamente ciò che P6
esiste per impedire.

L'unica cosa che scorre in locale è il tempo trascorso, e non è un'eccezione alla regola: è la
lettura di un orologio, non un dato della stazione. È **ricalcolato** da `started_at` a ogni
ripasso invece che incrementato, così non può derivare e una scheda rimasta sospesa torna
giusta appena si sveglia. Una sessione `closed` lo ferma: ha una fine, e il cronometro non deve
correrle oltre.

La fase `suspended` è l'unico punto dell'applicazione in cui il riparto della potenza diventa
visibile alla persona a cui sta capitando, e per questo è spiegata invece che nominata:
«suspended» da solo si legge come un guasto, e non lo è — la sessione è viva, il cavo è sotto
tensione, l'auto ricomincerà da sola.

### 16.6 Il socket che cade: l'unico caso che il server non può curare

La pagina della sessione ha un buco che la griglia della stazione non ha, e vale la pena
scriverlo perché la simmetria fra i due frame lo nasconde.

`station.js` può permettersi di tenere la griglia mentre riconnette: §3 spinge un `state` a ogni
`join`, quindi la staleness dura esattamente quanto la riconnessione. Per §5.2 quella garanzia
**non esiste**, ed è una conseguenza diretta di §16.2. Se la ricarica finisce mentre la pagina è
disconnessa, il frame `closed` è andato a un socket che non c'è più; il socket nuovo parte con
`last_session` vuoto e a un driver senza sessione non si manda niente. Nessun frame arriverà
**mai** a dire che è finita.

Tenere la card sarebbe quindi lasciare un «Charging, 130 kW» vivo sopra una sessione chiusa da
minuti — precisamente la deriva che §7.1 esiste per impedire, e in una pagina il cui commento in
testa dichiara di obbedirvi. Quindi `session.js` azzera ciò che ha in mano appena il canale non
è più `online`: la risposta onesta è «non lo so», e il placeholder più la pastiglia la dicono
insieme. Se invece la ricarica è sopravvissuta, il primo frame dopo il rientro ridisegna la card
entro un tick.

**Non si è scelto di curarlo lato server**, e la ragione è che le cure disponibili sono peggiori
del male: mandare un frame di zeri a chi non carica riporta l'ambiguità che §16.2 toglie, e far
sopravvivere `last_session` alla morte del socket vorrebbe dire uno stato per utente sulla
stazione — cioè la sessione lato server che §7.5 non ha, tenuta in piedi per un caso di bordo.
Tre righe nella pagina bastano.

### 16.7 Chi serve la pagina: `session.jsp` esiste, il servlet no


`station.jsp` è servita da `StationPageServlet`, che mette in pagina i tre valori di `jwt.md`
§2. Per `session.jsp` non esiste niente di simile e il servlet è **codice di B**. Verificato
prima di scrivere: otto servlet in `backoffice/src/main/java/.../web/`, nessuno per la sessione.

La strada scelta è chiedere a B un servlet gemello (`/session`, stesso contratto, dieci righe),
richiesta già scritta in `contracts/nota-per-B-m2a.md` §4. `session.jsp` è committata **pronta**
invece che tenuta indietro: è lo stesso scheletro di `station.jsp`, e quando il servlet arriva
non resta niente da scrivere da questa parte. Fino ad allora il file non è raggiungibile, e le
prove dal vivo sono girate su una pagina statica che monta lo stesso `<style>` e lo stesso
markup con le tre costanti messe a mano.

### 16.8 Un artefatto trovato dalle prove: la durata di una sessione che attraversa un riavvio

Non è di questo passo — è della riga su `sessions` (§13) e della riconciliazione (§11) — ma è
saltato fuori qui, verificando che il frame `closed` e la riga dicessero lo stesso numero, ed è
annotato dove è stato visto.

**Il fatto.** La riga 18 delle prove porta `12.042 kWh` con `started_at`/`ended_at` che coprono
**ventitré secondi**. L'energia è giusta — coincide al millesimo con il contatore
dell'emulatore, e una sola riga, nessun doppio addebito. La durata no: quell'auto aveva caricato
un'ora, attraversando due spegnimenti della stazione.

**Perché.** `ws-chargepoint.md` §6 fa tornare indietro **l'energia, non l'istante di inizio**.
Una stazione che riparte ha perso la sua sessione; il `plugged` di riconciliazione le ridà il
cumulativo del contatore e nient'altro, quindi `started_at` diventa l'istante dell'adozione. È
la stessa cosa già scritta in §13 sul percorso di adozione — lì suonava come un dettaglio, qui
si è visto quanto può essere grande lo scarto.

**Cosa non rompe.** Il conto. `BillingService.cost/3` prezza energia, tariffa e secondi di
overstay: nessuna delle due date entra nel calcolo, verificato leggendo il metodo. Rompe invece
qualunque lettura di `ended_at - started_at` come «tempo di ricarica», che è una cosa che
qualcuno prima o poi farà.

**Chiuso.** Al `plugged` di riconciliazione la colonnina aggiunge `charging_seconds`, **da
quanti secondi sta erogando**, e la stazione ricostruisce `started_at` con il proprio orologio
sottraendoli.

**Perché una durata è ammissibile dove un istante non lo sarebbe** — è il punto della
correzione, non un dettaglio della sua forma. §7.4 non dice «la colonnina non mandi dati»: dice
che i timestamp che contano sono quelli della stazione, perché un orario prodotto dalla
colonnina obbligherebbe due orologi a essere d'accordo su *che ora è*, e non lo sono. Una
durata non chiede niente del genere. È una grandezza che l'hardware ha **misurato**, della
stessa specie di `energy_kwh` — che il contratto gli fa già mandare e sul quale gli crede senza
esitazioni, perché è l'unico che l'abbia contata. La stazione legge il proprio orologio e
sottrae: due macchine sfasate di dieci minuti scrivono la stessa riga. Un `started_at` assoluto
mandato dall'hardware, esattamente sulla stessa informazione, ne scriverebbe due diverse. La
distinzione fra durata e istante è ciò che tiene la modifica dentro §7.4 alla lettera, non un
cavillo per farcela entrare.

Ed è misurata dallo stesso istante da cui è contata l'energia — il cavo che entra — quindi i
due numeri della riga coprono la stessa finestra: è questo che li rende coerenti fra loro, che
era tutto il problema.

Il campo è **facoltativo e resta tale**: assente o non positivo, `started_at` è l'istante
dell'adozione e la stazione si comporta come prima che il campo esistesse. Una colonnina che
non sa rispondere non è una colonnina rotta, ed è la ragione per cui il contratto dichiara di
essere implementabile da hardware vero (§7 del SCOPE).

**Scartate.** Far mandare all'hardware un `started_at` assoluto: è il caso di sopra, due
orologi che devono accordarsi. Dedurre la durata dall'energia e dalla potenza nominale: darebbe
un numero plausibile e **falso** — plausibile è peggio, perché un numero visibilmente sbagliato
si trova, uno verosimile no.

`ws-chargepoint.md` è di A da entrambi i lati, quindi la modifica non ha richiesto una PR. Cosa
è cambiato e cosa sopravvive: §18.1. Misurato sulla stessa scena, prima e dopo:
**65 s contro 148 s** per 5,956 e 5,957 kWh, cioè **329,9 kW impliciti contro 144,9** su una presa
da 150.

---

## 17. Il riaggancio del socket colonnina e l'emulatore dei driver (M2-A passo 5)

Due lavori in un giro: un difetto che si innesca proprio sotto carico, e il carico che serviva
a trovarne di nuovi. In quest'ordine, perché partire con un difetto noto avrebbe reso
illeggibile ciò che le prove trovavano.

### 17.1 Il difetto era vero, il meccanismo del piano no

`PIANO_LOAD.md` descriveva così la conseguenza della morte di un connettore: «i suoi `meter` e
`status` continuano ad arrivare a un pid morto — `gen_statem:cast` verso un processo defunto
non fallisce, sparisce in silenzio». **Non è quello che succede**, e la verifica bloccante
«riproduci prima di correggere» è servita esattamente a questo.

`vs_cp_proto` non ha mai memorizzato il pid: §11.10 lo dice e un test lo asserisce, il
connettore si rilegge da `lookup_pid/1` a ogni evento. Il registro del manager guarisce da solo
sul `connector_up`, e misurato sul compose ci mette meno di un secondo. Quindi i `meter`
**arrivano** al connettore nuovo. Il difetto è un altro, ed è peggiore perché lascia più tracce
sbagliate che giuste:

- il connettore rinato è `free` e non ha sessione, quindi ogni lettura diventa una riga
  «meter for a connector with no session (state free)» e viene buttata;
- `#data.cp` è `undefined`, quindi `send_cp/2` è un no-op: **nessun `set_limit` e nessuno
  `stop` può più raggiungere l'hardware**;
- l'`unplugged` finale cade su un connettore inattivo e §4.4 lo ignora, quindi la riga su
  `sessions` **non viene mai scritta**.

Misurato: con una `exit(Pid, kill)` sul connettore 3 a sessione in corso, l'auto ha continuato
a prendere 150 kW fino a 1,878 kWh, la stazione ha mostrato il connettore `free` per tutto il
tempo, e in `sessions` non è comparsa nessuna riga. `PROGRESS.md` lo aveva già annotato
correttamente al passo 1 («il `meter` successivo finisce nel log "meter senza sessione" invece
che nel vuoto»); il piano lo aveva riscritto peggio.

Il sintomo per cui la correzione esiste resta identico a quello del piano. Cambia la frase da
dire all'orale, e cambia il punto in cui si guarda per accorgersene: non un pid morto, ma un
connettore vivo che non sa niente.

### 17.2 Perché il socket si riaggancia invece di chiudersi

L'alternativa scartata era la più semplice: al `DOWN` del connettore, chiudere il socket e
lasciare che la colonnina si riconnetta col backoff di §6.1. Costa una riga.

Costa anche un secondo abbondante di erogazione non contata, ma soprattutto sposta
**sull'hardware la riparazione di un guasto della stazione**. §7.1 divide le competenze in modo
netto — la stazione autorizza, la colonnina riferisce — e §7.2 le dà il ruolo di autorità sullo
stato fisico, non quello di infermiere. Una stazione che chiede all'hardware di riavviarsi
perché un suo processo è morto sta chiedendo all'hardware di coprirla.

Quindi il socket monitora il connettore a cui si è attaccato, e sul `DOWN`:

1. arma un `erlang:send_after` di `CP_REATTACH_MS` — **un timer, non un'attesa**: il socket
   deve continuare a leggere frame, perché la colonnina non smette di parlare solo perché un
   processo della stazione è morto;
2. rilegge il pid da `vs_station_mgr:lookup_pid/1`, la stessa lettura sporca dell'handshake e
   per la stessa ragione (§11.10: mai una call sincrona dal socket al manager);
3. si riattacca con `attach_cp/2` e **riconcilia**;
4. dopo `CP_REATTACH_TRIES` tentativi si arrende con un 4404.

Misurato sul compose: dal `DOWN` al riaggancio, **501 ms**. L'emulatore non se ne accorge — il
suo log non ha un buco, la potenza non scende — e la riga finale porta `2.416 kWh`, identica al
totale del contatore.

### 17.3 Il pid ricordato non è una cache di instradamento

§11.10 dice che il connettore non si memorizza mai, e la sessione del socket adesso contiene un
`conn_pid`. Le due cose convivono, e la distinzione va detta perché è esattamente il genere di
cosa che in revisione sembra una contraddizione:

- **l'instradamento** passa ancora da `lookup_pid/1` a ogni evento, senza eccezioni;
- `conn_pid` esiste per due motivi che non sono l'instradamento: dare un soggetto al monitor,
  e permettere al riaggancio di distinguere «il connettore è tornato come processo **nuovo**»
  da «il registro nomina ancora quello che è appena morto».

Il secondo non è teorico. Il `DOWN` del socket e quello del manager sono indipendenti: se il
timer scatta prima che il manager abbia gestito il suo, `lookup_pid/1` restituisce ancora il
pid defunto. Confrontarlo è l'unico modo esatto di accorgersene — `is_process_alive/1` sarebbe
una domanda sul passato, e per un pid remoto nemmeno affidabile.

### 17.4 Lo stato nuovo del socket, e perché è giustificato

Il socket ricorda tre cose: `last_status`, `last_plugged`, `last_meter`. È tutto lo stato che
questo processo ha oltre all'handshake, e la giustificazione è una sola frase: **è la stessa
copia che la colonnina rimanderebbe riconnettendosi**, tenuta da questa parte per non chiedere
all'hardware di rifare una cosa che ha già fatto.

Non è un'analogia: §6.2 descrive letteralmente quel comportamento — «invia `boot` con il suo
stato vero e, se una sessione è in corso, un `plugged` con il veicolo e l'energia cumulativa
che ha contato» — ed è ciò che `cp.js` fa. Il riaggancio replica quelle due cose al posto suo.

Tre decisioni dentro questa scelta:

- **Il `plugged` si ricorda comunque**, anche quando la stazione lo rifiuta. La colonnina lo
  rimanderebbe comunque: `cp.js` mette `car.plugged = true` senza guardare la risposta, perché
  §7.1 le dà il ruolo di riferire e non quello di giudicare. Un `plugged` rifiutato viene
  rifiutato di nuovo al replay, che è l'esito onesto invece di uno silenzioso.
- **Si dimentica sull'`unplugged`.** Tenuto oltre, descriverebbe un'auto che se n'è andata, e
  il riaggancio successivo aprirebbe una sessione per lei. È l'unico modo in cui questa
  memoria potrebbe fare danno, e ha un test suo.
- **L'energia del replay viene dall'ultimo `meter`**, non dal `plugged` di quando il cavo è
  entrato — che porta quasi sempre zero. Scritto come `max` dei due perché §4.3 dice che il
  cumulativo è monotono: il `max` non può che pescare il `meter`, ed è la regola a essere
  scritta, non un dubbio sull'ordine di arrivo.

**Prima si attacca, poi si racconta.** L'ordine è portante: il `plugged` replicato porta il
connettore in `charging`, la cui `enter` manda il `set_limit` interinale attraverso `send_cp/2`.
Riconciliare prima di attaccare lo farebbe cadere in un `cp = undefined`, e l'auto resterebbe
sul limite vecchio fino al tick successivo del manager — cioè avremmo corretto metà del difetto
tenendoci l'altra metà.

### 17.5 La sessione che torna è un walk-in, e la prenotazione no

Il connettore rinato è `free`, quindi il `plugged` replicato ci entra dalla porta del walk-in:
niente claim, utente risolto dal veicolo (`vehicles.user_id` è unico, D1). È §6 preso alla
lettera — «ricostruire la prenotazione non viene deliberatamente tentato: l'auto continua a
caricare, la sessione viene fatturata, la prenotazione non c'è più» — e non una semplificazione
scelta qui.

Ha una conseguenza che va detta: se il connettore era `held` da un altro driver quando è morto,
quell'hold è perso col processo, e il primo `plugged` che arriva apre un walk-in. Lo stesso vale
già oggi per il riavvio di una stazione intera; qui la finestra è più piccola.

### 17.6 `CP_REATTACH_MS` e `CP_REATTACH_TRIES` non entrano nel contratto

Stessa regola di §12.8. `ws-chargepoint.md` §10 configura **il filo** — quello che la colonnina
si sente dire e a cui viene tenuta — mentre queste due descrivono come la stazione si ripara
dietro il filo. Una colonnina non sa, e non deve sapere, che un processo connettore le è
rinato sotto.

I valori: 500 ms perché è abbondantemente sopra il tempo misurato perché il `simple_one_for_one`
rifaccia il figlio e il manager gestisca il proprio `DOWN`, e ben dentro l'intervallo di un
`meter`. Cinque tentativi, cioè due secondi e mezzo: oltre quel punto il supervisore non è stato
lento, si è **arreso** (`intensity 5, period 10`), e restare attaccati a niente non aiuta.

### 17.7 Il 4404 della resa, e una divergenza segnalata e non corretta

Alla resa il socket chiude con **4404**, che è il codice che §1 dà a «questa stazione non ha
quel connettore» — e dopo cinque tentativi è letteralmente vero.

**`cp.js` però tratta il 4404 come fatale e termina** (`die(...)`), invece di riconnettersi col
backoff. Non è irragionevole da parte sua: §1 mette quel codice all'handshake, dove significa
una configurazione sbagliata, e riprovare all'infinito una configurazione sbagliata sarebbe un
ciclo. Ma vuol dire che l'ipotesi «lascia riconnettere la colonnina col suo backoff» **è falsa
per il nostro emulatore su quel percorso**.

Segnalato e non corretto **allora**: `cp.js` era fuori dal perimetro di quel passo, e la scelta
fra «cambiare il codice della resa» e «insegnare a `cp.js` a distinguere il 4404 dell'handshake
da quello a metà vita» è una decisione di contratto, che è di Caleb.

**Deciso poi, e nel primo dei due modi: §18.2.** La resa chiude `1012`, `cp.js` non è stato
toccato. Il percorso, che qui era descritto come «quasi irraggiungibile» e non era mai stato
imboccato nelle prove, è stato poi forzato apposta su un socket vero: l'emulatore moriva
davvero, e l'errore era per intero dalla parte della stazione.

### 17.8 L'emulatore dei driver: perché firma i token da sé

`driver.js` si firma i JWT, uno per driver emulato, ognuno col suo `vehicle_id`. Può farlo solo
perché il segreto **di sviluppo** è pubblicato in `sample-tokens.md`, e un generatore di carico
che avesse bisogno di un Tomcat acceso per produrre quaranta login non sarebbe un generatore di
carico.

In esercizio è impossibile e deve restarlo: `VOLTSHARE_JWT_SECRET` viene iniettato al deploy e
non è mai committato, e il back office è l'unico emittente (`jwt.md` §1). La stazione ha già un
`vs_jwt:secret/0` che avverte quando si accorge di star verificando col segreto pubblicato:
firmare qui è l'immagine speculare di quell'avviso, e le due cose smettono di essere vere nello
stesso istante.

La prova che non è una scorciatoia sciatta: `--self-test` rifirma i claim di `sample-tokens.md`
§1 e stampa se il risultato è la fixture pubblicata **byte per byte**. Lo è. Vuol dire che
questo file firma quello che firma Tomcat — stesso header, stesso ordine dei claim, `sub` come
stringa e `vehicle_id` come numero — e non qualcosa che la stazione accetta per caso.

### 17.9 Dove `driver.js` copia `js/ws.js`, e perché non è duplicazione

L'intestazione di `ws-driver.md` dice che i driver emulati del generatore di carico parlano lo
stesso contratto della pagina. Se le semantiche divergessero, la prova di carico misurerebbe
qualcosa che nessuno usa. Quindi sono identiche, e ciascuna è marcata nel sorgente:

- stesso `request_id` su ogni ritentativo (§2, §7.2), che è la metà client di P7 — senza,
  la cache at-most-once della stazione è codice che nessuno esercita;
- niente viaggia prima che il `join` sia acked (§3): le azioni sollevate prima aspettano;
- 4400/4401/4408 fatali, tutto il resto riconnette con backoff 500 ms → 10 s (§7.5);
- `?station_id=` lo appende il client (§1, §10.5).

Non è duplicazione perché **non è lo stesso programma**: `js/ws.js` gira nel browser, non ha
scenari, non misura tempi e non conta esiti; `driver.js` non ha DOM, non ha promesse esposte a
una pagina e ha un ciclo di vita a batch. Condividere il file avrebbe voluto dire un bundler e
un modulo comune per due runtime diversi — la stessa complicazione che il progetto ha rifiutato
ovunque. Dove i due divergessero, la regola dichiarata è che **ha ragione `js/ws.js`**: è quello
che gira davanti a un utente. Nelle prove non è emersa nessuna divergenza.

### 17.10 Cosa misurano gli scenari, e perché il massimo e non la media

Tre scenari, in ordine di valore: la contesa sullo stesso connettore (l'invariante centrale,
SCOPE §4), un veicolo e una prenotazione sola in rete (che attraversa il coordinatore), e il
carico sostenuto (dove il difetto della Parte 1 si sarebbe innescato).

Ogni scenario riporta richieste, accettate, rifiutate **per codice**, e il tempo di risposta
come **massimo e media**. Il massimo è il numero che conta: una prenotazione da otto secondi è
un'esperienza rotta anche con una media da 200 ms, e una media è esattamente la statistica che
nasconde quel caso.

L'orologio parte quando il driver **chiede**, non quando il frame parte: una richiesta rimasta
in coda dietro un `join` lento ha aspettato, e nasconderlo misurerebbe la stazione invece
dell'esperienza. I ritentativi sono dentro la stessa misura, per la stessa ragione.

E il conteggio deve **chiudere esatto**: su N richieste allo stesso connettore, `1 + (N-1)`
rifiuti senza avanzi. Un solo esito diverso e l'invariante è violata; il programma esce con
stato diverso da zero.

### 17.11 `stop_session` e il frame `session` hanno bisogno di un proprietario

Un carico di driver anonimi non può mostrare le due cose che §5.2 e §4.3 riservano a chi
**possiede** una sessione: che il frame `session` arrivi al proprietario e a nessun altro, e
che `stop_session` sulla ricarica di un altro sia `NOT_YOURS`.

Quindi `--charging-connector <n>`: con un `cp.js` che eroga su quel connettore, la corsa aggiunge
una sonda finale con il driver il cui veicolo è quello che sta caricando. Una volta sola, dopo
il ciclo e non dentro: il soggetto è una regola di autorizzazione, e ripeterla mille volte
aggiungerebbe rumore ai numeri senza aggiungere un fatto. Termina quella ricarica, e questa è
la dimostrazione — la stazione manda lo `stop`, la colonnina obbedisce, la riga viene scritta.

Misurato: `NOT_YOURS` all'estraneo, `ACK` al proprietario, `7.414 kWh` sulla riga, identici al
totale finale dell'emulatore.

### 17.12 Docker Desktop si sospende, e le misure vanno buttate

Non è una scelta di progetto, è una condizione dell'ambiente che invalida silenziosamente i
numeri, e sta scritta qui perché chiunque rifaccia le prove ci inciamperà. Docker Desktop mette
in pausa la sua VM quando nessuno le parla: fra una corsa e l'altra si sono osservate pause di
**ventidue minuti**, e una da 38 secondi è caduta dentro la riproduzione del difetto — fra il
`plugged` e il primo `set_limit`, quindi prima del kill e delle due istantanee, che sono
osservazioni di stato e non di tempo e reggono comunque.

Si vedono come buchi nel ping da tre secondi che la stazione fa comunque:

```bash
docker logs --since 5m station1 | grep -B1 "ping vs@" | grep NOTICE
```

Due timestamp consecutivi a più di sei secondi vogliono dire che la VM si è fermata, e quella
corsa va rifatta invece che spiegata. Tutti i **tempi** riportati per il passo 5 sono stati
presi con questo controllo eseguito **dopo** la corsa, e nessuno di essi attraversa una pausa.

---

## 18. Due ritocchi al contratto della colonnina (M2-A, dopo il passo 5)

Due modifiche piccole a `ws-chargepoint.md`, e nessuna delle due introduce un meccanismo: una
aggiunge un campo facoltativo, l'altra corregge un numero. Sono qui insieme perché condividono
la stessa regola di lavorazione — il contratto è di A da entrambi i lati, quindi cambia senza
PR, ma **testo e implementazioni cambiano nello stesso commit**. Un contratto che descrive un
campo che il codice non manda è peggio di nessuno dei due: il primo si scopre provando, il
secondo si scopre leggendo, e leggere è quello che fa chi arriva dopo.

### 18.1 `charging_seconds`: dove entra, e le due cose che non tocca

Il fatto, la misura e la ragione per cui una **durata** è ammissibile dove un **istante** non lo
sarebbe stanno in §16.8, dove il difetto era stato annotato. Qui c'è cosa è cambiato.

Il campo entra in un punto solo. `vs_cp_proto` lo legge dal payload del `plugged` e lo mette
nella mappa `Info` **solo se è positivo e sottraendolo non si finisce prima dell'epoca**;
altrimenti la chiave non c'è. `vs_connector:session_from/3` calcola `started_at` da quella
chiave se c'è, dall'orologio se non c'è. Nessun'altra data cambia.

**Perché la chiave si aggiunge invece di avere un default a zero.** È la differenza fra una
promessa strutturale e una convenzione. Con un default, ogni payload costruirebbe una mappa che
*contiene* il campo, e nulla impedirebbe a un percorso futuro di leggerlo credendolo sempre
significativo; senza, un `plugged` ordinario costruisce **la stessa mappa, chiave per chiave**,
che costruiva prima che il campo esistesse, e la facoltatività è una proprietà del codice invece
che di una riga di documentazione. Il test lo asserisce come assenza della chiave, non come
zero, apposta.

**I tre ingressi in `charging`, e perché solo l'adozione cambia.** `free`, `held` e
`out_of_service` passano tutti da `adopt/3` → `session_from/3`, e nessuno dei tre è stato
toccato: cambia il **dato**, non il percorso. Solo un `plugged` di riconciliazione porta una
durata, perché è l'unico che la colonnina abbia motivo di mandare. Il punto meritava una
verifica e non un'assunzione: la scena che conta — riavvio della stazione — **non** passa da
`out_of_service` ma da `free`, perché una stazione che riparte lo fa con processi connettore
**nuovi**, che nascono liberi. Legare la correzione strutturalmente a `out_of_service` avrebbe
prodotto codice che supera i test unitari e non corregge niente sul compose.

**Non è accoppiato a `energy_offset` (§14.2), e non deve diventarlo.** L'offset risponde a
«quanto di questo cumulativo appartiene a una riga che esiste già», la durata risponde a «quando
è cominciata l'erogazione»: sono due domande diverse e nessuna delle due si deduce dall'altra.
Stanno affiancate e non si leggono a vicenda.

**Cosa sopravvive, e va detto.** Due residui, entrambi noti e nessuno dei due chiuso qui.

1. **La copia del riaggancio non riporta la durata.** Quando muore il *connettore* sotto un
   socket vivo (§17.4), il socket rigioca il `plugged` che aveva messo da parte. Ogni campo di
   quella copia regge la traduzione tranne questo: l'energia si aggiorna dal `meter` arrivato
   un attimo prima, una durata non si aggiorna da niente e nel frattempo è cresciuta di quanto
   la copia è rimasta lì. Rigiocarla daterebbe la sessione troppo tardi di esattamente quel
   tanto — un numero plausibile e falso, che è la cosa che §16.8 sceglie di evitare. Viene
   tolta, e quel percorso torna al comportamento di prima (`started_at` = istante
   dell'adozione). Chiuderlo vorrebbe dire che il socket si annota **quando** ha ricevuto il
   frame: un pezzo di stato in più sul confine più delicato del milestone, per un percorso che
   l'hardware non vede nemmeno. Non adesso.
2. **Guasti incatenati sullo stesso cavo.** Se una sessione è già stata chiusa con il cavo
   dentro (§14.2, D-1) e la successiva adotta con un offset, l'energia della seconda riga è la
   fetta nuova mentre la durata che l'hardware dichiara copre **tutto** il cavo: le due righe si
   sovrappongono nel tempo. È il prezzo di tenere le due grandezze indipendenti, ed è stato
   pagato consapevolmente. Chiuderlo vorrebbe dire ricordare *fino a quando* si è fatturato, non
   solo *quanto*: un secondo offset, e un meccanismo nuovo dove questo lotto chiude difetti.

### 18.2 La resa del riaggancio chiude `1012`, e l'emulatore non si tocca

Il difetto è in §17.7: la resa chiudeva `4404`, e `cp.js` su `4404` muore. La correzione è di
una cifra, ma la ragione è la parte che conta.

`4404` è **permanente**: §1 gliel'ha assegnato all'handshake, dove significa «questo connettore
non è di questa stazione», e su una configurazione sbagliata riprovare all'infinito è un ciclo.
Una colonnina che lo tratta come fatale sta obbedendo al contratto, non sbagliando. La resa del
riaggancio è **temporanea**: un processo connettore è morto e il suo supervisore è indietro. Il
piano del passo 5 aveva riusato il codice permanente per una condizione passeggera, e la frase
con cui quel ramo si chiudeva — «the charge point will reconnect» — era falsa contro l'unica
colonnina che abbiamo.

`1012` (Service Restart) è il codice standard per «torna, sto ripartendo». La scelta però non è
stata fatta soltanto perché il nome è quello giusto: **`cp.js` non è stato toccato**, e questo è
l'argomento. Un `1012` cade da solo nel suo ramo generico di riconnessione con backoff, che
esisteva già e non sa niente di connettori e supervisori. Un codice che obbliga il client a
imparare un caso speciale della stazione è un codice scelto male; uno di fronte al quale un
client che non sa niente fa la cosa giusta da sé è la prova che dice quello che intende dire.
L'alternativa — insegnare a `cp.js` a distinguere il `4404` dell'handshake da quello a metà
vita — è stata scartata proprio per questo: avrebbe messo nell'emulatore una conoscenza che
l'hardware vero non ha nessun motivo di avere, e avrebbe lasciato il contratto a dire una cosa
falsa.

Il percorso, che §17.7 dava per «quasi irraggiungibile» e mai imboccato nelle prove, è stato
forzato apposta su un socket vero prima e dopo la correzione (`CP_REATTACH_TRIES` a 1,
supervisore sospeso con `sys:suspend`, connettore ucciso): prima l'emulatore usciva con codice
2, dopo si riconnette col backoff, riannuncia il cavo e la sessione viene fatturata. È la prima
volta che quel ramo gira su un socket vero — il passo 5 lo aveva solo nei test unitari.

**Ha trovato un terzo posto dove lo stesso errore è ancora dentro**, e non è stato corretto qui.
Tenendo il supervisore sospeso *a tempo indefinito* — che non è il caso vero, ma è quello che
rende la prova deterministica — l'emulatore riceve il `1012`, si riconnette come previsto, e
sull'**handshake** trova il registro ancora senza quel connettore: `4404`, e muore lo stesso.
`vs_station_mgr:lookup_pid/1` collassa in un solo `{error, unknown_connector}` tre situazioni di
cui due sono temporanee (manager non avviato, connettore senza pid in questo istante) e una sola
è permanente (id che non è di questa stazione), e il socket manda il codice permanente a tutte e
tre. È `PROBLEMI_TROVATI.md` P10: tocca `vs_station_mgr`, che è fuori perimetro, ed è una terza
decisione di contratto — la risposta giusta probabilmente esiste già in §3.1 (`accepted: false`
con un `reason`, «the charge point closes and retries with backoff») e non richiede un codice
nuovo. Segnalata e lasciata a chi decide il contratto, come §17.7 aveva fatto con questa.

**Decisa e chiusa lo stesso giorno: §18.3.**

### 18.3 L'handshake ammette il temporaneo, e a rispondere è il boot (P10)

Il terzo posto che §18.2 aveva trovato e lasciato aperto. `vs_station_mgr:lookup_pid/1`
collassava tre situazioni in un `{error, unknown_connector}` solo, e l'handshake della colonnina
mandava a tutte e tre il `4404` che §1 destina al permanente. Adesso ne dice quattro:

| ETS | ritorno | natura |
|---|---|---|
| riga con pid vivo | `{ok, Pid}` | — |
| riga con `undefined` | `{error, no_pid}` | temporanea: fra il DOWN e il restart |
| tabella assente (`badarg`) | `{error, no_manager}` | temporanea: manager non ancora su |
| riga assente | `{error, unknown_connector}` | **permanente**: non è di questa stazione |

La distinzione è pulita e non ha finestre grigie perché `init/1` inserisce **tutti** i connettori
configurati con pid `undefined` prima di qualunque altra cosa, e il `DOWN` rimette `undefined`
invece di cancellare la riga: una riga che c'è vuol dire "questo connettore è mio" per tutta la
vita di quel manager.

**La correzione non inventa un meccanismo, ne toglie uno di troppo.** I due temporanei sono
*ammessi* all'handshake e la risposta la dà il `boot`, cioè l'unico punto del contratto che sa
già dire «non adesso» senza dire «mai più»: `accepted: false` con un `reason`, e «the charge
point closes and retries with backoff». Il ramo esisteva dal passo 5 e ci si arrivava quasi mai;
oggi è la strada normale del riavvio di un connettore. Il `reason` distingue i due casi —
`"connector not ready"` contro `"unknown connector"` — ed è l'unica parte del rifiuto che
l'apparecchiatura legge.

Il `4404` torna a essere esattamente ciò che §1 dichiara e nient'altro, e il `logger:notice` che
lo accompagna («not a connector of station N») smette di mentire in due casi su tre. Come per il
`1012` di §18.2, **`cp.js` non è stato toccato**: un `accepted: false` cade da solo nel suo ramo
di chiusura-e-backoff, che non sa niente di supervisori.

**Il chiamante che la modifica avrebbe ucciso, e che il piano aveva ragione a cercare.**
`vs_claim_client:revoke/2` faceva `case vs_station_mgr:lookup_pid(...)` con **due sole clausole**.
Allargare il tipo di ritorno senza toccarlo avrebbe fatto sì che una revoca del coordinatore
arrivata durante il riavvio di un connettore producesse un `case_clause` dentro `handle_info`, e
morisse il processo che tiene *tutti* i claim della stazione. Vale la pena scriverlo perché è il
tipo di danno che una modifica "innocua" fa: nessuna delle due funzioni è sbagliata da sola.
Riprodotto prima di correggerlo, e la forma del rosso è quella di §19.1 — `17 tests, 0 failures,
6 cancelled`, non «1 fallimento».

**Il backoff piatto dell'emulatore nel giro del boot rifiutato — osservato, accettato, non
corretto.** `cp.js` azzera `backoffMs` in `onOpen`, e nel giro "connetti → boot rifiutato →
chiudi" la connessione **riesce** ogni volta: quindi il backoff non cresce mai e l'emulatore
ritenta a ~1/s finché il connettore non torna (misurato: 45 riconnessioni in 45 s). Non è un
difetto del contratto — §6.1 parla del backoff della *riconnessione*, e la riconnessione qui
riesce davvero — ed è l'emulatore, non l'hardware: una colonnina vera fa §3.1 per conto suo.
Correggerlo vorrebbe dire insegnare a `cp.js` a distinguere "aperto" da "aperto e servito", che
è la stessa conoscenza speciale della stazione che §18.2 ha rifiutato di metterci dentro.
Annotato e basta.

## 19. La suite come asserzione (P11)

Due decisioni prese il 29/08 dopo la segnalazione di B — un giro rosso su
`acquire_happy_path_test` e un giro che contava 274 test invece di 298. Misure e
sabotaggi in `REPORT_P11.md`.

### 19.1 Il conteggio dei test è un'asserzione, non una nota

`rebar3 eunit` non dice se il giro è andato bene. Provato rompendo la suite apposta in tre
modi diversi, su questo albero:

| rottura controllata | totale | `failures` | coda del sommario | exit |
|---|---|---|---|---|
| il `setup/0` di una fixture solleva | **invariato** (307) | 0 | `, 22 cancelled` | 1 |
| un `exit` nel processo di un test | **299** | 0 | `, 6 cancelled` | 1 |
| un `_test_()` solleva mentre eunit **enumera** | **286** | 0 | `, 5 cancelled` | 1 |

Tre cose che non si sapevano e che cambiano il rito:

1. **`0 failures` non vuol dire verde.** Lo stampa anche un giro che ha perso ventidue test.
   La parola che conta è quella dopo, e non c'è quando tutto va bene.
2. **Il totale non è una costante della suite**: è quanto lontano eunit è arrivato a
   *enumerare* l'albero dei test. Un'eccezione dentro una funzione generatrice ferma
   `eunit_data:iter_next/1` e fa sparire dal conteggio molti più test di quanti ne contenesse
   quel generatore — 21 per un generatore da 6.
3. **Il totale da solo non basta**: il primo caso lo lascia a 307.

Da qui `src/scripts/eunit_check.sh`, che è verde **solo** se rebar3 esce 0 **e** il sommario è
esattamente `307 tests, 0 failures`, ancorato a fine riga così che qualunque coda `cancelled`
o `skipped` lo faccia fallire. Il numero sta scritto in testa allo script e aggiornarlo è
parte dell'aggiungere un test.

L'alternativa scartata era documentare il totale solo in `PROGRESS.md`. È dove stava già, ed è
esattamente il motivo per cui B ha dovuto contare a occhio: un numero che nessuno confronta
automaticamente non è un'asserzione, è una speranza.

### 19.2 Il timeout di una chiamata di test non deve poter scattare

`vs_claim_client_tests` teneva `timeout_ms => 500` per la `gen_server:call` verso il
coordinatore. Il mock risponde in modo sincrono dal proprio `handle_call`, senza lavoro lento:
se 500 ms non bastano non è il codice a essere lento, sono gli scheduler a essere saturi — e
`call_one` traduce il timeout in `unreachable`, la lista dei nodi si esaurisce e il test riceve
`{error, no_claim}`. Il test misurava la macchina. Portato a 60000: nessun percorso di quel
file **aspetta** davvero, perché i rifiuti arrivano come risposte esplicite e i nodi morti come
`noproc` — il valore serve solo a rendere impossibile che lo scheduling lo faccia scattare.

Lo stesso ragionamento vale per i due altri orologi del file, che sono **retry limitati e non
asserzioni sul tempo**: `wait_until` esce alla prima verità, quindi il suo tetto (da 100 a 300
tentativi) non si paga sul verde, e l'`after` di `holds()` (da 1 s a 5 s) è raggiungibile solo
in un giro già rosso. Alzarli non rallenta niente e toglie il prossimo flake della stessa
famiglia.

**C'è però un'eccezione, ed è il motivo per cui la regola va scritta con il suo limite.**
`rebar.config` dichiara `{dist_node, [{setcookie, voltshare}, {sname, vs}]}`, e il provider
`eunit` di rebar3 lo onora: il nodo di test **è distribuito** (`node() = vs@<host>`). Quindi
`no_coordinator_at_all_refuses_with_no_claim_test`, che chiama `'nonexistent@nowhere'`, non
prende il `badarg` immediato che il commento in `call_one` promette per i nodi non distribuiti:
paga una risoluzione DNS/epmd che fallisce come `nodedown` dopo ~2,5 s. Misurato:

| `timeout_ms` | esito | durata |
|---|---|---|
| 500 | `{timeout, …}` | 511 ms |
| 5000 | `{nodedown, nonexistent@nowhere}` | 2278 ms |
| 60000 | `{nodedown, nonexistent@nowhere}` | 2704 ms |

L'esito del test è lo stesso nei tre casi — `call_one` fa `catch _:_ -> unreachable` — ma la
durata no, e eunit uccide un singolo test dopo **5000 ms** (`?DEFAULT_TEST_TIMEOUT`,
`eunit_internal.hrl:38`), mettendolo fra i *cancelled*, cioè togliendolo dal conteggio. Alzare
il timeout **anche lì** avrebbe fabbricato il difetto B con le nostre mani.

Quel solo test tiene quindi un override esplicito a 500 ms. La regola completa è: *il timeout
di una chiamata di test non deve poter scattare per scheduling; dove la chiamata è fatta apposta
per non raggiungere nessuno, il timeout diventa un tetto deterministico su una latenza che non
controlliamo, e va tenuto ben sotto i 5 s di eunit.*

---

## 20. Il claim non è un ricordo del client, è il riflesso di ciò che i connettori possiedono (P14 + P15)

### 20.1 Le due metà non si vedevano morire

Il claim vive in `vs_claim_client`, ma il **fatto** vive nel connettore: `#hold.claim_id` prima
che il cavo entri, `#session.claim_id` dopo. Fino al 29 agosto nessuna delle due metà si
accorgeva della morte dell'altra, e ognuna delle due direzioni era un difetto suo, misurato
(`REPORT_M3A_VERIFICA` §6.1 e §6.2):

- **muore il client** → riparte con `claims = #{}`, risponde a `who_do_you_hold` con niente, e
  alla prima elezione il coordinatore nuovo ricostruisce da un client che non sa più nulla:
  lo stesso veicolo si ritrova con due prenotazioni su due stazioni. È l'invariante di uso
  esclusivo di `SCOPE` §4 — la ragione per cui il coordinatore esiste — rotta in 53 secondi
  da un `exit/2`;
- **muore un connettore** → il client conserva un claim che non ha più proprietario e lo
  rinnova ogni 10 s. Siccome il coordinatore ricalcola `NewExpiry` a ogni giro, quel claim
  **non scade mai**: un veicolo chiuso fuori da tutta la rete, per sempre.

La radice è una sola, e la correzione è la stessa frase detta nelle due direzioni: **il claim
non è un ricordo del client, è il riflesso di ciò che i connettori possiedono.** È la lezione
del rebuild del coordinatore («il coordinatore è un indice, non il registro») applicata un
livello più in basso.

### 20.2 Il `monitor` invece del soft state, e perché

La direzione pensata inizialmente era la ripresentazione periodica: ogni connettore ricasta il
proprio claim ogni N secondi, il client tiene ciò che ha sentito di recente. È il modello con
cui B ha chiuso le sospensioni, e funziona.

Il `monitor` fa la stessa cosa meglio, e il confronto vale la pena di essere scritto perché la
differenza non è di efficienza:

| | monitor + domanda all'avvio | ripresentazione periodica |
|---|---|---|
| connettore morto | chiuso **nell'istante** del `DOWN` | chiuso dopo N periodi di silenzio |
| client riavviato | chiuso al primo `handle_continue` | chiuso al primo periodo |
| traffico a regime | **zero** | un giro di cast per periodo, per sempre |
| rischio nuovo | nessuno: il `DOWN` è un fatto | un connettore vivo ma **lento** viene letto come morto, e il suo claim rilasciato per errore |

L'ultima riga decide. Il soft state ha bisogno di un timeout, e un timeout su un processo
locale è **una misura della macchina, non del fatto** — la stessa lezione di P11 (§19). Il
`monitor` è la primitiva che Erlang offre proprio per non doverlo indovinare, e arriva anche
su `exit(Pid, kill)`, che è precisamente il caso in cui `terminate/3` non viene eseguito, cioè
il buco misurato in §6.2.

La domanda all'avvio è l'altra metà, e ha un verso preciso: **la fa chi ha perso lo stato**,
una volta sola, in `handle_continue`. Un cast `{claims_rebuild, self()}` a ogni connettore
vivo; chi tiene un claim risponde con un cast che porta i sei campi. Nessuna chiamata sincrona
in nessuna delle due direzioni, quindi la regola strutturale di §4.4 regge intatta: i pid dei
connettori si leggono dall'ETS del manager con la stessa lettura sporca che il modulo già
dichiara consentita.

### 20.3 La conseguenza dichiarata: il claim è legato alla vita del processo connettore

Questo è un cambio di semantica, non un dettaglio implementativo, e va scritto come tale.

**Da oggi un claim muore quando muore il processo che lo ha chiesto.** Se un connettore crasha
e riparte *durante una sessione di ricarica con prenotazione*, il claim viene rilasciato.

È coerente con quello che il sistema già faceva: §17.5 dice che una sessione che torna dopo la
morte del connettore **è un walk-in**, e che ricostruire la prenotazione è deliberatamente non
tentato (§6 del contratto colonnina: «l'auto continua a caricare, la sessione è fatturata, la
prenotazione è persa»). Il claim seguiva quella prenotazione: rilasciarlo mette il coordinatore
d'accordo con la stazione invece di lasciarli divergere.

Ed è corretto perché **non esiste un percorso che riadotti un `hold`**. Verificato per
struttura, non per lettura: `#hold{}` viene costruito in **un solo punto**
(`vs_connector.erl`, dentro `free({call, From}, {reserve, …})`, dopo un `acquire` riuscito),
`held` si raggiunge da lì e da nessun altro posto, `init/1` parte `free` col campo a
`undefined`, e le due adozioni da hardware riagganciato passano `undefined` come claim
esplicitamente. Se un giorno qualcuno scrive una riadozione, **questa scelta va ripensata**, e
la riga sopra è il posto in cui accorgersene.

### 20.4 I sei campi non c'erano: `claim_mod:acquire/4` ne restituisce quattro

Il piano dava per scontato che il connettore avesse già i sei campi del contratto da
ripresentare. Non era vero, e la differenza non era di forma:

- `#hold.granted_at` è `vs_time:now_ms()` **della stazione**, preso dopo l'`acquire`; il
  `GrantedAt` del coordinatore non arrivava mai al connettore;
- `#hold.expires_at` è la scadenza del **lease** (900 s), non quella del claim (960 s);
- `#session` non aveva né l'uno né l'altro: due dei sei campi mancavano del tutto.

Il `ClaimExpiresAt` tornava da `acquire/4` e veniva **solo loggato**. Il `GrantedAt` viveva
solo dentro il client — e con il client moriva.

Ripresentare i valori locali sarebbe stato inventarli, ed è esattamente ciò che il PR di
contratto del 24 agosto aveva eliminato: `claim.md` §5.5 decide *oldest wins* su `GrantedAt`, e
`vs_coord_srv:renew_one/4` usa il valore riportato dalla stazione **nei due rami di adozione**,
cioè proprio nella finestra di failover. Un orologio di stazione al posto di quello del
coordinatore avrebbe rimesso lo skew fra macchine dentro il confronto.

Quindi `claim_mod:acquire/4` restituisce `{ok, ClaimId, GrantedAt, ExpiresAt}` e il connettore
tiene i due valori **del coordinatore** accanto ai propri (`claim_granted_at`,
`claim_expires_at`), copiandoli in `#session` al passaggio `held → charging`. **Il contratto
sul filo non cambia**: `GrantedAt` era già sul filo, cambia solo la giuntura interna fra
connettore e claim_mod — la stessa che rende `vs_claim_null` sostituibile.

Quattro campi tempo in due coppie, ed è bene che i nomi lo dicano: `granted_at`/`expires_at`
sono la **prenotazione della stazione** (questo orologio, il lease che il driver vede, il timer
di `held`), `claim_granted_at`/`claim_expires_at` sono il **claim del coordinatore**, copiati e
mai toccati.

### 20.5 La rete di sicurezza, e il qualificatore che la rende vera

Nel `renew_tick` i claim già scaduti non vengono rinnovati: escono dalla mappa e la loro uscita
è un **`warning`**, perché in una stazione sana non deve succedere mai e una difesa che
silenzia è peggio del difetto rumoroso.

Ma «mai» è una parola che va guadagnata. Il connettore ripresenta la scadenza che aveva
copiato **quando il claim è stato concesso**, e nel frattempo il coordinatore l'ha spostata in
avanti ogni dieci secondi: le due divergono per costruzione. Una sessione di ricarica supera
lease+grace (960 s) di routine, quindi senza qualificatore un client che riparte durante una
qualsiasi sessione più vecchia di sedici minuti avrebbe ricostruito il claim e l'avrebbe
buttato un tick dopo, gridando contro una stazione perfettamente sana — cioè rimettendo in
piedi il difetto di §6.1 per lo stato `charging`, che è esattamente quello che questo lavoro
doveva chiudere.

Perciò il `#claim` porta un `confirmed`: vero per una concessione e per ogni claim che un giro
di renew ha confermato, falso per uno che un connettore ha ripresentato. **Lo sweep guarda solo
i confermati**, e con quel qualificatore diventa quello che `claim.md` §5.6 descrive: scatta
quando una scadenza *che il coordinatore stesso ha dichiarato* è passata senza rinnovo, cioè
quando il claim è morto anche per lui.

Un claim non confermato **entra** quindi in un giro di batch anche se la sua copia locale è
scaduta. Non è «rinnovare qualcosa di morto»: è chiedere all'unico che sa. Il coordinatore
risponde adottandolo — e la scadenza vera torna in `Ok`, che lo marca confermato — oppure
revocandolo. Un giro basta: misurato sul cluster vivo, un claim ricostruito con
`expires_at = 1788024516065` è tornato `1788024774224` al primo renew.

### 20.6 Il claim id non si avvicina al browser

La strada più economica per P14 sarebbe stata lo snapshot del manager: il client è già
sottoscritto a `{station_state, …}`. È stata scartata, e non per gusto: lo snapshot non
contiene `claim_id`, e aggiungercelo lo esporrebbe a `vs_driver_proto`, cioè **a un passo dalla
pagina**, protetto solo da un filtro che qualcuno deve ricordarsi di mantenere. Un canale
dedicato costa due cast e non ha quel rischio.

`build_snapshot/2` resta quindi senza i campi nuovi, ed è asserito sul sistema vivo, non
promesso: durante la sessione di controprova la snapshot del connettore in `charging` non
conteneva alcun `claim_id`, né al primo livello né dentro `session`.

---

## 21. La firma di ritorno decide quali distinzioni sono ancora possibili a valle (P4, P10, P13)

Tre correzioni in tre punti diversi del sistema, a tre giorni di distanza, e una radice sola.
Vale una voce unica perché **la lezione non è nessuno dei tre fix**.

| | dove | il permanente detto a un temporaneo | chiuso con |
|---|---|---|---|
| **P4** | resa del riaggancio, canale colonnina | `4404` — «questo connettore non è di questa stazione» (§1: permanente, e `cp.js` ci muore sopra, correttamente) | `1012` Service Restart (§18.2) |
| **P10** | handshake della colonnina | lo stesso `4404`, stavolta all'apertura del socket | i due temporanei **ammessi**, risposta data dal `boot` con `accepted:false` (§18.3) |
| **P13** | canale driver | `UNKNOWN_CONNECTOR` — «connector does not belong to this station» | `RETRY_LATER`, allargato ai suoi tre casi reali |

### La radice: `{error, atom()}` con un atomo solo per tre fatti diversi

`vs_station_mgr` tiene una riga per ogni connettore configurato, e la riga **non sparisce mai**:
`init/1` le inserisce tutte con pid `undefined`, e il `DOWN` di un connettore rimette
`undefined` invece di cancellare. Quindi la tabella distingue tre situazioni per costruzione —
riga con pid vivo, riga con `undefined`, riga assente — e ne aggiunge una quarta chi la legge
sporco: tabella non ancora creata.

Entrambe le funzioni di lettura ne restituivano **una sola**:

```erlang
_ -> {error, unknown_connector}     %% lookup_pid/1 fino a P10, connector_pid/1 fino a P13
```

Il difetto non è il ramo `_`. È che con quella firma **nessun chiamante può più distinguere**:
l'informazione è stata buttata dentro la funzione, e a valle non c'è codice che possa
recuperarla. Ogni chiamante è allora costretto a scegliere *una* condotta per tutti e tre i
casi, e sceglie la peggiore che sia corretta per almeno uno — cioè quella permanente. Il
risultato lo paga il chiamante **più lontano**, che è sempre lo stesso: l'apparecchiatura o il
browser, gli unici che non possono discutere. La colonnina moriva con `EXIT=2`; il driver
leggeva «questo connettore non è di questa stazione» di un connettore che, un secondo dopo,
era lì.

Da cui la regola generale, che è il motivo per cui questa voce esiste: **il tipo di ritorno di
una funzione non descrive ciò che essa sa, decide ciò che i suoi chiamanti potranno sapere.**
Collassare più esiti in un atomo solo è una perdita di informazione che avviene una volta, in
un posto, in silenzio, e diventa irreversibile per tutto ciò che sta a valle.

### E la regola di contratto, che è stata la stessa tre volte

In nessuno dei tre casi è stato inventato un codice nuovo. Il codice sul filo dice al client
**cosa fare**, non classifica la causa a beneficio nostro: se la condotta è identica — riprova
fra poco — il codice deve essere identico, e la causa va nel `message`, che è il campo fatto
per quello. La controprova è che in tutti e tre i giri **il client non è stato toccato**:
`cp.js` cade da solo nel suo ramo di backoff su un `1012` e su un `accepted:false`, e `js/ws.js`
mostra il `message` verbatim senza sapere niente di connettori e supervisori. Un codice davanti
al quale un client che non sa nulla fa comunque la cosa giusta è la prova che quel codice dice
ciò che intende dire.

`ws-driver.md` §6 elenca ora i tre casi di `RETRY_LATER` con il messaggio che li separa — leader
in ricostruzione, stazione in riavvio, connettore in riavvio. I primi due il codice li produceva
**già**: il contratto ne dichiarava uno solo, ed era in ritardo di un caso senza che ce ne
fossimo accorti. Allargarlo non è stato solo aggiungere P13, è stato allineare il documento a
ciò che il codice faceva da prima.

### Il quarto esito che qui non serve, e perché non è una svista

`lookup_pid/1` ha quattro ritorni, `connector_pid/1` tre. Non è un'asimmetria da sanare: la
prima è una **dirty read** dell'ETS e cattura il proprio `badarg` quando la tabella non esiste
(`no_manager`); la seconda è una `gen_server:call`, e un manager assente non è un `badarg` qui
ma un `exit({noproc, …})` sollevato **nel chiamante** — che `vs_driver_proto` cattura già e
traduce in `no_manager` da sé. Il caso c'è in entrambe; cambia soltanto chi lo produce.
Verificato, non dedotto: una call a un nome non registrato solleva
`{noproc, {gen_server, call, [vs_station_mgr, …]}}`, che è esattamente la forma che lo stub dei
test riproduce.

### P12, accorpato qui perché è la stessa riga

Il messaggio di `vehicle_committed` diceva «your vehicle already holds a reservation
**elsewhere**». Falso nel primo caso in cui un driver ci si imbatte davvero — la seconda
prenotazione sulla **stessa** stazione, due connettori più in là — e falso *solo perché era
troppo preciso*. Tolto l'avverbio la frase è vera ovunque sia l'altra prenotazione e continua a
fare l'unico lavoro che ha: mandare il driver ad annullare quella, invece che a provare i
connettori uno per uno. La stessa frase stava nella colonna «Meaning shown» di `ws-driver.md`
§4.1 ed è stata cambiata **nello stesso commit**: un test la confronta alla lettera, e un testo
che il contratto cita e il codice non pronuncia è un contratto che ha smesso di descrivere il
codice.
