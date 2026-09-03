# Le sette passate di revisione

Una passata, un difetto, dall'inizio alla fine del documento (o della sezione, se si lavora
per sezioni). Cercare più difetti insieme significa trovarne pochi di ciascuno: è il motivo
per cui esistono sette passate invece di una rilettura generica.

L'ordine conta. Non ha senso limare il ritmo di un paragrafo che la passata dei fatti
cancellerà.

---

## Passata 1 — Fatti

**Domanda:** questa affermazione è vera, e come lo so?

Riga per riga, ogni affermazione tecnica deve ricadere in una di tre categorie:

- verificata sul codice o su una misura, con la fonte annotata;
- dichiarata come scelta di progetto ("we chose", "we assume");
- dichiarata come limite ("we did not implement", "this was not measured").

Tutto il resto esce. I punti dove si sbaglia più spesso:

- numeri ripresi da una nota vecchia e nel frattempo cambiati nel codice;
- comportamenti dedotti dal nome di una funzione senza averla letta;
- funzionalità descritte al presente che in realtà sono future work;
- valori di configurazione scritti nel testo e diversi nel file di deploy.

**Uscita della passata:** un elenco di affermazioni da verificare, verificate una per una
prima di procedere.

---

## Passata 2 — Taglio

**Obiettivo:** togliere il 20% delle parole senza perdere un fatto.

Non è un esercizio di stile: la densità è la differenza più visibile tra una relazione
scritta e una generata. Cosa esce per primo:

- frasi che annunciano quello che la sezione sta per dire (`This section describes...`);
- ripetizioni tra l'introduzione di una sezione e il suo primo paragrafo;
- aggettivi che non cambiano il senso se cancellati;
- esempi che ripetono un esempio già dato;
- ogni frase che, coperta con un dito, non manca a nessuno.

Se una sezione non regge il taglio del 20%, di solito è perché aveva pochi fatti e molta
prosa di raccordo.

---

## Passata 3 — Voce

Applica la checklist di `human-voice.md` §8, in quell'ordine. È l'unica passata in cui è
utile procedere per ricerca testuale invece che per lettura: si cerca il pattern, si guarda
l'occorrenza, si decide.

Ricerche da fare, nell'ordine (con `Grep` sui `.tex`):

| Cerca | Perché |
|---|---|
| `ing,` e `ing\.` a fine proposizione | participi finali |
| `---`, `--`, `—` | em dash, che devono essere zero |
| `Moreover\|Furthermore\|Additionally\|In conclusion\|Overall` | connettivi da tema |
| `not just\|not only\|rather than` | parallelismi negativi |
| `crucial\|pivotal\|robust\|seamless\|comprehensive\|leverage\|utilize` | blacklist |
| `serves as\|acts as\|plays a key role\|is designed to` | copule gonfiate |
| `It is important to note\|It is worth noting` | preamboli di hedging |
| `ensures\|ensuring` | quasi sempre una promessa non quantificata |

---

## Passata 4 — Ritmo

Si legge ad alta voce. Non c'è alternativa: gli occhi saltano la monotonia, l'orecchio no.

Cosa si sente e cosa si fa:

- **Tre frasi di fila della stessa lunghezza** → una si accorcia o due si fondono.
- **Un paragrafo che non respira mai** → si spezza, o gli si mette davanti una frase corta.
- **Un elenco che segue immediatamente un altro elenco** → uno dei due torna in prosa.
- **Ogni paragrafo che inizia con lo stesso soggetto** (`The coordinator...`,
  `The coordinator...`) → si varia l'attacco.

Il linter dà la deviazione standard della lunghezza delle frasi: sotto 9 c'è un problema
misurabile, ma il numero da solo non dice dove. Lo dice la lettura.

---

## Passata 5 — Terminologia

Un concetto, un nome, per tutto il documento. In un sistema distribuito le collisioni sono
la norma: *reservation* e *claim*, *node* e *host*, *station* e *site*, *charge point* e
*connector*, *coordinator* e *leader*.

Da fare:

1. Elencare i termini tecnici del documento.
2. Per ciascuno, il punto in cui è definito la prima volta (in grassetto, una volta sola).
3. Cercarne le occorrenze e verificare che nessuna usi un sinonimo improvvisato.
4. Verificare l'inverso: che lo stesso termine non indichi due cose diverse in due sezioni.

Chi legge un documento tecnico impara i nomi mentre legge. Cambiarli a metà lo costringe a
ricominciare.

---

## Passata 6 — Struttura e navigazione

Si guarda il documento da lontano, non le frasi:

- L'indice, da solo, racconta il progetto? Un indice fatto di titoli generici
  (`Implementation`, `Details`) non racconta niente.
- Le sezioni hanno lunghezze coerenti con la loro importanza? La sezione centrale del
  progetto deve essere la più grossa. Se non lo è, o manca contenuto lì o ce n'è troppo
  altrove.
- Ogni figura e ogni tabella sono citate nel testo?
- I riferimenti incrociati sono `\cref`, non numeri scritti a mano?
- Ogni sezione ha uno schema interno diverso dalle vicine, o sono tutte
  paragrafo-elenco-paragrafo?

---

## Passata 7 — Compilazione

Ultima, perché prima non ha senso.

```powershell
latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex
python .claude/skills/tech-report-latex/scripts/style-lint.py doc/sections/*.tex
```

Controlli finali sul PDF, non sul sorgente:

- [ ] Zero `Undefined references` nel log
- [ ] Nessun `Overfull \hbox` sopra i 10pt
- [ ] Nessuna figura finita tre pagine dopo il punto che la cita
- [ ] Il conteggio pagine rientra nel budget deciso in fase 1
- [ ] L'indice non ha voci orfane (una sottosezione sola dentro una sezione)
- [ ] Nessun `\includeonly` rimasto attivo
- [ ] Il frontespizio ha i nomi giusti e l'anno accademico giusto

---

## Quando fermarsi

Il documento è finito quando una passata intera non produce modifiche sostanziali, non
quando non si trova più niente da limare. Da un certo punto in poi le revisioni tolgono
carattere al testo invece di difetti: la prosa diventa liscia, uniforme, e paradossalmente
più simile a quella generata.
