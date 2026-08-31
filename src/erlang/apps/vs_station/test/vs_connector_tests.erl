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
    %% Drain what this connector emitted. Without it a `session_closed'
    %% left by one test satisfies the next test's expect_event before that
    %% connector has done anything — a failure that points at the wrong
    %% test and moves when tests are reordered.
    flush_events().

flush_events() ->
    receive {connector_event, _, _} -> flush_events()
    after 0 -> ok
    end.

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

%% ws-driver.md §5.2 divides the battery that is left by the power that is
%% flowing, so `eta_seconds' needs the size of the battery. It has been in
%% `#session' since the first `plugged' and only the snapshot was missing
%% it — the same omission `max_kw' had until M2 step 2.
the_snapshot_carries_the_battery_size_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(58.0, maps:get(battery_kwh, Session))
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

%% M4 changed where the row is written on this path, and the test says so
%% in the middle. The stop ends the CHARGE; the row is the record of the
%% whole occupation, so it waits for the cable. What used to be asserted
%% here — row written and connector free immediately after the stop — was
%% the defect written down as an expectation: it left no interval for an
%% overstay to happen in, which is exactly why `overstay_seconds' could
%% only ever be zero.
owner_stops_session_and_row_is_written_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 41.2, power_kw => 50.0}),
        ?assertEqual(ok, vs_connector:stop_session(Pid, ?USER)),
        %% Nothing written, and this is not a race: `complete' has no
        %% timer of its own, so the connector will sit here until the
        %% hardware says the cable is out and no scheduler decides it.
        ?assertEqual([], vs_db_stub:rows()),
        vs_connector:unplugged(Pid, 41.2),
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
%% as well: since M2 step 3 the write is a cast, so the connector cannot
%% even find out — which is the point. It frees itself either way.
failed_write_still_frees_the_connector_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_db_stub:fail_next(),
        vs_connector:unplugged(Pid, 12.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(free, state_of(Pid)),
        ?assertEqual([], vs_db_stub:rows())
    end).

%% M2 step 3 — the decision the whole database step turns on, tested
%% against the **real** database module with no database process running
%% at all. `insert_session/1' is a cast, so it goes nowhere and returns
%% immediately, and the connector walks out of `closing' at the speed of
%% its own state machine.
%%
%% This is the shape of the failure that matters: a station whose writer
%% is restarting, or whose MySQL is gone, must still free its outlets
%% (SCOPE §4). A synchronous `insert_session/1' would not merely be slow
%% here — a `gen_server:call' to a name nobody has registered exits, and
%% the connector would go down with a physical outlet in hand.
closing_does_not_wait_for_the_database_test() ->
    ?assertEqual(undefined, whereis(vs_station_db)),
    with_connector(#{db_mod => vs_station_db}, fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        {Micros, _} = timer:tc(fun() ->
                          vs_connector:unplugged(Pid, 12.0),
                          wait_until(fun() -> state_of(Pid) =:= free end)
                      end),
        ?assert(Micros < 300000),
        ?assert(erlang:is_process_alive(Pid))
    end).

%% The row carries every column `sessions' needs, built by the connector
%% and read by nobody else on the way — vs_station_db turns exactly this
%% map into the INSERT parameters, and its own tests assert the columns.
the_written_row_carries_what_the_table_needs_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 7.5, power_kw => 50.0}),
        vs_connector:unplugged(Pid, 7.5),
        %% waiting on the row and not on the event: the mailbox may still
        %% hold a `session_closed' from an earlier test, and that one would
        %% satisfy expect_event without this connector having written
        %% anything yet
        wait_until(fun() -> vs_db_stub:rows() =/= [] end),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(?USER, maps:get(user_id, Row)),
        ?assertEqual(3, maps:get(connector_id, Row)),   %% the fixture's outlet
        ?assertEqual(7.5, maps:get(energy_kwh, Row)),
        %% M4 — zero here means "this session never reached `complete'",
        %% not "not implemented": the cable came out of a charging
        %% connector, so there was never a moment when the charge was over
        %% and the outlet still taken. `charge_ended_at' is `undefined'
        %% and `overstay_seconds/3' answers 0 for it by its first clause.
        ?assertEqual(0, maps:get(overstay_seconds, Row)),
        ?assert(is_integer(maps:get(station_id, Row))),
        ?assert(maps:get(ended_at, Row) >= maps:get(started_at, Row))
    end).

wait_until(F) -> wait_until(F, 200).
wait_until(_F, 0) -> erlang:error(timed_out_waiting);
wait_until(F, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

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

%% M4 — a revocation is the third soft ending, so it stops the charge and
%% leaves the connector in `complete' rather than closing it outright. The
%% driver is told the instant the coordinator decides; the row waits for
%% the cable, exactly as it does for a driver's own stop. A car left
%% plugged in after its reservation was revoked is an overstay like any
%% other, and it used to be the one ending that could not be one.
%% The grace is named rather than inherited from the environment: the
%% assertion below is about the state the revocation leaves behind, and
%% reading `complete' instead of `overstay' must not depend on an
%% OVERSTAY_GRACE_SECONDS that happens to be set in the shell.
revocation_stops_a_running_session_test() ->
    with_connector(#{overstay_grace_s => 3600}, fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = claim_id_of(Pid),
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 5.0}),
        vs_connector:revoke(Pid, ClaimId),
        ?assertMatch({claim_revoked, ?USER}, expect_event(claim_revoked)),
        ?assertEqual(complete, state_of(Pid)),
        ?assertEqual([], vs_db_stub:rows()),
        vs_connector:unplugged(Pid, 5.0),
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
%% makes it visible.
%%
%% M2 fix 2 (D-4): this comment used to end by calling the result "a
%% misbehaving charge point being reported honestly". It was not being
%% reported at all. `vs_power:demand_kw/3' reads the same `max_kw', so the
%% demand was zero too and no later `set_limit' could lift it: the car sat
%% at zero for ever with nothing in any log to say why. §4.2 makes the
%% field mandatory, and `vs_cp_proto' now refuses such a `plugged'
%% outright — see `vs_m2a_regression_tests'.
%%
%% What is asserted here is therefore the connector's own defence, for a
%% payload that should no longer be able to reach it: `min' with a zero is
%% zero, and it says so rather than inventing a ceiling (§7.2).
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
        %% M2 fix 1 (D-1). This assertion used to read 12.3 -- the whole
        %% cumulative, seeded straight from the payload -- and that was the
        %% double-billing: those 12.3 kWh are already in the row the grace
        %% wrote a moment ago, and counting them again put them on a second
        %% invoice. The adopted session starts at nothing delivered *since*
        %% that row, and the hardware's total is reached again only when the
        %% car has actually taken more.
        ?assertEqual(0.0, maps:get(energy_kwh, Session)),
        %% ...and the two rows together add up to what left the outlet,
        %% which is the property the whole offset exists for.
        vs_connector:unplugged(Pid, 20.0),
        wait_until(fun() -> length(vs_db_stub:rows()) =:= 2 end),
        ?assertEqual(20.0, lists:sum([maps:get(energy_kwh, R)
                                      || R <- vs_db_stub:rows()])),
        %% and the car was un-suspended by the same route as any other start
        ?assertEqual(#{command => set_limit, limit_kw => 150.0}, expect_cmd(Cp2))
    end).

