# Indice del documento, con budget e contenuti

Dodici sezioni, 25-35 pagine più frontespizio e indice. La spina dorsale è quella di
BlackNet; le differenze sono dove il nostro sistema fa cose che il loro non faceva.

## L'indice di BlackNet, per confronto

Estratto dal PDF consegnato (`DSMT_BlackNet__Project_Documentation.pdf`, 19 pagine):

```
1  Introduction
2  Requirements Specification        2.1 Functional  2.2 Non-Functional
3  Game Rules
4  System Architecture               4.1 Key Design Decisions (4 sottosezioni)
                                     4.2 Architectural Components (5 nodi)
5  Synchronization and Coordination Problems
6  Architecture Protocols            6.1 Client-Facing  6.2 Internal
7  Addressing Problems               7.1 Race Conditions: Pessimistic Locking
                                     7.2 Message Ordering: The Actor Model
                                     7.3 Fault Tolerance: The Recovery Log
8  API & Protocols Specification     8.1 REST API  8.2 WebSocket Protocol
9  Mnesia Integration
10 Future Works
```

Due cose da imparare da quella struttura, al di là dei titoli. La prima: §5 elenca i
problemi e §7 li risolve, separati. Elencare e risolvere nella stessa sezione confonde il
lettore su cosa sia difficile e cosa sia la soluzione. La seconda: §4.1 esiste come sezione
propria, con l'alternativa scartata per ogni scelta.

## Il nostro indice

