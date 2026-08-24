%%%-------------------------------------------------------------------
%%% @doc Tests for the station manager.
%%%
%%% Each test boots the real supervision pair — vs_connector_sup plus
%%% vs_station_mgr — with an explicit connector list, so what is being
%%% tested is the same wiring production uses, stubs standing in only
%%% for the coordinator and the database.
%%%-------------------------------------------------------------------
-module(vs_station_mgr_tests).
-include_lib("eunit/include/eunit.hrl").

-define(USER, 12).
-define(VEHICLE, 88).
-define(CONNECTORS, [{1, 150}, {2, 50}]).

%%%===================================================================
%%% fixture
%%%===================================================================

start_station() ->
    vs_claim_stub:reset(),
    vs_db_stub:reset(),
    {ok, Sup} = vs_connector_sup:start_link(),
    {ok, Mgr} = vs_station_mgr:start_link(#{station_id    => 1,
                                            site_power_kw => 350,
                                            connectors    => ?CONNECTORS,
                                            claim_mod     => vs_claim_stub,
                                            db_mod        => vs_db_stub,
                                            lease_seconds => 900}),
    {Sup, Mgr}.

stop_station({Sup, Mgr}) ->
    unlink(Mgr), exit(Mgr, shutdown),
    unlink(Sup), exit(Sup, shutdown),
    %% both are registered: the next test cannot start until the names
    %% and the named ETS table are actually gone
    wait_until(fun() ->
                       whereis(vs_station_mgr) =:= undefined
                           andalso whereis(vs_connector_sup) =:= undefined
                           andalso ets:info(vs_station_conns) =:= undefined
               end),
    flush_messages().

with_station(Fun) ->
    Ctx = start_station(),
    try Fun() after stop_station(Ctx) end.

wait_until(F) -> wait_until(F, 100).

wait_until(_F, 0) -> erlang:error(timed_out_waiting);
wait_until(F, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

flush_messages() ->
    receive _ -> flush_messages() after 0 -> ok end.

connector_in(State, ConnId) ->
    [C] = [C || C <- maps:get(connectors, State),
                maps:get(connector_id, C) =:= ConnId],
    C.

%%%===================================================================
%%% boot and registry
%%%===================================================================

boots_connectors_from_config_test() ->
    with_station(fun() ->
        State = vs_station_mgr:station_state(),
        ?assertEqual(1, maps:get(station_id, State)),
        %% the budget is carried as a value from M1; allocation is M2
        ?assertEqual(350, maps:get(site_power_kw, State)),
        [C1, C2] = maps:get(connectors, State),   %% sorted by connector id
        ?assertEqual(1,    maps:get(connector_id, C1)),
        ?assertEqual(150,  maps:get(rated_kw, C1)),
        ?assertEqual(free, maps:get(state, C1)),
        ?assertEqual(2,    maps:get(connector_id, C2)),
        ?assertEqual(50,   maps:get(rated_kw, C2)),
        ?assertEqual(free, maps:get(state, C2))
    end).

registry_resolves_connectors_test() ->
    with_station(fun() ->
        {ok, Pid} = vs_station_mgr:connector_pid(1),
        ?assert(is_pid(Pid)),
        ?assertEqual({error, unknown_connector}, vs_station_mgr:connector_pid(99))
    end).

%%%===================================================================
%%% aggregate state
%%%===================================================================

state_reflects_a_reservation_test() ->
    with_station(fun() ->
        {ok, Pid} = vs_station_mgr:connector_pid(1),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        C1 = connector_in(vs_station_mgr:station_state(), 1),
        ?assertEqual(held, maps:get(state, C1)),
        ?assertEqual(?USER, maps:get(held_by, C1)),
        %% the other connector is untouched — they are independent (P1)
        C2 = connector_in(vs_station_mgr:station_state(), 2),
        ?assertEqual(free, maps:get(state, C2))
    end).

%%%===================================================================
%%% subscriptions — the feed of the `state' push (P6)
%%%===================================================================

subscribers_get_the_complete_state_test() ->
    with_station(fun() ->
        ok = vs_station_mgr:subscribe(),
        {ok, Pid} = vs_station_mgr:connector_pid(1),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        State = expect_state(fun(S) ->
                    held =:= maps:get(state, connector_in(S, 1))
                end),
        %% complete state, not a diff: both connectors are in the push
        ?assertEqual(2, length(maps:get(connectors, State))),
        ?assertEqual(350, maps:get(site_power_kw, State))
    end).

unsubscribed_gets_no_push_test() ->
    with_station(fun() ->
        ok = vs_station_mgr:subscribe(),
        ok = vs_station_mgr:unsubscribe(),
        {ok, Pid} = vs_station_mgr:connector_pid(1),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        receive
            {station_state, _} -> erlang:error(unexpected_push)
        after 100 -> ok
        end
    end).

dead_subscriber_does_not_hurt_test() ->
    with_station(fun() ->
        Parent = self(),
        Sub = spawn(fun() ->
                        ok = vs_station_mgr:subscribe(),
                        Parent ! subscribed,
                        receive never -> ok end
                    end),
        receive subscribed -> ok after 1000 -> erlang:error(no_subscription) end,
        exit(Sub, kill),
        {ok, Pid} = vs_station_mgr:connector_pid(1),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        %% the broadcast to a dead pid is harmless and the manager lives on
        ?assertMatch(#{station_id := 1}, vs_station_mgr:station_state())
    end).

expect_state(Pred) ->
    receive
        {station_state, S} ->
            case Pred(S) of
                true  -> S;
                false -> expect_state(Pred)
            end
    after 1000 ->
        erlang:error(no_state_push)
    end.

%%%===================================================================
%%% healing — the registry survives crashes on either side
%%%===================================================================

crashed_connector_is_restarted_and_readopted_test() ->
    with_station(fun() ->
        {ok, Old} = vs_station_mgr:connector_pid(1),
        exit(Old, kill),
        %% transient: the supervisor restarts it, and its connector_up
        %% announcement re-registers the new pid — nobody polls
        wait_until(fun() ->
                           case vs_station_mgr:connector_pid(1) of
                               {ok, P} -> P =/= Old;
                               _       -> false
                           end
                   end),
        {ok, New} = vs_station_mgr:connector_pid(1),
        ?assert(erlang:is_process_alive(New)),
        %% it restarted in `free' — the safe state: without a claim it
        %% grants nothing
        ?assertEqual(free, maps:get(state, connector_in(vs_station_mgr:station_state(), 1)))
    end).

