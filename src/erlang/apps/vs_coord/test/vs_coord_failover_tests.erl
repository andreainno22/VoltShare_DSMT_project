%%%-------------------------------------------------------------------
%%% @doc M3: what the coordinator does when it is not the one in charge.
%%%
%%% The claim logic is covered by vs_coord_srv_tests. This file covers the
%%% states around it — standby, suspended, rebuilding — and the rebuild that
%%% turns a freshly elected leader into a serving one.
%%%
%%% These are the cases that decide whether P2 survives a failure, and none of
%%% them can be checked by looking at the happy path: every one of them is
%%% about refusing something, or about adopting something that was granted by
%%% a process that no longer exists.
%%%
%%% The election itself needs several nodes and is exercised in the compose
%%% (scenario 5 of the demo); what is testable here without a cluster is every
%%% decision the coordinator makes once it has been told its role, which is
%%% where the logic actually lives.
%%%-------------------------------------------------------------------
-module(vs_coord_failover_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STATION_1, 1).
-define(STATION_2, 2).
-define(VEHICLE, 88).
-define(USER, 12).
-define(OTHER_COORD, 'vs@coord3').

%%%===================================================================
%%% fixture
%%%===================================================================

setup() ->
    os:putenv("LEASE_SECONDS", "900"),
    os:putenv("CLAIM_GRACE_SECONDS", "0"),
    %% There are no station nodes in a local test VM, so the rebuild has nobody
    %% to ask and waits out its window (see vs_coord_rebuild:collect/3). Long
    %% enough here that a test can observe `rebuilding' and drive it by hand;
    %% the real answer would arrive from the stations.
    os:putenv("COORD_REBUILD_TIMEOUT_MS", "3000"),
    %% No COORD_NODES: a lone coordinator starts serving, which is the state
    %% every test here moves away from deliberately.
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

%% Casts are asynchronous; a synchronous call flushes the mailbox ahead of it.
sync() ->
    vs_coord_srv:mode().

fixture(Tests) ->
    {foreach, fun setup/0, fun cleanup/1, Tests}.

%%%===================================================================
%%% tests
%%%===================================================================

roles_test_() ->
    fixture([
        fun standby_redirects_claims_to_the_leader/1,
        fun standby_redirects_renewals_too/1,
        fun standby_forgets_the_claim_table/1,
        fun suspended_names_no_leader/1,
        fun suspended_refuses_even_though_it_was_leader/1,
        fun rebuilding_refuses_but_still_adopts/1
    ]).

rebuild_test_() ->
    fixture([
        fun rebuild_adopts_what_the_stations_report/1,
        fun rebuild_preserves_the_original_timestamps/1,
        fun rebuild_settles_a_conflict_by_oldest_wins/1,
        fun rebuild_answer_is_ignored_when_not_rebuilding/1,
        fun rebuild_survives_a_malformed_entry/1
    ]).

%%%===================================================================
%%% not the leader
%%%===================================================================

%% A station asking the wrong coordinator must be told where to go, not simply
%% refused: it retries on the named node and the driver never sees the failure
%% (claim.md §4).
standby_redirects_claims_to_the_leader(_) ->
    fun() ->
        vs_coord_srv:become_follower(?OTHER_COORD),
        ?assertEqual(standby, sync()),

        ?assertEqual({not_serving, ?OTHER_COORD},
                     vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3)),

        ?assertEqual([], vs_coord_srv:claims(),
                     "a follower grants nothing")
    end.

%% Renewals matter more than claims here: a renewal is how a leader ADOPTS a
%% claim. Answering one while in standby would build a table this node has no
%% right to hold, and would tell the station its claims are safe on a node that
%% is not deciding anything.
standby_redirects_renewals_too(_) ->
    fun() ->
        vs_coord_srv:become_follower(?OTHER_COORD),
        ?assertEqual(standby, sync()),

        Now = vs_time:now_ms(),
        ?assertEqual({not_serving, ?OTHER_COORD},
                     vs_coord_srv:renew(?STATION_1,
                                        [{<<"c-1">>, ?VEHICLE, 3, ?USER, Now}])),

        ?assertEqual([], vs_coord_srv:claims(),
                     "a redirected renewal must not be adopted")
    end.

%% Being deposed drops the table. Keeping it would leave the follower answering
%% about reservations it no longer tracks, and would poison its own rebuild if
%% it were elected later.
standby_forgets_the_claim_table(_) ->
    fun() ->
        {ok, _, _, _, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        ?assertEqual(1, length(vs_coord_srv:claims())),

        vs_coord_srv:become_follower(?OTHER_COORD),
        ?assertEqual(standby, sync()),

        ?assertEqual([], vs_coord_srv:claims())
    end.

%% Out of quorum we do not name a leader even if we remember one: it may be on
%% the other side of the partition, and sending the station there is worse than
%% admitting we do not know.
suspended_names_no_leader(_) ->
    fun() ->
        vs_coord_srv:become_follower(?OTHER_COORD),
        vs_coord_srv:suspend(),
        ?assertEqual(suspended, sync()),

        ?assertEqual({not_serving, undefined},
                     vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3)),
        ?assertEqual({not_serving, undefined},
                     vs_coord_srv:renew(?STATION_1, [{<<"c-1">>, ?VEHICLE, 3, ?USER, 1}]))
    end.

%% The case the quorum rule exists for: this node WAS the leader, then lost
%% sight of the majority. It must stop granting even though nobody deposed it —
%% otherwise a partition yields two leaders and the same vehicle twice.
suspended_refuses_even_though_it_was_leader(_) ->
    fun() ->
        {ok, _, _, _, _} = vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3),
        ?assertEqual(serving, sync()),

        vs_coord_srv:suspend(),
        ?assertEqual(suspended, sync()),

        ?assertMatch({not_serving, undefined},
                     vs_coord_srv:claim(<<"r-2">>, 99, ?USER, ?STATION_1, 2)),
        ?assertEqual([], vs_coord_srv:claims(),
                     "a suspended coordinator holds nothing it could serve from")
    end.

%% Rebuilding is the one refusal that is NOT a redirect: this node is the
%% leader, so there is nowhere better to send the station. But renewals are
%% still accepted, because they are a source of adoptions — that is how the
%% table fills up even if the rebuild query reaches nobody.
rebuilding_refuses_but_still_adopts(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        ?assertMatch({error, <<"r-1">>, rebuilding},
                     vs_coord_srv:claim(<<"r-1">>, ?VEHICLE, ?USER, ?STATION_1, 3)),

        Now = vs_time:now_ms(),
        {renewed, Ok, [], _} =
            vs_coord_srv:renew(?STATION_1, [{<<"c-old">>, ?VEHICLE, 3, ?USER, Now - 60000}]),
        ?assertEqual([<<"c-old">>], Ok),
        ?assertEqual(1, length(vs_coord_srv:claims()),
                     "a renewal during the rebuild is adopted, not refused")
    end.

%%%===================================================================
%%% the rebuild
%%%===================================================================

%% The shape stations answer with (claim.md §3.4).
holds(VehicleId, UserId, ConnId, ClaimId, GrantedAt, ExpiresAt) ->
    {VehicleId, UserId, ConnId, ClaimId, GrantedAt, ExpiresAt}.

rebuild_adopts_what_the_stations_report(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        Pid = whereis(vs_coord_srv),
        Pid ! {rebuilt, [{?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-a">>, Now - 5000, Now + 60000)]},
                         {?STATION_2, [holds(99, 13, 7, <<"c-b">>, Now - 4000, Now + 60000)]}]},

        ?assertEqual(serving, sync(), "the rebuild is what turns a winner into a server"),
        ?assertEqual(2, length(vs_coord_srv:claims())),

        %% and the adopted claims protect their vehicles like any other
        ?assertMatch({error, <<"r-x">>, already_held},
                     vs_coord_srv:claim(<<"r-x">>, ?VEHICLE, ?USER, ?STATION_2, 2))
    end.

%% The point of asking the stations rather than starting fresh: an adopted
%% claim keeps the timestamp it was born with, so "oldest wins" still means
%% something afterwards, and the driver keeps the lease they were promised
%% instead of having it silently extended.
rebuild_preserves_the_original_timestamps(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        Granted = Now - 120000,
        Expires = Now + 30000,
        Pid = whereis(vs_coord_srv),
        Pid ! {rebuilt, [{?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-a">>, Granted, Expires)]}]},
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
rebuild_settles_a_conflict_by_oldest_wins(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        Pid = whereis(vs_coord_srv),
        Pid ! {rebuilt, [
            {?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-newer">>, Now - 10000, Now + 60000)]},
            {?STATION_2, [holds(?VEHICLE, ?USER, 7, <<"c-older">>, Now - 90000, Now + 60000)]}
        ]},
        ?assertEqual(serving, sync()),

        [Claim] = vs_coord_srv:claims(),
        ?assertEqual(<<"c-older">>, maps:get(claim_id, Claim), "the older claim wins"),
        ?assertEqual(?STATION_2, maps:get(station_id, Claim)),
        ?assertEqual(1, length(vs_coord_srv:claims()),
                     "one vehicle, one claim — P2 holds through the rebuild")
    end.

%% The answer can arrive after we have been deposed or have lost quorum.
%% Adopting then would rebuild a table this node has no right to serve from.
rebuild_answer_is_ignored_when_not_rebuilding(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        vs_coord_srv:suspend(),
        ?assertEqual(suspended, sync()),

        Now = vs_time:now_ms(),
        Pid = whereis(vs_coord_srv),
        Pid ! {rebuilt, [{?STATION_1, [holds(?VEHICLE, ?USER, 3, <<"c-a">>, Now, Now + 60000)]}]},

        ?assertEqual(suspended, sync(), "a late answer must not resurrect us"),
        ?assertEqual([], vs_coord_srv:claims())
    end.

%% One unusable entry from one station must not cost us the whole rebuild:
%% the alternative is a coordinator stuck in `rebuilding' for ever, refusing
%% every reservation in the network.
rebuild_survives_a_malformed_entry(_) ->
    fun() ->
        vs_coord_srv:become_leader(),
        ?assertEqual(rebuilding, sync()),

        Now = vs_time:now_ms(),
        Pid = whereis(vs_coord_srv),
        Pid ! {rebuilt, [{?STATION_1, [{garbage},
                                       holds(?VEHICLE, ?USER, 3, <<"c-a">>, Now, Now + 60000)]}]},

        ?assertEqual(serving, sync()),
        ?assertEqual(1, length(vs_coord_srv:claims()),
                     "the good claim is kept, the bad one dropped")
    end.
