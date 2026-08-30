%%%-------------------------------------------------------------------
%%% @doc Tests for the claim client, against the REAL wire protocol:
%%% every test talks to vs_mock_coord registered under the contract's
%%% name (vs_coord_srv), through the same messages the coordinator of B
%%% will serve. The last test wires the whole station together —
%%% connector → client → coordinator and back down the revocation path.
%%%-------------------------------------------------------------------
-module(vs_claim_client_tests).
-include_lib("eunit/include/eunit.hrl").

-define(USER, 12).
-define(VEHICLE, 88).
-define(CONN, 3).

%%%===================================================================
%%% fixtures
%%%===================================================================

client_opts() ->
    #{station_id           => 1,
      coord_nodes          => [node()],       %% the mock lives on this node
      %% P11: not a wait anybody is meant to sit through, but a value the
      %% scheduler must never be able to trip. The mock answers synchronously
      %% from its handle_call, and the error paths of this file are driven by
      %% explicit replies, `noproc' and `nodedown' — never by the clock. So a
      %% short timeout buys nothing here, while a saturated machine can make
      %% it fire on the happy path: that is exactly the {error, no_claim} out
      %% of nowhere that B saw. The one call that really reaches nothing
      %% overrides this value below, and says why.
      timeout_ms           => 60000,
      renew_interval_ms    => 50,             %% contract says 10 s; shortened
      announce_interval_ms => 60000,          %% out of the tests' way
      station_info         => #{name             => <<"Test Station">>,
                                ws_url           => <<"ws://test">>,
                                site_power_kw    => 350,
                                tariff_cents_kwh => 45}}.

with_client(Fun) -> with_client(#{}, Fun).

with_client(Extra, Fun) ->
    {ok, Mock}   = vs_mock_coord:start_link(),
    {ok, Client} = vs_claim_client:start_link(maps:merge(client_opts(), Extra)),
    try Fun() after
        stop([Client, Mock]),
        wait_gone([vs_claim_client, vs_coord_srv]),
        flush()
    end.

%% The full station: mock coordinator, connector supervisor, manager
%% wired to the real client. What production runs, minus the WebSockets.
with_station(Fun) ->
    {ok, Mock}   = vs_mock_coord:start_link(),
    {ok, Sup}    = vs_connector_sup:start_link(),
    {ok, Mgr}    = vs_station_mgr:start_link(#{station_id    => 1,
                                               site_power_kw => 350,
                                               connectors    => [{?CONN, 150}],
                                               claim_mod     => vs_claim_client,
                                               db_mod        => vs_db_stub,
                                               lease_seconds => 900}),
    {ok, Client} = vs_claim_client:start_link(client_opts()),
    vs_db_stub:reset(),
    try Fun() after
        stop([Client, Mgr, Sup, Mock]),
        wait_gone([vs_claim_client, vs_station_mgr, vs_connector_sup, vs_coord_srv]),
        flush()
    end.

stop(Pids) ->
    lists:foreach(fun(Pid) -> unlink(Pid), exit(Pid, shutdown) end, Pids).

wait_gone(Names) ->
    wait_until(fun() ->
                       lists:all(fun(N) -> whereis(N) =:= undefined end, Names)
               end).

%% P11: a bounded retry, not an assertion about time. On the green path this
%% leaves at the first truth and never spends the ceiling, so raising it from
%% 100 to 300 (3 s) costs nothing there and only makes an already-red run take
%% longer to say so. Nothing in this file asserts that the ceiling is reached.
wait_until(F) -> wait_until(F, 300).

