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

%% P18 — a second claim, so that "the round carried *everything* the
%% station holds" is an assertion about a batch and not about a singleton.
-define(VEHICLE2, 201).
-define(CONN2, 1).

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

acquire2() ->
    vs_claim_client:acquire(?VEHICLE2, ?USER, 1, ?CONN2).

%% How many messages of one kind the coordinator has received. `history_has'
%% answers "at least one", which is the wrong question for P18: the whole
%% point of the debounce is that a burst produces *exactly* one round.
count(Tag) ->
    length([M || M <- vs_mock_coord:history(), element(1, M) =:= Tag]).

renews() ->
    [M || M <- vs_mock_coord:history(), element(1, M) =:= renew].

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
%%% the penalty events (M4-A, erlang-java.md §2.4)
%%%===================================================================
%%
%% These three assert the FORM on the wire, not merely that something was
%% sent, and the reason is that getting the arity wrong fails silently in
%% production: `vs_coord_srv' matches `{no_show, _, _, _}' and
%% `{show_up, _}' exactly, and anything else lands in its catch-all —
%% "unexpected cast" in a log nobody reads, and a strike that is never
%% counted. Nothing would be red anywhere. So the equality below is on
%% the whole tuple, against a mock that only records the shapes the real
%% coordinator accepts.

%% Four elements, and the middle one is the point: the connector passed a
%% user and a connector, and the station id was filled in by the client
%% out of its own state. That is the only field of the tuple nobody but
%% this process could have supplied.
no_show_reaches_the_leader_as_the_four_tuple_test() ->
    with_client(fun() ->
        ok = vs_claim_client:no_show(?USER, ?CONN),
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {no_show, ?USER, 1, ?CONN} end)
        end)
    end).

show_up_reaches_the_leader_as_the_two_tuple_test() ->
    with_client(fun() ->
        ok = vs_claim_client:show_up(?USER),
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {show_up, ?USER} end)
        end)
    end).

%% At-most-once has a failure mode, and this is it: the leader is not
%% there, the strike is lost, and that is the accepted outcome — not a
%% crash, and not a queue that would replay it later and count it twice
%% (vs_claim_client:no_show/2 says why).
%%
%% What is asserted is the *absence* of machinery. `get_route' is a call,
%% so it cannot be answered until both casts have been handled: by the
%% time it returns, the client has already done whatever it was going to
%% do with them. An empty mailbox and a live process afterwards is what
%% "nothing was buffered, nothing is being retried" looks like from
%% outside — there is no queue to inspect because there is no queue.
%%
%% No sleep anywhere: the synchronisation is the call (P11).
%%
%% `renew_interval_ms' is pushed out of the way for the same reason the
%% announce already is, and it is not tidiness: `client_opts/0' shortens the
%% renew to 50 ms so the other tests can watch a batch go by, which puts a
%% `renew_tick' in this process's mailbox twenty times a second. The queue
%% length below would then be sampled against a timer rather than against the
%% two casts — green on an idle machine and red on a busy one, which is
%% exactly the shape of the flake P11 was about. With both timers at a
%% minute there is no periodic message left, and a zero means what it says.
penalty_events_with_an_unreachable_leader_are_dropped_test() ->
    {ok, Client} = vs_claim_client:start_link(
                     maps:merge(client_opts(),
                                #{coord_nodes       => ['nonexistent@nowhere'],
                                  renew_interval_ms => 60000})),
    try
        ok = vs_claim_client:no_show(?USER, ?CONN),
        ok = vs_claim_client:show_up(?USER),
        %% both casts have been processed by the time this returns
        ?assertMatch({'nonexistent@nowhere', _, _},
                     gen_server:call(vs_claim_client, get_route)),
        ?assert(is_process_alive(Client)),
        ?assertEqual({message_queue_len, 0},
                     process_info(Client, message_queue_len)),
        %% and the claim table is untouched: a penalty event is not a claim
        %% and must not leave a trace in the reflection
        ?assertEqual({1, []}, holds())
    after
        stop([Client]),
        wait_gone([vs_claim_client]),
        flush()
    end.

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

%% M4, and the same trap one state later. `complete' and `overstay' are
%% what a connector reports once the charge is over and the cable has not
%% come out — the definition of an outlet that is taken and not usable —
%% and an overstay lasts minutes where a `closing' lasts two seconds.
%% Without their own clauses the catch-all would drop them, and the lobby
%% would show a site as emptiest exactly when it is most blocked: the
%% failure `suspended' taught us, in the place where it would be visible
%% for longest.
a_finished_charge_still_occupies_the_outlet_in_the_lobby_stats_test() ->
    Push = fun(States) ->
                   #{connectors => [#{connector_id => N, state => S}
                                    || {N, S} <- lists:enumerate(States)]}
           end,
    ?assertEqual({0, 0, 1}, vs_claim_client:count_stats(Push([complete]))),
    ?assertEqual({0, 0, 1}, vs_claim_client:count_stats(Push([overstay]))),
    %% and they add to the same total as the other occupied states
    ?assertEqual({1, 0, 4}, vs_claim_client:count_stats(
                              Push([free, charging, suspended, complete, overstay]))).

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


