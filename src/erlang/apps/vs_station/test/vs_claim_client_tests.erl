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
      timeout_ms           => 500,
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

wait_until(F) -> wait_until(F, 100).

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

%% Ask the client what it holds, with the contract's own message (§3.4).
holds() ->
    vs_claim_client ! {who_do_you_hold, self(), node()},
    receive
        {holds, StationId, Holds} -> {StationId, Holds}
    after 1000 ->
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
        {ok, ClaimId, ExpiresAt} = acquire(),
        ?assert(is_binary(ClaimId)),
        ?assert(ExpiresAt > vs_time:now_ms()),
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

no_coordinator_at_all_refuses_with_no_claim_test() ->
    {ok, Client} = vs_claim_client:start_link(
                     maps:merge(client_opts(),
                                #{coord_nodes => ['nonexistent@nowhere']})),
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
        {ok, ClaimId, _} = acquire(),
        ok = vs_claim_client:release(ClaimId, cancelled),
        ok = wait_until(fun() ->
            history_has(fun(M) -> M =:= {release, ClaimId, cancelled} end)
        end),
        ?assertEqual({1, []}, holds())
    end).

who_do_you_hold_answers_from_memory_test() ->
    with_client(fun() ->
        {ok, ClaimId, ExpiresAt} = acquire(),
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
        {ok, ClaimId, _} = acquire(),
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
        {ok, _ClaimId, _} = acquire(),
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

