%%%-------------------------------------------------------------------
%%% @doc What a freshly elected leader adopts before it starts serving.
%%%
%%% The rebuild is the part of the failover that is hard to reason about: the
%%% claims were granted by a process that no longer exists, and the new leader
%%% has to take them over without inventing anything. Every test here is about
%%% something surviving a change of leader unchanged.
%%%
%%% The modes the rebuild passes through — standby, rebuilding, suspended — are
%%% tested in `vs_coord_srv_tests', because they belong to that server.
%%%
%%% The election itself needs several nodes and is exercised in the compose
%%% (scenario 5 of the demo). What is testable here without a cluster is the
%%% adoption, which is where the logic lives.
%%%
%%% Note the module name: rebar3 pairs a test module to a source module of the
%%% same stem, so `vs_coord_rebuild_tests' is found through `vs_coord_rebuild'.
%%% The earlier name, `vs_coord_failover_tests', had no source behind it and was
%%% skipped by `rebar3 eunit --app vs_coord' without a word of warning.
%%%-------------------------------------------------------------------
-module(vs_coord_rebuild_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STATION_1, 1).
-define(STATION_2, 2).
-define(VEHICLE, 88).
-define(USER, 12).

%%%===================================================================
%%% fixture
%%%===================================================================

setup() ->
    os:putenv("LEASE_SECONDS", "900"),
    os:putenv("CLAIM_GRACE_SECONDS", "0"),
    %% No station nodes in a local test VM, so the rebuild has nobody to ask and
    %% waits out its window (vs_coord_rebuild:collect/3). Long enough here that a
    %% test can drive it by hand instead of racing it.
    os:putenv("COORD_REBUILD_TIMEOUT_MS", "3000"),
    {ok, Pid} = vs_coord_srv:start_link(),
    announce(?STATION_1, 'vs@station1'),
    announce(?STATION_2, 'vs@station2'),
    Pid.

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
    os:unsetenv("CLAIM_GRACE_SECONDS"),
    os:unsetenv("COORD_REBUILD_TIMEOUT_MS").

announce(StationId, Node) ->
    vs_coord_srv:station_up({station_up, StationId, Node,
                             <<"Station">>, <<"ws://localhost:9101/ws/driver">>,
                             350, 45, [1, 2, 3]}),
    _ = vs_coord_srv:mode(),
    ok.

sync() ->
    vs_coord_srv:mode().

fixture(Tests) ->
    {foreach, fun setup/0, fun cleanup/1, Tests}.

%% The shape stations answer with (claim.md §3.4).
holds(VehicleId, UserId, ConnId, ClaimId, GrantedAt, ExpiresAt) ->
    {VehicleId, UserId, ConnId, ClaimId, GrantedAt, ExpiresAt}.

%% Drives the rebuild by hand: in production these tuples arrive from the
%% stations, here they are delivered straight to the server's mailbox.
answer(Holds) ->
    whereis(vs_coord_srv) ! {rebuilt, Holds}.

%%%===================================================================
%%% tests
%%%===================================================================

rebuild_test_() ->
    fixture([
        fun adopts_what_the_stations_report/1,
        fun preserves_the_original_timestamps/1,
        fun settles_a_conflict_by_oldest_wins/1,
        fun answer_is_ignored_when_not_rebuilding/1,
        fun survives_a_malformed_entry/1
    ]).

adopts_what_the_stations_report(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        answer([{?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-a">>, Now - 5000, Now + 60000)]},
                {?STATION_2, [holds(99, 13, 7, <<"c-b">>, Now - 4000, Now + 60000)]}]),

        ?assertEqual(serving, sync(), "the rebuild is what turns a winner into a server"),
        ?assertEqual(2, length(vs_coord_srv:claims())),

        %% and the adopted claims protect their vehicles like any other
        ?assertMatch({error, <<"r-x">>, already_held},
                     vs_coord_srv:claim(<<"r-x">>, ?VEHICLE, ?USER, ?STATION_2, 2))
    end.

%% The point of asking the stations rather than starting fresh: an adopted claim
%% keeps the timestamp it was born with, so "oldest wins" still means something
%% afterwards, and the driver keeps the lease they were promised instead of
%% having it silently extended.
preserves_the_original_timestamps(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        Granted = Now - 120000,
        Expires = Now + 30000,
        answer([{?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-a">>, Granted, Expires)]}]),
        ?assertEqual(serving, sync()),

        [Claim] = vs_coord_srv:claims(),
        ?assertEqual(Granted, maps:get(granted_at, Claim),
                     "the coordinator must not invent a new granted_at"),
        ?assertEqual(Expires, maps:get(expires_at, Claim),
                     "nor extend the lease the driver was given"),
        ?assertEqual(?USER, maps:get(user_id, Claim),
                     "the user travels with the claim, so suspensions apply at once")
    end.

%% Two stations report the same vehicle — the split-brain leftover. The rule is
%% deterministic so that the leader and both stations reach the same conclusion
%% without negotiating.
settles_a_conflict_by_oldest_wins(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        answer([
            {?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-newer">>, Now - 10000, Now + 60000)]},
            {?STATION_2, [holds(?VEHICLE, ?USER, 7, <<"c-older">>, Now - 90000, Now + 60000)]}
        ]),
        ?assertEqual(serving, sync()),

        [Claim] = vs_coord_srv:claims(),
        ?assertEqual(<<"c-older">>, maps:get(claim_id, Claim), "the older claim wins"),
        ?assertEqual(?STATION_2, maps:get(station_id, Claim)),
        ?assertEqual(1, length(vs_coord_srv:claims()),
                     "one vehicle, one claim — P2 holds through the rebuild")
    end.

%% The answer can arrive after we have been deposed or have lost quorum.
%% Adopting then would rebuild a table this node has no right to serve from.
answer_is_ignored_when_not_rebuilding(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        vs_coord_srv:suspend(),
        ?assertEqual(suspended, sync()),

        Now = vs_time:now_ms(),
        answer([{?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-a">>, Now, Now + 60000)]}]),

        ?assertEqual(suspended, sync(), "a late answer must not resurrect us"),
        ?assertEqual([], vs_coord_srv:claims())
    end.

%% One unusable entry from one station must not cost us the whole rebuild: the
%% alternative is a coordinator stuck in `rebuilding' for ever, refusing every
%% reservation in the network.
survives_a_malformed_entry(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        answer([{?STATION_1, [{garbage},
                              holds(?VEHICLE, ?USER, 3, <<"c-a">>, Now, Now + 60000)]}]),

        ?assertEqual(serving, sync()),
        ?assertEqual(1, length(vs_coord_srv:claims()),
                     "the good claim is kept, the bad one dropped")
    end.
