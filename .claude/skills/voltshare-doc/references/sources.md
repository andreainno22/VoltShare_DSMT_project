# Fonti: dove sta cosa, e quanto ci si può fidare

Regola generale: le note di progetto dicono **cosa si è deciso**, il codice dice **cosa
fa il sistema**. Quando divergono vince il codice, e la nota va corretta.

## Documenti di progetto

| File | Righe | Contenuto | Affidabilità |
|---|---|---|---|
| `src/SCOPE.md` | ~140 | requisiti, attori, P1-P7, confine del sistema, decisione su P2, alternative scartate | alta: è il documento approvato, già in inglese |
| `src/DESIGN-NOTES.md` | ~300 | il perché di ogni scelta, fault tolerance in dettaglio, limiti ammessi, mappatura al programma del corso | alta, ma §9 elenca decisioni ancora aperte: verificare cosa è stato poi deciso |
| `src/DEMO.md` | ~740 | scenari dimostrativi con comandi e output reali | alta per i comandi, da rieseguire per i numeri |
| `src/PROGRESS.md` | ~3200 | diario di lavoro con le misure datate | è un diario: le voci vecchie possono essere superate da quelle nuove. Leggere dal fondo |
| `src/piano.md` | ~330 | piano iniziale con la ripartizione dei componenti | **datato**: descrive intenzioni, non il risultato. Usare solo per orientarsi |
| `src/erlang/scelte_di_progetto.md` | ~2200 | decisioni sul codice Erlang, modulo per modulo | alta, è la fonte più vicina al codice |
| `src/deploy/scelte_di_progetto.md` | ~40 | scelte sul deploy | alta |
| `src/emulator/README.md` | | emulatore charge point e generatore di driver | alta |

## Contratti di protocollo

In `src/contracts/`, sono la fonte per la sezione 9 del documento:

| File | Canale |
|---|---|
| `ws-driver.md` | WebSocket browser ↔ stazione |
| `ws-chargepoint.md` | WebSocket charge point ↔ stazione, sottoinsieme OCPP 1.6-J |
| `claim.md` | protocollo dei claim stazione ↔ coordinatore |
| `jwt.md` | token, emissione dal back office e verifica in stazione |
| `erlang-java.md` | ponte JInterface back office ↔ coordinatore |
| `sample-tokens.md` | token di esempio e la trappola di `jose_jwt:verify/2`, che verifica solo la firma |

Gli altri file in `contracts/` sono note fra i due membri del gruppo (`nota-per-B-*.md`,
`risposta-per-A-*.md`, `review-per-A-*.md`): sono discussioni, non specifiche. Utili per
capire *perché* una cosa è come è, mai da citare come fatto.

## Codice

### Coordinatore, `src/erlang/apps/vs_coord/src/`

| Modulo | Cosa guardarci |
|---|---|
| `vs_coord_srv.erl` | claim table, concessione e rifiuto dei claim |
| `vs_coord_election.erl` | bully, chi è leader |
| `vs_coord_membership.erl` | heartbeat, quorum, sospensione della minoranza |
| `vs_coord_rebuild.erl` | ricostruzione della claim table dopo il failover |
| `vs_coord_bo.erl` | canale verso il back office |
| `vs_coord_sup.erl`, `vs_coord_app.erl` | albero di supervisione |

### Stazione, `src/erlang/apps/vs_station/src/`

| Modulo | Cosa guardarci |
|---|---|
| `vs_connector.erl` | il `gen_statem` per connettore: è P1 |
| `vs_station_mgr.erl` | arbitraggio dei connettori, potenza di sito |
| `vs_power.erl` | politica di allocazione della potenza: è P5 |
| `vs_claim_client.erl` | lato stazione del protocollo di claim |
| `vs_driver_ws.erl`, `vs_driver_proto.erl` | WebSocket driver |
| `vs_cp_ws.erl`, `vs_cp_proto.erl` | WebSocket charge point |
| `vs_jwt.erl` | verifica del token |
| `vs_ping.erl` | rilevamento di liveness |
| `vs_station_db.erl` | accesso a MySQL da Erlang |
| `vs_station_sup.erl`, `vs_connector_sup.erl` | strategie di supervisione |

`vs_common/` ha `vs_env.erl` (configurazione) e `vs_time.erl`. `vs_mock_coord/` serve ai
test: non è parte del sistema consegnato e non va nel documento se non come strumento di
test.

### Back office

`src/backoffice/src/main/java/it/unipi/dsmt/voltshare/`, con `erlang/ErlangBridge.java` e
`erlang/StationDirectory.java` per il lato JInterface, `web/` per le servlet, `dao/` per
JDBC, JSP in `src/main/webapp/WEB-INF/views/`.

### Deploy e test

`src/deploy/docker-compose.yml` è l'unica fonte valida per la sezione 10: numero di
container, reti, variabili. `src/deploy/.env.demo` per i parametri della dimostrazione.
`src/scripts/eunit_check.sh` per i test, e le directory `test/` dentro ciascuna app Erlang.

## Verifiche rapide

Prima di scrivere un fatto, un comando che lo conferma:

```powershell
# quanti container e quali reti
Select-String -Path src\deploy\docker-compose.yml -Pattern "container_name|networks:|image:"

# i valori di configurazione veri (lease, grazia, soglie)
Select-String -Path src\deploy\.env.demo -Pattern "."

# dove si decide il quorum
Select-String -Path src\erlang\apps\vs_coord\src\*.erl -Pattern "quorum|majority"

# la misura di una demo, con la sua data
Select-String -Path src\DEMO.md -Pattern "kWh|measured"
```

## Cosa non entra nel documento

- Le note interne fra i due membri del gruppo, e il tono con cui sono scritte.
- `PROGRESS.md` come narrazione: il documento consegnato descrive il sistema, non il
  percorso per arrivarci.
- `vs_mock_coord` e gli altri appoggi per i test, se non nella sezione dei test.
- Qualunque cosa presente in `piano.md` e mai realizzata.