%%%===================================================================
%%% §6 — how long the hardware had been delivering
%%%===================================================================

%% The defect this closes, measured on the compose before it was: a car
%% that had charged for two and a half minutes across a station restart
%% produced a row covering sixty-five seconds and 5.956 kWh — 330 kW on a
%% 150 kW outlet. `started_at' was the instant of the adoption, because it
%% was the only instant the station had.
%%
%% This is the walk-in door, and it is the one that matters: a station that
%% restarts comes back with **fresh** connector processes in `free', so the
%% reconciliation of §6 arrives here and not at `out_of_service'.
an_adopted_session_is_dated_from_the_charging_seconds_test() ->
    with_connector(fun(Pid) ->
        Before = vs_time:now_ms(),
        ok = vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                         soc_pct => 58, battery_kwh => 58.0,
                                         max_kw => 150, energy_kwh => 12.042,
                                         charging_seconds => 3600}),
        StartedAt = maps:get(started_at,
                             maps:get(session, vs_connector:snapshot(Pid))),
        %% an hour back, on the station's own clock and nobody else's.
        %% P11: the ceiling is read AFTER the fact, not from `Before'. The
        %% connector stamps `now_ms() - 3600000' when it handles the plug,
        %% which is at or after `Before', so `=< Before - 3600000' asked the
        %% two clock readings to land in the SAME millisecond and failed
        %% whenever they did not. The pair of bounds still catches both
        %% regressions: no subtraction sails past the ceiling, too much
        %% subtraction falls through the floor below.
        ?assert(StartedAt =< vs_time:now_ms() - 3600000),
        ?assert(StartedAt >= Before - 3600000 - 2000),
        %% and the row that comes out of it is readable: the energy and the
        %% window it covers agree, which is the whole point
        vs_connector:unplugged(Pid, 12.042),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        Seconds = (maps:get(ended_at, Row) - maps:get(started_at, Row)) / 1000,
        ?assert(Seconds >= 3600),
        ?assert(Seconds < 3610)
    end).