%%%===================================================================
%%% the durable copy of a notification (M4-A, erlang-java.md §2.4)
%%%===================================================================
%%
%% Same reason as the penalty pair above: the shape on the wire is
%% asserted where the shape is built, because getting it wrong is silent.
%% `ErlangBridge:onNotify' reads three elements behind the tag and calls
%% `PenaltyService.onNotify(int, String, String)'; a tuple of any other
%% arity would be dropped by whatever it reached, with a log line nobody
%% is reading and a notification that simply never appears.
%%
%% What is *not* asserted here is that the real coordinator accepts it —
%% it does, and elsewhere: `vs_coord_srv' matches the 4-tuple and forwards
%% it (R2 of the PR #5 review, PR #8), and its own suite asserts that. The
%% mock is the contract's shape written down on our side of the wire, so
%% that this suite goes red here — where the tuple is built — rather than
%% at integration time, and it stays worth having now that both ends
%% agree: it is what keeps them agreeing.

%% Four elements. The two the manager passed became a user id, the binary
%% name of the kind as §5.3 spells it, and the sentence — looked up in
%% `vs_driver_proto', which is where the live frame gets it too.
a_notification_reaches_the_leader_as_the_four_tuple_test() ->
    with_client(fun() ->
        ok = vs_claim_client:notify(?USER, overstay_started),
        ok = wait_until(fun() ->
            history_has(fun(M) ->
                M =:= {notify, ?USER, <<"overstay_started">>,
                       vs_driver_proto:notification_text(overstay_started)}
            end)
        end)
    end).

%% The page and the row say the same words, and this is where that stops
%% being a comment. Both sides read the same table, so the assertion is
%% that the text on the wire is byte-for-byte the text in the live frame.
the_durable_copy_carries_the_same_sentence_as_the_live_one_test() ->
    with_client(fun() ->
        ok = vs_claim_client:notify(?USER, charge_complete),
        ok = wait_until(fun() -> history_has(fun is_notify/1) end),
        [{notify, ?USER, Kind, Text}] =
            [M || M <- vs_mock_coord:history(), is_notify(M)],
        #{payload := Payload} = vs_driver_proto:notification_frame(charge_complete, 3),
        ?assertEqual(maps:get(kind, Payload), Kind),
        ?assertEqual(maps:get(text, Payload), Text)
    end).

is_notify(M) -> is_tuple(M) andalso element(1, M) =:= notify.

%% At-most-once, and its accepted failure mode: no leader, no row, no
%% crash — and above all no queue to replay it from later. The assertion
%% is the absence of machinery, exactly as for the penalty pair: the call
%% below cannot be answered until the cast before it has been handled, so
%% an empty mailbox afterwards means nothing was buffered.
%%
%% A notification is the one of the three where a duplicate would be
%% harmless and it *still* has no retry: what would be protected is a
%% convenience, and the live copy has already reached whoever was
%% actually watching.
a_notification_with_an_unreachable_leader_is_dropped_test() ->
    {ok, Client} = vs_claim_client:start_link(
                     maps:merge(client_opts(),
                                #{coord_nodes       => ['nonexistent@nowhere'],
                                  renew_interval_ms => 60000})),
    try
        ok = vs_claim_client:notify(?USER, session_interrupted),
        ?assertMatch({'nonexistent@nowhere', _, _},
                     gen_server:call(vs_claim_client, get_route)),
        ?assert(is_process_alive(Client)),
        ?assertEqual({message_queue_len, 0},
                     process_info(Client, message_queue_len)),
        ?assertEqual({1, []}, holds())
    after
        stop([Client]),
        wait_gone([vs_claim_client]),
        flush()
    end.