wait_until(_F, 0) -> erlang:error(timed_out_waiting);
wait_until(F, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.

history_has(Pred) ->
    lists:any(Pred, vs_mock_coord:history()).

acquire() ->
    vs_claim_client:acquire(?VEHICLE, ?USER, 1, ?CONN).

%% P15 — who is monitoring this process. The manager monitors every
%% connector too (its registry heals on the DOWN), so the assertions
%% below are about membership, never about the whole list.
monitored_by(Pid) ->
    {monitored_by, Pids} = process_info(Pid, monitored_by),
    Pids.

monitors(Watcher, Pid) -> lists:member(Watcher, monitored_by(Pid)).

%% P14 — the restart REPORT_M3A_VERIFICA §6.1 measured: `exit(kill)', so
%% nothing gets to run a cleanup, and a brand new process that comes up
%% with `claims = #{}'. The caller stops the replacement itself: the
%% fixture's teardown holds the pid of the client it started, not of this
%% one.
restart_client() ->
    Old = whereis(vs_claim_client),
    unlink(Old),
    exit(Old, kill),
    wait_gone([vs_claim_client]),
    {ok, New} = vs_claim_client:start_link(client_opts()),
    New.

%% Ask the client what it holds, with the contract's own message (§3.4).
holds() ->
    vs_claim_client ! {who_do_you_hold, self(), node()},
    receive
        {holds, StationId, Holds} -> {StationId, Holds}
    after 5000 ->
        %% P11: same class as wait_until's ceiling — the reply comes straight
        %% out of the client's handle_info, so this branch is only ever
        %% reached in a run that is already red.
        erlang:error(no_holds_reply)
    end.

%%%===================================================================
%%% announcement and acquire
%%%===================================================================

announces_itself_on_boot_test() ->
    with_client(fun() ->
        ok = wait_until(fun() ->
            history_has(fun({station_up, 1, _Node, <<"Test Station">>, <<"ws://test">>,
                             350, 45, _Connectors}) -> true;
                           (_) -> false end)
        end)
    end).

acquire_happy_path_test() ->
    with_client(fun() ->
        {ok, ClaimId, GrantedAt, ExpiresAt} = acquire(),
        ?assert(is_binary(ClaimId)),
        ?assert(ExpiresAt > vs_time:now_ms()),
        %% P14 — four elements, and the second is the coordinator's own
        %% `GrantedAt'. It used to stop inside do_acquire/4; the connector
        %% needs it because the connector is the half that survives a
        %% restart of the client.
        ?assert(GrantedAt =< vs_time:now_ms()),
        ?assert(GrantedAt < ExpiresAt),
        %% the wire request carried exactly what the contract says
        ?assert(history_has(fun({claim, _ReqId, ?VEHICLE, ?USER, 1, ?CONN}) -> true;
                               (_) -> false end))
    end).

wire_refusals_are_mapped_to_connector_atoms_test() ->
    with_client(fun() ->
        lists:foreach(
          fun({Wire, Refusal}) ->
              ok = vs_mock_coord:set_reply({error, Wire}),
              ?assertEqual({error, Refusal}, acquire())
          end,
          %% The input is what the coordinator really sends (claim.md §3.1);
          %% only the name it is given inside the station changes. In the
          %% coordinator's vocabulary `already_held' is about the VEHICLE,
          %% so it arrives as `vehicle_committed' — the station's own
          %% `already_held' means the CONNECTOR is taken and is raised by
          %% vs_connector, never here.
          [{already_held, vehicle_committed},
           {suspended,    suspended},
           {rebuilding,   retry_later}])
    end).

%% §4: not_serving with no leader → next node; the list is one node long,
%% so the pass ends and the reservation is refused — never queued.
exhausted_discovery_refuses_with_no_claim_test() ->
    with_client(fun() ->
        ok = vs_mock_coord:set_reply({not_serving, undefined}),
        ?assertEqual({error, no_claim}, acquire()),
        ?assertEqual({1, []}, holds())
    end).

%% P11: the one call in this file that is meant to reach nothing, and the
%% only one that pays for it in wall clock. The comment in `call_one' says a
%% non-distributed node raises `badarg' for a remote name — but our test node
%% IS distributed (`{dist_node, [{sname, vs}]}' in rebar.config: node() is
%% `vs@<host>'), so the name costs a DNS/epmd lookup that fails as `nodedown'
%% after ~2.5 s instead. The outcome does not depend on which of the two
%% happens — `call_one' catches everything into `unreachable' — so the short
%% timeout asserts nothing about time: it is a deterministic bound on a
%% lookup latency this suite does not control, kept well under eunit's 5 s
%% ?DEFAULT_TEST_TIMEOUT (eunit_internal.hrl), which would otherwise cancel
%% this test and take its count with it.
no_coordinator_at_all_refuses_with_no_claim_test() ->
    {ok, Client} = vs_claim_client:start_link(
                     maps:merge(client_opts(),
                                #{coord_nodes => ['nonexistent@nowhere'],
                                  timeout_ms  => 500})),
    try
        ?assertEqual({error, no_claim}, acquire())
    after
        stop([Client]),
        wait_gone([vs_claim_client]),
        flush()
    end.

