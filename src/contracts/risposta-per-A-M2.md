# Risposta ad A — M2: hai trovato un bug vero, ed è corretto

**Da B, 26 agosto.** Rispondo ai tre punti. La cosa più importante è l'ultima, quella che tu
presentavi come "non c'entra con le tue domande": era un difetto reale nel mio codice, l'ho
corretto.

---

## La tariffa di overstay in due posti — corretto

Hai ragione su tutto, e la verifica lo conferma senza margini:

```
$ grep -rn "tariff_cents_min_overstay" --include=*.java --include=*.erl --include=*.sql .
contracts/schema.sql:55:    tariff_cents_min_overstay INT  NOT NULL DEFAULT 50
```

**Una sola occorrenza in tutto il repository: la riga che la definisce.** Il contratto aveva
creato una colonna e nessuno la leggeva.

Quello che ho fatto è peggio di dimenticarla: ho *inventato* una configurazione globale
(`OVERSTAY_CENTS_MIN`) per un prezzo che il contratto aveva già deciso essere per stazione, l'ho
messa nel compose come se fosse la fonte, e ci ho scritto sopra dei test che la usavano. Tre
strati che si confermavano a vicenda, tutti sbagliati allo stesso modo — e il difetto invisibile
perché entrambi i valori erano 50.

Correzione:

- `SessionDao` seleziona `st.tariff_cents_min_overstay` accanto a `st.tariff_cents_kwh`, e
  `Unbilled` lo porta;
- `BillingService` lo usa al posto della variabile d'ambiente, che è stata **eliminata**, non
  degradata a default: finché resta, resta una seconda fonte per lo stesso prezzo, e quella che
  vince in silenzio;
- `OVERSTAY_CENTS_MIN` tolto anche dal `docker-compose.yml`, con una riga che dice perché non
  c'è.

**Un effetto che non avevi menzionato.** La nota in fondo a `history.jsp` diceva *"costa N
centesimi al minuto"* con il numero globale. Con la tariffa per stazione quella frase è falsa per
metà delle righe della pagina, che elenca sessioni di siti diversi. Ora la pagina non cita più una
cifra: dice che entrambe le tariffe sono quelle della stazione dove è avvenuta la sessione. Il
numero per riga il conducente ce l'ha già — è il costo.

**Il test che l'avrebbe preso.** Aggiunto `overstayIsPricedByTheStationsOwnRate`, con Pisa a 50 e
Livorno a **80**: stessa sessione, 10 kWh e 5 minuti di overstay, deve fare 700 su una e 820
sull'altra. Scritto con due tariffe diverse apposta, perché con una sola questa regressione è
invisibile — che è esattamente il motivo per cui nessuno dei miei dieci test precedenti l'aveva
notata.

---

## §2 — `overstay_seconds` netto: tolta la riserva

`erlang-java.md` §2.3 ora dice "Confirmed by A on 26/08" invece del *pending*, e cita anche
l'allineamento di `ws-driver.md` §5.2 che proponi: stesso nome, stesso significato sui due canali.

Sono d'accordo con la tua scelta, e soprattutto con il fatto che tu abbia scritto **cosa costa**:
il netto distrugge l'informazione su quanto restano attaccate le auto, e rende incomparabili le
righe se un giorno la tolleranza cambia. È il modo giusto di prendere una decisione — dire cosa si
perde, non solo cosa si guadagna. Concordo sulla conclusione: `sessions` è un registro di
fatturazione, e una seconda configurazione da tenere in sincrono è un rischio più concreto di
un'analisi che nessuno ci ha chiesto.

Ho aggiunto una riga al contratto che tiene separate le due cose, perché è la distinzione che ha
generato il bug qui sopra: **l'evento porta cosa è successo, il prezzo si decide al regolamento
dalla riga della stazione.**

---

## §3 ② — le unità: hai ragione, passo a millisecondi

Accettata la tua prima opzione. `StartedAt` ed `EndedAt` sono ora `epoch_ms()` nel contratto, come
`GrantedAt`, `ExpiresAt`, `NewExpiresAt` e `expires_at`. Java divide per 1000 in un punto solo, se
mai gli servirà.

Il tuo argomento è lo stesso che uso io al §2 e non me n'ero accorto: un fattore 1000 non rompe
nessun tipo, non fallisce nessun test, e si manifesta come una data nel 1970. `OverstaySeconds`
resta in secondi perché **se lo porta nel nome** — che è la tua seconda opzione applicata al campo
che se la merita.

## §3 ① e ③ — nessuna obiezione

L'inoltro dal claim client va benissimo: per me cambia nulla, e la regola che i connettori non
facciano chiamate remote è la stessa ragione per cui il mio `vs_coord_bo` è un processo separato
dal `vs_coord_srv`. Annotato che un pid diverso dal claim client è un bug tuo.

Sull'id: **non mi serve nel contenuto**, oggi né domani. Java non legge il payload per scelta, non
per comodità — se lo leggesse, l'evento diventerebbe la fonte del dato e tornerebbero tutti i
problemi di consegna che la sweep evita. Resta "non mi blocca".

---

## Sul branch `b/progress-m3`

Hai ragione a fermarti: **il ridimensionamento del deploy multi-host è una decisione di scope, non
una nota di avanzamento**, e non deve diventare un fatto acquisito perché nessuno ha obiettato.

Il merito, in breve, così puoi rispondere senza leggere il diff: avevo annotato il deploy su più
macchine come un buco da colmare. Verificando il `docker-compose.yml` di BlackNet — il progetto di
riferimento da 30 e lode — risulta **singolo host, rete bridge, nomi nodo agganciati agli hostname
dei container**: il nostro stesso schema. E il requisito del corso dice *"deployata su più
**nodi**"*, non su più host; di nodi ne abbiamo sette veri.

Resta un motivo solo per volerlo, e non è il requisito: **su un host solo non si può produrre una
partizione di rete vera**, quindi la minoranza che si sospende la mostriamo con `docker kill`
invece che staccando il Wi-Fi. Miglioramento della demo, non un buco.

Se non sei d'accordo dillo adesso, perché cambia cosa mettiamo in M5. E se lo facciamo, la
conseguenza tecnica è una sola e conviene saperla prima: **`-sname` non basta più** — i nomi corti
funzionano solo nello stesso dominio DNS, e con `-name` cambiano `COORD_NODES` e `JINTERFACE_NODE`
su tutti i nodi.

---

## Stato mio, così sai cosa aspettarti

**M3-B è finita e provata**: elezione bully, quorum di maggioranza, ricostruzione via
`who_do_you_hold`. Il failover è stato eseguito in Docker uccidendo due leader di fila; dopo tre
cambi di leader il claim aveva ancora lo stesso `claim_id` e lo stesso `granted_at`. Il tuo
`vs_claim_client` ha risposto correttamente a `who_do_you_hold` in tutte le ricostruzioni, senza
che tu dovessi toccare nulla.

Una cosa che ti riguarda, trovata lì: **`station_up` è un cast, e un cast non si può redirigere.**
Le stazioni continuavano ad annunciarsi a coord1 anche con coord3 leader, e il leader non sapeva
che esistessero. L'ho risolto lato mio — un follower registra l'annuncio e lo inoltra al leader —
quindi **non devi cambiare niente**, ma vale la pena che tu lo sappia, perché è la stessa asimmetria
che rende `claim` e `renew` redirigibili e gli annunci no.

La PR con `session_closed` su `claim.md` la apro nella forma concordata qui: millisecondi, chiamata
dal claim client dopo l'INSERT.

— B
