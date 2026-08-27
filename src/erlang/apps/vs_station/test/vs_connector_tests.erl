%%%-------------------------------------------------------------------
%%% @doc Tests for the connector state machine.
%%%
%%% Every test drives the machine through the API a real caller would use
%%% and asserts on two things: the state the driver would see, and what
%%% the coordinator was asked. The second half matters as much as the
%%% first — "claim first, commit after" is a claim about the order of two
%%% actions, so it is tested by looking at the order.
%%%-------------------------------------------------------------------
-module(vs_connector_tests).
-include_lib("eunit/include/eunit.hrl").

-define(USER, 12).
-define(VEHICLE, 88).
-define(OTHER_USER, 99).
-define(OTHER_VEHICLE, 77).

%%%===================================================================
%%% fixture
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
                        notify_to     => self()}, Extra),
    {ok, Pid} = vs_connector:start_link(Opts),
    Pid.

stop_connector(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    ok.

with_connector(Fun) -> with_connector(#{}, Fun).

with_connector(Opts, Fun) ->
    Pid = start_connector(Opts),
    try Fun(Pid) after stop_connector(Pid) end.

state_of(Pid) -> maps:get(state, vs_connector:snapshot(Pid)).

plug(Pid, VehicleId) ->
    vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => VehicleId,
                                soc_pct => 22, battery_kwh => 58.0, max_kw => 150}).

%% Drains one connector_event of the expected kind, or fails after 1 s.
expect_event(Kind) ->
    receive
        {connector_event, _ConnId, Event} when element(1, Event) =:= Kind -> Event;
        {connector_event, _ConnId, _Other} -> expect_event(Kind)
    after 1000 ->
        erlang:error({no_event, Kind})
    end.

%%%===================================================================
%%% reservation
%%%===================================================================

reserve_grants_and_holds_test() ->
    with_connector(fun(Pid) ->
        ?assertEqual(free, state_of(Pid)),
        {ok, ExpiresAt} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual(held, state_of(Pid)),
        %% the deadline the driver is shown is real and in the future
        ?assert(ExpiresAt > vs_time:now_ms()),
        ?assertEqual(ExpiresAt, maps:get(expires_at, vs_connector:snapshot(Pid))),
        ?assertEqual(?USER, maps:get(held_by, vs_connector:snapshot(Pid)))
    end).

reserve_asks_the_coordinator_first_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        %% P2: exactly one claim, for this vehicle, before anything local
        ?assertMatch([{acquire, ?VEHICLE, ?USER, 1, 3}], vs_claim_stub:calls())
    end).

