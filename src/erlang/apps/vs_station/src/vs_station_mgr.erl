%%%-------------------------------------------------------------------
%%% @doc Station manager: connector registry and aggregate state.
%%%
%%% One per station node. It boots the connector processes from
%%% configuration, keeps a registry `conn_id → pid' in ETS, builds the
%%% aggregate station state the driver channel will push (P6: the server
%%% is the single source of truth and pushes *complete* state), and
%%% carries the site power budget — as a value only, until M2 brings the
%%% allocation algorithm.
%%%
%%% Registration protocol with the connectors, in two halves:
%%%
%%%   * at boot the manager starts each connector and records the pid it
%%%     gets back — deterministic: when init completes, the registry is
%%%     full and `station_state/0' never shows a phantom `offline';
%%%   * a `{connector_up, Pid}' event, emitted by every connector from its
%%%     own init, covers the other case: a connector restarted by
%%%     `vs_connector_sup' after a crash re-announces itself and the
%%%     registry heals. The event is idempotent, so the duplicate it
%%%     produces at first boot is absorbed.
%%%
%%% The event is a plain message, never a call from the connector's init
%%% to the manager: the manager starts connectors synchronously from
%%% handle_continue, so a child calling back into it while it waits would
%%% deadlock — same shape as the M0 ping deadlock (scelte §4.4).
%%%
%%% If the *manager* is the one that crashes, its restart must not touch
%%% the connectors (one_for_one; SCOPE §4 — station autonomy): on init it
%%% adopts the children still alive under vs_connector_sup and starts
%%% only the missing ones.
%%%-------------------------------------------------------------------
-module(vs_station_mgr).
-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, station_state/0, connector_pid/1,
         subscribe/0, unsubscribe/0]).
%% dirty reads — for vs_claim_client, which must never call us (see below)
-export([lookup_pid/1, connector_specs/0]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2]).

-define(TAB, vs_station_conns).
%% Matches the seed of station 1 in contracts/schema.sql. Connector ids
%% are globally unique, so each station's CONNECTORS env must list its
%% own rows of the seed (see deploy/docker-compose.yml).
-define(DEFAULT_CONNECTORS, "1:150,2:150,3:150,4:50").

