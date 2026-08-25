%%%-------------------------------------------------------------------
%%% @doc Quorum arithmetic and the heartbeat that feeds it.
%%%
%%% The rule these tests protect is short and load-bearing: a coordinator may
%%% serve only while it can see a majority of the configured coordinators. It
%%% is what stops a network partition from producing two leaders that both
%%% grant the same vehicle, and it is the reason the system survives a split
%%% rather than merely surviving a crash.
%%%
%%% Real peers are not needed to check it. What is checked here is that the
%%% node counts itself, that it gives up on a silent peer after the configured
%%% number of missed beats rather than waiting for the distribution's own
%%% sixty-second tick, and that the majority threshold is computed over the
%%% *configured* list and never over whoever happens to be talking to us.
%%%-------------------------------------------------------------------
-module(vs_coord_membership_tests).

-include_lib("eunit/include/eunit.hrl").

%% Fast heartbeat so a test does not spend seconds waiting for a conclusion
%% that production reaches in three.
-define(BEAT_MS, 40).
-define(MISSES, 3).
%% Comfortably more than MISSES beats, so the verdict has certainly been taken.
-define(SETTLE_MS, ?BEAT_MS * (?MISSES + 3)).

setup(Peers) ->
    All = [atom_to_list(node()) | Peers],
    os:putenv("COORD_NODES", string:join(All, ",")),
    os:putenv("COORD_HEARTBEAT_MS", integer_to_list(?BEAT_MS)),
    os:putenv("COORD_HEARTBEAT_MISSES", integer_to_list(?MISSES)),
    {ok, Pid} = vs_coord_membership:start_link(),
    Pid.

cleanup(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> demonitor(Ref, [flush]), error(membership_did_not_stop)
    end,
    os:unsetenv("COORD_NODES"),
    os:unsetenv("COORD_HEARTBEAT_MS"),
    os:unsetenv("COORD_HEARTBEAT_MISSES").

with(Peers, Body) ->
    {setup, fun() -> setup(Peers) end, fun cleanup/1, Body}.

%%%===================================================================
%%% tests
%%%===================================================================

%% A lone coordinator is always in quorum: a majority of one is one. This is
%% M1, every unit test, and any compose where coord2/coord3 are still
%% commented out — none of them should be crippled by a rule meant for three.
alone_test_() ->
    with([], fun(_) ->
        [?_assertEqual(true, vs_coord_membership:in_quorum()),
         ?_assertEqual([node()], vs_coord_membership:alive()),
         ?_assertEqual([], vs_coord_membership:peers())]
    end).

%% Two unreachable peers out of three configured: one node out of three is not
%% a majority, so this coordinator must take itself out of service. This is the
%% minority side of a partition.
minority_loses_quorum_test_() ->
    with(["vs@absent1", "vs@absent2"], fun(_) ->
        {timeout, 10, fun() ->
            timer:sleep(?SETTLE_MS),
            ?assertEqual(false, vs_coord_membership:in_quorum(),
                         "1 of 3 is not a majority"),
            ?assertEqual([node()], vs_coord_membership:alive(),
                         "a peer that never beats is not alive")
        end}
    end).

%% The optimistic start. Assuming the peers are up until proven otherwise is
%% deliberate: on a cluster-wide restart every node comes up at the same
%% moment, and a pessimistic start would have all three declare themselves
%% alone and elect themselves simultaneously.
starts_optimistic_test_() ->
    with(["vs@absent1", "vs@absent2"], fun(_) ->
        [?_assertEqual(true, vs_coord_membership:in_quorum())]
    end).

%% A heartbeat from something that is not a configured coordinator must not
%% count. Quorum is a property of the configured cluster; letting a passing
%% station top up the count would let a minority talk itself back into service.
stranger_does_not_count_test_() ->
    with(["vs@absent1", "vs@absent2"], fun(_) ->
        {timeout, 10, fun() ->
            timer:sleep(?SETTLE_MS),
            ?assertEqual(false, vs_coord_membership:in_quorum()),

            vs_coord_membership ! {heartbeat, 'vs@some_station'},
            _ = vs_coord_membership:status(),

            ?assertEqual(false, vs_coord_membership:in_quorum(),
                         "an unconfigured node cannot restore quorum"),
            ?assertEqual([node()], vs_coord_membership:alive())
        end}
    end).

%% A peer that beats is alive, and two of three is a majority. The heartbeat is
%% injected directly: what is under test is the counting, not the transport.
one_live_peer_restores_quorum_test_() ->
    with(["vs@absent1", "vs@absent2"], fun(_) ->
        {timeout, 10, fun() ->
            timer:sleep(?SETTLE_MS),
            ?assertEqual(false, vs_coord_membership:in_quorum()),

            %% Beat as one of the configured peers would, faster than the miss
            %% window, and the verdict flips back.
            [begin
                 vs_coord_membership ! {heartbeat, 'vs@absent1'},
                 timer:sleep(?BEAT_MS)
             end || _ <- lists:seq(1, 3)],

            ?assertEqual(true, vs_coord_membership:in_quorum(),
                         "2 of 3 is a majority"),
            ?assert(lists:member('vs@absent1', vs_coord_membership:alive()))
        end}
    end).

%% The threshold itself, stated once so a change to it fails loudly.
majority_of_three_is_two_test_() ->
    with(["vs@absent1", "vs@absent2"], fun(_) ->
        [?_assertEqual(2, maps:get(needed, vs_coord_membership:status())),
         ?_assertEqual(3, length(maps:get(all, vs_coord_membership:status())))]
    end).
