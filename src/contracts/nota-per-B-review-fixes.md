# Nota per B — cosa farà il pair delle sei correzioni, prima che lo lanci

*Da A, 3 settembre. Accompagna `risposta-per-B-review-progetto.md`. Il pair è scritto e **non
lanciato**: parte domani, dopo la prova generale di oggi e prima del congelamento. Te lo
anticipo perché due decisioni dentro toccano cose che leggi anche tu, e preferisco sentirti
prima di scrivere codice, non dopo.*

## Cosa cambia, in una riga per voce

| | Dove | Cosa | Ti tocca? |
|---|---|---|---|
| A1 | `vs_cp_proto`, `vs_cp_ws`, `vs_connector:cp_grace_ms/0` | due helper esportati, `heartbeat_interval_s()` = `max(1, env)` e `heartbeat_missed()` = `max(2, env)`; i **tre** lettori del valore passano da lì | **sì**, vedi sotto |
| A2 | `vs_claim_client:release/2` | da `gen_server:call` a `gen_server:cast`; la clausola si sposta con lo stesso corpo | no — `claim.md` §5.6 dice già best-effort, il codice si allinea al contratto |
| A3 | `vs_station_mgr:init/1` | tabella `public` + `try ets:new … catch badarg -> delete, new`, lo schema del claim client | **sì**, vedi sotto |
| A5 | `cp.js` | `backoffMs = 1000` si sposta da `onOpen` al boot **accettato** | no |
| A6 | `ws.js` | `pending.delete(call.id)` dentro `fail()` | no |
| — | `vs_claim_client:init/1` | default `COORD_NODES` → `vs@coordN` | no |

Suite da 392 a **395 o 396** (uno o due test per A1, dichiarato prima di lanciare), due test
mostrati **rossi prima** del fix (A2 e A3). Branch `a/review-progetto-fixes` da `a/p18-nodeup`,
PR verso `main` dopo il merge di entrambe le nostre PR di oggi.

## Le due decisioni su cui voglio il tuo parere

**1. I pavimenti di A1 stanno sui due ingressi, non sul prodotto.** `MISSED ≥ 2`, `INTERVAL ≥ 1`,
quindi idle ≥ un intervallo. Motivo: ho letto cowboy 2.18 nel `_build` — `start_timer(Timeout
div 10, …)`, dieci tick — quindi `0` è chiusura immediata (come dici tu) e **`−30000` è `badarg`
all'upgrade**: non «un tempo negativo a un timer», ma ogni colonnina che non riesce nemmeno a
collegarsi. `max(0, …)` da solo lascia lo `0`. Un intervallo è la quantità più piccola che
tiene in piedi «heartbeat → silenzio → chiusura», e mantiene vera l'identità
`idle + grace = MISSED × INTERVAL` sui valori clampati, che è ciò che il test esistente asserisce.
L'alternativa era un pavimento fisso in ms: scartata perché «un intervallo» ha un significato nel
contratto e un numero no. **I due pavimenti finiscono in `ws-chargepoint.md` §10**, accanto alle
variabili — è nostro, non serve PR, ma lo leggi tu quando scrivi il compose: se preferisci
valori diversi, dimmelo prima.

**2. La tabella del manager diventa `public`.** Non è cosmetico: `ets:delete` su una tabella
`protected` di un altro processo è `badarg`, e il proprietario è proprio quello che sta morendo.
È esattamente il motivo per cui la tabella di raggiungibilità del claim client è `public`.
Nessun altro processo scrive su `vs_station_conns` oggi (cercato per struttura), quindi non apre
niente che sia chiuso. Se vedi un lettore che non ho visto, dimmelo.

## Cosa il pair **non** fa, e perché

- **A4** (S×N chiamate per tick): una riga in `scelte_di_progetto.md` come limite dichiarato.
  Vero, misurabile, non un difetto da chiudere prima della consegna.
- **A7**: tuo, pagina e `ws.js` insieme — come nella risposta.
- **`warnings_as_errors` su `apps/`**: pair separato, da fare partendo da un `rebar3 compile`
  pulito e guardando cosa si rompe. **Chi lo fa** lo decidiamo quando ci sentiamo: è il build di
  tutti e due.

## Per quando ci sentiamo

1. Pavimenti `2` e `1`: vanno bene, o vuoi altri numeri?
2. `public` sul manager: obiezioni?
3. A7: lo fai nella tua PR attuale o in una dopo?
4. Il pair di `warnings_as_errors`: chi, e quando.
5. Il tuo §7zk → §7zn dopo il rebase: confermi?

— A
