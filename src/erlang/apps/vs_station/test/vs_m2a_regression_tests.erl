%%%-------------------------------------------------------------------
%%% @doc M2-A — regression tests for the nine defects of the review.
%%%
%%% These began life as `vs_review_m2a_tests': ten tests written by a
%%% review session to FAIL, one per defect found in `REVIEW_M2A_ESITO.md'.
%%% They stayed out of the tree while the two batches of corrections closed
%%% the defects one at a time — five in batch 1 (D-1, D-2, D-6, D-7), five
%%% in batch 2 (D-3, D-4, D-5, D-8, D-9) — and they are here now because
%%% they are all green: from this point they are regression tests like any
%%% other, and the name says so.
%%%
%%% Three of them were re-pointed while the defect they describe was being
%%% closed, and each one carries a NOTE saying what changed and why. The
%%% rule followed every time: an assertion may move to where the defect is
%%% actually fixed, but it may not be weakened — each re-pointed test was
%%% re-run against the uncorrected sources and had to still fail.
%%%
%%% What each test is for, and where the defect lived:
%%%
%%%   D-1  energy already written to a row is never written to a second
%%%        one          (`vs_connector', the offset)
%%%   D-2  the row carries the total the hardware reports
%%%                     (`vs_connector', the settle window)
%%%   D-3  a car that tapers below the floor does not flap
%%%                     (`vs_power', suspension only for scarcity)
%%%   D-4  a `plugged' with no usable `max_kw' opens no session
%%%                     (`vs_cp_proto', the mandatory field of §4.2)
%%%   D-5  a row handed to a writer that is not there is logged, not lost
%%%                     (`vs_station_db:insert_session/1')
%%%   D-6  a failing announcement does not take the writer down
%%%                     (`vs_station_db:write/4')
%%%   D-7  a row that cannot be encoded does not wedge the queue
%%%                     (`vs_station_db:params/1')
%%%   D-8  a charging connector reports no reservation
%%%                     (`vs_connector', the hold cleared)
%%%
%%% D-9 is not here: it is arithmetic on two timeouts, and it is asserted
%%% in `vs_cp_proto_tests' next to the socket it belongs to.
%%%-------------------------------------------------------------------
-module(vs_m2a_regression_tests).
-include_lib("eunit/include/eunit.hrl").
-export([log/2]).

-define(USER, 12).
-define(VEHICLE, 88).

%%%===================================================================
%%% fixture (copied from vs_connector_tests: helpers are not exported)
%%%===================================================================

start_connector(Extra) ->
    vs_claim_stub:reset(),
    vs_db_stub:reset(),
    Opts = maps:merge(#{conn_id       => 3,
                        station_id    => 1,
                        rated_kw      => 150,
                        lease_seconds => 900,
                        claim_mod     => vs_claim_stub,
                        db_mod        => vs_db_stub,
                        %% M2 fix 1 (D-2): `closing' now waits for the charge
                        %% point's last word before writing. Two seconds is
                        %% right in production and dead time here, so the
                        %% fixture shortens it exactly as it shortens
                        %% `cp_grace_ms' -- the behaviour under test is what
                        %% gets written, never how long the wait is.
                        closing_settle_ms => 100,
                        notify_to     => self()}, Extra),
    {ok, Pid} = vs_connector:start_link(Opts),
    Pid.

stop_connector(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    flush_events().

flush_events() ->
    receive {connector_event, _, _} -> flush_events()
    after 0 -> ok
    end.

with_connector(Opts, Fun) ->
    Pid = start_connector(Opts),
    try Fun(Pid) after stop_connector(Pid) end.

state_of(Pid) -> maps:get(state, vs_connector:snapshot(Pid)).

fake_cp() ->
    Test = self(),
    spawn(fun() -> cp_loop(Test) end).

cp_loop(Test) ->
    receive Msg -> Test ! {cp_got, self(), Msg}, cp_loop(Test) end.

stop_cp(Pid) -> exit(Pid, kill).

expect_event(Kind) ->
    receive
        {connector_event, _ConnId, Event} when element(1, Event) =:= Kind -> Event;
        {connector_event, _ConnId, _Other} -> expect_event(Kind)
    after 1000 -> erlang:error({no_event, Kind})
    end.

plug(Pid, Energy) ->
    vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                soc_pct => 22, battery_kwh => 58.0,
                                max_kw => 150, energy_kwh => Energy}).

billed(Rows) -> lists:sum([maps:get(energy_kwh, R) || R <- Rows]).

%%%===================================================================
%%% D-1  the charge point goes quiet past the grace, then comes back:
%%%      the energy counted before the fault is written twice
%%%===================================================================

grace_close_then_reconnect_bills_the_energy_twice_test() ->
    with_connector(#{cp_grace_ms => 100}, fun(Pid) ->
        Cp1 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp1),
        ok = plug(Pid, 0.0),
        %% 12 kWh delivered and metered
        vs_connector:meter(Pid, #{energy_kwh => 12.0, power_kw => 50.0}),
        %% the socket dies and stays dead past the grace: contract 3.2
        %% closes the session with the last measured energy -> row 1 = 12.0
        stop_cp(Cp1),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),

        %% contract 6: the hardware never stopped delivering and never
        %% stopped counting. It reconnects and re-announces the cable with
        %% its cumulative total (cp.js keeps car.energyKwh across the
        %% reconnection and sends it in plugged).
        Cp2 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp2),
        ok = plug(Pid, 12.0),
        ?assertEqual(charging, state_of(Pid)),
        %% the car finishes at 20 kWh delivered in total
        vs_connector:unplugged(Pid, 20.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),

        Rows = vs_db_stub:rows(),
        ?assertEqual(2, length(Rows)),
        %% 20 kWh left the outlet; 32 kWh reach sessions
        ?assertEqual(20.0, billed(Rows))
    end).

%%%===================================================================
%%% D-1b  the same defect through the other door: faulted closes the
%%%       session, available brings the connector back to free, and the
%%%       walk-in path adopts the cumulative meter again
%%%===================================================================

faulted_close_then_available_replug_bills_twice_test() ->
    with_connector(#{}, fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 9.0, power_kw => 40.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),

        vs_connector:cp_status(Pid, available),
        timer:sleep(20),
        ?assertEqual(free, state_of(Pid)),
        ok = plug(Pid, 9.0),                      %% same cable, same counter
        vs_connector:unplugged(Pid, 15.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),

        ?assertEqual(15.0, billed(vs_db_stub:rows()))
    end).

%%%===================================================================
%%% D-2  every close that is NOT an unplugged writes the row from the
%%%      last meter reading and throws away the final total the hardware
%%%      reports a moment later
%%%===================================================================

a_driver_stop_bills_the_last_meter_not_the_final_total_test() ->
    with_connector(#{}, fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 10.0, power_kw => 150.0}),
        %% The driver presses stop. cp.js answers the stop command with an
        %% unplugged carrying the true total (cp.js onStop -> unplug), so
        %% that is the order the frames really arrive in.
        %%
        %% NOTE (fix lotto 1): this test originally waited for the
        %% session_closed event BETWEEN the two lines below. That waiting
        %% encoded the defect's own timing -- under write-on-entry the
        %% event fired before the hardware could answer -- and it is not
        %% what the contract describes. The assertion is unchanged, and the
        %% test still fails on the unfixed connector: the row is written
        %% on entry there, so the unplugged lands too late whatever the
        %% caller does.
        ok = vs_connector:stop_session(Pid, ?USER),
        vs_connector:unplugged(Pid, 10.2),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(10.2, maps:get(energy_kwh, Row))
    end).

%%%===================================================================
%%% D-3  vs_power: a car that tapers below MIN_CHARGE_KW flaps between
%%%      suspended and full power for ever, one tick each way
%%%===================================================================

%% NOTE (fix lotto 2): this proof originally took two hand-built snapshots
%% and asserted first that tick 1 SUSPENDED the car (a limit of zero) and
%% then that tick 2 agreed with it. The first of those two assertions was
%% an observation of the defect, not an invariant: with the suspension gone
%% there is nothing to suspend and the expected value is no longer zero.
%% What was always the invariant is the second line -- a lone car on an
%% empty site must get a STABLE allocation.
%%
%% So the proof runs the loop instead of sampling two points of it, which
%% is strictly stronger: ticks/6 is one turn of
%% vs_station_mgr:reallocate/1 done by hand -- demands, allocate, and the
%% granted limit fed back into the snapshot the way set_limit feeds it into
%% the connector -- with the car drawing whatever it is allowed, up to the
%% 0.5 kW a nearly full battery still wants.
%%
%% On the unfixed allocator this produces [0.0, 150.0, 0.0, 150.0, ...].
taper_below_the_floor_does_not_flap_test() ->
    Min = 6, TaperSoc = 80, Margin = 5,          %% the shipped defaults
    Budget = 350,
    Start = #{connector_id => 3, rated_kw => 150, power_kw => 0.5,
              state => charging,
              session => #{started_at => 1, max_kw => 150,
                           soc_pct => 95, limit_kw => 150.0}},
    Limits = ticks(Start, 6, Budget, TaperSoc, Margin, Min),
    %% one value, repeated: a fixed point, not an oscillation
    ?assertEqual(1, length(lists:usort(Limits))),
    %% ...and it is not a suspension: nobody is short of anything here
    ?assertNot(lists:member(0.0, Limits)).

