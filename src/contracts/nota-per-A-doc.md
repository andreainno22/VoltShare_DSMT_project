# Nota per A — la relazione: impianto pronto, §7 e §8 scritte, il resto da dividere (3 settembre)

Questa nota **propone una divisione del lavoro** e chiede due decisioni piccole. Non tocca
codice: solo `src/doc/` (nuova), `DESIGN-NOTES.md` §4c e questo file.

Ho messo in piedi lo scheletro del documento consegnabile e ho scritto le due sezioni che
valgono di più all'orale, §7 e §8, perché sono quelle in cui il progetto ha qualcosa da dire
che gli altri non hanno. Il resto è diviso qui sotto seguendo il perimetro di ciascuno: chi
ha scritto una cosa la racconta.

---

## 1. Cosa c'è già

```
src/doc/
  main.tex                 preambolo, frontespizio, indice, \input delle 12 sezioni
  sections/01..12-*.tex    dodici file, uno per sezione
```

Compila con `latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex` da `src/doc/`.
Oggi fa **14 pagine**: §7 (4 pp.) e §8 (4 pp.) scritte, le altre dieci sono segnaposto.

Ogni segnaposto è un `\stub{...}` che stampa in grigio cosa va scritto lì, con il budget in
pagine e le fonti. Il comando è definito in `main.tex`: quando le sezioni sono tutte scritte,
**si cancella la definizione**, così un residuo dimenticato non compila invece di finire nel
PDF consegnato.

## 2. L'indice, e perché è quello

È l'indice di BlackNet esteso. Ho estratto il loro dal PDF nel repo (`1 Introduction`,
`2 Requirements`, `3 Game Rules`, `4 System Architecture` con `4.1 Key Design Decisions`,
`5 Synchronization and Coordination Problems`, `6 Architecture Protocols`,
`7 Addressing Problems`, `8 API & Protocols Specification`, `9 Mnesia Integration`,
`10 Future Works`), e ho tenuto la loro spina dorsale perché è una struttura che il docente
ha già valutato 30 e lode.

Due differenze, entrambe motivate:

- **il posto della loro §9 Mnesia lo prende la nostra §8 Fault Tolerance.** Loro avevano una
  sola sezione sul recupero; noi abbiamo cinque meccanismi diversi, elezione, quorum,
  ricostruzione, due rilevatori di guasto e tre garanzie di consegna. È il capitolo dove
  siamo più forti e merita quattro pagine;
- **il loro §7 diventa il nostro §7 + §8**, e abbiamo in più §10 Deployment e §11 Testing,
  che loro non avevano separati.

| # | Sezione | Pagine | Chi |
|---|---|---|---|
| 1 | Introduction | 1,5 | B |
| 2 | Requirements Specification | 2,5 | **A** |
| 3 | Domain Rules | 1,5 | **A** |
| 4.1 | Key Design Decisions | 3 | B |
| 4.2 | Architectural Components | 2 | B |
| 5 | Synchronization and Coordination Problems | 2,5 | B |
| 6 | Architecture Protocols | 1,5 | **A** |
| 7 | Addressing the Problems | 4 | fatta |
| 8 | Fault Tolerance and Recovery | 4 | fatta |
| 9.1, 9.4, 9.5 | HTTP e JWT, claim, bridge JInterface | 2 | B |
| 9.2, 9.3 | WebSocket driver, WebSocket charge point | 2 | **A** |
| 10 | Deployment | 2 | **A** |
| 11 | Testing and Demonstration | 2 | **A** |
| 12 | Future Works | 1 | **A** |

Totale ≈ 32 pagine. BlackNet ne aveva 19, ma il nostro sistema ha sette nodi, tre protocolli
e un coordinatore replicato: non è gonfiaggio, è che c'è più roba da descrivere.

**Il conto delle pagine: 13,5 a te, 11 a me più le 8 già scritte.** Ho tenuto per me le
sezioni che dipendono da materiale che ho in mano (il coordinatore, `SCOPE.md`,
`DESIGN-NOTES.md`) e ti ho lasciato quelle che si scrivono leggendo file che conosci meglio
di me. Se il bilancio non ti torna, il pezzo più facile da spostare è §4.2: i componenti
sono sette e due sono le tue stazioni.

## 3. Perché la divisione è questa

**Il criterio è il perimetro, non il numero di pagine.**

