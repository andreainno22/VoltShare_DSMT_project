---
name: voltshare-doc
description: Scrivere o aggiornare la documentazione d'esame di VoltShare (progetto DSMT, Unipi) in LaTeX. Contiene l'indice concordato, la mappa delle fonti interne, i fatti verificati e le trappole da non ripetere. Usare per qualsiasi lavoro sul documento consegnabile del progetto.
---

# Documentazione d'esame di VoltShare

**Come si scrive** sta nella skill `tech-report-latex`: caricala per prima e seguila. Questa
skill dice **cosa** scrivere, da dove prenderlo, e cosa non sbagliare.

## Il vincolo d'esame

Il documento accompagna un sistema distribuito funzionante e viene letto prima dell'orale.
Dal regolamento del corso, i punti che il documento deve dimostrare:

- **è in inglese**;
- identifica esplicitamente i problemi di **sincronizzazione, coordinazione e
  comunicazione**, e per ciascuno dice come è risolto (è la parte che pesa di più);
- giustifica il **middleware**: perché le sole socket TCP non bastavano;
- mostra il deploy su **più nodi**;
- dichiara le **alternative scartate** con il motivo, per ogni scelta tecnica non ovvia.

Il modello di riferimento è la documentazione di
[BlackNet](https://github.com/effemuraca/dsmt-blacknet), progetto dello stesso corso valutato
30 e lode: 19 pagine, un indice che si può ricostruire (in `references/outline.md`), e per
ogni decisione l'alternativa scartata. Il nostro indice è il loro, esteso dove il nostro
sistema fa di più.

**Obiettivo di lunghezza: 25-35 pagine.** Sopra BlackNet perché il sistema ha più parti,
non perché si scrive di più.

## Da dove vengono i fatti

Nessuna sezione si scrive a memoria. La mappa completa sta in `references/sources.md`; in
sintesi:

| Fonte | Cosa contiene |
|---|---|
| `src/SCOPE.md` | requisiti, attori, problemi P1-P7, confine del sistema, decisione su P2 |
| `src/DESIGN-NOTES.md` | il perché di ogni scelta, alternative scartate, fault tolerance, limiti ammessi, mappatura al programma del corso |
| `src/DEMO.md` | scenari dimostrativi con i comandi e gli output reali |
| `src/contracts/*.md` | protocolli: `ws-driver`, `ws-chargepoint`, `claim`, `jwt`, `erlang-java` |
| `src/erlang/scelte_di_progetto.md` | decisioni sul codice Erlang |
| `src/deploy/` | `docker-compose.yml`, `.env.demo`, Dockerfile: il deploy reale |
| `src/erlang/apps/` | `vs_coord`, `vs_station`, `vs_common`, `vs_mock_coord`: il codice |
| `src/PROGRESS.md` | diario di lavoro, misure datate, cose provate e scartate |

**I documenti sorgente sono note di lavoro, non bozze del documento.** Sono in italiano
misto a inglese, pieni di em dash, e in alcuni punti descrivono intenzioni invece di fatti.
Si traducono e si riscrivono, non si incollano. Prima di riportare un fatto tecnico, apri il
codice che lo implementa.

## Le trappole

Errori che il materiale sorgente induce a fare, ciascuno già costato una correzione:

1. **Nodi, non host.** Il deploy è su **una macchina sola**, con sette nodi in container. Non
   scrivere mai "deployed on multiple hosts". Il requisito parla di nodi, e BlackNet ha fatto
   lo stesso. La partizione di rete si ottiene con `docker network disconnect`, non con due
   macchine.
2. **Crash e partizione sono due guasti diversi.** `docker kill` è un crash, `docker network
   disconnect` è una partizione. Hanno rilevatori diversi (`nodedown` contro heartbeat) e
   conseguenze diverse. Confonderli è l'errore più visibile all'orale.
3. **Le sessioni in corso su una stazione che muore sono perse.** Non c'è recovery della
   sessione. Quello che si recupera al riavvio è la *misura*, perché il contatore sta nel
   charge point e la rimanda nel `plugged` alla riconnessione. Non promettere di più.
4. **Non c'è log replicato.** Il nuovo leader ricostruisce la claim table interrogando le
   stazioni. È una semplificazione deliberata, con un costo dichiarato: qualche secondo di
   indisponibilità delle nuove prenotazioni.
5. **Non copiare la sezione Mnesia di BlackNet.** La loro documentazione descrive
   un'integrazione Mnesia che nel repo pubblico non esiste. Noi non usiamo Mnesia.
6. **Un solo addebito.** L'overstay costa; il no-show no, si paga con la sospensione. Se il
   documento accenna a una penale in denaro per il no-show, contraddice §3.6 dello SCOPE.
7. **Niente numeri inventati.** Le misure vanno prese da `PROGRESS.md` o da `DEMO.md`, con
   la data e le condizioni. Se una misura non c'è, si scrive che non è stata fatta.

## Glossario: un concetto, un nome

Da usare in modo rigido per tutto il documento. La collisione tra questi termini è la prima
causa di confusione per chi legge.

| Termine | Significato, e cosa non è |
|---|---|
| **connector** | la presa fisica, risorsa esclusiva del sistema. Non "outlet", non "socket" |
| **charge point** (EVSE) | l'apparecchiatura che governa i connettori e conta l'energia. È un *peer* del sistema, non un utente |
| **station** | il sito fisico con N connettori e una potenza massima, e il nodo Erlang che lo governa |
| **reservation** | ciò che vede il driver: quel connettore, tenuto per lui fino a quell'ora. Locale alla stazione |
| **claim** | il permesso rilasciato dal coordinatore: *quel veicolo* è impegnato, e presso quale stazione. Vale su tutta la rete |
| **lease** | la scadenza automatica che accompagna reservation e claim |
| **coordinator** | uno dei tre nodi Erlang del cluster di coordinamento |
| **leader** | il coordinatore che in questo momento serve le richieste. Gli altri due non sono "backup": sono coordinatori in stand-by |
| **back office** | il nodo Java/Tomcat: front end web, autenticazione, storico, billing |
| **driver** | l'utente umano registrato |

Reservation e claim sono le due metà dello stesso atto e vanno tenute distinte in ogni
frase: la stazione ottiene il claim **prima** di confermare la reservation, mai il
contrario.

## Ordine di lavoro

1. Leggi `references/outline.md`: indice, budget per sezione, cosa va in ciascuna.
2. Per la sezione da scrivere, raccogli i fatti dalle fonti indicate lì, con `file:riga`.
3. Verifica sul codice i fatti tecnici (moduli in `src/erlang/apps/`, deploy in
   `src/deploy/`).
4. Scrivi la sezione seguendo `tech-report-latex`.
5. Passa il linter:
   `python .claude/skills/tech-report-latex/scripts/style-lint.py doc/sections/NN-*.tex`
6. Compila: `latexmk -pdf -interaction=nonstopmode -halt-on-error doc/main.tex`
7. Aggiorna `src/PROGRESS.md` con quello che è stato scritto.

## Dove vivono i file

Il documento sta in `src/doc/`, con `main.tex` e una sezione per file in `src/doc/sections/`.
Gli ausiliari di LaTeX (`.aux`, `.log`, `.out`, `.toc`, `.fls`, `.fdb_latexmk`) vanno
ignorati da git, il PDF finale no: si consegna.