ticks(_Snap, 0, _Budget, _TaperSoc, _Margin, _Min) ->
    [];
ticks(Snap, N, Budget, TaperSoc, Margin, Min) ->
    Alloc = vs_power:allocate(Budget, vs_power:demands([Snap], TaperSoc, Margin), Min),
    Kw = maps:get(3, Alloc),
    S = maps:get(session, Snap),
    %% the car takes what it is allowed, up to the 0.5 kW it still wants
    Next = Snap#{power_kw := min(Kw, 0.5), session := S#{limit_kw := Kw}},
    [Kw | ticks(Next, N - 1, Budget, TaperSoc, Margin, Min)].

%%%===================================================================
%%% D-4  a row handed to a writer that is not there is lost in silence
%%%===================================================================

insert_session_is_lost_without_a_single_log_line_test() ->
    ?assertEqual(undefined, whereis(vs_station_db)),
    Me = self(),
    ok = logger:add_handler(review_sink, ?MODULE, #{level => all, config => Me}),
    Row = #{user_id => 1, station_id => 1, connector_id => 3,
            started_at => 1755790000000, ended_at => 1755790600000,
            energy_kwh => 41.2, overstay_seconds => 0},
    %% the connector pattern-matches on this ok (vs_connector.erl:537)
    ?assertEqual(ok, vs_station_db:insert_session(Row)),
    Logged = receive {review_log, _} -> logged after 200 -> nothing end,
    ok = logger:remove_handler(review_sink),
    %% a row that never reaches a writer should at least leave a trace
    ?assertEqual(logged, Logged).