%% The controprova, at the unit the E2E measures on a real socket: a plug
%% that says nothing about durations starts now, exactly as every plug did
%% before the field existed. Both doors that a charge point can walk in
%% through with no reconciliation behind it.
a_plug_without_charging_seconds_still_starts_now_test() ->
    with_connector(fun(Pid) ->
        Before = vs_time:now_ms(),
        ok = plug(Pid, ?VEHICLE),
        StartedAt = maps:get(started_at,
                             maps:get(session, vs_connector:snapshot(Pid))),
        ?assert(StartedAt >= Before),
        ?assert(StartedAt =< vs_time:now_ms())
    end).

a_reserved_plug_is_untouched_by_the_new_field_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        Before = vs_time:now_ms(),
        ok = plug(Pid, ?VEHICLE),
        ?assertEqual(charging, state_of(Pid)),
        StartedAt = maps:get(started_at,
                             maps:get(session, vs_connector:snapshot(Pid))),
        ?assert(StartedAt >= Before),
        ?assert(StartedAt =< vs_time:now_ms())
    end).

%% `vs_cp_proto' filters the field before it ever gets here, so this is the
%% connector's own guard and not a second copy of the contract's rule: a
%% duration longer than the epoch would date a session in 1969 and break
%% the `epoch_ms()' the row is written with. It falls back rather than
%% clamping, for the same reason the wire does — a clamped duration is a
%% plausible number that is false.
an_impossible_charging_seconds_falls_back_to_now_test() ->
    with_connector(fun(Pid) ->
        Before = vs_time:now_ms(),
        ok = vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                         soc_pct => 22, battery_kwh => 58.0,
                                         max_kw => 150,
                                         charging_seconds => 4000000000}),
        StartedAt = maps:get(started_at,
                             maps:get(session, vs_connector:snapshot(Pid))),
        ?assert(StartedAt >= Before)
    end).

%%%===================================================================
%%% M2 fix 1 (D-2) — the row is written when the hardware has finished
%%%                  talking, not when the station stops listening
%%%===================================================================

plug_with(Pid, EnergyKwh) ->
    vs_connector:plugged(Pid, #{user_id => ?USER, vehicle_id => ?VEHICLE,
                                soc_pct => 22, battery_kwh => 58.0,
                                max_kw => 150, energy_kwh => EnergyKwh}).

billed() -> lists:sum([maps:get(energy_kwh, R) || R <- vs_db_stub:rows()]).

%% §5: the charge point applies the `stop' and reports the result, and
%% cp.js reports it as the `unplugged' carrying the true total. Writing on
%% entry to `closing' put the row in one frame too early and billed the
%% last `meter' instead — up to METER_INTERVAL_S of energy given away on
%% every session a driver ends.
a_driver_stop_bills_the_total_the_hardware_reports_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 10.0, power_kw => 150.0}),
        ok = vs_connector:stop_session(Pid, ?USER),
        vs_connector:unplugged(Pid, 10.2),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(10.2, maps:get(energy_kwh, Row))
    end).

%% The same for a revocation, which is the other ending that starts by
%% telling the hardware to stop.
a_revocation_bills_the_total_the_hardware_reports_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = vs_claim_stub:last_claim_id(),
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 4.0, power_kw => 100.0}),
        vs_connector:revoke(Pid, ClaimId),
        vs_connector:unplugged(Pid, 4.4),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(4.4, maps:get(energy_kwh, Row))
    end).

%% A reading that arrives inside the window is energy that was really
%% delivered, and the monotone `max' of §4.3 applies here as it does in
%% `charging'.
%%
%% M4 moved which ending gets here. The two tests below used to open with
%% a driver's stop, which since M4 goes to `complete' and waits for the
%% cable with no deadline at all — the wait IS the overstay. What still
%% arrives in `closing' with a window to expire is the fault of §4.1: the
%% hardware may get one last word in, and if it does not, nothing else is
%% coming. That is the path these two now exercise, and it is the only one
%% D-2 was ever really about.
a_meter_inside_the_window_still_counts_test() ->
    with_connector(#{closing_settle_ms => 400}, fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 5.0, power_kw => 150.0}),
        vs_connector:cp_status(Pid, faulted),
        vs_connector:meter(Pid, #{energy_kwh => 5.4, power_kw => 30.0}),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(5.4, maps:get(energy_kwh, Row))
    end).

%% Nobody answers — the charge point is gone, or simply says nothing. The
%% window expires and the row is written with what was measured, which is
%% what §3.2 asks for anyway.
a_silent_charge_point_settles_at_the_deadline_test() ->
    with_connector(#{closing_settle_ms => 120}, fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 8.0, power_kw => 50.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertEqual([], vs_db_stub:rows()),      %% not yet
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        %% §4.1 sends the connector out of service, not back to `free'
        ?assertEqual(out_of_service, state_of(Pid)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(8.0, maps:get(energy_kwh, Row))
    end).

