%%%-------------------------------------------------------------------
%%% @doc Bully election: which coordinator decides.
%%%
%%% Answers <em>who decides</em>; {@link vs_coord_membership} answers who is up
%%% and pushes changes here.
%%%
%%% == Priority ==
%%%
%%% Bully needs a total order on the candidates, and every node must compute
%%% the same one. It is taken from the position of each node in the sorted
%%% `COORD_NODES' list, which all coordinators already share — the highest
%%% position wins.
%%%
%%% Deliberately not a per-node `COORD_ID' environment variable: that is one
%%% more thing to configure and, worse, one more thing to get wrong. Two nodes
%%% accidentally given the same id would both refuse to yield, and the symptom
%%% (an election that never settles) looks nothing like the cause. Derived from
%%% a list everyone already agrees on, disagreement is impossible.
%%%
%%% == The algorithm ==
%%%
%%% ```
%%%   start        -> tell everyone above me, wait for an answer
%%%   no answer    -> I win: announce to everyone
%%%   answer       -> someone above is alive; wait to be told who won
%%%   no leader    -> that one died too: start again
%%%   {leader, N}  -> N >= me: accept.  N < me: contest, it does not know I am here
%%% '''
%%%
%%% == Quorum comes first ==
%%%
%%% An election is only allowed while in quorum, and losing quorum abdicates
%%% immediately. This ordering is the whole point: in a partition the minority
%%% side is perfectly capable of running an election and electing itself, and
%%% would then be a second leader granting claims for the same vehicles. Being
%%% leader is necessary to serve, never sufficient — the coordinator also has
%%% to be able to see a majority (SCOPE §9).
%%%
%%% == Being elected is not being ready ==
%%%
%%% A fresh leader knows nothing about the claims its predecessor had granted,
%%% so it does not start serving on victory: it goes through
%%% {@link vs_coord_rebuild} first. Handing out claims before knowing which
%%% vehicles are already held would break P2 exactly when the system is
%%% supposed to be recovering.
%%%-------------------------------------------------------------------
-module(vs_coord_election).
-behaviour(gen_server).

-export([start_link/0, membership_changed/2, leader/0, status/0, force_election/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {self_node :: node(),
                self_rank :: pos_integer(),
                ranks     :: #{node() => pos_integer()},
                all       :: [node()],
                leader    :: node() | undefined,
                phase     :: idle | awaiting_answer | awaiting_leader,
                alive     :: [node()],
                quorum    :: boolean(),
                timer     :: reference() | undefined,
                wait_ms   :: pos_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Called by vs_coord_membership whenever liveness or quorum changes.
-spec membership_changed([node()], boolean()) -> ok.
membership_changed(Alive, InQuorum) ->
    gen_server:cast(?SERVER, {membership, Alive, InQuorum}).

-spec leader() -> node() | undefined.
leader() ->
    gen_server:call(?SERVER, leader).

-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

%% @doc For the shell and the tests: start an election regardless of state.
-spec force_election() -> ok.
force_election() ->
    gen_server:cast(?SERVER, force_election).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Self = node(),
    All = lists:usort([Self | vs_env:get_nodes("COORD_NODES", [Self])]),
    Ranks = ranks(All),
    Wait = vs_env:get_int("COORD_ELECTION_WAIT_MS", 800),

    State = #state{self_node = Self,
                   self_rank = maps:get(Self, Ranks),
                   ranks     = Ranks,
                   all       = All,
                   leader    = undefined,
                   phase     = idle,
                   alive     = All -- [Self],
                   quorum    = true,
                   wait_ms   = Wait},

    case length(All) of
        1 ->
            %% Single coordinator: no one to elect against, and no partition
            %% to be on the wrong side of. This is M1, the tests, and any
            %% deployment that has not enabled coord2/coord3 yet.
            logger:notice("election: single coordinator, serving without an election"),
            vs_coord_srv:become_leader(),
            {ok, State#state{leader = Self}};
        N ->
            logger:notice("election: ~p coordinators, this one ranks ~p",
                          [N, State#state.self_rank]),
            %% Give the peers a moment to come up before concluding they are
            %% absent — on a `docker compose up' all three start at once, and
            %% electing in the first millisecond just means electing again.
            {ok, arm(State, Wait, start)}
    end.

