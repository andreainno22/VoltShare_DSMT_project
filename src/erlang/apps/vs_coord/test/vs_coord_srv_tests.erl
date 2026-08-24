%%%-------------------------------------------------------------------
%%% @doc Tests for the claim logic.
%%%
%%% These cover the rules of contracts/claim.md that the station side relies
%%% on. The interesting ones are the last three: they are the failover cases,
%%% the part that is hard to reason about and impossible to check by hand.
%%%-------------------------------------------------------------------
-module(vs_coord_srv_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STATION_1, 1).
-define(STATION_2, 2).
-define(VEHICLE, 88).
-define(USER, 12).

%%%===================================================================
%%% fixture
%%%===================================================================

%% CLAIM_GRACE_SECONDS is read once in init/1 and kept in the state, unlike
%% LEASE_SECONDS which is read on every grant. A test that wants a different
%% grace has to set it here, before start_link/0 — setting it inside a test
%% body has no effect. Zero keeps the expiry arithmetic equal to the lease.
setup() ->
    os:putenv("LEASE_SECONDS", "900"),
    os:putenv("CLAIM_GRACE_SECONDS", "0"),
    {ok, Pid} = vs_coord_srv:start_link(),
    announce(?STATION_1, 'vs@station1'),
    announce(?STATION_2, 'vs@station2'),
    Pid.