%%%===================================================================
%%% the claim table: release, rebuild query, renew
%%%===================================================================

release_reaches_the_coordinator_and_empties_the_table_test() ->
    with_client(fun() ->
        {ok, ClaimId, _GrantedAt, _ExpiresAt} = acquire(),
        ok = vs_claim_client:release(ClaimId, cancelled),
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {release, ClaimId, cancelled} end)
        end),
        ?assertEqual({1, []}, holds())
    end).

who_do_you_hold_answers_from_memory_test() ->
    with_client(fun() ->
        %% Binding GrantedAt here and matching it again below is the
        %% assertion, not decoration: what `acquire' hands back to the
        %% connector must be the very number this table stores and echoes.
        {ok, ClaimId, GrantedAt, ExpiresAt} = acquire(),
        {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, ExpiresAt}]} = holds(),
        ?assert(GrantedAt =< vs_time:now_ms()),
        ?assert(GrantedAt < ExpiresAt),
        %% the property the 24/08 contract PR buys: the SAME GrantedAt the
        %% coordinator issued comes back identical in the renew echo — the
        %% station never invents a timestamp, one clock orders the claims
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {renew, 1, [{ClaimId, ?VEHICLE, ?CONN,
                                                     ?USER, GrantedAt}]} end)
        end)
    end).

renew_batches_the_claims_every_tick_test() ->
    with_client(fun() ->
        {ok, ClaimId, _GrantedAt, _ExpiresAt} = acquire(),
        %% within a couple of (shortened) ticks the batch shows up, in
        %% the five-field form of the 24/08 contract PR — echoing the
        %% coordinator-issued GrantedAt, never a local timestamp
        ok = wait_until(fun() ->
            history_has(fun({renew, 1, [{Cid, ?VEHICLE, ?CONN, ?USER, GrantedAt}]}) ->
                                Cid =:= ClaimId andalso is_integer(GrantedAt);
                           (_) -> false end)
        end)
    end).

%%%===================================================================
%%% end to end: the revocation path (claim.md §3.2, §5.4)
%%%===================================================================

%% The lobby feed (B's StationDirectory): stats are event-driven and
%% deduplicated — the boot seed says "all free", a reservation flips it.
station_stats_follow_the_reservations_test() ->
    with_station(fun() ->
        %% boot: the cast-subscription seeds {free=1, held=0, charging=0}
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {station_stats, 1, 1, 0, 0} end)
        end),
        {ok, Pid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {station_stats, 1, 0, 1, 0} end)
        end)
    end).

%% `suspended' counts as charging. It is not a state of the connector's
%% machine but what a charging session at a limit of zero reports since
%% M2 step 2, so without its own clause it would fall into the catch-all
%% and vanish from the three numbers — a connector with somebody's car in
%% it, reported to the lobby as neither free, nor held, nor charging.
%%
%% count_stats/1 is a function of a map, so the map is built by hand
%% here: no station, no allocator, no budget small enough to starve
%% anybody, just the shape the manager pushes.
suspended_counts_as_charging_in_the_lobby_stats_test() ->
    Push = fun(States) ->
                   #{connectors => [#{connector_id => N, state => S}
                                    || {N, S} <- lists:enumerate(States)]}
           end,
    ?assertEqual({0, 0, 1}, vs_claim_client:count_stats(Push([suspended]))),
    %% and it adds to the same total as a charging one, rather than
    %% replacing it
    ?assertEqual({1, 1, 3}, vs_claim_client:count_stats(
                              Push([free, held, charging, suspended, closing]))),
    %% offline is still nothing, which is why the three may add up to
    %% less than the number of connectors
    ?assertEqual({0, 0, 1}, vs_claim_client:count_stats(
                              Push([offline, suspended]))).

