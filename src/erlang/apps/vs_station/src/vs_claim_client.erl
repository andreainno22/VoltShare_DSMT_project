%%%-------------------------------------------------------------------
%%% @doc The station's side of contracts/claim.md — the only place that
%%% talks to the coordinator.
%%%
%%% It plays two roles at once:
%%%
%%%   * towards the connectors it IS a claim_mod — same `acquire/4' and
%%%     `release/2' as vs_claim_null, which is what makes it swappable;
%%%   * towards the cluster it is the wire client: leader discovery
%%%     (claim.md §4), the 10 s renew batch, the who_do_you_hold answer,
%%%     the station_up announcement, and the claim table all live here,
%%%     in one process, because the current leader is one piece of state
%%%     and the renews must be batched per station (scelte §4.5).
%%%
%%% Two structural rules keep it deadlock-free (scelte §4.4):
%%%
%%%   1. **This gen_server never blocks on a remote call.** The remote
%%%      work happens in the caller: `acquire' runs the coordinator
%%%      round-trip in the connector's own process (which is rightly
%%%      synchronous — reserve has nothing else to do), renews run in a
%%%      spawned worker that reports back as a message, and the
%%%      fire-and-forget casts are spawned so that even the auto-connect
%%%      of a dead node cannot stall this process. A slow coordinator
%%%      therefore never freezes the renew loop or the station.
%%%   2. **This gen_server never makes a synchronous call into the
%%%      station either.** connector → client (acquire) and manager →
%%%      connector (snapshot) calls already exist; a client → manager
%%%      call would close a cycle of three gen_servers that can deadlock
%%%      under the right timing. Everything it needs from the manager it
%%%      reads through the dirty ETS helpers (vs_station_mgr:lookup_pid,
%%%      connector_specs); everything it tells a connector is a cast
%%%      (vs_connector:revoke).
%%%
%%% A failed renew is NOT a revocation: only an explicit `Revoked' list
%%% revokes (claim.md §5.4). If no coordinator answers, the claims are
%%% kept and retried at the next tick — discovery failures must never
%%% stop what is already running (claim.md §4); the local lease and the
%%% claim's own expiry are the backstop (§5.6).
%%%
%%% ## The table is a reflection, not a memory (P14, P15)
%%%
%%% The claim lives here, but the *fact* lives in the connector — in
%%% `#hold.claim_id', and in `#session.claim_id' once the cable is in.
%%% Until 29/08 the two halves could not see each other die, and each
%%% direction was its own defect, both measured (REPORT_M3A_VERIFICA
%%% §6.1, §6.2):
%%%
%%%   * this process died → it came back with `claims = #{}', answered
%%%     `who_do_you_hold' with nothing, and the first election let the
%%%     same vehicle hold two reservations (P14);
%%%   * a connector died → this process kept renewing a claim nobody
%%%     owned, and since the coordinator recomputes the expiry on every
%%%     round that claim **never expired**: one vehicle locked out of
%%%     the whole network, for ever (P15).
%%%
%%% So a claim is now tied to the life of the process that asked for it.
%%% `{granted, …}' monitors its caller — which is the connector's own
%%% process, and that is the premise the whole design rests on — and a
%%% `DOWN' releases the claim at the instant the owner dies. A monitor
%%% is the exact notification of what happened, it needs no timeout,
%%% and it arrives on `kill' too, which is precisely the case where
%%% `terminate/3' does not run.
%%%
%%% In the other direction, a client that has just booted asks: one
%%% `{claims_rebuild, self()}' cast per live connector, out of
%%% `handle_continue', and whoever holds a claim casts it back. A
%%% question asked once by the side that lost its state, not a
%%% heartbeat — and no synchronous call in either direction, so rule 2
%%% above still holds.
%%%-------------------------------------------------------------------
-module(vs_claim_client).
-behaviour(gen_server).