%% exit/2 is asynchronous: without waiting for the process to be gone, the next
%% setup/0 of the foreach fixture races the unregistering of vs_coord_srv and
%% fails with {already_started, Pid}.
cleanup(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        demonitor(Ref, [flush]),
        error(coordinator_did_not_stop)
    end,
    os:unsetenv("LEASE_SECONDS"),
    os:unsetenv("CLAIM_GRACE_SECONDS").

%% The coordinator refuses claims for stations it has never heard of, so the
%% tests have to announce them first — exactly as a real station does on boot.
announce(StationId, Node) ->
    vs_coord_srv:station_up({station_up, StationId, Node,
                             <<"Station">>, <<"ws://localhost:9101/ws/driver">>,
                             350, 45, [1, 2, 3]}),
    %% station_up is a cast: make sure it has been processed before going on
    _ = vs_coord_srv:mode(),
    ok.

claim_fixture(Tests) ->
    {foreach, fun setup/0, fun cleanup/1, Tests}.

%%%===================================================================
%%% tests
%%%===================================================================

claims_test_() ->
    claim_fixture([
        fun free_vehicle_is_granted/1,
        fun second_station_is_refused/1,
        fun released_vehicle_can_be_claimed_again/1,
        fun suspended_user_is_refused/1,
        fun unknown_station_is_refused/1,
        fun expired_claim_no_longer_blocks/1,
        fun late_release_does_not_erase_the_new_claim/1,
        fun own_claim_is_renewed/1,
        fun unknown_claim_is_adopted/1,
        fun renew_without_granted_at_is_accepted/1,
        fun oldest_claim_wins_a_conflict/1
    ]).

free_vehicle_is_granted(_) ->
    fun() ->
        Reply = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        ?assertMatch({ok, <<"r-1">>, _ClaimId, _ExpiresAt}, Reply),
        ?assertEqual(1, length(vs_coord_srv:claims()))
    end.

second_station_is_refused(_) ->
    fun() ->
        {ok, _, _, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        Reply = vs_coord_srv:claim(<<"r-2">>, ?VEHICLE, ?USER, ?STATION_2, 7),
        %% This single assertion is the invariant the whole project exists for.
        ?assertEqual({error, <<"r-2">>, already_held}, Reply),
        ?assertEqual(1, length(vs_coord_srv:claims()))
    end.

released_vehicle_can_be_claimed_again(_) ->
    fun() ->
        {ok, _, ClaimId, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        vs_coord_srv:release(ClaimId, completed),
        _ = vs_coord_srv:mode(),   %% let the cast land
        ?assertMatch({ok, <<"r-2">>, _, _},
                     vs_coord_srv:claim(<<"r-2">>, ?VEHICLE, ?USER, ?STATION_2, 7))
    end.

suspended_user_is_refused(_) ->
    fun() ->
        Until = erlang:system_time(second) + 3600,
        whereis(vs_coord_srv) ! {user_suspended, ?USER, Until},
        _ = vs_coord_srv:mode(),
        ?assertEqual({error, <<"r-1">>, suspended},
                     vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3))
    end.

unknown_station_is_refused(_) ->
    fun() ->
        ?assertEqual({error, <<"r-1">>, unknown_station},
                     vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, 99, 3))
    end.

%% A claim past its expiry must not block the vehicle even before the sweep
%% has removed it: the sweep is housekeeping, not the rule.
expired_claim_no_longer_blocks(_) ->
    fun() ->
        %% grace is already 0 from setup/0; only the lease can be changed here
        os:putenv("LEASE_SECONDS", "0"),
        {ok, _, _, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        timer:sleep(5),
        ?assertMatch({ok, <<"r-2">>, _, _},
                     vs_coord_srv:claim(<<"r-2">>, ?VEHICLE, ?USER, ?STATION_2, 7))
    end.

%% Regression. A station whose lease has just expired sends its release; by then
%% the vehicle may already have been claimed elsewhere. The stale release must
%% not take the new claim with it — if it does, two stations end up believing
%% they hold the same vehicle, which is P2 broken.
late_release_does_not_erase_the_new_claim(_) ->
    fun() ->
        os:putenv("LEASE_SECONDS", "0"),
        {ok, _, StaleClaimId, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        timer:sleep(5),

        os:putenv("LEASE_SECONDS", "900"),
        {ok, _, FreshClaimId, _} = vs_coord_srv:claim(<<"r-2">>, ?VEHICLE, ?USER, ?STATION_2, 7),

        vs_coord_srv:release(StaleClaimId, expired),
        _ = vs_coord_srv:mode(),   %% let the cast land

        [#{claim_id := Kept, station_id := Station}] = vs_coord_srv:claims(),
        ?assertEqual(FreshClaimId, Kept, "the valid claim must survive a stale release"),
        ?assertEqual(?STATION_2, Station),
        ?assertEqual({error, <<"r-3">>, already_held},
                     vs_coord_srv:claim(<<"r-3">>, ?VEHICLE, ?USER, ?STATION_1, 3),
                     "and it must still protect the vehicle")
    end.

own_claim_is_renewed(_) ->
    fun() ->
        {ok, _, ClaimId, FirstExpiry} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        [#{granted_at := GrantedAt}] = vs_coord_srv:claims(),
        timer:sleep(5),
        {renewed, Ok, Revoked, NewExpiry} =
            vs_coord_srv:renew(?STATION_1, [{ClaimId, ?VEHICLE, 3, GrantedAt}]),
        ?assertEqual([ClaimId], Ok),
        ?assertEqual([], Revoked),
        ?assert(NewExpiry >= FirstExpiry)
    end.

%% The failover case: this leader never granted the claim, the station tells it
%% about one. Refusing would cancel a perfectly good reservation.
unknown_claim_is_adopted(_) ->
    fun() ->
        Ghost = <<"c-from-the-previous-leader">>,
        GrantedAt = vs_time:now_ms() - 60000,
        {renewed, Ok, Revoked, _} =
            vs_coord_srv:renew(?STATION_1, [{Ghost, ?VEHICLE, 3, GrantedAt}]),
        ?assertEqual([Ghost], Ok),
        ?assertEqual([], Revoked),
        ?assertEqual({error, <<"r-x">>, already_held},
                     vs_coord_srv:claim(<<"r-x">>, ?VEHICLE, ?USER, ?STATION_2, 7),
                     "an adopted claim must protect the vehicle like any other")
    end.

%% Interoperability with a station that still sends the three-field form. It must
%% keep working: refusing would be bad, crashing on function_clause — which is what
%% happened before this clause existed — would take the coordinator down and lose
%% every claim, on a message that arrives every ten seconds.
renew_without_granted_at_is_accepted(_) ->
    fun() ->
        {ok, _, ClaimId, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),

        {renewed, Ok, Revoked, _} =
            vs_coord_srv:renew(?STATION_1, [{ClaimId, ?VEHICLE, 3}]),

        ?assertEqual([ClaimId], Ok),
        ?assertEqual([], Revoked),
        ?assertEqual(1, length(vs_coord_srv:claims())),

        %% and an unknown one in the old form is adopted, not dropped
        Ghost = <<"c-legacy">>,
        {renewed, [Ghost], [], _} =
            vs_coord_srv:renew(?STATION_2, [{Ghost, 99, 7}]),
        ?assertEqual(2, length(vs_coord_srv:claims()))
    end.

%% Two stations claiming the same vehicle after a failover. Deterministic rule,
%% so that both stations and any future leader reach the same conclusion.
oldest_claim_wins_a_conflict(_) ->
    fun() ->
        Now = vs_time:now_ms(),
        Newer = <<"c-newer">>,
        Older = <<"c-older">>,

        {renewed, [Newer], [], _} =
            vs_coord_srv:renew(?STATION_1, [{Newer, ?VEHICLE, 3, Now - 10000}]),

        {renewed, Ok, Revoked, _} =
            vs_coord_srv:renew(?STATION_2, [{Older, ?VEHICLE, 7, Now - 60000}]),

        ?assertEqual([Older], Ok, "the older claim wins"),
        ?assertEqual([Newer], Revoked, "the newer one is revoked"),

        [#{claim_id := Kept, station_id := Station}] = vs_coord_srv:claims(),
        ?assertEqual(Older, Kept),
        ?assertEqual(?STATION_2, Station)
    end.

%%%===================================================================
%%% cluster map
%%%===================================================================

stations_test_() ->
    claim_fixture([
        fun announced_stations_are_listed/1,
        fun stats_update_the_counters/1,
        fun a_dead_node_takes_its_claims_with_it/1
    ]).

announced_stations_are_listed(_) ->
    fun() ->
        Stations = vs_coord_srv:stations(),
        ?assertEqual(2, length(Stations)),
        %% Positional tuple: Java parses it by position, so the shape is part
        %% of the contract and worth asserting.
        [First | _] = lists:sort(Stations),
        ?assertMatch({_Id, _Node, <<"Station">>, _Free, _Held, _Charging,
                      3, 350, 45, <<"ws://localhost:9101/ws/driver">>}, First)
    end.

stats_update_the_counters(_) ->
    fun() ->
        vs_coord_srv:station_stats(?STATION_1, 1, 1, 1),
        _ = vs_coord_srv:mode(),
        {_, _, _, Free, Held, Charging, _, _, _, _} = station(?STATION_1),
        ?assertEqual({1, 1, 1}, {Free, Held, Charging})
    end.

a_dead_node_takes_its_claims_with_it(_) ->
    fun() ->
        {ok, _, _, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        whereis(vs_coord_srv) ! {nodedown, 'vs@station1'},
        _ = vs_coord_srv:mode(),

        ?assertEqual(1, length(vs_coord_srv:stations()), "the dead station is dropped"),
        ?assertEqual([], vs_coord_srv:claims(), "and so are the claims it held"),
        ?assertMatch({ok, <<"r-2">>, _, _},
                     vs_coord_srv:claim(<<"r-2">>, ?VEHICLE, ?USER, ?STATION_2, 7),
                     "the driver is free to reserve elsewhere")
    end.

station(Id) ->
    [S] = [T || T <- vs_coord_srv:stations(), element(1, T) =:= Id],
    S.
