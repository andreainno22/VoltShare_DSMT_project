# Scelte di progetto — deployment

Decisioni su come il sistema viene impacchettato ed eseguito, con motivazione e alternative scartate. Materiale per l'orale; la versione inglese confluisce nella relazione.

---

## 1. Un container per nodo

**Perché**: il requisito è "un processo per nodo, nodi su host distinti" (SCOPE §6). I container danno isolamento di rete e di nome host, che è ciò che serve per dimostrare la distribuzione: `docker kill coord-leader` è un guasto reale di un nodo, non la simulazione di un guasto. È anche l'unico modo pratico di far girare sette nodi sul portatile di uno studente.

*Perché non nodi Erlang multipli sullo stesso host con `-sname` diversi?* Funziona in sviluppo, ed è il modo in cui si prova l'elezione velocemente, ma non dimostra nulla sull'isolamento: condividono filesystem, rete e sorte. Restano lo strumento di sviluppo (README di `erlang/`), non il deployment.

## 2. Una sola immagine Erlang per stazione e coordinatore

`Dockerfile.erlang` costruisce tutte le applicazioni; il ruolo lo decide la variabile `ERL_APP`.

**Perché**: le due applicazioni condividono `vs_common` e la stessa toolchain. Due Dockerfile quasi identici sarebbero due file da tenere allineati, e il layer di build (che è la parte lenta) verrebbe pagato due volte. Il costo è un'immagine leggermente più grande del necessario per ciascun ruolo — irrilevante qui.

## 3. Build multi-stadio

Stadio 1 con la toolchain rebar3, stadio 2 con solo i `.beam` compilati.

**Perché**: l'immagine finale non contiene i sorgenti né il compilatore. È l'abitudine corretta e costa due righe; in più rende evidente che il nodo esegue codice compilato, non uno script.

## 3.1 Versione di OTP fissata, e fissata *uguale* a quella di sviluppo

`Dockerfile.erlang` usa `erlang:29.0.5` (Debian), non `erlang:latest` e nemmeno il tag mobile `erlang:29-alpine`: quest'ultimo segue le patch release, quindi due `docker build` a settimane di distanza potrebbero produrre runtime diversi senza che nessuno abbia toccato niente. Il pin alla patch rende la build riproducibile; l'aggiornamento di versione diventa un commit visibile, non un evento silenzioso.

*Perché Debian e non alpine?* Non per scelta: la build ufficiale alpine/amd64 è ferma a 29.0.2, e il tag `29.0.5-alpine` pubblica solo varianti 386/arm — su un host amd64 Docker ripiega **in silenzio** sulla 386, e i container finiscono a girare un Erlang a 32 bit. Scoperto da un `WARN InvalidBaseImagePlatform` durante un build: l'unico sintomo di un runtime diverso da quello di sviluppo. L'immagine Debian è l'unica che dà insieme la versione esatta pinnata e l'architettura nativa; il costo è qualche centinaio di MB di immagine, irrilevante qui. Nota di metodo per la relazione: il tag di un'immagine promette la versione del software, non l'architettura — le due cose vanno verificate separatamente (`docker image inspect --format '{{.Architecture}}'`).

**Perché fissarla**: un tag mobile cambia sotto i piedi. Una rebuild il giorno della consegna, con una major nuova nel frattempo, sposta il debug dal progetto alla toolchain nel momento peggiore.

**Perché allinearla allo sviluppo**: `rebar.config` ha `warnings_as_errors`, quindi ogni warning nuovo introdotto da un compilatore più recente è un build che fallisce. Con versioni diverse fra macchina e container il fallimento è *asimmetrico* — compila di là e non di qua — e sembra un problema di Docker quando è un problema di codice.

È successo davvero: il progetto era partito su OTP 26 nell'immagine mentre la macchina aveva OTP 29. Allineando l'immagine a 29 è emerso subito che `vs_connector` usava la forma `catch Expr`, deprecata da OTP 29. Il disallineamento non aveva creato il difetto, l'aveva solo nascosto: `warnings_as_errors` ha fatto il suo mestiere appena le due versioni hanno smesso di divergere.

