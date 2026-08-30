%%%-------------------------------------------------------------------
%%% @doc The half of contracts/claim.md §4 that one VM cannot show.
%%%
%%% `vs_claim_client_tests' puts the mock coordinator on the test node
%%% itself, so `coord_nodes' is a one-element list and the mock answers
%%% under the contract's fixed name `vs_coord_srv'. Two coordinators
%%% cannot coexist that way — one registered name, one VM — and so
%%% everything about *more than one* coordinator was untested by
%%% construction rather than by oversight: the redirect of §4.2, the
%%% full pass, the adoption of a claim by a leader that did not grant it.
%%%
%%% Here two `peer' nodes (OTP 29's replacement for `slave') each run
%%% their own `vs_mock_coord' registered locally as `vs_coord_srv' —
%%% which is exactly the topology of the contract, and the reason a
%%% redirect can be a redirect instead of a fiction.
%%%
%%% Three things about the fixture are deliberate:
%%%
%%%   * **`code:add_paths' on the remote, not `-pa' in the args.** A peer
%%%     inherits no code path. Both work here (`-pa' needs 94 argv tokens
%%%     and 2839 characters, far under any Windows limit), but shipping
%%%     `code:get_path()' over the wire cannot outgrow a command line and
%%%     stays right if the build layout changes.
%%%
%%%   * **`peer:start_link', and the peers are started once per group.**
%%%     Two peers plus their mocks cost about half a second; per test it
%%%     would be four times that for nothing. The link is the safety
%%%     net: `peer:stop/1' in the cleanup is the ordinary path, and if
%%%     the group process dies instead, peer's control process dies with
%%%     it and the node halts itself — measured, not assumed.
%%%
%%%   * **The mocks are driven with `erpc', never through a new export.**
%%%     `vs_mock_coord:history/0' and friends call `gen_server:call' on
%%%     the *local* `vs_coord_srv', so running them ON the peer resolves
%%%     the name where the mock actually is. Nothing in `vs_mock_coord'
%%%     had to change, which keeps its other callers untouched.
%%%
%%% Every test is wrapped in an explicit `{timeout, ...}': P11 made the
%%% suite's total an assertion, and eunit's 5 s default cancels a slow
%%% test *and takes its count with it*, which reads as a broken suite.
%%%-------------------------------------------------------------------
-module(vs_claim_peer_tests).
-include_lib("eunit/include/eunit.hrl").

-define(USER, 12).
-define(VEHICLE, 88).
-define(CONN, 3).
-define(STATION, 1).

%%%===================================================================
%%% the fixture
%%%===================================================================

peer_pair_test_() ->
    {setup,
     fun start_peers/0,
     fun stop_peers/1,
     fun(Peers) ->
             [{"a not_serving redirect is followed exactly once",
               {timeout, 60, fun() -> redirect_is_followed_once(Peers) end}},
              {"a circular redirect ends the pass instead of going round",
               {timeout, 60, fun() -> circular_redirect_does_not_loop(Peers) end}},
              {"a renew adopted by a new leader carries the original granted_at",
               {timeout, 60, fun() -> renew_against_a_new_leader_keeps_granted_at(Peers) end}},
              {"who_do_you_hold from a node that is not the leader re-points it",
               {timeout, 60, fun() -> who_do_you_hold_from_a_non_leader(Peers) end}}]
     end}.

start_peers() ->
    {start_peer(), start_peer()}.

start_peer() ->
    {ok, Pid, Node} =
        peer:start_link(#{name => peer:random_name(),
                          %% The cookie is not inherited: without it the
                          %% peer comes up with a random one and every
                          %% remote name resolves to `nodedown'.
                          args => ["-setcookie", atom_to_list(erlang:get_cookie()),
                                   %% the mock is chatty on every grant, and a
                                   %% peer's output is forwarded to this node's
                                   %% stdout, where it would interleave with the
                                   %% summary line eunit_check.sh matches
                                   "-kernel", "logger_level", "error"]}),
    ok = erpc:call(Node, code, add_paths, [code:get_path()]),
    {ok, _} = start_mock(Node),
    {Pid, Node}.

%% Unlinked on purpose: the erpc worker that runs this is gone a
%% microsecond later, and a link would take the mock with it.
start_mock(Node) ->
    erpc:call(Node, gen_server, start, [{local, vs_coord_srv}, vs_mock_coord, [], []]).