%% claim_mod interface — called from the connector's process
-export([acquire/4, release/2]).
%% dirty read — for the driver WebSocket processes (see below)
-export([coordinator_reachable/0]).
%% from vs_station_db, after the row is in MySQL
-export([session_closed/1]).
%% lifecycle
-export([start_link/0, start_link/1]).
%% pure, and exported so the lobby's three numbers can be tested on a map
%% built by hand instead of on a whole station
-export([count_stats/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-define(SRV, vs_coord_srv).          %% remote name, fixed by the contract
-define(REACH, vs_claim_reach).      %% one row: {coordinator_reachable, boolean()}

%% P15 — `owner' and `mon' are what makes the table a reflection: the
%% connector process that asked for this claim, and the monitor on it.
%% `owner' is carried for the logs only; `mon' is the key the `DOWN'
%% arrives with, and every path that takes a claim out of the map must
%% drop it (see drop_claim/2).
-record(claim, {vehicle_id :: pos_integer(),
                user_id    :: pos_integer(),
                conn_id    :: pos_integer(),
                granted_at :: vs_time:epoch_ms(),
                expires_at :: vs_time:epoch_ms(),
                owner      :: pid(),
                mon        :: reference(),
                %% Has a coordinator spoken about THIS claim since this
                %% process learned of it? `true' for a grant and for every
                %% claim a renew round confirmed; `false' for one a
                %% connector presented at rebuild, whose expiry is a copy
                %% taken at grant time and is therefore a lower bound, not
                %% a fact. Only the sweep reads it — see drop_expired/1.
                confirmed = false :: boolean()}).

-record(state, {station_id  :: pos_integer(),
                nodes       :: [node()],
                leader      :: node(),
                timeout_ms  :: pos_integer(),
                renew_ms    :: pos_integer(),
                announce_ms :: pos_integer(),
                info        :: map(),               %% name, ws_url, site kW, tariff
                claims = #{} :: #{binary() => #claim{}},
                last_stats  = undefined :: undefined |
                                           {non_neg_integer(), non_neg_integer(),
                                            non_neg_integer()}}).

%%%===================================================================
%%% claim_mod interface
%%%===================================================================

%% @doc Ask the coordinator before committing anything local. Runs in
%% the connector's process; blocking it is correct (reserve is
%% synchronous by design) and keeps this round-trip out of the client.
%%
%% It runs in the connector's process for a second reason since P15: the
%% claim is monitored on whoever makes this call, so the caller IS the
%% owner. Calling it from a throwaway process would attach the monitor
%% to that process and kill the claim a microsecond later.
%%
%% Four elements, not three (P14): `GrantedAt' is the coordinator's own
%% timestamp and it used to stop here, inside `do_acquire/4'. The
%% connector needs it because the connector is the only half that
%% survives a restart of this one, and claim.md §5.5 decides oldest-wins
%% on that number — a station that reported its own clock instead would
%% put the skew back that the contract PR of 24/08 removed.
-spec acquire(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ->
          {ok, binary(), vs_time:epoch_ms(), vs_time:epoch_ms()} |
          {error, vs_connector:refusal()}.
acquire(VehicleId, UserId, StationId, ConnId) ->
    try
        do_acquire(VehicleId, UserId, StationId, ConnId)
    catch
        %% The client itself is down (restarting): no coordinator, no new
        %% reservations — but nothing crashes, and walk-ins still work.
        exit:_ -> {error, no_claim}
    end.

%% @doc Best-effort by contract (§5.6): the claim expires on its own, so
%% the remote cast is spawned and forgotten.
-spec release(binary(), atom()) -> ok.
release(ClaimId, Reason) ->
    gen_server:call(?MODULE, {release, ClaimId, Reason}).

%%%===================================================================
%%% the reachability flag
%%%===================================================================

%% @doc Whether the **last renew round found a coordinator**. That is the
%% declared meaning, and it is narrower than "the cluster is healthy": it
%% is not a ping, it is the outcome of work this station actually did.
%%
%% Read straight out of the ETS, the same way vs_station_mgr:lookup_pid/1
%% is read and for the same reason: the driver WebSocket processes are
%% leaves, and answering them with a synchronous call would put this
%% gen_server on the critical path of every state push — while this
%% process, by structural rule, calls nobody inside the station either.
%% A dirty read of one boolean cannot be wrong in a way that matters:
%% the worst case is a value one renew tick old.
%%
%% `true' when the table does not exist yet, i.e. before the client has
%% booted. Optimistic on purpose: until something has actually failed,
%% reservations are worth attempting, and `acquire' is what really
%% decides. Refusing them for a coordinator nobody has tried to reach
%% would be a failure this station invented.
-spec coordinator_reachable() -> boolean().
coordinator_reachable() ->
    try ets:lookup(?REACH, coordinator_reachable) of
        [{coordinator_reachable, Reachable}] -> Reachable;
        _Empty                               -> true
    catch
        error:badarg -> true       %% the claim client is not up yet
    end.

%% @doc A session row has been written; wake the back office up
%% (erlang-java.md §2.3). Called by `vs_station_db' **after** the INSERT,
%% never by a connector: the event carries the row's id, which does not
%% exist until the row does.
%%
%% A cast, and delivery is best-effort by design. Java does not read the
%% payload — it prices sessions by sweeping `cost_cents IS NULL' every 60
%% seconds and this only makes the sweep run sooner — so losing the event
%% delays a receipt by one interval and loses nothing.
-spec session_closed(tuple()) -> ok.
session_closed(Event) ->
    gen_server:cast(?MODULE, {session_closed, Event}).

%%%===================================================================
%%% lifecycle
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() -> start_link(#{}).

%% @doc Options (defaulted from the environment; the tests shorten the
%% timers and point coord_nodes at a local mock): station_id,
%% coord_nodes, timeout_ms, renew_interval_ms, announce_interval_ms,
%% station_info.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    StationId = maps:get(station_id, Opts, vs_env:get_int("STATION_ID", 1)),
    Nodes = maps:get(coord_nodes, Opts,
                     vs_env:get_nodes("COORD_NODES",
                                      ['coord1@coord1', 'coord2@coord2', 'coord3@coord3'])),
    Info = maps:get(station_info, Opts, station_info_from_env(StationId)),
    init_reach_table(),
    {ok, #state{station_id  = StationId,
                nodes       = Nodes,
                leader      = hd(Nodes),            %% §4: first entry until told better
                timeout_ms  = maps:get(timeout_ms, Opts,
                                       vs_env:get_int("CLAIM_CALL_TIMEOUT_MS", 2000)),
                renew_ms    = maps:get(renew_interval_ms, Opts,
                                       vs_env:get_int("CLAIM_RENEW_INTERVAL_MS", 10000)),
                announce_ms = maps:get(announce_interval_ms, Opts,
                                       vs_env:get_int("STATION_ANNOUNCE_INTERVAL_MS", 30000)),
                info        = Info},
     {continue, announce}}.

handle_continue(announce, State) ->
    do_announce(State),
    %% Stats feed for the back office lobby: subscribe to the manager's
    %% state pushes. A cast, not a call — this process never makes a
    %% synchronous call into the station (see the module doc); the
    %% manager answers a cast-subscription by sending the current state
    %% at once, which seeds the first station_stats.
    gen_server:cast(vs_station_mgr, {subscribe, self()}),
    %% P14 — ask the connectors what they hold. Last of the three, and
    %% the order is a decision rather than an accident:
    %%
    %%   * **after `do_announce'**, because a claim presented to a
    %%     coordinator that has never heard of this station comes back
    %%     `unknown_station' on the first renew; announcing first costs
    %%     one cast and removes that round trip;
    %%   * **after the subscription**, because the reply to a subscribe
    %%     is a `{station_state, …}' push and this one is not: keeping
    %%     the subscription ahead means the first push describes the
    %%     station as it is, not as it was one rebuild ago.
    %%
    %% At the very first boot this finds either nothing (`connector_specs'
    %% answers `[]' while the manager's table does not exist) or a set of
    %% connectors that are all `free', and every one of them answers with
    %% silence. It costs one cast per connector, once per client life.
    ask_connectors_for_claims(),
    erlang:send_after(State#state.announce_ms, self(), announce_tick),
    erlang:send_after(State#state.renew_ms, self(), renew_tick),
    {noreply, State}.

%% -- serving the connector-side helpers ------------------------------

handle_call(get_route, _From, State) ->
    {reply, {State#state.leader, State#state.nodes, State#state.timeout_ms}, State};

handle_call(station_up_msg, _From, State) ->
    {reply, station_up_msg(State), State};

%% P15 — `From' was `_From' until 29/08, and that underscore was the
%% defect. A gen_server:call carries the caller's pid, this call is made
%% from the connector's own process (§1.2 of REPORT_CLAIM_RIFLESSO, and
%% the assertion that proves it), so the owner of the claim is right
%% here, for free, in the message that creates it.
handle_call({granted, Node, ClaimId, VehicleId, UserId, ConnId, GrantedAt, ExpiresAt},
            {Owner, _Tag}, State = #state{claims = Claims}) ->
    %% GrantedAt comes from the coordinator (contract PR of 24/08): the
    %% station never invents a timestamp, it stores this one and repeats
    %% it in renew and who_do_you_hold. Oldest-wins (§5.5) is thereby
    %% decided by ONE clock even across a failover — no cross-station
    %% clock skew in the comparison.
    {reply, ok, State#state{leader = Node,
                            claims = put_claim(ClaimId,
                                               #claim{vehicle_id = VehicleId,
                                                      user_id    = UserId,
                                                      conn_id    = ConnId,
                                                      granted_at = GrantedAt,
                                                      expires_at = ExpiresAt,
                                                      owner      = Owner,
                                                      %% the coordinator has
                                                      %% just spoken: this
                                                      %% expiry is a fact
                                                      confirmed  = true},
                                               Claims)}};

handle_call({release, ClaimId, Reason}, _From,
            State = #state{leader = Leader, claims = Claims}) ->
    cast_leader(Leader, {release, ClaimId, Reason}),
    {reply, ok, State#state{claims = drop_claim(ClaimId, Claims)}};

handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({leader_hint, Node}, State) ->
    {noreply, State#state{leader = Node}};

%% Out through `cast_leader/2' like every other message to a
%% coordinator, for the reason written there.
%%
%% The message is `{session_closed, Event}' — the two-element wrapper
%% `vs_coord_srv:handle_cast/2' matches, with the nine-field tuple of
%% erlang-java.md §2.3 inside it. Sending the nine fields flat would fall
%% into the coordinator's catch-all instead, which is a warning in a log
%% nobody is reading and a receipt that never arrives.
handle_cast({session_closed, Event}, State = #state{leader = Leader}) ->
    cast_leader(Leader, {session_closed, Event}),
    {noreply, State};

%% P14 — a connector answering the `{claims_rebuild, …}' this process
%% sent from `handle_continue'. Same six fields as a `granted', and the
%% same treatment: insert and monitor the sender, because the connector
%% that still holds the claim is still its owner.
%%
%% **Race (a), and why the map cannot be left dirty.** A connector may
%% answer this and then release the claim an instant later — its lease
%% ran out while we were rebuilding. Both messages travel from the SAME
%% process to THIS one (the cast here, then the `{release, …}' call of
%% `vs_connector:release/2'), so Erlang's pairwise ordering puts them in
%% that order in our mailbox and the release finds the claim to remove.
%% It holds *only* because both hops are direct connector→client: route
%% the release through a third party and the guarantee is gone. This is
%% a property the code rests on, so it is written next to it.
%%
%% **Race (b), and why there is no special case.** If the connector is
%% already dead when we get here, `erlang:monitor/2' delivers a `DOWN'
%% with `noproc' at once (verified on OTP 29, and asserted in
%% `a_claim_presented_by_a_dead_connector_is_dropped_at_once_test'), so
%% the claim is inserted and taken straight back out by the clause below.
handle_cast({claim_present, Owner, ClaimId, VehicleId, UserId, ConnId,
             GrantedAt, ExpiresAt},
            State = #state{claims = Claims}) ->
    case maps:is_key(ClaimId, Claims) of
        true ->
            %% Already known — a `granted' beat the answer here, or a
            %% connector answered twice. Re-monitoring would leak a
            %% monitor for a claim that can only be dropped once.
            {noreply, State};
        false ->
            logger:notice("claim client: connector ~p presented claim ~s "
                          "(vehicle ~p, user ~p) — rebuilding it",
                          [ConnId, ClaimId, VehicleId, UserId]),
            Claim = #claim{vehicle_id = VehicleId,
                           user_id    = UserId,
                           conn_id    = ConnId,
                           granted_at = GrantedAt,
                           expires_at = ExpiresAt,
                           owner      = Owner,
                           %% secondhand, and said so: the connector copied
                           %% this expiry when the claim was granted and
                           %% nobody has moved it since. The next renew
                           %% round settles it.
                           confirmed  = false},
            {noreply, State#state{claims = put_claim(ClaimId, Claim, Claims)}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%% -- the renew loop --------------------------------------------------

handle_info(renew_tick, State0 = #state{claims = Claims0}) ->
    erlang:send_after(State0#state.renew_ms, self(), renew_tick),
    %% The safety net (piano §1.4), applied before the batch is built so
    %% that nothing dead can be in it. See drop_expired/1 for why it is
    %% here at all and why it shouts.
    Claims = drop_expired(Claims0),
    State = State0#state{claims = Claims},
    case map_size(Claims) of
        0 -> ok;
        _ ->
            %% Five fields (contract PR of 24/08): UserId so that a new
            %% leader adopting the claim can enforce suspensions, and the
            %% coordinator-issued GrantedAt so that adoption preserves the
            %% original ordering instead of resetting it.
            Batch = [{ClaimId, C#claim.vehicle_id, C#claim.conn_id,
                      C#claim.user_id, C#claim.granted_at}
                     || {ClaimId, C} <- maps:to_list(Claims)],
            Msg = {renew, State#state.station_id, Batch},
            Self = self(),
            {Leader, Nodes, T} = {State#state.leader, State#state.nodes,
                                  State#state.timeout_ms},
            %% Ephemeral worker (scelte §4.4): the round of remote calls
            %% happens out there, the outcome comes back as a message.
            _ = spawn(fun() -> Self ! {renew_result, call_round(Msg, Leader, Nodes, T)} end)
    end,
    {noreply, State};

handle_info({renew_result, error}, State) ->
    %% No coordinator answered. NOT a revocation (§5.4): claims are kept,
    %% the next tick retries, expiry is the backstop (§5.6). What it *is*,
    %% is the one moment the station knows for certain that no coordinator
    %% is reachable — so it is where the flag the driver channel shows is
    %% written (ws-driver.md §5.1, §7.6: degrade, do not stop).
    set_reachable(false),
    logger:warning("claim client: renew failed on every coordinator, "
                   "keeping ~p claim(s) until the next tick",
                   [map_size(State#state.claims)]),
    {noreply, State};

handle_info({renew_result, {ok, Node, {renewed, Ok, Revoked, NewExpiresAt}}},
            State = #state{claims = Claims0}) ->
    set_reachable(true),
    Claims1 = lists:foldl(
                fun(ClaimId, Acc) ->
                        case Acc of
                            #{ClaimId := C} ->
                                Acc#{ClaimId := C#claim{expires_at = NewExpiresAt,
                                                        confirmed  = true}};
                            _ ->
                                Acc     %% released while the renew was in flight
                        end
                end, Claims0, Ok),
    Claims2 = lists:foldl(fun revoke/2, Claims1, Revoked),
    {noreply, State#state{leader = Node, claims = Claims2}};

%% A coordinator answered, just not with something we understand. The
%% claims are left alone, but a node did reply: reachability is about
%% whether anybody is there, not about whether the reply made sense.
%% (The design note listed two write sites; the module has three renew
%% outcomes, and this is the third.)
handle_info({renew_result, {ok, Node, Other}}, State) ->
    set_reachable(true),
    logger:warning("claim client: unexpected renew reply from ~p: ~p", [Node, Other]),
    {noreply, State#state{leader = Node}};

%% -- station_stats: derived from the manager's pushes ----------------

%% Event-driven and deduplicated: a push that changes nothing sends
%% nothing, so the lobby updates when reality changes, not on a clock.
handle_info({station_state, StateMap}, State = #state{last_stats = Last}) ->
    case count_stats(StateMap) of
        Last ->
            {noreply, State};
        {Free, Held, Charging} = Stats ->
            cast_leader(State#state.leader,
                        {station_stats, State#state.station_id, Free, Held, Charging}),
            {noreply, State#state{last_stats = Stats}}
    end;

%% -- the rebuild query (claim.md §3.4) -------------------------------

handle_info({who_do_you_hold, From, CoordNode},
            State = #state{station_id = StationId, claims = Claims}) ->
    %% Answered immediately from memory, nothing touched. The asker is a
    %% freshly elected leader introducing itself — free routing update.
    Holds = [{C#claim.vehicle_id, C#claim.user_id, C#claim.conn_id,
              ClaimId, C#claim.granted_at, C#claim.expires_at}
             || {ClaimId, C} <- maps:to_list(Claims)],
    From ! {holds, StationId, Holds},
    {noreply, State#state{leader = CoordNode}};

%% -- the owner died (P15) --------------------------------------------

%% The connector that asked for this claim is gone. It is not "maybe
%% gone", and no timeout had to guess it: a `DOWN' is the fact itself,
%% and it arrives on `exit(Pid, kill)' too — the case where the
%% connector's own `terminate/3' never runs, which is exactly the hole
%% measured in §6.2.
%%
%% A connector that comes back comes back `free' and claimless (verified
%% by structure: `#hold{}' is built in one place, on a grant), so there
%% is nothing to re-adopt and releasing is the whole of the right answer.
%%
%% `cancelled' is the reason: claim.md §3.3 fixes four words —
%% `cancelled | expired | completed | revoked' — and this is the station
%% giving the claim back, not a lease running out. No contract changes.
%%
%% No `demonitor' here: delivering the `DOWN' has already consumed the
%% monitor, so `maps:remove' rather than `drop_claim/2'.
handle_info({'DOWN', Ref, process, Pid, Reason}, State = #state{claims = Claims,
                                                               leader = Leader}) ->
    case claim_by_mon(Ref, Claims) of
        {ClaimId, C} ->
            logger:notice("claim client: the connector holding claim ~s died "
                          "(connector ~p, pid ~p, reason ~p) — releasing it",
                          [ClaimId, C#claim.conn_id, Pid, Reason]),
            cast_leader(Leader, {release, ClaimId, cancelled}),
            {noreply, State#state{claims = maps:remove(ClaimId, Claims)}};
        error ->
            %% A monitor this process no longer has a claim for. Harmless
            %% by construction — every removal demonitors with `flush' —
            %% and worth a line rather than a crash if it ever shows up.
            logger:debug("claim client: DOWN from ~p (~p) matching no claim",
                         [Pid, Reason]),
            {noreply, State}
    end;

handle_info(announce_tick, State) ->
    do_announce(State),
    erlang:send_after(State#state.announce_ms, self(), announce_tick),
    {noreply, State};

handle_info(Info, State) ->
    logger:debug("claim client ignoring ~p", [Info]),
    {noreply, State}.

%%%===================================================================
%%% the acquire round-trip — runs in the CONNECTOR's process
%%%===================================================================

do_acquire(VehicleId, UserId, StationId, ConnId) ->
    ReqId = req_id(),
    Msg = {claim, ReqId, VehicleId, UserId, StationId, ConnId},
    {Leader, Nodes, T} = gen_server:call(?MODULE, get_route),
    case call_round(Msg, Leader, Nodes, T) of
        {ok, Node, {ok, ReqId, ClaimId, GrantedAt, ExpiresAt}} ->
            ok = gen_server:call(?MODULE, {granted, Node, ClaimId, VehicleId,
                                           UserId, ConnId, GrantedAt, ExpiresAt}),
            {ok, ClaimId, GrantedAt, ExpiresAt};
        {ok, Node, {error, ReqId, unknown_station}} ->
            %% §3.1: re-announce, retry once. Cast then call from THIS
            %% process to THE SAME node: pairwise FIFO guarantees the
            %% announcement is processed before the retry.
            gen_server:cast(?MODULE, {leader_hint, Node}),
            gen_server:cast({?SRV, Node}, gen_server:call(?MODULE, station_up_msg)),
            case call_one(Msg, Node, T) of
                {ok, ReqId, ClaimId, GrantedAt, ExpiresAt} ->
                    ok = gen_server:call(?MODULE, {granted, Node, ClaimId, VehicleId,
                                                   UserId, ConnId, GrantedAt, ExpiresAt}),
                    {ok, ClaimId, GrantedAt, ExpiresAt};
                {error, ReqId, Reason} ->
                    {error, map_refusal(Reason)};
                _ ->
                    {error, no_claim}
            end;
        {ok, Node, {error, ReqId, Reason}} ->
            gen_server:cast(?MODULE, {leader_hint, Node}),
            {error, map_refusal(Reason)};
        {ok, Node, Other} ->
            logger:warning("claim client: unexpected claim reply from ~p: ~p",
                           [Node, Other]),
            {error, no_claim};
        error ->
            %% Full pass failed (§4.4): refuse, do not queue, do not block.
            {error, no_claim}
    end.

%% claim.md §4: last known leader first; follow one not_serving redirect;
%% then the rest of the list, at most one full pass.
call_round(Msg, Leader, Nodes, T) ->
    Order = [Leader | [N || N <- Nodes, N =/= Leader]],
    try_nodes(Msg, Order, T, false).

try_nodes(_Msg, [], _T, _Followed) ->
    error;
try_nodes(Msg, [Node | Rest], T, Followed) ->
    case call_one(Msg, Node, T) of
        {not_serving, undefined} ->
            try_nodes(Msg, Rest, T, Followed);
        {not_serving, L} when not Followed, L =/= Node ->
            try_nodes(Msg, [L | [N || N <- Rest, N =/= L]], T, true);
        {not_serving, _AlreadyFollowed} ->
            try_nodes(Msg, Rest, T, Followed);
        unreachable ->
            try_nodes(Msg, Rest, T, Followed);
        Reply ->
            {ok, Node, Reply}
    end.

%% §1: gen_server:call with an explicit timeout; a timeout, a dead node
%% and a missing process are all the same thing — try the next one. The
%% error is a value, never an exception to the caller (scelte §4.3).
call_one(Msg, Node, T) ->
    try
        gen_server:call({?SRV, Node}, Msg, T)
    catch
        %% timeout, noproc, nodedown/noconnection, and the badarg a
        %% non-distributed node raises for remote names: all the same
        %% thing here — this node cannot answer, try the next one.
        _:_ -> unreachable
    end.

%%%===================================================================
%%% internal
%%%===================================================================

%% Wire refusals → the connector's refusal atoms (claim.md §3.1 table).
%%
%% `already_held' is renamed on the way in, and the rename is the point:
%% in the coordinator's vocabulary it means "that VEHICLE is committed"
%% (claims are per vehicle), while in the station's it means "that
%% CONNECTOR is taken". Same word, two facts. Letting it through
%% unchanged made the driver channel answer ALREADY_HELD to both, and a
%% driver told the connector was busy tries the next connector — where he
%% fails identically, because the connector was never the problem.
map_refusal(already_held)    -> vehicle_committed;
map_refusal(suspended)       -> suspended;
map_refusal(rebuilding)      -> retry_later;
map_refusal(unknown_station) -> retry_later;
map_refusal(_)               -> no_claim.

revoke(ClaimId, Claims) ->
    case Claims of
        #{ClaimId := C} ->
            logger:warning("claim client: claim ~s revoked by the coordinator "
                           "(connector ~p)", [ClaimId, C#claim.conn_id]),
            case vs_station_mgr:lookup_pid(C#claim.conn_id) of
                {ok, Pid} ->
                    vs_connector:revoke(Pid, ClaimId);   %% a cast — no cycle
                {error, _} ->
                    %% P10: `no_pid' | `no_manager' | `unknown_connector' — the
                    %% three the dirty read can now tell apart, and this
                    %% answer is right for all three. A named clause here
                    %% would be a case_clause that kills the process
                    %% holding every claim of the station, the moment a
                    %% revocation lands during a connector restart.
                    ok   %% connector down: its restart comes back claimless anyway
            end,
            drop_claim(ClaimId, Claims);
        _ ->
            Claims   %% released in the meantime — nothing left to revoke
    end.

%%%===================================================================
%%% the claim table — every way in and out of it
%%%===================================================================

%% The one door in. It monitors the owner and, if that claim id was
%% somehow already there, drops the old monitor first: a second
%% `erlang:monitor' on the same pid returns a NEW reference, so
%% overwriting the record without this would leave a monitor that
%% nothing can ever demonitor.
put_claim(ClaimId, Claim = #claim{owner = Owner}, Claims) ->
    Claims1 = drop_claim(ClaimId, Claims),
    Claims1#{ClaimId => Claim#claim{mon = erlang:monitor(process, Owner)}}.

%% The one door out, used by release, revoke and the expiry sweep.
%%
%% `[flush]', never a bare demonitor: without it a `DOWN' that is already
%% in the mailbox is delivered after the claim is gone. Today that is
%% harmless — the clause above finds no claim for the reference and logs
%% a debug line — but a monitor left hanging on something that no longer
%% exists is exactly the kind of thing that is innocuous until it is not.
drop_claim(ClaimId, Claims) ->
    case maps:take(ClaimId, Claims) of
        {#claim{mon = Ref}, Rest} when is_reference(Ref) ->
            _ = erlang:demonitor(Ref, [flush]),
            Rest;
        {_NoMonitor, Rest} ->
            Rest;
        error ->
            Claims
    end.

claim_by_mon(Ref, Claims) ->
    case [{Id, C} || {Id, C = #claim{mon = R}} <- maps:to_list(Claims), R =:= Ref] of
        [Found | _] -> Found;
        []          -> error
    end.

%% The safety net of piano §1.4. It closes neither defect on its own —
%% the claim of §6.2 was never expired, it was being rejuvenated ten
%% seconds at a time — and it is here for the failure nobody has thought
%% of yet: if a monitor ever fails to fire, this turns "renew something
%% dead for ever" into "at most one tick late".
%%
%% Loud on purpose. In a healthy station this cannot happen: the owner's
%% `DOWN', the release and the revocation all get here first, and every
%% successful renew pushes the expiry forward. A defence that quietly
%% removes the evidence of the defect it defends against is worse than
%% the defect, so a claim dropped here is a `warning' with the reason
%% written out.
%%
%% **Only `confirmed' claims, and that qualifier is what keeps the
%% sentence above true.** A claim a connector presented at rebuild
%% carries the expiry the connector copied when it was granted, and
%% nobody has moved it since — while the coordinator has been pushing the
%% real one forward every ten seconds. The two diverge by design, and a
%% charging session outlives lease+grace routinely, so without this
%% qualifier a client restarting during any session older than sixteen
%% minutes would rebuild its claim and drop it one tick later, shouting
%% about a healthy station. (Measured on the live cluster: a rebuilt
%% claim's 1788024516065 became 1788024774224 at the first renew.)
%%
%% So an unconfirmed claim IS offered in one renew batch. That is not
%% renewing something dead: it is asking the only party that knows, and
%% the coordinator answers by adopting it — `Ok', with a real expiry,
%% which marks it confirmed — or by revoking it. Either way one round
%% settles it. If no coordinator answers at all it stays, and that is
%% §5.4: a failed renew is not a revocation.
drop_expired(Claims) ->
    Expired = [Id || {Id, C} <- maps:to_list(Claims),
                     C#claim.confirmed,
                     vs_time:expired(C#claim.expires_at)],
    lists:foldl(
      fun(ClaimId, Acc) ->
              #{ClaimId := C} = Acc,
              logger:warning("claim client: claim ~s (connector ~p, owner ~p) expired "
                             "at ~p and was still in the table — dropped instead of "
                             "renewed", [ClaimId, C#claim.conn_id, C#claim.owner,
                                         C#claim.expires_at]),
              drop_claim(ClaimId, Acc)
      end, Claims, Expired).

%% P14 — the question, asked once, by the side that lost its state.
%%
%% Both reads are the dirty ETS ones the module doc allows (rule 2): a
%% `gen_server:call' into the manager would close the cycle of three that
%% can deadlock, and the answer is worth exactly what a dirty read is
%% worth — a connector that dies between the lookup and the cast simply
%% never answers, and a connector that was not registered yet has no
%% claim to present.
%%
%% `{error, no_pid | no_manager | unknown_connector}' (P10) are all the
%% same thing here: nobody to ask.
ask_connectors_for_claims() ->
    Self = self(),
    lists:foreach(
      fun({ConnId, _RatedKw}) ->
              case vs_station_mgr:lookup_pid(ConnId) of
                  {ok, Pid}  -> vs_connector:claims_rebuild(Pid, Self);
                  {error, _} -> ok
              end
      end, vs_station_mgr:connector_specs()).

%% Every message this process sends to a coordinator goes out from a
%% throwaway process (scelte §4.4): a slow coordinator, or the
%% auto-connect attempt towards a node that is not there, must never be
%% able to stall the one process that renews the station's claims.
cast_leader(Leader, Msg) ->
    _ = spawn(fun() -> gen_server:cast({?SRV, Leader}, Msg) end),
    ok.

do_announce(State = #state{leader = Leader}) ->
    cast_leader(Leader, station_up_msg(State)).

station_up_msg(#state{station_id = StationId, info = Info}) ->
    {station_up, StationId, node(),
     maps:get(name, Info), maps:get(ws_url, Info),
     maps:get(site_power_kw, Info), maps:get(tariff_cents_kwh, Info),
     vs_station_mgr:connector_specs()}.

%% Public: the readers are other processes. Owned by this one, so it
%% dies with it and `coordinator_reachable/0' falls back to `true' — the
%% same optimistic direction as a client that has not booted yet.
%%
%% The recreation dance is not paranoia: three EUnit fixtures start a
%% client in the same VM, and their teardown waits for the registered
%% *name* to disappear, which a dying process gives up at a slightly
%% different moment from its ETS tables. Without this, whichever test ran
%% second would fail in `init/1' with a badarg nobody would connect to
%% the table. (vs_station_mgr_tests waits for `ets:info/1' as well — the
%% two fixtures are not symmetrical, and this is the side that has to
%% cope.)
init_reach_table() ->
    try ets:new(?REACH, [named_table, set, public, {read_concurrency, true}])
    catch
        error:badarg ->
            %% A public table can be deleted by a process that does not own
            %% it, which is exactly what makes the leftover recoverable.
            %% `try', never the old `catch Expr': OTP 29 deprecates that
            %% form and warnings_as_errors turns it into a build failure
            %% (the same note vs_connector:release/2 carries).
            try ets:delete(?REACH) catch error:badarg -> ok end,
            ets:new(?REACH, [named_table, set, public, {read_concurrency, true}])
    end,
    set_reachable(true).

set_reachable(Reachable) ->
    try ets:insert(?REACH, {coordinator_reachable, Reachable})
    catch error:badarg -> false      %% shutting down; nobody left to tell
    end.

station_info_from_env(StationId) ->
    #{name             => list_to_binary(
                            vs_env:get_str("STATION_NAME",
                                           "station-" ++ integer_to_list(StationId))),
      ws_url           => list_to_binary(
                            vs_env:get_str("WS_URL", "ws://localhost:8080/ws/driver")),
      site_power_kw    => vs_env:get_int("SITE_POWER_KW", 350),
      tariff_cents_kwh => vs_env:get_int("TARIFF_CENTS_KWH", 45)}.

req_id() ->
    list_to_binary("r-" ++ integer_to_list(erlang:unique_integer([positive]))).

%% closing counts as charging: a session is still ending there. offline
%% counts as nothing: not free, not usable — which is why the three
%% numbers may add up to less than the connector total.
%%
%% `suspended' counts as charging too, and the clause has to be written
%% out: it is what a charging session at a limit of zero reports since M2
%% step 2, and without it the catch-all below would quietly drop it. The
%% connector is neither free nor held — somebody's car is plugged into it
%% and the session is alive — so a lobby that showed it as available
%% would send the next driver to an outlet that is already taken.
count_stats(#{connectors := Connectors}) ->
    lists:foldl(fun(C, {F, H, Ch}) ->
                        case maps:get(state, C, offline) of
                            free      -> {F + 1, H, Ch};
                            held      -> {F, H + 1, Ch};
                            charging  -> {F, H, Ch + 1};
                            suspended -> {F, H, Ch + 1};
                            closing   -> {F, H, Ch + 1};
                            _         -> {F, H, Ch}
                        end
                end, {0, 0, 0}, Connectors);
count_stats(_) ->
    {0, 0, 0}.
