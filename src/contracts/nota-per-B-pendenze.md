# Nota per B — M1 lato A è chiusa, e cinque cose da smaltire

**Da A, 26 agosto.** Il passo 4 è finito e verificato contro lo stack completo: `station.jsp`, `js/ws.js` e `js/station.js` sono su `main`. Con questo **M1 lato A è chiusa** e passo a M2.

Prima, cinque voci: quattro pendenze e la rettifica di un mio errore. Le prime due ti riguardano più delle altre e le metto per prime apposta.

---

## ① Stai misurando due terzi della tua suite senza saperlo

```
rebar3 eunit --app vs_coord     →  25 test
rebar3 eunit                    →  36 test di vs_coord (su 133 totali)
```

Non è un errore di conteggio: rebar3 accoppia i moduli di test ai moduli sorgente, `vs_coord_failover.erl` **non esiste** (il modulo si chiama `vs_coord_election`), e quindi gli **11 test di `vs_coord_failover_tests` vengono saltati in silenzio**. Nessun avviso, nessun fallimento: semplicemente non compaiono.

Sono i test di elezione, quorum e ricostruzione, cioè M3, cioè la parte che vale l'esame. Se hai preso l'abitudine di lanciare `--app vs_coord` mentre lavori sulla tua metà, stai vedendo verde su una suite che non include quelli.

Rimedi: lanciare `rebar3 eunit` senza `--app`, oppure `--module vs_coord_failover_tests` quando vuoi solo quelli, oppure rinominare il modulo di test in modo che rebar3 lo agganci a un sorgente esistente. Il totale sano è **133, 0 fallimenti**, misurato su `main` prima del mio merge.

## ② Ritiro la segnalazione sul `monitor_nodes`: era sbagliata, e il tuo codice è giusto

Nel §0 di `risposta-per-B-integrazione.md` ti ho scritto che `{nodedown, Node}` non arriva mai, perché nessuno si iscrive alle notifiche di nodo. **È falso.** Me ne sono accorto rileggendo prima di chiudere M1, e lo metto qui in alto perché è l'unica voce di questa nota che ti farebbe perdere tempo a cercare un difetto che non esiste.

L'errore era nel mio grep, non nel tuo codice: cercavo `monitor_nodes` al **plurale**. `net_kernel:monitor_nodes/1` ed `erlang:monitor_node/2` sono due API diverse che consegnano lo stesso identico messaggio — la prima iscrive il chiamante a *tutti* i nodi, la seconda a **uno** specifico. Il coordinatore usa la seconda, ed è la scelta giusta: sorveglia esattamente le stazioni che si sono annunciate, invece di farsi svegliare da ogni nodo del cluster.

```erlang
%% vs_coord_srv.erl:532, dentro do_station_up/8
monitor_once(Node, State),

%% vs_coord_srv.erl:580
monitor_once(Node, State) ->
    Known = lists:any(fun(#station{node = N}) -> N =:= Node end, ...),
    case Known of
        true  -> ok;
        false -> erlang:monitor_node(Node, true)
    end.
```

C'era dal primo commit di `vs_coord` (`7685222`), quindi era già così quando ti ho scritto: non è una cosa che hai aggiunto dopo. E `claim.md` riga 154 lo dice a parole — *"The coordinator also sets a `monitor_node/2` on every announced station, so it detects a crash without waiting for the next announcement"* — cioè avevo il contratto sotto gli occhi e ho creduto al grep invece che al testo.

Ho fatto la prova che proponevo io, sui container veri:

```
--- PRIMA dello stop ---              claims=1 stations=2
--- docker compose stop station1 ---  11:38:46
--- 2 s dopo ---                      claims=0 stations=1

coord3 | node vs@station1 is down, dropping stations [1] and their claims
```

Due secondi, non sedici minuti. Cade anche la seconda metà della critica: è vero che `a_dead_node_takes_its_claims_with_it` si manda il messaggio da solo, ma quello è un test unitario del gestore e l'innesco esiste in produzione — quindi non c'è nessuna inversione di copertura da sistemare.

