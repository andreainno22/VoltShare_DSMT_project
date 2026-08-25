# VoltShare — stato dei lavori

Registro di cosa esiste, cosa è stato verificato e cosa manca. Si aggiorna a ogni pezzo consegnato.
Il piano di riferimento è [piano.md](piano.md); le specifiche sono in [SCOPE.md](SCOPE.md) e [DESIGN-NOTES.md](DESIGN-NOTES.md).

**Ultimo aggiornamento:** 25 agosto 2026 — M1-B, M2-B e **M3-B** chiuse. Tre coordinatori con elezione bully, quorum e ricostruzione: failover provato in Docker uccidendo due leader di fila. 132 test, 0 fallimenti.

---

## 1. Quadro d'insieme

| Milestone | A (stazione, emulatore, viste live) | B (coordinatore, back office, pagine) |
|---|---|---|
| **M0** fondamenta | ✅ impianto Erlang, ping fra nodi, deploy | ✅ contratti, schema, token di esempio |
| **M1** percorso base | 🟡 stazione **e canale driver** pronti (manager, connettori, claim client, mock del coordinatore, `vs_jwt` + `vs_driver_proto` + `vs_driver_ws` — **96 test lato A**); manca `station.jsp` (passo 4) | ✅ **chiusa e verificata in Docker il 25/08**: coordinatore vero, ponte JInterface, Tomcat, lobby con dati veri dal browser |
| **M2** sessione e potenza | ⬜ canale colonnina, potenza, INSERT sessione, `session.jsp` | ✅ **fatturazione e storico**, provati contro MySQL (§7k) |
| **M3** tolleranza ai guasti | ⬜ rinnovo contro il nuovo leader, revoca, riconnessione client | ✅ **elezione, quorum, ricostruzione** — failover provato in Docker (§7m) |
| **M4** regole di dominio | ⬜ | ⬜ |
| **M5** consegna | ⬜ | ⬜ |

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
| **Suite completa su `main`** | ✅ **132 test, 0 fallimenti** — misurati il 25/08, non stimati: `vs_common` 9 + `vs_station` 87 + `vs_coord` 36 (16 claim + 11 failover + 9 quorum). È il numero da citare |
| Failover con tre coordinatori | ✅ **eseguito il 25/08** in Docker — due leader uccisi di fila, minoranza sospesa, claim riadottato con lo stesso `granted_at` (§7m) |
| Canale driver contro il contratto (`ws-driver.md`) | ✅ verificato nei test — handshake coi tre token di `sample-tokens.md`, at-most-once dimostrato contando le chiamate al connettore, tabella dei rifiuti §4.1/§6, traduzione `offline` → `out_of_service`, `coordinator_reachable` end-to-end |
| `vs_claim_client` ↔ `vs_mock_coord` sul contratto vero | ✅ verificato nei test — claim, eco del `GrantedAt` nel renew, release, revoca end-to-end, `station_stats` |
| Docker compose (macchina A) | ✅ **eseguito** — 7 container su, coord1 (mock) riceve `station_up` da entrambe le stazioni (4 e 3 connettori) |
| Compose sull'immagine Debian 29.0.5 | 🟡 build verde; il giro completo era stato fatto con l'immagine 386, da ripetere dopo il merge |

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
| `station.jsp` | **A** | 🟡 scheletro con le tre variabili del contratto, da completare |
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
rebar3 eunit                           # 109 test (96 stazione+common lato A, 13 coordinatore)
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
- **Client browser del canale driver (A)**: `js/ws.js`, `js/station.js`, `station.jsp` finita. È l'unico pezzo che separa la demo di M1 dal funzionare end-to-end (§7j).
- **JWT B→A mai verificato in transito**: da provare al primo `join` reale.
- La lista stazioni si aggiorna con `<meta http-equiv="refresh">` a 15 secondi: scelta deliberata, da dichiarare nella relazione.
- **PR formale su `claim.md`** (`GrantedAt` in `acquire`, rinnovo a cinque campi): regolarizza modifiche già concordate e implementate da entrambi. Il codice è allineato, resta l'atto formale.
- Il coordinatore di M1 è **sempre leader** e non ha quorum: `mode` esiste già nello stato ma vale sempre `serving`. Elezione e maggioranza sono M3.

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

## 9. Prossimo passo

M1-B e M2-B sono chiuse e verificate (§7i, §7k). Quello che resta a B è la milestone su cui il
progetto viene giudicato: **il coordinatore smette di essere singolo**.

Oggi `vs_coord_srv` ha già `mode` nello stato, ma vale sempre `serving`: c'è un solo
coordinatore, è sempre leader, e nessuno verifica di essere in maggioranza. M3 riempie proprio
quel vuoto, secondo `piano.md` §6.1:

1. **`vs_coord_election`** — bully: heartbeat 1 s, leader dato per morto dopo 3 battiti mancati,
   messaggi `election` / `answer` / `leader`. Vince l'id più alto.
2. **`vs_coord_membership`** — vista dei coordinatori vivi. Senza maggioranza (2 su 3) il nodo
   passa a `suspended` e **rifiuta tutto**: è ciò che impedisce a due leader separati da una
   partizione di concedere lo stesso veicolo due volte.
3. **`vs_coord_rebuild`** — dopo la vittoria il nuovo leader interroga le stazioni con
   `who_do_you_hold`, ricostruisce la tabella dei claim, e solo allora passa a `serving`. È qui
   che si vede il principio già scritto in `DESIGN-NOTES`: il coordinatore è un **indice, non il
   proprietario** dello stato, e per questo può ricostruirsi chiedendo invece di replicare un log.
4. **`coord2` e `coord3` nel compose** — sono già scritti e commentati nel file, con `COORD_ID`
   come priorità.

Da A, in parallelo: rinnovo dei claim contro il nuovo leader, gestione di `{not_serving, Leader}`,
revoca. Il contratto per farlo esiste già e la stazione lo implementa da M1.

**La prova di accettazione** (scenario 5 della demo): si uccide il container del leader mentre
una sessione è in corso; l'elezione avviene, il nuovo leader ricostruisce dalle stazioni, le
prenotazioni riprendono da sole — e le sessioni di ricarica **non si fermano**, perché il
coordinatore non è nel percorso dell'erogazione. Quest'ultimo punto è il più convincente da
mostrare al docente e va provato esplicitamente.

Resta fuori M1: il client browser di A (§7j). Non blocca M3 — il failover si dimostra dai log e
dallo stato dei nodi — ma senza quello la demo dal browser non esiste, quindi va sollecitato.
