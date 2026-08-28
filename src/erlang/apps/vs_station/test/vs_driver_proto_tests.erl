%%%-------------------------------------------------------------------
%%% @doc Tests for the driver protocol, contract in hand.
%%%
%%% Nothing here starts an application, a listener or a socket: the whole
%%% of ws-driver.md is exercised by handing binaries to `handle_text/2'
%%% and reading the frames it returns. That is the reason the protocol
%%% was split out of the cowboy handler, and it is also what keeps
%%% `rebar3 eunit' from opening port 8080.
%%%-------------------------------------------------------------------
-module(vs_driver_proto_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"dev-secret-change-me-0123456789ab">>).
-define(USER, 12).
-define(VEHICLE, 88).

%% contracts/sample-tokens.md §1 — user 12, vehicle 88, valid until 2027.
-define(TOKEN,
        <<"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZC"
          "I6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxODMwMjkzOTQwLCJleHAiOjE4"
          "MzAyOTc1NDB9.VjbzuBTej0HI5PFV-Fl5x4WE5yfyxzWn58Qj4aNr3yQ">>).
%% §2 — expired.
-define(EXPIRED_TOKEN,
        <<"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZC"
          "I6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxNzg3Mzk3NDY2LCJleHAiOjE3"
          "ODc0MDEwNjZ9.xNtU08G70bYR15Ws67c4ecyuSzbvLZN24BVv8JJ7ThA">>).
%% §3 — signed with the wrong secret.
-define(FORGED_TOKEN,
        <<"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZC"
          "I6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxNzg3NDA4MjY2LCJleHAiOjE3"
          "ODc0MTE4NjZ9.Nr4iyC7Nbr-jMgYqCLpd8eQvOBI734jkVcwTbVgSwnI">>).

%%%===================================================================
%%% fixture
%%%===================================================================

%% jose has to be up before the first token is verified, and every test
%% wants a clean stub. Both are arranged once here, and each case is
%% named so that a failure says which rule of the contract broke.
proto_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(jose), Started end,
     fun(_) -> ok end,
     [{Name, fun() -> setup(), Case() end} || {Name, Case} <- cases()]}.

cases() ->
    [{"an action before join is cut off",
      fun action_before_join_is_cut_off/0},
     {"join answers ack then state",
      fun join_answers_ack_then_state/0},
     {"join binds the identity from the token only",
      fun join_binds_the_identity_from_the_token_only/0},
     {"a forged token closes 4401",
      fun forged_token_closes_4401/0},
     {"an expired token closes 4408",
      fun expired_token_closes_4408/0},
     {"a join without a token closes 4401",
      fun join_without_a_token_closes_4401/0},
     {"malformed JSON closes 4400",
      fun malformed_json_closes_4400/0},
     {"a frame that is not an object is a bad request",
      fun a_frame_that_is_not_an_object_is_a_bad_request/0},
     {"request_id is mandatory",
      fun request_id_is_mandatory/0},
     {"payload is mandatory and must be an object",
      fun payload_is_mandatory_and_must_be_an_object/0},
     {"an unknown action is a bad request",
      fun unknown_action_is_a_bad_request/0},
     {"the waiting list is out of M1",
      fun the_waiting_list_is_out_of_m1/0},
     {"an unknown connector is refused",
      fun unknown_connector_is_refused/0},
     {"connector_id must be a positive integer",
      fun connector_id_must_be_a_positive_integer/0},
     {"reserve acks with the lease",
      fun reserve_acks_with_the_lease/0},
     {"refusals map to the wire codes",
      fun refusals_map_to_the_wire_codes/0},
     {"the two refusals of 4.1 stay apart",
      fun the_two_refusals_of_section_4_1_stay_apart/0},
     {"an unmapped refusal becomes invalid_state",
      fun an_unmapped_refusal_becomes_invalid_state/0},
     {"a replayed request_id does not reserve twice",
      fun a_replayed_request_id_does_not_reserve_twice/0},
     {"a replayed join repeats the ack but not the snapshot",
      fun a_replayed_join_does_not_repeat_the_snapshot/0},
     {"a cached reply expires with its ttl",
      fun a_cached_reply_expires_with_its_ttl/0},
     {"the cache evicts past its size",
      fun the_cache_evicts_past_its_size/0},
     {"cancelling someone else's reservation is not_yours",
      fun cancel_of_someone_elses_reservation_is_not_yours/0},
     {"stop_session acks",
      fun stop_session_acks/0},
     {"a connector that times out answers no_claim",
      fun a_connector_that_times_out_answers_no_claim/0},
     {"a manager that is down answers retry_later",
      fun a_manager_that_is_down_answers_retry_later/0},
     {"request_id is echoed on ack and error",
      fun request_id_is_echoed_on_ack_and_error/0}].

setup() ->
    vs_driver_stub:reset(),
    ok.

session() ->
    vs_driver_proto:new(#{station_id => 1,
                          secret     => ?SECRET,
                          conn_mod   => vs_driver_stub,
                          mgr_mod    => vs_driver_stub,
                          claim_mod  => vs_driver_stub}).