%% The refusal that matters: the coordinator says no, so nothing local
%% changes. A connector that went to `held' anyway would break P2 while
%% looking perfectly healthy from the outside.
refused_claim_leaves_connector_free_test() ->
    with_connector(fun(Pid) ->
        vs_claim_stub:set_reply({error, already_held}),
        ?assertEqual({error, already_held}, vs_connector:reserve(Pid, ?USER, ?VEHICLE)),
        ?assertEqual(free, state_of(Pid)),
        ?assertEqual(undefined, maps:get(held_by, vs_connector:snapshot(Pid)))
    end).

refusals_are_passed_through_test() ->
    with_connector(fun(Pid) ->
        lists:foreach(
          fun(Refusal) ->
              vs_claim_stub:set_reply({error, Refusal}),
              ?assertEqual({error, Refusal}, vs_connector:reserve(Pid, ?USER, ?VEHICLE)),
              ?assertEqual(free, state_of(Pid))
          end,
          [already_held, suspended, retry_later, no_claim])
    end).

%% Scenario 1 of the demo, in miniature: two drivers, one connector.
second_driver_is_refused_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual({error, already_held},
                     vs_connector:reserve(Pid, ?OTHER_USER, ?OTHER_VEHICLE)),
        %% and the loser's request never reached the coordinator: local
        %% contention is settled locally, one claim was asked for in total
        ?assertEqual(1, length([C || C = {acquire, _, _, _, _} <- vs_claim_stub:calls()]))
    end).

%%%===================================================================
%%% cancellation and lease
%%%===================================================================

holder_can_cancel_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual(ok, vs_connector:cancel(Pid, ?USER)),
        ?assertEqual(free, state_of(Pid)),
        ?assertMatch([{release, _, cancelled}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

others_cannot_cancel_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual({error, not_yours}, vs_connector:cancel(Pid, ?OTHER_USER)),
        ?assertEqual(held, state_of(Pid))
    end).

%% P3: the connector frees itself, with no cooperation from anyone.
lease_expires_by_itself_test() ->
    with_connector(#{lease_seconds => 0}, fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertMatch({reservation_expired, ?USER}, expect_event(reservation_expired)),
        ?assertEqual(free, state_of(Pid)),
        ?assertMatch([{release, _, expired}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

%% The no-show is reported, never written: the penalty counter is the back
%% office's column (schema.sql).
no_show_is_reported_not_written_test() ->
    with_connector(#{lease_seconds => 0}, fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertMatch({no_show, ?USER}, expect_event(no_show)),
        ?assertEqual([], vs_db_stub:rows())
    end).

%%%===================================================================
%%% authorisation at the cable
%%%===================================================================

right_vehicle_starts_charging_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual(ok, plug(Pid, ?VEHICLE)),
        ?assertEqual(charging, state_of(Pid))
    end).

wrong_vehicle_is_refused_and_reservation_survives_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual({error, not_your_reservation}, plug(Pid, ?OTHER_VEHICLE)),
        ?assertEqual(held, state_of(Pid)),
        ?assertEqual(?USER, maps:get(held_by, vs_connector:snapshot(Pid)))
    end).

%% Walk-in on a free connector needs no claim at all — which is also what
%% lets a suspended account keep charging (SCOPE §3.3).
walk_in_needs_no_claim_test() ->
    with_connector(fun(Pid) ->
        ?assertEqual(ok, plug(Pid, ?VEHICLE)),
        ?assertEqual(charging, state_of(Pid)),
        ?assertEqual([], [C || C = {acquire, _, _, _, _} <- vs_claim_stub:calls()])
    end).

%%%===================================================================
%%% session
%%%===================================================================

meter_readings_accumulate_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{power_kw => 89.4, energy_kwh => 12.3, soc_pct => 58}),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(12.3, maps:get(energy_kwh, Session)),
        ?assertEqual(58, maps:get(soc_pct, Session))
    end).

%% A meter that resets must not subtract energy already delivered.
energy_never_goes_backwards_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 12.3}),
        vs_connector:meter(Pid, #{energy_kwh => 0.0}),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(12.3, maps:get(energy_kwh, Session))
    end).

owner_stops_session_and_row_is_written_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 41.2, power_kw => 50.0}),
        ?assertEqual(ok, vs_connector:stop_session(Pid, ?USER)),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(free, state_of(Pid)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(?USER, maps:get(user_id, Row)),
        ?assertEqual(3, maps:get(connector_id, Row)),
        ?assertEqual(41.2, maps:get(energy_kwh, Row)),
        %% cost is not the station's business: the row leaves it out entirely
        ?assertNot(maps:is_key(cost_cents, Row)),
        %% and the claim went back
        ?assertMatch([{release, _, completed}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

%% The car has already charged. Losing the row must not lose the connector
%% as well: the write is logged as an error and the machine carries on.
failed_write_still_frees_the_connector_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_db_stub:fail_next(),
        vs_connector:unplugged(Pid, 12.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(free, state_of(Pid)),
        ?assertEqual([], vs_db_stub:rows())
    end).

others_cannot_stop_a_session_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        ?assertEqual({error, not_yours}, vs_connector:stop_session(Pid, ?OTHER_USER)),
        ?assertEqual(charging, state_of(Pid))
    end).

unplugging_closes_with_the_meter_total_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 30.0}),
        vs_connector:unplugged(Pid, 41.2),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(41.2, maps:get(energy_kwh, Row))
    end).

%%%===================================================================
%%% revocation — the coordinator is authoritative
%%%===================================================================

revocation_frees_a_held_connector_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = claim_id_of(Pid),
        vs_connector:revoke(Pid, ClaimId),
        ?assertMatch({claim_revoked, ?USER}, expect_event(claim_revoked)),
        ?assertEqual(free, state_of(Pid))
    end).

%% A revocation for a claim this connector never held is ignored: a stale
%% message from a previous leader must not free somebody else's connector.
stale_revocation_is_ignored_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        vs_connector:revoke(Pid, <<"c-from-another-life">>),
        timer:sleep(50),
        ?assertEqual(held, state_of(Pid))
    end).

revocation_stops_a_running_session_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = claim_id_of(Pid),
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 5.0}),
        vs_connector:revoke(Pid, ClaimId),
        ?assertMatch({claim_revoked, ?USER}, expect_event(claim_revoked)),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(free, state_of(Pid)),
        %% the energy already delivered is still billed
        [Row] = vs_db_stub:rows(),
        ?assertEqual(5.0, maps:get(energy_kwh, Row))
    end).

%% A revocation carries the id the coordinator granted, so the test asks
%% the stub which id it handed out.
claim_id_of(_Pid) -> vs_claim_stub:last_claim_id().

%%%===================================================================
%%% snapshot
%%%===================================================================

snapshot_has_what_the_state_push_needs_test() ->
    with_connector(fun(Pid) ->
        Snap = vs_connector:snapshot(Pid),
        ?assertEqual(3, maps:get(connector_id, Snap)),
        ?assertEqual(150, maps:get(rated_kw, Snap)),
        ?assertEqual(free, maps:get(state, Snap)),
        ?assertEqual(0.0, maps:get(power_kw, Snap)),
        ?assertNot(maps:is_key(session, Snap))
    end).

%%%===================================================================
%%% the charge point — ws-chargepoint.md, M2 step 1
%%%===================================================================

%% A stand-in for the socket process of vs_cp_ws: it forwards everything
%% it receives to the test, so an assertion can be made about a message
%% the connector sent with `!' rather than about a call it answered.
fake_cp() ->
    Test = self(),
    spawn(fun() -> cp_loop(Test) end).