Le tue: §3 sono le regole di dominio, e lease, grazia dell'overstay e ripartizione della
potenza vivono in `vs_connector` e `vs_power`, che sono tuoi (la sospensione per no-show la
applica il coordinatore al momento del claim, quindi quel mezzo paragrafo lo rileggo io).
§9.2 e §9.3 sono i tuoi due canali WebSocket, `ws-driver.md` e `ws-chargepoint.md`, con il
sottoinsieme OCPP che hai definito tu. §6 è la panoramica degli stessi canali. §2 è
traduzione dei requisiti, lavoro meccanico ma lungo.

§10 e §11 te le ho date **per bilanciamento e non per perimetro**, e lo dico invece di
inventare una motivazione: il `docker-compose.yml` l'abbiamo toccato in due e `DEMO.md` è
mio. Ma gli scenari che si vedono a schermo (contesa su un connettore, no-show, potenza che
si ridistribuisce) sono i tuoi, e il conteggio EUnit lo rilanci tu a ogni giro. Se preferisci
scambiarle con §4.2 va bene uguale.

Le mie: §4.1 perché le alternative scartate sono in `SCOPE.md` §9 e `DESIGN-NOTES.md` §5;
§4.2 perché quattro nodi su sette sono il coordinatore, Tomcat e MySQL; §5 perché deve
restare allineata a §7 e §8 che ho appena scritto; §9.1, §9.4 e §9.5 perché sono JWT, claim
lato coordinatore e bridge JInterface.

**L'introduzione la scrivo per ultima**, quando il resto esiste. Un'introduzione scritta
prima promette un documento che non c'è ancora.

## 4. Le regole di scrittura, e perché ce ne sono

Il documento non deve sembrare generato da un LLM, e non è una preoccupazione teorica: è la
prima cosa che salta all'occhio a chi legge trenta relazioni. Ho messo le regole in due skill
dentro il repo, `.claude/skills/tech-report-latex/` (riutilizzabile) e
`.claude/skills/voltshare-doc/` (i fatti del progetto). Si leggono come documenti normali
anche senza usare Claude Code.

Il minimo indispensabile, se non leggi altro:

1. **Zero em dash.** Né `---`, né `—`, né `--` fuori dagli intervalli numerici. Al loro posto
   due punti, parentesi, o più spesso un punto fermo. Attenzione che `SCOPE.md` e
   `DESIGN-NOTES.md` ne sono pieni (8 e 11 ogni mille parole, li ho scritti io così): le
   frasi che riporti da lì vanno **rifatte, non ricopiate**.
2. **Niente code participiali.** `..., ensuring that no claim is lost` è il tic più
   riconoscibile che esista. O diventa una frase propria, o sparisce.
3. **Niente terzine.** `fast, reliable and scalable`, tre elementi paralleli della stessa
   lunghezza.
4. **Niente parallelismo negativo, e attenzione che ha due forme.** Quella evidente è
   `not just X, but Y`. Quella insidiosa è appositiva: `the connector is held, not free`,
   `these are two failures, not one`, `is not a failure of the system. It is the design.`
   È la stessa figura, e la seconda si riconosce da lontano. Budget per tutto il documento,
   sommando le due: due o tre occorrenze.
5. **Niente chiusure riassuntive.** Una sezione finisce sull'ultimo fatto, non su
   `In summary, this architecture provides...`.
6. **Niente aggettivi di importanza**: `crucial`, `robust`, `seamless`, `comprehensive`,
   `pivotal`. Se una cosa è importante si vede da cosa fa.
7. **Verbi semplici**: `is` e non `serves as`, `uses` e non `leverages`.
8. **Frasi di lunghezza diversa.** Il testo generato si assesta sulle 15-22 parole e ci
   resta. Dopo un passaggio lungo, una frase corta.

C'è un linter che misura queste cose:

```powershell
python .claude/skills/tech-report-latex/scripts/style-lint.py src/doc/sections/NN-*.tex
```

Non decide niente al posto tuo, conta e ti mostra dove. Obiettivo: nessun FAIL, deviazione
standard della lunghezza delle frasi sopra 9. Sulle mie due sezioni dà 10,2 e 11,3.

