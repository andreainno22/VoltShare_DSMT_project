# Review di B — passata completa sul progetto

**Da B, 2 settembre.** Non un diff: tutto `src/` a `78aa01c`. Tredici rilievi, verificati uno per
uno aprendo il codice. Sette sono nel tuo perimetro e stanno qui; sei erano miei e li ho già
corretti (in fondo la lista, perché due ti riguardano indirettamente).

---

## A1 — `idle_timeout` senza clamp: la stessa famiglia di B1

`vs_cp_ws.erl:180`

```erlang
(vs_env:get_int("CP_HEARTBEAT_MISSED", 3) - 1) * IntervalMs
```

`CP_HEARTBEAT_MISSED=1` dà **0**, e cowboy chiude ogni socket colonnina appena diventa inattivo:
nessuna apparecchiatura resta collegata, nessuna sessione viene misurata. `=0` dà **-30000**, un
tempo negativo passato a un timer.

`vs_env:get_int/2` torna al default solo su `badarg`, quindi entrambi passano — è esattamente il
meccanismo di B1, la grace negativa che avevo segnalato e che hai chiuso con `max(0, …)` in
`vs_connector:init/1`. Lì il clamp c'è su tutte e tre le durate; qui non è mai arrivato.

Non lo chiamo grave come B1 solo perché il default è 3 e nessuno lo tocca. Ma è lo stesso difetto,
e vale la pena chiuderlo con la stessa riga.

## A2 — `release/2` è una `call` sincrona dentro il gen_statem, contro la sua stessa @doc

`vs_claim_client.erl:162`. La documentazione due righe sopra dice:

> *Best-effort by contract (§5.6): the claim expires on its own, so the remote cast is spawned and
> forgotten.*

Ma è **spawnato solo l'hop verso il coordinatore**. L'hop locale è una `gen_server:call` con il
timeout implicito di 5000 ms, e la chiamano `vs_connector:settle/1` e le clausole `cancel` e
scadenza-lease di `held/3` — tutte da dentro la macchina a stati.

Se il claim client è occupato o sta ripartendo, il connettore resta in `closing` per cinque
secondi. E nel frattempo la `snapshot` che `vs_station_mgr:reallocate` gli manda va anch'essa in
timeout, `connector_entry/1` lo segna `offline`, e quel connettore **esce dal riparto della
potenza**: un outlet fisico bloccato e una quota redistribuita per un motivo che non esiste.

La @doc descrive il comportamento giusto. È il codice a non seguirla.

## A3 — l'ETS del manager non è protetta come quella del claim client

`vs_station_mgr.erl:228` fa un `ets:new/2` nudo. `vs_claim_client:init_reach_table/0`
(righe 900-911) documenta **questa identica corsa**:

> *a dying process gives up its registered name at a slightly different moment from its ETS tables*

e la gestisce cancellando e ricreando. Il manager no: se crasha e il supervisore lo riavvia dentro
quella finestra, `init/1` solleva `badarg`, si consuma uno dei cinque restart di
`intensity=5/period=10`, e una tempesta di restart porta giù `vs_station_sup` — **e con lui tutti i
connettori**, che è precisamente ciò che l'autonomia della stazione di SCOPE §4 esiste per evitare.

Indizio che la corsa è reale: la fixture dei test deve già aspettare su `ets:info/1` per aggirarla.

## A4 — 2N chiamate sincrone per evento, e S×N per tick

`vs_station_mgr.erl:367`. `handle_info({connector_event, …})` chiama `reallocate/1` — che fa
`connector_entries/1`, una `gen_statem:call` per connettore — e **poi** `broadcast/1` →
`build_state/1` → `connector_entries/1` di nuovo. Due passate complete per evento, e una carica che
finisce ne genera due di eventi (`charge_complete`, poi `state_changed` da `complete(enter)`):
**4N chiamate**.

In parallelo ogni `vs_driver_ws` sul suo `state_tick` chiama `vs_station_mgr:station_state/0`, che
rifà la stessa passata: **S pagine aperte × N connettori**, serializzate nel processo del manager.

Il generatore di carico di SCOPE §7 guida esattamente questa moltiplicazione. Il risultato di
`build_state/1` è identico per tutti i socket dentro un tick: calcolarlo una volta e spingerlo
toglierebbe il fattore S.

## A5 — `cp.js`: il backoff si azzera a ogni `onopen`

