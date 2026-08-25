%%%-------------------------------------------------------------------
%%% @doc Which coordinators are alive, and whether we are in the majority.
%%%
%%% Answers one question — <em>who is up</em> — and leaves <em>who decides</em>
%%% to {@link vs_coord_election}. The split matters because the two answers
%%% change for different reasons: a node dying changes liveness, winning an
%%% election changes authority, and conflating them is how a coordinator ends
%%% up serving while isolated.
%%%
%%% == Why a heartbeat when Erlang already has monitor_nodes ==
%%%
%%% Both are used, because they detect different failures.
%%%
%%% `monitor_nodes' fires the instant a TCP connection breaks, which is what a
%%% killed container looks like — that is the demo case, and it is immediate.
%%% But a node that stops answering without closing its socket (a partition, a
%%% frozen VM) is only noticed by the distribution's own tick, whose default
%%% `net_ticktime' is 60 seconds. Sixty seconds of a minority leader still
%%% granting claims is exactly the failure this module exists to prevent.
%%%
%%% So liveness is decided by an explicit heartbeat: every node announces
%%% itself to its peers each second, and a peer that misses three in a row is
%%% treated as gone. Three seconds to detect a partition instead of sixty.
%%% `nodedown' is subscribed to as well, purely to react faster when it does
%%% fire — it can only ever confirm what the heartbeat would conclude later.
%%%
%%% == Quorum ==
%%%
%%% A coordinator may serve only while it can see a majority of the configured
%%% coordinators, itself included. With three nodes that means two. This is
%%% what stops a partition from producing two leaders that both grant the same
%%% vehicle: the minority side can still elect itself, but it cannot serve,
%%% and P2 survives the split (SCOPE §9).
%%%
%%% Note what this costs, and say it plainly in the report: during a partition
%%% the minority refuses **new reservations**. Charging sessions already in
%%% progress are untouched, because the coordinator is not in the path of
%%% delivering power — it only decides who may hold a vehicle.
%%%
%%% A single-node deployment (`COORD_NODES' with one entry, which is M1 and
%%% every test) is always in quorum: a majority of one is one.
%%%-------------------------------------------------------------------
-module(vs_coord_membership).
-behaviour(gen_server).

-export([start_link/0, alive/0, in_quorum/0, peers/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {self_node  :: node(),
                all        :: [node()],          %% every coordinator, self included
                peers      :: [node()],          %% everyone else
                misses     :: #{node() => non_neg_integer()},
                alive      :: [node()],          %% peers believed up
                quorum     :: boolean(),
                needed     :: pos_integer(),     %% votes for a majority
                interval   :: pos_integer(),
                tolerated  :: pos_integer()}).   %% missed beats before giving up

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Coordinator nodes currently believed up, this one included.
-spec alive() -> [node()].
alive() ->
    gen_server:call(?SERVER, alive).

-spec in_quorum() -> boolean().
in_quorum() ->
    gen_server:call(?SERVER, in_quorum).

-spec peers() -> [node()].
peers() ->
    gen_server:call(?SERVER, peers).

%% @doc Everything at once, for the shell and the tests.
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Self = node(),
    All = configured_nodes(Self),
    Peers = All -- [Self],
    Interval = vs_env:get_int("COORD_HEARTBEAT_MS", 1000),
    Tolerated = vs_env:get_int("COORD_HEARTBEAT_MISSES", 3),
    Needed = length(All) div 2 + 1,

    %% Instant notification when a connection drops; the heartbeat is what
    %% catches everything else.
    ok = net_kernel:monitor_nodes(true),
    erlang:send_after(Interval, self(), beat),

    %% Optimistic start: assume the peers are there and let the first missed
    %% beats prove otherwise. Starting pessimistic would mean every node
    %% believes itself alone for the first three seconds after a cluster-wide
    %% restart, and three coordinators would all elect themselves at once.
    State = #state{self_node = Self,
                   all       = All,
                   peers     = Peers,
                   misses    = maps:from_list([{P, 0} || P <- Peers]),
                   alive     = Peers,
                   quorum    = true,
                   needed    = Needed,
                   interval  = Interval,
                   tolerated = Tolerated},

    logger:notice("membership: ~p coordinator(s) configured, ~p needed for quorum",
                  [length(All), Needed]),
    {ok, State}.