%% logger handler callback for the test above
log(Event, #{config := Pid}) -> Pid ! {review_log, Event}, ok.

%%%===================================================================
%%% D-5  announce/3 runs in the `of' body of the try in write/3, so an
%%%      exception there is NOT caught: the writer dies and takes every
%%%      queued row with it
%%%===================================================================

insert_id_failure_takes_the_whole_queue_down_test() ->
    vs_m2a_sql_stub:reset(),
    vs_claim_stub:reset(),
    {ok, Db} = vs_station_db:start_link(#{sql_mod   => vs_m2a_sql_stub,
                                          claim_mod => vs_claim_stub,
                                          conn_opts => [],
                                          retry_ms  => 50}),
    unlink(Db),
    Ref = monitor(process, Db),
    timer:sleep(50),
    %% three sessions closed at once; the first one's insert_id blows up
    vs_m2a_sql_stub:set_insert_id(raise),
    [vs_station_db:insert_session(row(N)) || N <- [1, 2, 3]],
    Died = receive {'DOWN', Ref, process, _, R} -> {died, R}
           after 500 -> alive
           end,
    catch gen_server:stop(Db),
    ?assertEqual(alive, Died).

%%%===================================================================
%%% D-6  a row the writer cannot turn into parameters wedges the queue:
%%%      insert_params/1 is evaluated inside write/3's try, so a bad row
%%%      is classified `retry' and stays at the head for ever
%%%===================================================================

a_row_that_cannot_be_encoded_wedges_the_queue_test() ->
    vs_m2a_sql_stub:reset(),
    vs_claim_stub:reset(),
    {ok, Db} = vs_station_db:start_link(#{sql_mod   => vs_m2a_sql_stub,
                                          claim_mod => vs_claim_stub,
                                          conn_opts => [],
                                          retry_ms  => 50}),
    unlink(Db),
    timer:sleep(50),
    Poison = (row(1))#{started_at := undefined},
    vs_station_db:insert_session(Poison),
    vs_station_db:insert_session(row(2)),
    vs_station_db:insert_session(row(3)),
    timer:sleep(300),                            %% several retry rounds
    Queued = gen_server:call(Db, queued_rows),
    Written = [P || {_Sql, P} <- vs_m2a_sql_stub:queries()],
    catch gen_server:stop(Db),
    %% rows 2 and 3 are perfectly good and never reach MySQL
    ?assertEqual({0, 2}, {length(Queued), length(Written)}).

row(N) ->
    #{user_id => N, station_id => 1, connector_id => 3,
      started_at => 1755790000000, ended_at => 1755790600000,
      energy_kwh => float(N), overstay_seconds => 0}.