**Il punto 4 lo scrivo perché ci sono cascato dentro io.** La prima stesura di §7 e §8 aveva
**24 parallelismi negativi in otto pagine**, e una parte me li sono messi da solo
*correggendo*: stavo togliendo i `rather than` e li ho sostituiti con `, not`, che è lo
stesso tic in una forma peggiore. Il linter mi dava via libera perché cercava solo la forma
esplicita. Ora ne cerca quattro, e nel testo ne restano sei, tutti descrittivi
(`a claim that was granted and never used`). Se rileggendo le mie sezioni ne vedi altri,
dimmelo.

**Una cosa che il linter non misura e che conta più di tutte:** i numeri veri. `0,248 →
0,403 → 0,558 kWh, misurato il 3 settembre` vale dieci volte `energy increased steadily`.
Stessa cosa per i nomi dei moduli e per i limiti ammessi. È la roba che nessun generatore
inventa, perché non ha niente da difendere.

## 5. La regola per non disallineare §5 con §7 e §8

Riguarda me, ma la scrivo qui perché tocca §6 e §9 che sono tue: **§5 elenca i problemi e non
anticipa le soluzioni**, che stanno in §7 (o in §8 se è un guasto). Stessa cosa per §6: dice
quale protocollo su quale arco e perché quello, e i messaggi li specifichi in §9.

I nomi dei problemi sono fissi e sono quelli di `SCOPE.md` §5: P1 ... P7. In §7 ho usato le
label `sec:p1`, `sec:p2`, `sec:p2b`, `sec:p3`, `sec:p5`, quindi puoi rimandarci con `\cref`.

Il glossario, che vale per tutti e due e che in §7 è già usato in modo rigido:

- **connector** la presa fisica, **charge point** l'apparecchiatura, **station** il sito e il
  suo nodo;
- **reservation** è locale e riguarda un connettore, **claim** è di rete e riguarda un
  veicolo. Non sono sinonimi in nessuna frase del documento;
- **coordinator** è uno dei tre nodi, **leader** è quello che sta servendo adesso. Gli altri
  due non sono «backup».

## 6. Una cosa che ho corretto scrivendo, e che riguarda me

**`DESIGN-NOTES.md` §4c era rimasto indietro sul mio stesso fix.** Diceva ancora che P18 è
*«Not fixed; mitigated in the demo by a ten-second pause»*, mentre il codice ha la correzione
del 3/09: `{rebuilt, []}` con `map_size(claims) =:= 0` resta in `rebuilding` e ne esce sul
primo renew, con `deadline_ms()` come tetto. L'ho verificato in `vs_coord_srv.erl:427-431`
prima di descriverlo in §8, e ho aggiornato la nota.

Lo segnalo perché il metodo vale per tutti e due: **le note di progetto e il codice hanno già
divergenza**, e la relazione si scrive traducendo le note. Prima di riportare un fatto
tecnico conviene aprire il modulo che lo implementa. A me è costato dieci minuti e ha evitato
di scrivere in un documento consegnato che un difetto noto è ancora aperto.

## 7. Due decisioni piccole

1. **I nomi sul frontespizio.** In `main.tex` c'è un `% TODO` con due `Nome Cognome`.
   Scrivili tu come li vuoi, cognome compreso.
2. **Il nome del progetto.** `DESIGN-NOTES.md` §9 dice ancora che *VoltShare* è un
   segnaposto. È in tutto il codice, nei container e nel database: io lo terrei e toglierei
   la riga dalle note. Se hai un'idea migliore, questo è l'ultimo momento utile.

## 8. Ordine consigliato

Non date, perché le fissiamo insieme. L'ordine sì, e ha una ragione:

1. **§9.2 e §9.3 per prime**, tue. Sono le più meccaniche (tabelle di messaggi dai
   `contracts/`) e le più lunghe da mettere in tabella: se slittano, slitta tutto.
2. **§2, §3, §6** a seguire, tue: traduzione di materiale che c'è già.
3. **§4.1, §4.2, §5, §9.1/9.4/9.5**, mie, in parallelo alle tue.
4. **§10, §11** tue, per ultime fra le tue: il deploy e la demo cambiano ancora, e
   descriverli adesso significa riscriverli dopo.
5. **§1** e **§12** in fondo, io la prima e tu la seconda.
6. Poi una passata di revisione **incrociata**: io rileggo le tue, tu le mie. È lo stesso
   metodo che ha funzionato per il codice, e per la prosa funziona ancora meglio, perché i
   difetti di stile chi scrive non li vede.

— B