handle_call(alive, _From, State) ->
    {reply, [State#state.self_node | State#state.alive], State};

handle_call(in_quorum, _From, State) ->
    {reply, State#state.quorum, State};

handle_call(peers, _From, State) ->
    {reply, State#state.peers, State};

handle_call(status, _From, State) ->
    {reply, #{self => State#state.self_node,
              all => State#state.all,
              alive => [State#state.self_node | State#state.alive],
              quorum => State#state.quorum,
              needed => State#state.needed}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% A peer announcing itself. Resetting the counter is the whole protocol.
handle_info({heartbeat, From}, State) ->
    case lists:member(From, State#state.peers) of
        false ->
            %% Not one of ours — a station, or a stale node name. Ignored
            %% rather than trusted: quorum is counted over the configured
            %% list, never over whoever happens to be talking to us.
            {noreply, State};
        true ->
            Misses = maps:put(From, 0, State#state.misses),
            {noreply, recount(State#state{misses = Misses})}
    end;

handle_info(beat, State) ->
    announce(State),
    Misses = maps:map(fun(_, N) -> N + 1 end, State#state.misses),
    erlang:send_after(State#state.interval, self(), beat),
    {noreply, recount(State#state{misses = Misses})};

%% Confirmation, not discovery: the heartbeat would reach the same conclusion
%% a moment later. Jumping the counter here only makes the reaction quicker.
handle_info({nodedown, Node}, State) ->
    case lists:member(Node, State#state.peers) of
        false -> {noreply, State};
        true ->
            logger:notice("membership: ~p went down", [Node]),
            Misses = maps:put(Node, State#state.tolerated, State#state.misses),
            {noreply, recount(State#state{misses = Misses})}
    end;

handle_info({nodeup, Node}, State) ->
    case lists:member(Node, State#state.peers) of
        false -> {noreply, State};
        true ->
            %% Do not declare it alive yet — a connection is not a working
            %% coordinator. Its first heartbeat is what counts.
            logger:info("membership: ~p is reachable again", [Node]),
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% internal
%%%===================================================================

configured_nodes(Self) ->
    Configured = vs_env:get_nodes("COORD_NODES", [Self]),
    %% Self must be in the list even if the environment forgot it, or the
    %% quorum arithmetic would be counting a different cluster than the one
    %% this node belongs to.
    lists:usort([Self | Configured]).

announce(#state{peers = Peers, self_node = Self}) ->
    Beat = {heartbeat, Self},
    %% `{Name, Node} ! Msg' never blocks and never fails on an unreachable
    %% node, so no peer can slow this tick down.
    [{?SERVER, P} ! Beat || P <- Peers],
    ok.

%% Recompute who is alive and whether that is a majority; report only changes.
recount(State) ->
    Alive = [P || P <- State#state.peers,
                  maps:get(P, State#state.misses, 0) < State#state.tolerated],
    Quorum = (length(Alive) + 1) >= State#state.needed,

    case {Alive =:= State#state.alive, Quorum =:= State#state.quorum} of
        {true, true} ->
            State;
        _ ->
            case Quorum =/= State#state.quorum of
                true when Quorum ->
                    logger:notice("membership: quorum regained (~p of ~p)",
                                  [length(Alive) + 1, length(State#state.all)]);
                true ->
                    logger:warning("membership: QUORUM LOST (~p of ~p) — "
                                   "this coordinator will refuse to serve",
                                   [length(Alive) + 1, length(State#state.all)]);
                false ->
                    logger:info("membership: alive peers now ~p", [Alive])
            end,
            vs_coord_election:membership_changed(Alive, Quorum),
            State#state{alive = Alive, quorum = Quorum}
    end.