%% The common ending pays none of the wait: an `unplugged' is the last
%% word, so the window closes on arrival rather than on the clock. With a
%% five second window the row is still there in a fraction of it.
an_unplugged_does_not_wait_for_the_window_test() ->
    with_connector(#{closing_settle_ms => 5000}, fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        {Micros, _} = timer:tc(fun() ->
                          vs_connector:unplugged(Pid, 12.0),
                          wait_until(fun() -> state_of(Pid) =:= free end)
                      end),
        ?assert(Micros < 1000000),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(12.0, maps:get(energy_kwh, Row))
    end).

%%%===================================================================
%%% M2 fix 1 (D-1) — energy already written to a row is never written
%%%                  to a second one
%%%===================================================================

%% The other door onto the same defect. A fault closes the session, the
%% hardware says `available' again, the connector goes back to `free', and
%% the cable that never came out is re-announced as a walk-in. The offset
%% has to survive `out_of_service' AND `free' to be there when it is read.
a_fault_then_a_replug_through_free_bills_each_kwh_once_test() ->
    with_connector(fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug_with(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 9.0, power_kw => 40.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),

        vs_connector:cp_status(Pid, available),
        wait_until(fun() -> state_of(Pid) =:= free end),
        ok = plug_with(Pid, 9.0),                 %% same cable, same counter
        vs_connector:unplugged(Pid, 15.0),
        wait_until(fun() -> length(vs_db_stub:rows()) =:= 2 end),
        ?assertEqual([9.0, 6.0], [maps:get(energy_kwh, R) || R <- vs_db_stub:rows()]),
        ?assertEqual(15.0, billed())
    end).

%% Two faults on one cable. What is carried forward is the cumulative the
%% hardware will report, not this session's share of it, so the second
%% offset subtracts the whole history rather than the last slice.
two_faults_on_one_cable_still_bill_each_kwh_once_test() ->
    with_connector(fun(Pid) ->
        ok = plug_with(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 5.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),

        ok = plug_with(Pid, 5.0),
        vs_connector:meter(Pid, #{energy_kwh => 12.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),

        ok = plug_with(Pid, 12.0),
        vs_connector:unplugged(Pid, 20.0),
        wait_until(fun() -> length(vs_db_stub:rows()) =:= 3 end),
        ?assertEqual([5.0, 7.0, 8.0], [maps:get(energy_kwh, R) || R <- vs_db_stub:rows()]),
        ?assertEqual(20.0, billed())
    end).

%% The offset is only meaningful while the hardware is counting the same
%% delivery. A charge point that comes back reporting LESS than what was
%% already billed has restarted its counter — a different car, a firmware
%% reset, an unplug we never saw — and the payload is taken at face value.
%% Without this the honest 2 kWh of a new car would be billed as nothing.
a_restarted_counter_drops_the_offset_test() ->
    with_connector(fun(Pid) ->
        ok = plug_with(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 4.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),

        vs_connector:cp_status(Pid, available),
        wait_until(fun() -> state_of(Pid) =:= free end),
        ok = plug_with(Pid, 0.0),                 %% a fresh counter
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(0.0, maps:get(energy_kwh, Session)),
        vs_connector:unplugged(Pid, 2.0),
        wait_until(fun() -> length(vs_db_stub:rows()) =:= 2 end),
        ?assertEqual([4.0, 2.0], [maps:get(energy_kwh, R) || R <- vs_db_stub:rows()])
    end).

%% §6 as the contract writes it — the station restarted, so this process
%% has no memory and no offset. Nothing changes for that case, which is
%% the point of keeping the offset in the process rather than in a flag.
a_fresh_connector_adopts_the_full_cumulative_test() ->
    with_connector(fun(Pid) ->
        ok = plug_with(Pid, 31.5),
        Session = maps:get(session, vs_connector:snapshot(Pid)),
        ?assertEqual(31.5, maps:get(energy_kwh, Session)),
        vs_connector:unplugged(Pid, 33.0),
        wait_until(fun() -> vs_db_stub:rows() =/= [] end),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(33.0, maps:get(energy_kwh, Row))
    end).

%% And an ending that DOES take the cable out carries nothing forward: the
%% next car on that outlet starts from its own zero.
an_unplugged_carries_no_offset_to_the_next_car_test() ->
    with_connector(fun(Pid) ->
        ok = plug_with(Pid, 0.0),
        vs_connector:unplugged(Pid, 7.0),
        wait_until(fun() -> vs_db_stub:rows() =/= [] end),
        ok = plug_with(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 3.0}),
        vs_connector:unplugged(Pid, 3.0),
        wait_until(fun() -> length(vs_db_stub:rows()) =:= 2 end),
        ?assertEqual([7.0, 3.0], [maps:get(energy_kwh, R) || R <- vs_db_stub:rows()])
    end).

