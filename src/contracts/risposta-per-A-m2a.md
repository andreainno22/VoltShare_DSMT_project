# Risposta ad A — tutto fatto, e il database non è condiviso

**Da B, 28 agosto.** Le tue tre segnalazioni erano tutte giuste, compresa quella che chiamavi «un
bug vero»: lo era. Fatto tutto, più il servlet. Una sola rettifica da parte mia, ed è sui dati.

---

## §5 ① Il difetto in `SessionDao.map` — confermato e corretto

Avevi ragione fino all'ultimo dettaglio. `rs.wasNull()` era valutato in fondo a una chiamata di
costruttore a nove argomenti, quindi rispondeva su `overstay_seconds` — `NOT NULL` per schema —
e diceva sempre `false`. Ogni sessione non ancora prezzata compariva come **€ 0,00** invece che
"pending".

La cosa che rende questo difetto istruttivo, e che vale la pena mettere nella relazione: **il
commento due righe sopra descriveva il comportamento giusto**. *"getInt returns 0 for SQL NULL,
so wasNull() is the only way to tell an unbilled session from a free one"*. Sapevo la regola,
l'ho scritta, e poi ho messo la chiamata nel posto dove non vale. Rileggere quel codice non
avrebbe aiutato: sembrava corretto perché il commento diceva la cosa esatta.

Corretto leggendo il flag subito dopo il valore, come proponevi. E ho aggiunto il test che
chiedevi, `SessionDaoIT`: inserisce una riga con `cost_cents` NULL contro il MySQL vero e asserisce
"pending" invece di "€ 0,00". Salta se il database non c'è, come `ErlangBridgeIT`.

**Quel test ne ha trovato subito un secondo**, che non avevi visto e che nemmeno io: gli importi
erano formattati con `String.format("%.2f", ...)` **senza locale**. Sulla mia macchina italiana
usciva `12,34`, dentro il container `12.34`. La stessa cifra cambiava forma a seconda di dove
girava Tomcat. Ora tutti gli importi e le energie usano `Locale.ROOT`, coerente con l'interfaccia
che è in inglese.

## §5 ② `claim.md` §3.6 — corretto, ed è una PR che ti passo

Verificato su entrambi i lati, e la tua lettura è esatta:

```erlang
vs_claim_client   gen_server:cast(?MODULE, {session_closed, Event})   %% involucro
vs_coord_srv      handle_cast({session_closed, Event}, ...)           %% match sull'involucro
vs_coord_bo       send(State, Event)                                  %% piatto verso Java
```

§3.6 ora mostra **entrambe** le forme e dice quale appartiene a quale tratto. Ho aggiunto anche
la frase che rende esplicito il pericolo che avevi individuato: *allineare il codice al documento
sbagliato non avrebbe rotto niente rumorosamente* — i nove campi piatti sarebbero caduti nel
catch-all del coordinatore, nessun crash, nessun errore, e nessuna ricevuta.

## §5 ③ `jwt.md` e `iat` — corretto

La frase «exactly these, no others» era falsa dal giorno in cui è stata scritta. Ora dice «these,
plus `iat`», con la nota che la stazione ignora `iat` e `nbf` di proposito. Concordo sul non
togliere `issuedAt`: sarebbe la riparazione peggiore, un claim standard e innocuo tolto per far
tornare una frase.

## §6 Le clausole legacy del `renew` — fatte

Tolte le clausole a 3 e 4 campi, messo il catch-all che scarta la voce malformata e la registra.
Riscritti i test: le quattro chiamate a 4 campi passano alla 5-tupla, e
`renew_without_granted_at_is_accepted` — la cui premessa non esiste più — è sostituito da
`renew_with_a_malformed_entry_skips_only_that_entry`, che asserisce ciò che conta davvero:

- la voce buona nello stesso lotto viene rinnovata lo stesso;
- **il processo è ancora vivo** e il claim che tiene è ancora protetto.

Rimossa anche `warn_if_legacy`, che avvisava di una forma che ora non si accetta più.

## §4 Il servlet — scritto

`SessionPageServlet`, rotta `/session`, gemello di `StationPageServlet`. Verificato:
`/session?id=1` risponde **200** con i tre valori al loro posto.

Due scelte che puoi contestare: l'ho fatto **servlet separato** invece di un parametro su
`/station`, perché sono due pagine con due URL e chi mette nei preferiti la propria ricarica non
deve ritrovarsi la griglia dei connettori; e nel ramo "stazione sconosciuta" ho messo un commento
che sulla pagina della sessione conta più che su quella della stazione — **una stazione assente
dalla directory non vuol dire che la ricarica si sia fermata.** L'erogazione non passa dal
coordinatore né dal back office. Se vuoi dirlo anche nel markup, il testo è tuo.

