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
%%%-------------------------------------------------------------------
-module(vs_claim_client).
-behaviour(gen_server).

%% claim_mod interface — called from the connector's process
-export([acquire/4, release/2]).
%% dirty read — for the driver WebSocket processes (see below)
-export([coordinator_reachable/0]).
%% lifecycle
-export([start_link/0, start_link/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-define(SRV, vs_coord_srv).          %% remote name, fixed by the contract
-define(REACH, vs_claim_reach).      %% one row: {coordinator_reachable, boolean()}

-record(claim, {vehicle_id :: pos_integer(),
                user_id    :: pos_integer(),
                conn_id    :: pos_integer(),
                granted_at :: vs_time:epoch_ms(),
                expires_at :: vs_time:epoch_ms()}).

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
-spec acquire(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ->
          {ok, binary(), vs_time:epoch_ms()} | {error, vs_connector:refusal()}.
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
    erlang:send_after(State#state.announce_ms, self(), announce_tick),
    erlang:send_after(State#state.renew_ms, self(), renew_tick),
    {noreply, State}.

%% -- serving the connector-side helpers ------------------------------

handle_call(get_route, _From, State) ->
    {reply, {State#state.leader, State#state.nodes, State#state.timeout_ms}, State};

handle_call(station_up_msg, _From, State) ->
    {reply, station_up_msg(State), State};

handle_call({granted, Node, ClaimId, VehicleId, UserId, ConnId, GrantedAt, ExpiresAt},
            _From, State = #state{claims = Claims}) ->
    %% GrantedAt comes from the coordinator (contract PR of 24/08): the
    %% station never invents a timestamp, it stores this one and repeats
    %% it in renew and who_do_you_hold. Oldest-wins (§5.5) is thereby
    %% decided by ONE clock even across a failover — no cross-station
    %% clock skew in the comparison.
    Claim = #claim{vehicle_id = VehicleId,
                   user_id    = UserId,
                   conn_id    = ConnId,
                   granted_at = GrantedAt,
                   expires_at = ExpiresAt},
    {reply, ok, State#state{leader = Node,
                            claims = Claims#{ClaimId => Claim}}};

handle_call({release, ClaimId, Reason}, _From,
            State = #state{leader = Leader, claims = Claims}) ->
    Msg = {release, ClaimId, Reason},
    _ = spawn(fun() -> gen_server:cast({?SRV, Leader}, Msg) end),
    {reply, ok, State#state{claims = maps:remove(ClaimId, Claims)}};

handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({leader_hint, Node}, State) ->
    {noreply, State#state{leader = Node}};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% -- the renew loop --------------------------------------------------

handle_info(renew_tick, State = #state{claims = Claims}) ->
    erlang:send_after(State#state.renew_ms, self(), renew_tick),
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
                                Acc#{ClaimId := C#claim{expires_at = NewExpiresAt}};
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
            Msg = {station_stats, State#state.station_id, Free, Held, Charging},
            Leader = State#state.leader,
            _ = spawn(fun() -> gen_server:cast({?SRV, Leader}, Msg) end),
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
            {ok, ClaimId, ExpiresAt};
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
                    {ok, ClaimId, ExpiresAt};
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
map_refusal(already_held)    -> already_held;
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
                {error, unknown_connector} ->
                    ok   %% connector down: its restart comes back claimless anyway
            end,
            maps:remove(ClaimId, Claims);
        _ ->
            Claims   %% released in the meantime — nothing left to revoke
    end.

do_announce(State = #state{leader = Leader}) ->
    Msg = station_up_msg(State),
    %% Spawned: even the auto-connect attempt towards a dead node must
    %% not stall this process.
    _ = spawn(fun() -> gen_server:cast({?SRV, Leader}, Msg) end),
    ok.

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
count_stats(#{connectors := Connectors}) ->
    lists:foldl(fun(C, {F, H, Ch}) ->
                        case maps:get(state, C, offline) of
                            free     -> {F + 1, H, Ch};
                            held     -> {F, H + 1, Ch};
                            charging -> {F, H, Ch + 1};
                            closing  -> {F, H, Ch + 1};
                            _        -> {F, H, Ch}
                        end
                end, {0, 0, 0}, Connectors);
count_stats(_) ->
    {0, 0, 0}.
