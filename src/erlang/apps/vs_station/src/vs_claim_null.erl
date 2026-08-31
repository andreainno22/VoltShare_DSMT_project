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

-export([acquire/4, renew/2, release/2, no_show/2, show_up/1]).

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

%%%===================================================================
%%% M4 — the penalty half of the interface
%%%===================================================================

%% These two are here for a reason `session_closed/1' is not: what happens
%% when the callback is missing.
%%
%% `vs_station_db' calls `ClaimMod:session_closed/1' inside a try/catch and
%% treats a failure as one lost best-effort wake-up (the row is already in
%% MySQL and the sweep finds it), so this module can simply not have it —
%% and does not.
%%
%% `vs_connector' calls these two straight from `held/3', with no net,
%% because there is nothing to fall back on: an `undef' would kill the
%% connector at the exact moment a reservation expires or a driver plugs
%% in, and a station running with `CLAIM_MOD=vs_claim_null' would lose an
%% outlet on every no-show. The stand-in has to answer.

%% Loud, like `acquire/4' and for the same reason: with no coordinator
%% there is nobody to count the strike, so the penalty of SCOPE §3.3 is
%% silently not being applied. That is fine in a shell session and would
%% be a hole in a deployment, so it says so.
-spec no_show(pos_integer(), pos_integer()) -> ok.
no_show(UserId, ConnId) ->
    logger:warning("vs_claim_null: no-show for user ~p on connector ~p goes "
                   "NOWHERE — no coordinator was asked, nothing is counted",
                   [UserId, ConnId]),
    ok.

%% Debug, not warning: a show-up that is not reported clears nothing, and
%% clearing nothing when nothing was ever counted is harmless.
-spec show_up(pos_integer()) -> ok.
show_up(UserId) ->
    logger:debug("vs_claim_null: show-up for user ~p goes nowhere", [UserId]),
    ok.
