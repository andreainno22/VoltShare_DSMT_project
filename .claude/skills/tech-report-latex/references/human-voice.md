# Voce umana in un documento tecnico

Catalogo dei tratti che i rilevatori e i lettori esperti associano al testo generato, con la
correzione accanto. Gli esempi sono in inglese perché è la lingua in cui si consegna.

Fonti di questa lista, per chi vuole risalire:
[Wikipedia — Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing),
[GPTZero — perplexity e burstiness](https://gptzero.me/news/perplexity-and-burstiness-what-is-it/),
[The Economist — How to spot AI writing](https://theeconomistoffthecharts.substack.com/p/how-to-spot-ai-writing),
[A field guide to AI tells](https://matthewvollmer.substack.com/p/i-asked-the-machine-to-tell-on-itself),
[Em-ergence of the em-dash (arXiv 2606.29540)](https://arxiv.org/pdf/2606.29540).

---

## 1. Sintassi

### 1.1 Participio finale — il tic numero uno

La frase dice la sua cosa, poi aggiunge una coda con un gerundio che commenta ciò che ha
appena detto. Nel testo generato compare a ogni due o tre frasi; nella prosa tecnica umana è
raro perché non aggiunge informazione.

> ✗ The coordinator rebuilds the claim table by querying the stations, **ensuring** that no
> reservation is lost during the failover.

> ✓ The coordinator rebuilds the claim table by querying the stations. No reservation is
> lost during the failover, because the stations own their connectors and were never asked
> to forget them.

Varianti dello stesso difetto: `allowing`, `enabling`, `providing`, `highlighting`,
`making it possible to`, `thus reducing`, `thereby avoiding`, `resulting in`.

Come si corregge: o la coda contiene un fatto, e allora merita una frase propria che lo
spieghi; o non lo contiene, e allora si cancella.

### 1.2 Copula gonfiata

Il testo generato evita `is`. Sono verbi che occupano spazio senza dire di più.

| ✗ | ✓ |
|---|---|
| `serves as the entry point` | `is the entry point` |
| `acts as the arbiter` | `arbitrates` |
| `represents a single connector` | `is a single connector` |
| `leverages the actor model` | `uses the actor model` |
| `utilizes` | `uses` |
| `facilitates recovery` | `makes recovery possible` / `recovers` |
| `enables the system to scale` | `lets the system scale` |
| `boasts three coordinators` | `has three coordinators` |
| `is designed to handle` | `handles` |
| `plays a key role in` | (rifare la frase: cosa fa esattamente?) |

### 1.3 Nominalizzazione

`performs the validation of the token` → `validates the token`.
`the implementation of the election mechanism` → `the election`.
Ogni `-tion of` è un verbo che si è travestito da sostantivo.

### 1.4 Passivo senza agente

Accettabile quando l'agente è ovvio o irrilevante (`the token is verified locally`).
Sospetto quando nasconde chi decide: `it was decided that three coordinators would be
used` → `we chose three coordinators`.

---

## 2. Retorica

### 2.1 Terzine (rule of three)

Tre elementi paralleli, quasi sempre della stessa lunghezza e con la stessa struttura
grammaticale. È il pattern più misurabile di tutti.

> ✗ The system is fast, reliable and scalable.
> ✗ The coordinator monitors nodes, grants claims and rebuilds state.

Non è vietato avere tre cose. È vietato che siano tre cose *uguali di forma*. Correzioni:

> ✓ The coordinator does two things: it grants claims, and it notices when a station dies.
> ✓ The coordinator grants claims. It also monitors the nodes, rebuilds its table after a
> failover, and feeds the back office — but the claims are the reason it exists.

### 2.2 Parallelismo negativo, in tutte le sue forme

La figura è una sola: **si dice cosa una cosa non è, per far sembrare più profondo quello
che è.** Cambia solo la sintassi, e cambiarla non la elimina.

Forma esplicita:

> ✗ This is not just a design choice, it is a guarantee.
> ✗ It is not about performance; it is about correctness.
> ✗ Rather than replicating a log, the coordinator rebuilds its state.

**Forma appositiva, la più insidiosa** perché sembra asciutta e invece è la più
riconoscibile di tutte:

> ✗ The connector is \texttt{held}, not \texttt{free}.
> ✗ That is recovery of the measurement, not recovery of the session.
> ✗ The cost is stated, not hidden.
> ✗ These are two failures, not one.
> ✗ A lost message costs promptness and never money.
> ✗ Refusing to serve is not a failure of the system. It is the design.

**Non si corregge un `rather than` trasformandolo in una virgola più `not`.** È lo stesso
tic in una forma peggiore, ed è l'errore che si commette proprio mentre si crede di stare
ripulendo il testo: un linter tarato solo su `not just` non lo vede, e la densità raddoppia
senza che nessuno se ne accorga.

Come si corregge davvero. Il termine negato quasi sempre non serve, perché il lettore non
aveva pensato all'alternativa che gli si sta togliendo:

| ✗ | ✓ |
|---|---|
| `finds it \texttt{held}, not \texttt{free}` | `finds it already \texttt{held}` |
| `the cost is stated, not hidden` | `the cost: sessions on that station are lost` |
| `these are two failures, not one` | `there are two distinct failures here` |
| `costs promptness and never money` | `delays the invoice without changing it` |
| `is not a failure. It is the design.` | `is deliberate` |

Quando il contrasto è davvero informativo (il lettore *avrebbe* creduto l'opposto), si tiene,
ma si spezza in due frasi e si dice perché: `The connector becomes out_of_service. It does
not go back to free: an outlet with no hardware attached cannot serve anyone.`

Budget per tutto il documento, sommando le due forme: **due o tre occorrenze**, non due o tre
per pagina.

### 2.3 Enfasi sulla significatività

`marks a pivotal moment`, `represents a significant shift`, `underscores the importance of`,
`is a testament to`. In un documento tecnico non c'è niente di epocale: c'è un sistema che
fa delle cose.

### 2.4 Chiusure riassuntive

Il paragrafo finale che ripete la sezione in forma compressa e non aggiunge un fatto.

> ✗ In summary, the architecture described above provides a robust and scalable foundation
> for distributed coordination, addressing the challenges outlined in Section 5.

Cancellare. Una sezione tecnica finisce quando ha detto l'ultima cosa. L'unica eccezione è
un vero riassunto che il lettore userà come riferimento, tipo una tabella.

### 2.5 Chiusure "sfide e prospettive"

`Despite its advantages, the approach faces several challenges` seguito da speculazioni
generiche. Se ci sono limiti veri, si dicono con precisione e si dice quanto costano; se non
ce ne sono di rilevanti, non se ne parla.

---

## 3. Lessico

### 3.1 Blacklist quasi assoluta

`delve`, `intricate`, `pivotal`, `crucial`, `vital`, `testament`, `tapestry`, `realm`,
`landscape`, `robust`, `seamless`, `cutting-edge`, `state-of-the-art`, `game-changing`,
`comprehensive`, `holistic`, `myriad`, `plethora`, `leverage` (verbo), `utilize`,
`showcase`, `foster`, `underscore`, `align with`, `navigate` (in senso figurato),
`streamline`, `elevate`, `unlock`, `harness`, `paramount`, `ever-evolving`.

`robust` merita una nota: è comunissimo anche nella letteratura tecnica vera, ma quasi
sempre come sinonimo di niente. Se il sistema tollera *questo* guasto entro *questo* tempo,
si scrive quello.

### 3.2 Da usare con misura

`key`, `essential`, `significant`, `powerful`, `efficient`, `optimal`, `ensure`,
`highlight`, `emphasize`, `enhance`, `demonstrate`. Non sono errori: diventano sospetti
quando compaiono ogni due paragrafi e quando nessuno di loro è quantificato.

### 3.3 Connettivi da tema

`Moreover`, `Furthermore`, `Additionally`, `In conclusion`, `Overall`, `It is worth noting
that`, `It is important to note that`, `Generally speaking`, `In many cases`, `As we can
see`.

Prova pratica: cancellarli. Nove volte su dieci la frase resta identica e legge meglio. Se
serve davvero un legame logico, spesso è `so`, `but`, `because`, o due punti.

### 3.4 Vaghezza attributiva

`some argue`, `it is widely recognised`, `research shows`, `experts agree`. In un documento
di progetto: chi lo dice, dove, e con che numero.

---

## 4. Formattazione

### 4.1 Grassetto decorativo

Il generatore mette in grassetto i concetti ordinari perché "sembra strutturato". Regola:
il grassetto marca un **termine tecnico alla sua prima definizione** o l'etichetta di una
voce di elenco. Mai una frase intera, mai per enfasi retorica.

### 4.2 Elenchi al posto della prosa

Il test è: gli elementi sono davvero un insieme di cose dello stesso tipo, senza un ordine
narrativo tra loro? Allora è un elenco. Se invece uno tira l'altro (perché, quindi, ma
allora), è un ragionamento e va in paragrafo, perché l'elenco distrugge i nessi.

Nel testo generato la proporzione tipica è più della metà del documento in bullet. In una
relazione tecnica ben fatta gli elenchi sono sotto un terzo.

### 4.3 Elenchi troppo simmetrici

Tutte le voci lunghe uguali, tutte con `**Termine**: definizione`, tutte che iniziano con un
verbo alla stessa forma. Rompere: qualche voce di una riga, qualcuna di quattro, qualcuna
senza etichetta in grassetto.

### 4.4 Titoli "X and Y"

`Challenges and Solutions`, `Design and Implementation`, `Results and Discussion`. Sono i
titoli che si scelgono quando non si sa cosa contiene la sezione. Preferire un titolo che
dica la cosa: `How P2 is enforced`, `What happens when a station dies`.

### 4.5 Em dash: zero

**Regola di questo documento: nessun em dash. Non "pochi", nessuno.**

È il segnale più chiacchierato in assoluto, al punto che ormai un lettore lo nota prima di
tutto il resto. Il difetto vero non è il trattino in sé, ma l'uso che ne fa il testo
generato: al posto della virgola, delle parentesi e dei due punti indifferentemente, uno
ogni due o tre frasi. Siccome distinguere l'uso legittimo da quello automatico costa più
fatica che rinunciarci, si rinuncia.

Vale per tutte le forme: `---` (em dash), `--` (en dash) usato come incidentale, il
carattere Unicode `—` incollato dal materiale sorgente, e la variante con spazi attorno, che
è a sua volta un indizio. L'en dash resta legittimo **solo** negli intervalli numerici
(`Sections 4--6`, `2025--2026`).

Ogni em dash ha un sostituto migliore, e nella maggior parte dei casi è il punto fermo:

| Cosa faceva il trattino | Cosa usare |
|---|---|
| annunciava una spiegazione | due punti |
| conteneva un inciso secondario | parentesi, o si taglia |
| attaccava un ripensamento in coda | punto fermo e frase nuova |
| separava due proposizioni in contrasto | `, but` oppure due frasi |
| introduceva un elenco in linea | due punti |

> ✗ The coordinator rebuilds its table by asking the stations---they own their connectors---and
> only then starts serving.

> ✓ The coordinator rebuilds its table by asking the stations, which own their connectors.
> Only then does it start serving.

**Attenzione al materiale sorgente.** Se le note di progetto da cui si traduce sono piene di
em dash, ogni frase riportata va rifatta, non ricopiata. È il punto in cui la regola si viola
senza accorgersene.

### 4.6 Emoji, checkmark, frecce nel corpo del testo

Fuori da un documento accademico, sempre.

---

## 5. Ritmo (burstiness)

La metrica: deviazione standard della lunghezza delle frasi in parole. Il testo generato sta
tipicamente sotto 6-7; la prosa tecnica umana curata sta sopra 9-10, spesso oltre 12.

Come si ottiene, senza barare:

- Dopo un passaggio lungo e articolato, una frase corta che tira la conclusione. Tre parole
  bastano. `It cannot happen here.`
- Le frasi lunghe si guadagnano: sono lunghe perché contengono una subordinata che porta
  informazione, non perché hanno tre aggettivi in fila.
- Un paragrafo di una frase sola, ogni tanto, è legittimo e cambia il passo della pagina.
- Iniziare occasionalmente con `But`, `So`, `And`, `Then`. In inglese tecnico è accettato e
  spezza la cadenza.

Controprova rapida: leggere ad alta voce mezza pagina. Se il respiro cade sempre nello
stesso punto, il ritmo è piatto.

---

## 6. Struttura del documento

- **Sezioni tutte della stessa lunghezza** è un segnale. La sezione centrale del progetto
  deve essere visibilmente più grossa delle altre.
- **Stesso schema interno ripetuto**: paragrafo introduttivo, elenco puntato, paragrafo di
  chiusura, per ogni sezione. Variare: una sezione può iniziare direttamente da una tabella,
  un'altra da un esempio concreto, un'altra da un problema.
- **Ogni sottosezione con lo stesso numero di sottosottosezioni**. La realtà non è
  bilanciata così.

---

## 7. Cosa aggiunge credibilità

Il rovescio del catalogo. Sono le cose che compaiono solo se chi scrive ha davvero costruito
il sistema, e che nessuna riscrittura superficiale può inventare:

1. **Misure con cifre non tonde**, con la data e le condizioni. `0.248 → 0.403 → 0.558 kWh,
   measured on 3 September on a single host`.
2. **Riferimenti a file, moduli, funzioni, righe.**
3. **Un default del framework che ha dato fastidio.** `net_ticktime defaults to 60 seconds,
   which is 57 seconds too many for our purpose.`
4. **Un limite ammesso senza attenuanti**, con la ragione vera, compresa "non c'era tempo".
5. **Un'alternativa scartata di cui si riconosce un pregio.** `A UNIQUE constraint would
   have worked and cost almost nothing. We rejected it because...` — la generosità verso
   l'opzione scartata è tipicamente umana.
6. **Un'asimmetria dichiarata**: qualcosa che è stato fatto bene da una parte e alla buona
   dall'altra, detto apertamente.
7. **Il verbo al passato per gli esperimenti** e al presente per il sistema. Il testo
   generato mette tutto al presente onnisciente.

---

## 8. Checklist della passata di voce

Da eseguire su una sezione alla volta, in quest'ordine:

- [ ] Cerca `ing,` a fine proposizione → participi finali, elimina o promuovi a frase
- [ ] Cerca le parole della blacklist §3.1 → zero occorrenze
- [ ] Cerca `Moreover|Furthermore|Additionally|In conclusion|Overall` → cancella
- [ ] Cerca `not just|not only|rather than` → al massimo una in tutto il documento
- [ ] Cerca `, not |and not |and never |is not a` → la forma appositiva di §2.2, due o
      tre in tutto il documento. Contale sul serio: è quella che sfugge
- [ ] Cerca `---`, `--` fuori dagli intervalli numerici e il carattere `—` → zero occorrenze
- [ ] Rileggi l'ultimo paragrafo di ogni sezione → se riassume, cancellalo
- [ ] Guarda le liste → almeno una si può riscrivere in prosa? Falla
- [ ] Guarda la simmetria delle voci di elenco → rompine qualcuna
- [ ] Passa il linter → SD della lunghezza frasi sopra 9
- [ ] Leggi ad alta voce un paragrafo a caso → il ritmo cambia almeno una volta?
