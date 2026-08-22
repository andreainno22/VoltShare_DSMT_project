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
-export([acquire/4, renew/2, release/2]).

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

acquire(VehicleId, UserId, StationId, ConnId) ->
    record({acquire, VehicleId, UserId, StationId, ConnId}),
    case persistent_term:get(?REPLY, ok) of
        ok ->
            ClaimId = list_to_binary("c-" ++ integer_to_list(erlang:unique_integer([positive]))),
            persistent_term:put(?LAST, ClaimId),
            {ok, ClaimId, vs_time:in_seconds(960)};
        {error, _} = Err ->
            Err
    end.

renew(StationId, ClaimIds) ->
    record({renew, StationId, ClaimIds}),
    {renewed, ClaimIds, []}.

release(ClaimId, Reason) ->
    record({release, ClaimId, Reason}),
    ok.
