# VoltShare — stato dei lavori

Registro di cosa esiste, cosa è stato verificato e cosa manca. Si aggiorna a ogni pezzo consegnato.
Il piano di riferimento è [piano.md](piano.md); le specifiche sono in [SCOPE.md](SCOPE.md) e [DESIGN-NOTES.md](DESIGN-NOTES.md).

**Ultimo aggiornamento:** 3 settembre 2026 — **tutte le milestone di codice sono chiuse sui due lati**, e **P18 è chiuso su tutti e due**. M0, M1, M2, M3 e M4, di A e di B, sono su `main`; l'1/09 il giro intero è stato guardato **in un browser vero** (§7zk), l'ultima cosa che restava fuori dal M1. Del difetto grave **P18** la metà di A è su `main` (§7zl, finestra da **4,11 s a 0 ms**) e la metà di B è in questo ramo: un rebuild vuoto con la tabella vuota **non promuove più a `serving`**, si resta in `rebuilding` finché non arriva un renew — è il compromesso disponibilità/correttezza, deciso in due e non da uno solo. Chiuso anche **A7**, l'ultimo rilievo della review: i tre valori delle pagine live escono dallo `<script>` e diventano attributi `data-` passati per `<c:out>` (§7zo). Resta la **M5**: prova generale, demo, relazione.

---

## 1. Quadro d'insieme

| Milestone | A (stazione, emulatore, viste live) | B (coordinatore, back office, pagine) |
|---|---|---|
| **M0** fondamenta | ✅ impianto Erlang, ping fra nodi, deploy | ✅ contratti, schema, token di esempio |
| **M1** percorso base | ✅ **chiusa e verificata in Docker il 27/08**: 7 container, token emesso da Tomcat e verificato dalla stazione, `reserve` fino al coordinatore vero e ritorno, dedup provata dentro `vs_coord_srv`, lease che libera da solo, riconnessione dopo `stop station1`. La resa visiva, unica cosa rimasta fuori per settimane, è **chiusa l'1/09** nel Chrome vero (§7zk): fino a quel giorno la logica del rendering era provata con un DOM minimale, non coi pixel | ✅ **chiusa e verificata in Docker il 25/08**: coordinatore vero, ponte JInterface, Tomcat, lobby con dati veri dal browser |
| **M2** sessione e potenza | ✅ **chiusa il 28/08**: canale colonnina, riparto della potenza, INSERT su `sessions`, `session.jsp`, emulatore. L'ultima pendenza — il fuso di `history.jsp`, che serviva un browser — è chiusa l'1/09 (§7zj, §7zk) | ✅ **fatturazione e storico**, provati contro MySQL (§7k) |
| **M3** tolleranza ai guasti | ✅ **chiusa fra il 29/08 e l'1/09**: il claim client smette di *ricordare* i claim e li **riflette** dai connettori (P14/P15, §7zd); il canale driver non risponde più «non è tuo» a un connettore che sta riavviando (P13/P12, §7ze); e le quattro misure di coda — partizione vera del leader vista dalla stazione, strada lenta, scadenza naturale, redirect circolare prodotto nei container (§7zj). Da quest'ultima è uscito **P18**, grave, misurato e non corretto per scelta (§8) | ✅ **elezione, quorum, ricostruzione** — failover provato in Docker (§7m) |
| **M4** regole di dominio | ✅ **chiusa fra il 30/08 e l'1/09**: `overstay` come fase derivata da `complete`, con `overstay_seconds` **netto** scritto all'unplug (§7zf); no-show e show-up raccontati al coordinatore **at-most-once** (§7zg); il frame `notification` di `ws-driver.md` §5.3 finalmente **emesso** — sei kind live al browser, quattro anche in copia durevole (§7zh); più i cinque rilievi della review di B, applicati per intero (§7zi). **La lista d'attesa resta fuori di proposito**: non è M4, e il contratto ora dichiara `waitlist_offer` non producibile invece di lasciarlo sembrare implementato | ✅ **penalità, notifiche, profilo** — provate contro il cluster (§7z) |
| **M5** consegna | ⬜ prova generale, demo, relazione | ⬜ prova generale, demo, relazione |

### Cosa è stato realmente eseguito

Distinzione importante, perché non tutto è verificabile su questa macchina:

