%%%-------------------------------------------------------------------
%%% @doc Tests for the charge point protocol, contract in hand.
%%%
%%% Nothing here starts an application, a listener or a socket: the whole
%%% of ws-chargepoint.md is exercised by handing binaries to
%%% `handle_text/2' and reading the frames it returns. That is the reason
%%% the protocol was split out of the cowboy handler, and it is also what
%%% keeps `rebar3 eunit' from opening port 8081.
%%%
%%% Half of this contract produces **no frame at all** — §9's ladder
%%% answers `meter' and `unplugged' with silence — so half of these
%%% assertions are about what the stub connector was asked to do rather
%%% than about what went back on the wire.
%%%-------------------------------------------------------------------
-module(vs_cp_proto_tests).
-include_lib("eunit/include/eunit.hrl").

-define(CONN, 3).
-define(VEHICLE, 88).

%%%===================================================================
%%% fixture
%%%===================================================================

proto_test_() ->
    [{Name, fun() -> vs_cp_stub:reset(), Case() end} || {Name, Case} <- cases()].

cases() ->
    [{"the handshake binds the connector of the query string",
      fun handshake_binds_the_connector/0},
     {"a connector of another station is refused 4404",
      fun a_connector_of_another_station_is_refused_4404/0},
     {"another station's id is refused 4404",
      fun another_stations_id_is_refused_4404/0},
     {"a connector with no process behind it is admitted, not refused",
      fun a_connector_with_no_pid_is_admitted/0},
     {"a connector looked up while the manager is down is admitted",
      fun a_connector_is_admitted_while_the_manager_is_down/0},
     {"a query string that does not parse is refused 4404",
      fun an_unparsable_query_string_is_refused_4404/0},
     {"boot is acked with everything the equipment needs",
      fun boot_is_acked_with_everything_the_equipment_needs/0},
     {"boot attaches this socket to the connector",
      fun boot_attaches_this_socket_to_the_connector/0},
     {"boot hands the reported status over for reconciliation",
      fun boot_hands_the_reported_status_over/0},
     {"boot carries the limit of a session already running",
      fun boot_carries_the_limit_of_a_running_session/0},
     {"a connector not ready at boot says so in the reason",
      fun a_connector_not_ready_at_boot_says_so/0},
     {"a connector lost between handshake and boot is not accepted",
      fun a_connector_lost_before_boot_is_not_accepted/0},
     {"heartbeat is acked with the station's clock",
      fun heartbeat_is_acked_with_the_stations_clock/0},
     {"an authorised plugged starts a session and sends no frame",
      fun an_authorised_plugged_sends_no_frame/0},
     {"the wrong vehicle is told to stop, and nothing else",
      fun the_wrong_vehicle_is_told_to_stop/0},
     {"a walk-in resolves the vehicle to an account",
      fun a_walk_in_resolves_the_vehicle_to_an_account/0},
     {"plugged on a charging connector is logged, never answered",
      fun plugged_on_a_charging_connector_is_only_logged/0},
     {"a plugged with no account for the vehicle is refused nothing",
      fun a_plugged_with_no_account_is_refused_nothing/0},
     {"reconciliation carries the energy already counted",
      fun reconciliation_carries_the_energy_already_counted/0},
     {"reconciliation carries how long the hardware has been delivering",
      fun reconciliation_carries_the_charging_seconds/0},
     {"an ordinary plugged carries no charging_seconds at all",
      fun an_ordinary_plugged_carries_no_charging_seconds/0},
     {"a charging_seconds of zero says nothing and is left out",
      fun a_zero_charging_seconds_is_left_out/0},
     {"a charging_seconds older than the epoch is refused, not clamped",
      fun an_impossible_charging_seconds_is_refused/0},
     {"meter readings reach the connector",
      fun meter_readings_reach_the_connector/0},
     {"unplugged reaches the connector with the final total",
      fun unplugged_reaches_the_connector/0},
     {"status reaches the connector as an atom",
      fun status_reaches_the_connector_as_an_atom/0},
     {"a status the contract does not define is dropped",
      fun an_undefined_status_is_dropped/0},
     {"request_id is echoed on the acks that exist",
      fun request_id_is_echoed_on_the_acks_that_exist/0},
     {"a frame with no request_id is dropped, not answered",
      fun a_frame_with_no_request_id_is_dropped/0},
     {"malformed JSON is dropped, not answered",
      fun malformed_json_is_dropped/0},
     {"there is no dedup cache on this channel",
      fun there_is_no_dedup_cache_on_this_channel/0},
     {"the connector is looked up on every event",
      fun the_connector_is_looked_up_on_every_event/0}].

session() ->
    vs_cp_proto:new(#{station_id   => 1,
                      connector_id => ?CONN,
                      conn_mod     => vs_cp_stub,
                      mgr_mod      => vs_cp_stub,
                      db_mod       => vs_cp_stub}).