-record(state, {station_id    :: pos_integer(),
                name          :: binary(),
                site_power_kw :: pos_integer(),
                %% Carried, never applied: the station reports the tariff
                %% so the page can show it, and the back office is the one
                %% that turns kWh into money (schema.sql, ownership rules).
                tariff_cents_kwh :: non_neg_integer(),
                child_opts    :: map(),
                %% M2 step 2 — the allocator's settings, read from the
                %% environment once here rather than inside vs_power, which
                %% stays a function of its arguments.
                power_tick_ms   :: pos_integer(),
                min_charge_kw   :: number(),
                taper_soc_pct   :: number(),
                taper_margin_kw :: number(),
                %% The last allocation this process computed and sent out:
                %% conn_id → kW. It is what `allocated_kw' reports, so the
                %% field says what was *granted*, not what the meters
                %% happen to be reading back (see build_state/1).
                alloc    = #{} :: #{pos_integer() => float()},
                monitors = #{} :: #{reference() =>
                                        {connector, pos_integer()} | {subscriber, pid()}},
                subs     = #{} :: #{pid() => reference()}}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

%% @doc Options (all defaulted from the environment): station_id,
%% site_power_kw, connectors :: [{ConnId, RatedKw}], plus claim_mod,
%% db_mod and lease_seconds forwarded to every connector.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc Aggregate view of the station: id, power budget, and one snapshot
%% per connector, sorted by connector id. This is the payload of the
%% `state' push in ws-driver.md.
-spec station_state() -> map().
station_state() ->
    gen_server:call(?MODULE, station_state).

-spec connector_pid(pos_integer()) -> {ok, pid()} | {error, unknown_connector}.
connector_pid(ConnId) ->
    gen_server:call(?MODULE, {connector_pid, ConnId}).

%% @doc The calling process starts receiving `{station_state, Map}' on
%% every connector event. Meant for the driver WebSocket processes.
-spec subscribe() -> ok.
subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}).

-spec unsubscribe() -> ok.
unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}).

%% @doc Lock-free lookup, reading the protected ETS directly. For
%% vs_claim_client only: synchronous calls already flow connector→client
%% and manager→connector, so a client→manager call would close a cycle
%% of three gen_servers that can deadlock. Callers accept the price of a
%% dirty read: a pid that may be milliseconds stale.
-spec lookup_pid(pos_integer()) -> {ok, pid()} | {error, unknown_connector}.
lookup_pid(ConnId) ->
    try ets:lookup(?TAB, ConnId) of
        [{ConnId, _RatedKw, Pid}] when is_pid(Pid) -> {ok, Pid};
        _ -> {error, unknown_connector}
    catch
        error:badarg -> {error, unknown_connector}   %% manager not up yet
    end.

%% @doc The configured connectors, for the station_up announcement. Same
%% dirty-read rationale as lookup_pid/1; [] when the manager is not up.
-spec connector_specs() -> [{pos_integer(), pos_integer()}].
connector_specs() ->
    try
        lists:keysort(1, [{Id, RatedKw} || {Id, RatedKw, _} <- ets:tab2list(?TAB)])
    catch
        error:badarg -> []
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    StationId = maps:get(station_id, Opts, vs_env:get_int("STATION_ID", 1)),
    SiteKw    = maps:get(site_power_kw, Opts, vs_env:get_int("SITE_POWER_KW", 350)),
    %% Same variables vs_claim_client reads for its station_up
    %% announcement, with the same defaults. Duplicated *reading*, not
    %% duplicated *computation*: one environment, one value, so the two
    %% cannot disagree. Having one process ask the other would couple two
    %% gen_servers the design deliberately keeps apart.
    Name      = maps:get(name, Opts,
                         list_to_binary(
                           vs_env:get_str("STATION_NAME",
                                          "station-" ++ integer_to_list(StationId)))),
    Tariff    = maps:get(tariff_cents_kwh, Opts,
                         vs_env:get_int("TARIFF_CENTS_KWH", 45)),
    Specs     = maps:get(connectors, Opts, connectors_from_env()),
    ets:new(?TAB, [named_table, set, protected]),
    lists:foreach(fun({Id, RatedKw}) ->
                          ets:insert(?TAB, {Id, RatedKw, undefined})
                  end, Specs),
    ChildOpts0 = maps:with([claim_mod, db_mod, lease_seconds], Opts),
    %% Production default is the real client; CLAIM_MOD=vs_claim_null
    %% degrades to the loud uncoordinated stand-in for shell exploration.
    ChildOpts = case maps:is_key(claim_mod, ChildOpts0) of
                    true  -> ChildOpts0;
                    false -> ChildOpts0#{claim_mod =>
                                             vs_env:get_atom("CLAIM_MOD", vs_claim_client)}
                end,
    {ok, #state{station_id       = StationId,
                name             = Name,
                site_power_kw    = SiteKw,
                tariff_cents_kwh = Tariff,
                child_opts       = ChildOpts,
                power_tick_ms    = maps:get(power_tick_ms, Opts,
                                            vs_env:get_int("POWER_TICK_MS", 5000)),
                %% Already a documented variable of ws-driver.md §10; the
                %% other two are station-internal and are documented in
                %% scelte_di_progetto.md, not in a contract.
                min_charge_kw    = maps:get(min_charge_kw, Opts,
                                            vs_env:get_int("MIN_CHARGE_KW", 6)),
                taper_soc_pct    = maps:get(taper_soc_pct, Opts,
                                            vs_env:get_int("TAPER_SOC_PCT", 80)),
                taper_margin_kw  = maps:get(taper_margin_kw, Opts,
                                            vs_env:get_int("TAPER_MARGIN_KW", 5))},
     {continue, start_connectors}}.

handle_continue(start_connectors, State0) ->
    %% Adopt whatever is already alive under vs_connector_sup — after a
    %% manager restart the connectors kept running, and restarting them
    %% would kill the sessions they carry.
    State1 = lists:foldl(fun({Id, Pid}, S) ->
                                 {_, S1} = register_pid(Id, Pid, S),
                                 S1
                         end, State0, running_connectors()),
    Missing = [{Id, RatedKw} || {Id, RatedKw, undefined} <- ets:tab2list(?TAB)],
    State2 = lists:foldl(
               fun({Id, RatedKw}, S) ->
                       case start_connector(Id, RatedKw, S) of
                           {ok, Pid} ->
                               {_, S1} = register_pid(Id, Pid, S),
                               S1;
                           error ->
                               S
                       end
               end, State1, Missing),
    %% The tick is armed after the connectors exist, so the first one
    %% cannot fire against an empty registry. Nothing is charging at boot,
    %% so there is no first allocation to make here: the `plugged' that
    %% starts one is itself a connector_event, and that recomputes.
    _ = schedule_power_tick(State2),
    {noreply, State2}.

handle_call(station_state, _From, State) ->
    {reply, build_state(State), State};

handle_call({connector_pid, ConnId}, _From, State) ->
    Reply = case ets:lookup(?TAB, ConnId) of
                [{ConnId, _RatedKw, Pid}] when is_pid(Pid) -> {ok, Pid};
                _ -> {error, unknown_connector}
            end,
    {reply, Reply, State};

handle_call({subscribe, Pid}, _From, State = #state{monitors = Mons, subs = Subs}) ->
    case maps:is_key(Pid, Subs) of
        true ->
            {reply, ok, State};
        false ->
            Ref = erlang:monitor(process, Pid),
            {reply, ok, State#state{monitors = Mons#{Ref => {subscriber, Pid}},
                                    subs     = Subs#{Pid => Ref}}}
    end;

handle_call({unsubscribe, Pid}, _From, State = #state{monitors = Mons, subs = Subs}) ->
    case maps:take(Pid, Subs) of
        {Ref, Subs1} ->
            erlang:demonitor(Ref, [flush]),
            {reply, ok, State#state{monitors = maps:remove(Ref, Mons), subs = Subs1}};
        error ->
            {reply, ok, State}
    end;

handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% Subscription by message — for vs_claim_client, which never makes a
%% synchronous call into this process (see lookup_pid). Unlike the
%% call-based subscribe, the subscriber receives the current state
%% immediately: a cast cannot combine subscribing with reading, so the
%% first push stands in for the read.
handle_cast({subscribe, Pid}, State = #state{monitors = Mons, subs = Subs}) ->
    Pid ! {station_state, build_state(State)},
    case maps:is_key(Pid, Subs) of
        true ->
            {noreply, State};
        false ->
            Ref = erlang:monitor(process, Pid),
            {noreply, State#state{monitors = Mons#{Ref => {subscriber, Pid}},
                                  subs     = Subs#{Pid => Ref}}}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%% A connector announcing itself: first boot (duplicate of the pid we
%% already recorded — absorbed silently) or a supervisor restart (new
%% pid — the registry heals here, and that IS an observable change).
%% Broadcasting the duplicate too would race with early subscribers:
%% handle_continue runs after start_link has returned, so a subscribe
%% can be queued ahead of the boot announcements and would then receive
%% pushes for changes that never happened.
handle_info({connector_event, ConnId, {connector_up, Pid}}, State0) ->
    case register_pid(ConnId, Pid, State0) of
        {unchanged, State} ->
            {noreply, State};
        {changed, State} ->
            State1 = reallocate(State),
            broadcast(State1),
            {noreply, State1}
    end;

%% Any other connector event may have changed the observable state, so the
%% subscribers get a fresh complete push (P6). No diffing on purpose.
%%
%% This is also one of the two moments the power is re-split (SCOPE §3.5:
%% "on every arrival, every departure"): arrivals and departures are
%% connector events, and this clause is where they all pass. Recomputing
%% *before* broadcasting is not incidental — see reallocate/1.
handle_info({connector_event, _ConnId, _Event}, State) ->
    State1 = reallocate(State),
    broadcast(State1),
    {noreply, State1};

%% The other moment: the periodic re-split of §3.5. It is the only thing
%% that can notice a taper, because a `meter' reading deliberately emits
%% no event — one per connector every METER_INTERVAL_S would flood every
%% open page with a change that never happened.
%%
%% No broadcast here, on purpose. A page that is watching re-reads the
%% whole state on its own STATE_TICK_MS timer (vs_driver_ws), so a
%% taper-driven change reaches it within the same five seconds anyway,
%% and pushing from both ends would double the traffic to say it twice.
handle_info(power_tick, State) ->
    _ = schedule_power_tick(State),
    {noreply, reallocate(State)};

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{monitors = Mons,
                                                                  subs = Subs}) ->
    case maps:take(Ref, Mons) of
        {{connector, ConnId}, Mons1} ->
            %% Between the crash and the supervisor restart the connector
            %% shows as `offline' rather than vanishing: it still exists
            %% physically, and hiding it would lie to the driver.
            case ets:lookup(?TAB, ConnId) of
                [{ConnId, RatedKw, _}] -> ets:insert(?TAB, {ConnId, RatedKw, undefined});
                [] -> ok
            end,
            %% A connector that died is a departure like any other: its
            %% share goes back into the split for the ones still alive.
            State1 = reallocate(State#state{monitors = Mons1}),
            broadcast(State1),
            {noreply, State1};
        {{subscriber, Pid}, Mons1} ->
            {noreply, State#state{monitors = Mons1, subs = maps:remove(Pid, Subs)}};
        error ->
            {noreply, State}
    end;

handle_info(Info, State) ->
    logger:debug("station manager ignoring ~p", [Info]),
    {noreply, State}.

%%%===================================================================
%%% internal
%%%===================================================================

running_connectors() ->
    lists:filtermap(
      fun({_, Pid, worker, _}) when is_pid(Pid) ->
              try
                  {true, {maps:get(connector_id, vs_connector:snapshot(Pid)), Pid}}
              catch
                  _:_ -> false   %% mid-shutdown: the DOWN path will see it
              end;
         (_) ->
              false
      end,
      supervisor:which_children(vs_connector_sup)).

start_connector(ConnId, RatedKw, #state{station_id = StationId, child_opts = ChildOpts}) ->
    Opts = maps:merge(#{conn_id    => ConnId,
                        station_id => StationId,
                        rated_kw   => RatedKw,
                        notify_to  => ?MODULE}, ChildOpts),
    case vs_connector_sup:start_connector(Opts) of
        {ok, Pid} ->
            {ok, Pid};
        {error, Reason} ->
            logger:error("station manager: cannot start connector ~p: ~p",
                         [ConnId, Reason]),
            error
    end.

register_pid(ConnId, Pid, State = #state{monitors = Mons0}) ->
    case ets:lookup(?TAB, ConnId) of
        [{ConnId, _RatedKw, Pid}] ->
            {unchanged, State};                     %% same pid: already registered
        [{ConnId, RatedKw, _Old}] ->
            Mons1 = demonitor_connector(ConnId, Mons0),
            Ref = erlang:monitor(process, Pid),
            ets:insert(?TAB, {ConnId, RatedKw, Pid}),
            {changed, State#state{monitors = Mons1#{Ref => {connector, ConnId}}}};
        [] ->
            logger:warning("station manager: connector_up for unknown connector ~p",
                           [ConnId]),
            {unchanged, State}
    end.

%% Drop any monitor still attached to this connector id — the stale pid of
%% a crashed process being replaced. Its pending DOWN is flushed with it.
demonitor_connector(ConnId, Mons) ->
    maps:filter(fun(Ref, {connector, Id}) when Id =:= ConnId ->
                        erlang:demonitor(Ref, [flush]),
                        false;
                   (_Ref, _Other) ->
                        true
                end, Mons).

%% The payload of the `state' push of ws-driver.md §5.1, minus the two
%% fields that are not the manager's to know: `coordinator_reachable'
%% belongs to the claim client, and `held_by_me'/`mine' depend on which
%% driver is looking. Both are added by vs_driver_proto:wire_state/3.
build_state(State = #state{station_id = StationId, name = Name,
                           site_power_kw = SiteKw, tariff_cents_kwh = Tariff}) ->
    #{station_id       => StationId,
      name             => Name,
      site_power_kw    => SiteKw,
      allocated_kw     => allocated_kw(State),
      tariff_cents_kwh => Tariff,
      connectors       => connector_entries()}.

%% What the site has **granted**, which since M2 step 2 is a different
%% number from what the meters read back — the cars may well be drawing
%% less than they were allowed, and a car that is tapering always is.
%% "Allocated" now means allocated: the field is the sum of the limits
%% this process handed out, so `allocated_kw =< site_power_kw' holds by
%% construction rather than by luck.
%%
%% Read from the stored allocation and not from the connectors, so that
%% `station_state' and `subscribe' stay pure reads. A build that had to
%% recompute would be a read with a side effect on every connector.
%% Always a float, empty allocation included: the key has been a float
%% since M1 and a page that formats it should not have to cope with the
%% one case where it is an integer.
allocated_kw(#state{alloc = Alloc}) ->
    float(lists:sum(maps:values(Alloc))).

connector_entries() ->
    [connector_entry(Row) || Row <- lists:keysort(1, ets:tab2list(?TAB))].

connector_entry({ConnId, RatedKw, undefined}) ->
    #{connector_id => ConnId, rated_kw => RatedKw, state => offline};
connector_entry({ConnId, RatedKw, Pid}) ->
    try
        vs_connector:snapshot(Pid)
    catch
        _:_ -> #{connector_id => ConnId, rated_kw => RatedKw, state => offline}
    end.

%%%===================================================================
%%% the power split (SCOPE §3.5)
%%%===================================================================

schedule_power_tick(#state{power_tick_ms = Ms}) ->
    erlang:send_after(Ms, self(), power_tick).

%% Read the connectors, split the budget, tell everybody, remember what
%% was granted. The manager is the only process that knows both the site
%% budget and every session at once; the connectors go on knowing nothing
%% about their neighbours.
%%
%% `set_limit' goes to **every** live session on every recomputation, at
%% an unchanged value too. That is ws-chargepoint.md §5 as written —
%% idempotence by repetition rather than diff tracking — and it means a
%% charge point that missed a frame is right again within one tick
%% instead of sitting on a stale limit forever.
%%
%% The order here is what makes the push that follows correct. The casts
%% go out first and `build_state' reads the connectors afterwards; message
%% order between two processes is preserved, so each connector handles its
%% `set_limit' before it answers the `snapshot' call, and the state the
%% subscribers receive already carries the new limits — `suspended'
%% included, which is derived from exactly that field.
reallocate(State = #state{site_power_kw = Budget, min_charge_kw = MinKw,
                          taper_soc_pct = TaperSoc, taper_margin_kw = Margin}) ->
    Demands = vs_power:demands(connector_entries(), TaperSoc, Margin),
    Alloc   = vs_power:allocate(Budget, Demands, MinKw),
    maps:foreach(fun(ConnId, Kw) ->
                         case lookup_pid(ConnId) of
                             {ok, Pid} -> vs_connector:set_limit(Pid, Kw);
                             _         -> ok      %% died between the two reads
                         end
                 end, Alloc),
    State#state{alloc = Alloc}.

broadcast(#state{subs = Subs}) when map_size(Subs) =:= 0 ->
    ok;
broadcast(State = #state{subs = Subs}) ->
    Msg = {station_state, build_state(State)},
    maps:foreach(fun(Pid, _Ref) -> Pid ! Msg end, Subs),
    ok.

%% CONNECTORS="1:150,2:150,3:150,4:50" — conn_id:rated_kw, comma-separated.
%% A malformed entry is skipped with a warning, never a boot failure
%% (scelte §2.2); an unusable value falls back to the default whole.
connectors_from_env() ->
    Raw = vs_env:get_str("CONNECTORS", ?DEFAULT_CONNECTORS),
    case lists:filtermap(fun parse_connector/1, string:lexemes(Raw, ",")) of
        [] ->
            logger:warning("CONNECTORS unusable (~p), using default ~p",
                           [Raw, ?DEFAULT_CONNECTORS]),
            lists:filtermap(fun parse_connector/1,
                            string:lexemes(?DEFAULT_CONNECTORS, ","));
        Specs ->
            Specs
    end.

parse_connector(Part) ->
    case string:lexemes(string:trim(Part), ":") of
        [IdS, KwS] ->
            try
                {true, {list_to_integer(string:trim(IdS)),
                        list_to_integer(string:trim(KwS))}}
            catch
                error:badarg ->
                    logger:warning("CONNECTORS: skipping malformed entry ~p", [Part]),
                    false
            end;
        _ ->
            logger:warning("CONNECTORS: skipping malformed entry ~p", [Part]),
            false
    end.
