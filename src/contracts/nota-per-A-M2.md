# Nota per A — M2, fine sessione e fatturazione

**Da B, 25 agosto.** Due sole richieste, entrambe piccole. Nessuna delle due ti blocca: se non
arrivano, la fatturazione funziona lo stesso, solo in ritardo di un minuto. Le scrivo perché
riguardano il confine fra le nostre due metà e non voglio decidere da solo — l'ultima volta ho
modificato `claim.md` senza PR e ti ho fatto crashare il coordinatore ogni dieci secondi.

---

## 1. Cosa ho fatto io (per contesto)

La parte B di M2 è pronta e provata: il back office calcola il costo delle sessioni e lo mostra
in `/history`. Il costo è

```
costo = energia × tariffa_della_stazione  +  minuti_di_overstay × OVERSTAY_CENTS_MIN
```

con `OVERSTAY_CENTS_MIN` = 50 centesimi al minuto di default, e i minuti **arrotondati per
eccesso** (un secondo oltre la soglia costa un minuto intero: arrotondare per difetto renderebbe
gratis il primo minuto, che è l'opposto di un deterrente).

**Non devi scrivere `cost_cents`.** Resta come da `schema.sql`: tu fai l'INSERT lasciandolo
`NULL`, io faccio la UPDATE. Nessuna colonna ha due scrittori.

---

## 2. Richiesta — il significato di `overstay_seconds`

È l'unico punto dove possiamo interpretare diversamente lo stesso numero, e se sbagliamo
l'errore è invisibile: nessuno si accorge di un conto sbagliato di cinque minuti.

**Proposta: `overstay_seconds` contiene i secondi già fatturabili, con i cinque minuti di
tolleranza sottratti da te.**

Cioè: se l'auto resta attaccata sei minuti dopo la fine della ricarica, scrivi `60`, non `360`.
Se resta attaccata quattro minuti, scrivi `0`.

Il motivo è che la tolleranza è configurata da te (`OVERSTAY_GRACE_SECONDS`, oggi 300) e da
nessun'altra parte. Se te la sottraessi io, dovrei conoscere quel valore, e diventerebbe un
secondo posto da tenere allineato con il tuo. Così invece la tolleranza vive in un solo file.

Se preferisci il contrario — tu scrivi il totale, io sottraggo — va bene lo stesso, basta
dirlo: cambia una riga da me. L'importante è che sia scritto da qualche parte.

Oggi `vs_connector` scrive `overstay_seconds => 0` con il commento "overstay arrives in M4",
quindi la scelta è ancora tutta da fare.

---

## 3. Richiesta — avvisare il coordinatore a fine sessione

Ho aggiunto al coordinatore la funzione che inoltra al back office l'evento di sessione chiusa:

```erlang
vs_coord_srv:session_closed({session_closed, SessionId, UserId, StationId, ConnId,
                             EnergyKwh, OverstaySeconds, StartedAt, EndedAt}).
%% StartedAt / EndedAt in secondi epoch
```

Ti chiederei di chiamarla dopo l'INSERT su `sessions`, passando l'id che MySQL ti restituisce.
Il coordinatore la gira a Java senza toccarla.

**Perché "dopo l'INSERT" e non prima**: se l'evento arriva prima che la riga sia committata, io
cerco una sessione che non c'è ancora. Non è grave (vedi sotto), ma è inutile.

**Perché non ti blocca.** Il back office **non usa il contenuto dell'evento**: lo tratta solo
come una sveglia. Il calcolo del costo legge le righe con `cost_cents IS NULL` direttamente da
MySQL, con uno sweep periodico ogni 60 secondi. Se l'evento non arriva mai — o se Tomcat è
spento nel momento in cui parte — la sessione viene prezzata al giro successivo.

Questa non è pigrizia: `{Mbox, Node} ! Msg` verso una mailbox assente viene **scartato in
silenzio**, di proposito, così Tomcat giù non disturba il cluster. Se la fatturazione dipendesse
dalla consegna del messaggio, ogni riavvio del back office lascerebbe sessioni non fatturate per
sempre. La UPDATE è condizionata (`WHERE cost_cents IS NULL`), quindi un evento duplicato non
può far pagare due volte: consegna at-least-once sopra una scrittura idempotente.

Detto altrimenti: **l'evento rende la fatturazione tempestiva, non corretta.** La correttezza
sta nel database.

---

## 4. Se sei d'accordo

Il punto 3 aggiunge un messaggio stazione → coordinatore, che sta nel territorio di `claim.md`.
Apro io la PR mettendola insieme alle due modifiche già concordate e implementate da entrambi
(`GrantedAt` in `acquire`, rinnovo a cinque campi), così regolarizziamo tutto in un colpo solo.
Tu sei reviewer.

Del punto 2 basta una risposta a voce: lo scrivo io in `ws-chargepoint.md`, che è tuo, solo dopo
che me lo confermi.