%%%===================================================================
%%% P18 — a coordinator comes back, and the claims go out at once
%%%===================================================================
%%
%% The defect these six describe is not a missing mechanism: the renew
%% batch already carries every claim with its original `granted_at', and a
%% leader that rebuilt from zero answers adopts them. What was missing was
%% the *moment*. A coordinator that comes back was discovered by the next
%% `renew_tick' — up to CLAIM_RENEW_INTERVAL_MS later, 10 s in production —
%% while it starts granting reservations about 2 s after it is elected. The
%% station knew, and was waiting for a clock to ask it.
%%
%% Every one of these drives the client with a `{nodeup, …}' sent straight
%% to the process. That is not a shortcut around a cluster: `nodeup' IS an
%% `handle_info' message, so sending it is the same event the VM would
%% deliver, and the whole scenario becomes deterministic — no second node,
%% no partition, no sleep (P11: nothing here is measured on a clock).
%%
%% `renew_interval_ms => 60000' everywhere except the last one, and it is
%% part of the assertion rather than tidiness: with the tick pushed out past
%% the end of the test, a batch that shows up can only have come from the
%% `nodeup'. `client_opts/0' shortens the tick to 50 ms, which would put a
%% renew in the history twenty times a second and make every count below
%% meaningless.

%% The one that says what P18 is about: two claims, one event, both
%% re-presented at once — and the announcement with them, because a leader
%% that has just rebuilt from nothing is exactly a coordinator that has
%% never heard of this station (the reason `handle_continue(announce, …)'
%% announces before it asks the connectors).
a_coordinator_coming_back_re_presents_every_claim_at_once_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        {ok, C1, G1, _} = acquire(),
        {ok, C2, G2, _} = acquire2(),
        %% the boot announcement has landed; from here the history is ours
        ok = wait_until(fun() -> count(station_up) >= 1 end),
        ok = vs_mock_coord:reset(),
        vs_claim_client ! {nodeup, node()},
        ok = wait_until(fun() -> count(renew) >= 1 end),
        %% one round, and it carried the whole table — five fields per
        %% entry, with the coordinator-issued GrantedAt echoed back
        ?assertEqual([{renew, 1, lists:sort([{C1, ?VEHICLE,  ?CONN,  ?USER, G1},
                                             {C2, ?VEHICLE2, ?CONN2, ?USER, G2}])}],
                     [{renew, S, lists:sort(B)} || {renew, S, B} <- renews()]),
        %% and the announcement went with it
        ?assertEqual(1, count(station_up))
    end).

%% A mesh reformation is not one event. Measured on the live cluster
%% (REPORT_P18 §1.3), a station that comes back sees four `nodeup' inside
%% 271 ms — the three coordinators within 11 ms of each other. Three rounds
%% would not be dangerous (they are idempotent, and each is one
%% `call_round'), but they are noise on the path every `acquire' goes
%% through, and the cheap way to not make it is a debounce.
%%
%% The synchronisation is the `get_route' call: it is a call, so it cannot
%% be answered before all three `nodeup' messages ahead of it in this
%% process's mailbox have been handled to the end. What is counted
%% afterwards is therefore what the client *decided* to send, not what the
%% scheduler had got round to.
three_nodeups_in_a_burst_produce_one_round_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        {ok, _C, _G, _E} = acquire(),
        ok = wait_until(fun() -> count(station_up) >= 1 end),
        ok = vs_mock_coord:reset(),
        lists:foreach(fun(_) -> vs_claim_client ! {nodeup, node()} end, [1, 2, 3]),
        _ = gen_server:call(vs_claim_client, get_route),
        ok = wait_until(fun() -> count(renew) >= 1 end),
        ?assertEqual(1, count(renew)),
        ?assertEqual(1, count(station_up))
    end).

%% The filter, and it is the first of the two conditions rather than the
%% second for a reason the same measurement gives: in that burst of four,
%% the first `nodeup' to arrive was a **station**, 260 ms ahead of the
%% coordinators. A debounce stamped before the filter would let a station's
%% return eat the window and swallow the three that matter.
%%
%% Which is also how this test is built. The stranger goes first; then a
%% second claim is acquired — a synchronous round trip through the client,
%% so by the time it returns the stranger's `nodeup' has been handled to
%% the end — and only then the real one. A round provoked by the stranger
%% would carry **one** claim and would have stamped the debounce, so the
%% real `nodeup' would be swallowed and the two-claim batch below would
%% never appear: the wait times out rather than quietly passing.
a_nodeup_from_a_node_that_is_not_a_coordinator_does_nothing_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        {ok, C1, G1, _} = acquire(),
        ok = wait_until(fun() -> count(station_up) >= 1 end),
        ok = vs_mock_coord:reset(),
        vs_claim_client ! {nodeup, 'stranger@nowhere'},
        {ok, C2, G2, _} = acquire2(),
        vs_claim_client ! {nodeup, node()},
        ok = wait_until(fun() ->
            [] =/= [B || {renew, _S, B} <- renews(), length(B) =:= 2]
        end),
        ?assertEqual([{renew, 1, lists:sort([{C1, ?VEHICLE,  ?CONN,  ?USER, G1},
                                             {C2, ?VEHICLE2, ?CONN2, ?USER, G2}])}],
                     [{renew, S, lists:sort(B)} || {renew, S, B} <- renews()]),
        ?assertEqual(1, count(station_up))
    end).

%% Nothing to re-present is not a reason to stay quiet about being here.
%% The announcement is what puts this station back in the coordinator's
%% `stations' map, and adoption never does that — measured on the cluster:
%% a leader served with two adopted claims and `stations = []' for 19.7 s,
%% refusing this station's next `acquire' with `unknown_station', until the
%% 30 s announce tick came round (REPORT_P18 §2.3).
%%
%% The renew, on the other hand, is skipped for exactly the reason the tick
%% skips it: `map_size(Claims) =:= 0 -> ok'. An empty batch would be a
%% question with no content.
a_coordinator_coming_back_is_announced_to_even_with_no_claims_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        ok = wait_until(fun() -> count(station_up) >= 1 end),
        ok = vs_mock_coord:reset(),
        vs_claim_client ! {nodeup, node()},
        ok = wait_until(fun() -> count(station_up) >= 1 end),
        _ = gen_server:call(vs_claim_client, get_route),
        ?assertEqual(1, count(station_up)),
        ?assertEqual(0, count(renew))
    end).

%% The other half of the pair, and the whole of it is that nothing happens.
%%
%% A node going down does not say who serves now, and a claim client that
%% "prepared" for it — moving the leader, dropping rows, re-presenting
%% pre-emptively — would be guessing, which is the same mistake as a
%% coordinator that serves from an empty table. Degradation already has a
%% place: `{renew_result, error}' is the one moment this station knows for
%% certain that nobody answered, and that is where the flag is written.
%%
%% `holds()' is compared whole — claim id, granted_at and expires_at — so
%% "identical" means identical, not "still one row".
a_nodedown_leaves_the_claim_table_exactly_as_it_was_test() ->
    with_client(#{renew_interval_ms => 60000}, fun() ->
        {ok, _C, _G, _E} = acquire(),
        ok = wait_until(fun() -> count(station_up) >= 1 end),
        ok = vs_mock_coord:reset(),
        Before = holds(),
        ?assertMatch({1, [_]}, Before),
        vs_claim_client ! {nodedown, node()},
        %% a call: it cannot be answered before the nodedown has been handled
        Route = gen_server:call(vs_claim_client, get_route),
        ?assertEqual(Before, holds()),
        %% the leader was not moved either
        ?assertEqual({node(), [node()], 60000}, Route),
        %% nothing was sent to anybody, and nothing is queued to be
        ?assertEqual(0, count(station_up)),
        ?assertEqual(0, count(renew)),
        ?assertEqual({message_queue_len, 0},
                     process_info(whereis(vs_claim_client), message_queue_len))
    end).

%% The regression guard for the extraction. `renew_round/1' is now called
%% from two places, and the one thing that must NOT have moved into it is
%% the tick's `erlang:send_after/3': a tick that fired once and never again
%% would still pass `renew_batches_the_claims_every_tick_test', because one
%% batch is all that one asserts.
%%
%% Three batches, so the tick has re-armed itself at least twice. Bounded
%% retry, not a measurement: at the 50 ms of `client_opts/0' this leaves
%% after ~150 ms, and only a red run ever reaches the ceiling.
the_periodic_tick_still_re_arms_itself_test() ->
    with_client(fun() ->
        {ok, _C, _G, _E} = acquire(),
        ok = wait_until(fun() -> count(renew) >= 3 end)
    end).