revocation_travels_from_coordinator_to_connector_test() ->
    with_station(fun() ->
        {ok, Pid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ExpiresAt} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual(held, maps:get(state, vs_connector:snapshot(Pid))),
        %% the coordinator turns hostile: next renew revokes everything
        ok = vs_mock_coord:set_renew(revoke_all),
        %% ... and within a few ticks the connector has obeyed (§5.4)
        ok = wait_until(fun() ->
            free =:= maps:get(state, vs_connector:snapshot(Pid))
        end),
        %% the client dropped the claim too: nothing left to renew
        ?assertEqual({1, []}, holds())
    end).

%% P10 — the revocation that used to kill the process holding every claim
%% of the station.
%%
%% `revoke/2' asks the registry for the connector's pid and had exactly two
%% clauses, `{ok, Pid}' and `{error, unknown_connector}'. Since
%% `vs_station_mgr:lookup_pid/1' tells the three cases apart, a revocation
%% that lands while the connector is between its death and its restart
%% answers `{error, no_pid}' — a case_clause inside `handle_info', i.e. the
%% claim client dies and takes every claim of the station with it. The
%% clause is `{error, _}' now, and this is the window in which that matters.
%%
%% Deterministic by construction: the connector supervisor is held with
%% `sys:suspend' so that it cannot restart the child, which is exactly how
%% the E2E of REPORT_CP_TOUCHUPS §6 forces the same window on a real socket.
%%
%% P15 moved this window, and the test has to move with it. A claim asked
%% for BY the connector now dies with the connector, so a revocation that
%% lands after the kill would find nothing to revoke: the test would stay
%% green while exercising none of the branch it was written for.
%%
%% The window is still real in production — the client's mailbox can hold
%% a `renew_result' ahead of the `DOWN', and then `revoke/2' runs with the
%% claim present and the connector already gone — and this is the
%% deterministic way to produce it: the claim's owner is the test process,
%% which outlives the connector on purpose. What is under test is
%% `revoke/2' reading the registry, which is where the P10 crash was, and
%% not who happens to own the claim.
a_revocation_while_the_connector_restarts_does_not_kill_the_client_test() ->
    with_station(fun() ->
        Client = whereis(vs_claim_client),
        {ok, Pid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ClaimId, _GrantedAt, _ExpiresAt} = acquire(),
        ok = sys:suspend(vs_connector_sup),
        try
            exit(Pid, kill),
            %% wait for the registry to be in the P10 state itself, rather
            %% than for the kill: the row is there, the pid is not
            ok = wait_until(fun() ->
                {error, no_pid} =:= vs_station_mgr:lookup_pid(?CONN)
            end),
            %% ... and only then let the coordinator revoke everything
            ok = vs_mock_coord:set_renew(revoke_all),
            ok = wait_until(fun() -> {1, []} =:= holds() end),
            %% the claim is gone AND the client is the same process it was:
            %% "it survived" is an assertion here, not something inferred
            %% from the fact that it answered
            ?assertEqual(Client, whereis(vs_claim_client)),
            ?assert(is_process_alive(Client))
        after
            %% a suspended supervisor would queue the shutdown of the
            %% fixture too, and `wait_gone' would sit there until eunit
            %% cancelled the whole group
            ok = sys:resume(vs_connector_sup)
        end
    end).

%%%===================================================================
%%% the reachability flag the driver channel shows (ws-driver.md §5.1)
%%%===================================================================