cp_loop(Test) ->
    receive Msg -> Test ! {cp_got, self(), Msg}, cp_loop(Test) end.

%% `kill', not a polite stop: a charge point socket dies of a network
%% failure or of cowboy's idle timeout, never by agreement.
stop_cp(Pid) -> exit(Pid, kill).

expect_cp(Cp) ->
    receive {cp_got, Cp, Msg} -> Msg
    after 1000 -> erlang:error({no_charge_point_message, Cp})
    end.

expect_cmd(Cp) ->
    case expect_cp(Cp) of
        {cp_cmd, Payload} -> Payload;
        Other             -> erlang:error({not_a_command, Other})
    end.

%%%-------------------------------------------------------------------
%%% D1 — who the session is billed to
%%%-------------------------------------------------------------------

%% §4.2 identifies a *vehicle*; the account is the holder's. The charge
%% point has no voice on who is billed (§7.1), so a payload naming someone
%% else changes nothing.
a_reserved_session_is_billed_to_the_holder_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ok = vs_connector:plugged(Pid, #{user_id    => ?OTHER_USER,
                                         vehicle_id => ?VEHICLE,
                                         max_kw     => 150}),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(?USER, maps:get(user_id, Session))
    end).

%%%-------------------------------------------------------------------
%%% D5 — the limit, stored and forwarded
%%%-------------------------------------------------------------------

%% The interim allocation of step 1: one value on entering `charging',
%% min(rated_kw, max_kw). Step 2 moves the calculation, not the transport.
the_session_starts_with_an_interim_limit_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        ?assertEqual(#{command => set_limit, limit_kw => 150.0}, expect_cmd(Cp))
    end).