| # | Sezione | Pagine | Fonte principale |
|---|---|---|---|
| 1 | Introduction | 1.5 | SCOPE §1 |
| 2 | Requirements Specification | 2.5 | SCOPE §3, §4 |
| 3 | Domain Rules | 1.5 | SCOPE §3.3, §3.4, §3.5, §3.6 |
| 4 | System Architecture | 5 | SCOPE §6, DESIGN-NOTES §1-2 |
| 5 | Synchronization and Coordination Problems | 2.5 | SCOPE §5 |
| 6 | Architecture Protocols | 1.5 | SCOPE §6, contracts/ |
| 7 | Addressing Problems | 5 | SCOPE §9, DESIGN-NOTES §3-4 |
| 8 | Fault Tolerance and Recovery | 4 | DESIGN-NOTES §4c |
| 9 | API & Protocols Specification | 4 | contracts/*.md |
| 10 | Deployment | 2 | deploy/, DEMO.md |
| 11 | Testing and Demonstration | 2 | DEMO.md, scripts/ |
| 12 | Future Works | 1 | SCOPE §10, DESIGN-NOTES §7 |

Totale ≈ 32,5 pagine. Il posto della loro §9 Mnesia lo prende la nostra §8, che è la parte
in cui il progetto ha più da dire.

---

## 1. Introduction

Cosa fa il sistema, per chi, e quali problemi distribuiti risolve. BlackNet chiude
l'introduzione con tre problemi in elenco: è una buona mossa, va rifatta con i nostri (che
sono più di tre, quindi si sceglie).

Deve rispondere entro la prima pagina: perché questo dominio ha contesa vera. La risposta è
in DESIGN-NOTES §1: il connettore è una risorsa fisicamente esclusiva, occupata a lungo, e i
driver sono agenti autonomi che l'operatore può solo arbitrare.

Da non fare: raccontare la storia della mobilità elettrica. Il lettore vuole sapere cosa c'è
da coordinare.

## 2. Requirements Specification

**2.1 Functional** e **2.2 Non-Functional**, come BlackNet. I funzionali stanno in SCOPE §3
e sono già scritti in una forma vicina a quella finale; i non funzionali in SCOPE §4.

Qui gli elenchi sono legittimi: è materiale davvero enumerabile.

## 3. Domain Rules

L'equivalente delle loro "Game Rules": le regole che il sistema fa rispettare e che il
lettore deve conoscere per capire le sezioni successive. Prenotazione con lease, no-show e
sospensione, autorizzazione della sessione, overstay e periodo di grazia, ripartizione della
potenza, tariffazione.

Va scritta prima dell'architettura e tenuta corta: sono regole, non discussione.

## 4. System Architecture

**4.1 Key Design Decisions** (3 pagine). Una sottosezione per decisione, e ognuna con:
scelta, meccanismo, alternativa scartata, motivo. Le decisioni da trattare:

- server-side rendering con servlet e JSP invece di una SPA (SCOPE §6, "Why server-side
  rendering");
- perché il middleware, cioè perché non bastano le socket TCP: distributed Erlang per il
  cluster, JInterface per il ponte Java-Erlang, WebSocket verso i client. È un requisito
  esplicito del corso e va argomentato, non dato per scontato;
- separazione fra coordinatori e stazioni, e perché il site controller sta alla stazione
  (SCOPE §6: deve continuare a erogare mentre è isolato);
- stato volatile in memoria Erlang contro stato durevole in MySQL;
- emulatore del charge point con un sottoinsieme di OCPP 1.6-J, e perché il confine passa
  di lì (SCOPE §7).

**4.2 Architectural Components** (2 pagine). I sette nodi, uno per sottosezione o una voce
per nodo in tabella: back office Java/Tomcat, tre coordinatori Erlang/OTP, due station
controller Erlang/OTP + Cowboy, MySQL. Per ciascuno: tecnologia, responsabilità,
comportamento a runtime.

Qui va la **figura di deployment**, la più importante del documento: i nodi, le reti, i
protocolli sugli archi.

## 5. Synchronization and Coordination Problems

Solo i problemi, nessuna soluzione: le soluzioni sono in §7 e §8. La tabella P1-P7 di
SCOPE §5 è già la struttura giusta, ma in LaTeX conviene un paragrafo per problema, perché
la tabella comprime troppo un contenuto che vale mezzo esame.

Per ciascuno: dove nasce, perché è difficile, cosa succederebbe senza soluzione. La
distinzione fra problemi **dentro una stazione** (P1, P5, P6) e problemi **fra nodi** (P2,
P2b, P4) è la cosa da far vedere.

Chiudere con i problemi di comunicazione: componenti eterogenei che devono scambiare dati
strutturati, connessioni durature a bassa latenza verso molti client, propagazione
asincrona dello stato senza polling.

## 6. Architecture Protocols

Panoramica, non specifica: quale protocollo su quale arco e perché quello. HTTP browser ↔
back office, WebSocket browser ↔ stazione, WebSocket/JSON charge point ↔ stazione,
distributed Erlang stazione ↔ coordinatore, JInterface back office ↔ coordinatore, SQL verso
MySQL.

BlackNet separa "client-facing" e "internal": conviene fare uguale. La specifica dei
messaggi è §9.

## 7. Addressing Problems

Il cuore del documento insieme a §8. Una sottosezione per meccanismo, ciascuna agganciata ai
problemi di §5:

**7.1 Mutual exclusion on a connector (P1).** Un processo `gen_statem` per connettore; le
richieste concorrenti sono serializzate dalla mailbox. Actor model, nessun lock. Dire
esplicitamente che questo è ciò che rende superflua la sincronizzazione esplicita.

**7.2 One reservation per vehicle, network-wide (P2).** Il claim al coordinatore prima del
commit locale. Perché in quest'ordine e non nell'altro: un guasto nel mezzo lascia un claim
inutilizzato che scade, invece di una prenotazione che nessuno conosce. Le quattro
alternative scartate sono già scritte in SCOPE §9 e sono materiale di prima qualità:
coordinatore singolo, vincolo UNIQUE sul database, Ricart-Agrawala, partizionamento dello
spazio dei veicoli.

**7.3 Leases (P3, P7).** Prenotazione e claim scadono da soli. Collegare esplicitamente al
leasing visto a lezione (PDF 06, distributed GC). Qui va anche l'at-most-once con request
id.

**7.4 Coordinator replication: election and quorum (P2b).** Bully sugli identificatori di
nodo, quorum di maggioranza contro lo split brain, ricostruzione della claim table dopo il
failover. L'assunzione di sistema **sincrono** va dichiarata: la detection per timeout è
corretta solo sotto quell'ipotesi.

**7.5 Power allocation (P5).** Risorsa divisibile assegnata a quote e rinegoziata a ogni
evento. Il contrasto con §7.1 è il punto interessante: mutua esclusione contro permessi, due
problemi che a lezione sono due capitoli diversi e qui convivono nello stesso nodo.

## 8. Fault Tolerance and Recovery

Sostituisce la loro sezione Mnesia. Materiale in DESIGN-NOTES §4c, che è già organizzato
bene.

- **Modello di guasto**: cosa può fallire e cosa si assume non fallisca.
- **Due rilevatori, perché ci sono due guasti**: `nodedown` per il crash, heartbeat
  esplicito per la partizione. Il numero da citare è il `net_ticktime` di default a 60
  secondi contro i 3 secondi dell'heartbeat (1 al secondo, 3 mancati tollerati). Questo è
  il genere di dettaglio che rende credibile il documento.
- **Una stazione isolata continua a erogare** mentre l'operatore la perde di vista, con la
  misura reale: energia che sale dentro la stazione isolata mentre il coordinatore la dà
  per non responsiva. Citare data e condizioni. Citare anche il limite scoperto nello stesso
  esperimento: la stazione isolata finisce ciò che ha iniziato ma non può iniziare nulla di
  nuovo, perché autorizzare significa risolvere veicolo → proprietario in MySQL.
- **Una stazione muore**: il coordinatore libera i suoi claim, i driver possono prenotare
  altrove; le sessioni in corso sono perse.
- **Un charge point muore**: grazia, poi onestà.
- **Supervisione dentro il nodo**: tre strategie e il motivo di ciascuna.
- **Tre garanzie di consegna sullo stesso filo**, volute.
- **Cosa non tollera niente, ed è dichiarato.**

## 9. API & Protocols Specification

Specifica vera, dai file in `src/contracts/`. Per ogni canale una tabella di messaggi:
nome, direzione, payload, effetto, errori. La tabella batte il listato: sta in meno spazio e
si consulta.

- **9.1 HTTP endpoints del back office** (form POST e pagine renderizzate), con la nota su
  JWT: `contracts/jwt.md`.
- **9.2 WebSocket driver ↔ stazione**: `contracts/ws-driver.md`.
- **9.3 WebSocket charge point ↔ stazione**: `contracts/ws-chargepoint.md`, dichiarando
  quali messaggi OCPP 1.6-J sono implementati e quali no.
- **9.4 Claim protocol stazione ↔ coordinatore**: `contracts/claim.md`.
- **9.5 Bridge JInterface**: `contracts/erlang-java.md`.

Una **figura di sequenza** per il caso che vale di più: prenotazione con claim, incluso il
caso in cui il claim viene rifiutato.

## 10. Deployment

Sette nodi, i container, le reti, come si avvia. Dal `docker-compose.yml` reale, non dalla
memoria. Il punto delicato è §"nodi, non host" della skill: qui si dice con precisione che
il deploy è su una macchina, che i nodi sono sette, e che la partizione si produce
staccando una rete.

Includere le due reti per stazione, che esistono proprio per rendere dimostrabile la
partizione di un sito.

## 11. Testing and Demonstration

Cosa è testato automaticamente (EUnit, `scripts/eunit_check.sh`) e cosa si mostra dal vivo.
Gli scenari sono in DEMO.md: contesa su un connettore, claim fra nodi, no-show, potenza
ripartita in tempo reale, failover del coordinatore, crash di una stazione, partizione di
una stazione.

Per ogni scenario: cosa si vede sullo schermo e quale problema di §5 dimostra. Il collegamento
scenario → problema è ciò che trasforma una demo in una prova.

## 12. Future Works

SCOPE §10 e DESIGN-NOTES §7: potenza condivisa fra stazioni sullo stesso allaccio,
partizionamento dello spazio dei veicoli fra coordinatori, dashboard operatore, notifiche
push native. Corta e onesta: sono cose non fatte, non promesse.