%% Before the client has booted there is no table, and the answer is
%% `true'. Optimistic on purpose: nothing has been tried, so nothing has
%% failed, and refusing reservations would be a failure this station
%% invented rather than one it measured.
coordinator_reachable_is_optimistic_before_the_client_boots_test() ->
    ok = wait_until(fun() -> ets:info(vs_claim_reach) =:= undefined end),
    ?assert(vs_claim_client:coordinator_reachable()).

%% The declared semantics, end to end: "the last renew round found a
%% coordinator". Not a ping — the outcome of work the station actually
%% did. The coordinator is killed under a live claim, the next renew
%% round comes back empty-handed, and the flag drops; when it returns,
%% so does the flag. §7.6: the station degrades, it does not stop.
coordinator_reachable_follows_the_renew_outcome_test() ->
    {ok, Mock}   = vs_mock_coord:start_link(),
    {ok, Client} = vs_claim_client:start_link(client_opts()),
    try
        ?assert(vs_claim_client:coordinator_reachable()),
        %% a claim, so that the renew tick has something to renew
        {ok, _ClaimId, _GrantedAt, _ExpiresAt} = acquire(),
        stop([Mock]),
        wait_gone([vs_coord_srv]),
        ok = wait_until(fun() -> not vs_claim_client:coordinator_reachable() end),
        %% ... and the claim was kept through it: a failed renew is not a
        %% revocation (claim.md §5.4), which is exactly why the flag had
        %% to be published separately from the claim table
        {1, [_TheClaim]} = holds(),
        {ok, Mock2} = vs_mock_coord:start_link(),
        try
            ok = wait_until(fun() -> vs_claim_client:coordinator_reachable() end)
        after
            stop([Mock2]),
            wait_gone([vs_coord_srv])
        end
    after
        stop([Client]),
        wait_gone([vs_claim_client]),
        flush()
    end.

%% The named table is created in init/1, and these fixtures start a
%% client several times in one VM. Teardown waits for the registered
%% *name*, which a dying process gives up at a slightly different moment
%% from its ETS tables — so `ets:new' can meet a leftover. This is that
%% sequence, on purpose.
the_reachability_table_survives_a_client_restart_test() ->
    {ok, First} = vs_claim_client:start_link(client_opts()),
    stop([First]),
    wait_gone([vs_claim_client]),
    {ok, Second} = vs_claim_client:start_link(client_opts()),
    try
        ?assert(vs_claim_client:coordinator_reachable())
    after
        stop([Second]),
        wait_gone([vs_claim_client]),
        flush()
    end.

%%%===================================================================
%%% P15 — the claim dies with the connector that held it
%%%===================================================================

%% The premise the whole design rests on, asserted instead of read.
%% `handle_call({granted, …})' monitors its caller, and the caller must be
%% the connector's own gen_statem process: if either of the two call
%% sites in `do_acquire/4' ran in a throwaway process, the monitor would
%% land on that process and the claim would die a microsecond after it
%% was granted.
%%
%% It has to go through `with_station'. The `acquire/0' helper above
%% calls the client from the TEST process — a legitimate owner, and
%% exactly the wrong one to assert on.
the_claim_is_monitored_on_the_connector_that_asked_for_it_test() ->
    with_station(fun() ->
        Client = whereis(vs_claim_client),
        {ok, ConnPid} = vs_station_mgr:connector_pid(?CONN),
        %% synchronous all the way down: `reserve' returns only after the
        %% client has answered `{granted, …}', so there is nothing to wait
        %% for here
        {ok, _ExpiresAt} = vs_connector:reserve(ConnPid, ?USER, ?VEHICLE),
        ?assert(monitors(Client, ConnPid))
    end).

%% §6.2, closed. A connector killed while `held' never runs `terminate/3',
%% so no release went out and the client kept renewing a claim nobody
%% owned — for ever, because the coordinator recomputes the expiry on
%% every round. The `DOWN' is the one notification `kill' cannot suppress.
a_killed_connector_releases_its_claim_test() ->
    with_station(fun() ->
        {ok, ConnPid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ExpiresAt} = vs_connector:reserve(ConnPid, ?USER, ?VEHICLE),
        {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, _}]} = holds(),
        exit(ConnPid, kill),
        %% the table empties itself ...
        ok = wait_until(fun() -> {1, []} =:= holds() end),
        %% ... and the coordinator is told, with one of the four words
        %% claim.md §3.3 allows — no new atom on the wire
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {release, ClaimId, cancelled} end)
        end)
    end).

