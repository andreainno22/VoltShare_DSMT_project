# VoltShare — Piano di sviluppo

## Contesto

Le specifiche funzionali sono chiuse ([src/SCOPE.md](src/SCOPE.md)) e le motivazioni di design sono documentate ([src/DESIGN-NOTES.md](src/DESIGN-NOTES.md)). Resta da costruire il sistema, in due persone, sul repository condiviso [andreainno22/VoltShare_DSMT_project](https://github.com/andreainno22/VoltShare_DSMT_project), che oggi contiene solo i due documenti.

Il vincolo che guida il piano: **i due sviluppatori devono poter lavorare in autonomia**. La strategia:

1. **dividere il lavoro in modo che chi implementa un server implementi anche il suo client** — così quasi tutti i protocolli restano interni a una sola persona e smettono di essere punti di sincronizzazione;
2. **congelare i due contratti che restano davvero condivisi** prima di scrivere codice;
3. **dare a ciascuno un finto interlocutore** per i primi giorni, così nessuno aspetta l'altro.

Questo file contiene **entrambe le parti**: ognuno implementa la propria leggendo i contratti della §4.

### Decisioni prese

| Ambito | Scelta |
|---|---|
| Divisione | Il mondo Erlang è diviso in due metà di pari difficoltà; le pagine web seguono il dato che mostrano |
| Frontend | **MVC server-side**: servlet → forward → JSP con JSTL/EL, come nel lab 08. `HttpSession` per il login. JavaScript solo nelle due viste live, per il WebSocket. Niente REST, niente framework, niente nginx |
| Deploy | **Docker Desktop + docker-compose**, un container per nodo |
| Coordinamento | Coordinatore replicato ×3, bully election, quorum di maggioranza (SCOPE §9) |

### Conseguenza sul documento di specifica

Tre punti di `SCOPE.md` da aggiornare in M0:
- §6, riga "Web client": da *Vue SPA served by nginx* a **server-rendered JSP pages on the back office Tomcat**;
- §6, protocolli: il canale client↔back office non è più *REST/JSON* ma **HTTP con pagine renderizzate dal server** (form POST e forward). Il WebSocket verso le stazioni resta invariato;
- il client non è più un nodo separato: i nodi diventano **7** (3 coordinatori, 2 stazioni, Tomcat+web, MySQL).

Motivazione da mettere nel documento: sono le *basic Java web technologies* che il docente raccomanda, e per le pagine non interattive il rendering lato server costa meno codice del rendering nel browser. Il tempo reale resta dove serve davvero — sul WebSocket — e non contamina il resto.

---

## 1. Prerequisiti

| Strumento | Stato | Chi |
|---|---|---|
| **Erlang/OTP 29** e rebar3 | installato su A | **entrambi** — ora scrivono Erlang tutti e due |
| Docker Desktop | **mancante** | entrambi |
| JDK 17, Maven | presente | — |
| Node.js 24 | presente | A (emulatore) |

**La versione di OTP è 29 e non è negoziabile fra i due sviluppatori**: `rebar.config`
la dichiara con `minimum_otp_vsn` e `deploy/Dockerfile.erlang` usa `erlang:29.0.5-alpine`.
Una macchina con una major diversa produce bytecode che il container non carica.

Erlang su Windows: `winget install --id Erlang.ErlangOTP --exact --version 29.0.5`,
poi `C:\Program Files\Erlang OTP\bin` nel PATH. rebar3 è separato — è un escript, si
scarica da rebar3.org e su Windows `rebar3 local install` non funziona: si mette il
file in una cartella del PATH con accanto un `rebar3.cmd` che invoca
`escript.exe "%~dp0rebar3" %*`.

Due conseguenze della 29 già affrontate, da conoscere prima di scrivere codice:

- **`catch Expr` è deprecato** e `warnings_as_errors` lo trasforma in errore: va scritto
  `try ... catch ... end` per esteso.
- **JInterface dev'essere quella della 29** (1.16). Quella pubblicata su Maven Central è
  la 1.6.1 del 2011 e non riesce a connettersi: vedi `backoffice/libs/README.md`.

---

## 2. Struttura del repository

Il `.gitignore` ignora tutto tranne `/src/`.

```
src/
├── docs/                  SCOPE.md, DESIGN-NOTES.md
├── contracts/             ← protocolli. Uno solo è davvero condiviso (§4)
│   ├── claim.md              CONDIVISO — stazione ↔ coordinatore
│   ├── jwt.md                CONDIVISO — mezza pagina: B firma, A verifica
│   ├── ws-driver.md          interno ad A (documentato per la relazione)
│   ├── ws-chargepoint.md     interno ad A
│   ├── erlang-java.md        interno a B
│   └── schema.sql            proprietà delle tabelle separata
├── erlang/
│   ├── rebar.config
│   ├── apps/
│   │   ├── vs_common/     ← condiviso, tocchi rari
│   │   ├── vs_station/    ← A
│   │   └── vs_coord/      ← B
│   └── config/
├── backoffice/            ← B
│   ├── pom.xml
│   └── src/main/
│       ├── java/it/unipi/dsmt/voltshare/
│       └── webapp/
│           ├── login.jsp register.jsp profile.jsp
│           │   history.jsp notifications.jsp stations.jsp     ← B
│           ├── station.jsp session.jsp                        ← A
│           ├── js/ws.js js/station.js js/session.js           ← A
│           ├── css/ WEB-INF/web.xml WEB-INF/tags/             ← B
├── emulator/              ← A (Node.js)
└── deploy/                ← condiviso, tocchi rari
    ├── docker-compose.yml
    ├── Dockerfile.erlang  Dockerfile.backoffice  Dockerfile.emulator
    └── mysql/init.sql
```

Le pagine di A vivono nel progetto Maven di B, ma su **file distinti**: Git non produce conflitti finché nessuno tocca i file dell'altro. B crea l'impianto in M0 (`web.xml`, layout, CSS, `js/api.js`) e da quel momento A ci scrive sopra le proprie pagine.

### Regole Git

- `main` sempre funzionante. Si lavora su branch `a/<feature>` e `b/<feature>`, merge con Pull Request.
- Ognuno tocca solo i propri file. Eccezioni: `deploy/`, `contracts/`, `vs_common/`.
- **Modificare `contracts/claim.md` o `contracts/jwt.md` richiede una PR con l'altro come reviewer.** È l'unico accordo formale necessario.
- Gli altri file in `contracts/` sono di chi possiede il protocollo: si aggiornano liberamente, servono alla relazione finale.

---

## 3. Chi fa cosa

**A — Station controller, emulatore, viste live**
`vs_station/`: processi connettore, station manager, allocazione della potenza, endpoint WebSocket per driver ed EVSE, scrittura delle sessioni su MySQL, client del claim.
`emulator/`: emulatore di colonnina e generatore di carico.
Pagine `station.jsp`, `session.jsp` e il JavaScript WebSocket.
Scenari di demo e prove di carico.

**B — Coordinatore, back office, pagine REST**
`vs_coord/`: claim, elezione bully, quorum, monitoraggio dei nodi, ricostruzione dopo failover, ponte JInterface verso Java.
`backoffice/java/`: autenticazione JWT, anagrafica, directory stazioni, storico, fatturazione, penalità, notifiche.
Impianto web e pagine che consumano le REST.

**Perché è bilanciato**: circa sei moduli Erlang complessi a testa (connettore + potenza da un lato, elezione + quorum + ricostruzione dall'altro). B ha più volume in Java, ma di difficoltà nota dai lab 07/08; A ha in cambio l'emulatore, le viste live e le prove di carico. Entrambi scrivono Erlang, che è il vincolo d'esame e materia d'orale.

---

## 4. I contratti condivisi

Ne resta **uno solo** di sostanza — il claim — più mezza pagina sul JWT e le regole di proprietà del database. Vanno scritti **il primo giorno**, insieme.

Tutto il resto è interno a una persona sola: il WebSocket driver e il canale colonnina li implementa A da entrambi i lati, il ponte JInterface lo implementa B da entrambi i lati, e le pagine web non hanno più un contratto REST perché servlet e JSP appartengono allo stesso codice.

### 4.1 `contracts/claim.md` — stazione → coordinatore

Il contratto più importante del sistema: è il meccanismo che garantisce P2. Messaggi Erlang fra nodi, il coordinatore è un `gen_server` registrato come `vs_coord_srv`.

```erlang
%% richiesta di claim, prima che la stazione confermi la prenotazione
{claim, ReqId, VehicleId, UserId, StationId, ConnId}
   → {ok, ReqId, ClaimId, ExpiresAt}
   | {error, ReqId, already_held | suspended | rebuilding}
   | {not_serving, LeaderNode}          %% la stazione ritenta sul leader indicato

%% rinnovo periodico, ogni 10 s, per tutti i claim della stazione
{renew, StationId, [ClaimId]}
   → {renewed, [ClaimId], [RevokedClaimId]}

%% rilascio: cancellazione, lease scaduto, sessione conclusa
{release, ClaimId, Reason :: cancelled | expired | completed}
   → ok

%% ricostruzione dopo un failover: il nuovo leader interroga le stazioni
{who_do_you_hold, From}
   → {holds, StationId, [{VehicleId, UserId, ConnId, ClaimId, GrantedAt, ExpiresAt}]}
```

Regole vincolanti per entrambi:
- La stazione **non conferma mai** una prenotazione senza `{ok, ...}` (DESIGN-NOTES §3).
- Il coordinatore risponde `{not_serving, Leader}` in ogni stato diverso da `serving`.
- In caso di conflitto durante la ricostruzione vince il claim con `GrantedAt` più vecchio.
- La stazione tratta un `renew` fallito come revoca: annulla la prenotazione e avvisa il conducente.

### 4.2 `contracts/jwt.md` — identità

B emette, A verifica **in locale** senza chiamare Tomcat.

- **HS256**, segreto in `VOLTSHARE_JWT_SECRET`.
- Claims: `sub` (user_id), `username`, `vehicle_id`, `iss` = `voltshare-backoffice`, `exp`.
- Durata 60 minuti, rigenerato dalla servlet quando la sessione HTTP è ancora valida: non serve refresh token, perché la sessione di login è gestita da Tomcat.
- Java: `jjwt`. Erlang: `jose`.
- B consegna in M0 `contracts/sample-tokens.md` con tre token firmati e la loro decodifica, così A verifica senza dipendere da Tomcat.

Il token **non passa dal JavaScript**: la servlet lo mette in `HttpSession`, la JSP lo stampa nel markup della pagina live e il codice del WebSocket lo legge da lì.

```jsp
<script>
  const TOKEN   = '${sessionScope.jwt}';
  const WS_URL  = '${station.wsUrl}';
  const STATION = ${station.id};
</script>
```

### 4.3 `contracts/schema.sql` — MySQL

```sql
users(id PK, username UNIQUE, password_hash, created_at,
      no_show_count INT DEFAULT 0, suspended_until DATETIME NULL)
vehicles(id PK, user_id FK, battery_kwh, max_kw)
stations(id PK, name, ws_url, site_power_kw, tariff_cents_kwh)
connectors(id PK, station_id FK, rated_kw)
sessions(id PK, user_id, station_id, connector_id, started_at, ended_at,
         energy_kwh DECIMAL(10,3), overstay_seconds INT DEFAULT 0, cost_cents INT NULL)
notifications(id PK, user_id FK, kind, text, is_read, created_at)
```

**Proprietà separata, per non avere due scrittori sullo stesso dato:**
- A scrive **solo** `sessions` (INSERT alla chiusura). Nient'altro.
- B scrive `users`, `vehicles`, `notifications`, e aggiorna `sessions.cost_cents`.
- `stations` e `connectors` vengono dal seed, lette da entrambi.
- Il contatore penalità è **solo di B**: A lo segnala con un messaggio (§5.2), mai con una UPDATE.

---

## 5. Parte A — stazione, emulatore, viste live

### 5.1 `vs_station` (Erlang)

Rilascio `vs_station` da `rebar.config`, dipendenze `cowboy`, `jsx`, `mysql`, `jose`.

| Modulo | Behaviour | Ruolo |
|---|---|---|
| `vs_station_sup` | supervisor | avvio, configurazione (id stazione, connettori, potenza di sito) |
| `vs_connector` | **`gen_statem`** | un processo per connettore: stati `free → held → charging → closing`; possiede lease, sessione, quota |
| `vs_connector_sup` | supervisor | `simple_one_for_one`, `restart => transient` |
| `vs_station_mgr` | `gen_server` | budget di potenza, riparto delle quote, lista d'attesa, stato aggregato, registry ETS dei connettori |
| `vs_driver_ws` | `cowboy_websocket` | canale browser: verifica JWT, filtra i `request_id` duplicati (P7), inoltra ai connettori |
| `vs_cp_ws` | `cowboy_websocket` | canale colonnina: eventi hardware, invio dei limiti |
| `vs_claim_client` | `gen_server` | **unico** punto che parla col coordinatore: claim, rinnovo ogni 10 s, gestione del redirect al leader |
| `vs_station_db` | modulo | INSERT su `sessions` con pool `mysql-otp` |

**Macchina a stati del connettore:**

```
free ──reserve, claim ottenuto──▶ held ──plugged, veicolo giusto──▶ charging
 ▲                                 │                                    │
 │◀──cancel / lease scaduto────────┘                     stop │ unplug │ target
 │                                                                      ▼
 └───sessione scritta · claim rilasciato · potenza restituita─────── closing
free ──plugged senza prenotazione (walk-in)──────────────────────▶ charging
```

Timer come `state_timeout`: lease 15 min, grace di overstay 5 min, tick di stato 5 s. Tutti configurabili (`LEASE_SECONDS`, `OVERSTAY_GRACE_SECONDS`) per accorciarli in demo.

**Riparto della potenza** in `vs_station_mgr`, politica equa con tetto alla domanda:

```
budget = site_power_kw
ripeti: quota = budget / n_attivi_non_saturi
        chi domanda meno della quota prende la sua domanda ed esce dal riparto
        redistribuisci il resto finché stabile
sotto min_kw (default 6) la sessione è sospesa, non affamata
```

### 5.2 Protocolli di A (interni, ma da documentare)

**`ws-driver.md`** — `ws://<station>:8080/ws/driver?station_id=<id>`

```jsonc
// client → stazione
{ "action":"join|reserve|cancel_reservation|stop_session|join_waitlist|leave_waitlist",
  "request_id":"<uuid>", "payload":{ } }
// stazione → client
{ "type":"ack|error|state|session|notification", "request_id":"<uuid>|null", "payload":{ } }
```

`join` porta `{"token":"<JWT>"}` e deve arrivare entro 5 s, altrimenti chiusura 4401. `state` contiene l'elenco completo dei connettori con stato, `rated_kw`, `held_by_me`, `expires_at` e la lista d'attesa; `session` porta `power_kw`, `energy_kwh`, `soc_pct`, `eta_seconds`, `phase`. Codici di errore: `ALREADY_HELD`, `NO_CLAIM`, `SUSPENDED`, `NOT_YOUR_TURN`, `INVALID_STATE`.

**`ws-chargepoint.md`** — `ws://<station>:8081/ws/cp?station_id=<id>&connector_id=<n>`, set ridotto ispirato a OCPP 1.6-J:

| Direzione | action | payload |
|---|---|---|
| CP → stazione | `boot` / `heartbeat` / `status` | `{...}` / `{}` / `{"status":"available\|occupied\|faulted"}` |
| CP → stazione | `plugged` | `{"vehicle_id":88,"soc_pct":22,"battery_kwh":58,"max_kw":150}` |
| CP → stazione | `unplugged` | `{"energy_kwh":41.2}` |
| CP → stazione | `meter` | `{"power_kw":89.4,"energy_kwh":12.3,"soc_pct":58}` ogni 5 s |
| Stazione → CP | `set_limit` / `stop` | `{"limit_kw":60}` / `{"reason":"..."}` |

**Eventi verso il back office**: A non parla con Java. Manda al coordinatore `{no_show, UserId, StationId, ConnId}` e `{show_up, UserId}`, che B inoltra (§6.2).

### 5.3 Emulatore (`emulator/`, Node.js + `ws`)

- `charge-point.js`: macchina a stati per connettore, integra l'energia dalla potenza concessa (`kWh += kW × Δt/3600`), curva che riduce la domanda oltre l'80% di carica.
- `load-generator.js`: N colonnine e M conducenti sintetici (i conducenti parlano il protocollo driver come farebbe il browser), con `--scenario=contention|noshow|overstay|mixed`.
- `mock-coord.erl`: trenta righe che concedono sempre il claim, per sbloccare A in M1 prima che il coordinatore di B esista.

### 5.4 Viste live

`station.jsp` + `js/station.js`, `session.jsp` + `js/session.js`, più `js/ws.js` (connessione, `request_id` con `crypto.randomUUID()`, riconnessione con backoff, coda in attesa di `ack`).

Sono le uniche due pagine con JavaScript. Prendono i dati iniziali dal server via EL — token, URL del WebSocket, identificativo della stazione — e da lì in poi vivono sul WebSocket: a ogni messaggio `state` ridisegnano interamente il contenitore dei connettori, che è piccolo e non contiene campi da preservare.

A non scrive servlet: la servlet che prepara `station.jsp` e mette in request la stazione richiesta è di B (`StationPageServlet`), e restituisce sempre le stesse tre variabili definite in §4.2. È l'unico punto in cui le due parti si incontrano nel web, ed è fissato dal contratto JWT.

---

## 6. Parte B — coordinatore, back office, pagine REST

### 6.1 `vs_coord` (Erlang)

| Modulo | Ruolo |
|---|---|
| `vs_coord_srv` | `gen_server`: tabella claim in ETS `{VehicleId → {StationId, ConnId, ClaimId, GrantedAt, ExpiresAt}}`; serve il contratto §4.1 |
| `vs_coord_election` | bully: heartbeat 1 s, leader morto dopo 3 mancati, messaggi `election` / `answer` / `leader` |
| `vs_coord_membership` | vista dei coordinatori vivi; senza maggioranza (2 su 3) il nodo passa a `suspended` e rifiuta tutto |
| `vs_coord_rebuild` | dopo la vittoria interroga le stazioni con `who_do_you_hold`, ricostruisce, poi passa a `serving` |
| `vs_coord_stations` | monitor sui nodi stazione, mappa del cluster, statistiche aggregate |
| `vs_coord_bo` | ponte verso Java via mailbox `backoffice` |

Stati: `standby → rebuilding → serving`, più `suspended` in minoranza. Solo in `serving` concede claim.

### 6.2 Ponte JInterface (interno a B)

Nodo Java `voltshare_bo@backoffice`, mailbox `backoffice`, cookie `VOLTSHARE_ERLANG_COOKIE`.

```erlang
%% Erlang → Java
{stations_update, [{StationId, Node, Name, Free, Held, Charging,
                    Total, SitePowerKw, TariffCentsKwh, WsUrl}]}
{session_closed, SessionId, UserId, StationId, ConnId,
                 EnergyKwh, OverstaySeconds, StartedAt, EndedAt}
{no_show, UserId, StationId, ConnId}     %% inoltrato dalle stazioni
{show_up, UserId}
{notify, UserId, Kind, Text}

%% Java → Erlang
{From, get_stations}      → {stations_update, [...]}
{From, get_suspensions}   → {suspensions, [{UserId, UntilEpoch}]}
{user_suspended, UserId, UntilEpoch}
{user_unsuspended, UserId}
```

`WsUrl` la produce il coordinatore, così il back office non conosce la topologia.

### 6.3 Back office (Java, Tomcat 10, `jakarta.*`)

Modello MVC del lab 08: la servlet è il controller, prende i dati dai DAO, li mette in request e fa `forward` alla JSP.

| Classe | Ruolo |
|---|---|
| `web.LoginServlet` `web.RegisterServlet` `web.LogoutServlet` | form POST, creano la `HttpSession` e generano il JWT per il WebSocket |
| `web.StationsServlet` | legge la cache in memoria, forward a `stations.jsp`. **Non interroga il cluster** |
| `web.StationPageServlet` | prepara `station.jsp`: stazione richiesta, `wsUrl`, token in sessione |
| `web.ProfileServlet` `web.HistoryServlet` `web.NotificationsServlet` | DAO + forward alle rispettive JSP |
| `web.AuthFilter` | filtro servlet: senza sessione valida, redirect a `login.jsp` |
| `erlang.ErlangBridge` | `OtpNode` + `OtpMbox`, thread dedicato con riconnessione (modello BlackNet) |
| `erlang.StationDirectory` | singleton aggiornato dai push |
| `dao.*` | JDBC con `DataSource` JNDI da `context.xml` |
| `service.BillingService` | costo = energia × tariffa + overstay × tariffa al minuto |
| `service.PenaltyService` | N=2 e K=1 giorno, invia `user_suspended` al coordinatore |
| `util.JwtUtil` `util.PasswordUtil` | jjwt, BCrypt |

### 6.4 Pagine di B

`login.jsp`, `register.jsp`, `profile.jsp`, `history.jsp`, `notifications.jsp`, `stations.jsp`, più `WEB-INF/web.xml`, `css/` e gli eventuali tag file comuni (intestazione, menu). Tutte con JSTL ed EL, zero JavaScript:

```jsp
<c:forEach items="${stations}" var="s">
  <tr><td>${s.name}</td><td>${s.free}/${s.total}</td>
      <td><a href="station?id=${s.id}">apri</a></td></tr>
</c:forEach>
```

`stations.jsp` si aggiorna con un `<meta http-equiv="refresh" content="15">`: è una lista, non una vista in tempo reale, e la scelta va dichiarata nella relazione — il tempo reale è sul WebSocket, dove serve.

---

## 7. Milestone

### M0 — Fondamenta (1-2 giorni, insieme)
Repo strutturato; `contracts/claim.md`, `jwt.md`, `ui-handoff.md`, `schema.sql` scritti e congelati; `sample-tokens.md` consegnato da B; impianto web creato da B; `docker-compose.yml` con tutti i servizi; MySQL con schema e seed; `SCOPE.md` aggiornato per JSP; toolchain verificate.
**Da fare subito**: due container Erlang che si scambiano un messaggio, e un `OtpNode` Java che ne riceve uno. È la configurazione che dà più grane e va disinnescata prima di tutto il resto.

### M1 — Percorso base
**A**: stazione con connettori, canale driver, prenotazione con lease contro `mock-coord.erl`; `station.jsp` funzionante.
**B**: registrazione e login con `HttpSession` + JWT in sessione, `stations.jsp` dalla cache, `StationPageServlet`, coordinatore singolo che serve il contratto claim.
**Integrazione**: si sostituisce il mock col coordinatore vero e si prenota dal browser.

### M2 — Sessione e potenza
**A**: canale colonnina, autorizzazione della sessione contro il claim, riparto della potenza, `set_limit`, scrittura sessione, `session.jsp`, emulatore completo.
**B**: `session_closed` verso Java, storico, fatturazione, `history.jsp`.
**Integrazione**: due auto sulla stessa stazione, la potenza della prima cala all'arrivo della seconda.

### M3 — Tolleranza ai guasti (la parte che vale l'esame)
**B**: tre coordinatori, bully, quorum, ricostruzione, monitor sulle stazioni.
**A**: rinnovo dei claim, gestione del redirect al nuovo leader, revoca, riconnessione lato client.
**Integrazione**: si uccide il leader e le prenotazioni riprendono da sole; si uccide una stazione e i suoi conducenti tornano liberi.

### M4 — Regole di dominio
**A**: overstay con grace di 5 minuti, lista d'attesa con offerta a scadenza, segnalazione `no_show` / `show_up`.
**B**: penalità N/K, sospensioni propagate al coordinatore, notifiche, `profile.jsp`, `notifications.jsp`.

### M5 — Consegna
Deploy su più host, prove dei sei scenari, documento finale in inglese, registrazione di riserva della demo.

---

## 8. Come non bloccarsi

| Chi | Ha bisogno di | Sostituto |
|---|---|---|
| **A** | il coordinatore, per prenotare | `mock-coord.erl`, trenta righe, concede sempre. Scritto da A in M1 |
| **A** | token JWT validi | `contracts/sample-tokens.md`, consegnato da B in M0 |
| **A** | le pagine di login per arrivare alle sue | in sviluppo apre `station.jsp` con token e `wsUrl` scritti a mano nel markup |
| **B** | stazioni che rispondano al claim | un modulo di test che invia `{claim, ...}`; non serve una stazione vera |
| **B** | i push del coordinatore, per il bridge Java | li genera dal proprio coordinatore: entrambi i lati sono suoi |

Regola: **chi implementa il server di un contratto scrive anche un client di prova minimo.**

---

## 9. Verifica

**In isolamento**
- Erlang: `rebar3 eunit` per la logica pura (riparto della potenza, transizioni, decisione di elezione); `rebar3 ct` per claim e failover; per l'elezione, tre nodi locali con `-sname` diversi e `kill` manuale.
- Java: JUnit sui DAO con MySQL in container, test del `JwtFilter`, test del bridge con un `OtpNode` mittente.
- Client: prove manuali contro la stazione di A.

**Integrazione**: a ogni milestone, `docker compose up --build` e lo scenario della milestone dal browser.

**I sei scenari della demo** (test di accettazione da M3 in poi):

| # | Scenario | Come | Atteso |
|---|---|---|---|
| 1 | Contesa | `load-generator --scenario=contention --drivers=20` | una prenotazione concessa, le altre `ALREADY_HELD` |
| 2 | Claim fra nodi | stesso account, due stazioni, due browser | la seconda rifiutata con `NO_CLAIM` |
| 3 | No-show | `--scenario=noshow`, lease accorciato | il connettore torna `free` da solo |
| 4 | Potenza | due colonnine attive | la potenza della prima cala, visibile nel browser |
| 5 | Failover | `docker kill coord-leader` | elezione, ricostruzione, prenotazioni di nuovo possibili; le sessioni non si fermano |
| 6 | Crash stazione | `docker kill station-1` | prenotazioni decadute, conducenti liberi, stazione fuori dalla lista |

---

## 10. Rischi

| Rischio | Mitigazione |
|---|---|
| Le due macchine finiscono con OTP diverse | `minimum_otp_vsn` in `rebar.config` e tag fisso nel Dockerfile: la build fallisce subito invece di sbagliare in esecuzione |
| Erlang e OTP da imparare mentre si costruisce, ora per entrambi | M1 volutamente minimale; la complessità arriva in M3 quando il linguaggio è familiare. Il lab 03 è già un `gen_server` funzionante da cui partire |
| JInterface fragile (nomi nodo, cookie, DNS fra container) | Provato in M0 prima di ogni altra cosa |
| Il contratto claim cambia a metà | È l'unico vero confine: si tocca solo con PR condivisa, e mai a metà milestone |
| M3 sottovalutata | È la parte che vale l'esame: va pianificato lì il tempo maggiore, non in fondo |
| Le pagine di A e B nella stessa cartella Maven | File distinti, impianto creato da B in M0 e poi non più toccato |
| Il frontend si mangia i giorni | Pagine deliberatamente spartane: la valutazione riguarda la coordinazione |