handle_call(leader, _From, State) ->
    {reply, State#state.leader, State};

handle_call(status, _From, State) ->
    {reply, #{node => State#state.self_node,
              rank => State#state.self_rank,
              leader => State#state.leader,
              phase => State#state.phase,
              quorum => State#state.quorum,
              alive => State#state.alive}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({membership, Alive, InQuorum}, State) ->
    {noreply, on_membership(Alive, InQuorum, State)};

handle_cast(force_election, State) ->
    {noreply, start_election(State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% --- the wire protocol -----------------------------------------------

%% Someone below me wants to be leader. Answer, so it stands down, and start
%% my own election — I may not be the highest one alive either.
handle_info({election, From}, State) ->
    case rank_of(From, State) of
        undefined ->
            {noreply, State};
        Rank when Rank < State#state.self_rank ->
            send(From, {answer, State#state.self_node}),
            {noreply, start_election(State)};
        _ ->
            %% From outranks us; it will announce itself shortly.
            {noreply, State}
    end;

handle_info({answer, From}, State) when State#state.phase =:= awaiting_answer ->
    logger:info("election: ~p is alive and outranks us, standing by", [From]),
    {noreply, arm(cancel(State#state{phase = awaiting_leader}),
                  State#state.wait_ms * 2, no_leader)};

handle_info({answer, _From}, State) ->
    {noreply, State};

handle_info({leader, Node}, State) ->
    case rank_of(Node, State) of
        undefined ->
            {noreply, State};
        Rank when Rank >= State#state.self_rank ->
            {noreply, accept_leader(Node, State)};
        _ ->
            %% A node below us claims the crown: it ran its election without
            %% hearing from us. Contest it rather than accept, or the cluster
            %% settles on the wrong leader and stays there.
            logger:info("election: ~p claims leadership but ranks below us", [Node]),
            {noreply, start_election(State)}
    end;

%% --- timers ----------------------------------------------------------

handle_info({timeout, Ref, start}, State = #state{timer = Ref}) ->
    {noreply, start_election(State#state{timer = undefined})};

%% Nobody above us answered: the crown is ours.
handle_info({timeout, Ref, no_answer}, State = #state{timer = Ref}) ->
    {noreply, win(State#state{timer = undefined})};

%% Someone answered but never announced a leader — it died mid-election.
handle_info({timeout, Ref, no_leader}, State = #state{timer = Ref}) ->
    logger:info("election: no leader announced, starting over"),
    {noreply, start_election(State#state{timer = undefined})};

handle_info({timeout, _Stale, _}, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% internal
%%%===================================================================

%% Position in the sorted list, 1-based. Same input on every node, same output.
ranks(All) ->
    maps:from_list(lists:zip(All, lists:seq(1, length(All)))).

rank_of(Node, #state{ranks = Ranks}) ->
    maps:get(Node, Ranks, undefined).

on_membership(Alive, InQuorum, State0) ->
    State = State0#state{alive = Alive, quorum = InQuorum},
    LeaderGone = State#state.leader =/= undefined
        andalso State#state.leader =/= State#state.self_node
        andalso not lists:member(State#state.leader, Alive),

    if
        not InQuorum ->
            abdicate(State);
        not State0#state.quorum andalso InQuorum ->
            logger:notice("election: quorum back, electing"),
            start_election(State);
        LeaderGone ->
            logger:notice("election: leader ~p is gone, electing", [State#state.leader]),
            start_election(State#state{leader = undefined});
        State#state.leader =:= undefined andalso State#state.phase =:= idle ->
            start_election(State);
        true ->
            State
    end.

%% Out of quorum: stop being the authority, whatever we thought we were. The
%% coordinator refuses everything until the majority is back.
abdicate(State) ->
    case State#state.leader of
        undefined -> ok;
        _         -> logger:warning("election: out of quorum, abdicating")
    end,
    vs_coord_srv:suspend(),
    cancel(State#state{leader = undefined, phase = idle}).

start_election(State = #state{quorum = false}) ->
    %% Refusing to even run is what keeps a minority partition from producing
    %% a second leader.
    abdicate(State);

start_election(State) ->
    Higher = [N || N <- State#state.alive, rank_of(N, State) > State#state.self_rank],
    case Higher of
        [] ->
            win(cancel(State));
        _ ->
            logger:info("election: asking ~p", [Higher]),
            [send(N, {election, State#state.self_node}) || N <- Higher],
            arm(cancel(State#state{phase = awaiting_answer}), State#state.wait_ms, no_answer)
    end.

win(State) ->
    Self = State#state.self_node,
    logger:notice("election: ~p is now the leader", [Self]),
    [send(N, {leader, Self}) || N <- State#state.all -- [Self]],
    %% Not `serving' yet: the new leader must first find out what the previous
    %% one had granted. vs_coord_srv drives that.
    vs_coord_srv:become_leader(),
    State#state{leader = Self, phase = idle}.

accept_leader(Node, State) ->
    case State#state.leader of
        Node -> cancel(State#state{phase = idle});
        _ ->
            logger:notice("election: following ~p", [Node]),
            vs_coord_srv:become_follower(Node),
            cancel(State#state{leader = Node, phase = idle})
    end.

arm(State, Ms, Msg) ->
    State#state{timer = erlang:start_timer(Ms, self(), Msg)}.

cancel(State = #state{timer = undefined}) ->
    State;
cancel(State = #state{timer = Ref}) ->
    _ = erlang:cancel_timer(Ref),
    State#state{timer = undefined}.

%% Never blocks, never fails on an unreachable node.
send(Node, Msg) ->
    {?SERVER, Node} ! Msg.