%% The third doorway. The offset is consumed by every adoption, not only
%% by the two the review exercised: after a fault the outlet goes back to
%% `free' and can be *reserved* before the cable is re-announced, so the
%% session opens from `held'. Same helpers, same subtraction — and this is
%% the path no proof of the review covers.
a_reserved_replug_after_a_fault_bills_each_kwh_once_test() ->
    with_connector(fun(Pid) ->
        ok = plug_with(Pid, 0.0),
        vs_connector:meter(Pid, #{energy_kwh => 6.0}),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),

        vs_connector:cp_status(Pid, available),
        wait_until(fun() -> state_of(Pid) =:= free end),
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ?assertEqual(held, state_of(Pid)),
        ok = plug_with(Pid, 6.0),                 %% the cable never came out
        ?assertEqual(charging, state_of(Pid)),
        vs_connector:unplugged(Pid, 10.0),
        wait_until(fun() -> length(vs_db_stub:rows()) =:= 2 end),
        ?assertEqual([6.0, 4.0], [maps:get(energy_kwh, R) || R <- vs_db_stub:rows()]),
        ?assertEqual(10.0, billed())
    end).

%%%===================================================================
%%% P14 — presenting the claim to a client that has forgotten it
%%%===================================================================

%% The claim client is a gen_server, so the connector answers with a
%% cast; arriving at a bare test process that is the raw `{'$gen_cast',
%% Msg}' wrapper, and unwrapping it here is cheaper than standing up a
%% whole client to receive one message.
%%
%% Both helpers put a `snapshot' call between the question and the
%% verdict, and that is what makes them deterministic rather than timed:
%% the cast and the call travel from this process to the same one, so the
%% connector has finished handling the rebuild before the snapshot reply
%% comes back — whatever it sent is already in this mailbox, and `after 0'
%% is enough. P11's rule: no assertion that a scheduler can trip.
claim_presented(Pid) ->
    _ = vs_connector:snapshot(Pid),
    receive
        {'$gen_cast', {claim_present, _, _, _, _, _, _, _} = Msg} -> Msg
    after 0 ->
        erlang:error(no_claim_presented)
    end.

no_claim_presented(Pid) ->
    _ = vs_connector:snapshot(Pid),
    receive
        {'$gen_cast', {claim_present, _, _, _, _, _, _, _} = Msg} ->
            erlang:error({presented_a_claim_it_does_not_have, Msg})
    after 0 ->
        ok
    end.

%% `held' is where the claim lives before the cable goes in, and the
%% expiry presented is the COORDINATOR's, not the station's lease. The
%% two are different numbers on purpose (claim.md §3.1 grants the claim
%% longer so it cannot die under a live reservation), and the snapshot
%% shows the lease — so comparing them is what proves the connector kept
%% the right one rather than re-reporting what it already had.
a_held_connector_presents_its_claim_on_rebuild_test() ->
    with_connector(fun(Pid) ->
        {ok, LeaseExpiresAt} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = vs_claim_stub:last_claim_id(),
        vs_connector:claims_rebuild(Pid, self()),
        {claim_present, Owner, Cid, Vehicle, User, ConnId, GrantedAt, ExpiresAt} =
            claim_presented(Pid),
        ?assertEqual(Pid, Owner),
        ?assertEqual(ClaimId, Cid),
        ?assertEqual(?VEHICLE, Vehicle),
        ?assertEqual(?USER, User),
        ?assertEqual(3, ConnId),
        ?assert(GrantedAt =< vs_time:now_ms()),
        ?assert(ExpiresAt > LeaseExpiresAt)
    end).

%% The other half: after `held → charging' the `#hold' is gone (D-8) and
%% the claim lives in `#session'. Without this clause a client that
%% restarted mid-session would never get the claim back, and §6.1 would
%% stay open for every connector that happens to be charging.
a_charging_connector_presents_its_claim_on_rebuild_test() ->
    with_connector(fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = vs_claim_stub:last_claim_id(),
        ok = plug(Pid, ?VEHICLE),
        ?assertEqual(charging, state_of(Pid)),
        vs_connector:claims_rebuild(Pid, self()),
        {claim_present, Owner, Cid, Vehicle, User, ConnId, GrantedAt, ExpiresAt} =
            claim_presented(Pid),
        ?assertEqual(Pid, Owner),
        %% the same claim, and the same two coordinator timestamps, carried
        %% across the transition that throws the reservation away
        ?assertEqual(ClaimId, Cid),
        ?assertEqual(?VEHICLE, Vehicle),
        ?assertEqual(?USER, User),
        ?assertEqual(3, ConnId),
        ?assert(is_integer(GrantedAt)),
        ?assert(ExpiresAt > vs_time:now_ms())
    end).

%% "Negli altri stati, silenzio" — and `free' is the state every
%% connector boots into, so this is what the very first rebuild of a
%% station's life gets back.
a_free_connector_says_nothing_on_a_claims_rebuild_test() ->
    with_connector(fun(Pid) ->
        ?assertEqual(free, state_of(Pid)),
        vs_connector:claims_rebuild(Pid, self()),
        ok = no_claim_presented(Pid)
    end).

%% Not a formality: a walk-in reaches `charging' through the same door as
%% a reserved session, and it has no claim at all (SCOPE §3.3 — no
%% reservation is needed to plug in at a free outlet). A clause that
%% matched `#session{}' without looking at the claim id would cast
%% `undefined' as a claim, and the client would put into its table — and
%% from there into the coordinator's, on the next renew — a claim nobody
%% ever granted.
a_walk_in_has_no_claim_to_present_test() ->
    with_connector(fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        ?assertEqual(charging, state_of(Pid)),
        ?assertEqual([], [C || C = {acquire, _, _, _, _} <- vs_claim_stub:calls()]),
        vs_connector:claims_rebuild(Pid, self()),
        ok = no_claim_presented(Pid)
    end).

%%%===================================================================
%%% M4 — the overstay
%%%===================================================================

%%%-------------------------------------------------------------------
%%% the arithmetic, on timestamps nobody had to wait for
%%%-------------------------------------------------------------------

%% The four numbers agreed with B in `risposta-per-B-M2.md' §2, on the
%% pure function so that seven minutes of overstay cost a microsecond of
%% test. P11's rule, and the reason the function is exported at all:
%% `vs_time' is the real clock and cannot be injected, so the only
%% alternative would be a test that sleeps for the answer.
the_overstay_is_the_billable_net_of_the_grace_test() ->
    T = 1755790000000,
    Grace = 300,
    %% seven minutes with the cable in: two of them are billable
    ?assertEqual(120, vs_connector:overstay_seconds(T, T + 420000, Grace)),
    %% four minutes: inside the tolerance, nothing to bill
    ?assertEqual(0,   vs_connector:overstay_seconds(T, T + 240000, Grace)),
    %% the boundary second is free — the grace is a tolerance, not a trap
    ?assertEqual(0,   vs_connector:overstay_seconds(T, T + 300000, Grace)),
    %% and B's own example: six minutes → 60
    ?assertEqual(60,  vs_connector:overstay_seconds(T, T + 360000, Grace)).

%% Every ending that never passed through `complete' — a cable pulled out
%% of a charging connector, a fault, a charge point past its grace. There
%% is no interval to measure and the answer is not "zero by accident" but
%% zero by the first clause of the function.
a_session_that_never_completed_has_no_overstay_test() ->
    ?assertEqual(0, vs_connector:overstay_seconds(undefined, 1755790000000, 300)),
    %% and the grace it would have had makes no difference to that
    ?assertEqual(0, vs_connector:overstay_seconds(undefined, 1755790000000, 0)).

%%%-------------------------------------------------------------------
%%% the state machine, with the grace set to zero so that the derivation
%%% is deterministic instead of timed
%%%-------------------------------------------------------------------

%% A grace of zero is not a shortcut, it is the only way to assert the
%% derivation without waiting five minutes for it: `reported_state/2'
%% compares with `>=' precisely so that the millisecond the charge ends
%% already reads `overstay' when the tolerance is zero.
no_grace() -> #{overstay_grace_s => 0}.

session_of(Pid) -> maps:get(session, vs_connector:snapshot(Pid)).

the_stop_ends_the_charge_and_starts_the_overstay_test() ->
    with_connector(no_grace(), fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        ?assertEqual(ok, vs_connector:stop_session(Pid, ?USER)),
        ?assertEqual(overstay, state_of(Pid)),
        %% the meter of the overstay has started but has counted nothing:
        %% the net is seconds, and no second has gone by
        ?assertEqual(0, maps:get(overstay_seconds, session_of(Pid))),
        %% the session is still open — the row is the record of an
        %% occupation that has not finished
        ?assertEqual([], vs_db_stub:rows())
    end).

the_unplug_ends_the_occupation_and_writes_the_net_test() ->
    with_connector(no_grace(), fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ok = plug(Pid, ?VEHICLE),
        ok = vs_connector:stop_session(Pid, ?USER),
        vs_connector:unplugged(Pid, 9.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(free, state_of(Pid)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(9.0, maps:get(energy_kwh, Row)),
        %% stopped and unplugged inside the same millisecond: the column is
        %% written, and what it says is that there was nothing to charge for
        ?assertEqual(0, maps:get(overstay_seconds, Row)),
        %% the claim goes back here and not a moment earlier
        ?assertMatch([{release, _, completed}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

%% Inside the tolerance the connector is `complete', not `overstay': the
%% cable is in, the clock is running, and nobody is being charged yet.
%% This is the same code path as the test above with one number changed,
%% which is the point — the two names are one comparison apart.
inside_the_grace_the_charge_is_complete_and_not_an_overstay_test() ->
    with_connector(#{overstay_grace_s => 3600}, fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        ok = vs_connector:stop_session(Pid, ?USER),
        ?assertEqual(complete, state_of(Pid)),
        ?assertEqual(0, maps:get(overstay_seconds, session_of(Pid)))
    end).

%% `target_reached' was in ws-chargepoint.md §5 from M2 and had no sender:
%% the station never noticed that a battery was full. The equipment reports
%% the state of charge and the station draws the conclusion, because §7.1
%% gives the equipment no say in when a session ends.
a_full_battery_stops_the_charge_by_itself_test() ->
    with_connector(no_grace(), fun(Pid) ->
        Cp = fake_cp(),
        ok = vs_connector:attach_cp(Pid, Cp),
        ok = plug(Pid, ?VEHICLE),
        ?assertMatch(#{command := set_limit}, expect_cmd(Cp)),
        vs_connector:meter(Pid, #{energy_kwh => 45.0, power_kw => 3.0, soc_pct => 100}),
        ?assertEqual(#{command => stop, reason => target_reached}, expect_cmd(Cp)),
        ?assertEqual(overstay, state_of(Pid)),
        %% the reading that ended the charge is applied, not dropped with it
        ?assertEqual(45.0, maps:get(energy_kwh, session_of(Pid))),
        ?assertEqual(100, maps:get(soc_pct, session_of(Pid)))
    end).

%% P14, in the state where a session now spends minutes instead of
%% milliseconds. A `complete' that stayed silent on the rebuild would
%% reopen the regression that was just closed, in the new place: the claim
%% exists, this process owns it, and a client that restarted has nowhere
%% else to look.
a_complete_connector_presents_its_claim_on_rebuild_test() ->
    with_connector(no_grace(), fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = vs_claim_stub:last_claim_id(),
        ok = plug(Pid, ?VEHICLE),
        ok = vs_connector:stop_session(Pid, ?USER),
        ?assertEqual(overstay, state_of(Pid)),
        vs_connector:claims_rebuild(Pid, self()),
        {claim_present, Owner, Cid, Vehicle, User, ConnId, GrantedAt, ExpiresAt} =
            claim_presented(Pid),
        ?assertEqual(Pid, Owner),
        ?assertEqual(ClaimId, Cid),
        ?assertEqual(?VEHICLE, Vehicle),
        ?assertEqual(?USER, User),
        ?assertEqual(3, ConnId),
        ?assert(is_integer(GrantedAt)),
        ?assert(ExpiresAt > vs_time:now_ms())
    end).

%% The overstay that outlives the lease. There is no charge left to stop
%% and no reservation left to hand back — `settle/1' will release at the
%% unplug — so the only right answer is to absorb it and go on measuring.
a_revocation_after_the_charge_has_nothing_left_to_stop_test() ->
    with_connector(no_grace(), fun(Pid) ->
        {ok, _} = vs_connector:reserve(Pid, ?USER, ?VEHICLE),
        ClaimId = claim_id_of(Pid),
        ok = plug(Pid, ?VEHICLE),
        ok = vs_connector:stop_session(Pid, ?USER),
        vs_connector:revoke(Pid, ClaimId),
        ?assertEqual(overstay, state_of(Pid)),
        ?assertEqual([], vs_db_stub:rows()),
        %% and the release still happens exactly once, at the settle
        ?assertEqual([], [C || C = {release, _, _} <- vs_claim_stub:calls()]),
        vs_connector:unplugged(Pid, 3.0),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertMatch([{release, _, completed}],
                     [C || C = {release, _, _} <- vs_claim_stub:calls()])
    end).

%% Physically occupied is physically occupied: there is a car on the cable
%% and the next driver must be sent to another outlet, not told to wait for
%% this one. Same refusal `charging' raises, for the same reason.
a_complete_connector_cannot_be_reserved_test() ->
    with_connector(no_grace(), fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        ok = vs_connector:stop_session(Pid, ?USER),
        ?assertEqual({error, already_held},
                     vs_connector:reserve(Pid, ?OTHER_USER, ?OTHER_VEHICLE)),
        %% and the coordinator was never troubled about it
        ?assertEqual([], [C || C = {acquire, _, _, _, _} <- vs_claim_stub:calls()])
    end).

%% The charge is over, so energy stops growing on a reading: the true
%% total arrives with the `unplugged' and goes through `final_energy/2'.
%% And the power the driver's page is shown is zero from the transition
%% onwards — a frozen "150 kW" over a car that finished ten minutes ago
%% would be a lie the two-second `closing' of M2 never had time to tell.
a_meter_after_the_charge_changes_nothing_test() ->
    with_connector(no_grace(), fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 6.0, power_kw => 150.0}),
        ok = vs_connector:stop_session(Pid, ?USER),
        vs_connector:meter(Pid, #{energy_kwh => 99.0, power_kw => 150.0}),
        ?assertEqual(6.0, maps:get(energy_kwh, session_of(Pid))),
        ?assertEqual(0.0, maps:get(power_kw, vs_connector:snapshot(Pid)))
    end).

%% §4.1 in the new state: the hardware is authoritative, so the row is
%% written with what was measured and the connector goes out of service.
%% No `unplugged' is ever coming from equipment that has faulted, and an
%% overstay nobody can measure is not one worth waiting for.
a_fault_during_the_overstay_writes_the_row_test() ->
    with_connector(no_grace(), fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 7.5, power_kw => 50.0}),
        ok = vs_connector:stop_session(Pid, ?USER),
        vs_connector:cp_status(Pid, faulted),
        ?assertMatch({session_closed, _}, expect_event(session_closed)),
        ?assertEqual(out_of_service, state_of(Pid)),
        [Row] = vs_db_stub:rows(),
        ?assertEqual(7.5, maps:get(energy_kwh, Row)),
        %% the row still carries the column, and with a real value: the
        %% overstay accrued up to the moment measurement stopped
        ?assert(is_integer(maps:get(overstay_seconds, Row)))
    end).

