# Cosa dice la relazione, cosa pesa, cosa si può tagliare — 5 settembre

Stato: **39 pagine** (37 di corpo, più frontespizio e indice), tutte le dodici sezioni
scritte, nessun segnaposto. Tetto concordato: **35**. Da togliere: **almeno 4 pagine**.

Le stime di resa sono in pagine, a ~450 parole per pagina di prosa; una tabella vale
0,25–0,4, una figura 0,6–0,8. Le righe con **A** sono di A, con **B** di B.

## Il principio

Il documento viene valutato su tre cose (skill `voltshare-doc`, regolamento del corso):
i problemi di sincronizzazione/coordinazione/comunicazione **e come sono risolti** (§5,
§7, §8), la **giustificazione del middleware** (§4.1, §6), le **alternative scartate**
(§4.1, §7.2, i blocchi *Decisions* di §9). Tutto il resto è contesto: serve, ma è lì
che si taglia.

Regola pratica: dove la stessa cosa è detta due volte, resta la copia nella sezione che
viene valutata e sparisce l'altra.

## Sezione per sezione

| § | pp. | Cosa dice | Peso | Cosa si può togliere | Resa |
|---|---|---|---|---|---|
| 1 Introduction (B) | 1,5 | perché il dominio ha contesa vera; i quattro problemi; confine reale/emulato; nota sui numeri | medio: prepara il lettore, non è valutata | **§1.3 «What is built and what is emulated»** è detto uguale in §4.1.5 e nel confine di §2: via. **§1.4 «A note on the numbers»**: due righe bastano | −0,45 |
| 2 Requirements (A) | 2 | attori, funzionali, non funzionali con `\cref` a chi li soddisfa, i tre requisiti *non* consegnati | medio-alto: il paragrafo sul non consegnato è onestà che il docente premia | la lista funzionale si può stringere di un terzo (account, discovery, billing in una riga ciascuno) | −0,3 |
| 3 Domain Rules (A) | 1,5 | le regole nell'ordine in cui il driver le incontra, macchina a stati, tabella parametri default/demo | alto: è il «Game Rules» di BlackNet, tutto il resto ci rimanda | quasi niente; al limite il paragrafo *Tariff and billing* a due righe | −0,1 |
| 4.1 Key design decisions (B) | 3 | middleware per arco, SSR, coordinamento separato dai siti, stato volatile/durevole, confine emulatore | **alto**: due dei tre criteri di valutazione stanno qui | **«Volatile state in memory, durable in MySQL»** (216 parole) si stringe a 120; **«Where the system stops»** resta solo se si taglia §1.3 | −0,25 |
| 4.2 Components (B) | 1,5 + fig | i sette nodi e la figura di deployment | alto | niente | 0 |
| 5 Problems (B) | 2,5 | P1–P7, dentro/fra nodi, comunicazione | **alto** | **§5.1 «The dividing line»**: 190 parole più una tabella che dice la stessa cosa; tenere la tabella e 80 parole. **§5.5 Communication problems** da 178 a 100 | −0,4 |
| 6 Protocols (A) | 1,5 | tabella degli archi, chi apre, chi ha autorità; il browser che parla direttamente alla stazione; one writer per table | medio-alto: è la panoramica del middleware | già tagliata due volte; si può ridurre §6.2 di un terzo (JInterface è già in §4.1 e §9.5) | −0,2 |
| 7 Addressing (B) | 4 | i meccanismi per P1–P7 con le alternative scartate | **altissimo**: il cuore della valutazione | solo prosa di raccordo: **§7.1** da 200 a 130; **§7.3** da 257 a 190; **§7.5 P5** da 470 a 320; **§7.6 P6** da 212 a 120 (le decisioni di §9.2 dicono il resto) | −0,9 |
| 8 Fault tolerance (B) | 5 | modello di guasto, due rilevatori, stazione morta/isolata, rebuild, charge point, supervisione, tre garanzie, cosa non tollera niente | **altissimo**, ma è la sezione più lunga | **§8.2 detectors** da 350 a 250; **§8.4 «A hole we measured»** da 304 a 180 (la storia di P18 vale, ma metà è cronaca); **§8.6 supervisione** da 309 a 200, o una tabella a tre righe; **§8.8** da 188 a 120 | −0,9 |
| 9.1 HTTP + JWT (B) | 1,3 | servlet, token HS256, la trappola di `jose`, `<c:out>` | medio | **«How the token reaches the browser»** (139 parole sull'XSS) a 40; la sezione token da 243 a 160 | −0,4 |
| 9.2 WS driver (A) | 2,7 (fig) | envelope, handshake, azioni, frame, at-most-once, notifiche, 4 decisioni; figura della prenotazione | alto: è la specifica del canale principale, e la figura è quella che B chiedeva | **tabella dei frame** → i campi in prosa (−0,35); decisioni da 4 a 3 (−0,15). La figura resta | −0,5 |
| 9.3 WS charge point (A) | 2,7 (fig) | mappa su OCPP, ammissione, silenzio, autorizzazione, meter/comandi, riconciliazione, 5 decisioni; figura della sessione con contesa | alto: è il confine del sistema (SCOPE §7) e il pezzo di OCPP che convince | **figura `fig:seq-cp`** è la meno necessaria delle quattro (−0,7); **tabella `tab:plugged`** → tre righe di prosa (−0,25); **Reconciliation** da 178 a 100, il resto è in §8.3 (−0,2) | −1,15 |
| 9.4 Claim (B) | 1,8 | acquire/renew/release, i rifiuti, il leader, le sei regole | **alto**: è il protocollo di P2 | la lista **«Behavioural rules»** ripete cose dette sopra | −0,1 |
| 9.5 JInterface (B) | 1,5 | nodo nascosto, messaggi, sospensioni per push, cosa succede se cade | medio-alto | **«A detail that cost a day»** (jar jinterface 1.6.1) da 134 a 60 | −0,15 |
| 10 Deployment (A) | 1,7 | sette container, immagini, nomi, avvio, «una rete dopo averne provate due», decisioni | medio: il criterio «più nodi» si soddisfa in mezza pagina | **Images** da 160 a 90; **One network** da 140 a 70; **Decisions** da 108 a 60 | −0,4 |
| 11 Testing & demo (A) | 2 | 395 test e `eunit_check.sh`, carico (tabella), mappa scene → problemi, i quattro difetti trovati provando | alto: la tabella scene→problemi trasforma la demo in prova | **tabella di carico** → una riga di prosa con 500 driver / 100 ms (−0,2); **«What the demonstration found»** da 124 a 70 (−0,1) | −0,3 |
| 12 Future works (A) | 1 | quattro estensioni con il motivo del rinvio; il log replicato dichiarato fuori lista | basso-medio | **push + console** da 154 a 80; **l'ultimo paragrafo** (log replicato) è già in §8.4 | −0,3 |

Somma di tutte le righe: **≈ −6,7 pagine**. Non servono tutte.

## Tre menu

**Minimo (−4,1), solo prosa, nessuna figura e nessuna tabella toccata.** §1.3 e §1.4;
§4.1 volatile/durable; §5.1 prosa e §5.5; §7.1, §7.5, §7.6; §8.4 «hole», §8.6
supervisione; §9.1 `<c:out>`; §9.3 riconciliazione; §10 immagini e rete; §11 «found»;
§12 push e ultimo paragrafo. È il menu che non cambia la struttura del documento e non
richiede di rifare niente: solo la passata 2 della skill (togliere il 20% delle parole
senza perdere un fatto), sezione per sezione.

**Consigliato (−5,5).** Il minimo, più: la figura `fig:seq-cp` (§9.3) e la tabella dei
frame (§9.2) in prosa; §7.3 e §8.2 stretti; le «Behavioural rules» di §9.4; il «detail
that cost a day» di §9.5. Si arriva a **~33–34 pagine**, con margine per la revisione
incrociata che di solito aggiunge una riga qua e là.

**Aggressivo (−8).** Il consigliato, più: §5 ridotto alla tabella e a un paragrafo per
gruppo (−1); §8.6 supervisione in tabella (−0,3); §2 funzionali compressi (−0,3); §6 alla
tabella più un paragrafo (−0,5). Si arriva a **~31**. Sconsigliato: §5 è valutata e
la sua prosa dice *perché* ogni problema è difficile, che la tabella non dice.

## Cosa non toccare

- §7 nei contenuti: ogni meccanismo con l'alternativa scartata. Si tocca la prosa di
  raccordo, mai un'alternativa.
- §8.2 e §8.3: i due rilevatori e le misure del 3/09 (0,248 → 0,558 kWh; 2,12 s / 2,29 s
  / 64,6 s). Sono le prove.
- §4.1 «The case for middleware»: è il criterio esplicito del corso.
- §9.4: il protocollo di claim con `GrantedAt` dal coordinatore e il renew che ricostruisce.
- Le tre figure che restano: deployment (§4.2), macchina a stati (§3), prenotazione con
  claim (§9.2). Un docente che sfoglia vede quelle.
- §2, il paragrafo sui tre requisiti non consegnati; §11, la tabella scene → problemi.

## Chi taglia cosa

Le righe **A** le taglio io appena decidi il menu. Le righe **B** sono sue: gli passo
questo file com'è. La revisione incrociata parte dopo, sul documento già alla lunghezza
giusta, altrimenti si rilegge prosa destinata a sparire.