%% Every exit from the table drops the monitor with it. A monitor left on
%% a claim that is gone would deliver a `DOWN' matching nothing —
%% harmless today, and precisely the kind of leak that becomes a puzzle
%% six months later.
a_released_claim_leaves_no_monitor_behind_test() ->
    with_station(fun() ->
        Client = whereis(vs_claim_client),
        {ok, ConnPid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ExpiresAt} = vs_connector:reserve(ConnPid, ?USER, ?VEHICLE),
        ?assert(monitors(Client, ConnPid)),
        %% the driver cancels: connector → release → the claim goes. The
        %% release is a call made from inside `cancel', so by the time
        %% `cancel' has returned the client has already done the removal.
        ok = vs_connector:cancel(ConnPid, ?USER),
        ?assertEqual({1, []}, holds()),
        ?assertNot(monitors(Client, ConnPid))
    end).

a_revoked_claim_leaves_no_monitor_behind_test() ->
    with_station(fun() ->
        Client = whereis(vs_claim_client),
        {ok, ConnPid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ExpiresAt} = vs_connector:reserve(ConnPid, ?USER, ?VEHICLE),
        ?assert(monitors(Client, ConnPid)),
        %% the coordinator revokes on the next renew (claim.md §5.4)
        ok = vs_mock_coord:set_renew(revoke_all),
        ok = wait_until(fun() -> {1, []} =:= holds() end),
        %% the connector obeyed and is still alive — so a monitor left on
        %% it would still be there to find
        ok = wait_until(fun() ->
            free =:= maps:get(state, vs_connector:snapshot(ConnPid))
        end),
        ?assertNot(monitors(Client, ConnPid))
    end).

%%%===================================================================
%%% P14 — the client asks the connectors for what it forgot
%%%===================================================================

%% §6.1, closed, with the sequence that was measured: a live reservation,
%% `exit(whereis(vs_claim_client), kill)', and the replacement answering
%% `who_do_you_hold' with nothing — which is what let the first election
%% hand the same vehicle a second reservation on another station.
%%
%% `GrantedAt' is matched, not ignored: it is the coordinator's own
%% timestamp, it is what claim.md §5.5 settles conflicts on, and the only
%% reason the connector carries it is so that it can come back here.
%% `ExpiresAt' is not matched — the renew loop moves it every tick, by
%% design.
a_restarted_client_rebuilds_its_claims_from_the_connectors_test() ->
    with_station(fun() ->
        {ok, ConnPid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ExpiresAt} = vs_connector:reserve(ConnPid, ?USER, ?VEHICLE),
        {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, _}]} = holds(),
        New = restart_client(),
        try
            ok = wait_until(fun() ->
                case holds() of
                    {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, E}]} ->
                        is_integer(E);
                    _Empty ->
                        false
                end
            end),
            %% and it is a claim like any other: monitored on its owner,
            %% so the rebuilt table is not a second-class copy
            ?assert(monitors(New, ConnPid))
        after
            stop([New]),
            wait_gone([vs_claim_client])
        end
    end).

%% The half that `held' alone would leave open. `held → charging' hands
%% the reservation in and discards the `#hold' (D-8), so after the cable
%% goes in the claim lives in `#session' — and a client that restarts
%% mid-session has to get it back from there, with the coordinator's two
%% timestamps intact. That is the whole reason `#session' carries them.
a_charging_connector_presents_its_claim_too_test() ->
    with_station(fun() ->
        {ok, ConnPid} = vs_station_mgr:connector_pid(?CONN),
        {ok, _ExpiresAt} = vs_connector:reserve(ConnPid, ?USER, ?VEHICLE),
        ok = vs_connector:plugged(ConnPid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                             soc_pct => 22, battery_kwh => 58.0,
                                             max_kw => 150}),
        ?assertEqual(charging, maps:get(state, vs_connector:snapshot(ConnPid))),
        {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, _}]} = holds(),
        New = restart_client(),
        try
            ok = wait_until(fun() ->
                case holds() of
                    {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, E}]} ->
                        is_integer(E);
                    _Empty ->
                        false
                end
            end)
        after
            stop([New]),
            wait_gone([vs_claim_client])
        end
    end).

%% Race (b) of the plan, which its own table listed as NOT VERIFIED: a
%% connector that is already dead when its answer is handled.
%% `erlang:monitor/2' on a dead pid delivers a `DOWN' with `noproc' at
%% once, so the claim is inserted and taken straight back out — no
%% special case anywhere in the code, and this is the proof.
%%
%% Deterministic without a clock: the cast and the `who_do_you_hold' both
%% travel from this process, so the claim IS in the table when the first
%% answer comes back, and the `DOWN' queued behind it takes it out.
a_claim_presented_by_a_dead_connector_is_dropped_at_once_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        Dead = spawn(fun() -> ok end),
        ok = wait_until(fun() -> not is_process_alive(Dead) end),
        ClaimId = <<"c-orphan">>,
        gen_server:cast(vs_claim_client,
                        {claim_present, Dead, ClaimId, ?VEHICLE, ?USER, ?CONN,
                         vs_time:now_ms(), vs_time:in_seconds(960)}),
        ?assertMatch({1, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, _}]}, holds()),
        ok = wait_until(fun() -> {1, []} =:= holds() end),
        %% and the coordinator hears that the vehicle is free again
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {release, ClaimId, cancelled} end)
        end)
    end).

%%%===================================================================
%%% the safety net (piano §1.4)
%%%===================================================================

%% It closes neither defect on its own — the claim of §6.2 was never
%% expired, it was being rejuvenated ten seconds at a time — and it is
%% here for the failure nobody has thought of yet. What it must not be is
%% silent, so the drop is logged at `warning'.
%%
%% The claim goes in through the rebuild cast — the only door that lets a
%% test choose the expiry, and it costs the mock coordinator no new knob —
%% and is then CONFIRMED by hand-delivering the renew reply the client
%% already handles, with an expiry that has passed. That is the real
%% shape of "a coordinator told us this claim dies at T, and T is behind
%% us". The tick is driven by hand too, so nothing here waits on a timer.
an_expired_claim_is_dropped_instead_of_renewed_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        ClaimId = <<"c-already-dead">>,
        Now = vs_time:now_ms(),
        gen_server:cast(vs_claim_client,
                        {claim_present, self(), ClaimId, ?VEHICLE, ?USER, ?CONN,
                         Now - 2000, vs_time:in_seconds(960)}),
        %% same sender, same mailbox: the cast is processed before this
        ?assertMatch({1, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, _}]}, holds()),
        %% the coordinator's own word, and it says the claim is already over
        vs_claim_client ! {renew_result, {ok, node(), {renewed, [ClaimId], [], Now - 1000}}},
        vs_claim_client ! renew_tick,
        ?assertEqual({1, []}, holds()),
        %% and it was never offered to the coordinator afterwards
        ?assertNot(history_has(fun({renew, 1, Batch}) ->
                                      lists:keymember(ClaimId, 1, Batch);
                                 (_) ->
                                      false
                              end))
    end).