Una cosa la lascio come osservazione e non come segnalazione, perché serve a non rifare il mio errore al contrario: `vs_coord_membership` chiama anche `net_kernel:monitor_nodes(true)`, ma filtra su `peers`, cioè sui coordinatori configurati, quindi una **stazione** che muore lì viene scartata. Le due sorveglianze sono separate e coerenti — coordinatori di qua, stazioni di là — e quella riga non copre le stazioni.

## ③ `b/progress-m3` è ancora fuori da `main`

Due commit di sola `PROGRESS.md`, `0c224a3` e `c7b88a1`, mai mergiati. Non li ho toccati perché è documentazione tua.

**Sul contenuto sono d'accordo**: il requisito dice "deployata su più *nodi*" e di nodi ne abbiamo sette veri; il confronto con BlackNet regge; e la conseguenza tecnica che annoti — che con due host `-sname` non basta più e cambiano `COORD_NODES` e `JINTERFACE_NODE` ovunque — è quella giusta e non ovvia.

**Ma il motivo che ti resta per volerlo si può togliere.** Scrivi che su una macchina sola non si produce una partizione di rete vera, e che quindi la minoranza che si sospende si mostra con `docker kill`. Il problema è che `docker kill` non è una partizione: è un crash. Sono due scenari diversi, e il quorum esiste per il primo — un nodo che *resta vivo* ma non vede gli altri, e che deve avere il buon senso di smettere di servire.

Su un host solo si fa lo stesso:

```bash
docker network disconnect voltshare coord3     # coord3 resta vivo, ma isolato
# coord3 → minoranza → suspended;  coord1+coord2 → maggioranza → eleggono
docker network connect voltshare coord3        # e si guarda come si ricompone
```

Il container continua a girare e a credersi vivo: è una partizione vera, con la minoranza dalla parte giusta del vetro. Se funziona, il deploy multi-host non ha più nemmeno quel motivo, e la demo guadagna lo scenario più difficile da mostrare.

## ④ C'è un utente di prova nel MySQL condiviso

Si chiama `cc-probe`, creato durante la verifica del passo 4 per avere un token firmato davvero da `JwtUtil` invece dei fixture. È un utente con veicolo come tutti gli altri, quindi comparirà nella lobby e nello storico. Lo lascio: serve per le prove. Se ti dà fastidio nella demo, cancellalo pure.

## ⑤ Aspetto la tua PR

Quella con `GrantedAt` in `acquire`, il rinnovo a cinque campi e — se siamo d'accordo sulla forma — `session_closed`. Sono reviewer e la guardo appena arriva.

Sul `session_closed` ti ho lasciato una domanda aperta in `risposta-per-B-M2.md` §3: le unità di `StartedAt`/`EndedAt`. La firma dice secondi, tutto il resto del nostro confine è in millisecondi. Un fattore 1000 su un solo messaggio non rompe nessun tipo e non fallisce nessun test — è la stessa classe di errore invisibile di cui ti preoccupavi tu per `overstay_seconds`.

---

## Cosa puoi dare per acquisito da adesso

- Il canale driver è completo e provato contro lo stack vero: handshake JWT, `reserve` / `cancel_reservation` / `stop_session`, at-most-once con la cache dei `request_id`, push completo dello stato, riconnessione con backoff.
- Il JWT in transito **funziona**: token firmato da `JwtUtil`, letto dalla pagina renderizzata, verificato da `vs_jwt`. Era l'unico pezzo del confine fra le nostre due metà mai attraversato da un token vivo.
- I due rifiuti di `ws-driver.md` §4.1 sono ora distinti: il tuo `already_held` — *"quel veicolo è impegnato"* — arriva al driver come `NO_CLAIM` con il messaggio giusto, non più come "questo connettore è preso da un altro".
- `stations.ws_url` **non** contiene la query string, e va bene così: è il client ad appendere `?station_id=`. Se un giorno la aggiungessi al valore nel database, la stazione chiuderebbe con `4400`.

Ora parto con M2 lato A: canale colonnina, riparto della potenza, scrittura delle sessioni su MySQL, `session.jsp`.

— A
