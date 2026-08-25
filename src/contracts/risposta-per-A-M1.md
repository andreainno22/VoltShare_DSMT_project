# VoltShare — risposta alla nota su M1 (da B)

Stato mio: `vs_coord` M1 è pronto — claim/renew/release, `station_up`/`station_stats`, sweep delle scadenze, `nodedown` che libera i claim della stazione caduta, e il ponte JInterface verso il back office. 22 test EUnit verdi su OTP 29. Il back office Java compila, login/registrazione e lobby ci sono, `station.jsp` è lo scheletro che ti aspetta con `TOKEN`/`WS_URL`/`STATION`.

Ma prima di tutto il resto, una cosa che va chiusa subito.

---

## 1. Ho toccato claim.md senza PR, e adesso i nostri due lati non si parlano

Rispondendo alla tua §3: **sì, mi serve `GrantedAt` nel payload di `renew`** — e ho fatto la modifica a `claim.md` mentre implementavo il rebuild, senza aprire la PR come invece prevede la regola che ci siamo dati. Colpa mia, la sistemiamo formalmente con la PR di cui sotto.

Il problema pratico è che il disallineamento è già operativo:

- la tua stazione manda `{renew, StationId, [{ClaimId, VehicleId, ConnId}]}` — 3 elementi;
- il mio `vs_coord_srv` fa match su `{ClaimId, VehicleId, ConnId, GrantedAt}` — 4.

Con la 3-tupla saltava `function_clause` dentro `handle_call`: il coordinatore **crashava**, il supervisore lo riavviava e i claim in memoria se ne andavano. Non una risposta di errore: il nodo che muore, su un messaggio che arriva ogni dieci secondi.

**L'ho già chiuso da parte mia: il coordinatore ora accetta entrambe le forme.** La 3-tupla viene trattata come la 4 con `GrantedAt` preso dall'orologio del coordinatore, e viene loggato un `notice` per rinnovo (non per claim, altrimenti annegherebbe il log). Quindi **non devi correre ad adeguare la stazione**: l'integrazione parte comunque, e il codice è su `b/m1-coordinator`.

Il degrado, per essere chiari su cosa perdiamo nel frattempo: un claim adottato in forma vecchia risulta appena nato, quindi in un conflitto perde contro un claim che il coordinatore già conosce. È la direzione prudente — preferisce ciò che sa — ma non è la regola che abbiamo scritto, ed è il motivo per cui la PR serve lo stesso.

## 2. La proposta completa: due modifiche, una PR

Mentre ci siamo, c'è un secondo buco più sottile nello stesso punto.

Tu salvi come `GrantedAt` **l'ora locale della stazione** al momento della concessione. Io registro `granted_at` con **l'orologio del coordinatore**, e non te lo comunico: la risposta di `acquire` è `{ok, ReqId, ClaimId, ExpiresAt}`. Quindi oggi i due lati hanno due valori diversi per la stessa cosa, e la regola "oldest wins" finirebbe per confrontare timestamp prodotti da orologi diversi. In caso di conflitto fra due stazioni, chi vince dipenderebbe dallo skew fra le loro macchine — cioè da qualcosa su cui non abbiamo garanzie (e su cui il corso è esplicito: niente clock globale).

Propongo di far generare **tutti** i `GrantedAt` al coordinatore:

```erlang
%% acquire — il coordinatore restituisce anche il timestamp che ha registrato
{claim, ReqId, VehicleId, UserId, StationId, ConnId}
   → {ok, ReqId, ClaimId, GrantedAt, ExpiresAt}      %% era {ok, ReqId, ClaimId, ExpiresAt}

%% renew — la stazione restituisce quel timestamp, non uno suo
{renew, StationId, [{ClaimId, VehicleId, ConnId, GrantedAt}]}
```

Così la stazione non deve mai inventare un timestamp: lo riceve, lo conserva, lo ripete in `renew` e in `who_do_you_hold`. L'ordinamento resta deciso da un solo orologio anche dopo un failover, ed è una proprietà che possiamo difendere alla presentazione invece di doverla giustificare.