%% The other side of the same qualifier, and the reason it exists.
%%
%% A connector presents the expiry it copied when the claim was granted;
%% the coordinator has been pushing the real one forward ever since. The
%% two diverge by design, and a charging session outlives lease+grace
%% routinely — so a client restarting during one rebuilds a claim whose
%% local expiry is already behind. Sweeping it would undo the rebuild one
%% tick later and shout about a station that is perfectly healthy.
%%
%% What must happen instead: the claim stays, and it goes into the batch,
%% because the coordinator is the only party that knows. It answers by
%% adopting it or by revoking it (claim.md §5.4), and one round settles
%% it — measured on the live cluster, where a rebuilt claim's expiry was
%% corrected at the very first renew.
a_rebuilt_claim_with_a_stale_expiry_is_asked_about_not_dropped_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        ClaimId = <<"c-stale-copy">>,
        Now = vs_time:now_ms(),
        gen_server:cast(vs_claim_client,
                        {claim_present, self(), ClaimId, ?VEHICLE, ?USER, ?CONN,
                         Now - 990000, Now - 1000}),
        ?assertMatch({1, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, _}]}, holds()),
        vs_claim_client ! renew_tick,
        %% not dropped ...
        ?assertMatch({1, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, _}]}, holds()),
        %% ... and put to the only party that can settle it
        ok = wait_until(fun() ->
            history_has(fun({renew, 1, Batch}) -> lists:keymember(ClaimId, 1, Batch);
                           (_) -> false
                        end)
        end),
        %% the mock renews it, so the expiry it comes back with is a real
        %% one and the claim is now confirmed
        ok = wait_until(fun() ->
            case holds() of
                {1, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, E}]} -> E > vs_time:now_ms();
                _Gone -> false
            end
        end)
    end).

