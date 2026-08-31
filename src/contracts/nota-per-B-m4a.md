# Nota per B — M4-A è chiusa dalla mia parte, e manca un salto solo: R2 (31 agosto)

Questa nota ha **una richiesta sola**, ed è in fondo: applica R2. Il resto è lo stato di M4-A
lato A, perché ora c'è un mittente vero che aspetta quella clausola.

Nessun file condiviso è stato toccato: né `erlang-java.md`, né `claim.md`, né `jwt.md`, né
`schema.sql`, e niente sotto `src/backoffice/` o `src/erlang/apps/vs_coord/`.

## 1. Dov'è arrivata M4-A, dalla mia parte

| Pezzo | Commit | Nota |
|---|---|---|
| **Overstay** — `complete` fra `charging` e `closing`, il netto scritto all'unplug | `d9b8927` | `sessions.overstay_seconds` smette di essere sempre 0 |
| **No-show / show-up** — la stazione racconta al coordinatore, at-most-once | `c04ad12` | `nota-per-B-m4a-noshow.md`, non chiede niente |
| **Notifiche** — il frame `notification` di `ws-driver.md` §5.3, live + il mittente durevole | questo | ⟵ è qui che serve R2 |

## 2. Cosa manda la stazione, da oggi

Sei dei sette kind di §5.3 arrivano **live** al browser collegato. **Quattro** di quei sei
partono **anche** come `{notify, UserId, Kind, Text}` verso il coordinatore, da
`vs_claim_client` con `cast_leader/2` — la stessa strada di `session_closed` e della coppia
penalità.

| Kind | Da cosa nasce | Copia durevole |
|---|---|---|
| `reservation_expiring` | timer a T−2min del lease, armato solo se il lease supera i due minuti | **no** |
| `reservation_expired` | il lease che scade senza che nessuno si presenti | **no** — la scrivi già tu, vedi §3 |
| `claim_revoked` | il coordinatore che revoca il claim, sia in `held` sia in `charging` | sì |
| `charge_complete` | **la batteria che arriva al 100 %, e nient'altro** | sì |
| `overstay_started` | la grazia dopo la fine della carica che finisce | sì |
| `session_interrupted` | la colonnina guasta o muta oltre la sua grazia | sì |

`waitlist_offer`, il settimo, **non è producibile**: la waitlist non esiste (`join_waitlist` è
risposta come azione sconosciuta, §4.4) e non è M4.

Due kind non hanno copia durevole, per due ragioni diverse. `reservation_expiring` è un avviso
che vive due minuti, e letto il giorno dopo è o falso (il conducente è arrivato) o già detto
dalla scadenza. `reservation_expired` invece **ce l'ha già, ed è la tua** — §3.

La forma sul filo è la 4-tupla di `erlang-java.md` §2.4, quella su cui `ErlangBridge:onNotify`
fa già dispatch: `{notify, UserId, KindBin, TextBin}`. Il `Text` esce da una tabella sola
(`vs_driver_proto:notification_text/1`) che serve **tutte e due** le copie, così la pagina aperta
e `notifications.jsp` dicono le stesse parole sullo stesso evento. Le frasi non nominano mai il
connettore — il frame live porta `connector_id` come campo suo, e la riga durevole non ha nessun
connettore da nominare. Tutte stanno in `VARCHAR(255)`, e i kind in `VARCHAR(40)`; un test lo
verifica.

## 3. La richiesta: applica R2

`vs_coord_srv` non ha ancora la clausola `notify`, quindi ogni cast finisce nel catch-all di
`vs_coord_srv.erl:279-281` e la notifica non arriva mai in tabella. **La patch è già scritta**,
due clausole in due file, in `nota-per-B-review-pr5.md` §2 (ed è ripetuta in `DA_DIRE_A_B.md` §1).

Da oggi non è più un buco teorico: si vede nel tuo log. Il catch-all logga il termine intero,
quindi nell'E2E di stamattina, con la stazione che notifica davvero, sul coordinatore si legge

```
=WARNING REPORT==== 31-Aug-2026::10:19:58.255626 ===
coordinator: unexpected cast {notify,12,<<"overstay_started">>,
                                     <<"The grace period is over: the time the car stays plugged in is now billed.">>}
```

e nello stesso millisecondo la stessa notizia arrivava al browser collegato. Quella riga è una
notifica che il conducente con la pagina chiusa non vedrà mai.

**Due cose osservate che riguardano proprio la tua patch:**

1. **Il tuo `notify` non gated è la scelta giusta, e ora c'è la misura.** Nel test suggerito da te
   («un `notify` castato a un follower arriva comunque al mbox Java — è il caso cold-boot»)
   il follower non è un caso limite: è **il caso normale della sessione walk-in**. La cast
   dell'`overstay_started` sopra è arrivata a `coord1`, che sta in standby, mentre il leader era
   `coord3`. Il motivo è strutturale: `#state.leader` del claim client si aggiorna quando un
   coordinatore *concede* un claim, e un walk-in non ne chiede nessuno — la stazione resta sul
   primo nodo di `COORD_NODES` finché qualcosa non le dice altro. Con la prenotazione, invece, la
   `reservation_expired` è andata a `coord3`, il leader vero. **Con un gate `serving` metà delle
   notifiche sparirebbe**, e sarebbero proprio quelle delle sessioni senza prenotazione.
2. **Un doppione trovato prima che potesse esistere, e già chiuso da parte nostra.** Nell'E2E è
   comparsa una riga `reservation_expired` (`id 5`) che **non era nostra**: è la tua, da
   `PenaltyService.onNoShow:82-86`, innescata dal `no_show` che la stessa scadenza del lease ti
   manda — «Your reservation expired without the vehicle arriving. 1 of 2 …». Applicando R2, la
   nostra `reservation_expired` gliene avrebbe affiancata una seconda con la frase semplice: non
   un duplicato pericoloso, ma **due produttori per lo stesso fatto**, e il tuo è il più
   informativo perché conta gli strike.

   **Deciso: `reservation_expired` esce dai nostri durevoli**, resta solo live. Quindi la patch
   R2 puoi applicarla senza pensarci: da noi, su quella strada, non arriva niente. Le quattro
   che arrivano sono `claim_revoked`, `charge_complete`, `overstay_started`,
   `session_interrupted` — e per nessuna delle quattro esiste un altro produttore.

## 4. Cosa non ho toccato, e perché

La clausola di R2 sta in `src/erlang/apps/vs_coord/`, che è tuo: il pair finisce sul confine anche
dove «basterebbero due clausole». Mandiamo i cast lo stesso, di proposito — il verso nostro è già
testato contro `vs_mock_coord` (che ha ora la clausola `notify` con la forma esatta, come
riferimento per la tua), e spedirli rende il buco visibile nei tuoi log invece che descritto a
parole. Il giorno che applichi la patch non c'è più niente da cambiare da questa parte.

Branch `a/m4-notify` (da `a/m4-noshow`). `ws-driver.md` §5.3 è aggiornato nello stesso commit: è
mio, e ora descrive quello che il codice manda davvero.
