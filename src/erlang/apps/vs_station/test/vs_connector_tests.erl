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