joined_session() ->
    {[_Ack | _], S} = handle(frame(<<"join">>, <<"r-join">>, #{token => ?TOKEN}),
                             session()),
    S.

handle(Bin, Session) -> vs_driver_proto:handle_text(Bin, Session).

frame(Action, ReqId, Payload) ->
    jsx:encode(#{action => Action, request_id => ReqId, payload => Payload}).

type_of(#{type := T}) -> T.
code_of(#{payload := #{code := C}}) -> C.
message_of(#{payload := #{message := M}}) -> M.

%%%===================================================================
%%% §3 — the handshake
%%%===================================================================

%% "Any action other than join before authentication is answered
%% error / UNAUTHENTICATED and the socket is closed with 4401."
action_before_join_is_cut_off() ->
    {close, Code, [Frame], _S} =
        handle(frame(<<"reserve">>, <<"r-1">>, #{connector_id => 1}), session()),
    ?assertEqual(4401, Code),
    ?assertEqual(error, type_of(Frame)),
    ?assertEqual(<<"UNAUTHENTICATED">>, code_of(Frame)),
    ?assertEqual(<<"r-1">>, maps:get(request_id, Frame)),
    %% and nothing was executed on the way out
    ?assertEqual(0, vs_driver_stub:count(reserve)).

%% §3.3: "It replies ack and immediately pushes a first state, so the
%% page can render without asking."
join_answers_ack_then_state() ->
    {[Ack, State], S} = handle(frame(<<"join">>, <<"r-join">>, #{token => ?TOKEN}),
                               session()),
    ?assertEqual(ack, type_of(Ack)),
    ?assertEqual(<<"r-join">>, maps:get(request_id, Ack)),
    ?assertEqual(#{}, maps:get(payload, Ack)),
    ?assertEqual(state, type_of(State)),
    %% §5: server-initiated frames carry a null correlation id
    ?assertEqual(null, maps:get(request_id, State)),
    ?assertMatch(#{station_id := 1, connectors := [_, _, _, _]}, maps:get(payload, State)),
    ?assert(maps:get(authenticated, S)).

%% §7.3 — the rule this channel exists to enforce: a payload cannot say
%% who you are. The token says user 12 / vehicle 88; the payload lies.
join_binds_the_identity_from_the_token_only() ->
    Bin = jsx:encode(#{action => <<"join">>, request_id => <<"r-j">>,
                       payload => #{token => ?TOKEN, user_id => 999,
                                    vehicle_id => 777}}),
    {_Frames, S} = handle(Bin, session()),
    ?assertEqual(?USER, maps:get(user_id, S)),
    ?assertEqual(?VEHICLE, maps:get(vehicle_id, S)),
    %% and the connector is asked on behalf of the token's identity
    {_, _} = handle(frame(<<"reserve">>, <<"r-2">>, #{connector_id => 1}), S),
    ?assertEqual([{connector_pid, 1}, {reserve, ?USER, ?VEHICLE}],
                 tl(vs_driver_stub:calls())).

forged_token_closes_4401() ->
    ?assertMatch({close, 4401, [], _},
                 handle(frame(<<"join">>, <<"r-j">>, #{token => ?FORGED_TOKEN}),
                        session())).

expired_token_closes_4408() ->
    ?assertMatch({close, 4408, [], _},
                 handle(frame(<<"join">>, <<"r-j">>, #{token => ?EXPIRED_TOKEN}),
                        session())).

join_without_a_token_closes_4401() ->
    ?assertMatch({close, 4401, [], _},
                 handle(frame(<<"join">>, <<"r-j">>, #{}), session())),
    ?assertMatch({close, 4401, [], _},
                 handle(frame(<<"join">>, <<"r-j">>, #{token => 42}), session())).

%%%===================================================================
%%% §2 — the envelope
%%%===================================================================

malformed_json_closes_4400() ->
    ?assertMatch({close, 4400, [], _}, handle(<<"{not json">>, session())),
    ?assertMatch({close, 4400, [], _}, handle(<<>>, session())).

%% Valid JSON, wrong shape. It parsed, so the stream is fine and the
%% client deserves an answer rather than a hang-up.
a_frame_that_is_not_an_object_is_a_bad_request() ->
    {[Frame], _S} = handle(<<"[1,2,3]">>, session()),
    ?assertEqual(<<"BAD_REQUEST">>, code_of(Frame)),
    ?assertEqual(null, maps:get(request_id, Frame)).

%% §2: "Mandatory on every action." With none, the error cannot be
%% correlated, so it goes out with null.
request_id_is_mandatory() ->
    lists:foreach(
      fun(Bin) ->
              {[Frame], _} = handle(Bin, session()),
              ?assertEqual(<<"BAD_REQUEST">>, code_of(Frame)),
              ?assertEqual(null, maps:get(request_id, Frame))
      end,
      [jsx:encode(#{action => <<"reserve">>, payload => #{}}),
       jsx:encode(#{action => <<"reserve">>, request_id => <<>>, payload => #{}}),
       jsx:encode(#{action => <<"reserve">>, request_id => 7, payload => #{}})]).

%% §2: "object; {} when there is nothing to say, never absent."
payload_is_mandatory_and_must_be_an_object() ->
    {[F1], _} = handle(jsx:encode(#{action => <<"reserve">>,
                                    request_id => <<"r-1">>}), session()),
    ?assertEqual(<<"BAD_REQUEST">>, code_of(F1)),
    ?assertEqual(<<"r-1">>, maps:get(request_id, F1)),
    {[F2], _} = handle(jsx:encode(#{action => <<"reserve">>, request_id => <<"r-2">>,
                                    payload => <<"nope">>}), session()),
    ?assertEqual(<<"BAD_REQUEST">>, code_of(F2)).

unknown_action_is_a_bad_request() ->
    {[Frame], _S} = handle(frame(<<"self_destruct">>, <<"r-1">>, #{}), joined_session()),
    ?assertEqual(<<"BAD_REQUEST">>, code_of(Frame)),
    %% no action means no action taken
    ?assertEqual(0, vs_driver_stub:count(reserve)).

%% Pins the M1 perimeter declared in ws-driver.md §4.4: the waiting list
%% is not implemented, so its two actions are simply unknown ones. If
%% somebody implements them, this test is what tells them to come back
%% and delete it.
the_waiting_list_is_out_of_m1() ->
    S = joined_session(),
    lists:foreach(fun(Action) ->
                          {[Frame], _} = handle(frame(Action, <<"r-", Action/binary>>, #{}), S),
                          ?assertEqual(<<"BAD_REQUEST">>, code_of(Frame))
                  end, [<<"join_waitlist">>, <<"leave_waitlist">>]).

%%%===================================================================
%%% §4 — the actions
%%%===================================================================

unknown_connector_is_refused() ->
    {[Frame], _} = handle(frame(<<"reserve">>, <<"r-1">>, #{connector_id => 99}),
                          joined_session()),
    ?assertEqual(<<"UNKNOWN_CONNECTOR">>, code_of(Frame)),
    ?assertEqual(0, vs_driver_stub:count(reserve)).

connector_id_must_be_a_positive_integer() ->
    S = joined_session(),
    lists:foreach(fun(Payload) ->
                          {[Frame], _} = handle(frame(<<"reserve">>, <<"r-x">>, Payload), S),
                          ?assertEqual(<<"BAD_REQUEST">>, code_of(Frame))
                  end,
                  [#{}, #{connector_id => <<"1">>}, #{connector_id => 0},
                   #{connector_id => -3}]).

%% §4.1: the ack carries the connector, the deadline in epoch
%% milliseconds and the lease, so the page counts down from a number the
%% server gave it.
reserve_acks_with_the_lease() ->
    vs_driver_stub:set_reserve({ok, 1755792000000}),
    {[Frame], _} = handle(frame(<<"reserve">>, <<"r-1">>, #{connector_id => 3}),
                          joined_session()),
    ?assertEqual(ack, type_of(Frame)),
    ?assertEqual(#{connector_id => 3, expires_at => 1755792000000,
                   lease_seconds => 900},
                 maps:get(payload, Frame)).

%% The whole of the §4.1/§6 table in one place.
refusals_map_to_the_wire_codes() ->
    S = joined_session(),
    lists:foreach(
      fun({Refusal, Code}) ->
              vs_driver_stub:set_reserve({error, Refusal}),
              ReqId = atom_to_binary(Refusal),
              {[Frame], _} = handle(frame(<<"reserve">>, ReqId, #{connector_id => 1}), S),
              ?assertEqual(error, type_of(Frame)),
              ?assertEqual(Code, code_of(Frame))
      end,
      [{already_held,      <<"ALREADY_HELD">>},
       {vehicle_committed, <<"NO_CLAIM">>},
       {no_claim,          <<"NO_CLAIM">>},
       {suspended,         <<"SUSPENDED">>},
       {retry_later,       <<"RETRY_LATER">>},
       {not_yours,         <<"NOT_YOURS">>},
       {invalid_state,     <<"INVALID_STATE">>}]).

%% The test that would fail if anyone ever merged the two refusals back
%% together. Same action, same connector, same session — only the atom
%% the connector answers with differs, and the driver must be told two
%% different things: "try the next connector" versus "your car is booked
%% somewhere else, and no connector here will help".
%%
%% Two DIFFERENT request_ids on purpose: with the same one the second
%% call would be replayed from the at-most-once cache (§7.2) and the
%% stub's second answer would never be consulted, so the test would pass
%% without proving anything.
the_two_refusals_of_section_4_1_stay_apart() ->
    S = joined_session(),

    %% raised by vs_connector itself: this outlet is taken
    vs_driver_stub:set_reserve({error, already_held}),
    {[Local], _} = handle(frame(<<"reserve">>, <<"req-local">>, #{connector_id => 1}), S),

    %% relayed from the coordinator: this vehicle is committed elsewhere
    vs_driver_stub:set_reserve({error, vehicle_committed}),
    {[Remote], _} = handle(frame(<<"reserve">>, <<"req-remote">>, #{connector_id => 1}), S),

    ?assertEqual(<<"ALREADY_HELD">>, code_of(Local)),
    ?assertEqual(<<"NO_CLAIM">>, code_of(Remote)),
    ?assertNotEqual(code_of(Local), code_of(Remote)),

    %% and the sentence, which is the half the driver actually reads —
    %% verbatim from the "Meaning shown" column of §4.1
    ?assertEqual(<<"your vehicle already holds a reservation elsewhere">>,
                 message_of(Remote)),
    ?assertNotEqual(message_of(Local), message_of(Remote)).

%% `not_your_reservation' is a real refusal of vs_connector with no code
%% in §6: it is raised by `plugged', an event of the charge point
%% channel, so seeing it here means something arrived from a direction
%% nobody designed. It is answered INVALID_STATE and logged.
an_unmapped_refusal_becomes_invalid_state() ->
    vs_driver_stub:set_reserve({error, not_your_reservation}),
    {[Frame], _} = handle(frame(<<"reserve">>, <<"r-1">>, #{connector_id => 1}),
                          joined_session()),
    ?assertEqual(<<"INVALID_STATE">>, code_of(Frame)).

cancel_of_someone_elses_reservation_is_not_yours() ->
    vs_driver_stub:set_cancel({error, not_yours}),
    {[Frame], _} = handle(frame(<<"cancel_reservation">>, <<"r-1">>,
                                #{connector_id => 2}), joined_session()),
    ?assertEqual(<<"NOT_YOURS">>, code_of(Frame)),
    %% the cancellation was attempted on behalf of the token's user
    ?assert(lists:member({cancel, ?USER}, vs_driver_stub:calls())).

stop_session_acks() ->
    {[Frame], _} = handle(frame(<<"stop_session">>, <<"r-1">>, #{connector_id => 2}),
                          joined_session()),
    ?assertEqual(ack, type_of(Frame)),
    ?assertEqual(#{connector_id => 2}, maps:get(payload, Frame)),
    ?assert(lists:member({stop_session, ?USER}, vs_driver_stub:calls())).

%%%===================================================================
%%% §7.2 — at most once
%%%===================================================================

%% The test the design note is written around. A retried reserve must
%% return the *stored* reply, and the connector must not hear about it
%% twice — a page that retries after a lost ack must not end up holding
%% two reservations.
a_replayed_request_id_does_not_reserve_twice() ->
    S0 = joined_session(),
    Bin = frame(<<"reserve">>, <<"a1">>, #{connector_id => 3}),
    {[First], S1} = handle(Bin, S0),
    {[Second], _S2} = handle(Bin, S1),
    ?assertEqual(First, Second),
    ?assertEqual(1, vs_driver_stub:count(reserve)),
    %% not even the lookup of the connector happens the second time
    ?assertEqual(1, vs_driver_stub:count(connector_pid)).

%% The one reply that must not be replayed whole. `join' answers with an
%% ack *and* the first state (§3.3); the ack is an answer and belongs in
%% the cache, the state is a snapshot and does not — resending it a
%% minute later would hand the page a photograph of a station that has
%% moved on, and §7.1 makes that photograph its whole truth.
a_replayed_join_does_not_repeat_the_snapshot() ->
    Bin = frame(<<"join">>, <<"j-1">>, #{token => ?TOKEN}),
    {[Ack, State], S1} = handle(Bin, session()),
    ?assertEqual(ack, type_of(Ack)),
    ?assertEqual(state, type_of(State)),
    {Replay, _S2} = handle(Bin, S1),
    ?assertEqual([Ack], Replay),
    %% and the manager was not asked for a second snapshot
    ?assertEqual(1, vs_driver_stub:count(station_state)).

%% REQUEST_CACHE_TTL_MS: past it the reply is no longer replayable and
%% the action is executed again. Injected through the session, so the
%% test does not sleep for a minute.
a_cached_reply_expires_with_its_ttl() ->
    S0 = (joined_session())#{cache_ttl_ms := 20},
    Bin = frame(<<"reserve">>, <<"a1">>, #{connector_id => 3}),
    {_, S1} = handle(Bin, S0),
    ?assertEqual(1, vs_driver_stub:count(reserve)),
    timer:sleep(40),
    {_, _S2} = handle(Bin, S1),
    ?assertEqual(2, vs_driver_stub:count(reserve)).

%% REQUEST_CACHE_SIZE: the cache is bounded, so a long-lived connection
%% cannot grow one reply at a time. The oldest entry falls out first.
the_cache_evicts_past_its_size() ->
    S0 = (joined_session())#{cache_size := 3},
    Oldest = frame(<<"reserve">>, <<"a1">>, #{connector_id => 3}),
    {_, S1} = handle(Oldest, S0),
    S4 = lists:foldl(fun(N, S) ->
                             ReqId = <<"b", (integer_to_binary(N))/binary>>,
                             {_, S1b} = handle(frame(<<"reserve">>, ReqId,
                                                     #{connector_id => 3}), S),
                             S1b
                     end, S1, [1, 2, 3]),
    ?assertEqual(3, length(maps:get(cache, S4))),
    ?assertEqual(4, vs_driver_stub:count(reserve)),
    %% "a1" was evicted: replaying it runs the action a fifth time
    {_, _} = handle(Oldest, S4),
    ?assertEqual(5, vs_driver_stub:count(reserve)).

%%%===================================================================
%%% degradation
%%%===================================================================

%% The measured case: `reserve' can outlive the 5 s implicit timeout of
%% the gen_statem call, because acquire may spend ~8 s walking the
%% coordinators. Without the catch the WebSocket process dies and the
%% browser sees a disconnection instead of an answer.
a_connector_that_times_out_answers_no_claim() ->
    vs_driver_stub:set_reserve(timeout),
    {[Frame], S} = handle(frame(<<"reserve">>, <<"r-1">>, #{connector_id => 1}),
                          joined_session()),
    ?assertEqual(<<"NO_CLAIM">>, code_of(Frame)),
    %% the session survived and can still be used
    ?assert(maps:get(authenticated, S)).

%% Same shape one level up: the manager restarting is a transient
%% internal condition, so the driver is told to try again rather than
%% being told the connector does not exist.
a_manager_that_is_down_answers_retry_later() ->
    S = joined_session(),
    vs_driver_stub:set_connectors(manager_down),
    {[Frame], _} = handle(frame(<<"reserve">>, <<"r-1">>, #{connector_id => 1}), S),
    ?assertEqual(<<"RETRY_LATER">>, code_of(Frame)).

%% §2: echoed on ack and error, and only there.
request_id_is_echoed_on_ack_and_error() ->
    S = joined_session(),
    {[Ack], _} = handle(frame(<<"reserve">>, <<"echo-1">>, #{connector_id => 1}), S),
    ?assertEqual(<<"echo-1">>, maps:get(request_id, Ack)),
    vs_driver_stub:set_reserve({error, already_held}),
    {[Err], _} = handle(frame(<<"reserve">>, <<"echo-2">>, #{connector_id => 1}), S),
    ?assertEqual(<<"echo-2">>, maps:get(request_id, Err)).

%%%===================================================================
%%% §5.1 — the wire snapshot
%%%===================================================================

%% `offline' is the manager's invention for "no process answers"; the
%% enum of §5.1 has no such name. It also arrives with three keys only,
%% so every read must have a default — this is the test that proves it.
offline_becomes_out_of_service_test() ->
    Wire = vs_driver_proto:wire_state(
             #{station_id => 1, connectors => [#{connector_id => 4, rated_kw => 50,
                                                 state => offline}]},
             ?USER, true),
    [C] = maps:get(connectors, Wire),
    ?assertEqual(out_of_service, maps:get(state, C)),
    ?assertEqual(false, maps:get(held_by_me, C)),
    ?assertEqual(false, maps:get(mine, C)),
    ?assertEqual(null, maps:get(expires_at, C)),
    ?assertEqual(0, maps:get(power_kw, C)).

%% §5.1: "held_by_me and mine are computed server-side from the token."
%% They are not synonyms — held_by_me is "the reservation is mine", mine
%% is "reservation or running session is mine".
held_by_me_and_mine_are_computed_from_the_token_test() ->
    Wire = vs_driver_proto:wire_state(
             #{station_id => 1,
               connectors => [#{connector_id => 1, rated_kw => 150, state => held,
                                held_by => ?USER, expires_at => 1755792000000,
                                power_kw => 0},
                              #{connector_id => 2, rated_kw => 150, state => held,
                                held_by => 77, expires_at => 1755792000000,
                                power_kw => 0},
                              #{connector_id => 3, rated_kw => 150, state => charging,
                                held_by => undefined, expires_at => undefined,
                                power_kw => 120.0,
                                session => #{user_id => ?USER, vehicle_id => ?VEHICLE}},
                              #{connector_id => 4, rated_kw => 50, state => charging,
                                held_by => undefined, expires_at => undefined,
                                power_kw => 43.0,
                                session => #{user_id => 77, vehicle_id => 5}}]},
             ?USER, true),
    [C1, C2, C3, C4] = maps:get(connectors, Wire),
    %% my reservation: both true
    ?assertEqual({true, true}, {maps:get(held_by_me, C1), maps:get(mine, C1)}),
    ?assertEqual(1755792000000, maps:get(expires_at, C1)),
    %% somebody else's reservation: both false
    ?assertEqual({false, false}, {maps:get(held_by_me, C2), maps:get(mine, C2)}),
    %% my running session: mine without held_by_me — the two are different
    ?assertEqual({false, true}, {maps:get(held_by_me, C3), maps:get(mine, C3)}),
    ?assertEqual(120.0, maps:get(power_kw, C3)),
    %% somebody else's session
    ?assertEqual({false, false}, {maps:get(held_by_me, C4), maps:get(mine, C4)}).

%% Every field of the §5.1 payload, including the ones the manager only
%% learned to say in this step and the constant that stands in for the
%% waiting list.
the_snapshot_carries_every_field_of_the_contract_test() ->
    Wire = vs_driver_proto:wire_state(
             #{station_id => 2, name => <<"Livorno Port">>, site_power_kw => 180,
               allocated_kw => 210.5, tariff_cents_kwh => 42,
               connectors => []},
             ?USER, false),
    ?assertEqual(2, maps:get(station_id, Wire)),
    ?assertEqual(<<"Livorno Port">>, maps:get(name, Wire)),
    ?assertEqual(180, maps:get(site_power_kw, Wire)),
    ?assertEqual(210.5, maps:get(allocated_kw, Wire)),
    ?assertEqual(42, maps:get(tariff_cents_kwh, Wire)),
    ?assertEqual(false, maps:get(coordinator_reachable, Wire)),
    %% §4.4 out of M1: a declared constant, never a missing key
    ?assertEqual(#{length => 0, my_position => null}, maps:get(waitlist, Wire)),
    ?assertEqual([], maps:get(connectors, Wire)).

%% The snapshot travels as JSON, and jsx renders the atom `undefined' as
%% the string "undefined" — only `null' becomes a JSON null. This is the
%% test that keeps `expires_at' from ever reaching a page as a word.
the_snapshot_survives_the_json_codec_test() ->
    Wire = vs_driver_proto:wire_state(
             #{station_id => 1, name => <<"Pisa Centro">>, site_power_kw => 350,
               allocated_kw => 0, tariff_cents_kwh => 45,
               connectors => [#{connector_id => 1, rated_kw => 150, state => free,
                                held_by => undefined, expires_at => undefined,
                                power_kw => 0.0}]},
             ?USER, true),
    Decoded = jsx:decode(jsx:encode(#{type => state, request_id => null,
                                      payload => Wire})),
    ?assertEqual(<<"state">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(null, maps:get(<<"request_id">>, Decoded)),
    P = maps:get(<<"payload">>, Decoded),
    ?assertEqual(true, maps:get(<<"coordinator_reachable">>, P)),
    [C] = maps:get(<<"connectors">>, P),
    ?assertEqual(<<"free">>, maps:get(<<"state">>, C)),
    ?assertEqual(null, maps:get(<<"expires_at">>, C)),
    ?assertEqual(#{<<"length">> => 0, <<"my_position">> => null},
                 maps:get(<<"waitlist">>, P)).

%% §5.1 again, from the other end: the flag the claim client publishes
%% reaches the page, and a claim client that is not up yet reads as
%% reachable rather than crashing the push.
coordinator_reachable_comes_from_the_claim_client_test() ->
    vs_driver_stub:reset(),
    S = vs_driver_proto:new(#{station_id => 1, secret => ?SECRET,
                              conn_mod => vs_driver_stub, mgr_mod => vs_driver_stub,
                              claim_mod => vs_driver_stub}),
    vs_driver_stub:set_reachable(false),
    ?assertEqual(false, vs_driver_proto:coordinator_reachable(S)),
    vs_driver_stub:set_reachable(true),
    ?assertEqual(true, vs_driver_proto:coordinator_reachable(S)),
    %% a module that is not there at all: optimistic, never an exception
    NoClient = S#{claim_mod := vs_no_such_module},
    ?assertEqual(true, vs_driver_proto:coordinator_reachable(NoClient)).

%%%===================================================================
%%% §5.2 — the live session
%%%===================================================================
%%%
%%% Same discipline as §5.1 above and for the same reason: the frame is a
%%% function of a manager state map and an identity, so the whole of the
%%% contract is asserted on maps built by hand — no manager, no connectors
%%% and no socket. The session is written out as the one key the function
%%% actually reads, which is also the cheapest way of saying what it
%%% depends on.

%% A station holding the given connector, with a free one and an offline
%% one on either side so that the search has to find the right entry.
station_with(Connector) ->
    #{station_id => 1, name => <<"Pisa Centro">>, site_power_kw => 350,
      allocated_kw => 150.0, tariff_cents_kwh => 45,
      connectors => [#{connector_id => 1, rated_kw => 150, state => free,
                       held_by => undefined, expires_at => undefined,
                       power_kw => 0.0},
                     Connector,
                     #{connector_id => 4, rated_kw => 50, state => offline}]}.

%% A charging connector of ?USER's, exactly as `vs_connector:build_snapshot/2'
%% shapes it. `Overrides' replaces keys at the top; `session' inside it
%% replaces keys of the sub-map rather than the whole of it.
charging(Overrides) ->
    Session = maps:merge(#{user_id => ?USER, vehicle_id => ?VEHICLE,
                           started_at => 1755790000000, energy_kwh => 12.317,
                           soc_pct => 58, battery_kwh => 58.0,
                           max_kw => 150, limit_kw => 150.0},
                         maps:get(session, Overrides, #{})),
    Base = maps:merge(#{connector_id => 2, rated_kw => 150, state => charging,
                        held_by => undefined, expires_at => undefined,
                        power_kw => 89.4},
                      maps:remove(session, Overrides)),
    Base#{session => Session}.

%% Everything `session_frame/2' reads of a session, and nothing else.
driver(UserId) -> #{user_id => UserId}.

payload_of(#{payload := P}) -> P.

%% §5.2, field by field. `overstay_seconds' is declared and zero rather
%% than missing: M4 will fill it in, and until then the page renders the
%% shape it always will.
the_session_frame_carries_every_field_of_the_contract_test() ->
    Frame = vs_driver_proto:session_frame(station_with(charging(#{})), driver(?USER)),
    ?assertEqual(session, maps:get(type, Frame)),
    %% §5: server-initiated frames carry a null correlation id
    ?assertEqual(null, maps:get(request_id, Frame)),
    P = payload_of(Frame),
    ?assertEqual(2, maps:get(connector_id, P)),
    ?assertEqual(charging, maps:get(phase, P)),
    ?assertEqual(89.4, maps:get(power_kw, P)),
    ?assertEqual(12.317, maps:get(energy_kwh, P)),
    ?assertEqual(58, maps:get(soc_pct, P)),
    ?assertEqual(1755790000000, maps:get(started_at, P)),
    ?assertEqual(0, maps:get(overstay_seconds, P)),
    %% 58 kWh x 42 % = 24.36 kWh left, at 89.4 kW
    ?assertEqual(981, maps:get(eta_seconds, P)),
    %% exactly the eight fields of the contract, no more
    ?assertEqual(lists:sort([connector_id, phase, power_kw, energy_kwh, soc_pct,
                             eta_seconds, started_at, overstay_seconds]),
                 lists:sort(maps:keys(P))).

%% "Sent ... to the owner of a running session". A driver who is not
%% charging receives nothing at all — not a frame of zeroes, which the page
%% could not tell from a session standing still.
a_driver_without_a_session_gets_no_frame_test() ->
    Station = station_with(charging(#{})),
    ?assertEqual(undefined, vs_driver_proto:session_frame(Station, driver(77))),
    %% and neither does a socket that has not joined yet
    ?assertEqual(undefined, vs_driver_proto:session_frame(Station, driver(undefined))),
    %% nor anybody at all on a station where nothing is charging
    Idle = #{station_id => 1,
             connectors => [#{connector_id => 1, rated_kw => 150, state => free,
                              held_by => undefined, expires_at => undefined,
                              power_kw => 0.0}]},
    ?assertEqual(undefined, vs_driver_proto:session_frame(Idle, driver(?USER))).

%% §7.3: the owner is matched on the identity the token bound. Two sessions
%% on the same station, and each driver sees his own.
the_frame_belongs_to_the_owner_of_the_session_test() ->
    Station = #{station_id => 1,
                connectors => [charging(#{connector_id => 2,
                                          session => #{user_id => 77,
                                                       soc_pct => 30}}),
                               charging(#{connector_id => 3, power_kw => 43.0})]},
    Mine   = payload_of(vs_driver_proto:session_frame(Station, driver(?USER))),
    Theirs = payload_of(vs_driver_proto:session_frame(Station, driver(77))),
    ?assertEqual(3, maps:get(connector_id, Mine)),
    ?assertEqual(43.0, maps:get(power_kw, Mine)),
    ?assertEqual(2, maps:get(connector_id, Theirs)),
    ?assertEqual(30, maps:get(soc_pct, Theirs)).

%% M2 step 2 derives `suspended' in the connector's snapshot from a limit of
%% zero; §5.2 shows it to the driver under the same name. This is the only
%% place where the power split becomes visible to whoever is charging.
the_phase_is_suspended_when_the_connector_is_test() ->
    Frame = vs_driver_proto:session_frame(
              station_with(charging(#{state => suspended, power_kw => 0.0,
                                      session => #{limit_kw => 0.0}})),
              driver(?USER)),
    P = payload_of(Frame),
    ?assertEqual(suspended, maps:get(phase, P)),
    %% no power flowing, so there is no estimate to give
    ?assertEqual(null, maps:get(eta_seconds, P)).

%% The rule §5.2 is explicit about: `complete' comes from the state of
%% charge, never from a power near zero, which is ambiguous between a
%% suspension and a deep taper.
the_phase_is_complete_from_the_soc_and_never_from_the_power_test() ->
    Tapering = payload_of(vs_driver_proto:session_frame(
                            station_with(charging(#{power_kw => 0.4,
                                                    session => #{soc_pct => 94}})),
                            driver(?USER))),
    ?assertEqual(charging, maps:get(phase, Tapering)),
    Full = payload_of(vs_driver_proto:session_frame(
                        station_with(charging(#{power_kw => 0.4,
                                                session => #{soc_pct => 100}})),
                        driver(?USER))),
    ?assertEqual(complete, maps:get(phase, Full)),
    %% and a full battery is finished whatever the allocator did with the
    %% last few kilowatts: `complete' wins over `suspended'
    Both = payload_of(vs_driver_proto:session_frame(
                        station_with(charging(#{state => suspended, power_kw => 0.0,
                                                session => #{soc_pct => 100}})),
                        driver(?USER))),
    ?assertEqual(complete, maps:get(phase, Both)).

%% "It is advisory and may jump when another car arrives and the allocation
%% is recomputed — that jump is the visible proof of P5 and should not be
%% smoothed away." The same session, the same battery, the same state of
%% charge: only the allocation changed, and the estimate follows it at once
%% and by the full amount.
the_eta_jumps_with_the_allocation_test() ->
    Alone  = payload_of(vs_driver_proto:session_frame(
                          station_with(charging(#{power_kw => 150.0})), driver(?USER))),
    Shared = payload_of(vs_driver_proto:session_frame(
                          station_with(charging(#{power_kw => 100.0})), driver(?USER))),
    ?assertEqual(585, maps:get(eta_seconds, Alone)),
    ?assertEqual(877, maps:get(eta_seconds, Shared)).

%% An estimate that does not exist is not an estimate of infinity, and it
%% must travel as the atom `null': jsx renders `undefined' as the string
%% "undefined" (the trap `expires_at' has in §5.1).
the_eta_is_null_when_there_is_nothing_to_divide_by_test() ->
    NoPower = payload_of(vs_driver_proto:session_frame(
                           station_with(charging(#{power_kw => 0.0})), driver(?USER))),
    ?assertEqual(null, maps:get(eta_seconds, NoPower)),
    %% a battery of unknown size, which ws-chargepoint.md §4.2 permits in a
    %% way it does not permit a missing `max_kw': running the formula anyway
    %% would print "0 seconds" over a car that has just been plugged in
    NoBattery = payload_of(vs_driver_proto:session_frame(
                             station_with(charging(#{session => #{battery_kwh => 0.0}})),
                             driver(?USER))),
    ?assertEqual(null, maps:get(eta_seconds, NoBattery)),
    %% a meter that reports past full does not produce a negative estimate
    Past = payload_of(vs_driver_proto:session_frame(
                        station_with(charging(#{session => #{soc_pct => 103}})),
                        driver(?USER))),
    ?assertEqual(0, maps:get(eta_seconds, Past)).

%% §5.2: "and once more when it ends". The socket notices the end because
%% the session is no longer in the snapshot, and answers with the values it
%% had — so the page shows the total of the charge that has just finished
%% instead of freezing on the last live reading.
the_session_ends_with_a_closed_frame_test() ->
    Live = station_with(charging(#{})),
    Gone = station_with(#{connector_id => 2, rated_kw => 150, state => free,
                          held_by => undefined, expires_at => undefined,
                          power_kw => 0.0}),
    {[Frame], Last} = vs_driver_proto:session_push(Live, driver(?USER), undefined),
    ?assertEqual(charging, maps:get(phase, payload_of(Frame))),
    {[Closed], Last1} = vs_driver_proto:session_push(Gone, driver(?USER), Last),
    P = payload_of(Closed),
    ?assertEqual(closed, maps:get(phase, P)),
    ?assertEqual(12.317, maps:get(energy_kwh, P)),
    ?assertEqual(2, maps:get(connector_id, P)),
    ?assertEqual(1755790000000, maps:get(started_at, P)),
    %% said once, then silence: the session is over and there is nothing
    %% left to report about it
    ?assertEqual(undefined, Last1),
    ?assertEqual({[], undefined},
                 vs_driver_proto:session_push(Gone, driver(?USER), Last1)).

%% The other half of the same rule: a driver who never had a session is
%% never told that one ended, because none did.
a_driver_who_never_charged_is_never_told_it_is_over_test() ->
    Idle = #{station_id => 1, connectors => []},
    ?assertEqual({[], undefined},
                 vs_driver_proto:session_push(Idle, driver(?USER), undefined)),
    %% and a live session is remembered, which is what makes the end
    %% recognisable one tick later
    {[Frame], Last} = vs_driver_proto:session_push(station_with(charging(#{})),
                                                   driver(?USER), undefined),
    ?assertEqual(Frame, Last).

%% The frame travels as JSON. `null' has to survive as a JSON null and the
%% phase as a string; an atom reaching the page as the word "undefined"
%% would be a bug none of the tests above can see.
the_session_frame_survives_the_json_codec_test() ->
    Frame = vs_driver_proto:session_frame(
              station_with(charging(#{state => suspended, power_kw => 0.0})),
              driver(?USER)),
    Decoded = jsx:decode(jsx:encode(Frame)),
    ?assertEqual(<<"session">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(null, maps:get(<<"request_id">>, Decoded)),
    P = maps:get(<<"payload">>, Decoded),
    ?assertEqual(<<"suspended">>, maps:get(<<"phase">>, P)),
    ?assertEqual(null, maps:get(<<"eta_seconds">>, P)),
    ?assertEqual(0, maps:get(<<"overstay_seconds">>, P)),
    ?assertEqual(1755790000000, maps:get(<<"started_at">>, P)).

%% The addition to `vs_connector:build_snapshot/2' is for §5.2 alone:
%% `wire_connector' reads the keys it names, so the battery size does not
%% leak into the §5.1 connector entry, whose shape is fixed.
the_battery_size_does_not_leak_into_the_state_frame_test() ->
    Wire = vs_driver_proto:wire_state(station_with(charging(#{})), ?USER, true),
    [_Free, Mine, _Offline] = maps:get(connectors, Wire),
    ?assertEqual(lists:sort([connector_id, rated_kw, state, held_by_me, mine,
                             expires_at, power_kw]),
                 lists:sort(maps:keys(Mine))),
    %% and it is still the same session, seen from §5.1
    ?assertEqual({false, true}, {maps:get(held_by_me, Mine), maps:get(mine, Mine)}).
