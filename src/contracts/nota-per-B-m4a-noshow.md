# Nota per B — il verso mancante di §2.4 ora c'è (M4-A, 31 agosto)

Breve, e non chiede niente: è un avviso di stato su un contratto che **non cambia**.

## Cosa è cambiato

Da oggi la stazione manda davvero i due messaggi di `erlang-java.md` §2.4, nelle forme già
concordate e che il tuo lato già accetta:

- `{no_show, UserId, StationId, ConnId}` — alla scadenza del lease di una prenotazione;
- `{show_up, UserId}` — quando il cavo entra su una prenotazione onorata.

Escono da `vs_claim_client` con `cast_leader/2`, la stessa strada di `session_closed`, e
atterrano su `vs_coord_srv` → `vs_coord_bo:penalty_event/1` → il tuo bridge. **Nessun file
condiviso è stato toccato**: né `erlang-java.md`, né `claim.md`, né `schema.sql`, e niente sotto
`src/backoffice/` o `src/erlang/apps/vs_coord/`. Il tuo lato era già completo da M4-B e non
richiede modifiche.

Branch `a/m4-noshow` (da `a/m4-overstay`). La riga «declared, not yet implemented» accanto a
§2.4 di `erlang-java.md` va tolta — ma in una PR, perché il file è condiviso: la mettiamo lì,
non qui.

## Con quale garanzia, e perché è diversa da `session_closed`

**At-most-once, deliberatamente.** Nessuna coda, nessun retry: se il leader non è raggiungibile
nell'istante del cast, lo strike è perso e nessun messaggio successivo lo ripara.

Non è un ripiego, è la garanzia che corrisponde alla scrittura a valle. `session_closed` è
at-least-once perché sveglia uno sweep che rilegge una riga già in MySQL: un duplicato costa uno
sweep anticipato. Un `no_show` invece atterra su
`UPDATE users SET no_show_count = no_show_count + 1` e non ha nessuna riga da rileggere — quel
messaggio *è* la registrazione del fatto. Quindi:

- uno **perso** = uno strike non contato, la sospensione arriva una prenotazione più tardi;
- uno **duplicato** = un account sospeso per un giorno dopo **una** sola prenotazione mancata,
  senza niente in database che spieghi perché.

Fra i due, il secondo è il danno peggiore, e la coda che eviterebbe il primo è esattamente la
cosa che causerebbe il secondo al primo failover.

**Il tuo gate va nello stesso verso, e ci siamo appoggiati.** `vs_coord_bo.erl:144-155` inoltra
solo mentre quel coordinatore serve, «relaying it from two coordinators at once would count one
no-show twice — Java's counter has no way to tell the duplicates apart». L'abbiamo letto per
intero prima di scegliere: protegge il salto coordinatore→Java durante un handover, e non
deduplica (né potrebbe) due messaggi mandati dalla stessa stazione. Quindi la stazione è
l'ultimo punto in cui il duplicato si può non creare, ed è lì che lo evitiamo. **Nessuno dei due
lati deduplica; tutti e due evitano di duplicare** — vale la pena dirlo così, perché è la
proprietà che tiene.

Ricadute per te: **nessuna**, se non che il contatore ora si muove.

## Da dove partono, esattamente

- `no_show` **solo** dalla scadenza del lease. Non da un `cancel` (il conducente ha mantenuto la
  parola in anticipo), non da un `revoke` (la finestra l'ha chiusa il coordinatore — anche per un
  failover o per un oldest-wins), non da una colonnina che smette di rispondere (guasto nostro).
- `show_up` **solo** dal `plugged` accettato su una prenotazione. **Non dal walk-in**: SCOPE §3.3
  lascia apposta caricare senza prenotare a un account sospeso, e se il walk-in azzerasse il
  contatore la sospensione verrebbe annullata proprio da ciò che continua a concedere.

Quattro test negativi inchiodano le uscite che devono tacere.

## Due cose misurate che ti riguardano

1. **`suspendUntil` azzera `no_show_count`** (`UserDao.java:178-185`), quindi dopo due strike la
   colonna è `0` e non `2`. È giusto ed è il tuo commento a dirlo («the penalty has been served on
   it») — lo scriviamo qui solo perché il nostro piano si aspettava `2` e chi legge la demo
   potrebbe fare lo stesso errore. La prova che i due strike ci sono stati è `suspended_until` più
   le righe in `notifications`.
2. **La sospensione arriva al coordinatore in catena sincrona** col secondo strike
   (`onNoShow` → `suspend()` → `notifySuspension`), quindi in millisecondi: nell'E2E il terzo
   `reserve` è stato rifiutato `SUSPENDED` nello stesso secondo in cui la riga è stata scritta.
   Nessun intervallo da aspettare, e la tua nota su `pushAllSuspensions` copre il caso in cui quel
   messaggio si perde.

E2E completo, su un database solo (il mio): due scadenze → sospeso e terzo `reserve` rifiutato
`SUSPENDED`; scadenza → arrivo onorato → scadenza → contatore a 1 e **nessuna** sospensione.

## Cosa NON è ancora chiuso, e resta tuo

`{notify, UserId, Kind, Text}` — R2 della review della PR #5. `vs_coord_srv` non ha ancora la
clausola, quindi la nostra cast cadrà nel catch-all e la notifica non arriverà mai in tabella.
La patch pronta è in `DA_DIRE_A_B.md` §1 (R2), due clausole in due file. Finché non c'è, il
frame `notification` di `ws-driver.md` §5.3 resta fuori dal nostro perimetro.