%%%===================================================================
%%% what the aggregate state learned to say for the driver channel
%%%===================================================================

%% ws-driver.md §5.1 wants more than the manager used to produce. These
%% three fields are additions: nothing that was already in the map
%% changed name or disappeared, which is what keeps vs_claim_client's
%% count_stats/1 and every assertion above green.
state_carries_the_fields_the_driver_channel_needs_test() ->
    with_station(fun() ->
        State = vs_station_mgr:station_state(),
        %% still there, unchanged
        ?assertEqual(1, maps:get(station_id, State)),
        ?assertEqual(350, maps:get(site_power_kw, State)),
        ?assertEqual(2, length(maps:get(connectors, State))),
        %% new
        ?assert(is_binary(maps:get(name, State))),
        ?assert(is_integer(maps:get(tariff_cents_kwh, State))),
        %% nothing is charging, so nothing is allocated
        ?assertEqual(0.0, maps:get(allocated_kw, State))
    end).

%% `name' and `tariff_cents_kwh' come from the same two variables
%% vs_claim_client reads for its station_up announcement. Reading the
%% environment in two places is duplication of *reading*, not of
%% *computation*: the value cannot diverge, and the alternative would
%% couple two processes the design keeps apart.
name_and_tariff_come_from_the_environment_test() ->
    os:putenv("STATION_NAME", "Pisa Centro"),
    os:putenv("TARIFF_CENTS_KWH", "42"),
    try
        with_station(fun() ->
            State = vs_station_mgr:station_state(),
            ?assertEqual(<<"Pisa Centro">>, maps:get(name, State)),
            ?assertEqual(42, maps:get(tariff_cents_kwh, State))
        end)
    after
        os:unsetenv("STATION_NAME"),
        os:unsetenv("TARIFF_CENTS_KWH")
    end.

%% Until the allocation algorithm of M2, `allocated_kw' is the sum of
%% what the connectors report drawing — a number the meters agree with,
%% rather than one nobody computed.
allocated_kw_is_the_sum_of_what_the_connectors_draw_test() ->
    with_station(fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        {ok, Pid2} = vs_station_mgr:connector_pid(2),
        {ok, _} = vs_connector:reserve(Pid1, ?USER, ?VEHICLE),
        ok = vs_connector:plugged(Pid1, #{user_id => ?USER, vehicle_id => ?VEHICLE}),
        vs_connector:meter(Pid1, #{power_kw => 120.5, energy_kwh => 3.0}),
        %% a walk-in on the other connector counts exactly the same
        ok = vs_connector:plugged(Pid2, #{user_id => 77, vehicle_id => 5}),
        vs_connector:meter(Pid2, #{power_kw => 40.0, energy_kwh => 1.0}),
        wait_until(fun() ->
                           120.5 + 40.0 =:= maps:get(allocated_kw,
                                                     vs_station_mgr:station_state())
                   end),
        ?assertEqual(160.5, maps:get(allocated_kw, vs_station_mgr:station_state()))
    end).

