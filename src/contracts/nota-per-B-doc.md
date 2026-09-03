# Nota per B — la relazione: impianto pronto, §7 e §8 scritte, il resto da dividere (3 settembre)

Questa nota **propone una divisione del lavoro** e chiede due decisioni piccole. Non tocca
codice: solo `src/doc/` (nuova) e questo file.

Ho messo in piedi lo scheletro del documento consegnabile e ho scritto le due sezioni che
valgono di più all'orale, §7 e §8, perché sono quelle in cui il progetto ha qualcosa da dire
che gli altri non hanno. Il resto è diviso qui sotto seguendo il perimetro di codice di
ciascuno: chi ha scritto una cosa la racconta.

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
| 1 | Introduction | 1,5 | A |
| 2 | Requirements Specification | 2,5 | **B** |
| 3 | Domain Rules | 1,5 | A |
| 4.1 | Key Design Decisions | 3 | A |
| 4.2 | Architectural Components | 2 | **B** |
| 5 | Synchronization and Coordination Problems | 2,5 | **B** |
| 6 | Architecture Protocols | 1,5 | **B** |
| 7 | Addressing the Problems | 4 | fatta |
| 8 | Fault Tolerance and Recovery | 4 | fatta |
| 9 | API & Protocol Specification | 4 | **B** |
| 10 | Deployment | 2 | A |
| 11 | Testing and Demonstration | 2 | A |
| 12 | Future Works | 1 | **B** |

Totale ≈ 32 pagine. BlackNet ne aveva 19, ma il nostro sistema ha sette nodi, tre protocolli
e un coordinatore replicato: non è gonfiaggio, è che c'è più roba da descrivere.

## 3. Perché la divisione è questa

**Il criterio è il perimetro di codice, non il numero di pagine.** §4.2 descrive i componenti,
e quattro dei sette nodi sono tuoi (tre coordinatori più Tomcat, con MySQL dietro). §9 è la
specifica dei protocolli, e tre dei cinque canali passano da te (`jwt.md`, `erlang-java.md`,
`claim.md` lato coordinatore). §6 è la panoramica degli stessi canali.

**§5 la do a te**, ed è la scelta meno ovvia della tabella, quindi la motivo. Elenca i
problemi P1-P7 che §7 e §8 risolvono, e il rischio è che le due sezioni si disallineino. Ma
P2 e P2b sono il coordinatore, cioè il tuo lato, e chi ha scritto l'elezione e il quorum
descrive meglio di me il problema che li ha resi necessari. La regola per non disallinearci è
in fondo a questa nota.

**Quello che resta a me** è la stazione (§3 sono lease, no-show, overstay e potenza, tutta
roba di `vs_station`), il deploy e la demo, più §4.1 perché le alternative scartate sono in
`SCOPE.md` §9 e `DESIGN-NOTES.md` §5, che ho scritto io.

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
   `DESIGN-NOTES.md` ne sono pieni (8 e 11 ogni mille parole): le frasi che riporti da lì
   vanno **rifatte, non ricopiate**.
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

**Una cosa che il linter non misura e che conta più di tutte:** i numeri veri. `0,248 → 0,403
→ 0,558 kWh, misurato il 3 settembre` vale dieci volte `energy increased steadily`. Stessa
cosa per i nomi dei moduli e per i limiti ammessi. È la roba che nessun generatore inventa,
perché non ha niente da difendere.

## 5. La regola per non disallineare §5 con §7 e §8

Una sola: **§5 elenca i problemi e non anticipa le soluzioni.** Per ogni problema, dove nasce,
perché è difficile, cosa succederebbe senza soluzione. Il meccanismo scelto sta in §7 (o in
§8 se è un guasto), e §5 può rimandarci con `\cref{sec:addressing}`.

I nomi sono fissi e sono quelli di `SCOPE.md` §5: P1 ... P7. In §7 ho usato le label
`sec:p1`, `sec:p2`, `sec:p2b`, `sec:p3`, `sec:p5`, quindi puoi rimandarci direttamente.

Il glossario, che vale per tutti e due e che in §7 è già usato in modo rigido:

- **connector** la presa fisica, **charge point** l'apparecchiatura, **station** il sito e il
  suo nodo;
- **reservation** è locale e riguarda un connettore, **claim** è di rete e riguarda un
  veicolo. Non sono sinonimi in nessuna frase del documento;
- **coordinator** è uno dei tre nodi, **leader** è quello che sta servendo adesso. Gli altri
  due non sono «backup».

## 6. Una cosa che ho trovato scrivendo, e che ti riguarda

**`DESIGN-NOTES.md` §4c è vecchio su P18.** Dice ancora *«Not fixed; mitigated in the demo by
a ten-second pause»*, ma il codice ha il tuo fix del 3/09: `{rebuilt, []}` con
`map_size(claims) =:= 0` resta in `rebuilding` e ne esce sul primo renew, con
`deadline_ms()` come tetto. L'ho verificato in `vs_coord_srv.erl:427-431` prima di
descriverlo in §8, e in §8 c'è la versione corretta.

Il punto per te non è la nota da aggiornare, è che **le note di progetto e il codice hanno
già divergenza**, e la relazione si scrive traducendo le note. Prima di riportare un fatto
tecnico conviene aprire il modulo che lo implementa: mi è costato dieci minuti e ha evitato
di scrivere in un documento consegnato che un difetto noto è ancora aperto.

## 7. Due decisioni piccole

1. **I nomi sul frontespizio.** In `main.tex` c'è un `% TODO` con due `Nome Cognome`.
   Mettili tu o dimmi come li scrivo.
2. **Il nome del progetto.** `DESIGN-NOTES.md` §9 dice ancora che *VoltShare* è un
   segnaposto. È in tutto il codice, nei container e nel database: io lo terrei e toglierei
   la riga dalle note. Se hai un'idea migliore, questo è l'ultimo momento utile.

## 8. Ordine consigliato

Non date, perché non le decido io. L'ordine sì, e ha una ragione:

1. **§9 API** per prima, tua. È la più meccanica (tabelle di messaggi dai `contracts/`) e la
   più lunga: se slitta, slitta tutto.
2. **§2, §4.2, §6** a seguire, tue: sono traduzione di materiale che c'è già.
3. **§3, §4.1, §10, §11**, mie, in parallelo alle tue.
4. **§5** tua, dopo aver letto §7 e §8 che sono già scritte, così l'aggancio lo fai vedendo
   dove vanno a parare.
5. **§1** e **§12** per ultime, io la prima e tu la seconda.
6. Poi una passata di revisione **incrociata**: io rileggo le tue, tu le mie. È lo stesso
   metodo che ha funzionato per il codice, e per la prosa funziona ancora meglio, perché i
   difetti di stile chi scrive non li vede.

— A
