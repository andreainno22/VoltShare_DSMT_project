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
                %% Two populations, because two different things are sent
                %% and only one of them is for a person to read (B's
                %% review of the M4-A stack).
                %%
                %%   `sockets'  — the driver WebSockets, in through the
                %%                **call** door `subscribe/0'. State
                %%                pushes and driver notifications.
                %%   `watchers' — in through the **cast** door
                %%                `{subscribe, Pid}'. State pushes only.
                %%                Today that is `vs_claim_client', which
                %%                subscribes for the lobby's stats feed
                %%                and is the one process that may not
                %%                call in here (see lookup_pid/1).
                %%
                %% The split is not new plumbing: the two doors have been
                %% distinct since M1 and their callers have never
                %% overlapped — what was missing was the manager writing
                %% down which door meant what. Before it, every
                %% `driver_notification' also landed in the claim client's
                %% mailbox, to be dropped by its catch-all `handle_info' —
                %% on the process that sits on the critical path of every
                %% acquire, every renew tick and the P14 rebuild.
                %%
                %% A pid is in at most one of the two: see subscribe_ok/2.
                sockets  = #{} :: #{pid() => reference()},
                watchers = #{} :: #{pid() => reference()}}).

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

%% @doc The connector's process, for the driver channel. Three answers,
%% because the two errors are not the same kind of fact:
%%
%%   `no_pid'             row there, process not — TEMPORARY: the gap
%%                        between a connector's death and its restart.
%%   `unknown_connector'  row absent — PERMANENT: this id is not a
%%                        connector of this station.
%%
%% P13, and the same distinction `lookup_pid/1' was given in P10, on the
%% same table and for the same reason. What differs is who paid for the
%% two being merged: there the charge point was closed with the permanent
%% 4404 while its connector was restarting, here the driver was told
%% UNKNOWN_CONNECTOR — "does not belong to this station" — about a
%% connector that belonged to it and would answer a second later.
%%
%% There is no fourth answer for "the manager is not up", and that is not
%% an omission. This is a `call': an absent manager is not a `badarg' to
%% catch here but an `exit({noproc, …})' raised in the CALLER, and
%% `vs_driver_proto' already turns that into `no_manager'.
-spec connector_pid(pos_integer()) ->
          {ok, pid()} | {error, no_pid | unknown_connector}.
connector_pid(ConnId) ->
    gen_server:call(?MODULE, {connector_pid, ConnId}).

%% @doc The calling process starts receiving `{station_state, Map}' on
%% every connector event, **and** the `{driver_notification, …}' of §5.3.
%%
%% This door is for the driver WebSockets and for them alone: a
%% notification is a sentence written for a person, and this is the
%% population that has one at the other end. A process that only wants the
%% state comes in through the cast door instead (see handle_cast/2) and
%% never sees a notification.
-spec subscribe() -> ok.
subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}).

%% @doc Undoes either subscription — a process knows it subscribed, it
%% should not also have to remember by which door.
-spec unsubscribe() -> ok.
unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}).

