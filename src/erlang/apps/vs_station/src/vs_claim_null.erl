%%%-------------------------------------------------------------------
%%% @doc Development stand-in for the claim client: grants everything.
%%%
%%% It exists so that a station started today — before `vs_claim_client'
%%% and before B's coordinator — is playable from the shell. It is the
%%% default only until M1 replaces it, and it announces itself loudly on
%%% every grant: a permissive default that stayed in by accident would
%%% break P2 silently, which is the one failure mode nobody would notice
%%% until the demo.
%%%
%%% Same interface as `vs_claim_client', which is what makes it swappable.
%%%-------------------------------------------------------------------
-module(vs_claim_null).

-export([acquire/4, renew/2, release/2]).

%% Four elements since P14: `GrantedAt' is the second one, and here it is
%% the local clock because there is no other — the whole point of this
%% module is that no coordinator was asked. In `vs_claim_client' the same
%% position carries the coordinator's own timestamp, which is what makes
%% oldest-wins (claim.md §5.5) a comparison between one clock and itself.
-spec acquire(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ->
          {ok, binary(), vs_time:epoch_ms(), vs_time:epoch_ms()} |
          {error, vs_connector:refusal()}.
acquire(VehicleId, UserId, StationId, ConnId) ->
    logger:warning("vs_claim_null: granting an UNCOORDINATED claim "
                   "(vehicle ~p, user ~p, station ~p, connector ~p)",
                   [VehicleId, UserId, StationId, ConnId]),
    ClaimId = list_to_binary("null-" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, ClaimId, vs_time:now_ms(),
     vs_time:in_seconds(vs_env:get_int("LEASE_SECONDS", 900) + 60)}.

-spec renew(pos_integer(), [binary()]) -> {renewed, [binary()], [binary()]}.
renew(_StationId, ClaimIds) ->
    {renewed, ClaimIds, []}.

-spec release(binary(), atom()) -> ok.
release(ClaimId, Reason) ->
    logger:debug("vs_claim_null: release ~s (~p)", [ClaimId, Reason]),
    ok.