| | Stato |
|---|---|
| Back office: compilazione e `war` | ✅ verificato — `mvn clean package` produce `target/voltshare.war` |
| Back office: test unitari | ✅ verificato — 4 test su `JwtUtil`, tutti verdi |
| Back office: esecuzione su Tomcat | ✅ **verificato il 25/08** su Tomcat 10.1.34 in locale — war deployato, JSP compilate, filtro e redirect corretti, bridge Erlang avviato dentro il container. Senza MySQL: percorso d'errore verificato, lobby no |
| `vs_coord`: compilazione | ✅ verificato su OTP 29 — un solo errore da correggere (`catch Expr` deprecato) |
| `vs_coord`: test EUnit | ✅ **16 test, 0 fallimenti** — misurati con `rebar3 eunit --app=vs_coord` il 25/08. Il "22" che stava qui contava le `?assert*`, non i casi: se n'è accorto A (§7l) |
| Suite EUnit completa, con la parte A | ✅ verificato il 24/08 — **44 test, 0 fallimenti**: è arrivato `a/m1-station-core` (station manager, `vs_claim_client`, `vs_mock_coord`) |
| Erlang: compilazione in generale | ✅ verificato — `rebar3 compile` pulito sulle tre applicazioni |
| JInterface: connessione Java → nodo Erlang | ✅ verificato **fuori dal progetto** — `OtpNode.ping` risponde `PONG` verso un nodo OTP 29 locale |
| Docker compose (macchina B) | ✅ **eseguito il 25/08** — 5 container, coordinatore vero al posto del mock, lobby con dati veri dal browser |
| Ponte JInterface fra Java ed Erlang | ✅ **verificato il 25/08** — `vs_coord_bo` → `ErlangBridge` end-to-end: coordinatore vero su `vs@NINJA2218`, Java come nodo nascosto, due stazioni ricevute con tutti i campi corretti. Test `ErlangBridgeIT` |
| `vs_station` M1 (connettori, manager, claim client): test EUnit | ✅ verificato — **48 test, 0 fallimenti** su OTP 29.0.5 (macchina A, 24/08: 22 connettore + 7 manager + 10 client + 9 vs_common) |
| `vs_station` M1 passo 3 (canale driver): test EUnit | ✅ verificato — **96 test lato A, 0 fallimenti** su OTP 29.0.5 (macchina A, 24/08: 22 connettore + 10 manager + 13 client + 11 `vs_jwt` + 31 `vs_driver_proto` + 9 vs_common) |
| **Suite completa su `main`** | ✅ **132 test, 0 fallimenti** — misurati il 25/08, non stimati: `vs_common` 9 + `vs_station` 87 + `vs_coord` 36 (16 claim + 11 failover + 9 quorum). Rimisurati il 26/08 su `main`: **ancora 132** |
| **Suite dopo il passo 4 (branch `a/m1-passo4`)** | ✅ **133 test, 0 fallimenti** — misurati il 26/08: il +1 è il test che tiene separati i due rifiuti di §4.1 (`already_held` vs `vehicle_committed`) |
| Attenzione alla misura per applicazione | ⚠️ `rebar3 eunit --app vs_coord` risponde **25**, non 36: rebar3 accoppia i moduli di test ai moduli sorgente e `vs_coord_failover.erl` non esiste, quindi gli 11 test di failover vengono **saltati in silenzio**. Il totale è giusto solo lanciando `rebar3 eunit` senza `--app` |
| Failover con tre coordinatori | ✅ **eseguito il 25/08** in Docker — due leader uccisi di fila, minoranza sospesa, claim riadottato con lo stesso `granted_at` (§7m) |
| Canale driver contro il contratto (`ws-driver.md`) | ✅ verificato nei test — handshake coi tre token di `sample-tokens.md`, at-most-once dimostrato contando le chiamate al connettore, tabella dei rifiuti §4.1/§6, traduzione `offline` → `out_of_service`, `coordinator_reachable` end-to-end |
| `vs_claim_client` ↔ `vs_mock_coord` sul contratto vero | ✅ verificato nei test — claim, eco del `GrantedAt` nel renew, release, revoca end-to-end, `station_stats` |
| Docker compose (macchina A) | ✅ **eseguito** — 7 container su, coord1 (mock) riceve `station_up` da entrambe le stazioni (4 e 3 connettori) |
| **Passo 4 end-to-end in Docker (27/08)** | ✅ **7 container**; `/js/ws.js` e `/js/station.js` serviti 200 da Tomcat senza toccare `web.xml`; `WS_URL` reso nella pagina è **`ws://localhost:9101/ws/driver`**, senza query string — conferma che appenderla è compito del client; 4 connettori su station1 e 3 su station2; `reserve` acked e `held`/`held_by_me` al `state` **successivo**; lease di 60 s che libera il connettore da solo a t=+59 s, 0 s dopo la scadenza annunciata; `stop station1` → chiusura **1001**, backoff, e ripopolamento **senza ricaricare** 17 s dopo |
| Parte 0 vista dall'utente, col coordinatore vero | ✅ **27/08** — prenotato il connettore 1 di station1, poi tentato station2 con lo stesso veicolo: `NO_CLAIM` + *"your vehicle already holds a reservation elsewhere"*, **non** *"held by another driver"* |
| Click dopo una chiusura fatale | ✅ **chiuso il 27/08** — era il limite dichiarato nel report del 26: la griglia restava cliccabile dopo un `4401`/`4408` e l'azione si accodava per sempre, congelando il pulsante in silenzio. Ora `send()` rifiuta all'istante (7 ms) con *"your session has expired — reload the page"*. Scenario ordinario, non limite: il token dura 60 min e la scadenza si controlla solo al `join` |
| `station.js` eseguito | 🟡 **27/08** — 23 controlli verdi contro frame veri con un DOM minimale in Node: griglia, pillola di stato, intestazione riscritta, regole dei pulsanti (Reserve/Cancel/Stop e **nessun pulsante** su `out_of_service`, `suspended` e sessioni altrui), conto alla rovescia da `expires_at` che scende da solo, messaggio del server accanto al connettore, avviso `coordinator_reachable`. **Non è un browser**: prova la logica, non i pixel |
| Compose sull'immagine Debian 29.0.5 | 🟡 build verde; il giro completo era stato fatto con l'immagine 386, da ripetere dopo il merge |
| Client del canale driver (`js/ws.js`) contro una stazione vera | ✅ **misurato il 26/08** — `ws.js` eseguito non modificato contro un nodo `vs_station` reale: handshake, primo `state` con 4 connettori, `reserve` acked e connettore `held` **al `state` successivo**, ritentativo del frame perso con lo **stesso** `request_id` (2 trasmissioni, 1 id, 5015 ms, **una** prenotazione), 4401 e 4400 che fermano il client senza loop. 22 controlli verdi |
| ① Giro in container con le dipendenze | ✅ **chiusa il 27/08** — `/app/lib` contiene `cowboy cowlib jose jsx ranch`, e le cinque versioni nell'immagine coincidono **esattamente** con `rebar.lock` (cowboy 2.18.0, cowlib 2.19.0, jose 1.11.12, jsx 3.1.0, ranch 2.2.1): il lock è onorato dentro il container |
| ② Dedup attraverso il **coordinatore vero** | ✅ **chiusa il 27/08** — buttato via il primo frame, il client ha ritrasmesso lo **stesso** `request_id`; `vs_coord_srv:claims()` sul leader `vs@coord3` mostra **un solo** claim. P7 dimostrata sul sistema intero, non più solo nei test |
| ③ Novanta secondi di inattività senza scollegarsi | ✅ **chiusa il 27/08** — **101 secondi** senza inviare nulla: socket sempre aperto, `["connecting","online"]` e nessuna riconnessione, 23 push di stato ricevuti. Il `pong` automatico tiene davvero fermo l'`idle_timeout` (60 s) di cowboy. Misurato con un client Node, che risponde ai ping esattamente come un browser |
| ④ JWT in transito (B firma con `JwtUtil`, A verifica con `vs_jwt`) | ✅ **chiusa il 27/08** — registrato un utente vero da Tomcat, letto il `TOKEN` dalla pagina renderizzata (`sub:"1"`, `vehicle_id:1`, `iss:voltshare-backoffice`, 60 min) e usato per il `join`: accettato. È l'ultimo pezzo del confine fra le due metà, ed era l'unico mai provato |
| **Suite completa dopo il merge di `a/m2-cp-touchups` (P11)** | ✅ **307 test** — misurati il 29/08 su `a/p11-suite-flake`: **stesso totale su 26 giri della suite completa**, e 0 fallimenti su 25 di quei 26 (l'unico rosso è il terzo difetto di §7zb, prima della sua correzione; dopo la correzione, 13 giri su 13 verdi). Da oggi il numero non è più una nota: `src/scripts/eunit_check.sh` lo confronta e fallisce se cambia (§7zb). **311 dal 29/08 con i quattro test di P10** (§7zc) |
| **Suite completa oggi** | ✅ **395 test, 0 fallimenti** — `./src/scripts/eunit_check.sh`, `EXPECTED_TESTS=395`. Erano **386** su `9ff8e63`, poi **392** con i test della metà A di P18 (§7zl), e **395** con i tre della metà di B. Aggiornare quel numero fa parte dell'aggiungere test, e il conteggio è un'asserzione, non una speranza (§7zb) |
| **Il giro intero in un browser vero** | ✅ **1/09** (§7zk) — registrazione, griglia, countdown, `charging`, stop → `complete` istantaneo con la potenza che rientra nel pool, `complete` → `overstay` al tick, la riga in `/notifications` con l'ora locale giusta, e in `/history` la sessione a **1,58 kWh · overstay 10 min · € 5,71**, conto verificato al centesimo. È la riga che chiude il «non i pixel» di M1 |
| **Partizione di rete vera sul *leader*** | ✅ **1/09** (§7zj) — `docker network disconnect` sul leader con due claim vivi e una ricarica in corso: `QUORUM LOST (1 of 3) … abdicating` a **2,12 s**, leader nuovo che serve con entrambi i claim a **2,29 s**, nodedown della distribuzione solo a **64,6 s**. Senza FIN si paga il tick — è ciò che `docker kill` non può mostrare |
| **Redirect circolare prodotto nei container** | ✅ **1/09** (§7zj) — fino a quel giorno solo in eunit. Nella finestra in cui un leader appena eletto è `rebuilding`, un conducente ha ricevuto **undici `RETRY_LATER` di fila** invece di rimbalzare: un redirect solo, mai un giro, sul codice di produzione |

**Prerequisiti ancora da installare:** solo Docker Desktop. Erlang/OTP 29 (erts 17.0.5) + rebar3 3.27, JDK 17 e Maven 3.9.9 ci sono e funzionano.

**PATH:** risolto il 24/08. `erl`, `erlc`, `escript` e `rebar3` si invocano direttamente sia da bash sia da PowerShell — non serve più il prefisso `export PATH="/c/Program Files/Erlang OTP/bin:$PATH"` che compariva nelle istruzioni precedenti.

---

## 2. Contratti — `src/contracts/`

Sono la parte che tiene insieme il lavoro delle due persone. Modificare `claim.md` o `jwt.md` richiede una PR rivista da entrambi.

| File | Contenuto | Stato |
|---|---|---|
| `claim.md` | **condiviso.** Cinque messaggi stazione↔coordinatore, tipi, regole di comportamento, ricerca del leader, due esempi di sequenza | ✅ scritto, da rivedere insieme |
| `jwt.md` | **condiviso.** HS256, claim, durata, passaggio via EL alla pagina | ✅ scritto |
| `sample-tokens.md` | tre token generati e verificati: valido fino al 2027, scaduto, con firma errata | ✅ generato dal codice |
| `schema.sql` | DDL e seed, con la proprietà delle tabelle divisa fra A e B | ✅ scritto |
| `ws-driver.md` | interno ad A — canale browser↔stazione | ✅ scritto |
| `ws-chargepoint.md` | interno ad A — canale colonnina↔stazione | ✅ scritto |
| `erlang-java.md` | interno a B — ponte JInterface: topologia, messaggi nelle due direzioni, comportamento ai guasti, prova di connettività | ✅ scritto |

---

## 3. Erlang — `src/erlang/`

Progetto umbrella con due applicazioni più una libreria condivisa.

```
apps/vs_common/     vs_env.erl (configurazione da ambiente), vs_time.erl
                    + test EUnit per entrambi
apps/vs_station/    vs_station_app, vs_station_sup, vs_ping,
                    vs_connector (gen_statem), vs_connector_sup,
                    vs_station_mgr, vs_claim_client, vs_station_db,
                    vs_claim_null
                    + test EUnit  ← 39 (connettore, manager, client)
apps/vs_coord/      vs_coord_app, vs_coord_sup, vs_coord_srv, vs_coord_bo
                    + test EUnit sui claim  ← 16 test, verdi su OTP 29
apps/vs_mock_coord/ coordinatore finto di M1 (A): si registra col nome
                    vero vs_coord_srv, concede sempre — riferimento
                    eseguibile del contratto e banco dei test del client
```

### Cosa è emerso alla prima compilazione

Le ~400 righe mai compilate hanno retto meglio del previsto: **un solo errore**, e nel
codice di produzione. Due difetti erano invece nella fixture dei test, e sono usciti solo
eseguendoli.

| Dove | Difetto | Correzione |
|---|---|---|
| `vs_coord_srv:publish/1` | `catch Expr`, deprecato da OTP 29, bloccato da `warnings_as_errors` | `try ... catch _:_ -> ok end` |
| `vs_coord_srv_tests:cleanup/1` | `exit/2` è asincrono: il `setup` successivo correva contro la deregistrazione del nome e falliva con `{already_started, Pid}`. Nove test su ventuno venivano annullati | `monitor` + attesa del `DOWN` |
| `vs_coord_srv_tests` | `expired_claim_no_longer_blocks` impostava `CLAIM_GRACE_SECONDS` **dentro** il test, ma la grace è letta una volta sola in `init/1`: il claim non scadeva e il test falliva con `already_held` | grace a `0` nel `setup`, dove ha effetto |

L'ultimo merita una riga in più, perché è una vera asimmetria del modulo, non una svista
del test: `LEASE_SECONDS` è riletto a ogni concessione, `CLAIM_GRACE_SECONDS` no. Va bene
così — la grace è una costante di deploy, il lease no — ma chi scrive test deve saperlo,
ed è ora annotato nel `setup`.

### `vs_coord` — coordinatore di M1

| Modulo | Ruolo |
|---|---|
| `vs_coord_srv` | il cuore: tabella dei claim, mappa delle stazioni, monitor sui nodi, i cinque messaggi di `contracts/claim.md` |
| `vs_coord_bo` | push verso il back office via JInterface, con ripubblicazione ogni 30 s |
| `vs_coord_sup` | strategia `rest_for_one`: il ponte pubblica ciò che il server possiede, quindi va riavviato dopo di lui |

Scelte prese scrivendolo:

- **Claim e stazioni in `map` dentro lo stato, non in ETS.** Solo questo processo li legge; la map tiene onesto il codice su chi possiede cosa. Se M3 avrà bisogno di letture concorrenti, il passaggio a ETS è locale.
- **Un claim scaduto non blocca il veicolo anche prima dello sweep.** Lo sweep periodico è manutenzione, non la regola: la verifica avviene alla lettura.
- **`user_id = 0` per i claim adottati.** Quando un nuovo leader adotta un claim che non ha concesso, non conosce l'utente: il messaggio di rinnovo non lo porta. Non è un problema in M1 (serve solo per le sospensioni, che arrivano in M4), ma va sistemato — o aggiungendo `user_id` al rinnovo, o recuperandolo con `who_do_you_hold`.
- **La caduta di un nodo stazione revoca i suoi claim.** Senza, i conducenti resterebbero bloccati fuori da tutta la rete fino alla scadenza.

`rebar.config` **non ha dipendenze esterne**: la compilazione di M0 funziona offline e in pochi secondi, così il test di rete non fallisce mai per motivi estranei alla distribuzione. Cowboy, jsx, jose e mysql sono elencati come commento e arrivano con M1.

`vs_ping` è la prova di connettività di M0, ed è scritto apposta con la stessa forma che avrà `vs_claim_client`: un `gen_server` che possiede il collegamento verso un nodo remoto, lo chiama con timeout esplicito e ripianifica un tick con `erlang:send_after/3`. Anche la gestione degli errori è quella definitiva — un nodo remoto morto viene registrato nel log e la vita continua, mai un'eccezione che propaga.

### `vs_station` — stazione di M1, passi 1 e 2 (A, 24 agosto)

| Modulo | Ruolo |
|---|---|
| `vs_connector` | `gen_statem`, un processo per presa: `free → held → charging → closing`, lease con `state_timeout`, walk-in senza claim, revoca autoritativa anche a sessione avviata |
| `vs_connector_sup` | `simple_one_for_one`, `restart => transient`: chi crasha riparte in `free`, lo stato sicuro |
| `vs_station_mgr` | registry ETS dei connettori, stato aggregato per il push `state`, sottoscrittori (call e cast), budget di potenza come valore (il riparto è M2); se a riavviarsi è lui, **adotta** i connettori vivi invece di riavviarli |
| `vs_claim_client` | l'unico processo che parla col coordinatore: discovery del leader (contratto §4), renew ogni 10 s in un worker effimero, tabella dei claim, `who_do_you_hold` risposto dalla memoria, `station_up` + `station_stats` (event-driven, dedup) |

Due regole strutturali, entrambe figlie del deadlock dei ping di M0: il claim client **non si blocca mai su una chiamata remota** (acquire gira nel processo del connettore, che giustamente aspetta; i renew in un worker effimero) e **non fa mai call sincrone verso manager o connettori** (letture ETS dirty, cast) — nel grafo delle chiamate sincrone della stazione non esistono cicli. Le motivazioni complete, per l'orale, sono in `erlang/scelte_di_progetto.md` §7–8.

`vs_mock_coord` parla il contratto vero, trasporto incluso (`claim`/`renew` come call, `release`/`station_up`/`station_stats` come cast — riferimento anche per B), ed è ispezionabile per i test: `history/0`, `set_reply/1` per i rifiuti, `set_renew/1` per la revoca end-to-end. La sostituzione col `vs_coord` vero è un cambio di `ERL_APP` nel compose.

---

## 4. Back office — `src/backoffice/`

Applicazione web Java su Tomcat 10.1, modello MVC del lab 08: servlet come controller, `forward` alla JSP, JSTL ed EL per la resa. Niente REST, niente JavaScript salvo nelle due viste live di A.

### Classi

| Package | Classe | Ruolo | Stato |
|---|---|---|---|
| `util` | `Env` | lettura configurazione da ambiente con default | ✅ |
| `util` | `JwtUtil` | firma e verifica dei token secondo `contracts/jwt.md` | ✅ con test |
| `util` | `PasswordUtil` | hash BCrypt | ✅ |
| `model` | `User`, `StationView` | POJO con getter JavaBean | ✅ |
| `dao` | `Db` | connessione: pool JNDI in Tomcat, `DriverManager` fuori | ✅ |
| `dao` | `UserDao` | registrazione (transazionale, utente + veicolo), autenticazione | ✅ |
| `erlang` | `StationDirectory` | cache in memoria della lista stazioni, sostituita per intero a ogni push | ✅ |
| `erlang` | `ErlangBridge` | `OtpNode` + mailbox `backoffice`, loop di ricezione, riconnessione | ✅ scritto, **mai eseguito** |
| `web` | `AppListener` | avvia e ferma il ponte con l'applicazione | ✅ |
| `web` | `AuthFilter` | protegge le pagine riservate, redirect al login | ✅ |
| `web` | `LoginServlet`, `RegisterServlet`, `LogoutServlet` | sessione HTTP + emissione del JWT | ✅ |
| `web` | `StationsServlet` | lista dalla cache, senza interrogare il cluster | ✅ |
| `web` | `StationPageServlet` | prepara la pagina live di A | ✅ |

### Pagine

| File | Proprietario | Stato |
|---|---|---|
| `WEB-INF/tags/page.tag` | B | ✅ intestazione, navigazione, piè di pagina |
| `login.jsp`, `register.jsp` | B | ✅ |
| `stations.jsp` | B | ✅ con avviso quando il cluster è irraggiungibile |
| `station-unavailable.jsp`, `error.jsp`, `index.jsp` | B | ✅ |
| `css/app.css` | B | ✅ deliberatamente spartano |
| `station.jsp` | **A** | ✅ completata: griglia dei connettori, pulsanti per stato, conto alla rovescia da `expires_at`, avviso `coordinator_reachable`; stili nella pagina, `app.css` non toccato |
| `js/ws.js`, `js/station.js` | **A** | ✅ scritti — trasporto e rendering separati (scelte §10) |
| `session.jsp`, `js/*` | **A** | ⬜ |

---

## 5. Deploy — `src/deploy/`

`docker-compose.yml` con MySQL, due nodi stazione e **coord1 che esegue il mock** (`ERL_APP: vs_mock_coord`); B lo sostituirà col `vs_coord` vero a parità di hostname e nome nodo. Le stazioni ricevono da env `CONNECTORS`, `SITE_POWER_KW`, `STATION_NAME`, `WS_URL`, `TARIFF_CENTS_KWH`, allineate al seed di `schema.sql`. Coordinatori veri e back office restano dichiarati e commentati.

L'immagine base è `erlang:29.0.5` **Debian**, non alpine: la build alpine/amd64 ufficiale è ferma a 29.0.2 e il tag `29.0.5-alpine` pubblica solo varianti 386/arm — Docker ripiegava **in silenzio** sul 32 bit, scoperto da un `WARN InvalidBaseImagePlatform`. Il tag di un'immagine promette la versione, non l'architettura (dettagli in `deploy/scelte_di_progetto.md`).

Lo `schema.sql` è **montato** da `contracts/`, non copiato: una sola copia da modificare.

---

## 6. Comandi verificati

```bash
# back office
cd src/backoffice
mvn clean package                      # produce target/voltshare.war, jinterface-1.16 in WEB-INF/lib
mvn test                               # 4 test, verdi
mvn test -Dtest=SampleTokenGenerator   # rigenera i token di contracts/sample-tokens.md

# erlang — OTP 29.0.5, rebar3 3.27
cd src/erlang
rebar3 compile                         # quattro applicazioni, nessun warning
rebar3 eunit                           # 395 test, 0 fallimenti (03/09, con le due metà di P18)
#
# Dal 29/08 il controllo vero prima di un push è lo script, non il comando nudo.
# Si posiziona da sé, quindi gira da qualunque directory (qui dalla radice):
#
#   ./src/scripts/eunit_check.sh         # verde solo se exit 0 E "395 tests, 0 failures"
#
# Il numero atteso vive in EXPECTED_TESTS dentro lo script: chi aggiunge test lo
# aggiorna nello stesso commit, altrimenti il guardiano diventa rosso a ragione.
#
# `rebar3 eunit' da solo non basta: un giro può stampare "0 failures" e avere
# ventidue test cancellati, o perderne otto dal conteggio (§7zb).
#
# Nota di misura (24/08, macchina A): `rebar3 eunit --app vs_coord` conta **13**
# test, non i 22 riportati sopra per M1-B — il file ha due generatori con 13
# funzioni in tutto e 0 fallimenti. Nessun test è rotto: è solo un conteggio da
# riallineare, e lo verifichi B sul proprio lato.

# tutto insieme (verificato su macchina A il 24/08)
cd src/deploy
docker compose up --build -d
docker compose logs -f coord1          # station_up delle due stazioni ogni 30 s
```

Su Windows `rebar3` è l'escript più un `rebar3.cmd` accanto che invoca
`escript.exe "%~dp0rebar3" %*`: `rebar3 local install` non è implementato.
`epmd.exe` non sta in `Erlang OTP\bin` ma in `Erlang OTP\erts-17.0.5\bin`, utile
saperlo quando serve `epmd -names` per capire quali nodi sono registrati.

---

## 7. Decisioni prese durante l'implementazione

Cose emerse scrivendo il codice, non previste dal piano.

**I record Java non funzionano con EL.** `User` e `StationView` erano stati scritti come `record`, ma le JSP risolvono `${user.username}` con la convenzione JavaBeans, che i record non seguono. Riscritti come POJO con getter espliciti. Vale per qualunque oggetto destinato a una pagina.

**Il segreto JWT deve essere lungo almeno 32 caratteri.** HS256 richiede 256 bit di chiave e jjwt si rifiuta di firmare con meno: `dev-secret-change-me` non bastava. Aggiornati `contracts/jwt.md` e `docker-compose.yml` con `dev-secret-change-me-0123456789ab`.

**EL non fa escaping.** Nelle JSP tutti i valori che arrivano dall'utente passano da `<c:out>`; `${...}` nudo in un attributo `value` è una falla XSS.

**`OtpErlangLong.intValue()` lancia un'eccezione controllata.** Nel ponte si usa `(int) longValue()`, che non la dichiara.

**⚠️ JInterface di Maven Central non funziona con OTP 26+.** L'artefatto `org.erlang.otp:jinterface` si ferma alla **1.6.1**, del 2011, e non riesce ad aprire il canale di distribuzione verso un nodo moderno: `OtpNode.ping` non ottiene risposta. Verificato con una sonda Java contro un nodo `-sname` reale — stessa sonda, stessa JVM, stesso cookie: 1.6.1 fallisce, una JInterface recente risponde `PONG`. Non è un effetto della 29: sarebbe fallito anche sulla 26 del piano originale, e sarebbe emerso solo al primo avvio del ponte.

Il jar corretto è la **1.16**, quella della OTP 29, compilata dai sorgenti ufficiali e messa in `backoffice/libs/` con la struttura di un repository Maven, dichiarato nel `pom.xml` come `voltshare-local`. `mvn package` funziona senza passaggi manuali e il jar finisce in `WEB-INF/lib` (verificato). Dettagli e comandi per rigenerarlo in `backoffice/libs/README.md`.

**`catch Expr` è deprecato da OTP 29.** Con `warnings_as_errors` è un errore di compilazione. In `vs_coord_srv:publish/1` è diventato un `try ... catch ... end` esteso. Da ricordare scrivendo `vs_station`: la forma breve è quella che viene naturale in una `gen_server`.

**Il repository Maven locale usa un URL `file://`.** Funziona anche con il percorso del progetto, che contiene spazi e un accento (`Università`) — provato. Se un giorno dovesse rompersi, l'alternativa non è `maven-install-plugin` in fase `initialize`: Maven risolve le dipendenze prima di eseguirla, quindi non fa in tempo a installare nulla.

**Il token non passa dal JavaScript.** La servlet lo mette in sessione, la JSP lo stampa nel markup, il codice del WebSocket lo legge da lì. Niente `sessionStorage`, niente refresh token: la sessione di login la gestisce Tomcat.

**⚠️ Modifica a un contratto condiviso — `GrantedAt` nel messaggio `renew`.** `claim.md` prescriveva che un nuovo leader adotti un claim sconosciuto «con il `GrantedAt` che la stazione riporta», ma quel campo nel messaggio non c'era: la regola «vince il più vecchio» non aveva niente da confrontare. La tupla è diventata `{ClaimId, VehicleId, ConnId, GrantedAt}`. **Da comunicare ad A prima che implementi `vs_claim_client`.**

→ **Chiuso il 24/08 con accordo A+B**, in forma più ampia: `GrantedAt` lo emette **sempre il coordinatore** — `acquire` risponde `{ok, ReqId, ClaimId, GrantedAt, ExpiresAt}` e la stazione lo ripete senza mai inventare timestamp propri, così "oldest wins" è deciso da un solo orologio anche dopo un failover. Il rinnovo è a **cinque campi** `{ClaimId, VehicleId, ConnId, UserId, GrantedAt}`: lo `UserId` chiude anche il punto dei claim adottati. Lato A client, mock e test sono adeguati; lato B restano il matcher del `renew` e la **PR formale su `claim.md`** (la apre B, A reviewer).

---

## 7b. Code review del 23 agosto — sei difetti corretti

Rilettura di `vs_coord` e del back office. Tutto verificato con i test dopo la correzione.

**① Un release tardivo cancellava il claim sbagliato — P2 violato.** `drop_claim/3` risaliva dal `claim_id` al veicolo e cancellava qualunque claim ci trovasse, senza controllare che fosse davvero quello. Sequenza: il lease di `c-A` scade, il veicolo viene legittimamente riassegnato a `c-B` di un'altra stazione, poi arriva il release di `c-A` — normale, non un caso di scuola — e porta via `c-B`. La stazione continuava a credersi titolare di una prenotazione che il coordinatore aveva dimenticato, e una terza stazione poteva prenotare lo stesso veicolo. Corretto con il confronto dell'identità; **test di regressione `late_release_does_not_erase_the_new_claim`**, che senza la correzione fallisce con `{badmatch,[]}`.

**② Voci orfane in `by_id`.** Sostituendo un claim scaduto restava l'indice del precedente, e nulla lo rimuoveva: lo sweep guarda solo `claims`. Perdita lenta ma illimitata. Corretto in `store/2`.

**③ Monitor duplicati sui nodi.** `forget_node/2` non chiamava `monitor_node(Node, false)`: al ritorno della stazione se ne installava un secondo, e ogni crash successivo arrivava due volte. Innocuo oggi, sorgente di eventi doppi in M3.

**④ Le JSP interne erano raggiungibili direttamente.** `stations.jsp`, `station.jsp` e le altre stavano nella radice della webapp, fuori dalla copertura di `AuthFilter`. Spostate sotto `WEB-INF/views/`, dove il container rifiuta le richieste dirette; `login.jsp` e `register.jsp` restano pubbliche perché devono esserlo. Nessun dato era esposto — gli attributi di request erano vuoti — ma con `history` e `profile` in arrivo la superficie sarebbe cambiata.

**⑤ Doppio rollback** in `UserDao.register` sul nome duplicato.

**⑥ Open redirect con backslash.** Il controllo su `next` non copriva `/\evil.com`, che alcuni browser normalizzano in `//evil.com`.

**Nota metodologica.** Avevo attribuito ① a `store/2` e presentato il controllo in `drop_claim` come difesa in profondità: rimuovendo i fix uno per volta si è visto che è **il contrario** — il controllo di identità è ciò che protegge P2, mentre `store/2` risolve solo la perdita di memoria. Vale la pena provare che un test fallisca senza la correzione, invece di fidarsi del ragionamento.

---

## 7c. Scambio con A — 24 agosto

A ha mandato `nota-per-B-M1.md`: station manager, `vs_claim_client` e un coordinatore finto (`vs_mock_coord`) registrato col nome vero, sul branch `a/m1-station-core`. Risposta in `risposta-per-A-M1.md`.

**Il punto che blocca l'integrazione.** Avevo aggiunto `GrantedAt` al payload di `renew` in `claim.md` mentre scrivevo il rebuild, **senza la PR che il nostro accordo prevede** per i contratti condivisi. Risultato: la stazione manda una 3-tupla `{ClaimId, VehicleId, ConnId}`, il coordinatore fa match su una 4-tupla, e il primo renew farebbe saltare `function_clause` dentro `handle_call` — il coordinatore non risponde male, muore e riparte perdendo i claim.

**La proposta fatta ad A**, da chiudere in un'unica PR su `claim.md`:

1. `GrantedAt` nel payload di `renew` (quello che ho già implementato, da formalizzare);
2. `GrantedAt` **restituito anche da `acquire`**: `{ok, ReqId, ClaimId, GrantedAt, ExpiresAt}`. Oggi la stazione userebbe il proprio orologio e il coordinatore il suo, quindi "oldest wins" confronterebbe timestamp di macchine diverse e in caso di conflitto deciderebbe lo skew. Facendoli generare tutti al coordinatore, l'ordinamento dipende da un orologio solo — proprietà difendibile, invece di un limite da dichiarare.

Altri punti della risposta: `station_stats` servono (senza, la lobby mostra sempre "tutti liberi"); framing `call`/`cast`/`info` confermato e già allineato; nell'adozione di un claim sconosciuto manca `UserId` — o entra nella tupla di `renew`, o lo recupero da `who_do_you_hold`.

### Cosa è stato chiuso subito, senza aspettare la PR

- **Il crash non è più possibile.** `renew_one/4` accetta sia la 3-tupla sia la 4-tupla: la forma vecchia viene trattata come la nuova con `GrantedAt` preso dall'orologio del coordinatore, più un `notice` per rinnovo. Test `renew_without_granted_at_is_accepted`. L'integrazione può partire con la stazione così com'è. **45 test, 0 fallimenti.**
  Degrado noto nel frattempo: un claim adottato in forma vecchia risulta appena nato e perde i conflitti contro claim già noti — direzione prudente, ma non la regola scritta, quindi la PR resta necessaria.
- **`piano.md` §4.1 corretto** (`renewed` a 4 elementi, payload di `renew` con `GrantedAt`) e marcato "riepilogo, non fonte: fa fede `contracts/claim.md`", così due documenti non tornano a contraddirsi.
- **Framing di `who_do_you_hold` scritto in `claim.md` §3.4**: plain message a `vs_claim_client`, risposta plain a `From`, con la motivazione (un leader in ricostruzione non deve bloccarsi su una stazione che non risponde). Registra ciò che A ha già implementato, non lo cambia.

**Resta aperto e richiede davvero l'accordo:** `GrantedAt` restituito da `acquire`. Non si può fare unilateralmente — aggiungere un campo alla risposta romperebbe il match `{ok, ReqId, ClaimId, ExpiresAt}` della stazione. È il solo punto che aspetta la PR.

---

## 7d. Revisione del deploy — 24 agosto

Controllo di `Dockerfile.erlang` e, a cascata, del compose e dei contratti. Il tag `erlang:29.0.5-alpine` esiste e `{minimum_otp_vsn, "29"}` è coerente: lì niente da correggere.

**① Symlink di `_build` copiati nell'immagine finale.** `COPY --from=build /build/_build/default/lib` portava dentro i link che rebar3 crea per le applicazioni dell'umbrella: puntano a `/build/...`, che nello stage finale non esiste, quindi `-pa /app/lib/*/ebin` non avrebbe trovato nulla e il nodo sarebbe morto al boot con un "no such file or directory" sul `.app`. Risolto compilando in `/out` con `cp -rL`, che dereferenzia. Su Windows rebar3 crea directory reali con solo `src` linkato, quindi il difetto **non si vede sviluppando qui**: si manifesta solo nel container.

**② Nomi dei nodi incoerenti fra contratti e realtà.** I contratti dicevano `coord1@coord1, coord2@coord2, …`, il compose usa `NODE_SNAME: vs` per tutti e quindi `vs@coord1, vs@coord2, …`; il default Java era `coord1@localhost`. Allineati contratti e codice al compose, che è la realtà operativa, con la nota che il nome corto è uguale per tutti e a distinguerli è l'hostname.

**③ Il back office nel compose non si sarebbe collegato.** Al blocco (commentato) mancavano `JINTERFACE_NODE`, `JINTERFACE_MBOX` e `COORD_NODES`: il bridge sarebbe partito come `voltshare_bo@localhost`, irraggiungibile dai coordinatori. Aggiunte, insieme alle `DB_*` che il codice si aspetta, e `depends_on` con `condition: service_healthy`.

**④ Cookie di default diversi fra i due lati.** Java usava `voltshare-dev-cookie`, Erlang `voltshare`. In Docker la variabile è passata e il problema non si vede; fuori da Docker l'handshake fallisce senza un messaggio utile. Allineato il default Java.

**⑤ Nessun `.dockerignore`.** Il contesto è `src/`, 22 MB di cui 21 sono `backoffice/target/`, spediti al daemon a ogni build. Aggiunto, escludendo anche `_build/` e i `.beam` compilati sull'host — che altrimenti finirebbero nell'immagine a fare ombra alla compilazione fatta nello stage di build.

**Ancora da fare:** `Dockerfile.backoffice` non esiste, e il compose lo referenzia nel blocco commentato. Serve prima di poter alzare il back office in Docker.

---

## 7e. Contratto claim allineato — 24 agosto, sera

A ha risposto (`risposta-per-B-M1.md`) accettando la proposta e indicando l'unica azione a mio carico. Il suo codice era già su `main` e l'ho letto per ricavarne le forme esatte, invece di dedurle dal testo.

**Adeguato il coordinatore alle due forme concordate:**

```erlang
{claim, ...}  → {ok, ReqId, ClaimId, GrantedAt, ExpiresAt}          %% era senza GrantedAt
{renew, StationId, [{ClaimId, VehicleId, ConnId, UserId, GrantedAt}]}   %% era a 4 campi
```

Il matcher del renew accetta anche le forme a 3 e 4 campi: costano tre righe e tolgono di mezzo una classe intera di incidente d'integrazione, visto che un `function_clause` lì dentro non è un errore ma il coordinatore che muore ogni dieci secondi.

**Effetto collaterale positivo:** `UserId` nel rinnovo chiude il buco che avevo segnalato — un claim adottato da un leader nuovo ora sa di chi è, quindi le sospensioni valgono da subito invece che dalla `who_do_you_hold` di M3.

**`claim.md` aggiornato** (§3.1 e §3.2) con la motivazione dell'orologio unico. Resta da aprire la PR formale con A come reviewer: il contenuto è concordato, manca il passaggio su GitHub.

**Test:** due nuovi — `granted_at_comes_from_the_coordinator` (il timestamp restituito è quello registrato, e cade fra due letture dell'orologio locale) e `adopted_claim_carries_its_user`. Aggiornate le asserzioni dei test esistenti alla risposta a cinque elementi. **64 test, 0 fallimenti** insieme alla parte A.

**Convenzioni di `station_stats` recepite nella lobby.** A conta `closing` come *charging* e lascia i connettori offline fuori da tutti e tre i contatori: quindi `free + held + charging` può essere **minore del totale**. La lobby ora ha una colonna *Out of service* con la differenza, altrimenti un connettore guasto sparirebbe dalla pagina senza che nessuno se ne accorga.

**Toolchain verificata:** `OTP_VERSION` locale è esattamente `29.0.5`, come chiede A — allineata all'immagine Debian del deploy.

---

## 7f. Il ponte JInterface funziona — 25 agosto

Era il rischio numero uno del piano (§10: *"JInterface fragile — provato in M0 prima di ogni altra cosa"*) e l'unica cosa di M1-B mai messa alla prova. Ora è verificato end-to-end, senza Docker.

**Come:** un coordinatore vero avviato a mano su `vs@NINJA2218`, con due stazioni annunciate, e il back office che gli si aggancia come **nodo nascosto** `voltshare_bo_test@NINJA2218`.

```
[coordinatore]  back office bridge: publishing to backoffice on voltshare_bo_test@NINJA2218
                station 1 announced from vs@NINJA2218
[Java]          Erlang bridge starting: node=voltshare_bo_test@NINJA2218 mbox=backoffice
[test]          Tests run: 1, Failures: 0, Errors: 0, Skipped: 0
```

**Cosa dimostra**, oltre al fatto che i due si vedono: la `StationDirectory` si popola alla connessione senza aspettare il push periodico (quindi `get_stations` all'avvio funziona), e i campi arrivano nella posizione giusta — nome, totale connettori, potenza di sito, tariffa e `ws_url` sono verificati uno per uno. Il parser positivo di `stations_update` è la parte più facile da sbagliare in silenzio, e un `assertEquals` sul nome non l'avrebbe presa: due interi scambiati passano inosservati finché non li guardi.

**Il test resta:** `backoffice/src/test/java/.../ErlangBridgeIT.java`. Si lancia con

```bash
mvn test -Dtest=ErlangBridgeIT
```

Il suffisso `IT` fa sì che un `mvn test` normale non lo esegua, e senza un coordinatore attivo **si salta invece di fallire** (`assumeTrue` sul ping del nodo): un test rosso ogni volta che nessuno ha un nodo acceso insegnerebbe solo a ignorarlo. Le istruzioni per avviare il coordinatore sono nel javadoc del test.

**Resta da provare:** il deploy vero su Tomcat, e il ponte dentro Docker — dove cambiano hostname e risoluzione DNS, cioè proprio le variabili che qui erano tutte in locale.

---

## 7g. Primo deploy su Tomcat — 25 agosto

Docker Desktop era acceso ma **il daemon non rispondeva** (tre tentativi, nemmeno a `docker info`), quindi il compose resta da provare. Nel frattempo il war è stato messo su un Tomcat 10.1.34 scaricato in locale, con un coordinatore Erlang vero acceso accanto.

Era la prima volta che le JSP venivano **compilate**: Jasper le traduce alla prima richiesta, quindi fino a qui un errore in una pagina o nel tag file non sarebbe emerso da nessun `mvn package`.

| Prova | Esito |
|---|---|
| `GET /` | 302 → `/login.jsp` — `index.jsp` con `c:redirect` funziona |
| `GET /login.jsp` | 200, pagina completa: tag file `page.tag`, EL, CSS, form |
| `GET /stations` senza sessione | 302 → `/login.jsp?next=%2Fstations` — `AuthFilter` e il parametro di ritorno |
| `GET /WEB-INF/views/stations.jsp` | **404** — lo spostamento deciso in code review regge: le pagine interne non sono raggiungibili dall'esterno |
| `POST /login` con MySQL assente | 200 con *"Service temporarily unavailable, try again"* — l'errore SQL è gestito, non una pagina 500 |
| Bridge dentro Tomcat | avviato dal `AppListener`, connesso a `vs@NINJA2218`, zero errori di parsing e zero disconnessioni |

**Quello che ancora non è dimostrato:** la lobby con dati veri. Senza MySQL non si può fare login, quindi `stations.jsp` non è mai stata renderizzata con una lista di stazioni — la ricezione dei dati è provata dal test `ErlangBridgeIT`, ma il passaggio *directory → pagina* no.

Serve MySQL, e MySQL arriva dal compose: **è il prossimo passo, appena il daemon Docker risponde.**

---

## 7h. Il primo `docker compose build` e una regressione mia — 25 agosto

Primo build vero delle immagini. È fallito su `station1` e `station2`, e la causa era una correzione che avevo introdotto io il 24:

```
cp: cannot stat '_build/default/lib/vs_common/priv': No such file or directory
cp: cannot stat '_build/default/lib/vs_common/include': No such file or directory
ERROR: process "/bin/sh -c rebar3 compile && ... && cp -rL ..." exit code: 1
```

rebar3 lascia in ogni applicazione dei symlink `priv` e `include`; per le nostre puntano a directory che non esistono. Sono link rotti innocui — ma `-L` dereferenzia, su un link rotto `cp` fallisce, e con esso l'intero build.

**Dove avevo sbagliato il ragionamento.** Avevo scritto che su Linux rebar3 *linka l'intera applicazione* in `_build`, e che quindi il `COPY --from` originale avrebbe portato nell'immagine finale link verso un `/build` inesistente. In realtà `ebin` è una directory reale anche su Linux: il `COPY` originale funzionava, e il "fix" ha rotto ciò che andava. L'avevo dichiarato come "rischio probabile ma non verificabile senza Docker" — la verifica ora dice che l'ipotesi era falsa.

**Correzione:** copia esplicita di quello che il runtime usa davvero — `ebin` di ogni applicazione, più `priv` dove esiste — invece di clonare l'albero di `_build`. Non dipende più da come rebar3 dispone il proprio build tree, in nessuna delle due direzioni.

Da ricordare: le due macchine si comportano diversamente, quindi un Dockerfile "ragionato" e mai eseguito vale poco. Questo è il primo build reale delle immagini, ed è servito a scoprirlo.

---

## 7i. M1-B chiusa: lo stack gira, la lobby mostra dati veri — 25 agosto

Cinque container su, `coord1` con il **coordinatore vero** al posto del mock di A, e il percorso completo verificato dal browser:

```
POST /register  → 302 /stations          utente scritto su MySQL, sessione creata
GET  /stations  → 200                    Pisa Centro (4 liberi) · Livorno Port (3 liberi)
                                          con i nodi vs@station1 e vs@station2
```

È la catena intera: browser → Tomcat → MySQL per l'account → JSP → e i dati delle stazioni arrivati **da Erlang via JInterface**, non da una tabella. Era l'ultimo pezzo mancante di M1-B.

### Il difetto che solo Docker poteva far emergere

Al primo avvio il bridge restava in loop:

```
IOException: Nameserver not responding on backoffice when publishing voltshare_bo
```

Il "nameserver" è **EPMD**. JInterface non si limita a connettersi al cluster: *pubblica* il nome del proprio nodo sul port mapper del proprio host — e un container con il solo Tomcat non ne ha. In locale non poteva vedersi, perché su una macchina da sviluppo l'EPMD è già acceso, avviato dal primo nodo Erlang.

Correzione: `erlang-base` nell'immagine del back office (il pacchetto più piccolo che porti il binario) ed `epmd -daemon` prima di Tomcat nell'entrypoint. Da tenere a mente: **la versione OTP di quel pacchetto non deve corrispondere a quella del cluster** — EPMD è un registro nome→porta con protocollo stabile fra release, e da lì non viene eseguito codice Erlang. Senza questa nota sembrerebbe che stiamo mescolando OTP 25 e OTP 29.

### Stato dei container

| Servizio | Stato |
|---|---|
| `mysql` | healthy, schema e seed caricati |
| `coord1` | `coordinator vs@coord1 ready, serving`; entrambe le stazioni annunciate |
| `station1`, `station2` | su, annunciate al coordinatore |
| `backoffice` | Tomcat in 4,9 s, bridge connesso senza errori |

Restano accesi: `docker compose down` da `src/deploy` per fermarli.

---

## 7j. Perché `station.jsp` resta su "connecting…" — 25 agosto

Aperta la lobby e cliccato "Pisa Centro", la pagina mostra `connecting…` e non si muove. Non è una connessione fallita: è **testo statico** nell'HTML ([station.jsp:30](backoffice/src/main/webapp/WEB-INF/views/station.jsp#L30)), che il JavaScript avrebbe dovuto sostituire al primo messaggio. Quel JavaScript non esiste:

```
js/ws.js       → HTTP 404      la cartella js/ non esiste
js/station.js  → HTTP 404
```

Il browser carica due `<script src>` inesistenti, nessun codice gira, nessuna connessione viene nemmeno tentata.

**La stazione, invece, è pronta.** Interrogando il suo endpoint con HTTP:

```
http://localhost:9101/ws/driver → 426 Upgrade Required
```

426 è la risposta corretta di un endpoint WebSocket sollecitato in HTTP: cowboy è in ascolto e chiede l'upgrade. `vs_driver_ws`, `vs_driver_proto`, `vs_jwt`, `vs_connector`, `vs_station_mgr` sono tutti compilati e attivi. Quindi la metà server del canale driver funziona e nessuno la sta chiamando.

Manca **solo il client browser** — `js/ws.js`, `js/station.js` e la sostituzione dello scheletro: passo 4 di M1, in carico ad A (piano §5.4). Deciso di **non scriverlo noi**: violerebbe la regola di proprietà dei file e rischierebbe lavoro doppio o un conflitto sul merge. Si riprova quando A consegna.

Da verificare in quel momento, perché è il vero punto di contatto fra le due metà: il **JWT che B firma e A verifica su `join`**. Se segreto o claim non combaciano, il difetto si manifesterà nel codice di A pur non essendo suo. I tre token di prova in `contracts/sample-tokens.md` bastano a isolare la questione senza Tomcat.

### Proprietà delle pagine, per non riaprire la domanda

| Pagina | Chi |
|---|---|
| `index.jsp`, `login.jsp`, `register.jsp` | B |
| `stations.jsp` (lobby), `error.jsp`, `station-unavailable.jsp` | B |
| `css/app.css`, `WEB-INF/tags/page.tag` (layout comune) | B |
| `station.jsp`, `session.jsp`, `js/` | **A** |

`page.tag` è usato anche dalle pagine di A: l'applicazione resta visivamente una sola cosa senza che le due parti debbano accordarsi sul markup.

---

## 8. Punti aperti

- ~~Il ponte JInterface non è mai stato eseguito~~ **chiuso il 25/08** (§7f, §7i): verificato in locale, su Tomcat e in Docker.
- ~~`Db` non è mai stato provato contro un MySQL vero~~ **chiuso il 25/08**: registrazione e login scrivono e leggono dal MySQL del compose.
- ~~Il back office non è mai stato deployato su Tomcat~~ **chiuso il 25/08** (§7g, §7i).
- ~~Il matcher del `renew` a cinque campi~~ **chiuso il 24/08** (§7e): `renew_one` tollera le tre forme.
- ~~`user_id = 0` nei claim adottati~~ **chiuso il 24/08**: il rinnovo a cinque campi porta `UserId`.
- ~~**Client browser del canale driver (A)**: `js/ws.js`, `js/station.js`, `station.jsp` finita~~ **chiuso**: il codice il 27/08 (§7j è la diagnosi), e i **pixel** l'1/09 (§7zk). La demo dal browser funziona.
- ~~**JWT B→A mai verificato in transito**~~ **chiuso il 27/08** (④ nella tabella di §1): utente registrato da Tomcat, `TOKEN` letto dalla pagina renderizzata e usato per il `join`, accettato.
- La lista stazioni si aggiorna con `<meta http-equiv="refresh">` a 15 secondi: scelta deliberata, da dichiarare nella relazione.
- ~~Il coordinatore è sempre leader e non ha quorum~~ **chiuso il 25/08** (§7m): elezione bully, quorum di maggioranza e ricostruzione, failover provato in Docker.
- **PR su `claim.md` per `session_closed`** stazione → coordinatore: la modifica **non è stata fatta**, apposta, per poterla proporre prima del codice invece che dopo. È la PR che sostituisce quella "retroattiva" proposta da A — vedi sotto.
- **Le clausole legacy del `renew`** e l'inversione di copertura dei test (§7l): in attesa della risposta di A sulla variante col catch-all.
- ~~**Overstay: chi sottrae la tolleranza**~~ **deciso e implementato** (§7zf): la sottrae **la stazione**, che è l'unico posto dove la tolleranza è configurata, e in `sessions` finisce `overstay_seconds` **netto**. Il back office lo prezza e basta. Era il tipo di errore che sarebbe stato invisibile: due sottrazioni o zero.
- ~~La **potenza** (M2-A) non è ancora allocata: la fatturazione gira su righe inserite a mano~~ **chiuso** (§7q, §7s): l'auto carica, la stazione scrive la riga, il coordinatore sveglia Java, Java la prezza — misurato a **38 ms** dalla fine della sessione.

### Aperti oggi (3 settembre)

- ~~**P18 — GRAVE.**~~ **Chiuso su tutte e due le metà.** Quella di A è su `main` il 02/09
  (§7zl); quella di B è in questo ramo: `{rebuilt, []}` con la tabella vuota **non promuove più
  a `serving`**, il coordinatore resta in `rebuilding` e ne esce al primo renew. Era una
  decisione e non una correzione — costa disponibilità — e infatti è stata presa in due, con la
  richiesta e il suo prezzo scritti prima in `nota-per-B-p18.md` e accettati in
  `risposta-per-A-p18.md` §2. La scheda originale del difetto resta qui sotto perché la misura
  che lo definisce serve alla relazione.

  *Il difetto.* Un coordinatore che rientra da una partizione più lunga del `net_ticktime`
  ricostruisce l'indice chiedendo alle stazioni, ma la sua lista di conoscenti è vuota
  (`asked 0 station node(s)`): aspetta la finestra piena di rebuild (**2000 ms**) e comincia a
  servire **con la tabella vuota**. Misura originale in §7zj ③: 272 ms dopo, lo stesso veicolo —
  che sta caricando altrove — ottiene una **seconda prenotazione**, e l'invariante di
  `SCOPE.md` §4 resta rotta **13,65 s**, finché il primo renew ripresenta il claim più vecchio e
  «oldest wins» revoca il nuovo.

  *Perché è una taratura.* **Il difetto è il rapporto** fra i 2000 ms di attesa e i 10 000 ms di
  periodo di renew, non l'uno o l'altro numero: la difesa copre un quinto di ciclo.

  *Cosa ha fatto A (§7zl).* `net_kernel:monitor_nodes(true)` nel claim client; sul `nodeup` di un
  coordinatore conosciuto, riannuncio più un giro di renew immediato — che è già la
  ripresentazione di tutti i claim. Sulla stessa scena la finestra di esposizione passa da
  **4,11 s a 0 ms**, e il coordinatore rientrato comincia a servire dicendo
  `serving with 2 adopted claim(s)` invece di `0`. **Ma è una gara vinta con 265 ms di margine**:
  dal lato stazione la finestra si **accorcia**, non si chiude. Lo zero misurato è l'esito di una
  corsa, non una garanzia — se il coordinatore avesse cominciato a servire mezzo secondo prima,
  si sarebbe riaperta.

  *Cosa ha fatto B, e perché è quella che chiude.* **Non si passa a `serving` con zero risposte
  *e* zero claim**: si resta in `rebuilding` finché non arriva un renew. È l'unica delle due metà
  che chiude davvero la finestra invece di accorciarla, perché non dipende da chi arriva primo. I
  client trattano già `rebuilding` come `RETRY_LATER` — misurato, §7zj ⑤ (undici di fila, nessun
  giro), quindi il costo è attesa, non errore. La richiesta col suo prezzo era in
  **`nota-per-B-p18.md`**, la decisione in **`risposta-per-A-p18.md`** §2.
- **P16 — BASSO, misurato il 29/08.** `vs_claim_client` parte con `leader = hd(COORD_NODES)` e
  non lo corregge finché non ha un motivo (concessione, renew riuscito, `who_do_you_hold`):
  la prima prenotazione dopo un boot paga sempre un **redirect §4.2 in più**. Nessuna azione
  proposta — è il comportamento che `claim.md` §4 descrive, ed è coperto da
  `vs_claim_peer_tests`. Registrato qui perché non venga riscoperto come difetto.
- **Limite dichiarato, non difetto**: non c'è alcun tetto sullo stato `complete`. Un'auto ferma
  col cavo dentro occupa davvero la presa, e liberarla d'ufficio dopo un timeout sarebbe peggio.
  La conseguenza da saper dire: una colonnina che non manda mai `unplugged` lascia la sessione in
  RAM e non fatturata.

---

## 7k. M2-B: fatturazione e storico — 25 agosto

Fatto e verificato contro il MySQL del compose. Codice nuovo:

| File | Ruolo |
|---|---|
| `model/SessionView.java` | bean (non record: EL cerca i getter) con i derivati per la pagina |
| `dao/SessionDao.java` | storico per utente, sessioni non prezzate, la UPDATE di `cost_cents` |
| `service/BillingService.java` | il calcolo e lo sweep |
| `web/HistoryServlet.java` + `views/history.jsp` | la pagina, già presente nel menu e finora vuota |
| `vs_coord_srv:session_closed/1`, `vs_coord_bo:session_closed/1` | inoltro dell'evento verso Java |
| `test/service/BillingServiceTest.java` | 9 test sul calcolo puro |

### La decisione che conta: l'evento è una sveglia, non un dato

La strada ovvia era fatturare dentro il gestore di `session_closed`, con i numeri che l'evento
porta. Scartata per tre motivi, tutti conseguenza del fatto che è un semplice messaggio Erlang:

1. **La consegna è best-effort.** `{Mbox, Node} ! Msg` verso una mailbox assente viene scartato
   in silenzio — di proposito, perché Tomcat giù non deve disturbare il cluster. Una sessione
   chiusa durante un riavvio del back office non verrebbe prezzata **mai**.
2. **L'evento può superare la riga.** La stazione fa l'INSERT e avvisa il coordinatore, e
   niente ordina le due cose: fatturare per id può cercare una riga non ancora committata.
3. **Il dato è già nel database.** L'evento porta ciò che porta la riga.

Quindi il costo si calcola con uno **sweep** di `cost_cents IS NULL` ogni 60 secondi — lo schema
lo indicizza già come `idx_unbilled` — e l'evento si limita a farlo partire prima. Perdere tutti
gli eventi ritarda una ricevuta di un intervallo e non perde nulla.

Con la UPDATE condizionata (`WHERE cost_cents IS NULL`) un evento duplicato non può far pagare
due volte: **consegna at-least-once sopra una scrittura idempotente**, che è il modo standard di
ottenere un comportamento effectively-once senza un canale exactly-once — che i sistemi
distribuiti non offrono. Vale la pena dirlo all'orale: è lo stesso ragionamento del claim, cioè
non fidarsi della consegna ma rendere innocua la ripetizione.

Un thread solo per lo sweep (`newSingleThreadScheduledExecutor`), quindi timer ed eventi
finiscono nella stessa coda e due sweep non possono sovrapporsi: nessun lock da scrivere.

### Il calcolo

```
costo = energia × tariffa_stazione + minuti_overstay × OVERSTAY_CENTS_MIN
```

- `BigDecimal`, non `double`: `energy_kwh` è `DECIMAL(10,3)` e il risultato è denaro. 41,2 × 45
  in virgola mobile binaria fa 1854,0000000000002.
- Overstay **arrotondato per eccesso al minuto**: un secondo oltre la soglia costa un minuto
  intero, altrimenti il primo minuto sarebbe gratis — l'opposto di un deterrente.
- La tariffa si legge da `stations`, non dall'evento: è il prezzo al momento del regolamento, e
  cambiarla non richiede di avvisare le stazioni.
- Default `OVERSTAY_CENTS_MIN=50`, `BILLING_SWEEP_SECONDS=60`, entrambi nel compose.

### Verifica eseguita

Tre sessioni inserite a mano in MySQL (quello che farà la stazione in M2-A), `cost_cents` NULL:

| kWh | stazione | overstay | atteso | ottenuto |
|---|---|---|---|---|
| 41,200 | Pisa (45 c) | 0 | 1854 | **1854** |
| 20,000 | Pisa (45 c) | 240 s | 900 + 200 = 1100 | **1100** |
| 33,500 | Livorno (42 c) | 0 | 1407 | **1407** |

`/history` risponde 200 e mostra le tre righe con totale **€ 43,61**, durate, overstay `4 min`
sulla riga giusta, nomi delle stazioni.

Poi le due prove che contano davvero:

- **Idempotenza**: messo a mano `cost_cents=9999` su una riga già fatturata → lo sweep **non
  l'ha riscritta**. La UPDATE condizionata regge.
- **Sweep senza evento**: inserita una quarta riga NULL e nessun evento inviato → prezzata dal
  timer periodico a 604 = 12 × 42 + 2 minuti di overstay. È la prova che il back office non
  dipende dalla consegna del messaggio.

Le quattro righe di prova sono ancora in MySQL, intestate all'utente `m2test`. Si tolgono con
`DELETE FROM sessions;` quando arriveranno quelle vere.

### Cosa serve da A

Scritto in `contracts/nota-per-A-M2.md`, nessuna delle due cose blocca B:

1. **Il significato di `overstay_seconds`.** Proposta: secondi **già fatturabili**, con i cinque
   minuti di tolleranza sottratti dalla stazione — perché `OVERSTAY_GRACE_SECONDS` è configurato
   lì e in nessun altro posto. È l'unico punto dove possiamo interpretare lo stesso numero in
   due modi, e l'errore sarebbe invisibile: un conto sbagliato di cinque minuti non lo nota
   nessuno. Oggi `vs_connector` scrive `0` con il commento "overstay arrives in M4".
2. **La chiamata a `vs_coord_srv:session_closed/1`** dopo l'INSERT.

`claim.md` **non è stato toccato**: il messaggio stazione → coordinatore sta nel suo territorio e
va nella PR con A come reviewer, insieme alle due modifiche già concordate. Dopo l'episodio del
24/08 — modifica unilaterale del contratto, coordinatore in `function_clause` a ogni rinnovo —
la regola vale anche quando la modifica sembra innocua.

---

## 7l. Nota di A sull'integrazione — 25 agosto

A ha inviato `nota-per-B-integrazione.md`, scritta il 24 sera: verifica riga per riga dei punti
di contatto fra le due metà, con esito **contratto allineato su tutti e sei i messaggi**.
Risposta in `contracts/risposta-per-A-integrazione.md`.

Gran parte del §3 (fare lo swap del mock, provare il ponte, deployare su Tomcat) è stata
superata dai fatti il 25: è tutto fatto e verificato.

### Cosa aveva ragione di segnalare

**① PR mancante sui file congelati.** Accettato senza discussione: la regola l'ha scritta B e
l'ha violata B, e quella modifica unilaterale è *precisamente* ciò che ha prodotto il crash del
24. Che il contenuto fosse concordato non salva il metodo — il metodo serve proprio quando uno
dei due è convinto che la modifica sia ovvia. Si apre PR retroattiva, con dentro anche il
`session_closed` di M2.

**② Conteggio dei test sbagliato.** Aveva ragione, e aveva pure previsto il totale. Misurato:

```
rebar3 eunit → 112 tests, 0 failures     (vs_common 9 + vs_station 87 + vs_coord 16)
```

Il "22" per `vs_coord` contava le `?assert*` invece dei casi; il "45" era un residuo di una
misura precedente al merge. `PROGRESS` ora riporta un solo numero, misurato. Regola da tenere:
**un numero che nessuno ha eseguito non è un dato.** All'orale si cita solo ciò che è stato
misurato.

**③a `-spec renew/2` disallineato.** Dichiarava la 4-tupla mentre l'implementazione ne accetta
tre forme. Corretto: ora dichiara la 5-tupla, cioè il contratto, con una nota che la tolleranza
per le forme vecchie è leniency dell'implementazione e non parte dell'interfaccia.

### Dove l'analisi ha aggiunto qualcosa

A proponeva di togliere le clausole legacy a 3 e 4 campi, ormai irraggiungibili in produzione.
Vero — ma controllando prima di toccarle è emerso che **sono i test di B a percorrerle**:

| Test | Forma |
|---|---|
| `own_claim_is_renewed` | 4 campi |
| `unknown_claim_is_adopted` | 4 campi |
| `renew_without_granted_at_is_accepted` | 3 campi |
| `oldest_claim_wins_a_conflict` | 4 campi |
| variante di `unknown_claim_is_adopted` | **5 campi** |

Cinque test coprono forme che nessuno invia, **uno solo** copre quella che viaggia davvero. È
un'inversione della copertura, e conta più del ramo morto in sé: il percorso di produzione del
`renew` — un messaggio che arriva ogni dieci secondi e tocca tutti i claim — è quasi scoperto.

Proposta rilanciata ad A: togliere le clausole ma **sostituirle con un catch-all che scarta la
voce malformata e la registra**, invece di lasciare che produca `function_clause`. La lezione del
24 non era "supportare le 3-tuple", era che *un messaggio inatteso ha ucciso il processo che
teneva tutti i claim*. Togliere le clausole lasciando cadere il processo riapre quella porta nel
momento peggiore, cioè quando qualcuno cambia una tupla senza accorgersene. Con il catch-all si
ottiene ciò che A vuole — niente rami morti da spiegare — e in più una scelta di progetto
raccontabile: **un rinnovo malformato perde un claim, non il coordinatore.**

In attesa della risposta di A: la modifica tocca `vs_coord` (di B) ma nasce da una sua proposta,
e riscrivere i cinque test è parte del lavoro.

---

## 7m. M3-B: elezione, quorum, ricostruzione — 25 agosto

Il coordinatore smette di essere singolo. Tre moduli nuovi, più le transizioni di stato in
`vs_coord_srv`, e **coord2/coord3 accesi nel compose**.

| Modulo | Domanda a cui risponde |
|---|---|
| `vs_coord_membership` | *chi è vivo* — heartbeat, `nodedown`, aritmetica della maggioranza |
| `vs_coord_election` | *chi decide* — bully |
| `vs_coord_rebuild` | *cosa era già stato concesso* — `who_do_you_hold` alle stazioni |

La separazione fra i primi due è voluta: le due risposte cambiano per ragioni diverse — un nodo
che muore cambia la liveness, un'elezione vinta cambia l'autorità — e confonderle è **esattamente
il modo in cui un coordinatore finisce per servire mentre è isolato**.

### Tre decisioni di progetto

**Heartbeat *e* `monitor_nodes`, non uno dei due.** `nodedown` scatta all'istante quando una
connessione TCP cade — il caso `docker kill`, cioè la demo. Ma un nodo che smette di rispondere
senza chiudere il socket (partizione, VM congelata) viene notato solo dal tick della
distribuzione, il cui `net_ticktime` di default è **60 secondi**. Sessanta secondi di un leader
in minoranza che continua a concedere claim sono precisamente ciò che il quorum deve impedire.
Con l'heartbeat esplicito (1 s, 3 battiti mancati) il verdetto arriva in tre secondi.

**Niente `COORD_ID`.** La priorità del bully è la posizione nella lista ordinata `COORD_NODES`,
che tutti e tre già condividono: ogni nodo calcola lo stesso ordine senza che glielo si dica. Un
id per nodo sarebbe una cosa in più da configurare e una in più da sbagliare — due nodi con lo
stesso id si rifiuterebbero entrambi di cedere, e un'elezione che non converge non somiglia per
niente alla sua causa.

**Essere eletti non è essere pronti.** Il vincitore passa per `rebuilding` e solo dopo serve.
Concedere prima di sapere quali veicoli sono già impegnati romperebbe P2 proprio mentre il
sistema si sta riprendendo da un guasto.

### Perché basta chiedere, senza replicare un log

È la decisione su cui poggia tutta la storia del failover: **il coordinatore è un indice, non il
proprietario dello stato che indicizza.** La copia autorevole di "il connettore 3 è impegnato per
il veicolo 88 fino alle 15:42" sta sulla stazione, che è anche l'unica che può agirvi. Una vista
derivata si può ricostruire dalle sue sorgenti — quindi niente log replicato, niente consenso su
una macchina a stati, niente persistenza: il nuovo leader chiede e le stazioni rispondono a
memoria.

Due percorsi convergono: la query esplicita è la via rapida, ma i rinnovi che arrivano ogni dieci
secondi portano `ClaimId`, `GrantedAt` e `UserId`, e un claim sconosciuto in un rinnovo viene
**adottato** anziché rifiutato. Il sistema convergerebbe da solo entro un intervallo di rinnovo;
la query fa sì che il recupero duri un secondo invece di dieci.

### Difetti trovati mentre lo costruivo

**Un test ha trovato un caso reale.** Con zero stazioni da interrogare la ricostruzione finiva
all'istante. Ci ho ragionato: *aver chiesto a nessuno non è come aver sentito tutti*. Un leader
eletto mentre le stazioni sono momentaneamente disconnesse concluderebbe in un microsecondo che
la rete non ha claim, e comincerebbe a concedere veicoli già in carica. Zero risposte è il caso
in cui si sa meno: ora è l'unico che aspetta l'intera finestra.

**M3 rompeva il ponte verso Java, in due modi.** Ogni coordinatore esegue `vs_coord_bo`, ma la
tabella stazioni di un follower è vuota — le stazioni si annunciano solo al leader. Con il
repubblish periodico ogni tick avrebbe sovrascritto la directory del back office con una lista
vuota, e **la lobby avrebbe lampeggiato** fra le stazioni vere e "no station is reporting". Stesso
problema per l'annuncio del leader: tre coordinatori che si annunciano all'avvio lasciavano il
back office puntato sull'ultimo che aveva parlato, spesso un follower. Ora parla **solo il
coordinatore che serve**.

**`station_up` è un cast, e un cast non si può redirigere.** A differenza di claim e renew,
un'annuncio non ha canale di risposta: la stazione continuava a mandarlo a coord1 anche quando il
leader era coord3, e il leader non sapeva che quelle stazioni esistessero. Ora un follower
registra l'annuncio (utile a sé stesso se verrà eletto: saprà a chi chiedere) e lo **inoltra** al
leader, incapsulato in `forwarded` così il secondo salto non rilancia mai.

**Una trappola del deploy.** Tre servizi che compilano lo stesso Dockerfile producono **tre
immagini distinte**: `docker compose build coord1` lasciava gli altri due al codice di ieri. Il
sintomo era ostico — il cluster si alza, elegge un leader, e poi un coordinatore risponde
`unexpected cast` a un messaggio che per gli altri è ordinario. Risolto dando alle tre un unico
`image: voltshare-coord:local`, così divergere è impossibile.

### La prova, eseguita

Scenario 5 della demo, fatto davvero:

```
coord3 leader                          → docker kill coord3
coord1: "vs@coord3 went down"            (nodedown, istantaneo)
coord2: eletto → rebuild: 2 stazioni interrogate, 2 risposte → serving
prenotazione vera creata sulla stazione: veicolo 88, claim c-9569F06C…
                                       → docker kill coord2
coord1: "QUORUM LOST (1 of 3) — this coordinator will refuse to serve"
        mode=suspended, claim rifiutato con {not_serving, undefined}
                                       → coord2 riacceso
coord2: eletto → rebuild: 2 stazioni, 1 claim → serving with 1 adopted claim
                                       → coord3 riacceso
coord3: riprende la corona (rango più alto), riadotta il claim
        coord2 torna standby e svuota la tabella
```

Il dettaglio che conta: dopo tre cambi di leader il claim ha **lo stesso `claim_id` e lo stesso
`granted_at`** dell'originale. Solo `expires_at` è avanzato, perché i rinnovi l'hanno esteso —
che è il comportamento giusto. La stazione non ha fatto nulla di speciale, e la lobby ha
continuato a rispondere 200 con entrambe le stazioni per tutto il tempo.

**La minoranza che si sospende è il risultato più importante.** Non è un guasto gestito: è il
sistema che rifiuta di funzionare quando non può garantire P2. Da mostrare al docente esattamente
così, perché la tentazione naturale — l'ultimo sopravvissuto prende il comando — è proprio ciò
che produrrebbe due leader dopo una partizione.

Costo da dichiarare nella relazione: durante una partizione la minoranza rifiuta **le nuove
prenotazioni**. Le ricariche in corso non sono toccate, perché il coordinatore non sta nel
percorso dell'erogazione.

### Test

**132 test, 0 fallimenti** (erano 112). I venti nuovi coprono i due lati:

- `vs_coord_failover_tests` (11) — standby redirige claim *e rinnovi*, il follower dimentica la
  tabella, la minoranza non nomina un leader, `rebuilding` rifiuta ma **adotta ancora i rinnovi**,
  la ricostruzione conserva i timestamp originali, il conflitto si risolve col più vecchio, una
  risposta tardiva non resuscita un sospeso, una voce malformata non blocca tutto.
- `vs_coord_membership_tests` (9) — un nodo solo è sempre in maggioranza, 1 di 3 no, l'avvio è
  ottimista di proposito (altrimenti a un riavvio simultaneo tutti e tre si eleggono), e
  **un estraneo non fa quorum**.

---

## 7zc. La review di A sulla PR #5, applicata per intero — 31 agosto

Arrivata con il pull di oggi (`nota-per-B-review-pr5.md`, riverificata da A sul `main` che
contiene il nostro merge). Tutti i rilievi controllati uno per uno prima di toccare qualcosa:
**erano tutti veri**. Risposta in `risposta-per-A-review-pr5.md`.

### R2 — il difetto grave: `notify` non veniva inoltrato

`ErlangBridge` smistava sul tag `notify` **da M4-B**, ma in `vs_coord_srv` non esisteva nessuna
clausola per inoltrarlo. Un `{notify, …}` da una stazione sarebbe caduto nel `handle_cast`
catch-all: scartato con un log, e la notifica mai arrivata in tabella.

È la terza volta che questo progetto sbaglia allo stesso modo — **una forma implementata su un
solo verso del ponte** — e questa volta l'ho fatto io in modo particolarmente istruttivo:
nello stesso commit di M4-B ho scritto il gestore Java *e* l'inoltro di `no_show`/`show_up`, e
ho saltato quello di `notify`. Il codice ricevente esisteva, quindi niente sembrava incompleto.

Avrebbe bloccato M4-A per intero: il frame `notification` di `ws-driver.md` esiste per portare
al browser il `session_interrupted` che il connettore emette già.

### R4 — il gate su `penalty_event` perdeva strike veri

Avevo messo un gate `serving` sull'inoltro dei `no_show` per impedire il doppio conteggio. A ha
fatto notare che quel doppio conteggio **è impossibile per costruzione**: una stazione manda la
cast a un nodo solo, quindi non esiste una seconda copia da cui difendersi. L'unico effetto del
gate era perdere strike nella finestra in cui una stazione crede ancora al vecchio leader — e un
no-show non lascia righe da nessuna parte, quindi il messaggio è l'unico documento che sia
successo.

Ora un follower **inoltra al leader** con lo stesso involucro `{forwarded, …}` già usato per gli
annunci. Se non c'è un leader a cui passarlo, viene registrato: un rilievo perso deve almeno
essere visibile.

### Le altre

| | |
|---|---|
| **R1 residuo** | un `user_suspended` che arriva a un follower era assorbito in silenzio: ora c'è un `warning`, perché significa che il back office sta indirizzando un nodo che non serve |
| **R3** | l'INSERT della notifica in `suspend()` ora ha il suo `try`: se fallisce, il coordinatore viene informato lo stesso. Una sospensione scritta in `users` che nessun coordinatore conosce è una penalità che non si applica |
| **R5** | `suspended_until > NOW()` confrontava l'orologio della JVM (in scrittura) con quello di MySQL (in lettura). Ora il limite è calcolato in Java e passato come parametro |
| minore | `NotificationDao.add` troncava `text` ma non `kind`: proprio il caso «kind inventato da una stazione» che il metodo dichiara di assorbire |
| minore | `onNoShow` su utente inesistente proseguiva fino alla violazione di foreign key, con un log che puntava alla cosa sbagliata |
| minore | `get_suspensions` era promesso dal contratto e implementato lato Erlang, ma Java non l'ha mai chiamato: ramo morto, rimosso e sostituito da `vs_coord_srv:suspensions/0`. Il contratto ora descrive il recupero **a spinta**, che è quello che gira |

### Verificato in Docker

Il test che A suggeriva, fatto: un `notify` mandato **al leader** e uno mandato **a un follower**
arrivano entrambi in tabella.

```
id | kind             | text
 3 | waitlist_offer   | inviata a un FOLLOWER
 4 | charge_complete  | inviata al LEADER
```

Prima del fix nessuna delle due sarebbe arrivata.

### `eunit_check.sh`: il conteggio dei test è un'asserzione, non una speranza

A ha versionato uno script che nasce da una misura importante — **tre modi diversi di rompere la
suite stampano tutti «0 failures»**, perché il totale non è una costante ma quanto lontano eunit
è arrivato a *enumerare* l'albero dei test.

Non è teoria: al primo giro di oggi la nostra suite ha stampato `234 tests, 1 failures, 6
cancelled`. Sessantaquattro test spariti. Senza quello script avrei potuto leggere «0 failures»
su una suite dimezzata e considerarla verde — e in effetti **è esattamente quello che è successo
il 28 agosto**, quando avevo riportato un giro a 274 senza sapere cosa significasse.

Aggiornato `EXPECTED_TESTS` a **336** (333 di A più i 3 nuovi qui): aggiornare quel numero fa
parte dell'aggiungere test, come dice lo script stesso.

### Una cosa che resta ad A

Due test in `vs_connector_tests` falliscono a intermittenza sotto carico —
`closing_does_not_wait_for_the_database_test` (asserisce `Micros < 300000`) e
`a_charge_point_gone_past_the_grace_closes_the_session_test` (`no_event`). Su tre giri: 2
fallimenti, 1, 0, con il totale sempre a 336. È la stessa famiglia che A dice di aver ripulito,
quindi qualcuno è sfuggito.

---

## 7za. Le sospensioni non sopravvivevano a un riavvio — 28 agosto

Nella sua nota A accennava a *"una review della PR #5: la più importante riguarda le sospensioni
dopo un riavvio"*. Quella review non è mai arrivata — su GitHub c'è solo quella automatica di
Copilot, su un altro punto. Ma **l'indizio era giusto**, e cercandolo sono usciti due buchi veri.

### Il buco

`pushAllSuspensions()` veniva chiamato solo quando il **nome** del leader cambiava:

```java
boolean changed = !a.atomValue().equals(leaderNode);
if (changed) { PenaltyService.getInstance().pushAllSuspensions(); }
```

Due modi per non farlo scattare:

1. **un coordinatore che si riavvia e rivince** torna con la mappa delle sospensioni **vuota**,
   annuncia lo stesso nome di prima, e per il back office "non è cambiato niente". Serve a tempo
   indeterminato lasciando prenotare utenti sospesi;
2. **il back office che si riavvia** parte con `leaderNode` = primo elemento di `COORD_NODES`. Se
   il leader è proprio quello, il primo annuncio non è un cambiamento. E peggio: `{leader, _}`
   veniva inviato **una volta sola**, alla vittoria dell'elezione — quindi un back office
   partito dopo non ne sentiva nessuno, e su un cluster sano l'elezione successiva non arriva mai.

Il secondo è il caso più realistico ed è esattamente quello che A chiamava "dopo un riavvio".

### Correzione, su entrambi i lati

- **Java**: si spinge a **ogni** annuncio, non solo quando il nome cambia. L'annuncio non
  significa "è cambiato il leader", significa *"ho appena cominciato a servire e la mia tabella è
  quel che sono riuscito a ricostruire"* — cioè precisamente il momento in cui le sospensioni
  vanno ripetute. È idempotente e costa una manciata di messaggi.
- **Erlang**: il republish periodico manda anche `{leader, node()}`. Un back office partito tardi
  converge da solo entro 30 secondi, invece di aspettare un'elezione che non verrà.

### Verifica

```
docker compose restart backoffice          # nessuna elezione nei coordinatori
backoffice | Coordinator leader is now vs@coord3
backoffice | Re-sent 1 suspension(s) to the new leader

utente sospeso, dopo il restart : {error, <<"r-c">>, suspended}
```

Il back office ha ripreso da solo, senza che nessuno rieleggesse nulla. Prima sarebbe rimasto in
silenzio.

### Perché è il tipo di difetto che sfugge

La condizione `changed` sembrava un'ottimizzazione ovvia — evitare un push inutile. Ma stava
confondendo **due domande diverse**: "chi è il leader?" e "il leader sa quel che deve sapere?".
Un processo riavviato ha lo stesso nome e una memoria vuota, e il nome è ciò che stavamo
guardando. Vale la pena raccontarlo all'orale insieme al rebuild: sono lo stesso problema —
uno stato che il cluster non possiede — risolto una volta chiedendo e una volta ripetendo.

---

## 7z. M4-B: penalità, notifiche, profilo — 28 agosto

Fatta e verificata end-to-end contro il cluster vero.

| File | Ruolo |
|---|---|
| `service/PenaltyService.java` | N=2 no-show consecutivi → K=1 giorno di sospensione |
| `dao/NotificationDao.java`, `model/Notification.java` | la tabella `notifications`, di sola B |
| `UserDao` (+5 metodi) | contatore e sospensione, con la riga bloccata |
| `web/NotificationsServlet`, `web/ProfileServlet` + le due JSP | le pagine, e la voce nel menu |
| `vs_coord_srv`, `vs_coord_bo` | inoltro di `no_show` / `show_up` / `notify` verso Java |

### La prova

```
1º no_show  → no_show_count = 1, notifica "reservation_expired"
2º no_show  → suspended_until = domani, contatore azzerato,
              notifica "suspended"

prenotazione per l'utente sospeso  : {error, <<"r-susp">>, suspended}
prenotazione per un utente normale : {ok, <<"r-ok">>, <<"c-5615...">>, ...}
```

La seconda riga è quella che conta: la sospensione è **mirata**, non un rifiuto generalizzato. E
la pagina profilo dice al conducente fino a quando, e che **può comunque caricare a un connettore
libero** — perché è la prenotazione a essergli tolta, non la ricarica.

### L'interazione con M3, progettata apposta

I claim sopravvivono a un failover perché il nuovo leader può **chiederli alle stazioni**, che li
possiedono. Le sospensioni no: nessuno nel cluster le ha, vivono solo in MySQL. Un nuovo leader
partirebbe quindi senza saperne nulla, e l'utente sospeso potrebbe riprenotare dopo ogni elezione.

Risolto con un **push**, non con una domanda: il ponte, quando scopre un leader nuovo, gli rimanda
tutte le sospensioni attive. Provato uccidendo il leader:

```
backoffice | Coordinator leader is now vs@coord2
backoffice | Re-sent 1 suspension(s) to the new leader

utente sospeso sul NUOVO leader: {error, <<"r-fo">>, suspended}
```

È lo stesso problema del rebuild ma con la sorgente **dall'altra parte del confine**, e per questo
si risolve nella direzione opposta. Vale la pena raccontarlo così all'orale: la regola non è "il
nuovo leader chiede", è "chi possiede lo stato lo ripropone", e le stazioni e il back office lo
possiedono in due modi diversi.

### Due scelte da difendere

**Il contatore è scritto solo dal back office.** La stazione osserva e segnala; non conta e non
sospende. "Due *consecutivi*" richiede storia, e la storia in una stazione si perde al riavvio —
mentre il senso della regola è che si accumuli.

**L'inoltro di `no_show` è gated su `serving`**, a differenza di `session_closed`. Due
coordinatori che relayano lo stesso evento lo farebbero contare due volte, e il contatore non ha
modo di distinguere i duplicati — mentre una sessione fatturata due volte è impossibile per via
della UPDATE condizionata. Stessa forma, garanzie diverse, quindi trattamento diverso.

E una concorrenza che **non** abbiamo introdotto: la sospensione è decisa in un posto solo e il
coordinatore ne è la cache, così non diventa un secondo oggetto conteso accanto al connettore
(`DESIGN-NOTES` §4b). L'unica corsa possibile è due `no_show` per lo stesso utente nello stesso
istante, ed è gestita dove va gestita — `recordNoShow` incrementa e rilegge con la riga bloccata.

---

## 7y. La partizione si fa su un host solo — A aveva ragione, 27 agosto

Provato il suggerimento di `nota-per-B-pendenze.md` §3, ed è **il risultato migliore della
milestone M3**:

```
docker network disconnect voltshare_voltshare coord3     # non lo uccide: lo isola

coord3 (vivo, isolato)     "QUORUM LOST (1 of 3) — this coordinator will refuse to serve"
                           "election: out of quorum, abdicating"
coord1 + coord2 (2 su 3)   coord2 eletto → rebuild: 2 stazioni interrogate → serving

docker network connect voltshare_voltshare coord3
coord3                     "quorum back, electing" → riprende la corona (rango più alto)
                           → rebuild → serving
```

Interrogato dall'interno del container isolato:

```
coord3 è vivo         : true
mode                  : suspended
in_quorum             : false
prenotazione tentata  : {not_serving, undefined}
```

**Il nodo è in esecuzione, si crede vivo, e si è tolto dal servizio da solo.** È esattamente lo
scenario per cui esiste il quorum e che `docker kill` non può mostrare: quello è un *crash*, cioè
un nodo che sparisce. Il caso difficile è un nodo che resta acceso e non vede più gli altri, e che
deve avere il buon senso di smettere di concedere.

Quindi cade anche l'ultimo motivo per il deploy multi-host (§7n): non serviva un'altra macchina per
produrre una partizione vera, bastava staccare l'interfaccia. **Da mettere nella demo al posto di
`docker kill`** — o meglio, accanto, perché sono due guasti diversi e il sistema li tratta in modo
diverso.

Un dettaglio onesto: alla riconnessione coord3 ha ricostruito con *"asked 0 station node(s)"*,
perché le connessioni Erlang verso le stazioni non si erano ancora ristabilite. Ha atteso l'intera
finestra — è il caso che avevamo corretto apposta il 25 (§7m) — e poi ha servito con tabella vuota;
i claim sarebbero rientrati dai rinnovi entro dieci secondi. Non c'erano prenotazioni in corso, ma
la finestra esiste e va detta.

---

## 7x. M1 di A è chiusa, e undici nostri test non venivano eseguiti — 27 agosto

`nota-per-B-pendenze.md`. **Il client browser è arrivato**: `station.jsp`, `js/ws.js`,
`js/station.js` su `main`, e con essi il JWT ha attraversato per la prima volta il confine fra le
due metà — firmato da `JwtUtil`, letto dalla pagina renderizzata, verificato da `vs_jwt`.

### ① Undici test di M3 saltati in silenzio

Verificato, ed è esattamente come dice A:

```
rebar3 eunit --app=vs_coord   →  25 test
rebar3 eunit                  → 133 test  (di cui 36 di vs_coord)
```

rebar3 accoppia un modulo di test a un sorgente con lo stesso stem. `vs_coord_failover.erl` **non
esiste** — il modulo si chiama `vs_coord_election` — quindi `vs_coord_failover_tests` veniva
**scartato senza un avviso**. Erano gli undici test di elezione, quorum e ricostruzione: la parte
che vale l'esame.

Il difetto era già visibile il 25: avevo notato *"solo 16, il nuovo modulo non è stato raccolto"*,
avevo aggirato l'ostacolo con `--module=` e **non avevo cercato la causa**. Il numero in `PROGRESS`
era giusto perché misurato con `rebar3 eunit` senza flag, quindi nulla segnalava il problema. È il
motivo per cui vale la pena trattare una stranezza come un difetto invece che come un attrito.

Correzione — rinominati i moduli perché si aggancino a un sorgente vero:

- i 5 test di adozione → `vs_coord_rebuild_tests` (accoppiato a `vs_coord_rebuild.erl`);
- i 6 test sui modi (standby, suspended, rebuilding) → dentro `vs_coord_srv_tests`, che è il server
  a cui appartengono;
- `vs_coord_failover_tests.erl` eliminato.

Ora `--app=vs_coord` ne conta **36** invece di 25, e la suite intera resta 133.

### ② A ritira la segnalazione sul `monitor_nodes`, e ha ragione a ritirarla

Aveva scritto che `{nodedown, Node}` non arrivava mai perché nessuno si iscriveva. Falso: il suo
grep cercava `monitor_nodes` al plurale, mentre `vs_coord_srv` usa `erlang:monitor_node/2`, che è
l'API per **un nodo specifico** — la scelta giusta, perché sorveglia le stazioni annunciate invece
di farsi svegliare da ogni nodo del cluster. `claim.md` riga 154 lo diceva già a parole.

Ha rifatto la prova sui container: `docker compose stop station1` → due secondi dopo, claim a zero
e stazioni a uno. Nessuna correzione da fare da parte nostra.

Vale la pena notare la simmetria: in due giorni A ha trovato due difetti veri nel nostro codice e
una volta si è corretto da solo. Il valore delle PR incrociate sta anche in questo — non solo nel
trovare, ma nel poter smentire un sospetto guardando il codice invece di ricordarselo.

### ③ La partizione si può fare su un host solo

Nell'annotare il ridimensionamento del multi-host avevamo scritto che l'unico motivo residuo per
volerlo era la **partizione vera**, impossibile su una macchina. A fa notare che l'argomento non
regge:

```bash
docker network disconnect voltshare coord3   # resta vivo, ma isolato
docker network connect    voltshare coord3
```

`docker kill` è un **crash**; il quorum esiste per l'altro scenario, un nodo che *resta vivo* e non
vede più gli altri. Disconnettere l'interfaccia lo riproduce esattamente, su un host solo. Se
funziona, al multi-host non resta nemmeno quel motivo — **e la demo guadagna lo scenario più
difficile da mostrare.** Da provare al prossimo avvio di Docker.

### ④ e ⑤

C'è un utente `cc-probe` nel MySQL condiviso, creato da A per firmare un token vero: comparirà
nella lobby e nello storico, si cancella se dà fastidio in demo. E A aspetta la PR su `claim.md`.

---

## 7o. A trova un bug nella fatturazione — 26 agosto

`risposta-per-B-M2.md` accetta entrambe le richieste di M2 e, in fondo, sotto *"non c'entra con le
tue domande"*, segnala un difetto reale nel codice di B. Risposta in `risposta-per-A-M2.md`.

### La tariffa di overstay stava in due posti

`schema.sql` — contratto congelato — definisce `stations.tariff_cents_min_overstay`, cioè una
tariffa **per stazione**. Verifica sul repository:

```
$ grep -rn "tariff_cents_min_overstay" --include=*.java --include=*.erl --include=*.sql .
contracts/schema.sql:55:    tariff_cents_min_overstay INT  NOT NULL DEFAULT 50
```

**Una sola occorrenza: la riga che la definisce.** Nessuno la leggeva.

`BillingService` usava invece `Env.getInt("OVERSTAY_CENTS_MIN", 50)`, un valore **globale**. Quindi
nella stessa formula un addendo era per stazione (l'energia, letta dal join) e l'altro per
deployment. Entrambi valevano 50, perciò nessun test poteva accorgersene.

L'errore vero non è stato dimenticare la colonna: è stato **inventare una configurazione** per un
prezzo che il contratto aveva già deciso dove vivesse, metterla nel compose come se fosse la
fonte, e scriverci sopra dei test che la usavano. Tre strati che si confermavano a vicenda.

### Correzione

- `SessionDao` seleziona `st.tariff_cents_min_overstay`; `Unbilled` lo porta.
- `BillingService` lo usa; `OVERSTAY_CENTS_MIN` **eliminata**, non degradata a default — finché
  resta è una seconda fonte per lo stesso prezzo, e quella che vince in silenzio. Tolta anche dal
  compose, con una riga che dice perché non c'è.
- `history.jsp` non cita più una cifra globale: con la tariffa per stazione quella frase era falsa
  per metà delle righe di una pagina che elenca sessioni di siti diversi. Effetto che A non aveva
  menzionato e che discende dalla stessa causa.
- Nuovo test `overstayIsPricedByTheStationsOwnRate`, **con due tariffe diverse** (50 e 80): con una
  sola la regressione è invisibile, che è il motivo per cui dieci test precedenti non l'avevano
  vista.

**Verificato in Docker.** Due sessioni identiche — 10 kWh, 5 minuti di overstay — su stazioni con
overstay a 50 e a 80:

| Sessione | Stazione | Energia | Overstay | Totale |
|---|---|---|---|---|
| 5 | Pisa Centro | 10 × 45 = 450 | 5 × 50 = 250 | **700** |
| 6 | Livorno Port | 10 × 42 = 420 | 5 × 80 = 400 | **820** |

Al primo tentativo Livorno usciva 670, cioè 420 + 5 × **50**: il container girava l'immagine
precedente perché il build era stato interrotto. Vale la pena annotarlo — un fix che sembra non
funzionare, quando il codice è giusto, quasi sempre è un'immagine non ricostruita.

### Le altre due decisioni

**`overstay_seconds` è il netto**: A conferma, la stazione sottrae `OVERSTAY_GRACE_SECONDS`.
Tolta la riserva *pending* da `erlang-java.md` §2.3. A allinea anche il campo omonimo nel frame
`session` di `ws-driver.md`, così il nome significa una cosa sola su entrambi i canali. Da notare
il modo in cui ha preso la decisione: dichiarando **cosa si perde** — con il netto non si può più
sapere a posteriori quanto restano attaccate le auto, e un cambio di tolleranza rende le righe
vecchie incomparabili.

**`StartedAt` / `EndedAt` passano a millisecondi.** Il contratto diceva "epoch seconds" mentre ogni
altro campo del confine è in millisecondi (`GrantedAt`, `ExpiresAt`, `NewExpiresAt`, `expires_at`).
A ha ragione e l'argomento è lo stesso che B usa altrove: un fattore 1000 non rompe nessun tipo,
non fallisce nessun test, e si manifesta come una data nel 1970. `OverstaySeconds` resta in secondi
perché **se lo porta nel nome**.

### Nota di metodo

Due volte in due giorni A ha trovato qualcosa di sostanziale leggendo codice di B: prima
l'inversione della copertura dei test sul `renew` (§7l), ora questa. In entrambi i casi il difetto
era invisibile a chi l'aveva scritto perché *coerente con sé stesso* — 50 = 50, e cinque test che
esercitano la forma sbagliata. È l'argomento più concreto a favore delle PR incrociate, e vale la
pena dirlo nella relazione invece che rivendicare solo il risultato.

---

## 7n. Il metodo dei branch, finalmente applicato — 25 agosto

Le due milestone di oggi sono entrate su `main` **passando da una PR**, non da un push diretto:

| PR | Contenuto | Merge |
|---|---|---|
| #1 `b/m2-billing` | deploy (EPMD), M2-B, documentazione | `75012f5` |
| #2 `b/m3-failover` | M3-B: elezione, quorum, ricostruzione | `ecdd323` |

Vale la pena annotarlo perchè è il punto di metodo che A aveva sollevato (§7l) e che B aveva
violato il 24: la regola dei branch e delle PR esisteva da M0 ma non era mai stata usata.

**Sulla PR "retroattiva" che A proponeva.** Non è realizzabile come la immaginava: i due diff su
`claim.md` sono già dentro `main` (`b830682`, `f14f852`), e non si apre una PR su ciò che è già
stato mergiato. Si potrebbe fabbricare un branch dal commit precedente, ma sarebbe una messinscena,
e all'orale una traccia costruita a posteriori vale meno di zero.

La risposta migliore è l'opposto: **la prossima modifica a `claim.md` non è ancora stata fatta.**
Il messaggio `session_closed` stazione → coordinatore è stato deliberatamente lasciato fuori dal
contratto proprio per poterlo proporre nel modo giusto — PR prima del codice, A come reviewer.
Nel merito dimostra la stessa cosa, e in più è vera.

---

## 7p. M2-A passo 1: il canale colonnina — 27 agosto

Branch `a/m2-chargepoint`. Nuovi `vs_cp_proto`, `vs_cp_ws`, `src/emulator/cp.js`; modificati
`vs_connector` (D1-D5), `vs_station_app` (secondo listener), `vs_station_db`
(`user_for_vehicle/1`). Contratto `contracts/ws-chargepoint.md` **non toccato**: è
implementabile com'è scritto, incluse le tre assenze che sembrano dimenticanze e non lo sono
(nessuna cache di dedup, nessun frame `error`, nessun ack sugli eventi — vedi
`scelte_di_progetto.md` §11.9).

Prima di questo passo, `plugged`/`meter`/`unplugged` esistevano come API di `vs_connector` e
**nessun codice di produzione le chiamava**: solo i test. Il sistema sapeva prenotare e non
sapeva caricare.

### Le tre premesse che il piano dichiarava NON VERIFICATE — ora misurate

| Premessa | Misura | Esito |
|---|---|---|
| Suite attuale 133 test, 0 fallimenti | `rebar3 eunit` (senza `--app`), 27/08 | **verificata**: 133/0 esatti |
| Node sul host ha il `WebSocket` globale | `node --version` → v24.18.0; `typeof WebSocket` → `function` | **verificata** |
| Un secondo listener cowboy convive col primo | app vera avviata, `cowboy:start_clear(vs_cp_listener, 8081)` accanto a `vs_driver_listener`, GET su entrambe le rotte | **verificata**: `{ok,Pid}`, `426 Upgrade Required` da 8080/ws/driver **e** da 8081/ws/cp, ranch non si lamenta |

La terza è stata provata **prima** di scrivere il listener vero, con un modulo usa-e-getta:
se ranch avesse protestato, il piano andava fermato lì e non dopo due ore di codice.

### Verificato — girato davvero

- **Suite: 180 test, 0 fallimenti** (`rebar3 eunit`, mai `--app`). 133 di baseline + 47 nuovi:
  18 su `vs_connector` (D1-D5, grazia, sostituzione socket, riconciliazione) e 29 su
  `vs_cp_proto` (handshake e 4404, boot/ack, heartbeat, i quattro esiti del `plugged`,
  meter/unplugged/status, envelope, e le quattro verdette del trasporto — 4404, 4409,
  encoding del comando, shutdown).
- **Sessione walk-in completa sul compose**, emulatore dal host contro
  `ws://localhost:9201/ws/cp?station_id=1&connector_id=3`, connettore 3: `boot` → ack
  (heartbeat 30 s, meter 5 s, limit 0) → `plugged` → `set_limit 150` dal connettore → `meter`
  → `unplugged`. **Emulatore `final energy_kwh = 1.206`, log stazione
  `session closed (not yet persisted): … energy_kwh => 1.206`: differenza 0.000**, contro una
  tolleranza dichiarata di ±0.01. La sessione è stata letta dal log della stazione, non da
  `station.jsp`.
- **Riconciliazione §6 sul compose**: `docker restart station1` con l'emulatore in carica a
  **1.417 kWh**. La stazione, andandosene, ha mandato `stop {reason: station_shutdown}` e ha
  chiuso 1001; l'emulatore ha tenuto cavo e contatore, si è riconnesso col backoff
  (1 s → 2 s), ha rimandato `boot` (`status: occupied`) e `plugged` con
  `energy_kwh: 1.417`, e la stazione ha **adottato** la sessione: il `meter` successivo
  riporta 1.625 — mai indietro. `started_at` della riga è l'istante dell'adozione, non del
  cavo: la stazione non ha memoria del pre-crash e §6 fa fede al totale del contatore.
- **Grazia dei tre heartbeat, sul compose**: emulatore ucciso a sessione in corso. Il log dice
  `connector 3: no charge point for 90000 ms mid-session - closing with the last measured
  energy` — 90 s = `CP_HEARTBEAT_MISSED × CP_HEARTBEAT_INTERVAL_S` letti dall'ambiente, non
  una costante — e la riga è stata scritta con **2.875 kWh**, esattamente l'ultimo `meter`
  ricevuto. Poi `out_of_service`.
- **Rientro in servizio**: un nuovo `boot` con `status: available` →
  `charge point reports available - back in service` → `free`, e la sessione successiva è
  finita nel modo ordinario (`energy_kwh => 0.583`, di nuovo pari al totale dell'emulatore).
  È la prova E2E che `after_closing` è una bandierina di sola andata (§11.5).
- **I due listener convivono nel container**: `GET :9101/ws/driver` → `426 Upgrade Required`,
  `GET :9201/ws/cp` → `426 Upgrade Required`, dopo tutto quanto sopra.
- **`warnings_as_errors` attivo**: la build passa pulita, nessun `catch Expr` deprecato.

### Non provato — e perché

- **`station.jsp` non è stato aperto in Chrome.** La sessione walk-in è stata verificata dal
  log della stazione, che è l'alternativa prevista. Manca quindi la conferma visiva che
  `out_of_service` e la sessione arrivino fino alla pagina — anche se la catena è verificata
  per struttura (`wire_connector_state/1` ha la clausola passante, l'enum di `ws-driver.md`
  §5.1 contiene già `out_of_service`).
- **Un connettore che crasha a sessione in corso** riparte `free` con `cp = undefined`, e
  niente dice al socket CP di riagganciarsi: i comandi smettono di fluire fino alla
  riconnessione del socket. È semantica di riavvio già presente da M1, non introdotta qui, e
  il `meter` successivo finisce nel log "meter senza sessione" invece che nel vuoto. Non
  allargato: il rimedio è un `attach_cp` scatenato dal `connector_up`, che tocca il manager.
- **La notifica `session_interrupted` non arriva al browser.** Il connettore *emette* l'evento
  verso il manager, come già fa per `claim_revoked`, ma il frame `notification` di
  `ws-driver.md` non è implementato sul canale driver (verificato: nessun builder in
  `vs_driver_proto`). Fuori perimetro, com'era per gli eventi di M1.
- **`user_for_vehicle/1` è uno stub dichiarato**: risponde l'identità e lo scrive nel log a
  ogni chiamata. Finché non c'è la SELECT del passo 3, un walk-in apre la sessione su
  `user_id = vehicle_id` — corretto per il seed dove i due coincidono, falso altrove.
- **Il rifiuto 4409 non è stato provato su un socket vero**: c'è il test del trasporto
  (`{cp_replaced}` → close 4409) e quello del connettore (il vecchio pid riceve
  `{cp_replaced}`), ma due emulatori sullo stesso connettore non sono mai stati messi in
  concorrenza sul compose.
- **La seconda uscita da `out_of_service` non è stata provata E2E.** L'adozione di §6 su un
  connettore fuori servizio (colonnina tornata `occupied` dopo la grazia, `plugged` col
  cumulativo) ha il test unitario ma non uno scenario sul compose: servirebbe un
  `docker network disconnect` di oltre 90 s tenendo vivo l'emulatore. Il buco è stato trovato
  in revisione, non dai test: tutti gli scenari eseguiti rientravano in servizio da un
  connettore libero, dove basta `available`.
- **`limit_kw: 0` come "sospeso"** è implementato e coperto dai test unitari, ma nessuno
  scenario E2E lo ha esercitato: nel passo 1 il limite viene impostato una volta sola e non
  scende mai. Sarà lo scenario naturale del passo 2, quando l'allocatore ripartisce.

### Catena dei chiamanti: una voce che il piano non aveva

Il piano (§6) elencava sei funzioni modificate. La ricerca per struttura (grep sui nomi, non
sui file attesi) ne ha trovata una settima, e per fortuna non richiede modifiche:
`vs_claim_client:count_stats/1` legge lo stato dei connettori per le `station_stats` verso il
coordinatore. Ha un catch-all `_ -> {F, H, Ch}`, quindi `out_of_service` viene contato come
niente — la stessa semantica di `offline`, che è quella giusta. Se il catch-all non ci fosse
stato, un connettore guasto avrebbe fatto crashare il client dei claim.

---

## 7q. M2-A passo 2: il riparto della potenza — 27 agosto

Branch `a/m2-power`, da `a/m2-chargepoint`. Nuovo `vs_power` (modulo puro) più i suoi test;
modificati `vs_station_mgr` (ricalcolo, tick, `allocated_kw`), `vs_connector`
(`build_snapshot`: `suspended` derivato e `max_kw` nello snapshot) e
`vs_claim_client:count_stats/1`. **Nessun contratto toccato**, `ws-driver.md` e
`ws-chargepoint.md` compresi: `suspended` era già nell'enum di §5.1 e `MIN_CHARGE_KW` già in
§10.

Prima di questo passo il limite era quello interinale di D5 — `min(rated_kw, max_kw)`, deciso
una volta all'ingresso in `charging` e mai più toccato. Con due auto sulla stazione 2 la somma
faceva 150 + 50 = 200 kW su un sito da 180: il buco che il passo 1 dichiarava e che questo
chiude.

### Una premessa del piano era falsa, ed è stata corretta prima di iniziare

Il piano diceva «base: `a/m2-chargepoint` (passo 1 committato)». **Non lo era**: l'ultimo
commit del branch era il merge di M1, e tutto il passo 1 stava nel working tree, non
versionato. Il contenuto era giusto — la baseline ha dato i 180 test attesi — ma il passo 2
sarebbe nato mescolato al passo 1 in un albero sporco, senza uno stato a cui tornare. Il passo
1 è stato committato (`b9ee35e`) su richiesta esplicita, e `a/m2-power` parte da lì.

### Le tre premesse che il piano dichiarava NON VERIFICATE — ora misurate

| Premessa | Misura | Esito |
|---|---|---|
| Baseline 180 test, 0 fallimenti | `rebar3 eunit` (senza `--app`), 27/08 | **verificata**: 180/0 esatti |
| L'emulatore applica un `set_limit` che **scende** a sessione in corso | una sola auto in carica a 150 kW su st. 2/conn 5, `vs_connector:set_limit(Pid, 20)` a mano via rpc | **verificata**: comando a `13:15:11.3`; `meter` a +4.3 s → 37.7 kW (rampa a metà, interpolazione esatta), `meter` a +9.3 s → **20 kW**. Dentro `LIMIT_APPLY_SECONDS` (5 s) più un intervallo di contatore |
| Due emulatori concorrenti sulla stessa stazione | conn 5 (150 kW) e conn 6 (50 kW) in carica insieme su st. 2 | **verificata**: nessun 4409, nessun socket rimpiazzato, nessun frame incrociato. Ognuno tiene il proprio limite e la propria sequenza di `request_id`; conn 5 è rimasto a 20 kW mentre conn 6 saliva a 50 |

La seconda e la terza sono esattamente ciò che il passo 2 mette sotto sforzo per la prima
volta: se l'emulatore non avesse obbedito a un limite in discesa, l'allocatore non avrebbe
avuto modo di funzionare e il difetto sarebbe stato lì.

### Verificato — girato davvero

- **Suite: 217 test, 0 fallimenti** (`rebar3 eunit`, mai `--app`). 180 di baseline, **+37 netti**:
  28 su `vs_power` (i sei scenari attesi, quattro proprietà su uno sweep deterministico di 112
  casi, gli angoli della sospensione, e `demand_kw`/`demands`), 6 su `vs_station_mgr`
  (allocazione, invariante, partenza, tick/taper, sospensione, il non-ciclo — sei, ma uno
  **sostituisce** il test M1 di `allocated_kw`, quindi +5 su quel file), 3 su
  `vs_connector` (limite zero → `suspended`, `plugged` senza `max_kw`, `max_kw` nello
  snapshot), 1 su `vs_claim_client` (`suspended` conta come `charging`).
- **I sei scenari del piano §8 escono esatti**, confronto con tolleranza dichiarata (0.001), non
  con `=:=`:

  | Scenario | Domande (kW) | Budget | Atteso | Osservato |
  |---|---|---|---|---|
  | St. 2, una 150 | 150 | 180 | 150 | **150** |
  | St. 2, 150 + 50 | 150, 50 | 180 | 130, 50 | **130, 50** |
  | St. 2, tre auto | 150, 50, 50 | 180 | 80, 50, 50 | **80, 50, 50** |
  | St. 1, quattro auto | 150, 150, 150, 50 | 350 | 100, 100, 100, 50 | **100, 100, 100, 50** |
  | St. 1, taper | 150, 150, 45, 50 | 350 | 127.5, 127.5, 45, 50 | **127.5, 127.5, 45, 50** |
  | Sospensione (budget forzato) | 50, 50, 50 | 15 | 7.5, 7.5, 0 | **7.5, 7.5, 0** |

- **E2E sul compose, stazione 2 (budget 180), tre fasi:**

  | Momento | Atteso | Osservato | Ritardo |
  |---|---|---|---|
  | Una 150 kW sul conn 5 | limite 150, `allocated_kw` 150 | **150.0 / 150.0** | — |
  | Arriva una 50 kW sul conn 6 | limiti 130 e 50, `allocated_kw` 180 | **130.0 e 50.0 / 180.0** | `plugged` a `13:34:28.627`, nuovo limite al conn 5 a `13:34:28.632` — **5 ms** |
  | La seconda se ne va (`stop_session` → `unplugged`) | il primo torna a 150 | **150.0 / 150.0** | stop a `13:34:48.317`, nuovo limite a `13:34:48.319` — **2 ms** |

  I contatori si sono assestati sui valori concessi esatti (130 e 50 kW), dopo la rampa
  `LIMIT_APPLY_SECONDS`. Il riparto è **guidato dagli eventi**: nessuna delle due transizioni
  ha aspettato il tick, che serve solo al taper.
- **`allocated_kw =< site_power_kw`** è un test dell'invariante, non un'osservazione: il campo
  è la somma dell'allocazione memorizzata, quindi vale per costruzione.
- **Il ricalcolo non si autoalimenta**: un test tiene il tick a 20 ms con una sessione viva e
  verifica che in 200 ms (≈10 ricalcoli) arrivino **zero** push ai sottoscrittori.
  `charging(cast, {set_limit,_})` non emette `notify`, e il test è lì perché smetta di essere
  vero rumorosamente se qualcuno gliela aggiunge.
- **`warnings_as_errors` attivo**: build pulita da `_build` svuotato.

### Non provato — e perché

- **`station.jsp` non è stato aperto in Chrome.** L'E2E è stato letto da `station_state` via
  rpc, non dalla pagina. Manca quindi la conferma visiva che `allocated_kw` che cambia e uno
  stato `suspended` arrivino fino al browser — la catena è verificata per struttura
  (`wire_connector_state/1` ha la clausola passante, `station.js:99` legge `allocated_kw`), non
  per osservazione. È lo stesso buco del passo 1.
- **La sospensione non è stata vista girare sul compose, e non può esserlo con i budget veri**:
  350/4 = 87.5 e 180/3 = 60, entrambi molto sopra i 6 kW di `MIN_CHARGE_KW`. È coperta da test
  unitari e da un test del manager con `site_power_kw` forzato a 8; per mostrarla nella demo
  serve un `SITE_POWER_KW` ridotto via ambiente. Scritto qui invece di lasciar credere che il
  caso sia stato osservato.
- **Il taper non è stato osservato E2E**: portare un'auto sopra l'80% di SoC richiede minuti di
  carica reale. È coperto dal test del manager (`the_power_tick_is_what_notices_a_taper_test`,
  con tick a 50 ms) e dai test di `demand_kw`, ma nessuna auto vera è arrivata all'80% con un
  vicino che ne raccogliesse l'avanzo.
- **Tre auto insieme sulla stessa stazione** non sono state provate sul compose: l'E2E ne ha
  usate due. Lo scenario a tre è un test unitario (80/50/50), non un'osservazione.
- **La stazione 1 non è stata toccata**: l'E2E è tutto su st. 2. Gli scenari a quattro auto e
  con il taper sono aritmetica verificata, non un compose osservato.
- **`vs_station_db` resta lo stub del passo 1**: le sessioni non finiscono ancora su MySQL, e il
  passo 2 non lo cambia (fuori perimetro).

### Catena dei chiamanti: quattro voci che il piano non aveva

La tabella §7 del piano elencava cinque funzioni. La ricerca per struttura ne ha aggiunte
quattro, e una era una trappola vera:

1. **`vs_cp_proto:limit_kw/2`** chiama `snapshot/1` per l'ack del `boot`. Innocuo — legge
   `session.limit_kw`, non `state` — ma è un consumatore reale che il piano non aveva.
2. **`vs_driver_ws:state_tick`** rilegge `station_state()` su un proprio timer da 5 s. È la
   ragione per cui il power tick **non** fa broadcast: la pagina vede il taper lo stesso, e
   spingere da entrambe le parti raddoppierebbe il traffico.
3. **`allocated_kw` non è letto "solo da `wire_state` e `station.js`"**: lo leggono anche
   `vs_driver_stub.erl:120` e tre asserzioni nei test.
4. **La trappola.** Il piano non prevedeva l'interazione fra `suspended` derivato e il
   ricalcolo: dopo la derivazione il manager vede `suspended` dove vedeva `charging`, e un
   filtro su `state =:= charging` avrebbe tolto la sessione dal riparto **nell'istante in cui
   la sospende** — fame permanente invece che di un tick. `vs_power:demands/3` accetta
   entrambi gli stati e ha un test dedicato.

### Una regola del piano raffinata, con conferma esplicita prima di scrivere

La sospensione letterale del piano — «finché una quota è sotto soglia, sospendi quella con
`started_at` maggiore» — sbaglia bersaglio quando la fame nasce dalla *domanda* invece che dal
*budget*. Domande di 3 e 50 kW su 180 di budget: la 3 prende 3 (sotto soglia) → si sospende la
50 perché è la più recente → resta la 3 da sola, ancora sotto soglia → si sospende anche quella
→ zero allocato con 180 kW liberi.

Il raffinamento, approvato prima di toccare il codice: se la quota sotto soglia coincide con la
domanda della sessione stessa, quella sessione non può essere alzata togliendo nessun altro, e
va lei. «L'ultimo arrivato» resta la regola dove è stata progettata, cioè sotto pressione di
budget. **I sei numeri attesi sono identici sotto le due letture** — cambia solo quell'angolo —
e la proprietà «nessuna allocazione fra 0 e `MIN_CHARGE_KW` esclusi» diventa esattamente vera.

### Un difetto dell'emulatore, trovato dall'E2E — e poi corretto

`cp.js` confrontava il limite in arrivo con quello **interpolato** in quel momento invece che
con il proprio bersaglio, quindi una ripetizione dello stesso valore mentre la rampa è a metà la
faceva ripartire dal punto in cui era. Con `set_limit` re-inviato a ogni tick — che è
ws-chargepoint.md §5 alla lettera — succedeva a ogni ricalcolo: convergeva (i contatori avevano
chiuso su 130 e 150 kW esatti) ma allungava la rampa, e il tempo di applicazione misurato nella
demo sarebbe stato più lungo di quello vero.

Segnalato alla fine del passo 2 e **corretto subito dopo**, insieme al lock-in del taper (§7r):
il confronto è ora con `limit.target`. Verificato dopo la correzione: `20 → 150` seguito da
quattro `set_limit 20` a un secondo l'uno dall'altro produce **una sola** riga di log, e il
contatore a +3.4 s legge 36.7 kW — l'interpolazione esatta da un'unica partenza, cioè la prova
che la rampa non è ripartita.

---

## 7r. Due correzioni al passo 2, prima di committare — 27 agosto

Sempre su `a/m2-power`, prima del commit. Due difetti trovati **in revisione, nessuno dei due
dai test**: è il dato interessante di questa voce, perché entrambi vivono in un angolo che i
budget veri non raggiungono mai e che quindi nessuno scenario eseguito aveva toccato.
Perimetro: `vs_power.erl`, `vs_power_tests.erl`, `src/emulator/cp.js`. L'algoritmo di riparto
(`fair_share/2`, `allocate/4`, `starved/3`, `victim/1`) **non è stato toccato**.

### Difetto 1 — la sospensione era permanente sopra la soglia del taper

Il gemello del lock-in che la soglia sul SoC doveva evitare, rientrato attraverso `power_kw`:

```
sospesa → limit_kw 0 → il CP applica 0 → meter riporta power_kw = 0
        → demand = min(Ceiling, 0 + TAPER_MARGIN_KW) = 5
        → 5 < MIN_CHARGE_KW (6), e Got >= demand ⇒ è `demand'-bound
        → victim/1 la preferisce a chiunque ⇒ sospesa di nuovo, per sempre
```

Un consumo misurato **mentre la sessione è a zero** non dice niente sulla curva della batteria:
dice che le abbiamo tolto la corrente. La correzione è in `demand_kw/3` — il ramo del taper
chiede due cose, sopra la soglia **e** `limit_kw =/= 0.0` — e sta in `scelte_di_progetto.md`
§12.3 con il perché.

**I due test nuovi sono stati eseguiti prima della correzione, e come falliscono è il dato:**

| Test | Prima | Dopo |
|---|---|---|
| `a_suspended_session_above_the_threshold_asks_for_its_ceiling_test` | `expected: 150.0 / got: **5.0**` | passa |
| `a_session_suspended_above_the_threshold_comes_back_test` | la sospesa resta a **0.0** col budget interamente libero | risale a 12.0 |

Il secondo è il ciclo completo — tre sessioni, budget stretto, una sospesa a SoC 85; poi le
altre due se ne vanno e al ricalcolo successivo la sospesa deve risalire. Il primo da solo non
basta: descrive un numero, non il difetto. `a_suspended_session_still_takes_part_test` (SoC 22,
copre l'altro lock-in, quello di `is_live/1`) continua a passare e resta separato: i due si
somigliano e non vanno fusi.

*Conseguenza sui test esistenti.* L'helper `snapshot/4` dei test fissava `limit_kw => 0.0`,
quindi ogni test del taper descriveva uno stato impossibile — 40 kW che scorrono con un limite
di zero. Adesso l'helper usa il proprio `Ceiling` come limite e c'è `snapshot/5` per chi vuole
una sessione davvero sospesa. Nessun numero atteso è cambiato: i 28 test preesistenti passavano
già prima della correzione con il nuovo helper.

### Difetto 2 — `setLimit` dell'emulatore faceva ripartire la rampa

Descritto in §7q e corretto qui: il confronto è ora con `limit.target` invece che con il valore
interpolato. Verifica eseguita su una stazione usa-e-getta con `SITE_POWER_KW=20`, così che le
ripetizioni identiche siano quelle che il contratto stesso produce a ogni tick:

- `limit 20 -> 150` a `14:11:23.055`, poi quattro `set_limit 20` a un secondo l'uno dall'altro;
- il log mostra **una sola** riga `limit 71.7 -> 20` (`14:11:25.045`) — le tre ripetizioni non
  producono niente, e nemmeno i tick della stazione;
- contatore a +3.4 s: **36.7 kW**, che è `71.7 + (20 − 71.7) × 3.385/5` esatto — la rampa è
  partita una volta sola;
- primo contatore dopo la finestra di 5 s: **20 kW**.

La partenza da 71.7 e non da 150 è la parte giusta del comportamento: un valore davvero nuovo
riparte da dove l'hardware è, non da dove gli era stato detto di arrivare.

### Suite

**219 test, 0 fallimenti** (`rebar3 eunit`, mai `--app`): 217 del passo 2 più i due nuovi.
Compilazione pulita da `_build` svuotato, `warnings_as_errors` attivo.

---

## 7s. M2-A passo 3: la riga su `sessions` — 27 agosto

Branch `a/m2-db`, da `a/m2-power` (`21ba127`). `vs_station_db` diventa un gen_server con una
connessione `mysql-otp`; nuova `vs_claim_client:session_closed/1`; `vs_connector:closing/3`
perde il `case` sull'esito della scrittura; `vs_station_sup` guadagna un figlio. Nuova
dipendenza `{mysql, "1.8.0"}`, `rebar.lock` aggiornato. **`schema.sql` non toccato**: la
tabella si usa com'è.

Con questo, la catena è chiusa da capo a fondo per la prima volta: l'auto carica, la stazione
scrive la riga, il coordinatore sveglia Java, Java la fattura. Fino a ieri la fatturazione
girava su righe inserite a mano.

### Una premessa del prompt era vecchia di due ore

Il prompt dava la baseline a 217 test. Sono **219**: i due test aggiunti dal commit `21ba127`
(le correzioni al passo 2), che il piano precede. Discrepanza spiegata per intero, non un
mistero: si riparte da 219.

### Le tre verifiche bloccanti

| Verifica | Misura | Esito |
|---|---|---|
| Baseline `rebar3 eunit` (mai `--app`) | 27/08 | **219 test, 0 fallimenti** (non 217 — vedi sopra) |
| `mysql-otp` 1.8.0 compila su OTP 29 | `{mysql, "1.8.0"}` in `rebar.config` + `rebar3 compile` | **verificata**: compila. Due warning nel sorgente della dipendenza (`catch` deprecato, `0.0` che non matcha `-0.0`), già coperti dall'`overrides` che toglie `warnings_as_errors` alle dipendenze |
| Il nodo Erlang raggiunge MySQL | connessione dal container `station2` con le credenziali del compose | **verificata**: `SELECT 1` → `[[1]]`; `vehicles` → `[[1,1],[2,2]]`; `sessions` → 0 righe (quindi nessun residuo di `cc-probe` che disturbi — la quarta premessa NON VERIFICATA del piano, chiusa) |

*Di passaggio, e vale la pena:* il container MySQL gira con `time_zone = SYSTEM` e
`NOW() = UTC_TIMESTAMP()`. Cioè `FROM_UNIXTIME()` oggi avrebbe dato lo stesso risultato — ed è
esattamente perché non la si usa: funzionerebbe finché nessuno cambia il fuso del container.

### Verificato — girato davvero

- **Suite: 244 test, 0 fallimenti** (`rebar3 eunit`, mai `--app`). 219 di baseline + 25 nuovi:
  23 su `vs_station_db` (l'orologio verso UTC compresa un'ora legale e un cambio d'ora, la riga
  colonna per colonna, la tupla di `erlang-java.md` §2.3 campo per campo, la coda, il tetto, il
  ritenta, il rifiuto del server contro la connessione caduta, la riconnessione, e i quattro
  esiti di `user_for_vehicle/1`) e 2 su `vs_connector`. **Nessuno richiede MySQL**: la parte che
  conta è il comportamento quando il database *non* risponde, e un test che avesse bisogno di un
  database funzionante non potrebbe produrlo su richiesta.
- **Sessione completa → una riga.** Emulatore su st. 2/conn 5, veicolo 2:
  `final energy_kwh = 1.164`, riga `energy_kwh = 1.164` — **differenza 0.000**. Log stazione:
  `session 1 written: connector 5, user 2, 1.164 kWh`.
- **Le date, lette in SQL.** Emulatore `plugged` alle `15:04:52.237`, `unplugged` alle
  `15:05:20.259` (il log di `cp.js` è in UTC, `toISOString`); riga
  `started_at = 15:04:52`, `ended_at = 15:05:20`. **Coincidono al secondo, in UTC.** Confermato
  da una seconda sessione: plugged `15:16:33.356` / unplugged `15:17:06.455` → riga
  `15:16:33` / `15:17:06`.
- **`cost_cents` NULL all'inserimento.** Non si riesce a *vederlo* nel giro normale, perché
  B fattura in 38 ms (sotto); osservato fermando il back office: riga `[5, 1, 2, 7, …, 0.458, 0,
  **null**]`. Al riavvio la spazzata periodica l'ha prezzata da sola
  (`15:20:55 Billed 1 session(s)`, costo 19) — cioè la proprietà del contratto "perdere l'evento
  ritarda una ricevuta di un intervallo e non perde niente", vista girare.
- **La catena fino a Java, cronometrata.** Sessione finita alle `15:17:06.455`; back office:
  `15:17:06.493 BillingService.sweep Billed 1 session(s)`. **38 ms**, che non è la spazzata da 60
  secondi: è la sveglia `session_closed` che l'ha fatta partire prima. È anche la prova che la
  tupla di §2.3 è nella forma giusta — un campo fuori posto non avrebbe dato errore da nessuna
  parte, e questo è l'unico modo di accorgersene senza guardare una fattura.
- **La prova che conta: MySQL fermo.** Sessione avviata con MySQL su, `docker stop mysql` a
  sessione in corso, poi chiusura:

  | | MySQL su | MySQL fermo |
  |---|---|---|
  | percorso di `closing`, dal cast `unplugged` al `free` | **12 µs** | **44 µs** |

  Microsecondi in entrambi i casi: nessun ritardo misurabile, che è il punto dell'INSERT
  asincrono. Connettore `free`, **1 riga in coda**. Al `docker start mysql` la riga è comparsa
  **da sola entro ~1 s** dal momento in cui MySQL è tornato sano — dentro `DB_RETRY_MS` (5 s) —
  con `session 3 written` nel log e nessun intervento.
- **Una riga per sessione, mai due**: cinque sessioni, cinque righe, id da 1 a 5, nessun
  duplicato — compresa quella passata dalla coda.
- **`warnings_as_errors` attivo**: build pulita da `_build` svuotato.

### Un difetto trovato dall'E2E, che i test non avevano preso

Il timer del ritenta fa due lavori — svuotare la coda **e** riaprire la connessione — e una coda
vuota lo cancellava. Una stazione che aveva scritto tutto e poi perdeva MySQL restava con coda
vuota e nessuna connessione: **cancellava la propria riconnessione e non ne apriva più un'altra.**
MySQL tornava su e la stazione continuava a rifiutare ogni walk-in, perché `user_for_vehicle/1`
rispondeva `no_connection` per sempre — senza un errore da nessuna parte che lo spiegasse.

Trovato perché dopo un `docker start mysql` la stazione andava avanti a rifiutare l'emulatore. Le
due clausole di `flush/1` sono ora nell'ordine opposto. Il test che lo copre tiene il guasto più
lungo del primo ritenta: scritto prima in una versione che *passava lo stesso* — la connessione
riusciva al primo tentativo e il ramo difettoso non veniva mai attraversato — e reso capace di
fallire prima di correggere. Senza quel passaggio sarebbe rimasto un test verde su un difetto
vivo.

### Non provato — e perché

- **`history.jsp` non è stata aperta.** Due ostacoli, entrambi fuori dal mio controllo:
  l'estensione Chrome non risulta connessa (`Browser extension is not connected`), e non ho la
  password di `lore` né di `cc-probe` — gli utenti sono di B e le loro credenziali non stanno nel
  repo. **La verifica del fuso è quindi fatta a metà**: le date coincidono al secondo lette in
  SQL, ma nessuno ha ancora confermato che appaiano con la stessa ora nella pagina. È l'unica
  metà che potrebbe nascondere un errore di un'ora, perché lì passa dal `getTimestamp` di B.
- **Il tetto della coda non è stato provato E2E**: 100 righe richiedono cento sessioni. Coperto
  da un test unitario con `queue_max => 3`.
- **La riga persa alla morte del nodo** (la finestra dichiarata) non è stata provocata: servirebbe
  un `docker kill` cronometrato fra il cast e l'INSERT. Il `terminate/2` che la scrive nel log
  esiste e non è stato visto scattare.
- **Il seed non distingue lo stub dalla SELECT vera** per i veicoli che ha: `vehicles` mappa 1→1
  e 2→2, quindi identità e query danno lo stesso risultato. Quello che *distingue* è il veicolo
  88 dell'esempio del passo 1, ora rifiutato (`no account for vehicle 88`) — ed è stato visto.
- **`overstay_seconds` è sempre 0**: è M4, e il campo è scritto come valore dichiarato, non
  mancante.

### Catena dei chiamanti: quattro voci che il piano non aveva

1. **`vs_cp_stub` è un secondo `db_mod`** che la tabella §6 non elenca: implementa
   `user_for_vehicle/1` per i test di `vs_cp_proto`. Non implementa `insert_session/1`, quindi il
   passaggio a cast non lo tocca — ma è un'implementazione in più da tenere allineata.
2. **`{session_closed, Row}` esisteva già** come nome di evento del connettore verso il manager
   (`vs_connector.erl:538`), ed è una cosa diversa dalla `vs_claim_client:session_closed/1` nuova
   verso il coordinatore. Stesso nome, due direzioni, due righe di distanza nello stesso file.
3. **La forma sul filo non è quella che sembra.** `vs_coord_srv` fa match su
   `{session_closed, Event}` — una tupla a **due** elementi che ne avvolge una a nove — mentre
   `station_stats`, che il piano indica come modello, viaggia piatta a cinque. Mandare i nove
   campi piatti sarebbe caduto nel catch-all del coordinatore: un warning in un log che nessuno
   guarda, e una ricevuta che non arriva mai. Verificato leggendo `vs_coord_srv:203-265` e
   `vs_coord_bo:126`, non assunto dal nome.
4. **`db_mod` è iniettato anche in `vs_cp_proto`** (`:86`), non solo nel connettore: due percorsi
   indipendenti verso lo stesso modulo.

### Una conseguenza di progetto da mettere agli atti

Con MySQL fermo un walk-in **non può cominciare**: `user_for_vehicle/1` non ha risposta e il
`plugged` viene rifiutato. Le sessioni già in corso si chiudono normalmente e le loro righe si
accodano. L'autonomia della stazione vale quindi per *finire* di caricare, non per *cominciare*
— e il commento di D1 (`user_for_vehicle` sta alla stazione «perché il walk-in deve funzionare
mentre il sito è isolato») va letto con questo in mano: MySQL è remoto quanto il coordinatore. Il
beneficio vero di quella scelta resta un altro e regge: `vehicles` è una tabella del back office
che il coordinatore non possiede.

---

## 7t. Lotto 1 delle correzioni della review — 27 agosto

Una sessione di review su M2-A (`REVIEW_M2A_ESITO.md`) ha trovato nove difetti, ognuno con un
test scritto per fallire. Quattro toccano quanto un driver paga, e sono questi. Gli altri cinque
(D-3 oscillazione del taper, D-4 sessione senza `max_kw`, D-5 riga persa in silenzio, D-8
prenotazione che trapela nello snapshot, D-9 novanta secondi che diventano centottanta) vanno nel
lotto 2 e sono stati **lasciati stare apposta**: le loro cinque prove continuano a fallire, ed è
il controllo che la correzione non ha effetti fuori dal suo perimetro.

**Le due verifiche bloccanti, prima di scrivere una riga.** Baseline `rebar3 eunit` senza
`--app`: 244 test, 0 fallimenti. Con le prove del revisore rimesse nell'albero: 254 con
esattamente 10 fallimenti, quelli attesi. Se ne fosse fallito un numero diverso le prove non
avrebbero più descritto il codice davanti a me, e correggere alla cieca è peggio che non
correggere. (Piano e prompt dicevano «quattro passano, sei continuano a fallire»: sono cinque e
cinque — D-1 ha due prove, il percorso della grazia e quello del guasto.)

**D-1, l'energia fatturata due volte.** Il difetto peggiore, e quello con la diagnosi più
interessante: lo *stesso* frame `plugged` arriva in due situazioni che non sono la stessa cosa.
Se il nodo è morto non esiste nessuna riga e adottare il cumulativo intero è giusto — è §6 del
contratto. Se invece il connettore è vivo e ha appena scritto una riga (grazia scaduta, guasto),
quel cumulativo comprende energia già fatturata. Il connettore ora ricorda quanto ha appena
scritto e lo sottrae; un processo appena avviato ha il campo a zero, quindi il caso del contratto
resta identico senza un ramo dedicato. Dettagli in `scelte_di_progetto.md` §14.2 — in
particolare perché si porta avanti il cumulativo e non la fetta, e perché un contatore ripartito
fa buttare l'offset invece di applicarlo.

**D-2, la riga scritta una frame troppo presto.** `stop_session` e `revoke` mandano un `stop`
all'hardware e §5 dice che l'hardware riferisce il risultato — con l'`unplugged` che porta il
totale vero. La riga veniva scritta prima, con l'ultimo `meter`: nove centesimi a sessione,
sistematici. Ora `closing` ascolta per `CLOSING_SETTLE_MS` (2000) prima di scrivere, e un
`unplugged` chiude l'attesa subito. Il percorso comune non paga niente perché la transizione
posta l'evento in avanti invece di applicarlo da sé.

**D-6 e D-7, la coda del writer.** `announce/3` stava nel corpo dopo `of` — che il `catch` della
stessa `try` non copre, per regola del linguaggio — quindi un `insert_id/1` su una connessione
appena morta uccideva il writer e con lui la coda intera. E ogni errore non riconosciuto
diventava `retry`, quindi una riga che non sarebbe passata mai teneva ferme tutte quelle dietro.
Ora i tre modi di fallire una scrittura sono distinti per quanto costano: non codificabile →
scartata subito; il server ha detto no in un modo che non capiamo → cinque tentativi e poi
scartata; non è partita → riprovata per sempre e non contata.

**Un test esistente è stato corretto, e va detto.**
`an_out_of_service_connector_adopts_a_reconnected_session_test` asseriva che la sessione adottata
partisse da 12.3 kWh — cioè asseriva il doppio addebito come comportamento atteso. Ora asserisce
0.0 e in più che le due righe sommate diano quello che è uscito dall'outlet, che è la proprietà
per cui l'offset esiste. Un test che codifica un difetto non è una rete di sicurezza, è il
difetto scritto due volte.

Anche la prova D-2 del revisore è stata risequenziata: aspettava l'evento `session_closed`
*fra* lo stop e l'`unplugged`, il che incorporava la tempistica del difetto (sotto
scrittura-in-entrata l'evento partiva prima che l'hardware potesse rispondere). L'asserzione non
è cambiata, e la prova risequenziata è stata rieseguita contro il connettore **non** corretto
per controllare che fallisse ancora: fallisce.

**Numeri.** Suite committabile 260 test, 0 fallimenti (244 di prima + 16 nuovi). Con le dieci
prove del revisore: 270 con 5 fallimenti, tutti del lotto 2. End-to-end sui container
ricostruiti, contro MySQL vero: venti kWh erogati attraverso un guasto e una riconnessione danno
due righe da 12.000 e 8.000 — **venti**, non trentadue; e uno `stop_session` con l'`unplugged`
subito dopo scrive **10.200**, il totale dell'hardware, non i 10.0 dell'ultimo `meter`.

**Una cosa trovata per strada:** `station1` stava girando da cinque ore un'immagine anteriore al
commit del passo 3, senza `vs_station_db` nell'albero di supervisione. Il revisore l'aveva
dichiarato e aveva misurato solo su `station2`; entrambe sono state ricostruite prima delle
misure di adesso, e i beam dei container hanno lo stesso md5 di `_build`. Vale la pena
ricordarsene: `docker compose up -d` non ricostruisce, e un'immagine vecchia misura il codice
sbagliato senza dirlo.

## 7u. Lotto 2 delle correzioni della review — 28 agosto

Le cinque prove ancora rosse del revisore: D-3 (oscillazione del taper), D-4 (sessione senza
`max_kw`), D-5 (riga persa in silenzio), D-8 (prenotazione che trapela nello snapshot), D-9
(novanta secondi che diventavano centottanta). Nessuno di questi tocca quanto si paga — quelli
erano il lotto 1 — ma due toccano cosa il driver vede e uno il tempo di reazione a un guasto.

**Le tre verifiche bloccanti, tutte e tre confermate.** Baseline 261/0, e 271 con esattamente
le cinque rosse attese. `release/2` trova il `claim_id` nella sessione quando l'hold è
`undefined` — riletta sul codice **dopo** il lotto 1, che aveva rimaneggiato `closing`, perché
se fosse stato falso azzerare l'hold avrebbe fatto perdere il rilascio dei claim. E sì,
**esisteva** un test che dava per buono un `plugged` senza `max_kw`.

**D-3 e D-4 erano lo stesso difetto visto da due lati, e la toppa precedente li aveva creati
entrambi.** La regola «si sospende chi sta sotto il minimo» non distingueva chi è sotto perché
il sito è a corto da chi è sotto perché chiede poco. Il secondo non è affamato da nessuno:
portarlo a zero non libera niente per nessuno. Da lì l'oscillazione — sospendi, il limite va a
zero, il limite a zero riporta la domanda al massimo, il massimo la fa rientrare, si
ricomincia — su un sito **vuoto**, con 350 kW liberi. Adesso si sospende solo per scarsità:
quota sotto il minimo **e** sotto la domanda. I sei scenari di `PIANO_POTENZA.md` §8 danno
numeri identici a prima, che era la prova richiesta: la regola nuova non cambia i casi
ordinari, toglie solo una sospensione inutile.

D-4 si è chiuso a monte e non nell'allocatore: `max_kw` è obbligatorio in §4.2, quindi un
`plugged` che non ce l'ha viene rifiutato da `vs_cp_proto` e non apre nessuna sessione.
Metterci una pezza nell'allocatore avrebbe voluto dire decidere noi cosa può prendere un
hardware che non l'ha detto — esattamente lo split che §7.2 vieta.

**Tre test esistenti codificavano il difetto, e vanno detti.** Due di `vs_power` asserivano che
un'auto che chiede 3 kW su un sito da 180 debba essere sospesa (era la specifica della toppa
precedente); una proprietà del sweep diceva «zero oppure almeno `MIN_CHARGE_KW`» e ora dice
«zero, almeno `MIN_CHARGE_KW`, **oppure esattamente ciò che ha chiesto**». E
`a_session_with_no_max_kw_starts_suspended_test` trattava come «segnalato onestamente» il
risultato che teneva l'auto a zero per sempre: resta, perché documenta la difesa del
connettore, ma con il commento corretto — dopo la correzione un payload del genere non arriva
più fin lì.

**Tre delle cinque prove del revisore sono state ri-puntate**, ed è la parte del lotto che
merita più attenzione. Quella di D-3 asseriva *prima* che il tick 1 sospendesse l'auto (cioè
osservava il difetto) e *poi* che il tick 2 fosse d'accordo: la prima asserzione non era un
invariante. Ora la prova gira il ciclo per sei tick e chiede un punto fisso, che è più forte.
Quelle di D-4 osservavano il difetto dentro l'allocatore, chiedendo che una sessione con
`max_kw = 0` ricevesse 350 kW — cosa che nessun allocatore deve fare: erano l'unico posto da
cui il difetto era ancora visibile, perché a quel punto era già successo. Adesso guardano dove
il difetto si chiude, cioè il payload. **Ognuna delle tre è stata rieseguita contro i sorgenti
non corretti e deve ancora fallire**: la regola seguita è che un'asserzione può spostarsi dove
il difetto viene davvero chiuso, ma non può essere indebolita.

**D-9 era il difetto più semplice e il più imbarazzante:** due funzioni che calcolano lo stesso
prodotto e agiscono in serie. Cowboy aspetta 90 s di silenzio, chiude il socket, e solo allora
il connettore ne aspetta altri 90. Tre heartbeat mancati ne facevano sei, e i commenti di
entrambi i moduli sostenevano che i due scadessero «sullo stesso orologio» — stessa durata, non
stesso istante. Adesso i novanta secondi sono un budget ripartito: 60 al socket, 30 alla
grazia. La grazia non poteva sparire — serve al blip di rete di §1, il socket che cade per un
FIN e non per silenzio — e trenta secondi bastano per una riconnessione che il contratto dà a
un secondo.

L'alternativa più fedele era distinguere le due morti del socket passando al connettore il
motivo dalla `terminate/3` di cowboy. Costa un messaggio nuovo sul confine più delicato del
passo 1, ed è annotata in `scelte_di_progetto.md` §15.5 come la strada da prendere se la
ripartizione si rivelasse rigida. Non ora: **il lotto 2 chiude difetti, non introduce
meccanismi.**

**Le dieci prove del revisore sono verdi e sono entrate nel commit**, rinominate
`vs_m2a_regression_tests.erl` con lo stub che le accompagna: da qui in avanti sono test di
regressione come tutti gli altri, e il nome lo dice. Ognuna delle tre ri-puntate porta una NOTE
che spiega cosa è cambiato e perché.

**Numeri.** Suite 274 test, 0 fallimenti — 261 del lotto 1, 11 di regressione (le dieci del
revisore, con quella di D-4 diventata tre: due rifiuti e un controllo positivo che tiene le
altre due dal passare per il motivo sbagliato), 2 per l'aritmetica di D-9. I sei scenari della
potenza: 150 / 130-50 / 80-50-50 / 100-100-100-50 / 127,5-127,5-45-50 / 7,5-7,5-0, identici.

## 7v. M2-A passo 4: il frame `session` e la pagina della sessione — 28 agosto

Branch `a/m2-session`, da `a/m2-fix2` (`ae848d7`) e **non da `main`** — vedi la verifica
bloccante 1 qui sotto. `vs_driver_proto` guadagna `session_frame/2` e `session_push/3`,
`vs_driver_ws` un campo di stato e il rinomino di `push_state/2` in `push/2`,
`vs_connector:build_snapshot/2` la chiave `battery_kwh`. Lato pagina: nove righe in `js/ws.js`,
`js/session.js` e `session.jsp` nuovi. Nessun contratto toccato: §5.2 si implementa com'è
scritta, e `SESSION_TICK_MS` era già in §10.

Con questo, chi carica vede la propria ricarica. Fino a ieri la sessione si intravedeva solo di
sbieco, come `power_kw` nella griglia della stazione.

### Le tre verifiche bloccanti

| Verifica | Misura | Esito |
|---|---|---|
| Baseline 274 test **su `main`** | `git ls-tree main` + `rebar3 eunit` sull'albero corrente | **fallita come premessa, sana come sostanza.** `main` è fermo a `54a03c4` e non ha **nessuno** dei merge di M2-A: niente `vs_cp_proto`, `vs_cp_ws`, `vs_power`, niente `vs_station_db_tests`. I 274 verdi esistono, ma su `a/m2-fix2`. Fermato e segnalato prima di scrivere una riga |
| Esiste un servlet per `session.jsp` | otto file in `backoffice/src/main/java/.../web/` | **no**, come il piano si aspettava. C'è solo `StationPageServlet` (`@WebServlet("/station")`, forward a `station.jsp`, mette in pagina `station` e `sessionScope.jwt`). Nessuna rotta `/session` |
| `battery_kwh` non è già nello snapshot | `build_snapshot/2` letto prima di toccarlo | **confermato**: la sotto-mappa aveva `user_id`, `vehicle_id`, `started_at`, `energy_kwh`, `soc_pct`, `max_kw`, `limit_kw`. Nessun doppione da creare |

**Sulla prima.** Non è «i merge sono andati male»: è che non sono mai stati fatti. La sostanza
che il controllo protegge — una base M2-A completa e verde — c'era, solo su un altro ramo e con
il lotto 2 ancora non committato. Le due decisioni sono state chieste e prese: committare il
lotto 2 (`ae848d7`) e ramificare da lì, e chiedere a B il servlet gemello.

### Catena dei chiamanti, cercata prima di toccare il codice

| Funzione | Chiamanti trovati | Conseguenza |
|---|---|---|
| `vs_connector:build_snapshot/2` (+`battery_kwh`) | `vs_station_mgr:connector_entry/1` → `build_state/1`; `vs_cp_proto:limit_kw/2` (legge `limit_kw`); `vs_power:demand_kw/3` (`max_kw`, `soc_pct`, `limit_kw`), `demands/1` (`started_at`), `is_live/1` (`session` è una mappa); `vs_driver_proto:wire_connector/2` (`user_id`); 15 punti nei test | **additiva**: ogni lettura nomina la sua chiave. Cercate anche le asserzioni su mappa intera (`?assertEqual(#{`) per escludere una rottura silenziosa: nessuna riguarda la sotto-mappa `session` |
| `vs_driver_ws:push_state/2` → `push/2` | privata, due chiamanti nello stesso modulo (`{station_state, _}` e `state_tick`) | cambia il tipo di ritorno in `{Frames, State}`, perché ora aggiorna `last_session`. Nessun chiamante fuori dal modulo |
| `vs_driver_ws:websocket_info/2` | cowboy | due frame invece di uno, dallo stesso snapshot e nella stessa `send` |
| `vs_driver_proto` (+ due funzioni) | `vs_driver_ws` | additiva |
| `js/ws.js` (+ caso `session`) | `station.js`, `session.js` | additiva. **`station.js` non registra `onSession`**: una pagina della stazione aperta dal proprietario di una sessione riceve il frame e lo lascia cadere, senza differenza visibile |

### Verificato — girato davvero

- **Suite: 286 test, 0 fallimenti** (`rebar3 eunit`, mai `--app`). 274 di baseline + 12 nuovi:
  11 su `vs_driver_proto` (gli otto campi del contratto e nessuno in più, il silenzio per chi
  non carica, la proprietà del frame, `suspended` dal connettore, `complete` dal SoC e non dalla
  potenza, il salto dell'ETA, i tre casi di `null`, il frame `closed` e il silenzio dopo, il
  giro attraverso jsx, e la non-fuga di `battery_kwh` nel frame `state`) e 1 su `vs_connector`.
  Tutti su mappe costruite a mano: nessun manager, nessun connettore, nessun socket.
- **I due frame partono nella stessa `send`.** Sul nodo vivo, timestamp del socket driver:
  `09:17:39.691 state` / `09:17:39.691 session`, per venti tick di fila. Non è una coincidenza
  di arrotondamento: è la stessa lista di frame.
- **Energia e potenza avanzano ogni cinque secondi.** St. 2 / conn 5, veicolo 2, batteria 58
  kWh: `0.333 → 0.541 → 0.749 → 0.958 → 1.166 → 1.374 kWh` a 150 kW, un frame ogni 5 s.
- **L'ETA salta, misurato.** Con la sola auto a 150 kW: `eta = 1044 s` (soc 25 %). Una seconda
  auto si attacca sul conn 6 (50 kW su un sito da 180): il riparto scende a 130 kW e un tick
  dopo `eta = 1189 s` (soc 26 %). **+145 secondi in un tick**, con un punto di SoC *in meno* da
  fare. È P5 che si vede, ed è la ragione per cui non c'è smoothing. Nessun `SITE_POWER_KW`
  ritoccato: la stazione 2 è seminata a 180 kW contro 250 installati proprio per questo.
  Rifatto poi nel browser e letto sulla pagina — vedi sotto.
- **`suspended` dal vivo.** `SITE_POWER_KW` di st. 2 portato a 10 con un override di compose
  (file di scratch, non committato): due auto, quota 5 kW a testa, sotto `MIN_CHARGE_KW`.
  Il frame: `phase=suspended power=0 kW eta=null`. La vittima è l'ultima arrivata, come vuole
  `victim/1`.
- **Il frame finale, per due strade diverse.** (a) `stop_session` dal canale driver → la
  stazione manda `stop` → `cp.js` stacca il cavo e riporta il totale → nell'istante in cui il
  connettore torna `free` arriva `phase=closed energy=5.97 kWh soc=32%`, e **niente dopo**.
  (b) `--unplug-at-soc 24`, cioè il cavo che esce da solo senza che il driver tocchi niente →
  `phase=closed energy=1.083 kWh soc=24%`, di nuovo una volta sola.
- **Il canale colonnina regge il riavvio.** Le stazioni sono state riavviate due volte durante
  le prove e l'emulatore ha riconciliato da solo ogni volta (§6): `boot` + `plugged` con il
  cumulativo, sessione riaperta senza intervento.
- **Il rendering di `js/session.js`** contro i payload reali dei sei casi, sotto un DOM di
  prova: placeholder senza sessione, «Charging / 130.0 kW / 5.970 kWh / 18 min», «Paused» con
  la spiegazione al posto della parola, «Charge complete», «Session ended» con potenza e stima
  a `—` e i totali al loro posto, e il socket che cade (sotto).

### Nel Chrome vero — cosa è stato visto con gli occhi

Tutto il blocco qui sopra è misurato **sul filo**: un client WebSocket Node che parla il
contratto e stampa i frame uno per uno. Il giro nel browser è arrivato dopo, sulla pagina
statica servita da `python -m http.server` (stesso `<style>`, stesso markup e gli stessi
`js/ws.js` e `js/session.js` della JSP, con le tre costanti di `jwt.md` §2 messe a mano).
Distinguere le due cose è il punto di questa sezione.

- **Card `charging`, vista**: connettore #5, badge *Charging*, barra del SoC, potenza, energia
  ed ETA che avanzano ogni cinque secondi, pastiglia *live*. La prima lettura è caduta dentro
  la rampa del limite (≈77 kW → «40 min»), che è la risposta giusta: l'ETA insegue il contatore
  e non lo smussa.
- **Card `suspended`, vista**: badge *Paused*, `Power 0.0 kW`, `Energy 0.000 kWh`,
  `Estimated time left unavailable`, e la nota ambra al posto della parola. **Con l'energia
  ferma e il Time che continuava a scorrere** — che è la dimostrazione visiva di §7.1: la
  pagina fa scorrere l'orologio, non il contatore.
- **La fase `suspended` ha tenuto per un'ora esatta**, ~720 frame consecutivi a
  `power=0 eta=null`, senza un solo rimbalzo. È il D-3 del lotto 2 (si sospende solo per
  scarsità) confermato dal vivo su una finestra che i test unitari coprono per sei tick.
- **Card `closed`, vista**: *Session ended*, potenza e stima a `—`, i totali al loro posto.
- **Il reset del reconnect, verificato per via indiretta ma conclusiva**: `docker stop` +
  `docker start` di `station2` e la sessione è ricomparsa con il **Time ripartito da zero**.
  Il socket è caduto davvero e la card si è svuotata per la durata del riavvio — troppo breve
  per coglierla a occhio, ma il cronometro azzerato lo dimostra. *Nota metodologica:* il
  throttling «Offline» di DevTools **non** chiude i WebSocket già aperti, quindi non serve come
  prova; l'unico modo è far cadere il socket sul serio.
- **Il salto dell'ETA, letto sulla pagina**: `18 min` → `21 min` in **un solo frame**, cinque
  secondi l'uno dall'altro, con il SoC fermo al 23 %. Sul filo: `eta 1072 s` a 150 kW,
  `eta 1237 s` a 130 kW.

### La rampa non è smoothing, e la differenza è stata misurata

Al primo tentativo il salto è arrivato in **due** frame (`15 min → 16 min → 18 min`), e la
domanda giusta era se ci fosse uno smoothing nascosto. Non c'è, e la prova è in due pezzi.

**Primo:** l'allocatore si muove in un colpo solo. Al `plugged` della seconda auto,
`allocated_kw` passa **150 → 180 in un unico push** e il `set_limit(130)` parte subito. Ciò che
sale gradualmente è il **contatore**, perché `ws-chargepoint.md` §5 concede alla colonnina
`LIMIT_APPLY_SECONDS` (§10, 5 s) per onorare un limite nuovo, e l'emulatore interpola su quella
finestra proprio per non far sembrare lo scenario migliore di com'è. L'ETA insegue il contatore
istante per istante, senza memoria del valore precedente.

**Secondo, ed è la prova decisiva:** rifatta la scena con `--limit-apply 0` — cioè con una
colonnina che applica il limite di scatto — il salto è tornato in **un frame solo**, `18 → 21
min`. Se ci fosse uno smoothing da qualche parte, quel parametro dell'emulatore non avrebbe
potuto toglierlo.

### La riga scritta, verificata a tre voci

Quattro sessioni chiuse nel giro finale (righe 18-21), **una riga per sessione, nessun
doppione**, e per ognuna i tre numeri coincidono:

| Riga | Frame `closed` | Contatore dell'emulatore | `sessions.energy_kwh` |
|---|---|---|---|
| 21 (conn 5, utente 2) | `3.986 kWh` | `final energy_kwh = 3.986` | `3.986` |
| 18 (conn 6, utente 1) | — (non è il driver della pagina) | `final energy_kwh = 12.042` | `12.042` |

La riga **18 è la prova dell'offset**: la sessione era nata al riavvio delle 10:43 ed è vissuta
23 secondi, ma porta **12.042 kWh** — un'ora di ricarica erogata *prima* di due spegnimenti
della stazione, restituita dall'emulatore con il `plugged` della riconciliazione (§6) e non
contata due volte. Il totale non è mai risultato superiore al contatore, che era la condizione
per fermarsi.

**Un artefatto onesto da mettere agli atti:** su quella riga `started_at`/`ended_at` coprono 23
secondi mentre l'energia ne copre sessanta minuti. Una stazione che riparte perde la sua
sessione e §6 le restituisce **l'energia, non l'istante di inizio**; la riga registra quindi la
sessione post-riavvio. Non tocca il conto — `BillingService.cost/3` prezza energia e secondi di
overstay, mai le due date — ma la durata di una sessione che ha attraversato uno spegnimento
non è quella vera, e chi leggesse `ended_at - started_at` come tempo di ricarica sbaglierebbe.

### Un difetto trovato in revisione, che nessuna delle prove copriva

Tutte le prove del rendering davano frame a una pagina connessa. Nessuna faceva **cadere il
socket**, ed è lì che stava il buco: se la ricarica finisce mentre la pagina è disconnessa — cioè
esattamente ciò che è successo due volte oggi, riavviando `station2` — il frame `closed` va a un
socket che non esiste più, il socket nuovo riparte con `last_session` vuoto, e a un driver senza
sessione **non si manda niente**. Nessun frame sarebbe mai arrivato a dire che era finita: la
pagina sarebbe rimasta su «Charging, 130 kW» con il cronometro che correva, sopra una sessione
chiusa da minuti.

È la deriva che §7.1 esiste per impedire, in una pagina il cui commento in testa dichiara di
obbedirvi. `station.js` non ce l'ha solo perché §3 spinge un `state` a ogni `join`, e per §5.2
quella garanzia non esiste.

Corretto lato pagina, tre righe: appena il canale non è `online`, `session.js` butta ciò che ha
in mano e torna al placeholder. La cura lato server sarebbe stata peggiore — un frame di zeri
riporta l'ambiguità che si era tolta, e far sopravvivere `last_session` alla morte del socket
vuol dire uno stato per utente sulla stazione, cioè la sessione lato server che §7.5 non ha.
Motivazione per esteso in `scelte_di_progetto.md` §16.6; il caso è ora nella prova di rendering.

### Una scelta di formato, presa guardando l'output

La stima usciva come `18:12`, che un lettore prende per un'ora del giorno. Ora è scritta a
parole e arrotondata al minuto (`18 min`, `1 h 22 min`): il secondo è rumore su un numero che è
dichiaratamente advisory e che salta. Il tempo trascorso resta a `mm:ss`, perché lì è un
cronometro.

### Non provato — e perché

1. **`session.jsp` non è mai stata renderizzata da Tomcat**, perché nessun servlet la serve. È
   committata pronta; il rischio residuo è un errore JSP che solo il compilatore di pagine
   troverebbe. Lo `<style>` e il markup sono però esattamente quelli girati nel browser sulla
   pagina statica, e la parte JSP è tre righe di taglib più il blocco di `jwt.md` §2 copiato da
   `station.jsp`.
2. **La barra del SoC non è stata guardata a percentuali diverse.** È stata vista disegnata,
   ma non c'è una lettura fatta apposta a 0 %, 50 % e 100 % per confermare che la larghezza
   segua. Il calcolo è ritagliato in `[0, 100]` ed è provato dal DOM di prova, non dall'occhio.
3. **`SESSION_TICK_MS` non viene letto** (scelte §16.1). Finché il default coincide con quello
   di `STATE_TICK_MS` non si vede; cambiarlo non produrrebbe alcun effetto.
4. **`overstay` e `complete` non sono stati visti dal vivo.** Il primo è M4. Il secondo
   richiede un'auto che arrivi al 100 %, cioè una ventina di minuti di emulatore: è provato in
   EUnit, sui tre casi che contano (taper al 94 % → `charging`, 100 % → `complete`, 100 % con
   il connettore sospeso → `complete`), e nel browser solo attraverso il DOM di prova.
5. **Lo svuotamento della card alla caduta del socket non è stato colto a occhio**, perché dura
   i due secondi del riavvio: è dimostrato dal cronometro ripartito da zero, non da un
   fotogramma. Il throttling «Offline» di DevTools non serve come prova — non chiude i
   WebSocket già aperti.
6. **Effetti sull'ambiente vivo.** `station1` e `station2` sono state ricostruite dal codice di
   questo passo (station2 era rimasta al lotto 1). Le prove hanno prodotto le righe sintetiche
   **13-21** in `sessions` per gli utenti 1 e 2, come le precedenti, tutte con `cost_cents`
   NULL perché il back office non era in piedi; `station2` è stata riavviata cinque volte, due
   delle quali con un `SITE_POWER_KW` a 10 che **non** è nel compose committato. Alla fine
   `docker compose down`: nessun container e nessun emulatore lasciati in giro.

## 7w. M2-A passo 5: il riaggancio del socket colonnina e l'emulatore dei driver — 28 agosto

Branch `a/m2-load`, da `a/m2-session` (`2c6a2a4`, passo 4 committato davvero). Due lavori in un
giro, in quest'ordine perché il primo è la premessa del secondo: un difetto che si innesca
proprio sotto carico avrebbe reso illeggibile ciò che le prove di carico trovavano.

`vs_cp_proto` guadagna `handle_info/2` e sei chiavi di sessione, `vs_cp_ws` due clausole di
`websocket_info/2`; `src/emulator/driver.js` è nuovo. Nessun contratto toccato.

### Le tre verifiche bloccanti

| Verifica | Misura | Esito |
|---|---|---|
| Baseline 286 test | `rebar3 eunit` (mai `--app`) su `2c6a2a4` | **286 test, 0 fallimenti**. Confermata |
| Il connettore riparte davvero, e il registro guarisce | `exit(Pid, kill)` sul compose, `lookup_pid/1` prima e dopo | **sì**. Nella riproduzione pre-correzione: `<10252.333.0>` ucciso, `lookup_pid/1` un secondo dopo risponde `<10251.400.0>`. `vs_connector_sup` è `transient` e il `connector_up` dell'`init` del connettore fa guarire il registro senza che nessuno interroghi niente |
| Il difetto esiste **come descritto** | riprodotto sul compose prima di scrivere una riga | **il difetto sì, il meccanismo del piano no.** Vedi sotto: è la scoperta principale di questo passo |

### Il difetto riprodotto — e il piano corretto

`PIANO_LOAD.md` diceva che i `meter` «continuano ad arrivare a un pid morto» e spariscono in
silenzio. **Non è così.** `vs_cp_proto` non ha mai memorizzato il pid (scelte §11.10, con un
test che lo asserisce): il connettore si rilegge a ogni evento, e il registro guarisce in meno
di un secondo. I `meter` arrivano al connettore **nuovo**.

Quello che succede davvero, osservato:

```
connector 3: charging, user 12, vehicle 88, 0.42 kWh, 150 kW      <- prima
<kill>
connector 3: free, 0.0 kW                                          <- 1 s dopo, e per sempre
connector 3: meter for a connector with no session (state free)    <- una ogni 5 s
```

L'emulatore intanto è arrivato a **1,878 kWh a 150 kW**, la stazione ha mostrato il connettore
`free` per tutto il tempo, e in `sessions` **non è comparsa nessuna riga**: l'`unplugged` finale
cade su un connettore inattivo e §4.4 lo ignora. In più `#data.cp` del connettore nuovo è
`undefined`, quindi `send_cp/2` è un no-op e **nessun `set_limit` e nessuno `stop` può più
raggiungere l'hardware**.

Il sintomo è quello del piano; il meccanismo è peggiore, perché il difetto lascia tracce che
sembrano diagnostiche e non lo sono. `PROGRESS.md` §7p («Non provato — e perché») lo aveva già
annotato **correttamente** al passo 1: «il `meter` successivo finisce nel log "meter senza
sessione" invece che nel vuoto». Il piano lo aveva riscritto peggio di come era già scritto qui.

### Il comportamento dopo, sulla stessa prova

```
charge point channel: connector 3 (<0.136.0>) died under a live socket (killed)
                      - reattaching in 500 ms
charge point channel: connector 3 is back as <0.225.0> - reattached
charge point channel: connector 3 reconciled to status available,
                      re-announcing vehicle 88 with 0.75 kWh
connector 3 walk-in session for user 12
```

**501 ms** fra il `DOWN` e il riaggancio. La sessione riappare con l'energia che il contatore
aveva; la potenza torna a 150 kW, quindi il `set_limit` interinale ha davvero raggiunto
l'hardware; e l'emulatore non se ne accorge — il suo log non ha un buco.

Ciclo completo, con l'auto che stacca da sola dopo il riaggancio:

```
final energy_kwh = 2.416 (soc 26%, soc reached 26%)     <- l'emulatore
session 1 written: connector 3, user 12, 2.416 kWh      <- la stazione
id=1  user_id=12  connector_id=3  energy_kwh=2.416      <- MySQL
```

Prima: 1,878 kWh erogati, zero righe. Dopo: 2,416 kWh erogati, 2,416 kWh fatturati, una riga.

### Catena dei chiamanti, cercata prima di toccare il codice

| Funzione | Chiamanti trovati | Conseguenza |
|---|---|---|
| `vs_connector:attach_cp/2` | in produzione **uno solo**, `vs_cp_proto:attach_to/2` (dal `boot`); 21 punti nei test di `vs_connector`/`vs_m2a_regression` | un chiamante nuovo, il riaggancio. Il connettore **non distingue i due casi** e va bene così: la clausola sta in `handle_common`, valida in ogni stato, e cancella la grazia in entrambi |
| `vs_station_mgr:lookup_pid/1` | `vs_claim_client:443`, `vs_station_mgr:reallocate/1` (interno), `vs_cp_proto:connector/1` | un chiamante in più sullo stesso percorso, stessa lettura sporca. Nessun cambio di firma |
| `vs_cp_proto:new/1` | `handshake/2`, `vs_cp_proto_tests:81`, `vs_m2a_regression_tests:402` | sei chiavi additive. **Ha rotto un test**, non per la firma ma per un confronto di mappa intera — vedi sotto |
| `vs_cp_proto:handle_text/2` | `vs_cp_ws:websocket_handle/2` | firma invariata; cambia solo la sessione che restituisce |
| `vs_cp_ws:websocket_info/2` | cowboy, più 4 chiamate nei test del trasporto | due clausole nuove, **sopra** il catch-all. Sotto sarebbero diventate una riga di debug e il socket sarebbe rimasto attaccato a un processo che non c'è più |
| `vs_cp_stub:attach_cp/2` (test) | `vs_cp_proto` attraverso `conn_mod` | registra una tupla a tre invece che a due, perché «a **quale** connettore si è attaccato» è tutta la domanda del riaggancio. Due asserzioni aggiornate |

**Il test rotto, e perché è servito.** `a_frame_with_no_request_id_is_dropped` faceva
`?assertEqual({[], booted_session()}, handle(Bin, booted_session()))`: due sessioni costruite
separatamente, che ora differiscono per il riferimento del monitor. Corretto confrontando la
sessione **con sé stessa**, che è anche ciò che il test voleva dire — «non è cambiato niente»,
non «è uguale a un'altra istanza».

### Verificato — girato davvero

- **Suite: 298 test, 0 fallimenti** (`rebar3 eunit`, mai `--app`). 286 di baseline + 12 nuovi:
  10 sul riaggancio in `vs_cp_proto` e 2 sul trasporto in `vs_cp_ws`. I dieci fanno nascere un
  processo vero da monitorare invece di sintetizzare il `DOWN`: il monitor **è** il meccanismo
  in prova, e un messaggio scritto a mano proverebbe solo che il codice sa leggere una tupla.
- **Il difetto prima e dopo**, sopra, sul compose con sette container.
- **`--self-test` dell'emulatore driver**: rifirma i claim di `sample-tokens.md` §1 e produce
  la fixture pubblicata **byte per byte**. È la prova che i token che manda sono quelli che
  firmerebbe Tomcat, non qualcosa che la stazione accetta per caso.

#### Scenario 1 — contesa sullo stesso connettore

| driver | accettate | rifiutate | tempo max | media |
|---|---|---|---|---|
| 20 | 1 | 19 `ALREADY_HELD` | 21 ms | 16 ms |
| 50 | 1 | 49 | 23 ms | 16 ms |
| 100 | 1 | 99 | 32 ms | 17 ms |
| 200 | 1 | 199 | 68 ms | 33 ms |
| 500 | 1 | 499 | 100 ms | 48 ms |

Il conteggio chiude esatto a ogni riga, senza avanzi, e la stazione conferma: **un** connettore
`held`, quello del vincitore. Il massimo cresce all'incirca linearmente con N, che è la firma
attesa dell'attore: le N richieste per quell'outlet sono N messaggi in **una** casella, servite
una alla volta nell'ordine di arrivo. Nessun lock, e nessuno che ne veda uno.

#### Scenario 2 — un veicolo, una prenotazione in rete

Lo stesso `vehicle_id` su cinque connettori di due stazioni, nello stesso istante: **1 accettata,
4 `NO_CLAIM`**, massimo 5 ms, media 5 ms. È l'unico scenario che attraversa il coordinatore, e
la distinzione fra i due rifiuti è quella che `ws-driver.md` §4.1 tiene separata apposta:
`ALREADY_HELD` lo alza il connettore («questo outlet è preso»), `NO_CLAIM` il coordinatore («il
tuo veicolo è impegnato altrove, e nessun altro connettore ti aiuta»).

Ripetuto **15 volte di fila** con veicoli diversi: 15 su 15 esatte.

#### Scenario 3 — carico sostenuto

10 driver su due stazioni, 150 secondi, mentre due colonnine erogano.

| | |
|---|---|
| richieste | 5620 |
| accettate | 2904 (1452 `reserve` + 1452 `cancel_reservation`) |
| rifiutate | 2716 `ALREADY_HELD` |
| tempo di risposta | **max 62 ms**, media 8 ms |
| connettori `held` alla fine | **0** su entrambe le stazioni |
| crash / supervisor report | **0** su tutti e cinque i nodi |

Il conto chiude: 4168 `reserve` = 1452 accettate + 2716 rifiutate, e 1452 `cancel` tutte
accettate. Le due colonnine hanno erogato per tutta la corsa senza interruzioni.

Memoria (`erlang:memory(total)`, campionata ogni 25 s):

```
station1  58 864 KB → 60 323 KB (picco) → 59 453 KB     processi 151 → 156 → 150
station2  57 391 KB → 58 598 KB (picco) → 57 744 KB     processi 150 → 155 → 150
```

Cresce del 2,5 % con i socket aperti e **torna alla base** quando si chiudono. Non cresce senza
fermarsi.

#### La sonda di proprietà

Un carico di driver anonimi non può mostrare le due cose riservate a chi **possiede** una
sessione. Con un `cp.js` che eroga sul connettore 3 e il driver del veicolo 88:

```
stranger sees session frames: no        <- §5.2, solo al proprietario
owner sees session frames:    YES       <- phase charging, 150 kW, 7.414 kWh, soc 33%, eta 933s
stranger stop_session:        NOT_YOURS <- §4.3
owner stop_session:           ACK
```

e la riga scritta porta `7.414 kWh`, identica al `final energy_kwh` dell'emulatore.

### Difetti trovati sotto carico e **non** corretti

Uno solo, e non è del carico: è la conseguenza del 4404 della resa.

**`cp.js` tratta il 4404 come fatale e termina** invece di riconnettersi col backoff. Il piano
assumeva il contrario («lascia riconnettere la colonnina col suo backoff»), e per il nostro
emulatore su quel percorso l'assunzione è falsa. Non corretto qui: `cp.js` è fuori perimetro, e
la scelta fra cambiare il codice della resa e insegnare a `cp.js` a distinguere il 4404
dell'handshake da quello a metà vita è una decisione di contratto, che è di Caleb. Il percorso
è quasi irraggiungibile — richiede che il supervisore abbia rinunciato del tutto — e in nessuna
prova è stato imboccato.

Il resto delle prove non ha prodotto difetti: zero crash, zero report di supervisore, zero
`ERROR REPORT` su stazioni e coordinatori, in tutte le corse.

### Non provato — e perché

- **Il ramo della resa (4404) non è stato eseguito su un socket vero.** Ha i due test unitari
  — cinque tentativi a vuoto → `{close, 4404, ...}`, e la corsa dal trasporto → `[{close, 4404,
  <<>>}]` — ma per vederlo sul compose bisognerebbe far arrendere `vs_connector_sup`, cioè
  cinque crash in dieci secondi, e a quel punto la stazione ha un problema più grande di questo.
- **Nessun `plugged` di veicolo sbagliato attraverso il riaggancio.** Il replay passa dal
  percorso ordinario, quindi `not_your_reservation` è raggiungibile in teoria; in pratica il
  connettore rinato è `free` e non ha hold, quindi non può succedere finché la prenotazione non
  sopravvive al riavvio — e §6 dice che non deve.
- **Il limite vero di cowboy/ranch non è stato trovato.** 500 driver simultanei su una stazione
  passano senza degradare oltre i 100 ms; il default di ranch è 1024 connessioni per listener e
  non ci si è arrivati. La premessa «le stazioni reggono M driver simultanei» è verificata fino
  a 500, non oltre.
- **Nessuna prova con il back office acceso.** I token li firma l'emulatore, quindi Tomcat non
  serviva e non è stato avviato; la fatturazione delle righe scritte durante le prove non è
  stata guardata.
- **Docker Desktop si sospende da solo** — pause fino a **ventidue minuti** fra una corsa e
  l'altra. Si vedono come buchi nel ping da tre secondi della stazione. Una da 38 secondi è
  caduta dentro la riproduzione del difetto, fra il `plugged` e il primo `set_limit`: la corsa
  vale lo stesso, perché il kill e le due istantanee sono successivi alla ripresa e
  l'osservazione è di stato e non di tempo. **Tutti i tempi delle prove di carico** sono stati
  verificati con quel controllo eseguito dopo la corsa, e nessuno attraversa una pausa.
- **Il seed di prova non è nel repository.** `users` e `vehicles` sono tabelle di B, popolate
  dalla registrazione, e `schema.sql` non le semina. Le due righe che servono a un `plugged`
  sono documentate in `src/emulator/README.md` invece di essere aggiunte a un contratto che non
  è nostro.

## 7x. Due ritocchi a `ws-chargepoint.md`: `charging_seconds` e il codice della resa — 29 agosto

Branch `a/m2-cp-touchups`, da `a/m2-load` (`cccf8f1`, passo 5 committato davvero — verificato con
`git log` prima di ramificare). Questa volta **il contratto si modifica**: `ws-chargepoint.md` è
di A da entrambi i lati, quindi niente PR, ma testo e implementazioni cambiano nello stesso
commit. Nessun meccanismo nuovo: un campo facoltativo in più, un numero corretto.

### Le tre verifiche bloccanti

| Verifica | Misura | Esito |
|---|---|---|
| Baseline 298 test | `rebar3 eunit` (mai `--app`) su `cccf8f1` | **298 test, 0 fallimenti**. Confermata |
| Dove sta davvero il `4404` della resa | `grep` su tutto il repo, poi lettura del commit | **c'è, ma non dove il piano lo cercava.** Il numero è in `vs_cp_proto:retry/2`, e il commento che motiva la scelta sbagliata è lì e nel doc di modulo, **non** in `vs_cp_ws` — che ha solo la citazione del 4404 di handshake, che resta giusta. Corretto dove sta |
| Nessun test difende il comportamento sbagliato | `grep 4404` e `grep started_at` nei test | **due test lo difendevano** (sotto). Sul `started_at` di una sessione adottata: **nessuno**, e l'unica asserzione vicina (`ended_at >= started_at`, `vs_connector_tests`) regge la retrodatazione |

### I due test che difendevano il difetto

`vs_cp_proto_tests:five_attempts_with_no_connector_close_4404/0` e `ws_give_up_closes_the_socket/0`
asserivano `4404` sul percorso della resa — uno sul protocollo, uno sul trasporto. Segnalati e non
aggiustati in silenzio: il numero **è** il contenuto di quel ramo, perché è l'unica cosa che
l'apparecchiatura dall'altra parte può leggere, quindi un test che lo asserisce non è un dettaglio
d'implementazione ma la codifica della scelta. Rinominati in `..._1012`, con il commento che dice
cosa asserivano prima e perché era sbagliato — che è il solo modo perché la prossima persona non
lo rimetta a posto «com'era».

### Catena dei chiamanti, cercata prima di toccare il codice

| Funzione | Chiamanti | Conseguenza |
|---|---|---|
| `vs_connector:session_from/3` | `adopt/3`, chiamata dai **tre** ingressi in `charging`: `free`, `held`, `out_of_service` | Cambia il **dato**, non il percorso: nessuno dei tre è stato toccato, e solo un `plugged` di riconciliazione porta una durata |
| `vs_cp_proto:authorise/5` | `with_account/4` ← `plugged/2` ← l'evento `plugged` **e** `reconcile/2` | Il replay del riaggancio passa dalla stessa funzione, ed è il motivo per cui la durata stantia va tolta lì (sotto) |
| `vs_cp_proto:retry/2` | `handle_info(cp_reattach, ...)`, due clausole | Cambia un numero e il commento che lo motivava |
| `#session.started_at` (letto) | `settle/1` (la riga), `build_snapshot/2` → `vs_driver_proto` (§5.2) e `vs_power:victim/1` | Tre conseguenze, tutte volute — sotto |
| `cp.js` | — | **nessuna modifica**, che è l'argomento del ritocco 2 |

**Il punto che il piano dava per scontato e che non lo era.** «Solo l'adozione deve cambiare» è
vero come *comportamento*, non come *struttura*: la scena che conta — riavvio della stazione —
**non** passa da `out_of_service` ma da `free`, perché una stazione che riparte lo fa con processi
connettore nuovi, che nascono liberi. Confermato dal log della prova: `connector 3 walk-in session
for user 12`. Legare la correzione strutturalmente a `out_of_service` avrebbe prodotto codice che
passa i test unitari e non corregge niente sul compose.

**Le tre conseguenze della retrodatazione, cercate e non subite.**

1. `vs_power:victim/1` sospende **l'ultimo arrivato**, ordinando per `started_at`. Una sessione
   adottata ora è anziana invece che appena arrivata: sotto scarsità viene sospesa **per ultima**
   invece che per prima. È il verso giusto — un'auto che carica da un'ora *è* arrivata prima di
   una attaccata un minuto fa — e la stabilità regge, perché `started_at` continua a essere
   scritto una volta sola e a non cambiare più.
2. La pagina del driver (`ws-driver.md` §5.2, campo `started_at`) mostra da quando si carica: dopo
   un riavvio diceva «da 23 secondi» a chi caricava da un'ora, adesso dice la verità. Il contratto
   del driver non cambia, cambia il valore che ci passa.
3. La riga su `sessions` — il difetto che si stava chiudendo.

### Verificato — girato davvero

**Suite.** `rebar3 eunit` senza `--app`: **307 test, 0 fallimenti** (298 + 9 nuovi — quattro sul
campo al confine del filo, uno sul replay che lo lascia cadere, quattro sul `started_at` delle tre
porte).

**Le due durate, sulla stessa scena.** Emulatore su conn 3, carica, `docker restart station1`,
sessione riadottata, stacco a SoC raggiunto. Immagine ricostruita fra le due corse, stessi
parametri, energia finale a un millesimo di distanza:

| | `started_at` → `ended_at` | durata | energia | kW impliciti |
|---|---|---|---|---|
| **prima** (riga 1) | 13:56:54 → 13:57:59 | **65 s** | 5.956 kWh | **329.9** su una presa da 150 |
| **dopo** (riga 3) | 08:18:20 → 08:20:48 | **148 s** | 5.957 kWh | **144.9** |

Il `started_at` di dopo è **l'istante in cui il cavo è entrato** (log dell'emulatore:
`08:18:20.465 plugged … cable in`), al secondo. I 144.9 invece di 150 sono le due rampe da cinque
secondi (partenza e ripartenza) più i tre secondi di socket giù: fisicamente coerenti. La
riconnessione ha portato `charging for 88s`, e il cavo era entrato 88 s prima.

**La controprova.** Sessione ordinaria, nessun riavvio, stessi parametri prima e dopo:

| | durata | energia | kW impliciti |
|---|---|---|---|
| **prima** (riga 2) | 43 s | 1.791 kWh | 149.9 |
| **dopo** (riga 4) | 43 s | 1.791 kWh | 149.9 |

Identica in ogni campo che non sia l'orologio a muro. E non è identica perché il campo non
arriva: l'emulatore lo manda anche al primo `plugged` (`charging for 0s`), e la stazione lo legge
come «niente da dichiarare» — quindi la controprova prova la cosa giusta, cioè che il percorso
ordinario è inerte **con** il campo sul filo.

**Il ritocco 2, prima e dopo, su un socket vero.** `CP_REATTACH_TRIES` a 1 via `os:putenv` sul
nodo, `sys:suspend` sul supervisore dei connettori, connettore ucciso. È **la prima volta che quel
ramo gira su un socket vero**: il passo 5 lo aveva solo nei test unitari, e lo dichiarava.

* **prima** — stazione: `… did not come back in 1 attempts … - closing 4404`; emulatore: `the
  station refused connector 3 (4404): it does not belong to station 1` → **uscita con codice 2**.
  La sessione non viene mai riconciliata né fatturata.
* **dopo** — stazione: `… - closing 1012`; emulatore: `disconnected (code 1012); retrying in
  1000 ms` → si riconnette, riannuncia il cavo con `charging for 21s`, la stazione riadotta e la
  riga viene scritta (`session 5 written: connector 3, user 12, 2.417 kWh`, uscita 0). `cp.js` non
  è stato toccato: è la prova che il codice scelto dice quello che intende dire.

### Un difetto nuovo, trovato provando questo — e non corretto

Tenendo il supervisore sospeso **a tempo indefinito** (deterministico, ma non il caso vero),
l'emulatore riceve il `1012`, si riconnette come previsto, e sull'**handshake** trova il registro
ancora senza quel connettore: `4404`, e muore lo stesso. È lo stesso errore di P4 un gradino più
in là: `vs_station_mgr:lookup_pid/1` collassa in un unico `{error, unknown_connector}` tre
situazioni di cui **due sono temporanee** (manager non avviato; connettore senza pid in questo
istante) e una sola è permanente. Segnalato in `PROBLEMI_TROVATI.md` **P10** e in
`scelte_di_progetto.md` §18.2: tocca `vs_station_mgr`, che è fuori perimetro, ed è una terza
decisione di contratto. Col supervisore che riparte davvero — il caso vero — non si presenta, ed è
il motivo per cui la prova sopra è stata rifatta lasciandolo ripartire.

### Ragionato, non provato — e perché

- **I due residui del campo facoltativo** (`scelte_di_progetto.md` §18.1) sono *decisi* e coperti
  da test unitari, non osservati sul compose. (a) La copia del riaggancio non riporta la durata,
  perché è l'unico campo che invecchia: quel percorso torna al comportamento di prima. Nella prova
  E2E non si è visto perché lì è stata la **colonnina** a rimandare il `plugged`, con un numero
  fresco — che è il progetto, non un caso fortunato. (b) Guasti incatenati sullo stesso cavo: la
  seconda riga porta l'energia della fetta nuova e una durata che copre tutto il cavo, quindi le
  due righe si sovrappongono nel tempo. È il prezzo di tenere durata ed energia indipendenti, ed è
  stato pagato consapevolmente.
- **Una colonnina che non manda il campo** è coperta da tre test (assenza, zero, valore
  impossibile) e da tutta la suite preesistente, ma non da una prova E2E con un emulatore
  modificato apposta: l'unica colonnina che abbiamo ora lo manda sempre.
- **`history.jsp`** non è stata riaperta: la riga adesso è internamente coerente, ma vederla nella
  pagina richiede il login di B.
- **Il fuso.** Le date sopra sono UTC in MySQL e ora locale nei log dell'emulatore; le due corse
  cadono a cavallo della mezzanotte del 28/29 e i confronti sono fatti su durate, non su istanti.

## 7zb. P11: un test che misurava la macchina, e un conteggio che può mentire — 29 agosto

Segnalazione di B su cinque giri della suite (`src/contracts/risposta-per-A-m2a.md`): un giro con
`acquire_happy_path_test` rosso per `{badmatch, {error, no_claim}}`, e un giro che contava **274
test invece di 298**. Due difetti distinti. Report completo in `REPORT_P11.md`.

**Il totale della suite è N = 307**, misurato su 26 giri della suite completa (3 di baseline, 10
di riproduzione, 10 di chiusura più 3 di prova dello script), sempre identico.

**P11-A — chiuso.** Il file di test del claim client fissava `timeout_ms => 500` per la
`gen_server:call` verso il coordinatore. Il mock risponde in modo sincrono senza lavoro lento: se
500 ms non bastano è perché gli scheduler sono saturi, e il test finisce per misurare la macchina
invece del codice. Portato a 60000, con `wait_until` da 100 a 300 tentativi e l'`after` di
`holds()` da 1 s a 5 s — stessa famiglia, costo zero sul verde.

Una deviazione dal piano, misurata e ratificata: `rebar.config` dichiara `{dist_node, [{sname,
vs}]}` e il nodo di test **è distribuito** (`node() = vs@BaLo`), quindi
`no_coordinator_at_all_refuses_with_no_claim_test` non prende il `badarg` immediato che il piano
gli attribuiva — paga una risoluzione DNS/epmd che fallisce come `nodedown` dopo ~2,5 s. Con
60000 quel test sarebbe passato da 0,5 s a ~2,7 s contro i **5 s** del `?DEFAULT_TEST_TIMEOUT` di
eunit, e un test ucciso da eunit finisce fra i *cancelled*: avremmo fabbricato noi il difetto B.
Quel solo test tiene quindi un override esplicito a 500 ms, con il perché scritto accanto.

**Un terzo difetto, trovato per strada e corretto.** Il giro 1 della baseline è fallito su
`vs_connector_tests:an_adopted_session_is_dated_from_the_charging_seconds_test` (1 volta su 13).
L'asserzione `?assert(StartedAt =< Before - 3600000)`, con `StartedAt` calcolato dal connettore
come `now_ms() - 3600000`, equivale a chiedere che le due letture dell'orologio cadano nello
**stesso millisecondo**. Tetto spostato su `vs_time:now_ms() - 3600000`, cioè letto dopo il
fatto, come già facevano i due test gemelli dello stesso file. La proprietà asserita non cambia.

**P11-B — non riprodotto, ma reso rumoroso.** Dieci giri consecutivi col report surefire attivo:
307 ogni volta, e le liste dei singoli testcase identiche fra tutti e dieci. Non c'è quindi
niente da attribuire a nessuno. Quello che invece è stato **misurato** è come un giro rotto
riesce a sembrare verde, sabotando la suite apposta in tre modi diversi:

| rottura | totale | `failures` | coda |
|---|---|---|---|
| `setup/0` di una fixture solleva | **invariato** (307) | 0 | `, 22 cancelled` |
| `exit` nel processo di un test | **299** | 0 | `, 6 cancelled` |
| un `_test_()` solleva mentre eunit enumera | **286** | 0 | `, 5 cancelled` |

Tre lezioni: `0 failures` non vuol dire verde; il totale non è una costante della suite ma quanto
lontano eunit è arrivato a enumerarla; e il totale da solo non basta, perché il primo caso lo
lascia intatto. Da qui `src/scripts/eunit_check.sh`, che è verde **solo** se rebar3 esce 0 **e** il
sommario è esattamente `307 tests, 0 failures` — ancorato, così che qualunque coda `cancelled`
lo faccia fallire. Aggiornare quel numero è parte dell'aggiungere un test.

## 7zc. P10: l'handshake diceva «mai più» per un fatto che dura un secondo — 29 agosto

Il difetto lasciato aperto da §7x, chiuso. `vs_station_mgr:lookup_pid/1` collassava in un unico
`{error, unknown_connector}` tre situazioni — tabella ETS assente (manager non ancora su), riga
presente col pid a `undefined` (connettore fra la morte e il riavvio), riga assente (id non di
questa stazione) — di cui **solo la terza è permanente**. L'handshake della colonnina rispondeva
a tutte e tre col `4404` che §1 del contratto dichiara permanente, e su cui `cp.js` muore,
correttamente.

Adesso `lookup_pid/1` ne restituisce quattro (`{ok, Pid}`, `no_pid`, `no_manager`,
`unknown_connector`), l'handshake **ammette** i due temporanei e la risposta la dà il boot con
l'`accepted: false` di §3.1, che esisteva già: `reason` `"connector not ready"` per il
temporaneo, `"unknown connector"` per il permanente. `cp.js` non è stato toccato — di nuovo, è
l'argomento della scelta e non una comodità. Contratto aggiornato (§1 e §3.1) nello stesso
commit di codice e test.

Il chiamante che sarebbe morto: `vs_claim_client:revoke/2` aveva due sole clausole, `{ok, Pid}` e
`{error, unknown_connector}`. Una revoca arrivata durante il riavvio di un connettore avrebbe
prodotto `{error, no_pid}` → `case_clause` dentro `handle_info` → **muore il processo che tiene
tutti i claim della stazione**. Allargata a `{error, _}`, e riprodotta prima di correggerla:
rimettendo la clausola vecchia la suite non dice «1 rosso», dice `17 tests, 0 failures,
6 cancelled` — la firma di §7zb, cioè esattamente il giro che `rebar3 eunit` da solo avrebbe
fatto passare per innocuo.

**Suite: 311 test** (307 + 4), tre giri consecutivi verdi con `eunit_check.sh` aggiornato nello
stesso momento.

**E2E sul compose, la scena di §7x che era rimasta rossa.** Emulatore in carica su conn 3,
supervisore dei connettori sospeso con `sys:suspend` a tempo indefinito, connettore ucciso:
resa `1012` (2,5 s) → riconnessione → **handshake ammesso** (`no_pid`) → boot
`accepted:false (connector not ready)` → l'emulatore ritenta ~1/s per 45 s → `sys:resume`, il
supervisore rifà il connettore in **10 ms** → boot accettato, `plugged` con `charging for 76s` e
1.166 kWh già contati → sessione **riconciliata, non ricominciata** (`started_at` è l'ora del
primo cavo) → `EXIT=0`, riga 6 in `sessions`: 13:30:08 → 13:33:19, 5.957 kWh, 268 cent.
Controprova del permanente: emulatore su un connettore non configurato (9) → `4404`, morte
immediata, `EXIT=2`. Report completo in `REPORT_P10.md`.

## 7zd. P14 e P15: il claim smette di essere un ricordo del client — 29 agosto

I due difetti misurati nel pair 1 (`REPORT_M3A_VERIFICA` §6.1 e §6.2), chiusi. Una radice sola:
il claim vive in `vs_claim_client`, il **fatto** vive nel connettore (`#hold.claim_id`, poi
`#session.claim_id`), e quando una delle due metà moriva l'altra non se ne accorgeva.

### Le due verifiche bloccanti, prima di scrivere qualsiasi cosa

**Esiste un percorso che fa riadottare un `hold` a un connettore riavviato?** No, e cercato per
struttura: `#hold{}` è costruito in **un solo punto** (dopo un `acquire` riuscito), `held` si
raggiunge solo da lì, `init/1` parte `free` col campo a `undefined`, `free(enter)` e
`out_of_service(enter)` azzerano `hold` e `session`, e le due adozioni da hardware riagganciato
passano `undefined` come claim esplicitamente. Se fosse esistito, rilasciare sul `DOWN` sarebbe
stato sbagliato e tutto il disegno andava ripensato.

**Entrambi i chiamanti di `{granted, …}` chiamano dal processo del connettore?** Sì — sono i due
rami di `do_acquire/4`, unico chiamante `acquire/4`, invocata solo come
`(Data#data.claim_mod):acquire(...)` dentro `free({call, From}, {reserve, …})`, che è una
callback di `gen_statem`. Se anche uno solo avesse chiamato da un processo effimero il monitor si
sarebbe attaccato a quello e il claim sarebbe morto subito. **Provato, non solo letto**: un test
asserisce che il pid monitorato è quello del connettore.

### Il piano si sbagliava su un punto, e non di forma

Dava per scontato che il connettore avesse già i sei campi del contratto da ripresentare. Non li
aveva: `#hold.granted_at` è l'orologio **della stazione**, `#hold.expires_at` è il **lease**
(900 s) e non la scadenza del claim (960 s), e `#session` non aveva né l'uno né l'altro — due dei
sei campi mancanti del tutto. Il `ClaimExpiresAt` tornava da `acquire/4` ed era **solo loggato**;
il `GrantedAt` del coordinatore viveva solo dentro il client, e con il client moriva.

Ripresentare i valori locali sarebbe stato inventarli, e avrebbe rimesso lo skew fra orologi
dentro il confronto *oldest wins* che il PR di contratto del 24 agosto aveva eliminato. Scelta
presa consapevolmente (opzione A): `claim_mod:acquire/4` restituisce
`{ok, ClaimId, GrantedAt, ExpiresAt}` e il connettore tiene i due valori **del coordinatore**
accanto ai propri. **Il contratto sul filo non cambia** — `GrantedAt` era già sul filo — cambia
solo la giuntura interna fra connettore e claim_mod. Dettagli in `scelte_di_progetto.md` §20.4.

### Cosa fa adesso

**P15.** `handle_call({granted, …})` usa il `From` che ignorava: `erlang:monitor` sul chiamante,
`reference()` nel `#claim`. Un `DOWN` rilascia il claim verso il leader (`cancelled`, una delle
quattro parole di `claim.md` §3.3 — nessun atomo nuovo sul filo), lo toglie dalla mappa e lo
**logga a `notice`**. Ogni altra uscita dalla mappa demonitora con `[flush]`.

**P14.** `handle_continue(announce, …)` chiede: un cast `{claims_rebuild, self()}` a ogni
connettore vivo, letto dall'ETS del manager con la lettura sporca già consentita. Chi tiene un
claim risponde con un cast, in `held` **e in `charging`**. Nessuna chiamata sincrona in nessuna
delle due direzioni.

**La rete di sicurezza**, con il qualificatore che la rende vera: i claim scaduti non vengono
rinnovati e escono con un `warning`, ma **solo i confermati**. Un claim ripresentato porta la
scadenza copiata al momento della concessione, che diverge da quella vera per costruzione: senza
il qualificatore un client che riparte durante una sessione più vecchia di sedici minuti avrebbe
buttato il claim un tick dopo averlo ricostruito, gridando contro una stazione sana — cioè
rimettendo in piedi §6.1 per lo stato `charging`. Il warning non è mai scattato in tutta la
sessione E2E, che è come deve essere.

**Suite: 328 test** (315 + 13), tre giri consecutivi verdi con `EXPECTED_TESTS` aggiornato nello
stesso momento. E la prova che mordono, perché passare non basta: rotte le due correzioni
(`DOWN` reso un no-op, domanda del rebuild tolta), il modulo dà `19 tests, 0 failures,
3 cancelled` — la firma di §7zb, cioè il giro che `rebar3 eunit` da solo avrebbe fatto passare
per innocuo.

Un test che c'era si era **svuotato**:
`a_revocation_while_the_connector_restarts_does_not_kill_the_client_test` (§7zc) apriva la sua
finestra con `exit(ConnPid, kill)`, e da oggi quel kill fa sparire il claim prima che la revoca
conti qualcosa — verde, e senza toccare più il ramo per cui era stato scritto. Riscritto perché
il claim sopravviva al connettore, così che `revoke/2` incontri davvero il `{error, no_pid}`.

### Le stesse misure del pair 1, ripetute

Immagini ricostruite e container ricreati; `beam_lib:md5` host↔container identico su
`vs_claim_client`, `vs_connector`, `vs_claim_null` e `vs_coord_srv` (quest'ultimo invariato,
`c5393f49…`, lo stesso valore registrato dal pair 1).

| | prima (pair 1) | dopo |
|---|---|---|
| **P15** — connettore ucciso mentre `held` | claim rinnovato ogni 10 s **per sempre**, veicolo chiuso fuori dalla rete | claim fuori dalla mappa in **10 ms**, `notice` nei log, coordinatore aggiornato |
| il veicolo prova un altro connettore | `NO_CLAIM — your vehicle already holds a reservation elsewhere` | **`{ok, …}`** — prenota, 312 ms dopo |
| **P14** — `exit(whereis(vs_claim_client), kill)` con un `held` vivo | `who_do_you_hold` → `{holds, 1, []}` | riavvio in **2 ms**, e la **prima** `who_do_you_hold` risponde già col claim, `granted_at` originale incluso |
| poi `docker stop` del leader | coord2 ricostruisce con **ZERO claim**, e station2 **ottiene** lo stesso veicolo | coord2: «2 station(s) answered with **1 claim(s)**», «serving with **1 adopted claim(s)**», e station2 → **`vehicle_committed`**, connettore 5 resta `free` |

**Controprova sul percorso sano**, con gli emulatori veri sui due canali WebSocket: boot della
colonnina, prenotazione, cavo alle 17:24:59, carica a 150 kW, unplug a SoC 25. Riga **7** in
`sessions` (12 / 1 / 3, 17:24:58 → 17:25:43, **1.876 kWh**), esattamente il
`final energy_kwh = 1.876` stampato da `cp.js`; claim rilasciato, connettore `free`, coordinatore
a zero claim. E il canale driver intatto: 8 driver in contesa su un connettore, 1 accettato,
7 `ALREADY_HELD`, invariante chiusa, risposta massima 4 ms.

Durante la sessione la snapshot del connettore in `charging` **non conteneva alcun `claim_id`**,
né al primo livello né dentro `session`: il divieto di avvicinare il claim id al browser è
asserito sul sistema vivo, non promesso. Report completo in `REPORT_CLAIM_RIFLESSO.md`.

## 7ze. P13 e P12: il canale driver smette di dire «non è tuo» a un connettore che sta riavviando — 30 agosto

Il terzo e ultimo posto della famiglia di §7x/§7zc, chiuso. `vs_station_mgr:connector_pid/1`
collassava in un unico `{error, unknown_connector}` due situazioni — riga col pid a `undefined`
(connettore fra la morte e il riavvio del supervisore) e riga assente (id non di questa
stazione) — di cui **solo la seconda è permanente**. Il canale driver rispondeva a entrambe
`UNKNOWN_CONNECTOR`, «connector does not belong to this station», di un connettore che è di
questa stazione e che un secondo dopo risponde.

`connector_pid/1` ne restituisce ora **tre**, e il ramo `{error, no_pid}` di `with_connector/4`
risponde `RETRY_LATER` con un messaggio proprio. Tre e non quattro come `lookup_pid/1`, ed è
verificato e non dedotto: `connector_pid/1` è una `call`, quindi un manager assente non è un
`badarg` da catturare nel manager ma un `exit({noproc, …})` sollevato nel **chiamante**, che
`vs_driver_proto` traduce già in `no_manager`.

**Il contratto era in ritardo di un caso prima ancora di questo lavoro.** `ws-driver.md` §6
definiva `RETRY_LATER` come «a new leader is rebuilding its claim table», cioè un fatto del
coordinatore; il codice lo usava **già** anche per «the station is restarting», che è un fatto
della stazione. §6 elenca ora i tre casi con il messaggio che li separa: nessun codice nuovo,
perché la condotta che il client deve tenere è identica in tutti e tre — e infatti nessun
client è stato toccato.

**P12**, accorpato perché è una riga dello stesso file: il messaggio di `vehicle_committed`
perde `elsewhere`, in `vs_driver_proto` **e** nella riga corrispondente di §4.1 — un test la
confronta alla lettera.

### Le tre verifiche prima di toccare il codice

1. **Bloccante — esiste un test che asserisce `UNKNOWN_CONNECTOR` per un connettore *della
   stazione ma senza pid*?** No. Cercati per struttura tutti i match sull'atomo e sul codice:
   `vs_driver_proto_tests:246` usa il connettore 99 contro `[1,2,3,4]`, `vs_station_mgr_tests:96`
   il 99 contro `[{1,150},{2,50}]` — entrambi **non configurati**, quindi restano corretti — e
   `crashed_connector_is_restarted_and_readopted_test` aspetta con un `_ -> false` senza
   asserire nulla. Nessun test difendeva il difetto: niente da rinominare.
2. **Qualcuno confronta la stringa `"elsewhere"`?** Sì, uno: `vs_driver_proto_tests:319`, che la
   cita «verbatim dalla colonna Meaning shown di §4.1». Aggiornato **per progetto**, non in
   silenzio. Le altre occorrenze fuori perimetro (`js/station.js`, `emulator/driver.js`) sono
   commenti in prosa, non confronti.
3. **`vs_driver_proto` è l'unico chiamante di produzione di `connector_pid`?** Sì, confermato
   per struttura: tutti gli altri ~25 call site sono test, tutti sul percorso `{ok, Pid}`. La
   tabella del piano era completa.

**Suite: 333 test** (328 + 5), tre giri consecutivi verdi con `EXPECTED_TESTS` aggiornato nello
stesso momento. I cinque test sono stati scritti prima del codice e visti fallire: tre
`case_clause {error, no_pid}` dentro `with_connector/4`, due sulla stringa vecchia, uno con
`{error, unknown_connector}` dove ci voleva `no_pid`.

### E2E sul compose, prima e dopo, sulla stessa scena

Compose già su (sette container). Finestra aperta come nel giro di §7zc — `sys:suspend` sul
supervisore dei connettori e connettore ucciso — così che duri quanto la misura invece di
millisecondi; prenotazione tentata dal canale driver vero su `ws://localhost:9101/ws/driver`.

| | `connector_pid(4)` | il driver riceve |
|---|---|---|
| **prima** (immagine in esecuzione, `vs_station_mgr` md5 `8340a381…`) | `{error, unknown_connector}` | `UNKNOWN_CONNECTOR` — *"connector does not belong to this station"* |
| **dopo** (immagine ricostruita, md5 `258a53aa…`) | `{error, no_pid}` | **`RETRY_LATER`** — *"the connector is restarting; try again in a moment"* |

Il nodo gira davvero il codice nuovo, verificato sul posto: `beam_lib:md5` host↔container
identico su `vs_station_mgr` (`258a53aa…`) e `vs_driver_proto` (`3fba1b84…`), ed entrambi
diversi dai valori di prima. Con la finestra aperta le **tre** azioni del canale — `reserve`,
`cancel_reservation`, `stop_session` — hanno risposto tutte `RETRY_LATER` con lo stesso
messaggio: il ramo sta in `with_connector/4`, che è il motivo per cui quella funzione era stata
fattorizzata.

**Controprova del permanente:** stesso socket, connettore **99** (non configurato) →
`UNKNOWN_CONNECTOR`, invariato. **Controprova di P12:** stesso veicolo su due connettori della
**stessa** stazione — il caso segnalato da B — → `NO_CLAIM`, *"your vehicle already holds a
reservation"*, senza l'avverbio. Stazione lasciata come trovata: quattro connettori `free`,
supervisore ripreso, quattro figli.

## 7zf. M4-A: `overstay_seconds` smette di essere zero — 30-31 agosto

Il campo non era «da implementare»: era **strutturalmente** zero, e nessun test poteva
accorgersene perché tutti asserivano quel comportamento. Il sistema confondeva due fatti che il
dominio tiene separati — *la ricarica è finita* e *il cavo è fuori*. `stop_session` in `charging`
andava dritto in `closing` (`vs_connector.erl:551-553`), `settle/1` scriveva la riga con
`overstay_seconds => 0` cablato, e fra le due cose non passava mai tempo che qualcuno potesse
misurare. Il terzo pezzo era l'emulatore: `cp.js` rispondeva a **qualunque** stop con un
`unplugged` immediato, quindi il cavo non restava mai dentro nemmeno volendo.

E il contratto si contraddiceva da solo, il che è la firma di questa famiglia di difetti:
`ws-driver.md` §4.3 diceva che lo stop «writes the session row», §120 dello stesso file che lo
stop non ferma l'orologio dell'overstay. Se la riga è scritta allo stop, l'overstay dopo uno
stop non può finirci dentro.

**La forma della correzione.** Uno stato nuovo, `complete`, fra `charging` e `closing`, in cui si
entra dalle tre fini *morbide* (`driver_stopped`, `target_reached`, `claim_revoked`) e da cui si
esce con l'`unplugged`. `overstay` **non** è un settimo stato: è `complete` oltre la grazia,
derivato in `reported_state/2` come `suspended` è `charging` a limite zero — un valore che scorre
da solo non può far entrare e uscire da uno stato. Niente timer: la pagina si aggiorna sul suo
tick da 5 s, e il timer servirà solo alla notifica, che è fuori perimetro. L'aritmetica sta in una
funzione pura esportata, `overstay_seconds/3`, perché i numeri che contano sono minuti e `vs_time`
non è iniettabile (lezione di §7zb: niente test a cronometro).

### Le verifiche bloccanti — due hanno cambiato il lavoro

1. **Nessuno, lato B, ricalcola l'overstay dai timestamp.** Cercato per struttura in tutto
   `src/backoffice/`: `SessionDao:24,86,134`, `SessionView:77-83`, `BillingService:158-172`
   leggono **solo la colonna**. L'unica derivazione da `started_at`/`ended_at` è
   `SessionView:70`, che è la *durata* mostrata nello storico. Se qualcuno l'avesse ricalcolato,
   spostare `ended_at` all'unplug avrebbe raddoppiato il conto e sarebbe servita una decisione.
2. **Dopo uno stop `cp.js` tace** (`cp.js:343-344`, `delivering=false`): la clausola `meter` di
   `complete` è difesa contro hardware che continua a parlare, non un percorso che qualcuno
   percorre. Detto nel commento, così com'è.
3. **Nessuna vista live si rompe.** `js/session.js:128-131` ha **già** `complete` e `overstay`
   nella mappa `PHASE`, con fallback; `js/station.js:140` stampa lo stato verbatim e `171-176`
   non offre azioni per uno stato che non conosce, che è la risposta giusta. `driver.js:736`
   stampa e basta. Unico buco, cosmetico: `station.jsp:61-66` non ha `.conn-complete` /
   `.conn-overstay` e quei connettori resteranno senza striscia colorata — il badge scrive
   comunque il nome, come dice il commento alla riga 59. È sotto `src/backoffice/`: **non
   toccato**, segnalato a B con le due righe di CSS pronte.
4. **`target_reached` arriva sul filo.** Tracciata tutta la catena — `stop_cmd/1` → `send_cp/2`
   → `vs_cp_ws:89-90` → `command_frame/1` → `jsx:encode` — e **non c'è nessun formatter con una
   whitelist**: il payload viaggia verbatim. Verificato sul filo vero, non solo sul tipo.
5. **La promessa di `risposta-per-B-M2.md` §17 NON era mantenuta.** `ws-chargepoint.md` §10
   diceva il valore della grazia e non la conseguenza. Riscritta: la tolleranza è sottratta lì e
   in nessun altro posto, e il numero che esce è già fatturabile.
6. **Il riaggancio §6 non ha mai avuto una clausola `plugged`, nemmeno in `charging`.** Il piano
   supponeva un meccanismo «probabilmente in `vs_cp_proto`». Non c'è: il `plugged` di ri-annuncio
   viene **rifiutato** `invalid_state` da `handle_common` e `vs_cp_proto:647-655` lo logga come
   divergenza senza mandare comandi. Ciò che salva la sessione è l'`attach_cp` del `boot`, che in
   `handle_common` cancella il timer di grazia in **qualunque** stato. Conseguenza pratica: per
   `complete` la cosa giusta era **non scrivere una clausola**, e una clausola propria avrebbe
   solo potuto rimettere a zero l'orologio di un'auto che non si è mossa.

### Tre chiamanti che la tabella del piano non aveva

1. **`vs_claim_client:count_stats/1`** (`804-814`) manda al coordinatore i tre numeri della
   lobby. `complete` e `overstay` sarebbero finiti nel catch-all e un connettore con un'auto
   ferma sopra sarebbe sparito da tutti e tre: né libero, né tenuto, né in carica. È
   letteralmente il difetto che la clausola `suspended` era stata scritta per evitare, nel posto
   dove sarebbe durato minuti invece di due secondi.
2. **`vs_driver_proto:phase/2` — l'ordine delle clausole era una trappola silenziosa.** La prima
   clausola era `soc >= 100 -> complete`, e una sessione finita per batteria piena riporta 100
   per tutto l'overstay: `overstay` non sarebbe **mai** stata producibile, e il test naturale
   (stop del driver, soc 41) non l'avrebbe mostrato. Le due clausole di stato ora vengono prima,
   e un test discrimina con `state => overstay, soc_pct => 100`.
3. **La suite è un chiamante**, e quattro test asserivano il difetto. Riscritti, non cancellati:
   i due sullo stop e sulla revoca ora aspettano l'`unplugged` per la riga; i due sulla finestra
   di `closing` (D-2) sono stati ribasati sul `faulted` di §4.1, che è l'unico percorso per cui
   quella finestra serva ancora — le tre fini morbide adesso aspettano il cavo senza scadenza,
   perché quell'attesa *è* l'overstay.

### Due campi azzerati entrando in `complete`, e nessuno dei due è cosmetico

`power_kw` viaggia nel frame §5.2 e in `complete` i `meter` sono assorbiti: senza azzerarlo la
pagina del driver avrebbe mostrato «150 kW» per tutta la durata dell'overstay. Prima di M4 il
difetto non era visibile perché `closing` durava due secondi.

`limit_kw` è il caso che il piano non aveva previsto e che vale il commento più lungo:
`vs_cp_proto:limit_kw/2` lo rilegge nel boot ack e `cp.js:224` lo riapplica, quindi una colonnina
che si riavvia durante l'overstay avrebbe **fatto ripartire l'erogazione** su un tetto che la
stazione aveva annullato un minuto prima. Zero è la parola che §5 usa già per «la sessione resta
aperta e non tira niente».

### Verificato — girato davvero

**Suite: 348 test** (333 + 15), `./src/scripts/eunit_check.sh` verde con `EXPECTED_TESTS`
aggiornato nello stesso change-set. La funzione pura eseguita in una shell, non dedotta:
`(T, T+420000, 300) → 120`, `(T, T+240000, 300) → 0`, `(T, T+300000, 300) → 0`,
`(T, T+360000, 300) → 60`, `(undefined, …) → 0` — i quattro numeri concordati con B in
`risposta-per-B-M2.md` §2, il secondo di confine incluso.

**E2E sul compose** (sette container, `mysql` healthy, Docker Desktop controllato prima), con
`station1` ricostruita dal branch e `OVERSTAY_GRACE_SECONDS=10` per non aspettare cinque minuti.
Tre corse, osservate da un client del canale driver vero e dalla riga in MySQL:

| corsa | come finisce la ricarica | fasi viste sul canale driver | riga in `sessions` |
|---|---|---|---|
| `--soc 99 --battery 1 --linger 20` | il primo `meter` a soc 100 → **`target_reached`**, il filo mai tirato prima di oggi | `charging` → `complete` **4 ms** dopo (via `connector_event`) → `overstay` al tick successivo alla grazia, `overstay_seconds` 3 → 8 → `closed` | id 8, **`overstay_seconds = 10`**, `cost_cents 50` |
| `--soc 40 --linger 20`, `stop_session` vero sul canale | `driver_stopped`; un secondo `stop_session` risponde **`INVALID_STATE`** come da §4.3 | `charging` → `complete` in 3 ms → `overstay` (2 → 7) → `closed` | id 9, **`overstay_seconds = 10`**, 0.417 kWh, `cost_cents 69` |
| **senza `--linger`** | stop e `unplugged` nello **stesso millisecondo** (17:01:25.970) | — | id 10, **`overstay_seconds = 0`** |

Il calcolo atteso, scritto prima di guardare: ricarica finita alle 16:58:11.03 sull'orologio
della stazione, `unplugged` alle 16:58:31.04 → 20 s → meno 10 di grazia → **10**. Osservato 10.
La terza corsa è la controprova che serviva davvero: senza il flag il comportamento di prima di
M4 è intatto bit per bit, quindi nessuno script e nessun test esistente cambia significato.

**La catena a valle è chiusa da sola**: `cost_cents = 50` è `round(0.005 × 45) = 0` di energia
più `(10+59)/60 = 1` minuto × 50 c. B ha fatturato un overstay senza che nessuno gli dicesse
niente, dal solo campo — che è esattamente ciò che il contratto prometteva e che finora non era
mai stato messo alla prova con un numero diverso da zero.

**Una cosa da sapere prima della demo, perché sembra un disallineamento e non lo è:** l'ultimo
frame che il driver vede dice `overstay_seconds=8` e la riga dice `10`. Il frame `closed` porta
per costruzione i valori dell'**ultimo tick** con la sola `phase` cambiata
(`vs_driver_proto:closed_frame/1`), e `energy_kwh` ha la stessa proprietà da M2. Il numero che
conta è quello della riga.

### Non provato — e perché

- **La pagina di B guardata con gli occhi.** I client sono stati censiti per struttura e il
  codice letto, ma nessun browser è stato aperto su un connettore in `overstay`: la mancanza di
  `.conn-complete` in `station.jsp` è letta nel CSS, non vista sullo schermo. Serve una password
  che non ho — la stessa che manca alla verifica del fuso di `history.jsp`.
- **Un overstay più lungo del lease del claim, con hardware che parla ancora.** La clausola
  `revoke` in `complete` (assorbi e continua a misurare) è coperta in unità con una revoca
  esplicita, ma non è mai girata una demo con un lease scaduto sotto un overstay: servirebbero
  `LEASE_SECONDS` bassissimi e un coordinatore che revochi davvero.
- **Il riavvio della stazione durante `complete`.** Ragionato e messo agli atti in
  `scelte_di_progetto.md` §22.7, **non riprodotto**. E lì il piano si sbagliava: diceva che «il
  prossimo `meter` a soc 100 lo rimanda in `complete` e l'orologio riparte», che vale solo per
  l'overstay da batteria piena e solo se la colonnina continua a mandare `meter` — la nostra
  tace. Per un overstay nato da uno stop del driver il soc non arriverà mai a 100: il connettore
  resta `charging` fino all'unplug e la riga esce con 0. In entrambi i casi lo scarto è a favore
  del driver, che è il verso giusto.
- **Hardware che manda `meter` dopo uno `stop`.** Coperto da un test unitario, esercitato da
  nessun emulatore (verifica 2).
- **`driver.js` in scenario completo** contro le stazioni nuove. Il ragionamento è che nessuno
  dei tre scenari passa `--linger`, quindi la fine di sessione è identica a prima; ma è un
  ragionamento, non una corsa.

### Cosa resta fuori da M4-A, e perché

- **Il frame `notification`** di ws-driver §5.3 (`charge_complete`, `overstay_started`): bloccato
  da **R2**, il coordinatore di B non inoltra i `{notify, …}` e non c'è una risposta alla review
  della PR #5. Quando si aprirà, la fase arriva comunque alla pagina via snapshot entro un tick,
  e il timer da aggiungere è un `{state_timeout, Grazia, overstay}` in `complete(enter, …)` che
  non cambia nient'altro.
- **La segnalazione no-show**, l'altro pezzo di M4-A: il contatore è scritto solo da B.

## 7zg. M4-A: la stazione racconta il no-show, e l'anello delle penalità si chiude — 31 agosto

L'anello era aperto esattamente a metà, e la metà mancante era nostra. La stazione **osservava**
la scadenza da M1 — `vs_connector.erl:455`, con accanto un commento onesto, «Reported, never
written» — ma quel `notify` va al manager e da lì alle pagine aperte: non usciva dalla stazione.
`show_up` non lo mandava nessuno, in tutto `src/`. Il lato di B era completo fino in fondo dal
M4-B (`vs_coord_srv.erl:247-252` → `vs_coord_bo:penalty_event/1` → `ErlangBridge.java:155-156` →
`PenaltyService` → `UserDao`), e stava in ascolto di un messaggio che non arrivava mai. Il
contatore restava a zero mentre ogni no-show veniva visto.

Due chiamate nuove sul claim client, due call-site nel connettore, e niente altro.

### Le quattro verifiche bloccanti, prima di scrivere codice

1. **Il gate anti-doppio-conteggio di B è sul salto coordinatore→Java, non su stazione→
   coordinatore** (`vs_coord_bo.erl:144-155`). Inoltra solo mentre `serving = true`, «relaying
   it from two coordinators at once would count one no-show twice — Java's counter has no way to
   tell the duplicates apart». Letto per intero: protegge dal fan-out durante un handover, e
   **non** deduplica affatto due `no_show` mandati dalla stessa stazione. È precisamente ciò che
   rende l'at-most-once dal nostro lato necessario e non solo economico — siamo l'ultimo punto in
   cui quel duplicato si può non creare.
2. **Il mock è `vs_claim_stub` e registra per struttura, ma le clausole vanno scritte a mano**
   (`test/vs_claim_stub.erl`): ogni callback esportata chiama `record({Tag, Args...})` in una
   lista `persistent_term`, e `calls/0` la restituisce grezza — nessuna whitelist, ma nemmeno
   nessun catch-all. E **`vs_claim_null` non ha `session_closed` per un motivo, non per una
   dimenticanza**: il suo unico chiamante (`vs_station_db.erl:509`) avvolge la chiamata in un
   `try/catch` e tratta il fallimento come una sveglia best-effort persa. I due nuovi non hanno
   quella rete — `vs_connector` li chiama dritti da `held/3` — quindi lo stand-in **deve**
   averli, o `CLAIM_MOD=vs_claim_null` perderebbe una presa a ogni scadenza.
3. **La sospensione torna al coordinatore in millisecondi, in catena sincrona** con il secondo
   strike: `ErlangBridge.handle` → `PenaltyService.onNoShow` → `suspend()` →
   `UserDao.suspendUntil` → `ErlangBridge.notifySuspension` → `vs_coord_srv.erl:295`. Nessun
   intervallo di polling da aspettare. Misurato nell'E2E: `suspended_until` scritto e terzo
   `reserve` rifiutato **entro lo stesso secondo**.
4. **Nessuno abbassa `LEASE_SECONDS` oggi**: `${LEASE_SECONDS:-900}` in tre punti del compose
   (stazioni e coordinatori) e nient'altro fuori dai test. Il minimo sicuro non è un numero
   assoluto ma una **direzione**: abbassarlo sulla sola `station1` lascia il claim del
   coordinatore a 900+60 s, cioè molto più lungo della prenotazione — che è il verso giusto
   (`claim.md` §3.1, il claim non deve mai morire sotto una prenotazione viva). Usati 5 s.

### Il piano si sbagliava su un numero, ed era un numero dell'E2E

Diceva «due scadenze → `no_show_count = 2`». Falso: `UserDao.suspendUntil` (righe 178-185)
scrive `SET suspended_until = ?, no_show_count = 0` — «resets the streak: the penalty has been
served on it». Al secondo strike il contatore torna a **zero**, e la prova che i due strike ci
sono stati è `suspended_until` più le righe in `notifications`. Trovato leggendo `UserDao`
durante le verifiche, prima di scrivere codice; l'E2E asserisce i valori corretti.

### Catena dei chiamanti — due voci che §6 del piano non aveva

1. **`vs_mock_coord`.** Il piano elencava `vs_claim_null` e `vs_claim_stub` e si fermava lì. Ma
   il test che asserisce la *forma sul filo* passa dal coordinatore finto, e il suo
   `handle_cast` catch-all **non registra**: senza due clausole nuove il test non avrebbe potuto
   distinguere «mandato con la forma giusta» da «mandato con la forma sbagliata». Aggiunte con
   la forma esatta, non con un match sul solo tag, così un elemento di troppo cade nel catch-all
   lì come cadrebbe in quello del coordinatore vero.
2. **`vs_driver_stub` no, e valeva controllarlo.** È `claim_mod` per `vs_driver_proto`, ma solo
   per `coordinator_reachable/0`: nessun connettore gira con quel modulo, quindi nessuna
   clausola da aggiungere. Verificato, non supposto.

Per il resto la catena è corta per costruzione: nessuna firma esistente cambia, i due call-site
aggiungono una riga ciascuno e non toccano transizioni, reply o rilasci. Chi guarda il manager
non vede niente di nuovo.

### Verificato — girato davvero

- **Suite: 348 → 357**, `EXPECTED_TESTS` aggiornato nello stesso commit. Nove test nuovi: sei sul
  connettore — due che devono segnalare (scadenza, `plugged` accettato) e quattro che devono
  tacere (`plugged` rifiutato, `revoke`, colonnina persa oltre la grazia, walk-in) — e tre sul
  client (le due forme sul filo, più il leader irraggiungibile). Più un'asserzione aggiunta al
  test del `cancel` che già esisteva: è la quinta uscita silenziosa, e senza quella riga la frase
  «solo dalla scadenza» era più larga di ciò che i test tenevano. Resta scoperta una sola uscita
  di `held`, il `cp_status faulted`, gemella della grazia scaduta — stessa `release(cancelled)`,
  stesso `out_of_service`.
- **La mutazione, perché un test sulla forma va provato falsificandolo.** Aggiunto un quinto
  elemento al `no_show` castato: **1 test rosso su 28** in `vs_claim_client_tests`. Senza le
  clausole nuove del mock sarebbe rimasto verde, che è esattamente il modo in cui questo difetto
  arriva in produzione.
- **E2E sul compose** (7 container, `mysql` healthy, `station1` ricostruita dal branch con
  `LEASE_SECONDS=5`, leader `vs@coord3`). Due sequenze, un solo utente perché il database ne ha
  uno solo (id 12 `andrea`, veicolo 88 — `users`/`vehicles` sono di B e nascono alla
  registrazione, `schema.sql` semina solo stazioni e connettori):
  - **la sequenza che NON deve sospendere** — scadenza → `no_show_count = 1`; arrivo onorato
    (cavo dentro col veicolo giusto prima della scadenza) → **0**; scadenza → **1**,
    `suspended_until` ancora `NULL`. È «turning up resets the counter» di SCOPE §3.3, misurato.
  - **la sequenza che deve sospendere** — due scadenze consecutive → `no_show_count = 0` e
    `suspended_until = 2026-09-01 08:41:15` (un giorno esatto dal secondo strike); il `reserve`
    successivo rifiutato **`SUSPENDED`** con il testo di `vs_driver_proto.erl:418-420`, «the
    account is serving a no-show penalty; walk-in charging still works», su un connettore
    **libero** — cioè il rifiuto riguarda l'account, non la presa.
- **La catena intera nei log**, non solo agli estremi: `station1` «connector 3 lease expired for
  user 12» → `backoffice` «No-show 1 for user 12 at station 1, connector 3». I tre campi della
  4-tupla arrivano interi fino a Java.
- **Il `cancel` non è uno strike**, osservato per caso e vale come misura: la prenotazione di
  verifica finale è stata cancellata e il contatore è rimasto 0.

### Un dettaglio dell'E2E che sembra un difetto e non lo è

Il primo terzo `reserve` è tornato `INVALID_STATE` invece di `SUSPENDED`: il connettore 3 era
andato `out_of_service` perché l'emulatore colonnina se n'era andato 30 s prima e la grazia era
scaduta. Ripetuto su un connettore mai toccato da una colonnina, il rifiuto è `SUSPENDED`. Lo
stato del connettore viene prima del controllo sull'account, che è l'ordine giusto — ma va saputo
prima di leggere quel `INVALID_STATE` come un buco nell'enforcement.

### Non provato — e perché

1. **Uno strike perso durante un failover vero.** L'at-most-once dice che se il leader cade fra
   il `cast_leader` e la consegna lo strike è perso: è la conseguenza accettata della scelta, non
   l'ho prodotta apposta. Il gate `serving` di B (R4 della review PR #5) rende quella finestra
   più larga di quanto serva, ed è già segnalato a B come rilievo aperto.
2. **Due `no_show` per lo stesso utente nello stesso istante.** `UserDao.recordNoShow` è
   transazionale con `FOR UPDATE` (letto), ma servirebbero due stazioni che scadono insieme.
3. **`recordNoShow` su un utente inesistente.** Il codice ha il ramo («the account is gone;
   nothing to punish») e non l'ho esercitato: il database ha un utente solo.
4. **La sospensione che scade da sola.** `is_suspended/2` confronta con l'orologio a ogni claim,
   quindi scade da sé — ma sarebbe stato domani. L'ambiente l'ho rimesso a posto pulendo MySQL e
   riavviando il coordinatore che serviva, perché `notifyUnsuspension` **non ha chiamanti** e la
   mappa in memoria del coordinatore non toglie mai una voce prima della sua scadenza.

### Cosa resta fuori, e perché

`{notify, UserId, Kind, Text}` e il frame `notification` di `ws-driver.md` §5.3 restano al pair
successivo (R2 della review PR #5: il coordinatore non ha ancora la clausola, la patch è pronta
nella nota a B). La riga «declared, not yet implemented» di `erlang-java.md` §2.4 va aggiornata
in PR, non qui: è un file condiviso.

## 7zh. M4-A: il frame `notification` esisteva dal M1 e non l'aveva mai emesso nessuno — 31 agosto

Ultimo pezzo di M4-A. `ws-driver.md` §5.3 descrive il frame dal M1, la pagina lo sa già
renderizzare (`js/ws.js:262` → `station.js:70`, `note(connector_id, text)`), il ponte Java lo sa
già ricevere (`ErlangBridge.java:157` → `PenaltyService.onNotify` → `notifications`) — e in mezzo
**non c'era mittente**. Tre buchi in fila, misurati prima di scrivere:

1. il connettore osservava quasi tutte le notizie ma le diceva **solo al manager**; due
   (`charge_complete`, `overstay_started`) non esistevano affatto e `reservation_expiring` non
   aveva il suo timer;
2. il manager, su ogni `connector_event`, faceva `reallocate` + `broadcast` di **solo stato** —
   l'evento, che *è* la notizia, non raggiungeva mai i subscriber;
3. `vs_driver_ws` non aveva una clausola per una notifica e `vs_driver_proto` non aveva il
   builder del frame.

### Le cinque verifiche bloccanti, prima di scrivere codice

1. **Il catch-all del coordinatore logga il termine intero** — `vs_coord_srv.erl:279-281`,
   `logger:warning("coordinator: unexpected cast ~p", [Unknown])`. Decide cosa può provare l'E2E
   della copia durevole: non «arriva e sparisce muto» ma «arriva e si legge per intero nel log
   di B». È diventato l'argomento centrale della nota per B.
2. **`notifications`** (`schema.sql:88-98`): `kind VARCHAR(40)`, `text VARCHAR(255)`. Le sei
   frasi stanno tutte con margine; un test asserisce le due lunghezze invece di fidarsi.
3. **L'identità del join in `vs_driver_ws`** vive dentro `Session` (`user_id`, legato dal token
   in `join` e da nient'altro), che sta nella mappa di stato `#{session, last_state,
   last_session}`. La clausola nuova confronta con quello — nel **capo della clausola**, con
   `UserId` che compare due volte, così il filtro non può essere aggirato da un payload.
4. **La semantica OTP dei timeout, confermata sui doc locali** (`stdlib-8.0.3/doc/html/
   gen_statem.md`): per lo `state_timeout` la doc dice esplicitamente *«A state change cancels
   this timer»*; nella sezione del `generic_timeout` quella frase **non c'è**, e c'è invece la
   regola del riarmo per nome. L'asimmetria è il meccanismo su cui poggia tutto il resto.
5. **Precedente per testare un frame *spinto*: sì**, `vs_cp_proto_tests.erl:806` guida
   `vs_cp_ws:websocket_info/2` direttamente su una mappa di stato costruita a mano. Non esiste
   nessun `vs_driver_ws_tests.erl` — quindi i test della clausola nuova stanno in
   `vs_driver_proto_tests`, con lo stesso metodo.

### Il censimento dei subscriber: §7 del piano ne vedeva metà

Il piano diceva «censisci chi chiama `vs_station_mgr:subscribe`». Farlo davvero mostra che
**nel manager si entra da due porte**, non da una:

| Porta | Chi | Tollera `{driver_notification, …}`? |
|---|---|---|
| `subscribe/0` (call) | `vs_driver_ws.erl:88` — una per pagina aperta | **la gestisce**: è il destinatario |
| `subscribe/0` (call) | il processo di test, in `vs_station_mgr_tests` | sì |
| `gen_server:cast(vs_station_mgr, {subscribe, self()})` | **`vs_claim_client.erl:303`** | **sì**, catch-all `handle_info` a `:587`, `logger:debug` |

Il claim client è un subscriber di produzione a tutti gli effetti — si iscrive per alimentare
`station_stats` per la lobby — e un grep su `subscribe(` non lo trova, perché usa la variante
cast. Riceverà una riga di debug per ogni notifica: innocuo, ma è esattamente il tipo di cosa
che il piano dava per «altri iscritti eventuali» e che invece esiste già.

### Un timer che sopravvive a tutto, e il crash che sarebbe certo

`reservation_expiring` deve usare un **timeout generico con nome**, perché in `held` lo
`state_timeout` è già occupato dal lease e ce n'è uno solo. Il prezzo è che non si cancella mai
da solo. `sys:get_status/1` pubblica i timer vivi, quindi non è un ragionamento ma una foto:

```
lease 900, in `held'         : {2, [{state_timeout,lease_expired}, {{timeout,expiring},expiring}]}
dopo il plugged, in `charging': {1, [{{timeout,expiring},expiring}]}
dopo l'unplug, in `free'      : {1, [{{timeout,expiring},expiring}]}
lease 120, in `held'          : {1, [{state_timeout,lease_expired}]}
```

Lo `state_timeout` sparisce al cambio di stato; l'altro no — e `handle_common` matcha solo
`{call,…}`, `cast`, `{timeout, cp_grace}` e `info`. Senza una clausola d'assorbimento è un
`function_clause`, e ci si arriva per **due** strade ordinarie: il conducente che si presenta
negli ultimi due minuti del lease, e — più banale ancora — **qualunque sessione breve**, che
lascia il connettore in `free` con il timer ancora armato per altri undici minuti. Non è
prudenza: è la conseguenza diretta della scelta del tipo di timer.

`overstay_started` usa invece uno `state_timeout` proprio per la ragione opposta: muore uscendo
da `complete`, quindi chi stacca il cavo dentro la grazia non produce niente e non c'è nessuna
cancellazione da ricordarsi. E con grazia 0 l'evento non è schedulato ma **accodato** davanti a
qualunque evento esterno non ancora arrivato (doc di `state_timeout`), il che rende il test
deterministico senza un solo `sleep`.

### Verificato — girato davvero

**Suite: 357 → 379, 0 failures** (`./src/scripts/eunit_check.sh`, `EXPECTED_TESTS` aggiornato
nello stesso commit). I 22 nuovi:

- la funzione pura sui tre numeri di §8: `expiring_delay(900000) → 780000`,
  `expiring_delay(90000) → none`, `expiring_delay(120000) → none`;
- l'armamento del timer letto da `sys:get_status/1` (lease 900 sì, lease 120 no) e la sua
  sopravvivenza a `held → charging`;
- `charge_complete` **una volta sola e solo dal target**: una seconda lettura piena in `complete`
  non produce niente (assorbita), e né lo stop del conducente né la revoca lo producono;
- `overstay_started` con grazia 0 scatta e con grazia 3600 no; chi stacca dentro la grazia non lo
  produce; e con grazia 0 la macchina è in `complete` mentre lo snapshot riporta `overstay` — le
  due risposte separate, che è tutto il disegno del pair overstay;
- manager: i sei kind → `{driver_notification, UserId, Kind, ConnId}` ai subscriber; **quattro su
  sei** → `notify` sul claim mod, e i due live-only asseriti sull'*assenza* della chiamata, che è
  l'unico osservabile che una cast at-most-once abbia; e il negativo su sette eventi che non
  sono notizie, `no_show` compreso — che è una coppia `{Kind, UserId}` identica alle altre e che
  solo una lista esplicita distingue;
- proto/ws: la forma esatta di §5.3, le lunghezze contro le colonne, l'unicità delle frasi, il
  kind sconosciuto che non fa crashare nessuno; il frame spinto sul socket del suo conducente e
  **non** su quello di un altro, né su uno che non ha fatto join; e la clausola che sta sopra il
  catch-all, asserito guidando la callback e non leggendo il sorgente;
- claim client: la 4-tupla esatta su `vs_mock_coord`, il testo identico fra copia live e durevole,
  e il leader irraggiungibile che non fa esplodere niente e non lascia coda.

**E2E live** (`LEASE_SECONDS=130 OVERSTAY_GRACE_SECONDS=10` su `station1`, client WebSocket
esterno perché il browser interno non passa i WS cross-origin):

```
10:19:48.251 --> stop_session connector 3
10:19:58.255 {"type":"notification","request_id":null,"payload":{
               "text":"The grace period is over: the time the car stays plugged in is now billed.",
               "connector_id":3,"kind":"overstay_started"}}

10:22:01.738 ack reserve conn 1, lease 130 s
10:22:11.739 {"kind":"reservation_expiring","text":"Your reservation expires in less than two minutes."}
10:24:11.732 {"kind":"reservation_expired","text":"Your reservation expired and the connector was released."}
```

Dieci secondi esatti dopo lo stop (la grazia), e i due avvisi della prenotazione a T−2min e a T
esatti — cioè l'aritmetica di `expiring_delay/1` misurata sul filo e non solo in EUnit.

**E2E durevole**: nello stesso millisecondo del frame live, sul coordinatore si legge

```
=WARNING REPORT==== 31-Aug-2026::10:19:58.255626 ===
coordinator: unexpected cast {notify,12,<<"overstay_started">>,
                                     <<"The grace period is over: the time the car stays plugged in is now billed.">>}
```

e **nessun cast per `reservation_expiring`** da nessuna parte: la tabella `durable/1` misurata
end-to-end. R2 è ancora aperto, quindi nessuna riga dalla nostra strada arriva in
`notifications` — verificato, e con una precisazione che conta (sotto).

*(L'E2E ha girato con `reservation_expired` ancora fra i durevoli — è la sua cast, arrivata a
`coord3`, che si vede citata qui sotto. La decisione presa subito dopo l'ha tolto dalla lista:
oggi quella cast non parte più, e il frame live resta.)*

### Una riga in `notifications` è comparsa, e non è la nostra

Il piano diceva: se una riga compare, qualcosa ha scavalcato R2 — fermarsi e segnalare. Una riga
è comparsa (`id 5`, `kind = reservation_expired`, alle 10:24:11, l'istante della scadenza) e
**non viene da noi**. Il testo lo dimostra: «Your reservation expired without the vehicle
arriving. 1 of 2 …», che è `PenaltyService.java:83` — la strada **no-show**, che scrive la sua
notifica da M4-B e che stamattina ha fatto quello che fa da sempre. La nostra frase è «Your
reservation expired and the connector was released.» e in tabella non c'è. Nessuna riga
`overstay_started`, che è la prova più pulita perché per quel kind non esiste nessun altro
produttore.

**E la scoperta era più utile del sospetto.** La stessa scadenza del lease manda a B *due*
messaggi — il `no_show`, che fa scrivere quella riga col conteggio degli strike, e (dopo R2) il
nostro `notify`. Applicata la patch, un no-show avrebbe scritto **due righe sullo stesso fatto**,
e la nostra sarebbe stata la più povera delle due.

**Deciso da Caleb, e fatto nello stesso commit: `reservation_expired` esce dai durevoli** e resta
live-only. Restano quattro kind durevoli — `claim_revoked`, `charge_complete`,
`overstay_started`, `session_interrupted` — e nessuno dei quattro ha un altro produttore. Costo
della correzione, presa prima che R2 esistesse: una riga in `durable/1`, un test e le carte;
presa dopo, sarebbe stata una colonna sporca in produzione.

L'argomento con cui `notify` è at-most-once («un duplicato è innocuo») è vero e non c'entrava:
riguarda due copie dello *stesso* messaggio, non due messaggi diversi sullo stesso evento. La
regola che ne esce sta in §24.6 di `scelte_di_progetto.md`: **una copia durevole è per un fatto
che non registra nessun altro**, e la domanda da farsi non è «quanto costa un duplicato?» ma
«chi scrive già questo fatto?», guardando *tutti* i messaggi che un evento genera.

### Un'altra cosa misurata: la cast del walk-in va a un follower

L'`overstay_started` è arrivato a `coord1`, che era in standby, mentre il leader era `coord3`;
la `reservation_expired` è arrivata a `coord3`. La differenza non è un difetto: `#state.leader`
del claim client si aggiorna quando un coordinatore **concede** un claim, e una sessione walk-in
non ne chiede nessuno — la stazione resta sul primo nodo di `COORD_NODES` finché non impara
altro. È esattamente il caso «cold-boot» che B nomina nel test che suggerisce per R2, e rende la
sua scelta di **non** mettere il gate `serving` su `notify` una necessità e non una preferenza:
col gate, tutte le notifiche delle sessioni senza prenotazione sparirebbero.

### Non provato — e perché

1. **Lo scatto del timer `expiring` fuori da `held`.** L'assorbimento in `handle_common` non è
   osservato sotto fuoco. Il ritardo è `Remaining - 120000` con `Remaining` che nasce da un lease
   in secondi interi: il più piccolo ottenibile è **1000 ms**, venti volte il tetto di P11. Quello
   che è provato è il meccanismo — il timer è ancora armato in `charging` e in `free`, letto da
   `sys:get_status/1` — cioè che senza quella clausola il crash arriverebbe. Non è forzato con
   uno sleep di proposito.
2. **La pagina vera in Chrome.** L'estensione non era collegata a nessun browser, quindi la
   verifica è stata fatta con un client WebSocket esterno che stampa i frame verbatim: prova che
   il frame esce da cowboy con la forma di §5.3 e il testo giusto, **non** che `station.js` lo
   dipinga. Quella metà è letta nel sorgente (`onNotification` → `note(connector_id, text)`,
   `station.js:69-73`) e resta da guardare con gli occhi.
3. **`charge_complete` sul filo.** Coperto da tre test, non dall'E2E: l'allocatore taglia la
   potenza di una batteria quasi piena (taper), quindi arrivare al 100 % con l'emulatore richiede
   minuti anche partendo dal 95 %. Il percorso è lo stesso `notify` degli altri tre.
4. **`claim_revoked` sul filo.** Servirebbe un secondo claim in conflitto o un failover; è
   coperto da test, e la sua emissione esisteva già da M1 — l'unica cosa nuova su quel percorso è
   l'instradamento nel manager, che i test del manager coprono per tutti e sei i kind insieme.

### Cosa resta fuori, e perché

- **La clausola di R2**: è `src/erlang/apps/vs_coord/`, di B. Il pair finisce sul confine anche
  dove basterebbero due clausole.
- **La waitlist e `waitlist_offer`**: non è M4. Il contratto ora dichiara il kind non producibile
  invece di lasciarlo sembrare implementato.
- **`erlang-java.md` §2.4**: file condiviso, si tocca in PR.
- **Retry o code per `notify`**: deliberato, §24.1 di `scelte_di_progetto.md`.

## 7zi. La review di B sullo stack M4-A: cinque rilievi, tutti veri — 1 settembre

B ha rivisto i cinque commit dello stack (`review-per-A-m4a.md`, branch `b/review-m4a`).
Riverificati aprendo il codice invece che la review: **tutti e cinque veri**, e uno grave.
Applicati sul branch, che aggiorna la PR aperta. Risposta in
`src/contracts/risposta-per-B-m4a-review.md`.

- **B1 — GRAVE.** `OVERSTAY_GRACE_SECONDS=-1` uccideva il connettore **entrando in `complete`**:
  `vs_env:get_int/2` torna al default solo su `badarg`, `"-1"` passa, e lo `state_timeout` nudo
  dell'enter faceva terminare gen_statem con `bad_action_from_state_function`. A ogni stop del
  conducente, a ogni batteria piena, a ogni revoca. Manopola **esposta nel compose** con il
  commento che invita a cambiarla. `max(0, …)` in `init/1` su tutte e tre le durate
  (`overstay_grace_s`, `cp_grace_ms`, `settle_ms`) — `CLOSING_SETTLE_MS=-1` faceva lo stesso a
  `closing`, e poteva da prima di M4.
- **B2.** `phase(closing, _)` cadeva nel catch-all e rispondeva `charging` durante il settle,
  con la sessione ancora nello snapshot e un frame davvero spedito. Ora `closed`, **sopra** la
  clausola `soc >= 100` (sotto, un'auto finita piena leggerebbe `complete`). Riga di
  `ws-driver.md` §5.2 riscritta nello stesso commit: `closed` ora arriva per due strade.
- **B3.** Le `driver_notification` arrivavano anche al claim client, che le scartava nel
  catch-all — sul processo che sta sul percorso critico di ogni acquire e della ricostruzione
  P14. Due mappe nel manager sulle due porte che c'erano già (`sockets` dalla call, `watchers`
  dalla cast); un solo `fan_out/2`, che era l'altra metà del rilievo.
- **B4.** `cp.js`: `lingerTimer` riassegnato senza `clearTimeout`, timer orfano che scatta per
  primo e cancella quello nuovo. Clear prima della riassegnazione.
- **B5.** Tre commenti dicevano che R2 era aperta. È chiusa dalla #8
  (`vs_coord_srv.erl:274` su `origin/main`). Riscritti: dicono il presente, e nessuno dei tre
  cita più un numero di riga — è così che erano marciti.

### La correzione a B: 385 → 382

La sua nota su `eunit_check.sh` diceva che il nostro 382 era misurato su un albero senza i suoi
tre test, quindi 385 al merge. **Il nostro albero li contiene**: `git merge-base` fra il branch
e `origin/main` *è* la punta di `origin/main` (`90cbf81`, il merge della #8), il file
`vs_coord_srv_tests.erl` è identico sui due lati, e i tre test girano da qui. Il suo `c65d0cb`
portava `EXPECTED_TESTS` da 333 a 336; 382 è misurato sopra quel commit e li include già.
Sommarli li conterebbe due volte. È il suo stesso principio — «misurato, non sommato».

### Verificato — girato davvero

- Suite: **382 → 386**, tre giri consecutivi di `eunit_check.sh` verdi, `EXPECTED_TESTS` a 386
  nello stesso commit dei test.
- **Ciascuno dei quattro test nuovi è stato visto fallire senza il suo fix**, non solo passare
  con. B1: `bad_action_from_state_function`, con la suite che stampa `76 tests, 0 failures, 3
  cancelled` — esattamente il modo di guasto contro cui è ancorata la stringa di
  `eunit_check.sh`. B2: `expected closed, got charging`; e spostando la clausola sotto quella
  `soc >= 100`, `expected closed, got complete` — l'ordine è asserito. B3: la notifica ricompare
  nella mailbox del claim client.
- La catena dei chiamanti di B3 tracciata per grep su tutto l'albero prima di toccare il
  manager: due porte, due chiamanti di produzione (`vs_driver_ws.erl:88`,
  `vs_claim_client.erl:343`), `unsubscribe/0` chiamato solo dai test.

### Non provato — e perché

- **B4 non ha un test.** È l'emulatore, e nessun test eunit lo raggiunge: la prova è la lettura
  del sorgente e la sequenza tracciata a mano. Un caso manuale (due stop morbidi in fila con
  `--linger` lungo) richiederebbe i container su e un minuto di orologio, e non l'ho fatto.
- **Nessuna verifica in Docker** in questo giro: le cinque correzioni sono tutte a livello di
  processo o di emulatore, e la suite le copre. L'ultima E2E resta quella del 31/08.
- **Il limite dichiarato di `complete`** (firmware che heartbeata per sempre col cavo dentro:
  sessione in RAM, riga mai scritta) non è misurato e non lo sarà: non c'è codice da provare,
  è una scelta. Scritta in `scelte_di_progetto.md` §25.5 col confine — se un giorno servirà un
  segnale sarà l'incoerenza `cp_status available` col cavo dentro, non un orologio.

### Cosa resta fuori, e perché

- **Il branch `b/review-m4a`** è di B: la review la merga o la include come vuole lui.
- **Un tetto su `complete`**: deciso di no, e il perché sta in §25.5 e nella risposta.
- **`vs_coord/`, `backoffice/`, i contratti condivisi**: fuori perimetro. `ws-driver.md` è
  toccato perché è nostro e perché B2 lo rendeva falso.

## 7zj. La coda di M3-A misurata: la partizione vera, la strada lenta, la scadenza naturale — 1 settembre

Le quattro misure che `REPORT_M3A_VERIFICA.md` §7 dichiarava non prodotte. Pair di
**verifica**: nessun file sotto `src/` toccato tranne questo e `scelte_di_progetto.md`, un
difetto grave trovato e **non corretto** (P18). Report intero in `REPORT_M3A_CODA.md`.

### La precondizione che era falsa, e che ha cambiato l'inizio

Le immagini **non** erano alla punta. `beam_lib:md5` letto **dai nodi vivi**
(`rpc:call(N, code, which, [M])`) contro un albero host compilato di fresco: `vs_connector` e
`vs_station_mgr` diversi — cioè esattamente i due moduli che `8162926` tocca, la review di B
applicata tre ore prima. I container giravano il `vs_connector` **precedente** alla correzione
B1. Ricostruito e riverificato su tutti e cinque i nodi prima di misurare qualsiasi cosa. La
data dell'immagine non serve a niente: `docker compose build` può essere tutto cache e il
timestamp non si muove.

### La premessa del piano che era falsa, e che valeva un ordine di grandezza

Il piano diceva «il claim client continua a **castare** i renew» e chiedeva `net_ticktime`
perché «i cast non hanno timeout». **Il renew non è un cast**: `handle_info(renew_tick, …)`
spawna un worker che fa `call_round/4` → `call_one/3` = `gen_server:call({vs_coord_srv, Node},
Msg, T)` con `T = CLAIM_CALL_TIMEOUT_MS = 2000`. I cast sono altri sei messaggi (`release`,
`no_show`, `show_up`, `notify`, `station_stats`, `station_up`), e lì il piano ha ragione: verso
un nodo partizionato spariscono senza errore.

`net_ticktime` **in uso: 60 s**, letto sui nodi vivi (nessun `-kernel net_ticktime` nel
`start-node.sh` né nel compose: è il default OTP). Misurato due volte: **72,5 s** e **64,6 s**
per la nodedown, dentro la forchetta documentata `[T, T+T/4] = [60, 75]`.

### ① M1 — la partizione del leader, vista dalla stazione

Scena: connettore 3 prenotato **e onorato** da `cp.js` (quindi `charging` **con** claim — un
walk-in non ne ha), connettore 1 prenotato da un secondo veicolo. `docker network disconnect`
sul leader.

```
14:33:54.181   >>> disconnect del leader coord3
14:33:56.298   coord3   QUORUM LOST (1 of 3) ... election: out of quorum, abdicating   [2,12 s]
14:33:56.468   coord2   election: leader vs@coord3 is gone, electing / is now the leader
14:33:56.470   coord2   rebuild: asked 2 station node(s) -> 2 answered, 2 claim(s)     [118 us]
14:33:56.470   coord2   coordinator vs@coord2 serving with 2 adopted claim(s)          [2,29 s]
14:34:58.747   coord2   ** Node vs@coord3 not responding **                            [64,6 s]
```

**2,29 s** dalla partizione a un leader nuovo che serve con entrambi i claim. Il costo del
failover non è ricostruire, è accorgersi: le stazioni hanno risposto al `who_do_you_hold` in
**118 microsecondi**.

**Come se ne accorge la stazione: non se ne accorge.** Nel log di station1 non c'è **una sola**
riga `claim client: renew failed on every coordinator`. `handle_info({who_do_you_hold, …})`
risponde **e** fa `State#state{leader = CoordNode}`: la stazione impara il leader nuovo dentro
la risposta, gratis. **La finestra dei renew nel vuoto è stata di zero tick** — non fra 30 s
(republish) e 60 s (tick), come stimava il piano. Il tick della distribuzione è arrivato 28
volte più tardi dell'heartbeat e non ha rilevato niente che non fosse già deciso: non è il
rilevatore, è la pulizia.

**Che cosa ha visto il conducente: niente.** Un osservatore del canale driver connesso per
tutta la partizione ha ricevuto **30 frame `state`, tutti con `coordinator_reachable: true`** e
la griglia immobile (`held` / `charging` a 150 kW). `coordinator_reachable` si scrive solo in
`handle_info({renew_result, error}, …)`, e quel clause non è mai stato raggiunto.

Alla riconnessione il rango più alto riprende la corona in **1,08 s** — ed è lì che si è aperta
la cosa seria (③).

### ② M2 — la strada lenta, misurata due volte

`vs_coord_rebuild:station_nodes/0` è `[N || N <- nodes(), not lists:member(N, Coords)]`:
**«asked 0 station node(s)» non vuol dire che le stazioni tacciono, vuol dire che il leader
nuovo non aveva una connessione dist verso di loro.** Non il silenzio, la lista dei conoscenti.

La misura buona è arrivata **da sé**, alla riconnessione di M1 (connessioni smontate dal tick e
non ancora ristabilite):

```
14:35:35.556  rebuild: asked 0 station node(s), waiting up to 2000 ms
14:35:37.557  0 station(s) answered with 0 claim(s) -> serving with 0 adopted claim(s)
14:35:42.96   coord3: 2 claim        <-- rientrati dal CICLO DI RENEW, non dal rebuild
```

**7,41 s** in tutto (2,00 di finestra piena + 5,40 di fase del renew). Predetto **3-13 s,
centro ~8**: dentro. Il «~12 s» del piano è il **bordo alto**, non il centro — i dieci secondi
di periodo si pagano interi solo con la fase peggiore. La ricetta deliberata
(`erlang:disconnect_node/1` da coord2 verso le stazioni, poi `docker stop coord3`) riproduce il
presupposto a comando, ma `global` stacca anche i coordinatori fra loro
(«*to prevent overlapping partitions*») e la corsa diventa una rielezione: buona come prova
della ricetta, non come misura.

### ③ Il difetto: P18, GRAVE, trovato guardando la riconnessione

Nei **5,40 s** in cui coord3 serviva con la tabella vuota, la domanda ovvia era se in quella
finestra si potesse rompere l'esclusività. Sì. Riprodotto con una gara a 300 ms:

```
14:45:45.647  coord3    serving with 0 adopted claim(s)
14:45:45.919  station2  connector 5 reserved by user 12 (claim c-EED83F0B90A0F402)   <-- CONCESSA
14:45:59.570  station2  claim c-EED83F0B90A0F402 revoked by the coordinator
```

**272 ms** dopo l'inizio del servizio, il veicolo 88 — che stava **caricando** su station1 —
tiene due prenotazioni su due stazioni. Dura **13,65 s**, poi «oldest wins» (§5.5) revoca
quella nuova e la ricarica non viene toccata: la regola sceglie il verso giusto.

La difesa esiste e `vs_coord_rebuild` la documenta («*zero answers is when we know least, so
that is the one case that waits out the full window*»), ma è **2000 ms contro un periodo di
renew di 10 000**: copre un quinto di ciclo. **Non corretto**, P18 in `PROBLEMI_TROVATI.md` con
le due direzioni possibili — allungare l'attesa a un periodo di renew, oppure non passare a
`serving` con zero risposte *e* zero claim. È un compromesso disponibilità/correttezza, da
discutere.

### ④ M3 — la scadenza naturale, e perché la ricetta ovvia non funziona più

**Post-P15 uccidere il connettore non produce una scadenza: produce un rilascio in
millisecondi** (il `DOWN` fa partire `cast_leader({release, …})`). Servono quattro condizioni
insieme: nessun `release` che parta (il client deve morire **senza processare il `DOWN`**),
nessun renew, **nessuno che ripresenti** (P14: il connettore non deve essere vivo e con
l'`hold` quando il client riavviato chiede), e il nodo stazione **vivo e connesso** — perché
`{nodedown, Node}` → `forget_node/2` butta la stazione *e i suoi claim*, quindi un
`docker kill station1` farebbe sparire il claim subito invece che in 960 s.

Ricetta che le soddisfa: due `exit(Pid, kill)` consecutivi dal nodo sonda, client per primo —
stesso canale dist, stesso segmento TCP. I log lo confermano: due `SUPERVISOR REPORT` con
`reason: killed` nello **stesso millisecondo** (14:14:02.452).

E una cosa che nessun documento diceva: **la scadenza si conta dall'ultimo renew, non dalla
concessione**, perché `do_renew/3` ricalcola `NewExpiry = now_ms() + (Lease+Grace)*1000` a ogni
giro. Predetto «fra 950 e 960 s dall'uccisione»; misurato **956,955 s**.

```
14:14:02.452  uccisi client + connettore     -> orfano: coord3 1 claim, client 0 claim
14:14:22.924  station2 -> NO_CLAIM "your vehicle already holds a reservation"
              (connettore locale gia' `free`: nessuna prenotazione esiste, e il veicolo
               e' escluso da tutta la rete — la forma di P15, ma questa si sana da sola)
14:29:59.407  expires_at
14:29:59.727  T+320 ms: l'orfano e' ANCORA nella mappa del coordinatore
14:29:59.846  T+439 ms: prenotazione dello stesso veicolo su station2 CONCESSA
```

**Il meccanismo è la lettura pigra, non lo scrub.** `live_claim/2` passa da `vs_time:expired/1`
(`now_ms() >= ExpiresAt`) e tratta un claim scaduto come assente: il veicolo è tornato libero
**mentre la riga era ancora fisicamente lì**. Lo scrub non è mai passato su quell'orfano — nel
log di coord3 non c'è nessun `sweeping N expired claim(s)` — perché il claim nuovo per lo
stesso veicolo ha sovrascritto la riga via `store/2` prima del giro da 5 s. Risposta esatta:
**la lettura pigra ha liberato il veicolo, `store/2` ha tolto la riga, lo scrub non ha avuto
occasione.**

Lo scrub l'ho osservato a parte, in una corsa dichiarata a timer accorciati
(`LEASE_SECONDS=20 CLAIM_GRACE_SECONDS=5`, coordinatori riportati ai default subito dopo e
riverificati): `sweeping 1 expired claim(s)` **23,5 s** dopo l'uccisione. Non è la misura dei
960 s: è la conferma del secondo meccanismo.

### ⑤ M4 — il redirect circolare, prodotto nei container

Fino a oggi solo in eunit. Serve uno standby il cui `leader` punti a un nodo che non serve:
esiste per i ~2 s in cui un leader appena eletto è `rebuilding`. Sonda a 250 ms già in corsa
prima della perturbazione:

```
14:45:43.812 .. 14:45:45.571   coord1 -> {not_serving,vs@coord3}   coord2 -> {not_serving,vs@coord3}
                               (e coord3 in quel momento era `rebuilding`)
```

E il giro non si è chiuso, provato **sul percorso vero del client**: in quella finestra un
conducente su station2 ha ricevuto **undici `RETRY_LATER` di fila** — cioè
`map_refusal(rebuilding)` — invece di rimbalzare. Il client ha seguito **un** redirect, ha
trovato un nodo che rifiuta, e ha restituito il rifiuto: è il flag `Followed` di `try_nodes/4`.
**Un redirect solo, mai un giro**, sul codice di produzione.

### Verificato — girato davvero

- `beam_lib:md5` uguale host/container su cinque nodi, prima di misurare;
- `./src/scripts/eunit_check.sh` → **386 tests, 0 failures** prima e dopo: nessun codice
  toccato, l'ambiente non ha sporcato il repo;
- ambiente rimesso e **verificato**: 7 container tutti e soli su `voltshare_voltshare`, zero
  claim su tutti e cinque i nodi, connettori `{4,0,0}` e `{3,0,0}`, `LEASE=900 GRACE=60`
  riletti dai coordinatori, `git status --short` vuoto;
- `sessions`: **due righe aggiunte** (17 e 18), dalle due ricariche vere della scena di M1 e
  della prova della ricetta pixel. Non ne è stata cancellata nessuna: la stazione in `sessions`
  solo inserisce.

### Non provato — e perché

- **I pixel**: nessuna estensione browser in questa sessione, come il prompt prevede. In
  `REPORT_M3A_CODA.md` §7 c'è la ricetta della scena **provata per intero al primo colpo**
  (comandi, URL, e il fatto che **non esiste una credenziale di prova**: `schema.sql` non
  semina utenti, l'unico utente del DB ha `'$2a$10$fixture.not.a.real.hash'` come hash e
  `cc-probe` in questo database non c'è più — si entra registrandosi da `/register.jsp`, che
  crea utente e veicolo e fa login da solo).
- **Lo scrub sulla scadenza vera dei 960 s**: per vederlo servirebbe una seconda corsa da
  sedici minuti in cui nessuno riprenoti quel veicolo, cioè rinunciando alla prova della
  lettura pigra. Ho scelto la lettura pigra.
- **Il caso peggiore della strada lenta** (fase sfavorevole, ~12-13 s totali): le due corse
  hanno estratto 5,40 s e 13,65 s di attesa; il totale peggiore resta interpolato.
- **Una seconda misura di P18**: colto una volta, su 272 ms di margine. Riproducibile ma non
  deterministico: va scritto in eunit, dove la finestra si controlla.

---

## 7zk. Il giro intero guardato coi pixel, nel Chrome vero — 1 settembre

L'ultima cosa che restava fuori dal M1-A, e ci è rimasta per settimane. Fino a oggi la logica
del rendering era provata con un **DOM minimale in Node** (23 controlli, §1): dimostra che il
codice reagisce ai frame giusti, **non** che una persona davanti a uno schermo vede la cosa
giusta. Le due domande sono diverse, e la seconda non si risponde con un test.

Perché ci è voluto tanto: il browser interno dell'assistente **non fa passare i WebSocket** verso
un'origine diversa, quindi la pagina live non si può guardare da lì. Serve il Chrome vero, a
mano, con lo stack su. E non esiste una credenziale di prova — `schema.sql` semina solo
`stations` e `connectors` — quindi si entra da `/register.jsp`, che crea utente **e** veicolo e
fa login da solo (ricetta in §7zj, «Non provato — e perché»).

### Cosa è stato visto, in ordine

Registrazione; griglia dei connettori; prenotazione con il **conto alla rovescia che scende da
solo**; `charging`; **stop dal browser** → `complete` istantaneo, con la potenza che rientra nel
pool e le altre auto che salgono; `complete` → **`overstay`** al tick successivo, col cavo ancora
dentro; la riga comparsa in **`/notifications`**; e in **`/history`** la sessione chiusa a
**1,58 kWh · overstay 10 min · € 5,71**.

### Le due cose che solo i pixel potevano chiudere

1. **Il fuso.** I timestamp in tabella sono UTC (scelta di progetto, §7s); la conversione la fa
   `Times.java`. L'ora mostrata in `/notifications` e in `/history` è quella **locale**, non
   quella del database: era l'ultima pendenza di M2-A, e non si poteva vedere altrove.
2. **Il conto al centesimo.** € 5,71 lega la riga scritta dalla stazione — `energy_kwh` e
   `overstay_seconds` **netto** — al prezzo calcolato da B. Verificato a mano: è il punto in cui
   le due metà del progetto si toccano davvero, e un errore di tolleranza (sottratta due volte, o
   mai) sarebbe comparso qui e in nessun test.

### Non provato — e perché

Osservazione **a mano, su una corsa sola**: non è una misura ripetibile e non pretende di esserlo.
Restano **tre cose mai viste con gli occhi**, tutte per la prova generale di M5:

- il **riparto 75 · 75 · 50** sotto scarsità — il meccanismo è misurato (§7q), i pixel no;
- le **pagine del no-show**: profilo sospeso e notifiche con gli strike — misurati al database
  (§7zg, §7z), mai guardati;
- il **giro intero col cronometro**, cioè la demo dentro il tempo che ha.

---


---

## 7zl. P18, la nostra metà: ripresentare all'evento invece che al prossimo giro — 2 settembre

Branch `a/p18-nodeup`. La metà del difetto che è nostra, con la sua misura; la metà di B è una
**decisione**, non una correzione, e gliela abbiamo chiesta con i numeri in mano
(`src/contracts/nota-per-B-p18.md`).

**Il difetto non era il meccanismo, era il momento.** La ripresentazione dei claim esisteva già
ed era corretta — il `renew_tick` manda tutti i claim col `granted_at` originale, il redirect
`not_serving` viene seguito, e il coordinatore adotta un claim che non conosce. Mancava
*quando*: partiva al tick, fino a 10 s dopo, mentre la finestra pericolosa si apre ~2 s dopo il
rientro del leader. Ora `net_kernel:monitor_nodes(true)` e due clausole **sopra** il catch-all:
un coordinatore che torna → riannuncio e giro di renew immediato. Nessun messaggio nuovo, nessun
contratto toccato, **nessuna riga sotto `vs_coord/`**, e il tick periodico intatto (il giro
immediato è *in più*, non *invece*).

### Le quattro verifiche fatte prima di scrivere una riga di codice

| | risposta |
|---|---|
| il `nodeup` arriva alla stazione senza che sia lei a parlare per prima? | **sì**, a **959 ms** dal `docker network connect` — con la stazione a zero claim e leader ≠ coord3, cioè senza alcun motivo di rivolgersi a lui. È **342 ms dentro** la finestra di rebuild e **1,7 s prima** che il leader cominci a servire |
| il `do_renew` di B con una stazione sconosciuta | **adotta** (`vs_coord_srv.erl:472-486`, e la clausola `error ->` di `renew_one/4` a `:524-538`); `unknown_station` sta solo in `check_can_grant/4` (`:432`), sul percorso `acquire`. Quindi l'annuncio prima del renew è **precedenza, non necessità** — ma serve lo stesso, perché l'adozione riempie `claims` e mai `stations` |
| quanto rumore fa `monitor_nodes(true)` | rientro del solo leader: **1 `nodeup`**. Isolamento della stazione: **4 in 271 ms**, i tre coordinatori entro 11 ms. Il back office non compare (parla solo coi coordinatori); i nodi `-hidden` non generano eventi (misurato: 0 su cinque connessioni di sonda) |
| la latenza era già misurata dal pair 2? | **no**: §1.2 di `REPORT_M3A_CODA` dà ~10 s con una sonda che campionava ogni 4 s — un tetto, e nel verso sbagliato. Andava rifatta |

La terza ha deciso una cosa che sembrava stile: **il filtro sui `coord_nodes` va prima del
debounce**, perché il primo `nodeup` della raffica è di una *stazione*, 260 ms davanti ai
coordinatori — e un debounce segnato prima del filtro farebbe ingoiare proprio i tre che
contano.

### Verificato — girato davvero

- **`beam_lib:md5` prima e dopo**: 17 moduli su 5 nodi identici all'albero host **prima** di
  misurare (la precondizione che il pair 2 trovò falsa il 01/09, quindi rifatta e non ereditata);
  e dopo la ricostruzione, `vs_claim_client` = `61c5adf7…` su host, station1 e station2, con
  `vs_connector` e `vs_station_mgr` **invariati** — il perimetro chiuso verificato in binario;
- **suite 386 → 392**, `EXPECTED_TESTS` aggiornato nello stesso commit, **tre giri consecutivi
  verdi** (`392 tests, 0 failures` × 3);
- **ogni test nuovo visto rosso senza il suo pezzo di fix**, con cinque mutazioni una per volta:
  tolto il debounce → rosso il test della raffica; tolto il filtro → rosso quello del nodo
  estraneo; tolto l'annuncio → rossi quattro; `nodedown` che svuota la tabella → rosso il suo;
  tolto il `send_after` del tick → rosso il test dell'estrazione (e anche un test preesistente,
  che è la conferma che il tick serviva davvero a qualcuno);
- **le clausole nuove sopra il catch-all, provato spostandole sotto**: il compilatore emette
  `this clause for handle_info/2 cannot match because a previous clause always matches` (due
  volte) e **quattro** dei sei test diventano rossi. Sotto sarebbero codice morto e i test
  sarebbero verdi per il motivo sbagliato;
- **E2E, scena vera** (connettore 1 prenotato, connettore 3 in carica a 150 kW, partizione del
  leader e rientro), predizione scritta prima e corse singole:

| | finestra di esposizione | riga del coordinatore | `stations` all'inizio del servizio |
|---|---|---|---|
| prima | **4,11 s** | `serving with 0 adopted claim(s)` | `[]` per altri 19,7 s |
| dopo | **0 ms** | `serving with 2 adopted claim(s)` | `[1,2]`, 1,74 s prima |

  Lo zero è verificabile e non ottimistico: l'osservatore a 100 ms ha fotografato coord3 ancora
  in `mode=rebuilding` con già `vehicles=[88,201]` e `stations=[1,2]`. E la riga del rebuild è
  rimasta `asked 0 station node(s) … 0 station(s) answered`: **la strada di B non è cambiata**,
  la finestra che lasciava vuota è stata riempita dal nostro renew.

### Non provato — e perché

- **La finestra non si chiude, e non pretendiamo che si chiuda.** Lo zero è l'esito di *questa*
  corsa: il renew immediato deve vincere una gara col leader uscente, e il margine misurato su
  quella gara è **265 ms**, non 1,74 s. Se il coordinatore serve a tabella vuota prima che
  chiunque possa parlargli, nessuna prontezza della stazione arriva in tempo — per costruzione.
  A chiudere è la metà di B, che è una scelta di disponibilità e non un bug fix.
- **Una seconda corsa E2E «dopo»**: una sola, come la «prima». Le due si confrontano perché lo
  scenario è identico, non perché siano una statistica.
- **Il veicolo che ottiene la seconda prenotazione** non è stato riprovato: l'1/09 fu colto su
  272 ms di margine, quindi riproducibile ma non deterministico, e non è la cosa che si misura.
  Ciò che si misura è la finestra.
- **`warnings_as_errors` non è in vigore su `apps/`** — trovato correndo le mutazioni e
  **riprodotto a mano il 02/09** su un albero pulito: una funzione non esportata con dentro una
  variabile mai usata, aggiunta a `apps/vs_common/src/vs_time.erl`, produce due warning e
  `rebar3 compile` esce comunque **0**. La causa è la forma `{del, Options}` senza nome
  applicazione in `rebar.config`, che vale per tutte le applicazioni e non solo per le
  dipendenze. **Il comportamento non è corretto** — è una modifica al build di tutto l'albero e
  vale un pair suo — ma **il commento che affermava il contrario sì**, perché era una riga falsa
  in un file versionato, accanto alla riga che la smentiva. Il ragionamento in
  `scelte_di_progetto.md` §27.7, con la correzione anche a §9.10, che diceva la stessa cosa
  sbagliata dal 24/08. Conseguenza da sapere: la regola «`main` verde con `warnings_as_errors`»
  non copre `src/` più di quanto copra i test — cioè non copre niente, e va detta a B, che nella
  `risposta-per-A-review-pr5.md` §99 aspetta una pulizia sul presupposto opposto.
## 7zm. Passata di review su tutto il progetto, e la demo resa lanciabile — 2 settembre

Tre lavori nella stessa giornata: una review completa di `src/`, gli otto file che il runbook
della demo dava per esistenti e non esistevano, e la caccia a un guasto dell'infrastruttura che
ha finito per scoprirne uno peggiore.

### La review: tredici rilievi, sei miei

Non un diff — tutto `src/` a `78aa01c`, aprendo i file. **Sei erano miei e li ho corretti**;
sette sono nel perimetro di A e stanno in `contracts/review-per-A-progetto.md`, **ancora da
mandargli**.

I due miei che contano, e sono entrambi nel coordinatore:

1. **`vs_coord_rebuild:run/1` faceva `spawn_link`**, e `vs_coord_srv` non fa `trap_exit`. Una
   qualunque eccezione nel worker — per esempio un `{holds, …}` malformato da una stazione —
   avrebbe ucciso **il processo che tiene tutti i claim della rete**, e `rest_for_one` avrebbe
   portato giù l'intero sottoalbero. È lo stesso guasto che il catch-all in `renew_one/4`
   esiste per prevenire, reintrodotto due milestone dopo **da una parola**. Ora è
   `spawn_monitor`.
2. **Lo stato `rebuilding` non aveva uscita.** L'unica via era il messaggio `{rebuilt, _}`: se
   il worker moriva prima di mandarlo, il coordinatore rifiutava **ogni prenotazione della rete,
   per sempre**, e nei log non c'era niente a dirlo. Ora ci sono il `DOWN` del monitor e una
   deadline di sicurezza (`deadline_ms/0`); in entrambi i casi si passa a `serving` con un
   warning, perché i rinnovi adottano comunque entro dieci secondi e restare bloccati è
   strettamente peggio.

Gli altri quattro: **XSS stored** nello username reso senza `<c:out>` in `page.tag` — e quel
tag rende su **ogni** pagina autenticata, mentre `validate` controlla solo la lunghezza 3-50,
quindi `<img src=x onerror=…>` (32 caratteri) passava la registrazione; e tutto il percorso
delle sospensioni che leggeva e scriveva con l'orologio della JVM mentre `sessions` è in UTC,
ora unificato su UTC con `util/Times.java` per la resa in `APP_TIMEZONE`.

Vale la pena notarlo per l'orale: i primi due sono difetti di **supervisione**, non di logica.
Il codice era corretto; sbagliato era cosa succede quando non lo è.

### Gli otto file della demo, e uno scritto da zero

`DEMO.md` dava per esistenti `.env.demo`, `seed-demo.sql` e sei script. Non c'erano. Creati
tutti; due meritano una riga.

**`emulator/demo/reserve.js`, scritto da zero.** A lo dava per esistente come
`scena-pixel-driver.js`, che non è mai arrivato. Serve per una battuta sola: lasciare **una
prenotazione in piedi** prima del failover. Non si può usare `driver.js --scenario
one-vehicle`, che alla fine cancella deliberatamente la prenotazione superstite, né un walk-in
via `cp.js`, che non crea nessun claim (`vs_connector:free/3` adotta la sessione con `claim_id
= undefined`). Senza, la battuta del failover mostrerebbe il nuovo leader che ricostruisce una
tabella vuota: il coordinatore che funziona perfettamente e non dimostra niente.

**`emulator/demo/coord-status.sh`, riscritto.** La versione dell'appendice usava `erl -remsh`
col comando su stdin e **non stampava niente**: la shell remota legge l'EOF e termina prima di
emettere il risultato, si vede solo `*** Shell process terminated! Read EOF ***`. Ora avvia un
nodo effimero che fa una `rpc:call` e chiude — nessuna shell di mezzo, nessun EOF da cui
dipendere — e riporta anche le sospensioni.

### Il container zombie che erano dieci, e il guasto peggiore che ci stava sotto

Sintomo: la lobby diceva «no station is reporting» con `mysql` e `backoffice` regolarmente su.
`docker ps -a`: **cinque container `Exited (137)`** (coord1/2/3, station1/2) e **cinque in
`Created`** con nomi prefissati da un hash. Causa: un `up -d --build` interrotto a metà. Compose
rinomina il vecchio container con un prefisso, crea il nuovo, poi rimuove il vecchio; fermarlo
nel mezzo lascia i vecchi uccisi e i nuovi mai partiti.

**Ripulito con `down --remove-orphans`, che ha funzionato e ha cancellato il database.** Il
servizio `mysql` non aveva un volume nominato: l'unico `volumes:` era il bind di sola lettura
di `schema.sql`, quindi i dati stavano nel layer scrivibile del container. Persi utenti,
sessioni e notifiche, compreso l'account del presentatore. Errore mio: andava detto **prima** di
lanciare il comando, non dopo.

Il danno è stato nullo perché erano dati di prova, ma ha reso visibile una cosa che il giorno
della demo sarebbe costata cara, e ne ha portata a galla una seconda: il primo boot su database
vuoto ha impiegato **oltre sei minuti**, e la healthcheck (20 tentativi × 5 s) è scaduta molto
prima — quindi stazioni e back office si sono rifiutati di partire contro un database che era
soltanto lento. Sembrava tutto rotto mentre MySQL stava solo nascendo.

**Correzione, in `docker-compose.yml`:** volume nominato `mysql-data` su `/var/lib/mysql`,
`retries` da 20 a 60 e `start_period: 30s`. Da ora `down` è innocuo e `down -v` è l'unico modo
di perdere i dati — un atto deliberato invece di un effetto collaterale.

Una trappola trovata verificando: **la healthcheck può passare sul server sbagliato.** L'entrypoint
di MySQL alza un server temporaneo per eseguire gli script di init, e `mysqladmin ping -h
localhost` passa dal socket, quindi risponde già lì; il mio primo caricamento del seed è finito
proprio nella finestra fra la chiusura di quello temporaneo e l'apertura di quello vero
(`Can't connect … through socket`). Chi semina subito dopo un boot pulito deve aspettare le
**tabelle**, non il ping.

### Il ping di M0, acceso da quattro milestone

Provando i pannelli della demo, il log della stazione era **illeggibile**: due righe ogni tre
secondi, per stazione, di `ping vs@station2 -> pong from vs@station2`. È `vs_ping`, la sonda
di connettività di M0, sostituita in M1 da `COORD_NODES` e dal claim client vero e lasciata
accesa per abitudine — `vs_station_sup` la descrive già come *«retired when the real claim
client arrived»*, ma `PING_TARGET` era ancora nel compose.

Il filtro che `DEMO.md` suggeriva, `grep -v ping`, **non funziona** e questo è il dettaglio
che vale la pena ricordare: il logger di Erlang stampa due righe per messaggio, una
intestazione `=NOTICE REPORT==== <timestamp> ===` e il testo. Togliendo la riga col ping
restano le intestazioni orfane, cioè il pannello continua a scorrere mostrando **solo**
timestamp. Sembrava che la stazione non stesse loggando niente; stava loggando solo rumore
a cui era stata tolta la metà riconoscibile.

Tolto `PING_TARGET` dai due servizi. Nessuna modifica al codice e nessuna ricostruzione:
`vs_ping:init/1` senza target non arma il tick e si limita a rispondere, e lo dichiara nel
log — `vs_ping ready on vs@station1 (answering only)`. Per sondare a mano resta
`PING_TARGET=vs@station2 docker compose up -d station1`.

**Effetto collaterale utile**: ricreare le due stazioni ha staccato le due auto di sfondo, e
si sono **riagganciate da sole al primo giro** — il backoff di `cp.js` provato senza volerlo.

### La catena delle penalità si è dimostrata da sé, dal vivo

Mentre spiegavo la logica del no-show, l'account del presentatore si è **sospeso da solo**:
due prenotazioni fatte dal browser e mai onorate, a 90 s di lease. Le due notifiche in
tabella, con l'ora:

```
15:37:22  reservation_expired  "… 1 of 2 — reaching 2 suspends reservations for 1 day(s)."
15:39:02  suspended            "Reservations are suspended until 03/09/2026 17:39 …"
```

È il beat marcato 🔴 nella checklist di `DEMO.md` — *«meccanismo misurato al database il
31/08; queste sono le pagine, mai viste»*. Ha girato tutto: stazione che segnala, coordinatore
che inoltra, Java che conta, scrive la sospensione, azzera il contatore e la **spinge al
leader** (`coord3 suspensions=1`). E c'è la prova del fuso in una riga sola: `15:39:02` in
tabella (UTC), **17:39** nel testo della notifica, cioè l'ora di Roma — `util/Times.java`
scritto stamattina.

**Una cosa trovata sbloccando l'account**: `ErlangBridge.notifyUnsuspension(int)` esiste, e
`vs_coord_srv` ha la clausola `{user_unsuspended, UserId}` che la riceve, ma **nessuno in Java
la chiama**. Non è un difetto di comportamento — `is_suspended/2` confronta `Until >
erlang:system_time(second)`, quindi la sospensione decade da sola all'ora giusta — ma sono un
metodo morto e una voce che resta nella mappa del coordinatore per sempre. Per togliere una
sospensione in anticipo (come oggi) bisogna scrivere sul database **e** mandare il messaggio a
mano via `rpc`, altrimenti la ripubblicazione del back office la rimette entro 30 secondi.
Annotato, non corretto.

### Verificato — girato davvero

- **Il volume regge un `down`**: riga marcatore inserita in `users`, `docker compose down`
  completo (container e rete rimossi), `up -d`, riga **ritrovata al primo tentativo**,
  `utenti=7`. Marcatore poi cancellato, `utenti=6`. `docker volume ls` mostra
  `voltshare_mysql-data`.
- **Nessuna reinizializzazione al secondo boot**: sul volume già popolato MySQL ha risposto al
  primo colpo, contro i >6 minuti del primo. È la misura che giustifica la modifica.
- **Stack completo risalito**: 7 container su, `mysql healthy`, `GET /` → `302` (redirect al
  login, cioè `AuthFilter` vivo), `coord3 mode=serving` con coord1 e coord2 in `standby` —
  l'ordine bully atteso, il rango più alto vince.
- **Seed ricaricato**: 6 utenti, 6 veicoli, 2 stazioni, 7 connettori.
- `eunit_check.sh` verde a **386**, Java 14 test verdi (dalla passata di review).

### Non provato — e perché

- **La demo non è ancora stata corsa per intero.** Lo stack è sano e seminato, ma l'account del
  presentatore è morto col database e va **ri-registrato da `/register`** prima di cominciare,
  rileggendo `$PV`.
- **I sette rilievi ad A non gli sono ancora arrivati.** `review-per-A-progetto.md` è scritto e
  committato; il più concreto è il clamp mancante su `idle_timeout` in `vs_cp_ws`, che con
  `CP_HEARTBEAT_MISSED=1` dà `0` e chiude ogni socket colonnina appena inattivo.
- **Il PR di `b/review-progetto` non è aperto**, quindi niente di questo è su `main`.

---

## 7zn. Provando la demo per davvero: quattro difetti, tutti trovati guardando — 3 settembre

Nessuno di questi è emerso da un test. Sono emersi perché per la prima volta abbiamo
**guardato girare la demo intera** invece dei pezzi. Vale la pena dirlo nella relazione: la
suite era verde a 386 mentre tutti e quattro erano lì.

### ① Il coordinatore era muto sulla decisione che lo definisce

`vs_coord_srv` ha **ventitré** chiamate al logger. Nessuna su `do_claim/6`. Concedere o
rifiutare un claim — l'atto che l'intero cluster esiste per compiere — non lasciava traccia
da nessuna parte, e il **rifiuto** non era loggato nemmeno dalla stazione: `NO_CLAIM`
esisteva solo come frame in un browser.

In scena significa che la battuta centrale («nessuna delle due stazioni può decidere da
sola, decide il coordinatore») non aveva niente a supporto sui log. Aggiunte due
`logger:notice`, sui due rami:

```
coord3  claim GRANTED to vehicle 103 (user 103) on station 1 connector 3 — c-67C6BC73
coord3  claim REFUSED to vehicle 103 (user 103) on station 2 connector 5 — already_held
```

`notice` e non `info` deliberatamente: una corsa di contesa che stampa quindici rifiuti e
una concessione è **il quadro più chiaro di P2 che il sistema sappia produrre**, non
rumore.

### ② Quattro pannelli erano un errore di impostazione

Il §5 di `DEMO.md` prescriveva un riquadro per servizio. Provandolo: ingestibile, e
sbagliato in linea di principio — **la storia è una sola** (browser → coordinatore →
stazione → Java) e su quattro riquadri è a pezzi.

Scritto `demo/logs.sh`: i sette servizi in una colonna, ordinati nel tempo, con l'ora e il
nodo colorato. Tre cose lo rendono leggibile e senza di esse non lo sarebbe: il timestamp
di Docker (`-t`) ridotto a `HH:MM:SS`; le intestazioni `=NOTICE REPORT==== … ===` buttate
via (**il logger di Erlang stampa due righe per messaggio** e la prima non dice niente); e
il colore per nodo, che è l'unica cosa che permette di seguire un attore senza rileggere.

Il rumore tolto è solo periodico: la ripubblicazione del leader ogni 30 s, il ciclo di vita
di Tomcat, e il ping di M0 se qualcuno lo riaccende. `VERBOSE=1` rimette tutto.

### ③ `world.sh` non sorvegliava le sue auto

Lanciava i due `cp.js` con `&` e poi `wait`. Se **una** moriva, `wait` restava sull'altra e
la morta **non ripartiva mai**. La conseguenza non è "manca un'auto": trenta secondi dopo
la stazione dichiara quel connettore `out_of_service`, perché una presa senza
apparecchiatura non è una presa libera. Lo sfondo si spegneva a metà demo senza che si
capisse perché.

Ora ogni auto gira in un ciclo che la rilancia, con una pausa di 3 s. Distingue due casi,
come farebbe un supervisore OTP: uscita 1 o segnale = incidente, si rilancia; **uscita 2**
(`die()`: connettore inesistente, 4404, o 4409) = errore di configurazione, non si
rilancia, perché si ripeterebbe identico e verrebbe nascosto.

Verificato uccidendo un `cp.js` con `taskkill`: `world: conn 6 uscito (codice 1), rilancio
fra 3s`, e il connettore è tornato **da `out_of_service` a `charging` da solo**.

### ④ `cp.js` diceva di essere la colonnina ma viveva quanto l'auto

Il difetto più interessante dei quattro, perché è di **modellazione**, non di codice.

`unplug()` finiva sempre in `process.exit(0)`. Ma una colonnina è avvitata al muro e resta
collegata al back end per anni mentre le auto vanno e vengono; questo processo sosteneva di
esserne una e durava quanto una singola macchina. Quindi **ogni sessione completata
lasciava la presa incustodita**, e trenta secondi dopo la stazione — correttamente, non
avendo modo di distinguere "hardware sparito" da "hardware rotto" — la dichiarava
`out_of_service`.

Misurato dal vivo: `session 2 written: connector 2, user 108, 11.817 kWh` (fatturata,
`cost_cents = 532`), poi `charge point socket gone in free (normal)`, poi
`no charge point for 30000 ms - out of service`. Due battute e mezza stazione sarebbe stata
spenta.

Aggiunto `--stay`: alla fine il processo non esce, tiene il socket e manda
`status: available` — che è anche ciò che **solleva** un connettore da `out_of_service`
(`vs_connector`: *"out_of_service ──charge point boots available──▶ free"*). Passato da
`presenter-cp.sh` e `world.sh`, quindi i comandi in scena non cambiano.

### Il contorno, sempre dal guardare

- **`--soc 45 --battery 60 --max-kw 150` erano i default di `cp.js`.** Il copione li faceva
  riscrivere in ogni comando. Tolti: restano due numeri per comando, connettore e veicolo.
- **La query SQL per leggere il veicolo era inutile**: `profile.jsp:18` stampa
  `Vehicle #${account.vehicleId}`, ed è una pagina già aperta nel browser.
- **`ErlangBridge.notifyUnsuspension(int)` non ha chiamanti** (già annotato in §7zm). Scritto
  `demo/unsuspend.sh`, che fa i due passi nell'ordine giusto: prima la riga, poi l'`rpc` ai
  tre coordinatori — al contrario la ripubblicazione del back office rimette la sospensione
  entro 30 s.
- **Il ping di M0 aveva un gemello**: tolto `PING_TARGET`, resta che il rumore periodico va
  cercato ovunque prima di una presentazione, non solo dove dà fastidio per primo.

### Verificato — girato davvero

- `eunit_check.sh` **386, 0 failures** dopo la modifica al coordinatore; immagine
  ricostruita e i tre coordinatori ricreati (condividono `voltshare-coord:local`, quindi un
  solo `build`).
- `claim GRANTED` / `claim REFUSED` visti nei log durante un P2 vero: `reserve.js` sul
  connettore 3 di Pisa concesso, sul 5 di Livorno rifiutato con `already_held`.
- Supervisione di `world.sh`: `cp.js` ucciso, rilanciato dopo 3 s, connettore risalito da
  `out_of_service` a `charging`.
- `--stay`: carica fino al 26%, `unplugged` a 0,805 kWh, `cable out — charge point stays
  online, connector free again`, connettore **`free`** e processo ancora vivo.
- Connettore 2 riportato in servizio attaccandogli una colonnina che non infila nessuna auto
  (`--plug-after 9999 --stay`). Pisa: `1 charging, 2 free, 3 free, 4 free`.
- Fatturazione end-to-end sulla sessione reale: 11,817 kWh → `cost_cents = 532`.

### La tolleranza ai guasti, finalmente scritta in un posto solo

`DESIGN-NOTES` §4 copriva il coordinatore — elezione, quorum, ricostruzione — e basta. Tutto
il resto era **nei commenti del codice**, che è il posto giusto per implementarlo e quello
sbagliato per difenderlo all'orale. Scritta `DESIGN-NOTES` §4c, in inglese come il resto del
documento.

La tesi che tiene insieme la sezione, e che vale la pena dire con queste parole: **la
tolleranza discende dalla proprietà dello stato, non dalla replicazione.** Ogni componente
tiene solo ciò che possiede, e ogni altro tratta quello stato come recuperabile dal suo
proprietario. Da lì discendono cose che sembrano scelte separate e non lo sono: perché non
serve un log replicato, perché i claim si recuperano *chiedendo* e le sospensioni
*spingendo*, perché una stazione morta libera i suoi veicoli.

Contenuto: il modello di guasto in tabella (cosa fallisce, come si accorge, cosa succede,
cosa si perde); **i due rilevatori e perché ce ne vogliono due** — con le tre misure
dell'1/09, e l'osservazione che `docker kill` non esercita affatto quel percorso, perché
chiude il socket; la stazione che muore e perché il coordinatore le scarta i claim invece di
aspettare il lease; la colonnina che muore, i 30 s di grazia e la sessione chiusa con
l'ultima energia misurata; **le tre strategie di supervisione e cosa afferma ciascuna**, con
i due difetti di review che erano guasti di supervisione e non di logica; e le **tre
garanzie di consegna diverse sullo stesso filo**, scelte per messaggio invece che per
canale.

E la parte che conta di più per il voto: **cosa non tollera niente**, dichiarato — MySQL,
le sessioni sulla stazione morta, e P18 con i suoi numeri.

**Una correzione in `SCOPE.md` §5.** P4 sosteneva che *"sessions in progress are reconciled
for billing on restart"*. **È falso**: la riga in `sessions` la scrive la stazione alla
chiusura, quindi se il nodo muore a metà sessione non viene scritto niente, e al riavvio i
connettori ripartono senza memoria. Ciò che davvero sopravvive è la **misura**, e non per
merito nostro: la colonnina è l'unico lato che conta l'energia e la riporta nel `plugged`
che rimanda alla riconnessione. Riscritto per dire quello che succede. Aggiunto anche un
paragrafo sui due rilevatori, perché condiziona ciò che P2b e P4 possono promettere.

**Due file citati da PROGRESS non esistono nel repository**: `PROBLEMI_TROVATI.md` e
`REPORT_M3A_CODA.md`, entrambi di A, mai committati. I riferimenti in §7zj restano perché
sono la sua cronaca; ma dove servivano a sostenere un'affermazione — P18 in `DESIGN-NOTES`
§4c — ho messo i numeri per esteso invece del rimando, così la frase regge da sola.

### ⚠️ La sezione qui sotto è sbagliata nella diagnosi, e la correzione sta dopo

Quello che segue è stato scritto e committato (`3840cc8`) sulla base di una misura letta
male, e **la modifica è stata annullata lo stesso giorno**. Lo lascio perché la conclusione
finale non si capisce senza, e perché l'errore è più istruttivo del risultato: vedi *«La
misura rifatta piano»* più sotto.

### La partizione di una stazione, che dichiaravamo e non sapevamo mostrare

Il guasto più raccontabile del progetto — **il sito funziona, le auto caricano, l'operatore
non lo vede più** — era indimostrabile, e per un motivo che non stava nel codice.

`SCOPE` §6 dice da sempre che la stazione è un *site controller* e *«must keep working when
the connection to the operator's cloud is down»*. Ma gli emulatori `cp.js` giravano sul
portatile e raggiungevano la stazione attraverso una porta pubblicata sul bridge del
cluster: `docker network disconnect station2` tagliava l'uplink **e i cavi** insieme.

E il sintomo era abbastanza sottile da essere creduto: la stazione isolata continuava a
dire `charging`, con l'energia **ferma a 34,523 kWh su tre letture consecutive**. Non
un'auto che carica: l'ultima misura prima che il cavo ammutolisse. Una demo costruita lì
sopra avrebbe affermato una cosa falsa.

**La correzione è topologica, non algoritmica.** Nessuna riga di Erlang toccata.

- `Dockerfile.emulator`: `node:22-alpine` più `src/emulator`. Nessuna dipendenza da
  installare — `cp.js` usa WebSocket e crypto nativi di Node 22 — e il build fa
  `node --check`, così un errore di sintassi non arriva a run time dentro un container che
  compose riavvierebbe all'infinito.
- Due reti nuove, `site1` e `site2`: le LAN dei siti, cavi in un parcheggio. Non c'è sopra
  nessun coordinatore e nessun back office, perché in un impianto vero non ci sarebbero.
- Ogni stazione su **due** reti; le colonnine di Livorno (`cp6`, `cp7`) solo su `site2`, con
  `restart: unless-stopped` — l'equivalente compose del ciclo di supervisione di `world.sh`.

Sono su Livorno e non su Pisa apposta: i connettori di Pisa sono del presentatore, e una
colonnina permanente lì risponderebbe `4409` a `presenter-cp.sh`.

**Misurato dopo la modifica**, con l'uplink tagliato:

- energia che **sale** dentro la stazione isolata: 0,875 → 0,944 → 1,014 kWh, e i numeri
  della stazione coincidono con quelli che `cp6` scrive nel suo log;
- il leader sceso a **una** stazione conosciuta, dopo `** Node vs@station2 not responding **`
  e `dropping stations [2] and their claims`;
- alla riconnessione, due stazioni note dopo undici giri di controllo e **nessuna
  interruzione** delle due ricariche (1,014 → 1,569 kWh attraverso tutto l'episodio).

**Una scoperta che rende la storia migliore, non peggiore**: le porte pubblicate
**sopravvivono** alla partizione. La 9102 risponde `426` a stazione isolata, quindi un
conducente fisicamente lì potrebbe ancora aprire la pagina. Quello che si perde è la
**lobby**, perché la lobby la disegna il coordinatore. È la forma onesta di questo guasto —
funziona tutto tranne chi deve saperlo — ed è precisamente il motivo per cui le
prenotazioni scadono da sole invece di dipendere da qualcuno che le cancelli.

**Due affermazioni false corrette in `SCOPE`**, entrambe trovate cercando dove scrivere
questa: §6 diceva che il deploy è *«demonstrated on more than one host»* — non lo è, gira su
una macchina sola, e la frase giusta è che i **nodi** sono sette e che la partizione vera si
ottiene con `disconnect`, non con più host (BlackNet, il progetto da 30 e lode, non l'ha
fatto). E §5 P4 sosteneva la riconciliazione al riavvio, già corretta nel commit
precedente.

**Conseguenza sulla demo**: `world.sh` non serve più a T+0, il layout scende da tre riquadri
a due, e il beat di P4 diventa `network disconnect` invece di `kill`. Il `kill` resta come
caso duro — sessioni perse, verificato con `sessions` ferma a 3 prima e dopo — ma se il
tempo stringe si tiene il `disconnect`, che è quello che si racconta senza dover spiegare
cosa sia un container.

### La misura rifatta piano, e la modifica buttata

La sezione precedente poggiava su un numero: **34,523 kWh fermo su tre letture** a stazione
isolata. Da lì la conclusione «la porta pubblicata non sopravvive al `disconnect`, quindi il
cavo è tagliato insieme all'uplink», e da lì una riprogettazione del deploy — reti per sito,
emulatori containerizzati.

**La conclusione era falsa.** Ecco l'esperimento che l'ha smontata, fatto perché A ha
obiettato che due colonnine in container e cinque no non è un progetto ma una modifica
lasciata a metà.

Con `station2` isolata, una `cp.js` **lanciata dall'host** si collega senza problemi:

```
10:38:44  conn5 connecting to ws://localhost:9202/ws/cp
10:38:44  conn5 connected
10:38:44  conn5 boot accepted
```

E, con un'auto già in carica, l'energia **sale attraverso la partizione**, fianco a fianco
con una containerizzata:

```
conn 5  (host)        0,248 → 0,403 → 0,558
conn 6  (container)  14,069 → 14,139 → 14,208
```

Identiche. **I container non servivano.** Il numero congelato di stamattina era la finestra
di riconnessione, campionata tre volte in sei secondi contro un tick di cinque. È il terzo
errore dello stesso tipo in una giornata: due volte ho letto un contatore troppo in fretta e
ho concluso che si fosse fermato.

Annullato: via `cp6`, `cp7`, le reti `site1`/`site2` e `Dockerfile.emulator`. Torna
`world.sh` per tutte e sette le prese, un modello solo. Il beat della partizione funziona
come prima — anzi, ora si sa che funziona, invece di crederlo.

**Cosa sopravvive della giornata, ed è la parte che vale**: le misure, che valgono comunque
di dove girino gli emulatori.

1. **Una stazione isolata continua a erogare** e il coordinatore la scarta:
   `** Node vs@station2 not responding **` → `dropping stations [2] and their claims`, leader
   sceso a una stazione, lobby svuotata. Alla riconnessione, due stazioni e nessuna
   interruzione.
2. **Le porte pubblicate sopravvivono**: la 9102 risponde `426` a stazione isolata, quindi
   chi è fisicamente lì può ancora aprire la pagina. Si perde la *vista* dell'operatore,
   non il servizio. È la forma onesta di questo guasto.
3. **Ma una sessione nuova non parte.** Autorizzare un'auto significa risalire dal veicolo
   al proprietario, cioè MySQL, che sta oltre il taglio: `no account for vehicle 104` e
   nessuna sessione aperta. Le ricariche già in corso non se ne accorgono, perché non
   toccano il database. Realistico — è ciò che fa una colonnina vera con una tessera
   sconosciuta e nessuna linea — e mai scritto prima.
4. **Un difetto vero, nel perimetro di A.** `vs_station_db` si riprende dopo la partizione,
   ma non all'istante; e un `plugged` che arriva in quella finestra viene **perso in
   silenzio**. `vs_cp_proto:with_account/4` logga `no account for vehicle N`, ritorna
   `{[], Session}` — nessuna risposta sul canale, nessun ritardo, nessun tentativo — e la
   colonnina continua a misurare nel vuoto per sempre. Visto dal vivo: `limit 0 kW`, dodici
   `meter` a `0 kW, 0 kWh` di fila. Serve almeno un tentativo, o un rifiuto esplicito.
   **Da mettere nella nota per A.**

### La lezione, che vale più della modifica

Un contatore che non si muove **non è la prova che il sistema sia fermo**: è la prova che
non hai aspettato abbastanza. Tre volte oggi ho scambiato la seconda cosa per la prima, e
la terza mi è costata una riprogettazione del deploy e quaranta minuti.

Nel runbook è finita come regola operativa: davanti a un'energia che non sale, guardare per
**almeno mezzo minuto** prima di concludere — il tick è di cinque secondi e dopo una
partizione c'è una finestra di riconnessione.

### Non provato — e perché

- **La demo intera in sequenza** non è ancora stata corsa: la giornata è stata di
  diagnosi. Le singole battute sì.
- **La partizione di `station1`** non è stata provata, solo quella di `station2`. Ora che si
  sa che gli emulatori sull'host reggono, non c'è motivo perché dia un risultato diverso —
  ma è una deduzione, non una misura.
- **Il difetto n. 4 non è stato riprodotto una seconda volta**: colto una volta sola, nella
  finestra di ripresa del database. Riproducibile fermando MySQL per qualche secondo, non
  provato.
- **`not_your_reservation` e `unknown_vehicle` end-to-end**: i due rifiuti del canale
  colonnina hanno test unitari ma nessuna corsa. Si producono in due comandi
  (`cp.js --vehicle 88` per lo sconosciuto, un veicolo seminato diverso dal titolare per
  l'altro) e coprirebbero due righe di `ws-chargepoint.md` §4.2 mai viste girare.
- **`'global' … requested disconnect … to prevent overlapping partitions`**, comparso una
  volta. Quasi certamente causato dai nodi effimeri di `coord-status.sh`, che entrano nel
  cluster e muoiono subito. Innocuo, non indagato a fondo.

---

## 7zo. A7: le tre costanti escono dallo `<script>`, e la pagina smette di essere sorgente JS — 3 settembre

Chiusura dell'ultimo rilievo della review che era rimasto senza padrone. L'avevo scritto io in
`review-per-A-progetto.md` come A7 offrendomi di non toccare la pagina di A; A ha risposto
**«cambialo tu, tutto — la pagina *e* il client, in un commit solo»**, e il motivo è quello
giusto: in due PR separate la pagina resta rotta nel mezzo.

### Il difetto

`station.jsp` e `session.jsp` costruivano **sorgente JavaScript** con EL:

```jsp
const WS_URL = '${station.wsUrl}';
```

`station.wsUrl` non è una costante di pagina: nasce nella variabile d'ambiente `WS_URL` di un
nodo stazione, passa per l'annuncio `station_up`, il coordinatore e `StationDirectory`. Una
stazione che si annunciasse come `ws://h/ws/driver';alert(document.cookie);//` chiudeva la
stringa ed eseguiva script nella pagina di **ogni** conducente. La stessa JSP passava
`station.name` per `<c:out>` poche righe più sotto: era solo dentro lo `<script>` che l'EL
usciva crudo.

**Severità reale bassa** — per sfruttarlo bisogna già controllare la configurazione di un nodo
del cluster, cioè essere dentro. Ma il rimedio toglie la **classe** invece dell'istanza.

### Il rimedio, e le due decisioni dentro

I tre valori sono attributi `data-` su un elemento `hidden`, ciascuno reso da `<c:out>`: un
attributo non può diventare codice, qualunque cosa contenga, perché non entra mai in un parser
JavaScript.

**La lettura sta in `ws.js`, non nei due consumatori.** `driverChannelConfig()` restituisce
`{url, station, token}` e `station.js`/`session.js` chiamano `createDriverChannel(driverChannelConfig())`.
Le due pagine differiscono in **cosa disegnano**, non in come sono configurate: l'id
dell'elemento vive in un posto solo, nello stesso file che possiede già la forma di `config`.

**`station_id` è ora una stringa**, non un numero: un attributo non ha tipi. Non morde, perché
il suo unico uso è `endpoint()`, che lo percent-encoda nella query — e la query è testo comunque.
Nessuno lo confronta con un numero. La jsdoc lo dichiara invece di lasciarlo scoprire.

Se l'elemento manca, `driverChannelConfig()` **lancia** invece di restituire `undefined`: senza
di esso non c'è né endpoint né token, e fallire lì dice quale contratto non è stato onorato,
invece di fallire tre passi dopo nell'handshake con un messaggio che parla del token.

`jwt.md` §2 è aggiornato — è il contratto che prometteva il blocco `<script>`, quindi cambiare
il codice e lasciare lì la vecchia forma avrebbe spostato la bugia da una parte all'altra.

### Verificato — e cosa no

- `node --check` sui tre file, e nessuna occorrenza residua di `TOKEN`/`WS_URL`/`STATION` fuori
  dai commenti che spiegano il difetto.
- `eunit_check.sh` **395, 0 failures** — la modifica non tocca Erlang, ma il ramo non era mai
  stato verificato dopo il merge di `main`.
- Gli `<script>` sono in fondo a entrambe le pagine, dopo l'elemento: quando `station.js` gira,
  il `div` è nel DOM. Verificato leggendo, non serve altro.
- **Non riprovato nel browser.** Il giro coi pixel è quello di A del 1/09 (§7zk) e non l'ho
  rifatto dopo questa modifica: va rifatto alla prova generale, ed è la prima cosa da guardare
  perché tocca l'unica riga che apre il socket.

### Un rosso che non era un rosso, e va saputo prima della demo

Il **primo** giro di `eunit_check.sh` dopo il merge è finito così:

```
184 tests, 0 failures, 6 cancelled
```

Non un difetto: `_build` era freddo e
`vs_cp_proto_tests:the_socket_timeout_and_the_grace_add_up_to_three_heartbeats_test` ha superato
i **5 secondi** di timeout di default di eunit mentre era dentro `code:ensure_loaded` per
`cowboy_req` — lo stacktrace lo dice riga per riga. Morto quel test, eunit ha abbandonato il
resto del gruppo: da qui i 184 invece dei 395. Il giro successivo, a cache calda, **395, 0
failures**.

Il test è quello che legge il timeout *attraverso il suo unico chiamante* (`vs_cp_ws:init/2`)
invece di ricopiare la formula — scelta giusta, che però fa entrare cowboy in un test altrimenti
puro. Su questa macchina, con i sorgenti su OneDrive, il primo caricamento può costare più del
budget di eunit. **Non l'ho cambiato**: è un rischio di ambiente, non di logica, e sarebbe la
terza volta (§7zb) che si tara un test sulla macchina invece che sul contratto. Ma è da sapere
prima della prova generale: **il primo `eunit_check.sh` dopo un `_build` pulito va rilanciato una
volta prima di crederci.**

### Il merge di `main`, e la rinumerazione

`main` (`0b31f3e`, con `a/p18-nodeup`) è dentro questo ramo. Le mie due sezioni si sono
spostate — la review 2/09 da §7zk a **§7zm**, le prove 3/09 da §7zl a **§7zn** — perché A aveva
già preso §7zk (il giro coi pixel) e §7zl (la sua metà di P18). `DESIGN-NOTES` §4c puntava al
vecchio §7zk e ora punta a §7zm: la rinumerazione l'avevo dichiarata ad A come «riferimenti
interni aggiornati», e quello era l'unico esterno — trovato cercandolo, non per caso.

---

## 7zp. §8: i due alberi di supervisione disegnati, e il criterio dietro le tre strategie — 4 settembre

`sec:supervision` elencava i tre supervisori con la loro strategia, ma non li **mostrava**: dal
solo elenco non si vede che la stazione ne annida due (`vs_connector_sup` è figlio di
`vs_station_sup`) mentre il coordinatore ne ha uno solo, e non si vede che l'ordine di
dichiarazione dei figli di `vs_coord_sup` *è* l'ordine delle dipendenze. Aggiunto un listato coi
due alberi affiancati (`lst:suptrees`).

Aggiunto anche il criterio che sta sotto la scelta delle tre strategie, implicito nei tre casi ma
mai enunciato: **riparte con te chi ha memorizzato un riferimento al tuo stato**. `vs_coord_bo`
pubblica quello che tiene `vs_coord_srv`, quindi un server riavviato lo lascia con in mano una
tabella che non c'è più; i connettori non memorizzano niente del manager, lo trovano per nome
registrato e il manager li riadotta, e `one_for_one` basta. È lo stesso principio per cui
`vs_cp_proto` rifà `lookup_pid/1` a ogni evento invece di tenersi il pid.

`vs_ping` **non compare nel listato**, pur essendo ancora il primo figlio di `vs_station_sup`:
è la sonda di M0, disarmata il 3 settembre (§7zm) togliendo `PING_TARGET` dal compose, e nel
diagramma non aggiunge niente a un discorso che parla di strategie e dipendenze. La divergenza
è consapevole e vale la pena saperla all'orale: nel codice i figli della stazione sono cinque,
nel disegno quattro. Se un giorno la child spec sparisce davvero, il documento è già allineato.

Documento a 26 pagine, compila pulito. `style-lint` non segnala niente di nuovo: il WARN su
`rather than` è preesistente e sparso su tutta la sezione.

---

## 7zq. Relazione, la mia parte: §9.2 e §9.3 scritte — 4 settembre

Prime due sezioni mie della relazione, nell'ordine che B aveva consigliato nella nota
(`contracts/nota-per-A-doc.md` §8): i due canali WebSocket, perché sono i più meccanici e i più
lunghi da mettere in tabella. Le due skill di B (`.claude/skills/tech-report-latex` e
`voltshare-doc`) sono installate e seguite; il nome del progetto resta **VoltShare**.

**Da dove vengono i fatti.** `ws-driver.md` e `ws-chargepoint.md` per la specifica, poi il codice
per ogni numero e ogni comportamento: `vs_driver_proto.erl` (cache 64/60 s consultata prima del
dispatch, `cacheable/1` che esclude lo `state`, i nove codici, il `call_connector/1` con gli 8 s
del caso peggiore), `vs_driver_ws.erl` (tick 5 s con il ping, idle 60 s, il filtro delle
notifiche nella testa di clausola), `vs_cp_proto.erl` (handshake 4404 solo permanente, boot
`accepted: false` con le due `reason`, `max_kw` obbligatorio, `charging_seconds` opzionale, il
reattach 5 x 500 ms che chiude 1012), `vs_cp_ws.erl` (idle = 2 x 30 s, il `stop(station_shutdown)`
prima del 1001), `vs_connector.erl` (`max(stored, reported)`, le sei ragioni di `stop`),
`cp.js` e `ws.js` per i backoff (1 s → 30 s; 500 ms → 10 s).

**Due divergenze contratto/codice trovate scrivendo**, entrambe risolte a favore del codice:
`NOT_YOUR_TURN` è in `ws-driver.md` §6 ma non ha un percorso che lo produca (la waitlist non
esiste), quindi nel documento i codici sono nove e non dieci; la tabella §4.2 di
`ws-chargepoint.md` dice `charging | closing` per il rifiuto del `plugged`, il codice rifiuta
anche `complete` (commento in `authorise/5`), e nel documento c'è la terna.

**Le misure citate**, con la fonte: 12,042 kWh in una riga da 23 s (§7v, 28/08, la prova
dell'offset che ha fatto nascere `charging_seconds`); 34,795 → 34,812 kWh attraverso `docker
kill station2` (DEMO.md, 3/09), che è la riconciliazione §6 vista dal vivo.

**Il conto delle pagine non torna, e va detto a B.** Il budget era 2 pagine per §9.2+§9.3;
sono **3,3** dopo due passate di taglio (da 21 400 a 18 000 caratteri), con quattro tabelle. Ma
§9.1 di B è 1,7 pagine su un budget condiviso di 2 con §9.4 e §9.5, e §9 intera è a **~8
pagine su 4**. Il documento è a **30 pagine** con §2, §3, §6, §10, §11, §12 ancora segnaposto
(10,5 pagine di budget): la proiezione è **~40**, sopra il tetto di 35. Da decidere insieme
nella revisione incrociata dove tagliare; io propongo di tenere le tabelle e tagliare la prosa
di raccordo in §9, e di stare stretti su §2 e §11.

**Lint e compilazione.** `style-lint.py` su `09-api-specification.tex`: 0 FAIL, SD 14,7, un
solo `neg_appositive` (di B). Nessun em dash, nessun participio in coda, quattro parallelismi
negativi tolti in rilettura (tre erano miei). `latexmk`: zero riferimenti indefiniti, nessun
overfull sopra i 10 pt dopo `\allowbreak` nell'URL del charge point e `sloppypar` sull'elenco
delle notifiche.

### Secondo giro, stesso giorno: figure, scelte in evidenza, §2, §3, §6, §12

**Figure.** Tre, tutte in TikZ nel sorgente (niente PNG, niente file esterni; `main.tex` ha
`\usepackage{tikz}` + `positioning`): la sequenza della prenotazione con claim, retry dalla
cache e rifiuto del coordinatore (§9.2, `fig:seq-reserve`, quella che la nota di B chiedeva);
la sessione sul canale charge point con la seconda auto che arriva e il limite 150 → 130 di
`station2` del 28/08 (§9.3, `fig:seq-cp`); la macchina a stati del connettore (§3,
`fig:connector-states`), ricavata dal diagramma ASCII in testa a `vs_connector.erl`. Il
diagramma di deployment resta lo `\stub{figure: ...}` di B in §4.2; §11 avrà bisogno di
screenshot della demo, che si fanno con Docker acceso.

**Scelte progettuali in evidenza.** Ogni sottosezione di §9 mia chiude con un blocco
`\paragraph{Decisions on this channel.}`: scelta in grassetto, alternativa, motivo (cinque
per il canale driver, sette per il charge point). §6 ha la scelta del browser che parla
*direttamente* alla stazione e non passa da Tomcat, con l'alternativa scartata e il prezzo
(la seconda autenticazione), e la regola «one writer per table» dello schema.

**§2** (2 pagine): tabella attori, requisiti funzionali e non con `\cref` alla sezione che li
soddisfa, e un paragrafo che dichiara i tre requisiti *non* consegnati (waiting list,
modifica/cancellazione profilo, filtri della lista). **§3** (1,5 pagine): le regole nell'ordine
in cui un driver le incontra, la macchina a stati, e la tabella dei parametri con default e
valori demo, tutti verificati (`LEASE_SECONDS` 900/90, `CLAIM_GRACE_SECONDS` 60/30,
`OVERSTAY_GRACE_SECONDS` 300/20, `PENALTY_NO_SHOWS` 2, `PENALTY_DAYS` 1, `MIN_CHARGE_KW` 6,
`tariff_cents_min_overstay` 50, `BILLING_SWEEP_SECONDS` 60/10, budget 350→200 e 180).
**§6** (1,5 pagine): tabella degli archi (protocollo, chi apre, cosa porta), client-facing e
internal come BlackNet. **§12** (1 pagina): quattro estensioni con il motivo del rinvio, e il
log replicato dichiarato *fuori* lista con il 2,29 s del failover misurato.

**Verifiche fatte scrivendo:** `ProfileServlet` è in sola lettura (nessun `doPost`), nessun
filtro in `stations.jsp`, nessun refresh token (la sessione è `HttpSession` + JWT da 60 min):
lo SCOPE §3.1 prometteva «access/refresh tokens» e il documento dice quello che c'è. La
revoca del claim viaggia nella risposta al `renew`, il coordinatore non chiama la stazione
(`vs_coord_srv.erl:752`); il coordinatore indirizza `{vs_claim_client, Node}`
(`vs_coord_rebuild.erl:100`).

**`DESIGN-NOTES.md` §9** riscritto da «decisioni aperte» a «decisioni chiuse»: nome VoltShare
confermato (come proposto da B), emulatore in Node.js, fair share con hand-back, waitlist
fuori scope, due stazioni.

**Conto pagine:** 36 con §4.2-figura, §10 e §11 ancora segnaposto (stima finale ~40). Le mie
sono nel budget salvo §9.2+9.3 (3,5 con le figure su 2). Da tagliare in revisione incrociata,
e i candidati sono la prosa di raccordo in §9 e §7/§8 di B.

**Lint:** 0 FAIL su tutte e sei le sezioni; SD 22,5 / 12,1 / 10,6 / 15,2 / 17,1.
`latexmk`: zero riferimenti indefiniti, nessun overfull sopra i 10 pt.

### Terzo giro, 5 settembre: §10, §11, la figura di deployment, e la lista dei tagli

Demo e compose congelati, quindi **§10** (1,7 pp.) e **§11** (2 pp.) scritte. Tutto dal
`docker-compose.yml` e dai file di `deploy/`, non dalla memoria: sette container su **una
rete** sola (la seconda rete per sito del 3/09 è raccontata come esperimento smentito dalla
misura, com'è nei commenti del compose); OTP pinnato a 29.0.5 e il `catch Expr` che il
disallineamento nascondeva; healthcheck a 60 tentativi per il primo boot da sei minuti;
`start-node.sh` al posto di una release; colonnine sull'host e non nel compose. §11: **395**
test EUnit (`EXPECTED_TESTS`) con la storia dei tre modi di rompere la suite a «0 failures»;
il carico del 28/08 in tabella (500 driver, 1 accettata, 100 ms max); la mappa scene →
problemi della demo con la data in cui ogni scena è stata vista; i quattro difetti del 3/09
trovati guardando, con la suite verde a 386.

**Figura di deployment fatta in TikZ e messa in §4.2 al posto dello `\stub` di B**: sette
container, il browser e gli emulatori sull'host, il protocollo su ogni arco, il gruppo dei
coordinatori. B, se preferisci la tua da draw.io, sostituisci la `figure` con
`\includegraphics`: la label `fig:deployment` è già citata da §4.2 e §10.

**`\stub` rimosso da `main.tex`**, come da regola: nessun segnaposto resta, e un residuo
non compilerebbe. Aggiunto `\usetikzlibrary{positioning}`.

**Seconda passata di taglio sulle mie sezioni**: via i doppioni con §3/§7/§8 (decisioni
di §9 da 5+7 a 4+5, «one network» e «images» in §10 accorciate, Ranch e l'intro di §11).

**Stato: 39 pagine, tetto 35.** La decisione su cosa levare è in **`doc/TAGLI.md`**:
sezione per sezione cosa dice, quanto pesa all'esame, cosa si può togliere e quanto rende,
con tre menu (−4,1 solo prosa; −5,5 consigliato; −8 aggressivo) e la lista di ciò che non
si tocca. Le righe A le eseguo io a menu deciso; le righe B sono sue.

**Rilettura finale sul PDF** (passata 1 e 3 della skill, sulle mie sezioni): tre frasi
rimaste nella forma vecchia dopo un taglio abortito (§9.2 ping, §9.3 silence, §11 i quattro
difetti) rimesse a posto; «outlet» → «connector» in §11 (glossario); la tabella del claim di
B (§9.4) da `[t]` a `[h]`, perché finiva in cima alla pagina in mezzo alla mia lista di
decisioni.

**Lint:** 0 FAIL su dodici sezioni, tutte le mie a «ok»; 3 WARN in sezioni di B (tricolon
in §1 e §4, `rather than` ×8 in §8). `latexmk`: zero riferimenti
indefiniti, zero overfull sopra i 10 pt.

---

## 9. Prossimo passo

**Le quattro milestone di codice sono chiuse su entrambi i lati** e verificate in Docker. Il
progetto ha tutto ciò su cui viene giudicato: coordinazione, tolleranza ai guasti, la
dimostrazione che P2 sopravvive a un failover, e — dall'1/09 — il giro intero visto in un
browser vero (§7zk). Quello che resta non è più codice: è la **demo** e la **relazione**.

### 1. P18 — **chiuso su tutte e due le metà**, e resta da rivedere in due

Rompeva l'invariante di `SCOPE.md` §4 — un veicolo, una prenotazione in rete — per **13,65 s**
misurati. La scheda è in §8, la misura originale in §7zj ③, il lavoro di A in §7zl.

- **la metà di A**, `monitor_nodes` + riannuncio e renew sul `nodeup`: su `main`. La finestra è
  passata da **4,11 s** a **0 ms** sulla stessa scena — ma **accorciando**, e per aver vinto una
  gara con **265 ms** di margine;
- **la metà di B**, non passare a `serving` con zero risposte *e* zero claim: **fatta**, in
  questo ramo. È quella che chiude, perché non dipende da chi arriva primo.

Se il coordinatore serve a tabella vuota **prima** che chiunque possa parlargli, nessuna
prontezza del lato stazione arriva in tempo: le due metà non erano alternative, e la prima da
sola non bastava. I client trattano già `rebuilding` come `RETRY_LATER` — misurato, §7zj ⑤.

**Quello che resta è una verifica, non una decisione:** la scena di §7zj ③ non è stata rifatta
nei container **dopo** la metà di B. I test coprono la transizione, la misura end-to-end no. Va
messa nella prova generale.

### 2. La demo (M5)

Il deploy è già quello dichiarato, e la scaletta è scritta. Manca la **prova generale**, e serve
soprattutto per le **tre cose mai viste con gli occhi** elencate in §7zk: il riparto
75 · 75 · 50, le pagine del no-show, e il giro intero **col cronometro**.

Due cose da concordare prima, non durante:

- **su quale macchina**. I database **non sono condivisi**: ogni misura «sul database» va fatta
  su una macchina sola, e un eventuale `DELETE FROM sessions;` va concordato prima, non
  improvvisato davanti al professore.
- **chi guida** e chi commenta.

E una regola imparata sul campo: **in demo non si usa il Ctrl-C sugli emulatori**. L'1/09 uno dei
due processi è sopravvissuto al Ctrl-C e me ne sono accorto solo leggendo il suo terminale. Gli
stop passano dalla pagina, gli unplug dal `--linger` di `cp.js`.

### 3. La relazione

Il materiale c'è quasi tutto ed è già scritto sotto `src/`: questo documento per «verificato vs
mai provato», `src/erlang/scelte_di_progetto.md` per le motivazioni (§18-§26 sono degli ultimi
giorni), i contratti per il confine fra le due metà. L'ossatura del capitolo di progettazione
sono le lezioni ricorrenti — la firma di ritorno che decide quali distinzioni i chiamanti possono
fare; chi possiede lo stato lo ridice a chi lo aggrega; tre garanzie di consegna diverse per tre
nature diverse; una copia durevole serve solo per un fatto che non registra nessun altro; e le
misure scadono.

### In attesa di B

- **La riga «`do_renew` si fida dei renew perché vale P15»**, da mettere agli atti: il ricalcolo
  della scadenza a ogni giro è innocuo **perché** dal lato stazione nessuno rinnova più un claim
  fantasma (§7zd). È una difesa sola per un difetto a due metà, e la dipendenza va scritta dove
  si vede, non lasciata implicita.

### Prima di M5

Il deploy dichiarato in `SCOPE.md` §6 — **sette nodi**: tre coordinatori, due stazioni, Tomcat,
MySQL — da oggi è **esattamente quello che gira**, sette container nel compose. Fino a ieri erano
cinque, con un solo coordinatore: il documento descriveva l'obiettivo, ora descrive il fatto.

**Sul deploy multi-host — ridimensionato dopo una verifica.** Avevo annotato che mancava il deploy
su più macchine, trattandolo come un buco. Controllando il `docker-compose.yml` di BlackNet — il
progetto di riferimento valutato 30 e lode — risulta che **loro non l'hanno fatto**: singolo host,
rete bridge di default, nomi nodo agganciati agli hostname dei container, esattamente il nostro
schema. Il requisito del corso dice *"deployata su più **nodi**"*, non su più host, e di nodi ne
abbiamo sette veri. "Tipicamente cloud" è un esempio, non un obbligo.

~~Resta un motivo **solo** per volerlo, e non è il requisito: su una macchina sola non si può
produrre una **partizione di rete vera**.~~ **Falso, e chiuso due volte.** `docker network
disconnect voltshare_voltshare <container>` produce una partizione vera su un host solo: il
nodo resta acceso, si crede vivo, non manda nessun FIN. B lo aveva mostrato sui follower il
27/08 (§7y); il 01/09 (§7zj) l'ho fatto **sul leader**, con due claim vivi e una ricarica in
corso, e misurato tutto: `QUORUM LOST (1 of 3) … abdicating` a **2,12 s**, un leader nuovo che
serve con entrambi i claim a **2,29 s**, e la nodedown della distribuzione solo a **64,6 s** —
la prova che senza FIN si paga il tick, che è esattamente ciò che `docker kill` non può
mostrare. **Quindi non resta nessun motivo per il deploy multi-host**, e nella demo la
partizione va accanto al `docker kill`: sono due guasti diversi e il sistema li tratta in modo
diverso.

Se lo si fa, la conseguenza tecnica è una sola e va saputa prima: `-sname` non basta più. I nomi
corti funzionano solo dentro lo stesso dominio DNS, e `Dockerfile.erlang` dice *"long names would
buy nothing here"* — vero su un host, falso su due. Servirebbe `-name` con FQDN o IP, e con esso
cambiano `COORD_NODES` e `JINTERFACE_NODE` su tutti i nodi.