%% §6.2 during an overstay. A charge point whose socket blipped boots
%% again and re-announces the cable; the connector answers exactly as
%% `charging' does — `invalid_state', logged by `vs_cp_proto' and dropped
%% — and nothing about the session moves. The clock in particular does
%% not restart: a car that never moved must not earn back its grace by
%% the station losing a socket.
a_replug_during_the_overstay_does_not_reset_the_clock_test() ->
    with_connector(#{overstay_grace_s => 3600}, fun(Pid) ->
        ok = plug(Pid, ?VEHICLE),
        vs_connector:meter(Pid, #{energy_kwh => 4.0, power_kw => 50.0}),
        ok = vs_connector:stop_session(Pid, ?USER),
        Before = session_of(Pid),
        %% the re-announcement of a live cable, refused the way `charging'
        %% refuses it
        ?assertEqual({error, invalid_state}, plug(Pid, ?VEHICLE)),
        ?assertEqual(complete, state_of(Pid)),
        After = session_of(Pid),
        %% same session, same energy, same start — nothing was adopted
        ?assertEqual(maps:get(started_at, Before), maps:get(started_at, After)),
        ?assertEqual(4.0, maps:get(energy_kwh, After)),
        %% and the attach of the boot still cancels the grace timer from
        %% anywhere, which is what makes the blip cost nothing at all
        Cp = fake_cp(),
        ?assertEqual(ok, vs_connector:attach_cp(Pid, Cp)),
        ?assertEqual(complete, state_of(Pid))
    end).