set_limit_is_stored_and_forwarded_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp)),
        vs_connector:set_limit(Pid, 60),
        ?assertEqual(#{command => set_limit, limit_kw => 60.0}, expect_cmd(Cp)),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(60.0, maps:get(limit_kw, Session))
    end).

%% M2 step 2 — `suspended' is derived from the limit, not stored: it is
%% `charging' at zero, which is what ws-driver.md §5.1 says it means and
%% what ws-chargepoint.md §5 puts on the wire. Nothing else about the
%% connector changes, which is the point of deriving it rather than
%% adding a sixth state: it goes back and forth with the allocation, and
%% a real state would fire `enter' and `exit' every time it did.
a_zero_limit_is_reported_as_suspended_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp)),   %% the D5 interim one
        ?assertEqual(charging, state_of(Pid)),

        vs_connector:set_limit(Pid, 0),
        ?assertEqual(#{command => set_limit, limit_kw => 0.0}, expect_cmd(Cp)),
        ?assertEqual(suspended, state_of(Pid)),
        %% the session is alive, not ended: that is the whole difference
        %% between suspended and closed
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(?USER, maps:get(user_id, Session)),
        ?assertEqual(0.0, maps:get(limit_kw, Session)),

        %% and it comes back the same way it went, with no state change
        vs_connector:set_limit(Pid, 40),
        ?assertEqual(#{command => set_limit, limit_kw => 40.0}, expect_cmd(Cp)),
        ?assertEqual(charging, state_of(Pid))
    end).

%% A car that never declared what it can take starts at min(rated, 0),
%% which is zero — D5 says so in words, and the derived state is what
%% makes it visible. §4.2 makes `max_kw' mandatory, so this is a
%% misbehaving charge point being reported honestly, not a supported way
%% to plug in.
a_session_with_no_max_kw_starts_suspended_test() ->
    with_connector(fun(Pid) ->
        ok = vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE}),
        ?assertEqual(suspended, state_of(Pid))
    end).

%% The allocator needs the car's own ceiling to compute a demand, and it
%% reads it off the snapshot. It was in the session record already; only
%% the snapshot was missing it.
the_snapshot_carries_what_the_car_can_take_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(150, maps:get(max_kw, Session))
    end).

%% "Meaningful only while charging": a limit for a connector with nothing
%% plugged in has nothing to limit, and nothing goes out on the wire.
set_limit_outside_a_session_is_absorbed_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        vs_connector:set_limit(Pid, 60),
        ?assertEqual(free, state_of(Pid)),
        receive {cp_got, Cp, Msg} -> erlang:error({unexpected, Msg})
        after 200 -> ok
        end
    end).

%%%-------------------------------------------------------------------
%%% §5 — the charge point is told why a session ended
%%%-------------------------------------------------------------------

the_charge_point_is_told_why_a_session_ended_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp)),
        ?assertEqual(ok, vs_connector:stop_session(Pid, ?USER)),
        ?assertEqual(#{command => stop, reason => driver_stopped}, expect_cmd(Cp))
    end).

a_revoked_claim_stops_the_car_too_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = claim_id_of(Pid),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp)),
        vs_connector:revoke(Pid, ClaimId),
        ?assertEqual(#{command => stop, reason => claim_revoked}, expect_cmd(Cp))
    end).

%%%-------------------------------------------------------------------
%%% §1 — one socket per connector, the newest wins
%%%-------------------------------------------------------------------

%% "Hardware that reconnects after a network blip must not be locked out
%% by its own stale socket. The old socket is closed with 4409" — which is
%% what the old socket does when it gets this message.
a_second_charge_point_replaces_the_first_test() ->
    with_connector(fun(Pid) ->
        Cp1 = fake_cp(),
        Cp2 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp1),
        ok = vs_connector:attach_cp(Pid, Cp2),
        ?assertEqual({cp_replaced}, expect_cp(Cp1)),
        %% and the commands now go to the newcomer, not to the ghost
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp2))
    end).

%% The socket we replaced then dies, as it must. Its DOWN was flushed with
%% the monitor, so it cannot arm the grace timer of a connector whose
%% charge point is perfectly healthy.
the_death_of_a_replaced_socket_is_not_a_fault_test() ->
    with_connector(#{cp_grace_ms => 150}, fun(Pid) ->
        Cp1 = fake_cp(),
        Cp2 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp1),
        ok = vs_connector:attach_cp(Pid, Cp2),
        ?assertEqual({cp_replaced}, expect_cp(Cp1)),
        stop_cp(Cp1),
        timer:sleep(400),
        ?assertEqual(free, state_of(Pid))
    end).

%%%-------------------------------------------------------------------
%%% D3 — the grace, and what happens when it runs out
%%%-------------------------------------------------------------------

%% §1 plans for the blip with a one second reconnect: a reservation must
%% not die of a fault that lasted a moment.
a_charge_point_back_inside_the_grace_leaves_no_trace_test() ->
    with_connector(#{cp_grace_ms => 300}, fun(Pid) ->
        Cp1 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp1),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        stop_cp(Cp1),
        timer:sleep(100),
        Cp2 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp2),
        timer:sleep(400),                    %% well past the original grace
        ?assertEqual(held, state_of(Pid)),
        ?assertEqual(?USER, maps:get(held_by, vs_connector:snapshot(Pid)))
    end).

%% §3.2: "any reservation on it is released with a session_interrupted
%% notification".
a_charge_point_gone_past_the_grace_releases_the_reservation_test() ->
    with_connector(#{cp_grace_ms => 100}, fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        stop_cp(Cp),
        ?assertMatch({session_interrupted, ?USER}, expect_event(session_interrupted)),
        ?assertEqual(out_of_service, state_of(Pid)),
        ?assertMatch([{release, _, cancelled}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

%% "Charging that was in progress is closed with the energy last reported —
%% a session that cannot be measured must not keep accruing cost."
a_charge_point_gone_past_the_grace_closes_the_session_test() ->
    with_connector(#{cp_grace_ms => 100}, fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 7.5, power_kw => 50.0}),
        stop_cp(Cp),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(7.5, maps:get(energy_kwh, Row))
    end).

%%%-------------------------------------------------------------------
%%% D2 — out_of_service is a state
%%%-------------------------------------------------------------------

%% §4.1: "faulted immediately takes the connector out of service and stops
%% any session; the driver is notified with session_interrupted."
a_fault_while_reserved_releases_the_reservation_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_interrupted, ?USER}, expect_event(session_interrupted)),
        ?assertEqual(out_of_service, state_of(Pid)),
        ?assertEqual(undefined, maps:get(held_by, vs_connector:snapshot(Pid))),
        ?assertMatch([{release, _, cancelled}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

a_fault_while_charging_writes_the_row_and_stops_the_car_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp)),
        vs_connector:meter(Pid, #{energy_kwh => 7.5, power_kw => 50.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertEqual(#{command => stop, reason => faulted}, expect_cmd(Cp)),
        ?assertMatch({session_interrupted, ?USER}, expect_event(session_interrupted)),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(7.5, maps:get(energy_kwh, Row))
    end).

%% handle_common already answers invalid_state to the calls it does not
%% handle, so `reserve' on an out-of-service connector refuses itself.
an_out_of_service_connector_cannot_be_reserved_test() ->
    with_connector(fun(Pid) ->
        vs_connector:cp_status(Pid, faulted),
        ?assertEqual(out_of_service, state_of(Pid)),
        ?assertEqual({error, invalid_state}, vs_connector:reserve(Pid, ?USER, ?VEHICLE)),
        %% and the coordinator was never troubled about it
        ?assertEqual([], [C || C = {acquire, _, _, _, _} <- vs_claim_stub:calls()])
    end).

%% §3.1 — the hardware is authoritative on physical state, so only the
%% hardware can say the connector is healthy again. And D4 is a one-trip
%% flag: the session after the fault ends the ordinary way, in `free'.
available_brings_it_back_and_the_next_session_ends_free_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 4.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),

        vs_connector:cp_status(Pid, available),
        ?assertEqual(free, state_of(Pid)),

        ok = plug(Pid, ?VEHICLE),
        vs_connector:unplugged(Pid, 2.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(free, state_of(Pid)),
        ?assertEqual(2, length(vs_db_stub:rows()))
    end).

%%%-------------------------------------------------------------------
%%% §4.3 and §6 — meters without a session, and reconciliation
%%%-------------------------------------------------------------------

%% "A meter for a connector with no session is dropped and logged."
%% Dropped is the assertion: nothing about the connector moves.
a_meter_without_a_session_changes_nothing_test() ->
    with_connector(fun(Pid) ->
        vs_connector:meter(Pid, #{power_kw => 50.0, energy_kwh => 3.0}),
        ?assertEqual(free, state_of(Pid)),
        Snap = vs_connector:snapshot(Pid),
        ?assertNot(maps:is_key(session, Snap)),
        ?assertEqual(0.0, maps:get(power_kw, Snap)),

        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        vs_connector:meter(Pid, #{power_kw => 50.0, energy_kwh => 3.0}),
        ?assertEqual(held, state_of(Pid)),
        ?assertNot(maps:is_key(session, vs_connector:snapshot(Pid)))
    end).

%% §6: the station restarted, the car never stopped charging. "It adopts
%% what the hardware reports rather than stopping a car that is charging
%% happily", and the energy from before the crash is preserved because the
%% charge point is the side that counted it.
a_reconnecting_charge_point_seeds_the_session_with_its_own_total_test() ->
    with_connector(fun(Pid) ->
        ok = vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                         soc_pct => 58, battery_kwh => 58.0,
                                         max_kw => 150, energy_kwh => 12.317}),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(12.317, maps:get(energy_kwh, Session)),
        %% and a later meter cannot subtract what was already delivered
        vs_connector:meter(Pid, #{energy_kwh => 1.0}),
        vs_connector:unplugged(Pid, 13.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(13.0, maps:get(energy_kwh, Row))
    end).

%% The scenario the grace leaves behind: the hardware went quiet past the
%% 90 s while delivering, the session was closed with the last measured
%% energy, and now the charge point is back — still occupied, still
%% counting. `occupied' lifts nothing, so the adoption of §6 is the only
%% way this car ever charges again.
an_out_of_service_connector_adopts_a_reconnected_session_test() ->
    with_connector(#{cp_grace_ms => 100}, fun(Pid) ->
        Cp1 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp1),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp1)),
        vs_connector:meter(Pid, #{energy_kwh => 12.3, power_kw => 50.0}),
        stop_cp(Cp1),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),

        %% back, occupied, with the total it never stopped counting
        Cp2 = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp2),
        vs_connector:cp_status(Pid, occupied),
        ?assertEqual(out_of_service, state_of(Pid)),   %% occupied lifts nothing
        ok = vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                         soc_pct => 30, battery_kwh => 58.0,
                                         max_kw => 150, energy_kwh => 12.3}),
        ?assertEqual(charging, state_of(Pid)),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(12.3, maps:get(energy_kwh, Session)),
        %% and the car is un-suspended by the same route as any other start
        ?assertEqual(#{command => set_limit, limit_kw => 150.0}, expect_cmd(Cp2))
    end).