Se sei d'accordo apro io la PR su `claim.md` con le due modifiche (§3.1 e §3.2) e ti metto reviewer; il mio codice è già allineato alla seconda, adeguo la prima nello stesso commit. Se preferisci un'altra strada — per esempio lasciare `GrantedAt` alla stazione e non toccare `acquire` — dimmelo, ma allora mettiamo nero su bianco nel contratto che il confronto dipende dagli orologi delle stazioni, perché è un limite da dichiarare.

## 3. `station_stats`: sì, servono, appena puoi

Le usa la lobby. `StationsServlet` legge la mia `StationDirectory`, che si alimenta solo dai tuoi messaggi, e la pagina mostra le colonne *free / held / charging* per stazione.

Senza `station_stats` i contatori restano quelli dell'ultimo `station_up`, dove metto `free = length(Connectors)` e gli altri a zero: la lobby direbbe "tutti i connettori liberi" anche con una prenotazione in corso. Non è bloccante per M1, ma è la prima cosa che si nota aprendo la pagina.

Nota di implementazione dalla mia parte: un `station_up` ripetuto **non** azzera i contatori. Li preservo apposta (`keep_counters/2`), altrimenti ogni ri-annuncio a 30 s farebbe lampeggiare la lobby su "tutto libero".

## 4. Framing: confermo, siamo già allineati

La tabella della tua §1 è esattamente quello che il mio coordinatore implementa:

| Messaggio | Lato mio |
|---|---|
| `{claim, ...}`, `{renew, ...}` | `handle_call` |
| `{release, ...}`, `{station_up, ...}`, `{station_stats, ...}` | `handle_cast` |
| messaggi dal back office (`{From, get_stations}`, `user_suspended`, …) | `handle_info` — JInterface manda plain, non `call` |

`who_do_you_hold` non è ancora implementato: il rebuild è M3. Il framing che indichi — plain message a `vs_claim_client`, risposta plain a `From` — **l'ho già scritto in `claim.md` §3.4**, con la motivazione: un leader in ricostruzione parla con più stazioni insieme e non deve bloccarsi su nessuna. È l'unica cosa che ho messo nel contratto senza chiedertelo, perché registra ciò che hai già implementato invece di cambiarlo; se non ti torna, si toglie.

Confermo anche il resto: `not_serving` con redirect, `{error, _, unknown_station}` se la stazione non si è ancora annunciata (mi serve l'annuncio prima di concedere), e la 4-tupla `{renewed, Ok, Revoked, NewExpiresAt}` come risposta. Hai ragione su `piano.md` §4.1: **corretto**, e ho aggiunto in testa al blocco la riga "riepilogo, non fonte — fa fede `contracts/claim.md`", così non ricapita che due documenti si contraddicano.

## 5. Un dettaglio sul rebuild che ti riguarda

Nell'adozione di un claim sconosciuto io non ho lo `UserId` — il payload di `renew` non lo porta — e per ora lo metto a `0`. Non è un problema per l'esclusione, che lavora sul veicolo, ma lo diventa per le sospensioni: un utente sospeso con un claim adottato non verrebbe riconosciuto.

Due modi: o aggiungiamo `UserId` alla tupla di `renew` (cinque campi, tanto la stiamo già cambiando), oppure lo lascio a zero e me lo riprendo con `who_do_you_hold`, che lo porta già. La seconda mi sembra sufficiente per M3; se pensi che convenga la prima, la infiliamo nella stessa PR.

## 6. Toolchain

Ho Erlang/OTP 29 e rebar3 3.27 in locale, quindi siamo allineati; per i test uso anche `erlang:29-alpine` come suggerisci, così non mi scopro divergente per un warning. Grazie per aver dichiarato la versione: con `warnings_as_errors` è il tipo di cosa che fa perdere un pomeriggio a capire perché "a me compila".

## 7. Prossimo passo

Appena chiudiamo il punto 2 sostituiamo `coord1` col `vs_coord` vero — stesso hostname e stesso nome nodo, come dici — e proviamo la prenotazione dal browser end-to-end. La lobby e la pagina stazione sono pronte a riceverti.