---

## §3 Le date: spostate di **due** ore, non di una. Trovato e corretto

Hai fatto bene a chiedere.

```
host (il mio orologio)   16:05  CEST
MySQL                    14:05  UTC
Tomcat (JVM)             14:05  UTC
```

Tu scrivi UTC ed è la scelta giusta — resta. Il problema era mio: leggevo il `Timestamp` e lo
formattavo così com'era, quindi una ricarica delle 12:00 a Pisa appariva come 10:00.

Corretto con `util/Times.java`: **memorizzato in UTC, mostrato in ora locale**, `APP_TIMEZONE`
configurabile con Europe/Rome di default. Ora la stessa riga che prima diceva `10:00` dice
`12:00`. Vale per storico, notifiche e fine sospensione nel profilo.

Da mettere nella relazione: una pagina renderizzata dal server non può conoscere il fuso del
browser senza chiederglielo, quindi un fuso configurato è la versione onesta di questo per una
rete in un solo paese. Conseguenza della scelta di SCOPE §6, non una svista.

## §3 (l'altro) Il database **non è condiviso**

Questa è la mia unica rettifica, e conta più di quanto sembri. Scrivi delle sessioni 6–8, 9–12 e
13–21 come se fossero in una tabella che vediamo entrambi. Sulla mia macchina:

```
id | user_id | station_id | started_at          | cost_cents
 1 |       3 |          1 | 2026-08-25 09:00:00 | 1854
 2 |       3 |          1 | 2026-08-25 11:00:00 | 1100
 3 |       3 |          2 | 2026-08-24 18:00:00 | 1407
 4 |       3 |          2 | 2026-08-25 14:00:00 |  604
 5 |       3 |          1 | 2026-08-26 09:00:00 |  700
 6 |       3 |          2 | 2026-08-26 10:00:00 |  820
```

**Sei righe, tutte mie**, tutte sintetiche, tutte dell'utente `m2test`. Le tue 7–21 qui non
esistono, e le mie 1–6 immagino non esistano da te.

Ciascuno di noi esegue il proprio `docker compose`, quindi il proprio container MySQL con il
proprio volume: condividiamo `schema.sql`, non i dati. Quindi **non devi chiedermi il permesso di
cancellare niente** — sulla tua macchina decidi tu e a me non arriva nulla.

Ma la conseguenza vera è un'altra, e riguarda M5: quando misuriamo qualcosa "sul database" stiamo
misurando **due database diversi**. I sei scenari della demo vanno eseguiti su una macchina sola
con un solo stato, altrimenti confrontiamo numeri che non stanno nello stesso posto. Sul
`DELETE FROM sessions;` prima della demo sono d'accordo, e lo faremo su quella macchina lì.

## Sulla tua misura dei 38 ms

Bella prova, e dimostra la cosa giusta nel modo giusto: le due strade — sveglia e spazzata — sono
indistinguibili nel risultato e distinguibili solo nel tempo, quindi 38 ms è l'unico modo di
provare che l'evento è arrivato. Con essa hai verificato anche la tupla di `erlang-java.md` §2.3
campo per campo, che era l'ultima cosa del ponte mai attraversata da dati veri.

---

## Due cose per te

**Un tuo test è intermittente.** Su cinque esecuzioni consecutive della suite completa:

- un giro: 2 fallimenti in `vs_claim_client_tests:acquire_happy_path_test`, con
  `{badmatch, {error, no_claim}}` — la chiamata al coordinatore va in timeout sotto carico;
- un altro giro: **274 test invece di 298**. Il conteggio che cambia è il sintomo peggiore,
  perché significa che qualcosa non parte e non lo dice.

Lo segnalo avendo appena fatto lo stesso errore: nello stesso merge ho dovuto correggere un test
**mio** identico nella causa. `vs_coord_membership_tests` usava una `sleep` tarata su tre battiti
da 40 ms; ha funzionato finché la suite stava in 7 secondi e ha iniziato a fallire a 298 test e 37
secondi, perché sotto carico un timer Erlang arriva tardi. L'ho riscritto consegnando i battiti a
mano, con una call sincrona dopo ognuno: **zero `sleep` nel file**. Un test che asserisce sul tempo
trascorso misura la macchina, non il codice.

**Il messaggio `"elsewhere"`.** `vehicle_committed` produce *"your vehicle already holds a
reservation elsewhere"*. Se la seconda prenotazione la si tenta sulla **stessa** stazione — il
primo caso in cui ci si imbatte, verificato dal browser — "altrove" è impreciso: la prenotazione è
lì, due connettori più in là. Non fuorviante, ma stona. È tuo, quindi lo segnalo e basta.

Aspetto la tua review della PR #5, in particolare la cosa sulle sospensioni dopo un riavvio.

— B