*Perché non allineare al contrario, riportando lo sviluppo a 26?* Perché avrebbe congelato il progetto su una versione del 2023 per non toccare una riga di codice deprecato — e la riga andava riscritta comunque.

## 4. `start-node.sh` invece di una release OTP (`relx`)

**Perché**: una release è la forma giusta per la produzione (VM inclusa, hot upgrade, `bin/app start`), ma introduce `vm.args`, `sys.config` e i profili di rilascio in un momento in cui il rischio da abbattere è un altro: far parlare due nodi. Uno script che invoca `erl` con `-sname`, `-setcookie` e `-pa` rende visibile in tre righe *esattamente* come il nodo viene battezzato — che è il punto in cui le cose si rompono davvero.

Da rivedere in M5 se il deploy su più host mostra che serve.

## 5. Cookie e segreti come variabili d'ambiente con default di sviluppo

`ERLANG_COOKIE`, `VOLTSHARE_JWT_SECRET` hanno un default nel compose (`voltshare`, `dev-secret-change-me`) sovrascrivibile da `.env`.

**Perché**: il cookie Erlang *è* il meccanismo di autenticazione fra nodi — nodi con cookie diversi non si parlano, ed è la prima causa di "non si vedono" durante il setup. Averlo esplicito e uguale in un posto solo elimina la classe di errore. I default servono perché il progetto deve poter essere clonato ed eseguito senza configurazione, come dovrà fare il docente.

*Perché non un secret manager?* Fuori scope: nessuna delle problematiche di sicurezza affrontate dal corso passa da lì, e sarebbe un nodo in più.

## 6. `schema.sql` montato da `contracts/`, non copiato in `deploy/`

**Perché**: lo schema è un contratto condiviso — la tabella delle proprietà di scrittura sta lì dentro. Copiarlo nella cartella di deploy creerebbe due copie destinate a divergere, e la divergenza si scoprirebbe con un `INSERT` che fallisce alla demo. Una sola copia, montata in sola lettura.

## 7. Porte: 8080/8081 dentro il container, 9101/9201 sull'host

**Perché**: dentro il container ogni stazione usa le stesse porte, così la configurazione dell'applicazione non dipende da quale stazione è. La rimappatura per stazione avviene solo all'esterno, dove serve perché l'host ha una sola porta 8080. Il browser riceve comunque l'URL da `stations.ws_url`, mai costruito lato client: la topologia resta un dato, non una convenzione sparsa nel codice.

## 8. `depends_on` con `condition: service_healthy` su MySQL

**Perché**: `depends_on` semplice garantisce solo l'ordine di avvio, non che MySQL accetti connessioni — il caso classico in cui il primo `docker compose up` fallisce e il secondo funziona, cioè un guasto non riproducibile che fa perdere ore. L'healthcheck lo rende deterministico.

Nota per l'orale: è una dipendenza di *avvio*, non un accoppiamento a runtime. Una stazione che perde MySQL continua a caricare e scrive la sessione al ritorno del database; la scrittura è a fine sessione proprio per non avere il database sul percorso critico.

## 9. Coordinatori e back office dichiarati ma commentati

**Perché**: la M0 deve poter girare mentre la parte B non esiste ancora — è la regola "nessuno aspetta l'altro". Le definizioni ci sono già, con nomi nodo e variabili corretti, così quando `vs_coord` compila si scommenta invece di progettare. Evita anche che i due sviluppatori scrivano due compose incompatibili.

## 10. Il probe M0 fra le due stazioni

In M0 `station1` e `station2` si pingano a vicenda; in M1 il ping è sostituito dal claim verso i coordinatori.

**Perché**: servono due nodi che si parlino, e i due nodi che esistono già sono le stazioni. Fa emergere subito i tre problemi veri del deployment distribuito — risoluzione dei nomi fra container, cookie condiviso, EPMD raggiungibile — senza dipendere da codice che deve ancora essere scritto.