`src/emulator/cp.js:185`. `onAck` gestisce `accepted: false` chiudendo il socket, col commento
*"§3.1: the charge point closes and retries with backoff"*. `onClose` programma il retry con
`backoffMs` e lo raddoppia — ma il prossimo `onopen` scatta comunque, perché **la connessione TCP
riesce: è il `boot` a essere rifiutato**, e rimette `backoffMs` a 1000.

Un connettore configurato male (`unknown_connector`) viene martellato con un ciclo completo
connect+boot al secondo, per sempre.

## A6 — `ws.js`: una chiamata fallita resta in `pending`

`js/ws.js:181`. `transmit()` rifiuta la promise senza rimuovere la voce dalla mappa: se
`onTimeout` ritenta e nel frattempo il socket si è chiuso, si prende il ramo `!OPEN` → `fail()`,
che azzera il timer e rifiuta ma **non cancella la voce inserita prima**. `failAll` sul prossimo
`onClose` ri-rifiuta una promise già rifiutata (innocuo) e ripulisce la mappa per caso; una
chiamata fallita così fra due chiusure resta, e un ack tardivo per quel `request_id` finisce in
`settle()` su una promise già risolta.

## A7 — i tre `const` nelle pagine live non sono escapati per JavaScript

`station.jsp:23-25` e `session.jsp:28-30`:

```jsp
const WS_URL  = '${station.wsUrl}';
```

Il valore **non è una costante di pagina**: viene dalla variabile d'ambiente `WS_URL` di un nodo
stazione, passa per l'annuncio `station_up`, il coordinatore e `StationDirectory`. Una stazione che
si annunciasse con `ws://h/ws/driver';alert(document.cookie);//` eseguirebbe script nella pagina di
ogni conducente. La stessa JSP usa `<c:out>` per `station.name` alla riga 83, ma non qui.

**Severità reale bassa**: per sfruttarlo bisogna già controllare la configurazione di un nodo del
cluster, cioè essere dentro. Ma il rimedio è economico — mettere i tre valori in attributi `data-`
su un elemento, passati per `<c:out>`, e leggerli da `ws.js` — e toglie una classe di problema
invece di un'istanza.

Il blocco `<script>` con le tre costanti è il pezzo che B garantisce (`jwt.md` §2), quindi se
preferisci lo cambio io: dimmelo, perché il file è tuo e non voglio riscriverti la pagina.

---

## Quello che ho corretto io, e due cose che ti toccano

Sei rilievi erano miei. Due meritano che tu li sappia:

**Il worker di rebuild uccideva il coordinatore.** `vs_coord_rebuild:run/1` faceva `spawn_link`, e
`vs_coord_srv` non fa trap_exit: una qualunque eccezione nel worker — per esempio un `{holds, …}`
malformato da un qualunque nodo — avrebbe ucciso **il processo che tiene tutti i claim della
rete**, e `rest_for_one` avrebbe portato giù l'intero sottoalbero del coordinatore. È lo stesso
guasto che il catch-all in `renew_one/4` esiste per prevenire, reintrodotto due milestone dopo da
una parola. Ora è `spawn_monitor`.

**E `rebuilding` non aveva uscita.** L'unica via era il messaggio `{rebuilt, _}`: se il worker
moriva prima di mandarlo, il coordinatore rifiutava **ogni prenotazione della rete, per sempre**,
senza niente nei log a dirlo. Ora c'è il `DOWN` del monitor e una deadline di sicurezza; in
entrambi i casi si passa a `serving` con un warning, perché i rinnovi adottano comunque entro dieci
secondi e restare bloccati è strettamente peggio.

Ti riguardano perché il primo rendeva fatale un messaggio che **le tue stazioni** mandano, e il
secondo produceva un `RETRY_LATER` permanente sul **tuo** canale driver — due sintomi che
sarebbero sembrati colpa tua.

Gli altri quattro miei, per completezza: XSS stored nello username reso senza `<c:out>` in
`page.tag` (chiunque poteva registrarsi come `<img src=x onerror=…>`, e quel tag rende su **ogni**
pagina autenticata); e tutto il percorso delle sospensioni che leggeva e scriveva con l'orologio
della JVM mentre `sessions` è in UTC — ora è UTC ovunque, una convenzione sola per tutto il
database.

**Una cosa tua che ho solo annotato**: `vs_claim_client:init/1` ha come default di `COORD_NODES`
`['coord1@coord1', 'coord2@coord2', 'coord3@coord3']`, che è la nomenclatura di prima del 25/08 —
oggi i nodi sono `vs@coordN`. Il compose imposta sempre la variabile, quindi non morde mai; ma è un
default che non porta da nessuna parte.

**Stato**: `eunit_check.sh` verde a 386, Java 14 test verdi.

— B
