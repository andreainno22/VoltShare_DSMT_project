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

%% The allocator's settings are options and not only environment
%% variables so that a test can shorten the power tick instead of
%% sleeping through five seconds of it — the same reason lease_seconds is
%% an option.
start_station(Extra) ->
    vs_claim_stub:reset(),
    vs_db_stub:reset(),
    {ok, Sup} = vs_connector_sup:start_link(),
    {ok, Mgr} = vs_station_mgr:start_link(
                  maps:merge(#{station_id    => 1,
                               site_power_kw => 350,
                               connectors    => ?CONNECTORS,
                               claim_mod     => vs_claim_stub,
                               db_mod        => vs_db_stub,
                               lease_seconds => 900}, Extra)),
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
    with_station(#{}, Fun).

with_station(Extra, Fun) ->
    Ctx = start_station(Extra),
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

%% P13 — the three cases `connector_pid/1' has to tell apart, and the
%% reason they cannot stay one: the row that carries `undefined' is
%% TEMPORARY (the connector is ours, its supervisor is milliseconds
%% behind), the absent row is PERMANENT (this id is not ours). Its twin
%% `lookup_pid/1' learned the distinction in P10; this is the call side
%% of the same registry, and the driver channel is what was paying for
%% the two being answered alike.
%%
%% Deterministic by construction, not by timing: the connector supervisor
%% is held with `sys:suspend' so it cannot restart the child, which is how
%% vs_claim_client_tests forces the same window. The wait is on the
%% registry reaching the state under test — row there, pid not — and not
%% on the kill, so a failure here is an answer that is wrong rather than
%% one that was read too early.
connector_pid_tells_the_three_cases_apart_test() ->
    with_station(fun() ->
        {ok, Pid} = vs_station_mgr:connector_pid(1),
        ok = sys:suspend(vs_connector_sup),
        try
            exit(Pid, kill),
            wait_until(fun() ->
                               {error, no_pid} =:= vs_station_mgr:lookup_pid(1)
                       end),
            ?assertEqual({error, no_pid}, vs_station_mgr:connector_pid(1)),
            %% the permanent one did not move with it
            ?assertEqual({error, unknown_connector}, vs_station_mgr:connector_pid(99))
        after
            %% a suspended supervisor would queue the fixture's own
            %% shutdown too, and stop_station would sit there until eunit
            %% cancelled the group
            ok = sys:resume(vs_connector_sup)
        end
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

%%%===================================================================
%%% the power split (SCOPE §3.5) — M2 step 2
%%%===================================================================

%% Plug a car in, with everything §4.2 makes mandatory. `soc_pct' stays
%% well under TAPER_SOC_PCT unless a test says otherwise, so the demand
%% is the pair of ceilings and not the charging curve.
plug(Pid, UserId, VehicleId, MaxKw) ->
    ok = vs_connector:plugged(Pid, #{user_id => UserId, vehicle_id => VehicleId,
                                     soc_pct => 22, battery_kwh => 58.0,
                                     max_kw  => MaxKw}).

limit_of(ConnId) ->
    {ok, Pid} = vs_station_mgr:connector_pid(ConnId),
    maps:get(limit_kw, maps:get(session, vs_connector:snapshot(Pid))).

allocated() ->
    maps:get(allocated_kw, vs_station_mgr:station_state()).

near(Expected, Actual) -> abs(Expected - Actual) =< 0.001.

%% The definition changed in M2 step 2: `allocated_kw' is the sum of the
%% limits the manager granted, not of the power the meters report. The
%% two numbers differ on purpose — a car may draw less than it is allowed
%% and one that is tapering always does — and the granted figure is the
%% one that answers "how much of this site is committed".
%%
%% This test is the rewrite of the M1 one, not a new test beside it: the
%% field did not disappear, its definition moved.
allocated_kw_is_the_sum_of_the_limits_granted_test() ->
    with_station(fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        {ok, Pid2} = vs_station_mgr:connector_pid(2),
        {ok, _} = vs_connector:reserve(Pid1, ?USER, ?VEHICLE),
        plug(Pid1, ?USER, ?VEHICLE, 150),
        %% a walk-in on the other connector counts exactly the same
        plug(Pid2, 77, 5, 50),
        %% 350 kW of budget for 200 of demand: everybody gets what they ask
        wait_until(fun() -> near(200.0, allocated()) end),
        ?assert(near(150.0, limit_of(1))),
        ?assert(near(50.0, limit_of(2))),
        %% and the meters are deliberately *not* what is being summed
        vs_connector:meter(Pid1, #{power_kw => 120.5, energy_kwh => 3.0}),
        vs_connector:meter(Pid2, #{power_kw => 40.0, energy_kwh => 1.0}),
        ?assert(near(200.0, allocated()))
    end).

%% The invariant of the whole step, in one line: a site cannot hand out
%% more than it has. Two cars asking for 200 kW on a 180 kW site — the
%% hole M1 left open and this step closes.
allocated_kw_never_exceeds_the_site_budget_test() ->
    with_station(#{site_power_kw => 180}, fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        {ok, Pid2} = vs_station_mgr:connector_pid(2),
        plug(Pid1, ?USER, ?VEHICLE, 150),
        plug(Pid2, 77, 5, 50),
        wait_until(fun() -> near(180.0, allocated()) end),
        ?assert(allocated() =< maps:get(site_power_kw, vs_station_mgr:station_state())),
        %% the fair share with hand-back, on the real topology: the small
        %% car cannot absorb its 90 kW half and returns 40 of it
        ?assert(near(130.0, limit_of(1))),
        ?assert(near(50.0, limit_of(2)))
    end).

%% A departure is a recomputation like an arrival: the power the leaving
%% car was holding goes back to whoever is left, without a tick.
a_departure_returns_its_power_to_the_others_test() ->
    with_station(#{site_power_kw => 180}, fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        {ok, Pid2} = vs_station_mgr:connector_pid(2),
        plug(Pid1, ?USER, ?VEHICLE, 150),
        plug(Pid2, 77, 5, 50),
        wait_until(fun() -> near(130.0, limit_of(1)) end),
        vs_connector:unplugged(Pid2, 4.0),
        wait_until(fun() -> near(150.0, limit_of(1)) end),
        ?assert(near(150.0, allocated()))
    end).

%% The tick exists for exactly one reason: a `meter' emits no event, so a
%% car that starts tapering would otherwise keep its whole allocation
%% until somebody arrived or left. Here the small connector's car goes
%% over the taper threshold and drops to absorbing 10 kW, its demand
%% falls to 15, and the tick is what hands the other car the difference.
the_power_tick_is_what_notices_a_taper_test() ->
    with_station(#{site_power_kw => 180, power_tick_ms => 50}, fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        {ok, Pid2} = vs_station_mgr:connector_pid(2),
        plug(Pid1, ?USER, ?VEHICLE, 150),
        plug(Pid2, 77, 5, 50),
        wait_until(fun() -> near(130.0, limit_of(1)) end),
        %% no event comes out of this, by design
        vs_connector:meter(Pid2, #{power_kw => 10.0, energy_kwh => 2.0, soc_pct => 90}),
        wait_until(fun() -> near(15.0, limit_of(2)) end),
        %% the other car climbs from 130 back to its own ceiling; the 15
        %% kW the site no longer needs simply stays unallocated, because
        %% nobody can absorb it
        ?assert(near(150.0, limit_of(1))),
        ?assert(near(165.0, allocated()))
    end).

%% Below the floor a session is suspended, not starved (SCOPE §3.5): it
%% is given a limit of zero and reports itself `suspended', which is the
%% derived state of ws-driver.md §5.1 and not a sixth state of the
%% connector's machine. With the real budgets this is unreachable —
%% 350/4 and 180/3 are both far above 6 kW — so the only way to show it
%% is a site configured small, which is exactly what the demo would do.
a_suspended_connector_reports_suspended_test() ->
    with_station(#{site_power_kw => 8, min_charge_kw => 6}, fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        {ok, Pid2} = vs_station_mgr:connector_pid(2),
        plug(Pid1, ?USER, ?VEHICLE, 150),
        plug(Pid2, 77, 5, 50),
        %% 4 kW each is under the floor, so the later arrival is suspended
        %% and the first one keeps the whole 8
        wait_until(fun() -> near(+0.0, limit_of(2)) end),
        ?assert(near(8.0, limit_of(1))),
        State = vs_station_mgr:station_state(),
        ?assertEqual(suspended, maps:get(state, connector_in(State, 2))),
        %% the session is alive, not ended: it is charging at zero
        ?assertEqual(charging, maps:get(state, connector_in(State, 1))),
        ?assert(is_map(maps:get(session, connector_in(State, 2)))),
        %% and the site is still within its budget
        ?assert(near(8.0, allocated()))
    end).

%% `set_limit' is re-sent on every recomputation even at an unchanged
%% value (ws-chargepoint.md §5). What must NOT happen is the recomputation
%% producing an event of its own: that would be recompute → event →
%% recompute, a loop at full speed rather than a slow leak. The tick runs
%% here every 20 ms with a session up; if a set_limit notified, the
%% manager's mailbox would never drain.
the_recomputation_does_not_feed_itself_test() ->
    with_station(#{power_tick_ms => 20}, fun() ->
        {ok, Pid1} = vs_station_mgr:connector_pid(1),
        plug(Pid1, ?USER, ?VEHICLE, 150),
        wait_until(fun() -> near(150.0, limit_of(1)) end),
        ok = vs_station_mgr:subscribe(),
        %% drain whatever the arrival itself produced
        flush_messages(),
        timer:sleep(200),        %% ~10 ticks
        Pushes = count_pushes(0),
        ?assertEqual(0, Pushes),
        %% and the manager is alive and still answering
        ?assert(near(150.0, allocated()))
    end).

count_pushes(N) ->
    receive {station_state, _} -> count_pushes(N + 1)
    after 0 -> N
    end.


%%%===================================================================
%%% M4-A — the fan-out of the notifications (ws-driver.md §5.3)
%%%===================================================================
%%
%% The manager is where the list lives: which connector events are news
%% for a driver, and which of those are worth a row in `notifications'.
%% Both halves are asserted from the outside — a message in this process's
%% mailbox, and a call recorded by the claim stub.

%% Sends one connector event and returns what the manager did with it.
%%
%% **The synchronisation is the call, not a sleep** (P11). A gen_server
%% handles its mailbox in order, so by the time `station_state' has
%% answered, the event sent just before it has been fully handled and
%% anything it was going to push is already here. `after 0' is then exact
%% rather than optimistic, and — this is the point for the negative tests
%% — an absence measured this way is a real absence and not a race the
%% test happened to win.
what_happens_to(Event) ->
    vs_claim_stub:reset(),
    vs_station_mgr ! {connector_event, 1, Event},
    _ = vs_station_mgr:station_state(),
    {notification_in_mailbox(), vs_claim_stub:calls()}.

%% Every connector event also produces a state push (`reallocate' +
%% `broadcast'), and this process is subscribed to those too. They are
%% skipped rather than asserted on: what they contain is the subject of
%% the tests above.
notification_in_mailbox() ->
    receive
        {driver_notification, _U, _K, _C} = Msg -> Msg;
        {station_state, _}                      -> notification_in_mailbox()
    after 0 -> none
    end.

%% All six kinds of §5.3 this station can produce, live. The connector id
%% travels with them: the page needs to know which outlet the sentence is
%% about, and the sentence itself never says (vs_driver_proto).
every_kind_of_news_reaches_the_open_pages_test() ->
    with_station(fun() ->
        ok = vs_station_mgr:subscribe(),
        lists:foreach(
          fun(Kind) ->
              {Notification, _Calls} = what_happens_to({Kind, ?USER}),
              ?assertEqual({driver_notification, ?USER, Kind, 1}, Notification)
          end,
          [reservation_expiring, reservation_expired, claim_revoked,
           charge_complete, overstay_started, session_interrupted])
    end).

%% Four of the six also go to the coordinator. The two that do not are the
%% two halves of one rule: **a durable copy is for a fact nobody else
%% records**.
%%
%%   * `reservation_expiring' — nobody records it, and nobody should: the
%%     warning is true for two minutes and a row read the next day is
%%     either wrong (he arrived) or already said by the expiry.
%%   * `reservation_expired' — somebody already does. The same lease timer
%%     reports the no-show, and `PenaltyService.onNoShow' writes a
%%     `RESERVATION_EXPIRED' row **with the strike count**. Ours would be a
%%     second, poorer sentence about one fact.
%%
%% Both assertions below are on the *absence* of a call, which is the only
%% observable an at-most-once cast has: nothing comes back to look at, so a
%% cast that should not have gone out is invisible anywhere else.
four_of_the_six_are_also_worth_a_row_test() ->
    with_station(fun() ->
        ok = vs_station_mgr:subscribe(),
        lists:foreach(
          fun(Kind) ->
              {_Notification, Calls} = what_happens_to({Kind, ?USER}),
              ?assertEqual([{notify, ?USER, Kind}], Calls)
          end,
          [claim_revoked, charge_complete, overstay_started,
           session_interrupted]),
        lists:foreach(
          fun(Kind) ->
              {Notification, Calls} = what_happens_to({Kind, ?USER}),
              %% live yes, durable no — the page still hears about it
              ?assertEqual({driver_notification, ?USER, Kind, 1}, Notification),
              ?assertEqual([], Calls)
          end,
          [reservation_expiring, reservation_expired])
    end).

%% The negative, and it is the reason the routing is an explicit list
%% rather than a shape test. `no_show' is a `{Kind, UserId}' pair exactly
%% like the six above — same arity, same types — and it must produce
%% nothing at all: it is reported to the coordinator by its own path, as a
%% penalty, and a driver who missed a reservation is being told so by the
%% `reservation_expired' raised in the same breath. `session_closed'
%% carries a map where the others carry a user id, and would have been
%% caught by a shape test; the other three would not.
what_is_not_news_says_nothing_test() ->
    with_station(fun() ->
        ok = vs_station_mgr:subscribe(),
        lists:foreach(
          fun(Event) ->
              ?assertEqual({none, []}, what_happens_to(Event))
          end,
          [{state_changed, free},
           {state_changed, charging},
           {session_started, ?USER},
           {no_show, ?USER},
           {reservation_cancelled, ?USER},
           {session_closed, #{user_id => ?USER, energy_kwh => 1.0}},
           {reserved, ?USER, vs_time:now_ms()}])
    end).

%% The station keeps working when the news is for somebody who is not
%% watching: the manager holds pids, not identities, so it sends to
%% everyone and the filtering happens in the socket (vs_driver_ws, §7.3).
%% Here that means the subscriber gets a notification naming a user it is
%% not — which is exactly right, and the reason the ws test exists.
the_manager_does_not_filter_by_identity_test() ->
    with_station(fun() ->
        ok = vs_station_mgr:subscribe(),
        {Notification, _Calls} = what_happens_to({charge_complete, 999}),
        ?assertEqual({driver_notification, 999, charge_complete, 1}, Notification)
    end).

%%%===================================================================
%%% M4-A — the two populations of subscribers (B's review)
%%%===================================================================
%%
%% Not everything subscribed to this manager is a page. `vs_claim_client'
%% comes in through the cast door for the lobby's stats feed, and before
%% this fix it sat in the one `subs' map with the sockets and received
%% every `driver_notification' the station raised — to drop them in its
%% catch-all `handle_info'. Harmless per message, and on the wrong
%% process: the claim client is on the critical path of every acquire,
%% every renew tick and the P14 rebuild.
%%
%% The two doors were already distinct. What was missing was the manager
%% writing down what each one meant.

%% A stand-in for a driver socket: in through the **call** door, and it
%% can be asked what it has received. It has to be another process —
%% having both populations at once is the whole subject of the test, and
%% this one leaves the test process free to play the claim client.
socket_subscriber() ->
    Test = self(),
    Pid = spawn(fun() ->
                        ok = vs_station_mgr:subscribe(),
                        Test ! {subscribed, self()},
                        socket_loop([])
                end),
    receive {subscribed, Pid} -> Pid
    after 1000 -> erlang:error(socket_never_subscribed)
    end.

socket_loop(Seen) ->
    receive
        {what_did_you_get, From} -> From ! {got, lists:reverse(Seen)},
                                    socket_loop(Seen);
        Msg                      -> socket_loop([Msg | Seen])
    end.

%% **Exact, not optimistic** (P11). By the time the barrier call in the
%% test has returned, the manager has finished handling the event before
%% it, so every `Pid ! Msg' it was going to make has already run — and a
%% local send lands in the target's mailbox as it happens. The round trip
%% below therefore reads a mailbox that is already complete; there is
%% nothing to wait for and no sleep that would make it truer.
notifications_seen_by(Pid) ->
    Pid ! {what_did_you_get, self()},
    receive {got, Msgs} -> [M || M = {driver_notification, _, _, _} <- Msgs]
    after 1000 -> erlang:error(socket_silent)
    end.

pushes_seen_by(Pid) ->
    Pid ! {what_did_you_get, self()},
    receive {got, Msgs} -> [M || M = {station_state, _} <- Msgs]
    after 1000 -> erlang:error(socket_silent)
    end.

the_notifications_go_to_the_sockets_and_not_to_the_claim_client_test() ->
    with_station(fun() ->
        Socket = socket_subscriber(),
        try
            %% the claim client's door: a cast, answered with a seed push
            gen_server:cast(vs_station_mgr, {subscribe, self()}),
            _ = vs_station_mgr:station_state(),
            ?assertMatch({station_state, _},
                         receive S = {station_state, _} -> S
                         after 1000 -> no_seed_push
                         end),
            flush_messages(),
            %% one notification, raised the way a connector raises it
            vs_station_mgr ! {connector_event, 1, {charge_complete, ?USER}},
            _ = vs_station_mgr:station_state(),
            %% the page gets the sentence
            ?assertEqual([{driver_notification, ?USER, charge_complete, 1}],
                         notifications_seen_by(Socket)),
            %% the claim client still gets the state — the subscription is
            %% intact and this is what it subscribed for
            ?assertMatch({station_state, _},
                         receive P = {station_state, _} -> P
                         after 1000 -> no_state_push
                         end),
            %% and nothing else. `notification_in_mailbox/0' drains the
            %% remaining pushes looking for one, so `none' is the whole
            %% mailbox answering, not just the front of it.
            ?assertEqual(none, notification_in_mailbox())
        after
            exit(Socket, kill)
        end
    end).

%% The other half of the split, and the one it would be easy to break
%% while fixing the first: the state push is for **both** populations. A
%% claim client that stopped hearing about the station would stop feeding
%% the lobby, silently — `station_stats' is a cast nobody answers.
the_state_push_still_reaches_both_populations_test() ->
    with_station(fun() ->
        Socket = socket_subscriber(),
        try
            gen_server:cast(vs_station_mgr, {subscribe, self()}),
            _ = vs_station_mgr:station_state(),
            flush_messages(),
            %% an event that is not news for a driver: no notification is
            %% raised by it, so what arrives is the broadcast and only it
            vs_station_mgr ! {connector_event, 1, {state_changed, charging}},
            _ = vs_station_mgr:station_state(),
            ?assertMatch([{station_state, _} | _], pushes_seen_by(Socket)),
            ?assertMatch({station_state, _},
                         receive P = {station_state, _} -> P
                         after 1000 -> no_state_push
                         end)
        after
            exit(Socket, kill)
        end
    end).