%% @doc Lock-free lookup, reading the protected ETS directly. For
%% vs_claim_client only: synchronous calls already flow connector→client
%% and manager→connector, so a client→manager call would close a cycle
%% of three gen_servers that can deadlock. Callers accept the price of a
%% dirty read: a pid that may be milliseconds stale.
%%
%% P10 — three answers, not one, because the three have three natures and
%% only the caller can decide what to do about each. `init/1' inserts
%% EVERY configured connector with a pid of `undefined' before anything
%% else can read the table, and the `DOWN' handler puts `undefined' back
%% instead of deleting the row: so a row that exists means "this connector
%% is mine" for as long as this manager lives, and an absent one is not a
%% race window.
%%
%%   `no_pid'             row there, process not — TEMPORARY: the gap
%%                        between a connector's death and its restart.
%%   `no_manager'         no table at all — TEMPORARY: this manager has
%%                        not finished booting. Same name the driver
%%                        channel already answers RETRY_LATER to.
%%   `unknown_connector'  table there, row absent — PERMANENT: this id is
%%                        not a connector of this station.
%%
%% Collapsed into one, the charge point handshake answered every one of
%% them with 4404 — the permanent code of ws-chargepoint.md §1 — to a
%% connector that would have been back in milliseconds.
-spec lookup_pid(pos_integer()) ->
          {ok, pid()} | {error, no_pid | no_manager | unknown_connector}.
lookup_pid(ConnId) ->
    try ets:lookup(?TAB, ConnId) of
        [{ConnId, _RatedKw, Pid}] when is_pid(Pid) -> {ok, Pid};
        [{ConnId, _RatedKw, _NoPid}]               -> {error, no_pid};
        _NotConfigured                             -> {error, unknown_connector}
    catch
        error:badarg -> {error, no_manager}   %% manager not up yet
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

%% The three of connector_pid/1 above, in the order the table can hold
%% them. `[]' is the whole of the third case because ?TAB is a `set'.
handle_call({connector_pid, ConnId}, _From, State) ->
    Reply = case ets:lookup(?TAB, ConnId) of
                [{ConnId, _RatedKw, Pid}] when is_pid(Pid) -> {ok, Pid};
                [{ConnId, _RatedKw, _NoPid}]               -> {error, no_pid};
                []                                         -> {error, unknown_connector}
            end,
    {reply, Reply, State};

