%%%-------------------------------------------------------------------
%%% @doc Coordinator stand-in for the tests: answers whatever the test
%%% asks it to, and records what it was asked.
%%%
%%% This is why `vs_connector' takes `claim_mod' as an option — the state
%%% machine can be driven through every refusal the contract defines
%%% without a coordinator, without a network, and in milliseconds.
%%%-------------------------------------------------------------------
-module(vs_claim_stub).

-export([set_reply/1, calls/0, reset/0, last_claim_id/0]).
-export([acquire/4, renew/2, release/2, session_closed/1, no_show/2, show_up/1,
         notify/2]).

-define(REPLY, {?MODULE, reply}).
-define(CALLS, {?MODULE, calls}).
-define(LAST,  {?MODULE, last_claim}).

%% Reply :: ok | {error, already_held | suspended | retry_later | no_claim}
set_reply(Reply) -> persistent_term:put(?REPLY, Reply).

reset() ->
    persistent_term:put(?REPLY, ok),
    persistent_term:put(?CALLS, []),
    persistent_term:put(?LAST, undefined).

%% The last claim id handed out — the tests need it to send a revocation,
%% which is the coordinator's privilege and carries the id it granted.
last_claim_id() -> persistent_term:get(?LAST, undefined).

%% Everything the connector asked of the coordinator, oldest first.
calls() -> lists:reverse(persistent_term:get(?CALLS, [])).

record(Call) ->
    persistent_term:put(?CALLS, [Call | persistent_term:get(?CALLS, [])]).

%% Four elements since P14, like the real client: the second is the
%% coordinator's `GrantedAt'. Here it is `now_ms()' — this stub IS the
%% coordinator for these tests, so it is the one clock, which is the
%% property claim.md §5.5 wants and not an approximation of it.
acquire(VehicleId, UserId, StationId, ConnId) ->
    record({acquire, VehicleId, UserId, StationId, ConnId}),
    case persistent_term:get(?REPLY, ok) of
        ok ->
            ClaimId = list_to_binary("c-" ++ integer_to_list(erlang:unique_integer([positive]))),
            persistent_term:put(?LAST, ClaimId),
            {ok, ClaimId, vs_time:now_ms(), vs_time:in_seconds(960)};
        {error, _} = Err ->
            Err
    end.

renew(StationId, ClaimIds) ->
    record({renew, StationId, ClaimIds}),
    {renewed, ClaimIds, []}.

release(ClaimId, Reason) ->
    record({release, ClaimId, Reason}),
    ok.

%% Since M2 step 3 the claim client is also the way out for the back
%% office wake-up, sent by vs_station_db once the row is in MySQL. Landing
%% it in the same call log lets a test assert the tuple field for field.
session_closed(Event) ->
    record({session_closed, Event}),
    ok.

%% M4 — the two penalty events the connector reports (erlang-java.md §2.4).
%%
%% Recorded like everything else, and the count is the assertion here more
%% than the shape. An at-most-once event has no reply to look at: the only
%% observable difference between "sent once" and "sent twice" is a second
%% entry in this log, and a second entry is a doubled counter and an
%% unjust suspension. Hence the tests count, they do not only match.
%%
%% Three elements, not four: the connector knows a user and a connector,
%% and the station id is added one hop later by `vs_claim_client'. What
%% travels on the wire is asserted where it is built — in
%% vs_claim_client_tests, against vs_mock_coord.
no_show(UserId, ConnId) ->
    record({no_show, UserId, ConnId}),
    ok.

show_up(UserId) ->
    record({show_up, UserId}),
    ok.

%% M4-A — the durable copy of a driver notification, as the STATION
%% MANAGER asks for it: two elements, because the kind is all the manager
%% knows and the sentence is looked up one hop later. What actually
%% reaches the coordinator is the 4-tuple, and it is asserted where it is
%% built (vs_claim_client_tests, against vs_mock_coord).
%%
%% Counting matters here as much as matching, for the mirror image of the
%% no-show reason: four kinds pass through this call and only four, so a
%% fifth entry means the manager decided something was durable that the
%% product decision says is not — `reservation_expiring', whose row would
%% be stale, and `reservation_expired', whose row `PenaltyService' already
%% writes with the strike count.
notify(UserId, Kind) ->
    record({notify, UserId, Kind}),
    ok.
