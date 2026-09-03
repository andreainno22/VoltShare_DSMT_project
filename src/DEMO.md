# VoltShare — piano di esecuzione della demo

Runbook operativo per la presentazione di M5. Lo leggono in due mentre provano e durante
la demo. Il piano *concettuale* (quali problemi si mostrano e perché) sta in
[DESIGN-NOTES.md](DESIGN-NOTES.md) §10; qui c'è solo il *come*: comandi esatti, ordine,
cosa deve apparire sullo schermo, cosa dire, e i fallback.

> Se la presentazione è in inglese, le battute di «cosa dire» vanno tradotte; i comandi no.

---

## 0. Revisione di A — 2 settembre

Runbook ottimo: ruoli, mondo di sfondo, mappa P1-P7, appendici e fallback. L'ho riletto
verificando ogni affermazione sul codice, e ho cambiato sei cose. **Tre sono correzioni**,
il resto sono innesti dal mio copione.

| # | Cosa | Dove |
|---|---|---|
| 1 | **Correzione — il beat del claim ricostruito non aveva un claim da mostrare.** Il walk-in **non crea un claim** (`free/3` chiama `adopt(Info, undefined, Data)`; il commento di P14 lo dice: *«a walk-in presents nothing: its `claim_id` is `undefined`»*). Al T+3:10 tutte le auto in campo sono walk-in e le prenotazioni dei no-show sono scadute: al failover la tabella è **vuota** e `coord-status.sh` direbbe `claims=0`. Ora l'auto del riparto **prenota e poi attacca**, così il claim c'è, è rinnovato per tutta la demo, ed è quello che il nuovo leader ricostruisce. | §4, §8 T+3:10, §10.1 |
| 2 | **Correzione — ogni riavvio di un coordinatore è una finestra di P18.** Un coordinatore che riparte si elegge prima che le stazioni si siano riconnesse, ricostruisce con `asked 0 station node(s)` e serve **con la tabella vuota**: misurato l'1/09, lo stesso veicolo ha ottenuto **due prenotazioni** su due stazioni per 13,65 s. Il tuo punto «prova un `reserve`, ora passa» cade proprio lì. Aggiunta la regola d'attesa. | §10.2, §10.3, §11 |
| 3 | **Correzione — il Ctrl-C alla colonnina non arriva sempre** (misurato l'1/09: un emulatore è rimasto vivo e me ne sono accorto solo leggendo il suo terminale). L'overstay ora finisce da solo col `--linger`, senza toccare niente in scena. | §8 overstay, §11 |
| 4 | Il **quorum si mostra con `network disconnect`**, non con `kill` — come dice il tuo PROGRESS §7y del 27/08 (*«da mettere nella demo al posto di `docker kill`»*): il caso difficile è il nodo vivo che non vede più gli altri. | §10.2 |
| 5 | Colonna **«già visto»** nella mappa dei beat: dove ciascuna cosa è stata vista funzionare, con la data. Serve a non mostrare niente per la prima volta davanti al professore — e a sapere in anticipo quali beat vanno provati. | §1, §2 |
| 6 | Chiusura sul **metodo** (`eunit_check.sh`) e tabella **«cosa non mettiamo in scena»** con le risposte pronte. | §8 T+7:30, §13 |

Sotto ogni beat, la riga **⟵ Prova** dice dove quella cosa è già stata osservata. Dove
manca, il beat è in §13 o nella checklist di prova.

---

## 1. Il principio

- **Una corsa sola di ~8–10 minuti.** Il mondo gira da solo (colonnine emulate che
  caricano in sottofondo) e il presentatore ci agisce sopra dal browser, dal vivo.
- **«Tempo veloce» = lease e grazie corti**, non un orologio scalato. Un lease di 90 s
  fa sì che un no-show da «15 minuti» maturi in un minuto e mezzo. Va detto nella
  relazione così com'è (DESIGN-NOTES §6, §10) — non è una scorciatoia, è configurazione.
- **Due persone.** Il *presentatore* guida browser e `docker kill` e non tocca mai un
  emulatore; il *co-pilota* fa partire il mondo e poi esegue solo i comandi che
  corrispondono alle azioni del presentatore (già scritti sotto, li incolla).
- **L'invariante P2 vincola la coreografia**: il veicolo del presentatore può tenere
  **una sola prenotazione per volta in tutta la rete**. Le sue azioni sono quindi
  necessariamente in fila, mai sovrapposte — l'ordine del §9 tiene conto di questo.
- **Niente si mostra per la prima volta.** Ogni beat porta una riga *⟵ Prova* con dove
  quella cosa è già stata vista funzionare. Le due che non ce l'hanno — il riparto in
  pagina e le pagine del no-show — sono segnate, e vanno chiuse nella prova generale
  (Appendice D). Se in prova un beat non torna, si toglie: la corsa è fatta di pezzi
  indipendenti apposta.

---

## 2. Cosa si vede (mappa per l'orale)

| Beat | Problema | Dove si vede | Già visto |
|---|---|---|---|
| Due tab, stesso account, `reserve` su due stazioni | **P2** — un veicolo, una prenotazione, di rete | la seconda tab: *"your vehicle already holds a reservation elsewhere"* (`NO_CLAIM`) | ✅ 27/08, in Docker, dall'utente |
| N driver sullo stesso connettore (opener facoltativo) | **P1** — attore che serializza senza lock | pannello `driver.js --scenario contention`: 1 accettata, N−1 `ALREADY_HELD` | ✅ fino a 200 driver, `REPORT_LOAD.md` |
| Prenoto e non mi presento ×2 | **P3** — leasing | note `reservation_expired`; poi `notifications.jsp` con «1 of 2» / «2 of 2 — suspended 1 day»; `reserve` successivo → `SUSPENDED` | ⚠️ meccanismo ✅ 31/08 (SQL + log di tutta la catena), **pagine mai viste** |
| Una seconda auto attacca mentre carico | **P5** — potenza come risorsa divisibile | `session.jsp`: i kW calano, `eta_seconds` salta | ⚠️ calcolo ✅ test + E2E letto via rpc (M2), **mai visto in pagina** |
| Resto attaccato dopo la fine carica | overstay (§3.4) | fase `complete` → `overstay`, `overstay_seconds` che sale, addebito in `history.jsp` | ✅ 1/09 nel Chrome vero, fino a `1,58 kWh · 10 min · € 5,71` |
| **`network disconnect` su station2** | **P4** — un sito che funziona ma che l'operatore non vede più | la lobby perde Livorno e il coordinatore ne scarta i claim, **mentre le auto continuano a caricare**; una ricarica nuova però non parte (serve MySQL, che è oltre il taglio) | ✅ 3/09: energia 0,248 → 0,403 → 0,558 kWh a stazione isolata, nessuna interruzione alla riconnessione, e `no account for vehicle 104` sul tentativo nuovo |
| `docker kill station2` | **P4** — il nodo stazione che muore | la lobby perde Livorno; sessioni in corso perse, nessuna riga scritta | ✅ 3/09: `sessions` ferma a 3 prima e dopo. L'energia però sopravvive, perché la conta la colonnina: 34,795 kWh prima, 34,812 al riavvio |
| `docker kill coord3` (leader) mentre una sessione carica | **P2b** — failover, elezione bully, ricostruzione | pannello log coordinatori; la sessione a schermo non batte ciglio; `reserve` rifiutato durante il rebuild, poi di nuovo ok | ✅ 25/08 (B) e 1/09 (A, cronometrato: 2,29 s) |
| **`network disconnect` su un coordinatore** | **P2b** — quorum contro split-brain | log `QUORUM LOST (1 of 3)`, `mode=suspended`; ogni `reserve` fallisce; la carica continua | ✅ 27/08 (B, PROGRESS §7y) e 1/09 (A, dal lato stazione) |
| Tutta la corsa | **P6** snapshot completo pushato, **P7** at-most-once | la pagina non deriva stato; un frame perso non la sfasa | ✅ per costruzione, e visto in ogni corsa |

---

## 3. I file da preparare (una volta sola)

Nessuna modifica al codice applicativo, agli emulatori o ai contratti. Solo:

| File | Contenuto | Appendice |
|---|---|---|
| `deploy/.env.demo` | i tempi corti (lease, grazie, sweep) + cookie + segreto JWT | [A](#appendice-a--deployenvdemo) |
| `deploy/seed-demo.sql` | utenti + veicoli per le colonnine di sfondo (idempotente) | [B](#appendice-b--deployseed-demosql) |
| `emulator/demo/world.sh` | il mondo di sfondo: due auto su Livorno, con un ciclo che le rilancia se muoiono | [C](#appendice-c--gli-script) |
| `emulator/demo/presenter-cp.sh` | helper del co-pilota: una colonnina per le azioni del presentatore | [C](#appendice-c--gli-script) |
| `emulator/demo/logs.sh` | **il pannello principale**: i sette servizi in una colonna sola, denoised, con l'ora e il nodo colorato | [C](#appendice-c--gli-script) |
| `emulator/demo/coord-logs.sh` | solo i coordinatori. Resta per quando serve guardare l'elezione da sola; in scena si usa `logs.sh` | [C](#appendice-c--gli-script) |
| `emulator/demo/unsuspend.sh` | toglie una sospensione dal database **e** dalla cache dei tre coordinatori (la riga da sola non basta) | [C](#appendice-c--gli-script) |
| `emulator/demo/socket.sh` | l'estintore: riattacca una colonnina vuota a una presa andata `out_of_service`, e ce la tiene. Serve solo dopo un errore — tipicamente un Ctrl-C dato a un `presenter-cp.sh` per riprendersi il terminale | [C](#appendice-c--gli-script) |
| `emulator/demo/coord-status.sh` | `mode` e numero di claim di un coordinatore (bonus) | [C](#appendice-c--gli-script) |
| `emulator/demo/p2.sh` | P2 come one-shot, se le due tab dal vivo sono scomode | [C](#appendice-c--gli-script) |
| `emulator/demo/reserve.js` | **(A, nuovo)** client minimo del canale driver: `join` con un JWT firmato e una singola azione (`reserve`, `cancel_reservation`, `none`). Serve al co-pilota per far prenotare un veicolo seminato — è con questo che l'auto del riparto prende un claim vero (§8 T+3:10, §10.1). È il mio `scena-pixel-driver.js`, con cui ho preso le misure dell'1/09: da promuovere qui | [C](#appendice-c--gli-script) |
| `docker-compose.yml` | **una riga**: su `station1`, `SITE_POWER_KW: 350` → `SITE_POWER_KW: ${STATION1_SITE_POWER_KW:-350}` (default invariato; `.env.demo` lo porta a 200 così il riparto di potenza è visibile con due auto) | — |

---

## 4. Allocazione dei connettori

Da rispettare, altrimenti il mondo di sfondo ruba un connettore al presentatore a metà beat.

| Conn | Stazione | rated | Di chi è nella demo | Uso |
|---|---|---|---|---|
| 1 | Pisa Centro | 150 | **presentatore** | bersaglio P2 A · walk-in carica · vittima del riparto · overstay |
| 2 | Pisa Centro | 150 | **presentatore** | no-show #1 |
| 3 | Pisa Centro | 150 | mondo (su cue) | la «seconda auto» che fa calare la potenza di conn 1 — **prenota prima di attaccare**, ed è il suo il claim che il failover ricostruisce (§10.1) |
| 4 | Pisa Centro | 50 | **presentatore** | no-show #2 |
| 5 | Livorno Port | 150 | **presentatore** | bersaglio P2 B (tenuto ~2 s, poi cancellato) |
| 6 | Livorno Port | 50 | mondo (`world.sh`) | walk-in che carica per tutta la demo. **Sopravvive alla partizione** di station2, ed è questo il beat |
| 7 | Livorno Port | 50 | mondo (`world.sh`) | come sopra |

Veicoli: presentatore = `$PV` (assegnato alla registrazione, vedi §6); mondo = 101, 102;
auto del riparto su conn 3 = 103. Tutti in `seed-demo.sql` tranne `$PV`.

---

## 5. Layout degli schermi

```
SCHERMO PROIETTATO  —  Browser (presentatore)
  tab 1  http://localhost:8080/stations      (lobby)
  tab 2  /station?id=1  (Pisa)      tab 3  /station?id=2  (Livorno)
  tab 4  /session       tab 5  /notifications       tab 6  /history

A LATO  —  secondo monitor o terminale grande
  Pane A   ./emulator/demo/logs.sh      TUTTO il sistema, una colonna sola
  Pane B   ./emulator/demo/world.sh     lo sfondo: si lancia e non si tocca più
  Pane C   terminale libero             docker kill / network disconnect, presenter-cp.sh
```

**Tre riquadri, non quattro, e il primo è nuovo.** La versione precedente aveva un pannello
per servizio (`coord-logs.sh`, i log di `station1`, quelli del back office): seguirne quattro
mentre si parla è ingestibile, e soprattutto **la storia da raccontare è una sola** — la
prenotazione parte dal browser, il coordinatore decide, la stazione apre la sessione, Java
la prezza. Su quattro riquadri quella storia è a pezzi.

I due pannelli che restano oltre ai log non vanno toccati fino alla fine: `world.sh` e
`presenter-cp.sh` **sono hardware**. Se li chiudi, trenta secondi dopo i loro connettori
vanno `out_of_service` (§11).

**Tre riquadri, non quattro, e il primo è nuovo.** La versione precedente aveva un
pannello per servizio (`coord-logs.sh`, i log di `station1`, quelli del back office):
seguirne quattro mentre si parla è ingestibile, e soprattutto **la storia da raccontare
è una sola** — la prenotazione parte dal browser, il coordinatore decide, la stazione
apre la sessione, Java la prezza. Su quattro riquadri quella storia è a pezzi.

`logs.sh` segue i sette servizi insieme, in ordine di tempo, con l'ora e il nome del
nodo colorato, e toglie il rumore periodico (le intestazioni doppie del logger Erlang,
la ripubblicazione del leader ogni 30 s, il ciclo di vita di Tomcat). `VERBOSE=1
./demo/logs.sh` rimette tutto; `./demo/logs.sh coord1 coord2 coord3` restringe.

Così si legge:

```
08:21:10  station1    driver channel: user 103 (vehicle 103) joined station 1
08:21:10  coord3      claim GRANTED to vehicle 103 (user 103) on station 1 connector 3 — c-67C6…
08:21:11  station2    driver channel: user 103 (vehicle 103) joined station 2
08:21:11  coord3      claim REFUSED to vehicle 103 (user 103) on station 2 connector 5 — already_held
```

Quelle due righe di `coord3` sono state aggiunte il 3/09: fino a quel giorno
`vs_coord_srv` aveva ventitré chiamate al logger e **nessuna** sul percorso che concede
o rifiuta, quindi P2 — la battuta centrale della demo — non lasciava traccia da nessuna
parte. Il rifiuto non era loggato né dal coordinatore né dalla stazione.

---

## 6. Setup il giorno (T−20 min)

Tutto da `src/deploy/` salvo diverso avviso.

```bash
# 1. su i sette container con il profilo demo
cd src/deploy
docker compose --env-file .env.demo up -d
docker compose --env-file .env.demo ps          # 7 up, mysql healthy

# 2. semina le colonnine di sfondo (schema.sql è già girato al primo boot)
docker exec -i mysql mysql -uvoltshare -pvoltshare voltshare < seed-demo.sql

# 3. account del presentatore: registrazione dal form (crea utente + veicolo e fa login)
#    http://localhost:8080/register   →   andrea / demo1234 / batteria 60 / max 150
#    poi apri il Profilo: il numero del veicolo è stampato lì, "Vehicle #N".
#    → export PV=N                   (nel pane C)
#    Non serve nessuna query: profile.jsp lo mostra, ed è la pagina che hai già aperto.

# 4. prova rapida che il confine regge (facoltativa, 20 s)
cd ../emulator && node driver.js --self-test        # deve dire "identical to the published fixture"

# 5. apri il pannello log in Pane A
./demo/logs.sh
#    deve mostrare, a regime: coord3 = leader (rango più alto), coord1/coord2 = standby
```

**Un account nuovo a ogni prova generale è la strada giusta**, e costa dieci secondi. In
profilo demo il lease è di 90 secondi, quindi una prenotazione fatta per mostrare P2 e poi
dimenticata diventa uno strike, e **due strike chiudono l'account fuori per un giorno**
(è successo due volte in ventiquattro ore). Registrarsi di nuovo è più rapido che
sbloccare. Se proprio serve sbloccare quello vecchio: `./demo/unsuspend.sh <username>` —
tocca il database **e** la cache dei tre coordinatori, perché cancellare solo la riga non
basta (la ripubblicazione del back office la rimette entro 30 s).

**Niente `--build` la mattina della demo.** Le immagini si costruiscono la sera prima
(`docker compose --env-file .env.demo build`, una volta): con `--build` il passo 1 impiega
minuti invece di secondi, e se lo si interrompe a metà si resta con i vecchi container
uccisi e i nuovi fermi in `Created` — cluster giù e lobby che dice «no station is
reporting» senza spiegare perché. Il ripristino è `up -d` di nuovo, non `down`.

Verifiche prima di cominciare:

- lobby carica con **due** stazioni, Pisa 4 connettori / Livorno 3, tutti `free`;
- `docker compose logs --since 2m coord3 | grep -i "now the leader"` → coord3;
- niente pause della VM di Docker Desktop: tieni i log che scorrono, non lasciare la
  macchina ferma prima di iniziare (vedi §11).

---

## 7. Ruoli

**Presentatore** — browser, narrazione, `docker kill` / `network disconnect` dal Pane B.
**Co-pilota** — esegue i comandi marcati 🡒 **co-pilota** nel copione. Ha `$PV` nel suo
shell (dal Profilo, «Vehicle #N»).

---

## 8. La corsa — copione minuto per minuto

I tempi sono indicativi: le attese dei no-show (90 s) sono assorbite dalle chiacchiere.

### T+0:00 — il mondo parte
🡒 **co-pilota**, Pane B:
```bash
cd src/emulator && ./demo/world.sh
```
Due auto (veicoli 101, 102) attaccano su Livorno 6 e 7 a 20 s di distanza. **Lo script
resta lì per tutta la demo**: ogni auto gira in un ciclo che la rilancia se muore, ma se
chiudi il terminale muoiono entrambe e i connettori vanno `out_of_service`.

**Dire:** «Questi sono altri automobilisti. La stazione non sa che sono emulati: per lei
è un cavo che entra, esattamente come per un caricatore vero.»

**Vedere:** la lobby — Livorno a 2 connettori `charging`, i kW allocati che salgono.

### T+0:30 — P2, un veicolo una prenotazione (dal vivo)
**Presentatore:** tab 2 (Pisa) e tab 3 (Livorno) affiancate. `reserve` sul connettore 1 di
Pisa, poi **subito** `reserve` sul connettore 5 di Livorno.
**Vedere:** una passa (diciamo Pisa 1: `held_by_me`); l'altra torna
*"your vehicle already holds a reservation elsewhere"* — codice `NO_CLAIM`.
**Dire:** «Nessuna delle due stazioni può decidere da sola: il connettore, da entrambe le
parti, era libero. La decisione la prende il coordinatore, ed è l'unico punto della rete
che vede il veicolo, non il connettore. Questo è il cuore del progetto — P2.»
Poi **cancella** la prenotazione sopravvissuta (Cancel). *(Se le due tab dal vivo sono
scomode: `./demo/p2.sh` nel Pane C fa la stessa cosa da riga di comando.)*

### T+0:50 — no-show #1 (dal vivo)
**Presentatore:** tab 2, `reserve` sul connettore **2**. Non fa altro.
**Dire:** «Ho circa 90 secondi per infilare il cavo. Non lo faccio — vediamo cosa succede.»

### T+1:10 → ~T+2:20 — si riempie il tempo, e cade una stazione
Mentre il lease di conn 2 scorre, il presentatore:
- mostra la lobby e il traffico di sfondo, racconta l'architettura (7 nodi, i tre canali);
- **opener P1 facoltativo** 🡒 **co-pilota**:
  `node driver.js --scenario contention --connector 3 --drivers 15` — 1 accettata,
  14 `ALREADY_HELD`. «Quindici richieste, un connettore, nessun lock: l'attore le ha
  messe in coda nella sua mailbox e risposte una alla volta.»
- **P4 — la stazione che l'operatore non vede più.** Presentatore, Pane B:
  ```bash
  MSYS_NO_PATHCONV=1 docker network disconnect voltshare_voltshare station2
  ```
  **`disconnect`, non `kill`, e la differenza è il senso del beat.** `kill` è un blackout
  del sito: la BEAM evapora, non c'è nessun dentro che continua, e la storia si esaurisce
  in «si è rotto». `disconnect` taglia solo il **collegamento al centro**: l'impianto
  continua a erogare mentre l'operatore lo perde di vista. È il guasto per cui esistono il
  lease e il monitor sui nodi, ed è quello con una lettura chiara fuori da questa stanza.

  **Vedere**, e sono tre cose insieme:
  - la **lobby perde Livorno** — la disegna il coordinatore, e il coordinatore non la vede;
  - nel Pane A: `** Node vs@station2 not responding **` seguito da
    `node vs@station2 is down, dropping stations [2] and their claims`;
  - **le auto continuano a caricare.** Nel terminale di `world.sh` i contatori scorrono, e
    l'energia sale. Misurato il 3/09 a stazione isolata: **0,248 → 0,403 → 0,558 kWh**.

  ⚠️ **Guarda l'energia per almeno mezzo minuto prima di trarre conclusioni.** Il tick del
  contatore è di 5 secondi e alla partizione segue una finestra di riconnessione: tre
  letture ravvicinate danno lo stesso numero e sembrano dire che tutto si è fermato. Il
  3/09 quella lettura affrettata è costata una riprogettazione del deploy, poi buttata.

  **Una cosa che l'isolamento *impedisce*, e vale la pena mostrarla:** prova a far
  attaccare un'auto nuova su Livorno. Non parte. Autorizzarla significa risalire dal
  veicolo al proprietario, cioè interrogare MySQL, che sta oltre il taglio — nel Pane A
  compare `no account for vehicle N`. Le ricariche già in corso non se ne accorgono,
  perché non toccano il database. *«Il sito finisce quello che ha cominciato e non accetta
  nessuno di nuovo — che è quello che fa una colonnina vera con una tessera sconosciuta e
  nessuna linea.»*

  **Dire:** «Il sito funziona. Le auto caricano, chi è fisicamente lì può usarlo. Ma
  l'operatore è cieco: la lobby non elenca più Livorno, perché la lobby la disegna il
  coordinatore. È il guasto peggiore da diagnosticare — funziona tutto tranne chi deve
  saperlo — ed è il motivo per cui le prenotazioni hanno una scadenza invece di dipendere
  da qualcuno che le cancelli.»

  Poi si riattacca, ed è il momento migliore:
  ```bash
  MSYS_NO_PATHCONV=1 docker network connect voltshare_voltshare station2
  ```
  Livorno torna in lobby e **la ricarica non si è mai interrotta**: la stazione si
  riannuncia, il coordinatore la riprende. Misurato il 3/09: due stazioni note al leader
  dopo undici giri di controllo, energia da 1,014 a 1,569 kWh senza un salto.

  *(Se vuoi mostrare anche il crash: `docker kill station2` è il caso duro — sessioni
  perse, nessuna riga scritta, verificato il 3/09 con `sessions` ferma a 3 prima e dopo.
  L'energia però sopravvive, perché la conta la colonnina e la riporta al riavvio: 34,795
  kWh prima del kill, 34,812 dopo. Due guasti, due reazioni: vale la pena mostrarli
  entrambi, ma se il tempo stringe, quello che si tiene è il `disconnect`.)*

### ~T+1:40 — no-show #1 scade
**Vedere:** nota `reservation_expired` accanto al connettore 2.
**Presentatore:** subito dopo, `reserve` sul connettore **4** (no-show #2). Non fa altro.

### ~T+2:40 — no-show #2 scade → sospensione
**Vedere:** tab 5 `notifications.jsp` con due righe —
«… 1 of 2 — reaching 2 suspends reservations for 1 day(s).» e la seconda a «2 of 2».
Poi il presentatore prova un `reserve` qualsiasi → banner **`SUSPENDED`**.
**Dire:** «Due no-show consecutivi. L'account perde il diritto di *prenotare* per un
giorno — non il diritto di *caricare*: su un connettore libero il walk-in funziona ancora.
Il contatore lo tiene il back office in un posto solo; la stazione l'ha solo segnalato, non
scritto. Nessun valore conteso in più — è la stessa forma del claim.»

### ~T+3:10 — carico lo stesso (walk-in), e la potenza si divide
🡒 **co-pilota** — walk-in sul connettore 1 col veicolo del presentatore, cavo che resta
dentro 60 s dopo lo stop (è l'overstay, e finisce da solo — vedi §8 T+6:30):
```bash
./demo/presenter-cp.sh 1 "$PV" --linger 60
```

> `--soc 45 --battery 60 --max-kw 150` erano nel comando fino al 3/09 e **sono i default
> di `cp.js`**: riscriverli non cambiava niente e allungava una riga che va digitata
> davanti a un pubblico. `--linger` invece serve, ed è l'unico argomento che serve: senza,
> l'emulatore stacca subito dopo lo Stop e l'overstay non esiste.
>
> `presenter-cp.sh` passa anche `--stay` da sé: la colonnina sopravvive all'auto, così
> quando la ricarica finisce il connettore torna `free` invece di andare
> `out_of_service` (§11).
**Presentatore:** tab 4 `session.jsp` — la sessione parte, ~150 kW (Pisa a 200 kW di
budget nel profilo demo, una sola auto sta sotto).

🡒 **co-pilota** — la seconda auto, **che prima prenota e poi attacca** (due comandi):
```bash
node demo/reserve.js --station 1 --connector 3 --user 103 --vehicle 103 --action reserve
./demo/presenter-cp.sh 3 103
```
> **Perché prenota invece di fare un walk-in** *(correzione di A, §0 n.1)*: un walk-in
> **non ha claim** — `free/3` apre la sessione con `adopt(Info, undefined, Data)`. Se tutte
> le auto in campo sono walk-in, al failover del §10 la tabella del coordinatore è vuota e
> il beat «lo stesso `claim_id` dopo la ricostruzione» non ha niente da mostrare. Con la
> prenotazione il claim entra nella sessione (`held → charging` lo porta con sé) e viene
> rinnovato ogni 10 s per tutta la demo: è quello che il nuovo leader ricostruirà.

**Vedere:** su `session.jsp` la potenza del presentatore scende da ~150 a ~100 kW;
`eta_seconds` fa un salto.
**Dire:** «Una risorsa divisibile, non una mutua esclusione. È ripartita a ogni arrivo e
ogni partenza; il salto dell'ETA è la prova visibile di P5 e non va nascosto.»

*Variante (se la prova generale la promuove): una terza auto sul connettore **4**, che è da
**50 kW**, fa vedere il **travaso** invece della sola divisione — quota equa 66,7, ma la
presa piccola non può prenderne più di 50 e l'avanzo trabocca sulle altre due:
**75 · 75 · 50**. Un comando in più (`./demo/presenter-cp.sh 4 104 --soc 30 --battery 50
--max-kw 50`) e una frase: «nessuno resta a secco e niente va sprecato».*

⟵ **Prova:** il calcolo è coperto dai test unitari con la tabella dei numeri e l'E2E di M2
fu letto dal `station_state` via rpc — **con la pagina davanti non è mai stato visto**. È il
beat numero 1 della prova generale (Appendice D). Se i numeri non tornano, si toglie e si
racconta a voce: nient'altro dipende da qui.

### ~T+4:00 — il coordinatore cade (la parte invisibile) → §10

### ~T+6:30 — resto attaccato: overstay e penalità
**Presentatore:** tab 4, preme **Stop** sulla sessione del connettore 1.
**Vedere:** fase `complete` (carica finita, cavo dentro) **subito**, e la potenza che torna
nel calderone — l'intestazione della stazione lo mostra. Dopo `OVERSTAY_GRACE_SECONDS`
(20 s) la fase diventa `overstay`, `overstay_seconds` sale, e su tab 5
`notifications.jsp` compare la riga `overstay_started`.
**Nessuno tocca la colonnina**: il `--linger 60` del T+3:10 fa uscire il cavo da solo un
minuto dopo lo Stop. *(Correzione di A, §0 n.3: il Ctrl-C a `cp.js` non arriva sempre —
l'1/09 un emulatore è rimasto vivo e me ne sono accorto solo leggendo il suo terminale.
In scena non si usa: la durata la decide il flag.)*
**Vedere:** `unplugged`; entro ~10 s (sweep) tab 6 `history.jsp` mostra la sessione con
energia **e** addebito di overstay — 40 secondi fatturabili, cioè i 60 col cavo dentro meno
i 20 di tolleranza.
**Dire:** «Questo è l'unico addebito del sistema, ed è deliberato: un no-show lo risolve il
software liberando il connettore per lease; un'auto parcheggiata no. Il sistema può solo
accorgersene, avvisare, e far costare l'attesa. E i secondi che la stazione scrive sono già
**netti** della tolleranza: la tolleranza è configurata sulla stazione e in nessun altro
posto, così il back office non può sottrarla una seconda volta — un dato, un proprietario.»

*Se chiedono della notifica:* «ha fatto tutto il giro — presa, stazione, coordinatore, ponte
Java, database — e le tre cose che viaggiano su quel filo hanno tre garanzie diverse
apposta: la riga di sessione è **at-least-once** su una scrittura idempotente, lo strike del
no-show è **at-most-once** perché un contatore non sa riconoscere un duplicato, la notifica
è at-most-once al contrario — un duplicato è una riga letta due volte, una persa è persa.»

⟵ **Prova:** tutta la catena vista nel Chrome vero l'1/09 — `complete` istantaneo,
`overstay` allo scadere della tolleranza, la riga in `/notifications` con l'ora locale
giusta (UTC in tabella, conversione di B corretta) e in `/history`
`1,58 kWh · overstay 10 min · € 5,71`, conto verificato al centesimo.

### ~T+7:30 — chiusura
Torna alla lobby, tutto stabile. Riepilogo P1–P7 contro quello che si è appena visto.

Poi, un comando solo nel Pane B — **chiudere sul metodo, non su una funzionalità**:
```bash
./src/scripts/eunit_check.sh          # → 386 tests, 0 failures
```
**Dire:** «Il numero di test è **asserito**, non solo contato. Abbiamo misurato che una
suite può perdere sessantaquattro test in silenzio e continuare a dichiararsi verde: da
allora il controllo fallisce anche se il totale cambia, e aggiornarlo fa parte
dell'aggiungere un test.»

🡒 **co-pilota:** `Ctrl-C` su `world.sh`.

⟵ **Prova:** girato tre volte di fila l'1/09, sempre verde. *(Se nel frattempo è entrata
la correzione di P18, il numero sarà più alto: leggilo da `EXPECTED_TESTS` in
`src/scripts/eunit_check.sh` la mattina della demo invece di impararlo a memoria.)*

---

## 9. Ordine sintetico (da tenere sott'occhio)

```
world.sh  →  P2 (2 tab) + cancel  →  no-show #1 (conn 2)
          →  [P1 opener]  [DISCONNECT station2: il sito vive, l'operatore è cieco]
          →  #1 scade → no-show #2 (conn 4)  →  #2 scade → SUSPENDED + notifications
          →  walk-in conn 1  →  conn 3: PRENOTA, poi attacca (riparto)   [§0 n.1]
          →  KILL COORD3 (§10.1)  →  DISCONNECT COORD2 (§10.2)  →  [bully: §10.3]
             ⚠ dopo OGNI riavvio di un coordinatore: ~10 s prima di qualunque reserve
          →  Stop su conn 1 → overstay → il --linger stacca da solo → history
          →  riepilogo  →  eunit_check
```

**I tre guasti, e perché sono tre e non uno.** Vale la pena dirlo in chiusura, perché è la
struttura dell'intera parte sulla tolleranza:

| Manovra | Cosa rappresenta | Come lo scopre il sistema |
|---|---|---|
| `docker kill coord3` | un nodo che muore | `nodedown`, immediato: il socket si chiude |
| `docker network disconnect … coord2` | un nodo **vivo** che non vede più gli altri | il battito, 3 s. `nodedown` arriverebbe a 60 |
| `docker network disconnect … station2` | un **sito** che funziona ma è irraggiungibile | il monitor sul nodo, e la lobby che si svuota |

Tre guasti diversi, tre rilevatori diversi, tre reazioni diverse. Un solo esperimento non
li avrebbe mostrati: `kill` chiude il socket e quindi **non esercita affatto** il percorso
del battito, che è il motivo per cui il battito esiste.

---

## 10. La parte invisibile: failover, quorum, bully

Per progetto l'elezione **non ha resa in UI** (il coordinatore è un indice, sta fuori dal
percorso di erogazione). Non inventare una dashboard: mostrala su **quattro superfici
insieme** — è più convincente così.

**Prima:** una sessione carica su `session.jsp` (quella del connettore 1, ancora aperta) e
il **Pane A** (`coord-logs.sh`) visibile. Il leader sano è **coord3** (rango più alto in
`COORD_NODES` ordinato).

### 10.1 `docker kill coord3` — il failover
Presentatore, Pane B:
```bash
docker kill coord3
```
1. **Nel Pane A**, entro ~3 s (battito 1 s × 3 mancati):
   ```
   coord1: election: leader vs@coord3 is gone, electing
   coord2: election: vs@coord2 is now the leader
   coord2: rebuild: 2 stazioni interrogate, N risposte → serving
   ```
2. **La UI non trema.** `session.jsp` sul connettore 1 continua: potenza costante, kWh che
   salgono. È il momento singolo più convincente — *«le sessioni in corso non passano dal
   coordinatore, quindi non si accorgono di niente»*.
3. **Le prenotazioni riprendono da sole.** Nella finestra di rebuild (~2 s) un `reserve`
   dal browser è rifiutato (`coordinator_reachable:false`, la pagina lo dice); qualche
   secondo dopo lo stesso `reserve` passa. Nessuno ha fatto niente.
4. **Il claim è stato ricostruito, non ripristinato.** Pane B:
   ```bash
   ./emulator/demo/coord-status.sh coord2
   ```
   mostra il claim **dell'auto sul connettore 3** con **lo stesso `claim_id` e
   `granted_at`** di prima (solo `expires_at` è avanzato per via dei rinnovi).
   **Dire:** «Il nuovo leader non eredita un log. Ricostruisce la tabella chiedendo alle
   stazioni, che possiedono i loro connettori. Funziona perché il coordinatore è stato
   progettato come indice — è una scelta, non fortuna. E il `granted_at` è quello
   originale, emesso dal coordinatore di allora: è l'ordinamento che decide chi vince un
   conflitto, e sopravvive al failover intatto.»

   > *(Correzione di A, §0 n.1)* È il claim **del connettore 3**, non del presentatore: la
   > sua sessione sul connettore 1 è un walk-in e un walk-in non ha claim. Se qui vedi
   > `claims=0`, l'auto del connettore 3 ha attaccato senza prenotare prima — rifai il
   > T+3:10 nell'ordine giusto. Il presentatore non può prenotare a questo punto della
   > corsa: è sospeso, ed è il beat precedente ad averlo dimostrato.

### 10.2 Isolare coord2 — il quorum (il climax)
```bash
MSYS_NO_PATHCONV=1 docker network disconnect voltshare_voltshare coord2
```
*(Correzione di A, §0 n.4: **disconnect, non kill**. Lo dice il tuo PROGRESS §7y del 27/08
— «da mettere nella demo al posto di `docker kill`» — ed è il punto: `kill` è un crash,
cioè un nodo che sparisce; il caso difficile, quello per cui il quorum esiste, è il nodo
**vivo** che non vede più gli altri e deve avere il buon senso di smettere di concedere.
Nota anche il nome: la rete è `voltshare_voltshare`, non `voltshare` — verificato l'1/09 e
nel tuo §7y. Un `docker network ls` la mattina della demo toglie ogni dubbio.)*
**Nel Pane A:**
```
coord1: QUORUM LOST (1 of 3) — this coordinator will refuse to serve
coord1: mode=suspended
```
Ora **ogni `reserve` fallisce, ovunque** — ma la sessione a schermo carica ancora.
**Dire:** «La minoranza si sospende da sola. Non è un guasto gestito: è il sistema che si
rifiuta di funzionare quando non può garantire P2. La tentazione naturale — l'ultimo
sopravvissuto prende il comando — è proprio ciò che dopo una partizione produrrebbe due
leader che concedono claim in parallelo. Costo dichiarato: durante una partizione la
minoranza rifiuta le nuove prenotazioni; le ricariche in corso no.»

Poi:
```bash
MSYS_NO_PATHCONV=1 docker network connect voltshare_voltshare coord2
```
→ elezione → `coord2 ... serving`. I `reserve` ripartono.

> ### ⚠ La regola dei dieci secondi *(correzione di A, §0 n.2)*
>
> **Dopo che un coordinatore rientra — riavviato o riconnesso — aspetta ~10 secondi prima
> di fare qualunque `reserve`.** Non è prudenza generica, è **P18**, misurato l'1/09 e
> scritto in `PROBLEMI_TROVATI.md`.
>
> Un coordinatore che rientra si elegge **prima** che le stazioni si siano riconnesse:
> `vs_coord_rebuild:station_nodes/0` è un filtro su `nodes()`, cioè la lista dei suoi
> conoscenti, non l'elenco delle stazioni. Trova zero interlocutori, aspetta la finestra
> di rebuild (`COORD_REBUILD_TIMEOUT_MS`, **2000 ms**) e comincia a servire **con la
> tabella dei claim vuota**. I claim rientrano col ciclo di renew, che è di **10 000 ms**:
> il difetto è il rapporto fra i due numeri. Nella corsa misurata, 272 ms dopo che il
> leader ha cominciato a servire lo stesso veicolo ha ottenuto una **seconda prenotazione**
> su un'altra stazione, e l'invariante P2 è rimasta rotta **13,65 secondi** finché il primo
> renew non ha ripresentato il claim più vecchio.
>
> In scena questo significherebbe rompere P2 **due minuti dopo aver detto che P2 è il
> cuore del progetto**. Dieci secondi di pausa lo evitano, e non si vedono nemmeno: sono
> il tempo di dire la battuta sul quorum.
>
> Vale per §10.2 e §10.3, **non** per §10.1: lì coord2 era vivo e connesso tutto il tempo,
> quindi la sua ricostruzione trova davvero le stazioni. Nel Pane A si legge la differenza:
> `rebuild: 2 stazioni interrogate` contro `asked 0 station node(s)`.
>
> **Stato:** la metà nostra della correzione è in lavorazione (il claim client ripresenta i
> claim appena vede tornare un coordinatore, invece di aspettare il tick — verificato che i
> `nodeup` arrivano: quattro in 271 ms). Accorcia la finestra ma **non la chiude**: perché
> sparisca serve anche la tua metà — *non passare a `serving` con zero risposte **e** zero
> claim finché non è arrivato almeno un renew*. Ne parliamo prima della demo; fino ad
> allora, la regola dei dieci secondi resta.

### 10.3 Il «bully», alla lettera (facoltativo, 20 s)
```bash
docker start coord3
```
Pur essendo coord2 sano, **coord3 si riprende la corona** (rango più alto): nel Pane A
coord2 torna `standby` e svuota la tabella. *«È da qui che l'algoritmo prende il nome: un
nodo che riavviandosi si autoproclama leader anche se ce n'è già uno sano.»*

⚠ **Vale la regola dei dieci secondi del §10.2**: coord3 sta rientrando, quindi si elegge
prima che le stazioni si riconnettano. Guarda il Pane A: se leggi `asked 0 station
node(s)`, stai vedendo dal vivo il presupposto di P18 — e va bene raccontarlo («l'abbiamo
trovato misurando questa stessa manovra, è scritto, si corregge così»), purché nessuno
prema `reserve` in quel momento.

### 10.4 Onestà da mettere nella relazione
Su un host solo `docker kill` è un crash pulito (fail-stop). Una **partizione vera** — nodo
vivo ma irraggiungibile, rilevata dal battito e non da `nodedown` — si ottiene con
`docker network disconnect voltshare_voltshare coordN`: è la forma per cui il quorum
esiste, ed è **quella che il §10.2 usa adesso di default** (correzione di A, §0 n.4). Il
kill resta in §10.1, dove serve proprio il crash: due guasti diversi, due reazioni diverse,
ed è più interessante mostrarli entrambi che sceglierne uno. Il deploy multi-host darebbe la
partizione fisica ma impone `-name` con FQDN su tutti i nodi (`COORD_NODES`,
`JINTERFACE_NODE`) — stretch goal solo se avanza tempo; BlackNet, il progetto di
riferimento, non l'ha fatto.

---

## 11. Fallback e problemi noti

| Sintomo | Causa | Rimedio |
|---|---|---|
| I millisecondi nei report sono assurdi, buchi nel log dei ping | Docker Desktop ha sospeso la VM (pause anche di 20 min a riposo) | tieni i log che scorrono da prima; se è successo, scarta e rifai il beat |
| Una colonnina di sfondo non carica, `unknown_vehicle` | veicolo non seminato | `docker exec -i mysql mysql -uvoltshare -pvoltshare voltshare < deploy/seed-demo.sql` |
| L'elezione «non si vede» nel Pane A | grep troppo stretto o log bufferizzato | `docker compose --env-file .env.demo logs -f coord1 coord2 coord3` senza grep; in parallelo `coord-status.sh` in loop mostra comunque `mode` che cambia |
| `reserve` sempre `SUSPENDED` anche dopo la demo | la sospensione dura 1 giorno | account nuovo dal form, oppure `UPDATE users SET no_show_count=0, suspended_until=NULL WHERE username='andrea';` |
| La nota `reservation_expiring` (T−2min) non appare | con lease 90 s non è armata (serve lease > 2 min) | atteso; dichiararlo, oppure `LEASE_SECONDS=150` in `.env.demo` (attese no-show più lunghe) |
| `session.jsp` vuota dopo lo Stop | il frame `closed` può arrivare più volte, è terminale | è corretto: la pagina rende l'ultimo frame ricevuto |
| Il connettore 1 risulta occupato all'inizio del beat walk-in | P2 ha lasciato lì una prenotazione | assicurati di aver premuto **Cancel** dopo P2 |
| `station2` uccisa non rientra | manca lo `start` | `docker start station2`; le colonnine di sfondo si riagganciano da sole (backoff) |
| La colonnina non stacca, il Ctrl-C sembra ignorato | **misurato l'1/09**: il Ctrl-C a `cp.js` non arriva sempre | non contarci: la durata la decide `--linger`. Se devi proprio chiudere un emulatore, verifica nel **suo** terminale che sia uscito, non presumerlo |
| Un `reserve` passa quando non dovrebbe, subito dopo che un coordinatore è rientrato | **P18**: leader che serve con la tabella vuota (§10.2) | è il difetto noto, non un caso fortuito: aspetta ~10 s dopo ogni rientro. Se è già successo davanti al professore, raccontalo — è scritto in `PROBLEMI_TROVATI.md` con la misura |
| `coord-status.sh` dice `claims=0` al failover | l'auto del connettore 3 ha attaccato **senza prenotare prima** (§0 n.1) | rifai il T+3:10 nell'ordine: `reserve.js` e poi `presenter-cp.sh` |
| Il nome della rete non esiste (`docker network disconnect` fallisce) | il prefisso del progetto compose | `docker network ls`: è `voltshare_voltshare`, non `voltshare` |
| Un connettore diventa `out_of_service` e la lobby ne offre uno di meno | **la sua colonnina non risponde più**. La stazione aspetta 30 s e poi dichiara la presa inutilizzabile, perché dal suo lato un emulatore uscito e un caricatore rotto sono la stessa cosa. La causa più probabile in scena: un Ctrl-C dato a un `presenter-cp.sh` per riprendersi il terminale | `./demo/socket.sh N` — attacca una colonnina vuota e ce la tiene. Il `boot` con stato `available` rimette la presa `free` all'istante (`vs_connector`: "out_of_service ──boots available──▶ free") |
| Una presa si rispegne qualche minuto dopo essere stata riparata | il processo che l'aveva riattaccata è morto a sua volta — tipicamente perché lanciato dentro un `timeout`. **Nessun processo che rappresenta hardware va lanciato a scadenza**: una colonnina sta al muro | `socket.sh` si auto-rilancia proprio per questo. Se hai usato `cp.js` a mano, rilancialo senza `timeout` |
| Idem, **dopo** una ricarica finita bene | fino al 3/09 `cp.js` usciva allo `unplugged`: diceva di essere la colonnina ma viveva quanto l'auto, e ogni sessione completata spegneva la presa | risolto da `--stay`, che `presenter-cp.sh` e `world.sh` passano già. Se lanci `cp.js` a mano per una demo, mettilo |
| Un'auto di sfondo sparisce e non torna | fino al 3/09 `world.sh` lanciava i due `cp.js` e faceva `wait`: se uno moriva, l'altro teneva vivo lo script e il morto non ripartiva mai | risolto — ora ogni auto gira in un ciclo che la rilancia (uscita 2 esclusa: è un errore di configurazione, e rilanciarlo lo nasconderebbe) |
| Nei log compare `'global' … requested disconnect … to prevent overlapping partitions` | `global` risolve una vista incoerente della membership disconnettendo due nodi. Lo provocano i nodi effimeri di `coord-status.sh`, che entrano nel cluster e muoiono subito | innocuo, si riconnettono. Se capita in scena **dillo**: è lo stesso istinto del nostro quorum — rifiutarsi di lavorare con una vista ambigua |

Se qualcosa si impunta a fondo: `docker compose --env-file .env.demo restart stationN`
(oppure `coordN`) e prosegui dai log invece che dalla pagina.

---

## 12. Reset tra una prova e l'altra

Tre livelli, dal più leggero. **Scegli il più leggero che basta**: solo il terzo costa la
ri-registrazione dell'account del presentatore.

Reset completo dei processi, database intatto — è quello da usare fra una prova e l'altra:

```bash
cd src/deploy
docker compose --env-file .env.demo down
docker compose --env-file .env.demo up -d
```

Account, storico e notifiche sopravvivono, perché dal 2/09 MySQL scrive su un volume
nominato (`voltshare_mysql-data`) invece che nel layer del container. Verificato: riga
inserita, `down`, `up -d`, riga ancora lì — e MySQL pronto al primo colpo, senza rifare
l'inizializzazione da sei minuti.

Database vuoto, schema ricreato da `contracts/schema.sql`:

```bash
docker compose --env-file .env.demo down -v      # -v distrugge il volume: NON in T−20
docker compose --env-file .env.demo up -d
docker exec -i mysql mysql -uvoltshare -pvoltshare voltshare < seed-demo.sql
# ri-registra 'andrea' dal form, ri-esporta $PV
```

Il `-v` è ora l'unico modo di perdere i dati, ed è un atto deliberato. **Il primo boot su
volume vuoto ha impiegato oltre sei minuti** su un portatile: se lo lanci a T−20 la demo
comincia in ritardo, e finché la healthcheck non passa stazioni e back office si rifiutano
di partire — sembra tutto rotto mentre il database sta solo nascendo.

Reset veloce senza ricreare il DB (tiene l'account, azzera penalità e prenotazioni):

```bash
docker compose --env-file .env.demo restart station1 station2 coord1 coord2 coord3
docker exec mysql mysql -uvoltshare -pvoltshare voltshare -e \
  "UPDATE users SET no_show_count=0, suspended_until=NULL; DELETE FROM sessions; DELETE FROM notifications;"
```

---

## 13. Cosa non mettiamo in scena, e come rispondere *(aggiunta di A)*

Non è una lista di buchi: sono cose provate altrove, che in scena costerebbero più di
quello che rendono. Averle in tasca con la risposta pronta vale più che mostrarle male.

| Se chiedono… | Risposta |
|---|---|
| la **sospensione per scarsità** (una presa a zero kW) | Coi budget veri non può capitare: 350 diviso 4 fa 87,5 kW e la soglia `MIN_CHARGE_KW` è 6. Mostrarla dal vivo vorrebbe dire truccare i numeri fino all'assurdo. È coperta da un test col budget forzato a 8, e da uno del manager. |
| il **taper** (l'auto sopra l'80% che rallenta) | Servono minuti di carica vera per arrivarci: è coperto dal test del manager che lo fa notare al tick. |
| un **guasto della colonnina** (`faulted`) | L'emulatore non sa fingerlo — manderebbe un frame `status` che non ha. Il percorso c'è ed è testato (§4.1: fuori servizio immediato, sessione chiusa con l'energia misurata); la scena no. |
| la **fine carica per batteria piena** (`target_reached`) | Stessa ragione: portare un'auto al 100 % richiede minuti. È il terzo modo di entrare in `complete`, insieme allo stop e alla revoca, ed è testato. |
| la **scadenza naturale di un claim** (lease + grazia) | Misurata l'1/09: **956,955 s**, e il veicolo si libera per lettura pigra, non per uno scrub periodico. Sedici minuti sono fuori scala per una demo. |
| la **lista d'attesa** | Dichiarata nei contratti (`ws-driver.md` §4.4, il frame `waitlist_offer`) e **non implementata**: era fuori dal perimetro concordato, ed è scritto. |
| **P18** | Trovato l'1/09 misurando la partizione, scheda con i log in `PROBLEMI_TROVATI.md`, correzione in corso su entrambi i lati. È il motivo della pausa di dieci secondi del §10.2. |
| perché non c'è un **deploy multi-host** | La partizione vera si ottiene su un host solo staccando l'interfaccia (§10.4), quindi il multi-host non aggiungeva la proprietà che ci interessava: imponeva `-name` con FQDN su tutti i nodi in cambio di niente. |

---

## Appendice A — `deploy/.env.demo`

```dotenv
# VoltShare — profilo demo.  Uso, da src/deploy/:
#   docker compose --env-file .env.demo build     una volta, la sera prima
#   docker compose --env-file .env.demo up -d     la mattina, in pochi secondi
# "Tempo veloce" = lease e grazie corti; nessun orologio scalato. Dirlo nella relazione.

ERLANG_COOKIE=voltshare
VOLTSHARE_JWT_SECRET=dev-secret-change-me-0123456789ab

# lease della prenotazione + scadenza del claim. 90 s: un no-show "da 15 minuti" in ~1,5 min.
LEASE_SECONDS=90
# quanto sopravvive un claim senza rinnovo dopo la morte di una stazione (beat P4).
CLAIM_GRACE_SECONDS=30

# tolleranza di fine carica prima che il contatore parta sull'overstay.
OVERSTAY_GRACE_SECONDS=20

# ogni quanto il back office prezza le sessioni chiuse: il costo appare ~10 s dopo l'unplug.
BILLING_SWEEP_SECONDS=10

# budget di potenza di Pisa abbassato così il riparto si vede con due auto (richiede la
# riga ${STATION1_SITE_POWER_KW:-350} in docker-compose.yml, servizio station1).
STATION1_SITE_POWER_KW=200

# i tempi dell'elezione sono già rapidi nel compose (battito 1 s, 3 mancati → verdetto ~3 s).
```

---

## Appendice B — `deploy/seed-demo.sql`

```sql
-- VoltShare — seed della demo. Caricare DOPO `docker compose up` (schema.sql gira al
-- primo boot):  docker exec -i mysql mysql -uvoltshare -pvoltshare voltshare < seed-demo.sql
-- Idempotente. Si può rilanciare tra una prova e l'altra.
--
-- `reserve`/`cancel` non toccano MySQL (il claim è per vehicle_id). `plugged` sì: un
-- walk-in per un veicolo sconosciuto è rifiutato. Quindi ogni --vehicle usato da cp.js in
-- world.sh vuole una riga qui. Convenzione: id utente == id veicolo.

USE voltshare;

INSERT IGNORE INTO users (id, username, password_hash) VALUES
  (101,'load101','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (102,'load102','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (103,'load103','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (104,'load104','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (105,'load105','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (106,'load106','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx');

INSERT IGNORE INTO vehicles (id, user_id, battery_kwh, max_kw) VALUES
  (101,101, 60.00, 50),
  (102,102, 40.00, 50),
  (103,103, 75.00,150),
  (104,104, 50.00,150),
  (105,105, 80.00,150),
  (106,106, 55.00, 50);

-- --- OPZIONALE: account presentatore deterministico (così i default 12/88 di cp.js e
--     driver.js "funzionano e basta" su ogni DB nuovo). Serve un hash BCrypt VERO:
--       1. docker compose up; http://localhost:8080/register → 'andrea' / 'demo1234'
--       2. docker exec mysql mysql -uvoltshare -pvoltshare voltshare -N -e \
--            "SELECT password_hash FROM users WHERE username='andrea'"
--       3. incolla qui sotto, togli i commenti: da allora è il login su ogni DB pulito.
-- INSERT IGNORE INTO users (id, username, password_hash) VALUES
--   (12,'andrea','<HASH BCRYPT QUI>');
-- INSERT IGNORE INTO vehicles (id, user_id, battery_kwh, max_kw) VALUES (88,12,60.00,150);
```

> Con l'account presentatore seminato, in §6 salti il passo 3 e usi `PV=88`.

---

## Appendice C — gli script

Tutti in `src/emulator/demo/`. `chmod +x` dopo averli creati. Girano in git-bash
(Node e `docker` sul PATH).

### `world.sh`
```bash
#!/usr/bin/env bash
# VoltShare — il "mondo" di sfondo per la demo: walk-in scaglionati su Livorno, così la
# lobby ha vita mentre il presentatore guida il browser. Ctrl-C ferma tutto.
#   ./world.sh
# Il presentatore possiede Pisa 1/2/4 e Livorno 5; il mondo qui possiede Livorno 6/7.
# L'auto del riparto su Pisa 3 la lancia il co-pilota su cue (presenter-cp.sh 3 103).
set -u
cd "$(dirname "$0")/.."                       # -> src/emulator
S2=ws://localhost:9202/ws/cp

trap 'echo; echo "world: stop"; kill 0 2>/dev/null; wait; exit 0' INT TERM

echo "world: Livorno conn 6 — veicolo 101"
node cp.js --url $S2 --station 2 --connector 6 --vehicle 101 --soc 30 --battery 60 --max-kw 50 --quiet &
sleep 20
echo "world: Livorno conn 7 — veicolo 102"
node cp.js --url $S2 --station 2 --connector 7 --vehicle 102 --soc 55 --battery 40 --max-kw 50 --quiet &

echo "world: in corsa. Ctrl-C per fermare."
wait
```

### `presenter-cp.sh`
```bash
#!/usr/bin/env bash
# Helper del co-pilota: una colonnina per un'azione del presentatore.
#   ./presenter-cp.sh <connettore> [<veicolo>] [altri argomenti di cp.js...]
# Esempi:
#   ./presenter-cp.sh 1 "$PV" --soc 45 --battery 60 --max-kw 150 --linger 150
#       carica su Pisa 1; dopo lo Stop tiene il cavo dentro 150 s -> è l'overstay.
#   ./presenter-cp.sh 3 103 --soc 40 --battery 75 --max-kw 150
#       la "seconda auto" che fa calare l'allocazione del presentatore su conn 1.
set -u
cd "$(dirname "$0")/.."                       # -> src/emulator
conn=${1:?connettore richiesto}; veh=${2:-88}
shift $(( $# > 1 ? 2 : 1 ))
port=9201; st=1
case "$conn" in 5|6|7) port=9202; st=2;; esac
exec node cp.js --url ws://localhost:$port/ws/cp --station $st --connector "$conn" \
                --vehicle "$veh" "$@"
```

### `coord-logs.sh`
```bash
#!/usr/bin/env bash
# L'unico pannello che rende visibile la storia del coordinatore.
cd "$(dirname "$0")/../../deploy"
exec docker compose --env-file .env.demo logs -f --tail=0 coord1 coord2 coord3 \
  | grep --line-buffered -Ei 'election|rebuild|quorum|leader|serving|standby|nodedown|went down'
```

### `coord-status.sh`
```bash
#!/usr/bin/env bash
# mode + numero di claim di un coordinatore.  ./coord-status.sh coord2
node=${1:-coord1}
echo 'io:format("~p  mode=~p  claims=~p~n",[node(),vs_coord_srv:mode(),(catch length(vs_coord_srv:claims()))]).' \
 | timeout 6 docker exec -i "$node" erl -sname "probe$RANDOM" -setcookie voltshare \
     -remsh "vs@$node" -hidden 2>/dev/null
```

### `p2.sh`
```bash
#!/usr/bin/env bash
# P2 come one-shot, se le due tab dal vivo sono scomode: un veicolo corre su due stazioni.
# Una reserve vince, il resto NO_CLAIM.
cd "$(dirname "$0")/.."                       # -> src/emulator
exec node driver.js --scenario one-vehicle \
     --url  ws://localhost:9101/ws/driver --url2 ws://localhost:9102/ws/driver \
     --connectors "1" --connectors2 "5" --first-user 104 --first-vehicle 104
```

> Nota di A: `--scenario one-vehicle` **cancella la prenotazione sopravvissuta** in fondo
> alla corsa (`cancelling the surviving reservation…`). Per `p2.sh` va benissimo — anzi,
> lascia il campo pulito — ma è il motivo per cui **non** si può usare per lasciare in
> piedi una prenotazione: per quello serve `reserve.js` qui sotto.

### `reserve.js` — *(nuovo, di A)*

Client minimo del canale driver: apre il socket, fa `join` con un JWT firmato col segreto
di sviluppo di `contracts/sample-tokens.md`, esegue **una** azione e chiude. È lo strumento
con cui ho preso le misure dell'1/09; oggi sta nella mia root come
`scena-pixel-driver.js` e va copiato in `src/emulator/demo/reserve.js`.

```bash
# far prenotare un veicolo seminato e lasciare la prenotazione in piedi
node demo/reserve.js --station 1 --connector 3 --user 103 --vehicle 103 --action reserve

# --action  reserve | cancel_reservation | none   ('none' ascolta e basta: utile per
#           guardare i frame `state` senza toccare nulla)
# --url     default ws://localhost:9101/ws/driver   (9102 per la stazione 2)
```

La prenotazione **sopravvive alla chiusura del socket**: vive nel processo del connettore,
non nella pagina (`ws-driver.md` §7.5). È esattamente ciò che serve al T+3:10.

---

## Appendice D — checklist di prova (fare almeno un giro completo)

**I due segnati 🔴 sono quelli che non hanno ancora una prova con gli occhi** (colonna
«già visto» del §2): se saltasse solo la prova generale, sono questi due a dover girare
almeno una volta.

- [ ] `.env.demo`, `seed-demo.sql`, gli **9** script creati e `chmod +x` (`world.sh`,
      `presenter-cp.sh`, `logs.sh`, `coord-logs.sh`, `coord-status.sh`, `unsuspend.sh`,
      `socket.sh`, `p2.sh`, `reserve.js`); la riga `${STATION1_SITE_POWER_KW:-350}` in
      `docker-compose.yml`.
- [ ] `logs.sh` mostra `claim GRANTED` e `claim REFUSED` da un coordinatore durante P2.
      Se non compaiono, l'immagine dei coordinatori è precedente al 3/09: `build coord1`
      e `up -d coord1 coord2 coord3` (i tre condividono l'immagine, quindi si costruisce
      una volta sola).
- [ ] dopo una ricarica **finita**, il connettore torna `free` e non `out_of_service`:
      è la verifica che `--stay` sia in `presenter-cp.sh`.
- [ ] **immagini costruite la sera prima** (`build`, non `up -d --build`), così la mattina
      il passo 1 dura secondi.
- [ ] `docker volume ls` mostra `voltshare_mysql-data`: senza quello un `down` cancella
      l'account del presentatore, e il boot successivo rifà l'inizializzazione (>6 min).
- [ ] `up` pulito, 7 container, coord3 leader nei log; `docker network ls` mostra
      `voltshare_voltshare`.
- [ ] `world.sh`: Livorno 6 e 7 vanno `charging` in lobby entro ~30 s.
- [ ] P2 dal vivo: una `reserve` vince, l'altra `NO_CLAIM`. Cancel funziona.
- [ ] 🔴 no-show: con lease 90 s, `reservation_expired` compare ~90 s dopo; due di fila →
      `notifications.jsp` con «1 of 2» e «2 of 2»; `reserve` → `SUSPENDED`; **e il Profilo
      mostra la sospensione con la scadenza**. (Meccanismo misurato al database il 31/08;
      queste sono le pagine, mai viste.)
- [ ] walk-in su conn 1 da sospeso: **autorizzato** (SCOPE §3.3).
- [ ] 🔴 conn 3 **prenota e poi attacca**; su `session.jsp` i kW di conn 1 calano
      visibilmente (~150 → ~100). Se provi la variante col travaso, i tre numeri devono
      essere **75 · 75 · 50**.
- [ ] **prima del failover**, `coord-status.sh` sul leader mostra **almeno un claim** —
      quello del connettore 3. Se dice `claims=0`, il beat §10.1 non ha niente da mostrare
      (§0 n.1).
- [ ] `kill coord3`: elezione nei log in ~3 s; `session.jsp` non trema; `coord-status.sh
      coord2` mostra lo stesso `claim_id`; nel Pane A si legge `rebuild: 2 stazioni
      interrogate` (**non** `asked 0 station node(s)`).
- [ ] `network disconnect coord2`: `QUORUM LOST`, `reserve` fallisce ovunque, carica
      continua; `network connect coord2` → `serving`. **Cronometra i dieci secondi** prima
      del `reserve` successivo (§10.2) e guarda che riga stampa il rebuild.
- [ ] Stop su conn 1 → `complete` **subito** e potenza restituita → `overstay` dopo 20 s →
      riga `overstay_started` in `notifications.jsp` → il `--linger` stacca da solo →
      `history.jsp` con l'addebito entro ~10 s, **40 secondi fatturabili** (60 − 20).
- [ ] `./src/scripts/eunit_check.sh` verde, e il numero che stampa è quello che dirai.
- [ ] cronometrare l'intera corsa: deve stare in 8–10 min. **È il controllo che salta più
      spesso ed è quello che costa di più saltare.**
```