%% The socket door: state pushes and notifications both.
handle_call({subscribe, Pid}, _From, State = #state{monitors = Mons, sockets = Sockets}) ->
    case subscribe_ok(Pid, State) of
        false ->
            {reply, ok, State};
        {ok, Ref} ->
            {reply, ok, State#state{monitors = Mons#{Ref => {subscriber, Pid}},
                                    sockets  = Sockets#{Pid => Ref}}}
    end;

handle_call({unsubscribe, Pid}, _From, State) ->
    {reply, ok, forget_subscriber(Pid, State)};

handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% Subscription by message — for vs_claim_client, which never makes a
%% synchronous call into this process (see lookup_pid). Unlike the
%% call-based subscribe, the subscriber receives the current state
%% immediately: a cast cannot combine subscribing with reading, so the
%% first push stands in for the read.
%%
%% It is also, since B's review, the door that says "state only". The
%% claim client asked for a stats feed and got the driver notifications
%% too, on the one process in the station that must never be made to
%% carry work it did not ask for. Nothing about the subscription changed
%% for it — same cast, same seed push, same pushes afterwards — only what
%% no longer arrives.
%%
%% The seed push is outside the dedup on purpose and always has been: a
%% client that subscribes again is asking to be told again, and this door
%% has no reply to tell it with.
handle_cast({subscribe, Pid}, State = #state{monitors = Mons, watchers = Watchers}) ->
    Pid ! {station_state, build_state(State)},
    case subscribe_ok(Pid, State) of
        false ->
            {noreply, State};
        {ok, Ref} ->
            {noreply, State#state{monitors = Mons#{Ref => {subscriber, Pid}},
                                  watchers = Watchers#{Pid => Ref}}}
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
handle_info({connector_event, ConnId, Event}, State) ->
    State1 = reallocate(State),
    broadcast(State1),
    %% M4-A — and after the snapshot, on purpose: the page gets the world
    %% as it now is, then the sentence explaining why it changed.
    announce(ConnId, Event, State1),
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

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #state{monitors = Mons}) ->
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
        %% The monitor stays tagged `{subscriber, Pid}' and says nothing
        %% about which population the pid belonged to — deliberately. The
        %% removal below covers both maps and a pid is in at most one, so
        %% the tag never has to agree with anything: a second place that
        %% recorded the door would be a second place that could be wrong.
        %% No `demonitor': delivering this `DOWN' has already consumed it.
        {{subscriber, Pid}, Mons1} ->
            {noreply, State#state{monitors = Mons1,
                                  sockets  = maps:remove(Pid, State#state.sockets),
                                  watchers = maps:remove(Pid, State#state.watchers)}};
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

%% The snapshot goes to **both** populations: it is the state of the
%% station, and wanting only that is the whole of what the cast door
%% means. The shortcut guards `build_state/1' rather than the sends —
%% that is a `snapshot' call per connector, and a station with nothing
%% watching would pay it on every connector event to build a map nobody
%% receives.
broadcast(#state{sockets = Sockets, watchers = Watchers})
  when map_size(Sockets) =:= 0, map_size(Watchers) =:= 0 ->
    ok;
broadcast(State = #state{sockets = Sockets, watchers = Watchers}) ->
    Msg = {station_state, build_state(State)},
    fan_out(Msg, Sockets),
    fan_out(Msg, Watchers),
    ok.

%% One message to one population, and the only place in this module that
%% walks a subscriber map. It was two — `live/4' had grown its own copy of
%% this loop and lost the empty-map head on the way — and B's point was
%% the arithmetic of that: the day the set of subscribers stops being a
%% bare map of pids there must be one place to change, not two. The day
%% came in the same review.
fan_out(_Msg, Subs) when map_size(Subs) =:= 0 ->
    ok;
fan_out(Msg, Subs) ->
    maps:foreach(fun(Pid, _Ref) -> Pid ! Msg end, Subs),
    ok.

%% A pid becomes a subscriber once, whichever door it came through: the
%% check spans **both** maps and not just the one about to be written.
%% That is what makes "a pid is in at most one population" an invariant
%% rather than a happy consequence of who calls what today — and that
%% invariant is what lets the `DOWN' handler and `forget_subscriber/2'
%% remove from both without having to ask which door was used.
subscribe_ok(Pid, #state{sockets = Sockets, watchers = Watchers}) ->
    case maps:is_key(Pid, Sockets) orelse maps:is_key(Pid, Watchers) of
        true  -> false;
        false -> {ok, erlang:monitor(process, Pid)}
    end.

%% Both maps, and the monitor with whichever entry is found. `maps:take'
%% on an absent key answers `error', so the population the pid is not in
%% costs one lookup and nothing else.
forget_subscriber(Pid, State = #state{monitors = Mons, sockets = Sockets,
                                      watchers = Watchers}) ->
    {Mons1, Sockets1}  = take_subscriber(Pid, Mons,  Sockets),
    {Mons2, Watchers1} = take_subscriber(Pid, Mons1, Watchers),
    State#state{monitors = Mons2, sockets = Sockets1, watchers = Watchers1}.

take_subscriber(Pid, Mons, Subs) ->
    case maps:take(Pid, Subs) of
        {Ref, Subs1} ->
            %% `flush': a `DOWN' already on its way would otherwise arrive
            %% after the maps have forgotten the pid and fall into the
            %% `error' branch of the handler — harmless, but this way the
            %% monitor and the entry die together.
            erlang:demonitor(Ref, [flush]),
            {maps:remove(Ref, Mons), Subs1};
        error ->
            {Mons, Subs}
    end.

%%%===================================================================
%%% M4-A — the notifications of ws-driver.md §5.3
%%%===================================================================
%%
%% **Why the fan-out is here and not in the connector.** The six events
%% below are already in flight as `connector_event': every one of them is
%% raised by a `notify/2' the connector was making anyway, from six
%% clauses across three states. Reading them here costs zero new calls at
%% those six sites and leaves exactly one place that knows which events
%% are news and which of those deserve a row. The alternative — each
%% clause calling `claim_mod:notify/2' for itself — spreads the same list
%% over six sites of three states, where the next kind has to be added
%% six times or (worse) five.
%%
%% Neither arrangement lets a connector make a remote call: the hop to the
%% coordinator is `cast_leader/2' inside the claim client either way. What
%% is chosen here is only where the list lives.

%% ws-driver.md §5.3, as one table.
%%
%%   `true'  — news, and worth a row in `notifications';
%%   `false' — news, live only;
%%   `none'  — not news.
%%
%% The catch-all is the point of the table as much as the entries are.
%% `state_changed', `session_started', `session_closed',
%% `reservation_cancelled' and `no_show' all reach this function and all
%% must produce nothing — and `no_show' in particular is a `{Kind,
%% UserId}' pair exactly like the six above it, so nothing but an explicit
%% list separates it from them. It is reported to the coordinator by its
%% own path, as a penalty, and a driver who missed a reservation is told
%% by `reservation_expired' in the same breath; a second frame saying he
%% has a strike is not this channel's job.
%%
%% **Two kinds are live-only, for two different reasons.**
%%
%% `reservation_expiring' is a warning with a two-minute life. A row
%% written for it would be read the next day, when it is either wrong —
%% the driver arrived — or redundant, because the `reservation_expired'
%% written two minutes later says how it ended.
%%
%% `reservation_expired' is live-only because **the row already exists,
%% and it is a better row than ours would be**. The same lease timer that
%% raises this event also reports the no-show, and that path ends in
%% `PenaltyService.onNoShow' (:82-86), which writes a
%% `RESERVATION_EXPIRED' notification carrying the strike count — "1 of
%% 2 — reaching 2 suspends reservations for 1 day(s)". Sending our own
%% would put a second, poorer sentence about one fact next to it the day
%% R2 opens. Measured on 31/08 before it could happen, and the rule it
%% settles is worth more than the case: **two producers for one fact is
%% the defect, not the redundancy** — the question is never "is a
%% duplicate harmful?" but "who already writes this?".
durable(reservation_expiring) -> false;
durable(reservation_expired)  -> false;
durable(claim_revoked)        -> true;
durable(charge_complete)      -> true;
durable(overstay_started)     -> true;
durable(session_interrupted)  -> true;
durable(_NotNews)             -> none.

announce(ConnId, {Kind, UserId}, State) ->
    case durable(Kind) of
        none ->
            ok;
        false ->
            live(ConnId, Kind, UserId, State);
        true ->
            live(ConnId, Kind, UserId, State),
            %% Fire-and-forget, no retry, no queue — and unlike the
            %% no-show it is the *duplicate* that is harmless here and
            %% the loss that is tolerable: a second row is a line the
            %% driver reads once, a lost one is a convenience nobody is
            %% billed for. See vs_claim_client:notify/2.
            (claim_mod(State)):notify(UserId, Kind)
    end;
announce(_ConnId, _Event, _State) ->
    ok.

%% The same message to every socket, filtered by nobody here: which socket
%% may see it is a question about the token that opened it, and only that
%% socket knows the answer (vs_driver_ws, §7.3). This process holds pids,
%% not identities, and keeping it that way is what stops the manager from
%% ever becoming a second place where identity is decided.
%%
%% "Every socket" is now the literal truth of the map being walked, which
%% is B's correction: the sentence above was written about `subs', and
%% `subs' also held the claim client. The premise was false and the
%% consequence was a notification for a driver being delivered to a
%% process that has no driver, no token and no page — one that could only
%% drop it. Broadening the fan-out to a population that cannot use it was
%% never what "filtered by nobody" meant; the filtering that is refused
%% here is by **identity**, and it is refused because a socket can do it
%% and this process cannot.
live(ConnId, Kind, UserId, #state{sockets = Sockets}) ->
    fan_out({driver_notification, UserId, Kind, ConnId}, Sockets).

%% The module the connectors were given, so a test that runs the manager
%% with `vs_claim_stub' sees the durable copy in the stub's log instead of
%% casting into the void. `init/1' fills the key in unconditionally.
claim_mod(#state{child_opts = ChildOpts}) ->
    maps:get(claim_mod, ChildOpts, vs_claim_client).

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
