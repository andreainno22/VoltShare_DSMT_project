---
name: tech-report-latex
description: Scrivere, revisionare o compilare una relazione tecnica in LaTeX (progetto universitario, design document, report di sistema) con prosa che non ha i tic della scrittura generata. Usare quando si redige un .tex lungo, quando si traduce materiale di progetto in un documento consegnabile, o quando si revisiona un capitolo già scritto.
---

# Relazione tecnica in LaTeX

Skill riutilizzabile. Non conosce nessun progetto in particolare: i fatti li porta chi scrive
o una seconda skill di progetto.

## Regola zero

**Nessuna frase entra nel documento se non è verificata.** Un numero senza una misura alle
spalle, un componente descritto senza aver aperto il file, un comportamento dedotto dal nome
di una funzione: sono errori più gravi di qualunque difetto di stile, e sono anche quelli che
un docente scopre all'orale con una domanda sola.

Se un fatto serve e non è verificabile, ci sono due uscite oneste: verificarlo, oppure
scriverlo come limite dichiarato ("we did not measure this"). Non esiste la terza.

## Le cinque fasi

Non saltarle e non fonderle. La qualità viene dalla separazione: ogni fase ha un obiettivo
solo, e chi scrive e revisiona contemporaneamente non fa bene nessuna delle due cose.

### 1. Indice con budget

Prima di scrivere una riga, fissare l'elenco delle sezioni **e le pagine che spettano a
ciascuna**. Il budget serve a due cose: impedisce alla sezione facile di gonfiarsi, e rende
visibile subito se una sezione importante non ha abbastanza materiale per esistere.

Regola pratica: una sezione sotto mezza pagina è una sottosezione di qualcos'altro; una
sopra le sei pagine va spezzata.

### 2. Raccolta dei fatti, sezione per sezione

Per ogni sezione, prima della prosa, un elenco di fatti nudi con la fonte accanto:
`file:riga`, il nome del test, il log dell'esperimento. Se un fatto resta senza fonte, torna
alla regola zero.

Questa fase è quella che rende il documento diverso da un tema: la prosa nasce dai fatti,
non i fatti dalla prosa.

### 3. Bozza, una sezione alla volta

Ordine di scrittura, non di lettura: prima le sezioni tecniche centrali (architettura,
problemi, soluzioni), poi quelle di contorno, **l'introduzione per ultima**. L'introduzione
scritta per prima promette un documento che non esiste ancora e va comunque riscritta.

Scrivere una sezione intera prima di rileggerla. Le correzioni riga per riga durante la
stesura producono paragrafi levigati e capitoli sconnessi.

### 4. Passate di revisione

Una passata, un difetto. Sono sette e stanno in `references/revision-passes.md`, con la
checklist di ciascuna. Non fonderle: cercare contemporaneamente fatti sbagliati, parole di
troppo e tic stilistici significa trovare poco di tutto.

### 5. Compilazione e lint

`latexmk` per il PDF, `scripts/style-lint.py` per le metriche di stile. Il linter non decide
niente al posto di chi scrive: segnala i punti da guardare. Dettagli in
`references/latex-setup.md`.

## Voce

Il capitolo completo è in `references/human-voice.md`, con esempi prima/dopo. Qui le regole
che vanno tenute a mente mentre si scrive, non dopo.

**Le sette che fanno più danno**

1. **Niente participio finale.** `..., ensuring consistency across nodes.` è il tic più
   riconoscibile di tutti. O diventa una frase propria, o sparisce.
2. **Niente terzine.** Tre elementi paralleli della stessa lunghezza (`fast, reliable and
   scalable`) sono la firma. Se gli elementi sono davvero tre, dargli lunghezze diverse.
3. **Niente parallelismo negativo, in nessuna delle sue forme.** Vale per `not just X but
   Y` e `rather than X` quanto per l'appositivo `X, not Y` / `X and never Y` / `is not a
   failure. It is the design.` Sono la stessa figura, e la seconda forma è la più
   riconoscibile: correggere un `rather than` sostituendolo con `, not` peggiora il testo.
   Budget per l'intero documento: due o tre occorrenze. Vedi `human-voice.md` §2.2.
4. **Niente chiusure riassuntive.** Una sezione finisce sull'ultimo fatto, non su
   `In summary, this architecture provides...`.
5. **Niente aggettivi di importanza.** `crucial`, `pivotal`, `robust`, `seamless`,
   `comprehensive`. Se una cosa è importante, si vede da cosa fa.
6. **Verbi semplici.** `is` invece di `serves as`, `uses` invece di `leverages`, `lets`
   invece di `facilitates`.
7. **Zero em dash.** Nessun `---`, nessun `—`, nessun `--` fuori dagli intervalli numerici.
   Al loro posto: due punti, parentesi, o più spesso un punto fermo. Il materiale sorgente
   ne è pieno e va riscritto, non ricopiato.

**Le due che si dimenticano sempre**

8. **Varianza nella lunghezza delle frasi.** Il testo generato si assesta su 15-22 parole a
   frase e ci resta. La prosa umana alterna frasi di quattro parole e frasi di trentacinque.
   Questa è la metrica che i rilevatori chiamano *burstiness*, ed è la più difficile da
   simulare a posteriori: viene sola se si scrive pensando, e va controllata col linter.
9. **Asimmetria.** Sezioni tutte della stessa lunghezza, elenchi tutti da quattro voci, voci
   tutte con `**Termine**: spiegazione`. La regolarità perfetta è artificiale.

## Cosa mettere *dentro* il testo

Le regole sopra tolgono. Queste aggiungono, e sono ciò che rende un testo tecnico
riconoscibilmente scritto da qualcuno che c'era:

- **Numeri non tondi presi da misure vere.** `0.248 → 0.403 kWh` vale dieci volte
  `energy increased steadily`.
- **Nomi propri**: moduli, funzioni, file, container, numeri di riga. Un documento che
  nomina `vs_claim_client.erl` è stato scritto da chi lo ha aperto.
- **Limiti ammessi in prima persona.** `We did not implement X. The reason is Y.` Nessun
  generatore ammette spontaneamente un buco, perché non ha niente da difendere.
- **Motivi poco lusinghieri ma veri.** "Il default di `net_ticktime` è sessanta secondi, e
  sessanta secondi erano troppi" è una spiegazione; "for optimal performance" non lo è.
- **Date e circostanze.** `measured on 3 September on a single host` colloca il fatto.
- **Ciò che è stato scartato e perché.** La sezione più difficile da falsificare e quella
  che i docenti leggono per prima.

## Antipattern

Cose che sembrano soluzioni e non lo sono:

- **Introdurre errori di ortografia o colloquialismi** per "sembrare umani". Peggiora il
  documento e non sposta nessuna metrica.
- **Sostituire le parole vietate con sinonimi** lasciando la frase vuota. `crucial` che
  diventa `important` non cambia niente: era la frase a non dire nulla.
- **Riscrivere tutto in frasi corte.** La monotonia corta è monotonia uguale.
- **Fidarsi del punteggio di un rilevatore.** Sono classificatori con falsi positivi noti su
  prosa tecnica densa. Servono le metriche del linter come indicatori, non il verdetto.

## File di riferimento

| File | Quando aprirlo |
|---|---|
| `references/human-voice.md` | prima della passata di voce, e la prima volta per intero |
| `references/latex-setup.md` | all'inizio del documento, e quando la compilazione rompe |
| `references/revision-passes.md` | durante la fase 4, una passata per volta |
| `scripts/style-lint.py` | dopo ogni sezione finita e prima della consegna |
