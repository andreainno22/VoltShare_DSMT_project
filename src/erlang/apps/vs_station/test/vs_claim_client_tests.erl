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
          [{already_held, already_held},
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