%%%===================================================================
%%% D-7  the reservation leaks into the charging snapshot: `hold' is
%%%      never cleared on held -> charging, so build_snapshot reports
%%%      held_by / expires_at for a connector that is charging, and
%%%      vs_driver_proto:wire_connector/2 puts both on the wire.
%%%      ws-driver.md section 5.1 shows a charging connector with
%%%      "expires_at": null and "held_by_me": false.
%%%===================================================================

a_charging_connector_still_reports_its_old_reservation_test() ->
    with_connector(#{}, fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ok = plug(Pid, 0.0),
        ?assertEqual(charging, state_of(Pid)),
        Snap = vs_connector:snapshot(Pid),
        Wired = vs_driver_proto:wire_state(#{connectors => [Snap]}, ?USER, true),
        [Wire] = maps:get(connectors, Wired),
        ?assertEqual(charging, maps:get(state, Wire)),
        ?assertEqual(null, maps:get(expires_at, Wire)),
        ?assertEqual(false, maps:get(held_by_me, Wire))
    end).

%%%===================================================================
%%% D-8  the OTHER form of the suspension lock-in, through the demand
%%%      ceiling. vs_connector.erl:429-434 claims that a plugged payload
%%%      with no max_kw "starts suspended [and] the next set_limit - one
%%%      tick, in M2 step 2 - corrects it". It does not: demand_kw/3
%%%      caps the demand at min(rated_kw, max_kw) = 0, so the session is
%%%      demand-bound at zero, victim/1 prefers it to everybody, and it
%%%      is re-suspended at every recomputation, at any budget, for ever.
%%%===================================================================

%% NOTE (fix lotto 2): this proof used to observe D-4 inside the
%% ALLOCATOR, asserting that a session declaring max_kw = 0 should be given
%% 350 kW on an empty site. That assertion cannot be right and never was:
%% an allocator must not hand 350 kW to a car that says it can take
%% nothing. It was simply the only place the defect was still visible
%% from, because by then the defect had already happened.
%%
%% The field is mandatory in ws-chargepoint.md 4.2, so the defect is closed
%% where the payload arrives -- and that is where the proof now looks. Same
%% defect, observed at its root instead of at its symptom, and it still
%% fails on the unfixed vs_cp_proto, which opens the session.
a_plugged_with_no_max_kw_opens_no_session_test() ->
    vs_cp_stub:reset(),
    Payload = #{vehicle_id => ?VEHICLE, soc_pct => 22, battery_kwh => 58},
    {Frames, _S} = cp_handle(<<"plugged">>, Payload),
    %% 7.6 -- logged, never answered: there is no stop reason in 5 for an
    %% incomplete payload
    ?assertEqual([], Frames),
    %% and, the point of it: no session was opened
    ?assertEqual(0, vs_cp_stub:count(plugged)).

%% Nor a value that says the car can take nothing, which is the same
%% statement with a number in it.
a_plugged_with_a_non_positive_max_kw_opens_no_session_test() ->
    vs_cp_stub:reset(),
    Payload = #{vehicle_id => ?VEHICLE, soc_pct => 22, battery_kwh => 58,
                max_kw => 0},
    {Frames, _S} = cp_handle(<<"plugged">>, Payload),
    ?assertEqual([], Frames),
    ?assertEqual(0, vs_cp_stub:count(plugged)).

%% The control that keeps the two above from passing for the wrong reason:
%% a complete payload still opens a session, with the ceiling it declared.
a_plugged_with_a_real_max_kw_still_opens_a_session_test() ->
    vs_cp_stub:reset(),
    Payload = #{vehicle_id => ?VEHICLE, soc_pct => 22, battery_kwh => 58,
                max_kw => 150},
    {Frames, _S} = cp_handle(<<"plugged">>, Payload),
    ?assertEqual([], Frames),
    ?assertEqual(1, vs_cp_stub:count(plugged)),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(150, maps:get(max_kw, Info)).

%% One frame through vs_cp_proto against the charge point stub, on a
%% session that has already booted.
cp_handle(Action, Payload) ->
    Session = vs_cp_proto:new(#{station_id   => 1,
                                connector_id => 3,
                                conn_mod     => vs_cp_stub,
                                mgr_mod      => vs_cp_stub,
                                db_mod       => vs_cp_stub}),
    Boot = #{vendor => <<"VoltShare-Emu">>, model => <<"EMU-150">>,
             firmware => <<"0.1.0">>, rated_kw => 150, status => <<"available">>},
    {[_Ack], Booted} =
        vs_cp_proto:handle_text(cp_frame(<<"boot">>, Boot), Session),
    vs_cp_proto:handle_text(cp_frame(Action, Payload), Booted).

cp_frame(Action, Payload) ->
    jsx:encode(#{action => Action, request_id => <<"cp-8">>, payload => Payload}).