%% A session that has already seen its `boot', for the tests about events.
booted_session() ->
    {[_Ack], S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    S.

boot_payload() ->
    #{vendor => <<"VoltShare-Emu">>, model => <<"EMU-150">>,
      firmware => <<"0.1.0">>, rated_kw => 150, status => <<"available">>}.

handle(Bin, Session) -> vs_cp_proto:handle_text(Bin, Session).

frame(Action, ReqId, Payload) ->
    jsx:encode(#{action => Action, request_id => ReqId, payload => Payload}).

qs(StationId, ConnId) ->
    [{<<"station_id">>, integer_to_binary(StationId)},
     {<<"connector_id">>, integer_to_binary(ConnId)}].

opts() ->
    #{station_id => 1, conn_mod => vs_cp_stub,
      mgr_mod => vs_cp_stub, db_mod => vs_cp_stub}.

type_of(#{type := T})       -> T.
payload_of(#{payload := P}) -> P.

%%%===================================================================
%%% §1 — the handshake
%%%===================================================================

handshake_binds_the_connector() ->
    {ok, Session} = vs_cp_proto:handshake(qs(1, ?CONN), opts()),
    ?assertEqual(?CONN, maps:get(connector_id, Session)),
    ?assertEqual(1, maps:get(station_id, Session)),
    %% §3.1: nothing has booted yet, whatever the socket may already have
    ?assertEqual(false, maps:get(booted, Session)).

%% "A connector id that does not belong to station_id is refused at the
%% handshake with close code 4404."
a_connector_of_another_station_is_refused_4404() ->
    vs_cp_stub:set_connectors([1, 2, 3, 4]),
    ?assertEqual({refuse, 4404}, vs_cp_proto:handshake(qs(1, 7), opts())).

another_stations_id_is_refused_4404() ->
    ?assertEqual({refuse, 4404}, vs_cp_proto:handshake(qs(2, ?CONN), opts())),
    %% and the connector was never even looked up: the station check comes
    %% first, so a charge point pointed at the wrong host cannot make this
    %% node touch its registry
    ?assertEqual(0, vs_cp_stub:count(lookup_pid)).

an_unparsable_query_string_is_refused_4404() ->
    ?assertEqual({refuse, 4404},
                 vs_cp_proto:handshake([{<<"station_id">>, <<"one">>},
                                        {<<"connector_id">>, <<"3">>}], opts())),
    ?assertEqual({refuse, 4404}, vs_cp_proto:handshake([], opts())).

%% P10 — §1: "a connector that this station **does** have but that has no
%% process behind it at that instant ... is **admitted**". The row is in
%% the registry with `undefined' in it, which is what the manager writes
%% at init and writes back on the connector's `DOWN'. Refusing here sent
%% 4404 — the permanent code — for a fact that lasts a supervisor restart,
%% and our own emulator dies on 4404, correctly.
a_connector_with_no_pid_is_admitted() ->
    vs_cp_stub:set_pid(undefined),
    ?assertMatch({ok, #{connector_id := ?CONN}},
                 vs_cp_proto:handshake(qs(1, ?CONN), opts())),
    %% and it really did ask the registry: the admission is a decision
    %% about the ANSWER, not a check that was skipped
    ?assertEqual(1, vs_cp_stub:count(lookup_pid)).

%% The other temporary one: no table at all, because this manager has not
%% finished booting. Same verdict, and for the same reason — a charge
%% point that dials in during the station's own start-up is early, not
%% wrong.
a_connector_is_admitted_while_the_manager_is_down() ->
    vs_cp_stub:set_connectors(manager_down),
    ?assertMatch({ok, #{connector_id := ?CONN}},
                 vs_cp_proto:handshake(qs(1, ?CONN), opts())),
    %% nothing was bound: §3.1 does the binding, and it has not run
    ?assertEqual(0, vs_cp_stub:count(attach_cp)).

%%%===================================================================
%%% §3 — bring-up
%%%===================================================================

%% "The station replies with everything the charge point needs to behave,
%% so that the equipment carries no configuration of its own."
boot_is_acked_with_everything_the_equipment_needs() ->
    {[Ack], _S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual(ack, type_of(Ack)),
    ?assertEqual(<<"cp-1">>, maps:get(request_id, Ack)),
    P = payload_of(Ack),
    ?assertEqual(true, maps:get(accepted, P)),
    ?assertEqual(30, maps:get(heartbeat_interval_s, P)),
    ?assertEqual(5, maps:get(meter_interval_s, P)),
    %% "0 means suspended": nothing is plugged in, so there is no limit
    ?assertEqual(0.0, maps:get(limit_kw, P)),
    %% §3.2 — epoch **milliseconds**, the station's clock and no other
    ServerTime = maps:get(server_time, P),
    ?assert(is_integer(ServerTime)),
    ?assert(abs(ServerTime - vs_time:now_ms()) < 5000),
    %% a value in seconds would be about a thousand times smaller
    ?assert(ServerTime > 1700000000000).

%% §1: the socket *is* the connector, and this call is what makes it so —
%% it is also what closes a stale socket with 4409, on the connector side.
boot_attaches_this_socket_to_the_connector() ->
    {[_Ack], _S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    %% Both halves of the binding: the connector the registry named, and
    %% this process as the socket that speaks for it.
    ?assertEqual({attach_cp, self(), self()}, vs_cp_stub:last(attach_cp)).

%% §3.1: "Booting resets nothing. A charge point that reconnects sends
%% boot again and reports its true physical status; the station reconciles
%% that against what it believes." Which is how a connector left
%% out_of_service comes back.
boot_hands_the_reported_status_over() ->
    {[_Ack], _S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual({cp_status, available}, vs_cp_stub:last(cp_status)),
    %% and in this order: attached first, so the status lands on a
    %% connector that already knows which socket speaks for it
    ?assertMatch([{lookup_pid, _}, {attach_cp, _, _}, {cp_status, available} | _],
                 vs_cp_stub:calls()).

boot_carries_the_limit_of_a_running_session() ->
    vs_cp_stub:set_snapshot(#{connector_id => ?CONN, rated_kw => 150,
                              state => charging, power_kw => 41.0,
                              session => #{user_id => 12, vehicle_id => ?VEHICLE,
                                           started_at => 1755790000000,
                                           energy_kwh => 12.3, soc_pct => 58,
                                           limit_kw => 60.0}}),
    {[Ack], _S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual(60.0, maps:get(limit_kw, payload_of(Ack))).

%% §3.1: "accepted: false with a reason means the station does not
%% recognise this connector or cannot serve it right now; the charge point
%% closes and retries with backoff."
%%
%% The arrangement here is the PERMANENT one: the registry no longer holds
%% this id at all, which since P10 means "not a connector of this station"
%% and nothing else. It can only be reached with a manager that came back
%% with a different configuration between the upgrade and this frame — the
%% boot refuses it all the same, and the 4404 lands at the next handshake
%% (vs_cp_proto §3.3). The assertion stays on the presence of a `reason'
%% rather than its text, because the text is the other test's subject.
a_connector_lost_before_boot_is_not_accepted() ->
    vs_cp_stub:set_connectors([]),
    {[Ack], S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual(false, maps:get(accepted, payload_of(Ack))),
    ?assert(maps:is_key(reason, payload_of(Ack))),
    ?assertEqual(false, maps:get(booted, S)),
    ?assertEqual(0, vs_cp_stub:count(attach_cp)).

%% P10 — the other half of §3.1's table, and the whole point of admitting
%% the socket at the handshake: a charge point let in while its connector
%% has no process must be told WHY in a word it can tell apart from the
%% permanent one. Same `accepted: false', different `reason'.
a_connector_not_ready_at_boot_says_so() ->
    vs_cp_stub:set_pid(undefined),
    {[Ack], S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual(false, maps:get(accepted, payload_of(Ack))),
    ?assertEqual(<<"connector not ready">>, maps:get(reason, payload_of(Ack))),
    %% and the permanent one still reads the way §3.1 says it does
    vs_cp_stub:set_connectors([]),
    {[Ack2], _} = handle(frame(<<"boot">>, <<"cp-2">>, boot_payload()), session()),
    ?assertEqual(<<"unknown connector">>, maps:get(reason, payload_of(Ack2))),
    %% nothing was attached on either path
    ?assertEqual(false, maps:get(booted, S)),
    ?assertEqual(0, vs_cp_stub:count(attach_cp)).

%% §3.2: "The ack carries server_time, which the charge point uses to keep
%% its clock aligned."
heartbeat_is_acked_with_the_stations_clock() ->
    {[Ack], _S} = handle(frame(<<"heartbeat">>, <<"cp-42">>, #{}), booted_session()),
    ?assertEqual(ack, type_of(Ack)),
    ?assertEqual(<<"cp-42">>, maps:get(request_id, Ack)),
    ?assertEqual([server_time], maps:keys(payload_of(Ack))),
    ?assert(abs(maps:get(server_time, payload_of(Ack)) - vs_time:now_ms()) < 5000).

%%%===================================================================
%%% §4.2 — plugged, the one place authorisation happens
%%%===================================================================

plugged_payload(VehicleId) ->
    #{vehicle_id => VehicleId, soc_pct => 22, battery_kwh => 58, max_kw => 150}.

%% The row "held / matches the reservation" and the row "free / any". Both
%% end the same way on the wire: nothing. The `set_limit' that starts the
%% car comes from the connector on entering `charging', by the same route
%% every later recomputation will take.
an_authorised_plugged_sends_no_frame() ->
    {Frames, _S} = handle(frame(<<"plugged">>, <<"cp-8">>, plugged_payload(?VEHICLE)),
                          booted_session()),
    ?assertEqual([], Frames),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(?VEHICLE, maps:get(vehicle_id, Info)),
    ?assertEqual(22, maps:get(soc_pct, Info)),
    ?assertEqual(58.0, maps:get(battery_kwh, Info)),
    ?assertEqual(150, maps:get(max_kw, Info)).

%% "held / different vehicle → refused: command / stop with reason
%% not_your_reservation; the reservation stays." The reservation staying is
%% the connector's half (vs_connector_tests); this is the frame.
the_wrong_vehicle_is_told_to_stop() ->
    vs_cp_stub:set_plugged({error, not_your_reservation}),
    {[Frame], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, plugged_payload(77)),
                           booted_session()),
    ?assertEqual(command, type_of(Frame)),
    %% §5: always server-initiated
    ?assertEqual(null, maps:get(request_id, Frame)),
    ?assertEqual(#{command => stop, reason => not_your_reservation},
                 payload_of(Frame)).

%% D1: the payload names a vehicle, the session needs an account. The
%% mapping is 1:1 in the schema, and it is resolved here rather than at the
%% coordinator, which does not own the table.
a_walk_in_resolves_the_vehicle_to_an_account() ->
    vs_cp_stub:set_user({ok, 12}),
    {[], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, plugged_payload(?VEHICLE)),
                      booted_session()),
    ?assertEqual({user_for_vehicle, ?VEHICLE}, vs_cp_stub:last(user_for_vehicle)),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(12, maps:get(user_id, Info)).

%% "charging | closing / any → refused, invalid_state; the physical state
%% and ours have diverged, and the station logs it loudly." Loudly, and
%% with no command: §7.6 says divergence is found, not patched, and
%% stopping a car that may be charging perfectly well would turn our bug
%% into its problem.
plugged_on_a_charging_connector_is_only_logged() ->
    vs_cp_stub:set_plugged({error, invalid_state}),
    {Frames, _S} = handle(frame(<<"plugged">>, <<"cp-8">>, plugged_payload(?VEHICLE)),
                          booted_session()),
    ?assertEqual([], Frames).

a_plugged_with_no_account_is_refused_nothing() ->
    vs_cp_stub:set_user({error, no_such_vehicle}),
    {Frames, _S} = handle(frame(<<"plugged">>, <<"cp-8">>, plugged_payload(?VEHICLE)),
                          booted_session()),
    ?assertEqual([], Frames),
    %% and the connector was never asked: there is no account to bill
    ?assertEqual(0, vs_cp_stub:count(plugged)).

%% §6: "It sends boot with its true status and, if a session is running, a
%% plugged with the vehicle and the cumulative energy it has counted." The
%% station has no memory of the session, so it adopts what the hardware
%% reports rather than stopping a car that is charging happily.
reconciliation_carries_the_energy_already_counted() ->
    Payload = (plugged_payload(?VEHICLE))#{energy_kwh => 12.317, soc_pct => 58},
    {[], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, Payload), booted_session()),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(12.317, maps:get(energy_kwh, Info)),
    ?assertEqual(58, maps:get(soc_pct, Info)).

%% §6.2 — the second thing only the hardware knows. The energy says how
%% much was delivered, this says over how long, and a `sessions' row needs
%% both to be readable: the station lost the start of the session with the
%% node and cannot reconstruct it from anything it holds.
reconciliation_carries_the_charging_seconds() ->
    Payload = (plugged_payload(?VEHICLE))#{energy_kwh => 12.042,
                                           charging_seconds => 3600},
    {[], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, Payload), booted_session()),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(3600, maps:get(charging_seconds, Info)).

%% §6: "absent or not positive, the station behaves exactly as it did
%% before the field existed". Asserted as the **absence of the key**, not
%% as a zero: the guarantee is that an ordinary plug builds the same map it
%% built before, so that no path downstream can quietly come to depend on
%% a field the contract lets equipment omit.
an_ordinary_plugged_carries_no_charging_seconds() ->
    {[], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, plugged_payload(?VEHICLE)),
                      booted_session()),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertNot(maps:is_key(charging_seconds, Info)).

%% What a charge point sends on a cable that has just gone in — our own
%% emulator does. §6 makes it the same statement as saying nothing, so it
%% must not reach the connector and must not be logged as a divergence.
a_zero_charging_seconds_is_left_out() ->
    Payload = (plugged_payload(?VEHICLE))#{charging_seconds => 0},
    {[], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, Payload), booted_session()),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertNot(maps:is_key(charging_seconds, Info)).

%% A duration longer than the station's clock: subtracting it would date the
%% session before the epoch. Dropped rather than clamped — a clamped
%% duration is a plausible number that is false, and §6 prefers a visibly
%% missing one. The session still opens: the field is optional, and a bad
%% optional field is no reason to refuse a car that is charging.
an_impossible_charging_seconds_is_refused() ->
    Payload = (plugged_payload(?VEHICLE))#{charging_seconds => 4000000000},
    {[], _S} = handle(frame(<<"plugged">>, <<"cp-8">>, Payload), booted_session()),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertNot(maps:is_key(charging_seconds, Info)),
    ?assertEqual(?VEHICLE, maps:get(vehicle_id, Info)).

%%%===================================================================
%%% §4.3 and §4.4 — the events that answer nothing
%%%===================================================================

meter_readings_reach_the_connector() ->
    Payload = #{power_kw => 89.4, energy_kwh => 12.317, soc_pct => 58},
    {Frames, _S} = handle(frame(<<"meter">>, <<"cp-9">>, Payload), booted_session()),
    ?assertEqual([], Frames),
    ?assertEqual({meter, #{power_kw => 89.4, energy_kwh => 12.317, soc_pct => 58}},
                 vs_cp_stub:last(meter)).

unplugged_reaches_the_connector() ->
    {Frames, _S} = handle(frame(<<"unplugged">>, <<"cp-10">>,
                                #{energy_kwh => 41.203}), booted_session()),
    ?assertEqual([], Frames),
    ?assertEqual({unplugged, 41.203}, vs_cp_stub:last(unplugged)).

%% Four names and no more become atoms in this node: a peer that can mint
%% atoms is a peer that can exhaust the atom table.
status_reaches_the_connector_as_an_atom() ->
    lists:foreach(
      fun({Wire, Atom}) ->
              vs_cp_stub:reset(),
              {[], _} = handle(frame(<<"status">>, <<"cp-7">>, #{status => Wire}),
                               booted_session()),
              ?assertEqual({cp_status, Atom}, vs_cp_stub:last(cp_status))
      end,
      [{<<"available">>, available}, {<<"occupied">>, occupied},
       {<<"faulted">>, faulted}, {<<"unavailable">>, unavailable}]).

an_undefined_status_is_dropped() ->
    S0 = booted_session(),
    Before = vs_cp_stub:count(cp_status),
    {Frames, _S} = handle(frame(<<"status">>, <<"cp-7">>, #{status => <<"on_fire">>}), S0),
    ?assertEqual([], Frames),
    ?assertEqual(Before, vs_cp_stub:count(cp_status)).

%%%===================================================================
%%% §2 — the envelope
%%%===================================================================

request_id_is_echoed_on_the_acks_that_exist() ->
    {[Boot], S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual(<<"cp-1">>, maps:get(request_id, Boot)),
    {[Beat], _} = handle(frame(<<"heartbeat">>, <<"cp-2">>, #{}), S),
    ?assertEqual(<<"cp-2">>, maps:get(request_id, Beat)).

%% §2 gives this channel two station -> charge point frame types, `ack' and
%% `command'. There is no `error', so a frame that cannot be read leaves a
%% log line and nothing else — the contract is not widened from here.
a_frame_with_no_request_id_is_dropped() ->
    %% Compared against the session that went **in**, not against a second
    %% one built the same way: since the boot takes out a monitor on the
    %% connector, two sessions built alike differ by that reference, and
    %% "unchanged" is what this assertion is actually about.
    S = booted_session(),
    Bin = jsx:encode(#{action => <<"heartbeat">>, payload => #{}}),
    ?assertEqual({[], S}, handle(Bin, S)),
    NoPayload = jsx:encode(#{action => <<"heartbeat">>, request_id => <<"cp-1">>}),
    ?assertMatch({[], _}, handle(NoPayload, booted_session())),
    NoAction = jsx:encode(#{request_id => <<"cp-1">>, payload => #{}}),
    ?assertMatch({[], _}, handle(NoAction, booted_session())).

malformed_json_is_dropped() ->
    ?assertMatch({[], _}, handle(<<"{not json">>, booted_session())),
    ?assertMatch({[], _}, handle(<<"[1,2,3]">>, booted_session())).

%% §2: "It is not a deduplication key here — the events of the two sides
%% are naturally idempotent or naturally ordered." A repeated meter is
%% absorbed by the connector's monotonic max, not by a cache here, and the
%% proof is that the connector really is asked twice.
there_is_no_dedup_cache_on_this_channel() ->
    S0 = booted_session(),
    Bin = frame(<<"meter">>, <<"cp-9">>, #{power_kw => 89.4, energy_kwh => 12.3}),
    {[], S1} = handle(Bin, S0),
    {[], _S2} = handle(Bin, S1),
    ?assertEqual(2, vs_cp_stub:count(meter)).

%% The pid is never cached: a connector that crashes is restarted with a
%% new pid, and a socket holding the old one would cast meters into a dead
%% mailbox instead of into the live process.
the_connector_is_looked_up_on_every_event() ->
    S0 = booted_session(),
    Before = vs_cp_stub:count(lookup_pid),
    {[], S1}     = handle(frame(<<"meter">>, <<"cp-9">>, #{energy_kwh => 1.0}), S0),
    {[_Ack], S2} = handle(frame(<<"heartbeat">>, <<"cp-10">>, #{}), S1),
    {[], _}      = handle(frame(<<"unplugged">>, <<"cp-11">>, #{energy_kwh => 2.0}), S2),
    %% meter and unplugged each looked it up; heartbeat needs no connector
    ?assertEqual(Before + 2, vs_cp_stub:count(lookup_pid)).

%%%===================================================================
%%% §6 — the connector dies under the socket: reattach and reconcile
%%%===================================================================

%% The defect these cover, reproduced on the compose before a line of the
%% fix was written: with a car charging on connector 3, `exit(Pid, kill)'
%% from the shell left the reborn connector `free' with `cp = undefined',
%% every later `meter' became a "meter for a connector with no session"
%% line, no `set_limit' could reach the hardware again, and the final
%% `unplugged' landed on an idle connector — 1.878 kWh delivered and no
%% `sessions' row written.
%%
%% Unlike the rest of this file these tests need a real pid to monitor, so
%% they spawn one: the monitor and its `DOWN' are the mechanism under
%% test, and a synthetic message would prove only that the code can read a
%% tuple.

reattach_test_() ->
    [{Name, fun() -> vs_cp_stub:reset(), flush(), Case() end}
     || {Name, Case} <- reattach_cases()].

reattach_cases() ->
    [{"the DOWN arms a timer instead of blocking the socket",
      fun the_down_arms_a_timer/0},
     {"a DOWN followed by a new pid reattaches and rebuilds the session",
      fun a_new_pid_reattaches_and_rebuilds_the_session/0},
     {"the rebuilt session carries the energy of the last meter",
      fun the_rebuilt_session_carries_the_energy_of_the_last_meter/0},
     {"the connector is attached before it is told anything",
      fun the_connector_is_attached_before_it_is_told_anything/0},
     {"a DOWN with no session reattaches without a plugged",
      fun a_down_with_no_session_reattaches_without_a_plugged/0},
     {"an unplugged is forgotten, so no ghost session comes back",
      fun an_unplugged_is_forgotten/0},
     {"a stale charging_seconds is not replayed on the reattach",
      fun a_stale_charging_seconds_is_not_replayed/0},
     {"five attempts with no connector close the socket 1012",
      fun five_attempts_with_no_connector_close_1012/0},
     {"a connector that comes back on the last attempt is not closed",
      fun a_connector_back_on_the_last_attempt_is_not_closed/0},
     {"the monitor is re-armed, so a second death is noticed too",
      fun the_monitor_is_rearmed/0},
     {"a DOWN this socket does not hold is ignored",
      fun a_foreign_down_is_ignored/0}].

%% A stand-in for a connector process, alive until the test kills it. What
%% makes it worth spawning: the `DOWN' the socket reacts to is then the one
%% the runtime really delivered, not one the test wrote by hand.
fake_connector() ->
    spawn(fun() -> receive stop -> ok end end).

%% `reattach_ms => 0' so the timer the code arms is observable inside a
%% test without a sleep; the retries themselves are driven by hand, which
%% is what keeps the assertions about the logic and not about timing.
reattach_session(ConnPid) ->
    vs_cp_stub:set_pid(ConnPid),
    S = vs_cp_proto:new(#{station_id   => 1,
                          connector_id => ?CONN,
                          conn_mod     => vs_cp_stub,
                          mgr_mod      => vs_cp_stub,
                          db_mod       => vs_cp_stub,
                          reattach_ms  => 0,
                          reattach_tries_max => 5}),
    {[_Ack], S1} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), S),
    S1.

%% A session with a car charging on it, which is the case the whole
%% mechanism exists for.
charging_session(ConnPid) ->
    S0 = reattach_session(ConnPid),
    {[], S1} = handle(frame(<<"plugged">>, <<"cp-2">>, plug_payload()), S0),
    {[], S2} = handle(frame(<<"meter">>, <<"cp-3">>,
                            #{power_kw => 150.0, energy_kwh => 4.5, soc_pct => 40}), S1),
    S2.

plug_payload() ->
    #{vehicle_id => ?VEHICLE, soc_pct => 22, battery_kwh => 58,
      max_kw => 150, energy_kwh => 0}.

%% Kill the connector and hand back the `DOWN' the runtime delivered.
kill_and_collect(Pid) ->
    exit(Pid, kill),
    receive
        {'DOWN', _Ref, process, Pid, _Reason} = Down -> Down
    after 2000 ->
            error({no_down_from, Pid})
    end.

flush() ->
    receive _Anything -> flush()
    after 0 -> ok
    end.

info(Msg, Session) -> vs_cp_proto:handle_info(Msg, Session).

%% The socket must go on reading frames while it waits — a charge point
%% does not stop reporting because a station process died — so the wait is
%% a timer and not a `receive'. What proves it: the message the code armed
%% turns up in this process's own mailbox.
the_down_arms_a_timer() ->
    Conn = fake_connector(),
    S0 = charging_session(Conn),
    {[], _S1} = info(kill_and_collect(Conn), S0),
    receive
        cp_reattach -> ok
    after 2000 ->
            error(no_reattach_timer)
    end.

%% The heart of it: the connector comes back as a different process, and
%% the session the station lost is rebuilt from what the socket remembers.
a_new_pid_reattaches_and_rebuilds_the_session() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    Down = kill_and_collect(Old),
    {[], S1} = info(Down, S0),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], _S2} = info(cp_reattach, S1),
    %% bound to the NEW connector, with this socket as its charge point
    ?assertEqual({attach_cp, New, self()}, vs_cp_stub:last(attach_cp)),
    %% §6.2 — the true physical status, then the cable
    ?assertEqual({cp_status, available}, vs_cp_stub:last(cp_status)),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(?VEHICLE, maps:get(vehicle_id, Info)),
    %% §4.2 makes max_kw mandatory and the replay goes through the same
    %% validation as a live plugged, so it must still be there
    ?assertEqual(150, maps:get(max_kw, Info)).

%% §6.2: "a `plugged' with the vehicle and the cumulative energy it has
%% counted". The plug frame said zero; the meter is what the hardware has
%% counted since, and it is the only side that counted it.
the_rebuilt_session_carries_the_energy_of_the_last_meter() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    {[], S1} = info(kill_and_collect(Old), S0),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], _S2} = info(cp_reattach, S1),
    {plugged, Info} = vs_cp_stub:last(plugged),
    ?assertEqual(4.5, maps:get(energy_kwh, Info)),
    %% and the fresher soc, for the same reason
    ?assertEqual(40, maps:get(soc_pct, Info)).

%% The order is load-bearing: `plugged' takes the connector into
%% `charging', whose entry callback sends the interim `set_limit' back
%% through this socket. Reconciling before attaching would drop that
%% command into a `cp = undefined' and leave the car on a stale limit.
the_connector_is_attached_before_it_is_told_anything() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    {[], S1} = info(kill_and_collect(Old), S0),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    Before = length(vs_cp_stub:calls()),
    {[], _S2} = info(cp_reattach, S1),
    After = lists:nthtail(Before, vs_cp_stub:calls()),
    ?assertMatch([{lookup_pid, ?CONN}, {attach_cp, _, _},
                  {cp_status, available}, {user_for_vehicle, ?VEHICLE} | _],
                 After),
    %% and the plugged really is last of the three
    ?assertMatch({plugged, _}, lists:last(After)).

%% Nothing was plugged in, so there is nothing to re-announce. The status
%% still goes over — a reborn connector has no idea what the hardware is
%% doing — but no session is invented for a cable that is not there.
a_down_with_no_session_reattaches_without_a_plugged() ->
    Old = fake_connector(),
    S0 = reattach_session(Old),
    {[], S1} = info(kill_and_collect(Old), S0),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], _S2} = info(cp_reattach, S1),
    ?assertEqual({attach_cp, New, self()}, vs_cp_stub:last(attach_cp)),
    ?assertEqual({cp_status, available}, vs_cp_stub:last(cp_status)),
    ?assertEqual(0, vs_cp_stub:count(plugged)).

%% The other half of the same rule, and the one that would hurt: a copy
%% kept past the `unplugged' describes a car that has driven away, and the
%% next reattach would open a session for it.
an_unplugged_is_forgotten() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    {[], S1} = handle(frame(<<"unplugged">>, <<"cp-4">>, #{energy_kwh => 4.9}), S0),
    {[], S2} = info(kill_and_collect(Old), S1),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], _S3} = info(cp_reattach, S2),
    ?assertEqual({attach_cp, New, self()}, vs_cp_stub:last(attach_cp)),
    %% the one from before the unplug, and no second one
    ?assertEqual(1, vs_cp_stub:count(plugged)).

%% §6.2's copy stands in for a frame the charge point would send *now*, and
%% every field of it survives that translation except this one. The energy
%% is refreshed from the meter that arrived a moment ago; a duration cannot
%% be refreshed from anything, and the one written down has been growing
%% ever since. Replaying it would date the session too late by however long
%% the copy sat here — a plausible number that is false, where leaving it
%% out falls back to the honest behaviour every adoption had before.
a_stale_charging_seconds_is_not_replayed() ->
    Old = fake_connector(),
    S0 = reattach_session(Old),
    Reconnected = (plug_payload())#{charging_seconds => 3600},
    {[], S1} = handle(frame(<<"plugged">>, <<"cp-2">>, Reconnected), S0),
    %% it did reach the connector the first time, live
    {plugged, Live} = vs_cp_stub:last(plugged),
    ?assertEqual(3600, maps:get(charging_seconds, Live)),
    {[], S2} = info(kill_and_collect(Old), S1),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], _S3} = info(cp_reattach, S2),
    {plugged, Replayed} = vs_cp_stub:last(plugged),
    ?assertNot(maps:is_key(charging_seconds, Replayed)),
    %% and the rest of the copy is replayed as it always was
    ?assertEqual(?VEHICLE, maps:get(vehicle_id, Replayed)),
    ?assertEqual(150, maps:get(max_kw, Replayed)).

%% The supervisor has given up: five attempts, then a close and let the
%% charge point come back on its own backoff. Better a clean reconnection
%% than a socket bound to a connector that does not exist.
%%
%% **1012, and this assertion used to say 4404.** The code is the whole
%% content of the branch — it is the only thing the equipment on the other
%% end can read — and 4404 is the permanent condition of §1, which our own
%% emulator (rightly) treats as fatal. Asserting it here is what would have
%% carried the defect through any later correction, so the number is quoted
%% against the contract and not against the implementation.
five_attempts_with_no_connector_close_1012() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    {[], S1} = info(kill_and_collect(Old), S0),
    vs_cp_stub:set_connectors([]),          %% nothing comes back, ever
    S2 = lists:foldl(fun(_N, S) ->
                             {[], S1b} = info(cp_reattach, S),
                             S1b
                     end, S1, lists:seq(1, 4)),
    ?assertMatch({close, 1012, [], _}, info(cp_reattach, S2)),
    %% and it never bound itself to anything in the meantime
    ?assertEqual(1, vs_cp_stub:count(attach_cp)).

%% The counter is a budget, not a deadline: a connector that turns up on
%% the last attempt is reattached like any other.
a_connector_back_on_the_last_attempt_is_not_closed() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    {[], S1} = info(kill_and_collect(Old), S0),
    vs_cp_stub:set_connectors([]),
    S2 = lists:foldl(fun(_N, S) ->
                             {[], S1b} = info(cp_reattach, S),
                             S1b
                     end, S1, lists:seq(1, 4)),
    New = fake_connector(),
    vs_cp_stub:set_connectors([?CONN]),
    vs_cp_stub:set_pid(New),
    {[], S3} = info(cp_reattach, S2),
    ?assertEqual({attach_cp, New, self()}, vs_cp_stub:last(attach_cp)),
    %% and the budget is full again, so the next death gets five of its own
    ?assertEqual(0, maps:get(reattach_tries, S3)).

%% A reattach that did not re-arm the monitor would work exactly once, and
%% the second crash would be the original defect all over again.
the_monitor_is_rearmed() ->
    Old = fake_connector(),
    S0 = charging_session(Old),
    {[], S1} = info(kill_and_collect(Old), S0),
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], S2} = info(cp_reattach, S1),
    flush(),
    %% second death, and the socket must notice it the same way
    {[], _S3} = info(kill_and_collect(New), S2),
    receive
        cp_reattach -> ok
    after 2000 ->
            error(no_second_reattach_timer)
    end.

%% The `DOWN' of a connector this socket was replaced on, or one whose
%% message outran the `demonitor'. There is nothing to repair and nothing
%% to arm — a timer here would go looking for a connector that is fine.
a_foreign_down_is_ignored() ->
    Conn = fake_connector(),
    S0 = charging_session(Conn),
    Stranger = fake_connector(),
    Foreign = {'DOWN', make_ref(), process, Stranger, killed},
    ?assertEqual({[], S0}, info(Foreign, S0)),
    receive
        cp_reattach -> error(armed_a_timer_for_a_stranger)
    after 100 -> ok
    end.

%%%===================================================================
%%% the transport — the three close codes and the command frame
%%%===================================================================

%% `vs_cp_ws' has no protocol in it, but it does own the verdicts the
%% contract expresses as *frames on the socket*: 4404, 4409, 1012, the
%% shutdown and the encoding of a command. They are callbacks on a plain map, so
%% they are tested here rather than behind a listener — the same reason
%% the protocol was split out in the first place.

ws_test_() ->
    [{"a refused handshake closes 4404", fun ws_refused_handshake_closes_4404/0},
     {"a replaced socket closes 4409", fun ws_replaced_socket_closes_4409/0},
     {"a command from the connector goes out as a frame",
      fun ws_command_goes_out_as_a_frame/0},
     {"shutdown stops the car before closing",
      fun ws_shutdown_stops_the_car_before_closing/0},
     {"the DOWN of the connector reaches the protocol",
      fun() -> vs_cp_stub:reset(), flush(), ws_down_reaches_the_protocol() end},
     {"a reattach that gives up closes the socket 1012",
      fun() -> vs_cp_stub:reset(), flush(), ws_give_up_closes_the_socket() end}].

ws_refused_handshake_closes_4404() ->
    ?assertEqual({[{close, 4404, <<>>}], {refuse, 4404}},
                 vs_cp_ws:websocket_init({refuse, 4404})).

%% §1: "The old socket is closed with 4409."
ws_replaced_socket_closes_4409() ->
    {Frames, _State} = vs_cp_ws:websocket_info({cp_replaced}, #{}),
    ?assertEqual([{close, 4409, <<>>}], Frames).

ws_command_goes_out_as_a_frame() ->
    {[{text, Bin}], _State} =
        vs_cp_ws:websocket_info({cp_cmd, #{command => set_limit, limit_kw => 60.0}}, #{}),
    Decoded = jsx:decode(Bin),
    ?assertEqual(<<"command">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(null, maps:get(<<"request_id">>, Decoded)),
    ?assertEqual(#{<<"command">> => <<"set_limit">>, <<"limit_kw">> => 60.0},
                 maps:get(<<"payload">>, Decoded)).

%% Both messages have to be matched **above** the catch-all, or they become
%% a debug line and the socket stays bound to a process that is gone. The
%% test is on the callback rather than on the clause order because that is
%% what actually breaks if the order is wrong.
ws_down_reaches_the_protocol() ->
    Conn = fake_connector(),
    S0 = charging_session(Conn),
    Down = kill_and_collect(Conn),
    {[], State1} = vs_cp_ws:websocket_info(Down, #{session => S0}),
    %% the monitor is released, and the timer the protocol armed is here
    ?assertEqual(undefined, maps:get(conn_mon, maps:get(session, State1))),
    receive cp_reattach -> ok after 2000 -> error(no_reattach_timer) end,
    New = fake_connector(),
    vs_cp_stub:set_pid(New),
    {[], _State2} = vs_cp_ws:websocket_info(cp_reattach, State1),
    ?assertEqual({attach_cp, New, self()}, vs_cp_stub:last(attach_cp)).

%% The give-up of §6 as the socket sees it: a close frame, and the charge
%% point reconnects on its own backoff — which is true of 1012 and was not
%% true of the 4404 this asserted before, because a client that obeys §1 to
%% the letter treats 4404 as permanent and stops coming back.
ws_give_up_closes_the_socket() ->
    Conn = fake_connector(),
    S0 = charging_session(Conn),
    {[], State1} = vs_cp_ws:websocket_info(kill_and_collect(Conn), #{session => S0}),
    vs_cp_stub:set_connectors([]),
    State2 = lists:foldl(fun(_N, St) ->
                                 {[], St1} = vs_cp_ws:websocket_info(cp_reattach, St),
                                 St1
                         end, State1, lists:seq(1, 4)),
    {Frames, _State3} = vs_cp_ws:websocket_info(cp_reattach, State2),
    ?assertEqual([{close, 1012, <<>>}], Frames).

%% The frame first, the close after: a car left drawing power from a
%% station that no longer counts it is the outcome §7.3 rules out.
ws_shutdown_stops_the_car_before_closing() ->
    {[{text, Bin}, {close, Code, <<>>}], _State} =
        vs_cp_ws:websocket_info(station_shutdown, #{}),
    ?assertEqual(1001, Code),
    Decoded = jsx:decode(Bin),
    ?assertEqual(#{<<"command">> => <<"stop">>,
                   <<"reason">> => <<"station_shutdown">>},
                 maps:get(<<"payload">>, Decoded)).

%%%===================================================================
%%% M2 fix 2 (D-9) — three missed heartbeats are one budget, split
%%%===================================================================

%% §3.2 says three missed heartbeats. The socket timeout and the
%% connector's grace act in series — cowboy waits out the silence, and only
%% when it gives up does the connector see the DOWN and start its own
%% clock — so as long as both computed the whole product the contract's
%% ninety seconds took a hundred and eighty, and a faulted connector stayed
%% reservable for three minutes.
the_socket_timeout_and_the_grace_add_up_to_three_heartbeats_test() ->
    Interval = vs_env:get_int("CP_HEARTBEAT_INTERVAL_S", 30),
    Missed   = vs_env:get_int("CP_HEARTBEAT_MISSED", 3),
    Idle     = socket_idle_timeout_ms(),
    Grace    = vs_connector:cp_grace_ms(),
    %% the two halves, and the sum the contract asks for
    ?assertEqual((Missed - 1) * Interval * 1000, Idle),
    ?assertEqual(Interval * 1000, Grace),
    ?assertEqual(Missed * Interval * 1000, Idle + Grace),
    %% with the shipped defaults: 60 + 30 = 90 s
    ?assertEqual(60000, Idle),
    ?assertEqual(30000, Grace).

%% The grace is not decoration and must not be squeezed to nothing: §1
%% plans for the network blip, a socket that dies of a FIN rather than of
%% silence with the charge point back in about a second.
the_grace_still_covers_a_reconnection_test() ->
    ?assert(vs_connector:cp_grace_ms() >= 5000).

%% Read through the only caller, so the assertion is on what cowboy is
%% actually handed rather than on a formula copied into the test.
socket_idle_timeout_ms() ->
    Req = #{qs => <<"station_id=1&connector_id=3">>},
    {cowboy_websocket, _Req, _State, Opts} = vs_cp_ws:init(Req, []),
    maps:get(idle_timeout, Opts).
