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
    ?assertEqual({attach_cp, self()}, vs_cp_stub:last(attach_cp)).

%% §3.1: "Booting resets nothing. A charge point that reconnects sends
%% boot again and reports its true physical status; the station reconciles
%% that against what it believes." Which is how a connector left
%% out_of_service comes back.
boot_hands_the_reported_status_over() ->
    {[_Ack], _S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual({cp_status, available}, vs_cp_stub:last(cp_status)),
    %% and in this order: attached first, so the status lands on a
    %% connector that already knows which socket speaks for it
    ?assertMatch([{lookup_pid, _}, {attach_cp, _}, {cp_status, available} | _],
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
%% recognise this connector; the charge point closes and retries with
%% backoff." The handshake already checked, so this is the manager having
%% gone away in between — a restart, and backoff is the right answer.
a_connector_lost_before_boot_is_not_accepted() ->
    vs_cp_stub:set_connectors([]),
    {[Ack], S} = handle(frame(<<"boot">>, <<"cp-1">>, boot_payload()), session()),
    ?assertEqual(false, maps:get(accepted, payload_of(Ack))),
    ?assert(maps:is_key(reason, payload_of(Ack))),
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
    Bin = jsx:encode(#{action => <<"heartbeat">>, payload => #{}}),
    ?assertEqual({[], booted_session()}, handle(Bin, booted_session())),
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
%%% the transport — the three close codes and the command frame
%%%===================================================================

%% `vs_cp_ws' has no protocol in it, but it does own the four verdicts the
%% contract expresses as *frames on the socket*: 4404, 4409, the shutdown
%% and the encoding of a command. They are callbacks on a plain map, so
%% they are tested here rather than behind a listener — the same reason
%% the protocol was split out in the first place.

ws_test_() ->
    [{"a refused handshake closes 4404", fun ws_refused_handshake_closes_4404/0},
     {"a replaced socket closes 4409", fun ws_replaced_socket_closes_4409/0},
     {"a command from the connector goes out as a frame",
      fun ws_command_goes_out_as_a_frame/0},
     {"shutdown stops the car before closing",
      fun ws_shutdown_stops_the_car_before_closing/0}].

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
