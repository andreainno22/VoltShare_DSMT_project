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

## 4. Comunicazione fra nodi

### 4.1 Erlang distribuito nativo fra stazione e coordinatore, non un broker

**Perché**: il messaggio di claim è una tupla Erlang spedita a un `gen_server` registrato; il linguaggio offre già trasporto affidabile e ordinato, monitor sui nodi e rilevamento dei guasti. Aggiungere un broker introdurrebbe un nodo in più da tenere vivo — e sarebbe un secondo punto di fallimento centralizzato in un progetto che esiste per rimuoverne uno.

### 4.2 Nomi corti (`-sname`) invece di lunghi (`-name`)

**Perché**: sulla rete di Docker Compose ogni container risolve gli altri per nome di servizio; i nomi lunghi pretenderebbero un FQDN e un DNS configurato senza dare nulla in cambio. Il deploy su più host previsto in M5 è l'unico caso in cui la scelta andrà rivista, e va rivista lì, non ora.

### 4.3 Ogni chiamata remota ha un timeout esplicito e non solleva mai eccezioni al chiamante

`vs_ping:call_remote/2`, e in M1 `vs_claim_client`, avvolgono `gen_server:call/3` in un `try ... catch` che restituisce `{error, timeout | noproc | nodedown}`.

**Perché**: `gen_server:call/2` con timeout infinito appende il processo chiamante a un nodo morto. Con timeout esplicito e risultato come valore, il connettore decide cosa fare (rifiutare la prenotazione) invece di crashare, e la stazione degrada senza fermarsi. È il presupposto della regola "niente coordinatore, niente prenotazioni nuove, ma le sessioni continuano".

Il valore (2000 ms, `CLAIM_CALL_TIMEOUT_MS`) è la parte assunta del sistema sincrono: come dice DESIGN-NOTES §6, sbagliare il timeout costa un failover inutile, non una doppia prenotazione — la correttezza la garantisce il quorum, non il timer.

### 4.4 `vs_claim_client` come unico processo che parla col coordinatore

**Perché**: i rinnovi vanno raggruppati (un solo messaggio `renew` per stazione ogni 10 s, non uno per connettore) e il nodo leader corrente è uno stato solo, aggiornato in un posto solo quando arriva un `{not_serving, Leader}`. Se ogni connettore parlasse per conto proprio, ogni connettore dovrebbe scoprire il nuovo leader da sé, moltiplicando i messaggi durante un failover — cioè proprio quando la rete è già in difficoltà.

---

## 5. Verifica

### 5.1 Logica pura separata dai processi, testata con EUnit

Il riparto della potenza e le decisioni di stato sono funzioni pure chiamate dai `gen_server`/`gen_statem`, non logica dentro i callback.

**Perché**: una funzione pura si testa con una tabella di casi e senza avviare nulla. Testare l'algoritmo di riparto attraverso i messaggi di un processo richiederebbe di orchestrare processi per verificare una divisione.

### 5.2 Il probe M0 (`vs_ping`) ha la forma del client dei claim

**Perché**: non è codice usa e getta. Verifica esattamente ciò che rischia di rompersi nel deploy (nomi, cookie, DNS) usando lo stesso schema che userà `vs_claim_client`: gen_server, call remota con timeout, tick con `erlang:send_after/3`, errore trattato come valore. Quando arriva M1, il modulo vero è una riscrittura di qualcosa di già visto funzionare.