stop_peers({{PidA, _}, {PidB, _}}) ->
    ok = peer:stop(PidA),
    ok = peer:stop(PidB),
    ok.

%%%===================================================================
%%% per test: a fresh client, two clean mocks
%%%===================================================================

client_opts(Nodes) ->
    #{station_id           => ?STATION,
      coord_nodes          => Nodes,
      %% P11's rule: a value the scheduler must never be able to trip.
      %% Every refusal here is an explicit reply or a `noproc' — nothing
      %% in this file is driven by the clock.
      timeout_ms           => 60000,
      %% Off by default, so a history holds claim traffic and nothing
      %% else; the one test that needs the loop turns it back on.
      renew_interval_ms    => 60000,
      announce_interval_ms => 60000,
      station_info         => #{name             => <<"Peer Station">>,
                                ws_url           => <<"ws://test">>,
                                site_power_kw    => 350,
                                tariff_cents_kwh => 45}}.

with_client(Nodes, Extra, Fun) ->
    lists:foreach(fun reset_mock/1, Nodes),
    {ok, Client} = vs_claim_client:start_link(maps:merge(client_opts(Nodes), Extra)),
    try Fun() after
        unlink(Client),
        exit(Client, shutdown),
        wait_until(fun() -> whereis(vs_claim_client) =:= undefined end),
        flush()
    end.

%% One test stops a mock on purpose, so "reset" has to mean "there is a
%% clean mock there", not "the mock you left is empty".
reset_mock(Node) ->
    case erpc:call(Node, erlang, whereis, [vs_coord_srv]) of
        undefined ->
            {ok, _} = start_mock(Node),
            ok;
        Pid when is_pid(Pid) ->
            ok = erpc:call(Node, vs_mock_coord, reset, [])
    end.

%%%===================================================================
%%% talking to a mock that lives somewhere else
%%%===================================================================

history(Node)      -> erpc:call(Node, vs_mock_coord, history, []).
set_reply(Node, R) -> ok = erpc:call(Node, vs_mock_coord, set_reply, [R]).

claims(History) -> [M || M <- History, element(1, M) =:= claim].
renews(History) -> [M || M <- History, element(1, M) =:= renew].

acquire() -> vs_claim_client:acquire(?VEHICLE, ?USER, ?STATION, ?CONN).

%% The client's own idea of where it is pointing — read, never inferred.
leader() -> element(1, gen_server:call(vs_claim_client, get_route)).

%% §3.4 with the coordinator's own message. The third element is not
%% decoration: the client re-points its leader at whatever node the
%% asker declares, so a test that wants the leader left alone has to
%% name the node it is already on.
holds_from(CoordNode) ->
    vs_claim_client ! {who_do_you_hold, self(), CoordNode},
    receive_holds().

receive_holds() ->
    receive
        {holds, StationId, Holds} -> {StationId, Holds}
    after 5000 ->
        erlang:error(no_holds_reply)
    end.

%% P11: a bounded retry, not an assertion about time — it leaves at the
%% first truth and only a red run ever reaches the ceiling.
wait_until(F) -> wait_until(F, 300).

wait_until(_F, 0) -> erlang:error(timed_out_waiting);
wait_until(F, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

flush() -> receive _ -> flush() after 0 -> ok end.

%%%===================================================================
%%% 1. the redirect of §4.2, followed once
%%%===================================================================

%% A is not serving and names B; B grants. What is being measured is not
%% that the claim arrives — it is that B was asked ONCE. A redirect that
%% was retried, or a pass that reached B on its own after asking it
%% already, would look identical from the caller's side.
redirect_is_followed_once({{_, NodeA}, {_, NodeB}}) ->
    with_client([NodeA, NodeB], #{}, fun() ->
        set_reply(NodeA, {not_serving, NodeB}),
        {ok, ClaimId, _GrantedAt, ExpiresAt} = acquire(),
        ?assert(is_binary(ClaimId)),
        ?assert(ExpiresAt > vs_time:now_ms()),
        ?assertMatch([{claim, _, ?VEHICLE, ?USER, ?STATION, ?CONN}],
                     claims(history(NodeA))),
        ?assertMatch([{claim, _, ?VEHICLE, ?USER, ?STATION, ?CONN}],
                     claims(history(NodeB))),
        %% and the routing update the grant carries with it
        ?assertEqual(NodeB, leader())
    end).

%%%===================================================================
%%% 2. the redirect that points back — the `Followed' flag, first use
%%%===================================================================

%% A names B, B names A. `try_nodes/4' follows the first redirect with
%% `Followed = true', and from then on a `not_serving' means only "try
%% the next one" — and after the hop there is no next one. So: one
%% request on each side, `{error, no_claim}', and the leader left where
%% it was, because a refusal is not a routing fact.
circular_redirect_does_not_loop({{_, NodeA}, {_, NodeB}}) ->
    with_client([NodeA, NodeB], #{}, fun() ->
        set_reply(NodeA, {not_serving, NodeB}),
        set_reply(NodeB, {not_serving, NodeA}),
        ?assertEqual({error, no_claim}, acquire()),
        ?assertEqual(1, length(claims(history(NodeA)))),
        ?assertEqual(1, length(claims(history(NodeB)))),
        ?assertEqual(NodeA, leader()),
        ?assertEqual({?STATION, []}, holds_from(NodeA))
    end).

%%%===================================================================
%%% 3. adoption by a new leader — the "oldest wins" input (§5.5)
%%%===================================================================

%% A grants, A goes away, the renew tick finds B. The claim surviving is
%% the easy half; the half that matters is the `GrantedAt' B is handed.
%% If the station reinvented it on adoption, two stations arguing over
%% the same vehicle would be ordered by whichever failed over last
%% instead of by who asked first.
%%
%% Only the mock is stopped, not the node: the peers belong to the group
%% and the tests after this one still need them. `reset_mock/1' puts a
%% fresh one back before the next test runs.
renew_against_a_new_leader_keeps_granted_at({{_, NodeA}, {_, NodeB}}) ->
    with_client([NodeA, NodeB], #{renew_interval_ms => 100}, fun() ->
        {ok, ClaimId, GrantedAt, _ExpiresAt} = acquire(),
        ?assertEqual(NodeA, leader()),
        {?STATION, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, _}]} =
            holds_from(NodeA),
        %% A really was renewing it, with that timestamp
        ok = wait_until(fun() -> renews(history(NodeA)) =/= [] end),
        ?assertMatch([{renew, ?STATION,
                       [{ClaimId, ?VEHICLE, ?CONN, ?USER, GrantedAt}]} | _],
                     renews(history(NodeA))),
        %% ... and now it cannot answer at all
        ok = erpc:call(NodeA, gen_server, stop, [vs_coord_srv]),
        ok = wait_until(fun() -> renews(history(NodeB)) =/= [] end),
        [{renew, ?STATION, [{SeenId, ?VEHICLE, ?CONN, ?USER, SeenAt}]} | _] =
            renews(history(NodeB)),
        ?assertEqual(ClaimId, SeenId),
        %% the assertion this scenario exists for
        ?assertEqual(GrantedAt, SeenAt),
        %% the round that failed on A did not drop the claim (§5.4), and
        %% the round that succeeded on B moved the leader
        ?assertMatch({?STATION, [{?VEHICLE, ?USER, ?CONN, ClaimId, GrantedAt, _}]},
                     holds_from(NodeB)),
        ?assertEqual(NodeB, leader())
    end).

%%%===================================================================
%%% 4. who_do_you_hold from a node that is not the leader (§3.4)
%%%===================================================================

%% A freshly elected leader introducing itself. The answer is served
%% from memory, and the side effect is the point: the client re-points
%% its leader at the asker, so the next renew goes straight there
%% instead of paying a timeout on a node that has already lost.
%%
%% The message is sent FROM the peer — `erlang:send/2' runs on B — so
%% `CoordNode' is a node that really is not the current leader rather
%% than a label the test made up.
who_do_you_hold_from_a_non_leader({{_, NodeA}, {_, NodeB}}) ->
    with_client([NodeA, NodeB], #{}, fun() ->
        {ok, ClaimId, _GrantedAt, ExpiresAt} = acquire(),
        ?assertEqual(NodeA, leader()),
        Self = self(),
        _ = erpc:call(NodeB, erlang, send,
                      [{vs_claim_client, node()}, {who_do_you_hold, Self, NodeB}]),
        ?assertMatch({?STATION, [{?VEHICLE, ?USER, ?CONN, ClaimId, _, ExpiresAt}]},
                     receive_holds()),
        ?assertEqual(NodeB, leader())
    end).
