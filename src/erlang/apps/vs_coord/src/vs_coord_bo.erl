%%%-------------------------------------------------------------------
%%% @doc The push towards the back office.
%%%
%%% Java joins the cluster as a hidden node and registers a mailbox called
%%% `backoffice'; this process sends the station list there whenever it
%%% changes, and at least every 30 seconds. Nothing is ever requested from
%%% Java — the back office only reads what it is told, which is what keeps a
%%% lobby refresh from reaching Erlang at all.
%%%
%%% Implements the Erlang side of contracts/erlang-java.md.
%%%
%%% Sending to a mailbox that is not there is not an error in Erlang: the
%%% message is silently dropped. That is the behaviour we want — Tomcat being
%%% down must not disturb the cluster — but it also means this process cannot
%%% tell whether anyone is listening, so it simply keeps publishing.
%%%-------------------------------------------------------------------
-module(vs_coord_bo).
-behaviour(gen_server).

-export([start_link/0, publish/1, announce_leader/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(REPUBLISH_INTERVAL_MS, 30000).

-record(state, {mbox        :: atom(),
                java_node   :: node(),
                last        :: [tuple()],
                published   :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Called by vs_coord_srv on every visible change. Asynchronous on
%% purpose: publishing must never slow down the decision of a claim.
-spec publish([tuple()]) -> ok.
publish(Stations) ->
    gen_server:cast(?SERVER, {publish, Stations}).

%% @doc Tell the back office which node is serving. In M1 that is always this
%% one; from M3 the newly elected leader calls it after winning.
-spec announce_leader() -> ok.
announce_leader() ->
    gen_server:cast(?SERVER, announce_leader).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Mbox = vs_env:get_atom("JINTERFACE_MBOX", backoffice),
    Java = vs_env:get_atom("JINTERFACE_NODE", 'voltshare_bo@backoffice'),
    erlang:send_after(?REPUBLISH_INTERVAL_MS, self(), republish),
    logger:notice("back office bridge: publishing to ~p on ~p", [Mbox, Java]),
    %% Announce straight away: if Tomcat is already up it learns the leader
    %% without waiting for the first station to appear.
    self() ! announce,
    {ok, #state{mbox = Mbox, java_node = Java, last = [], published = 0}}.

handle_call(status, _From, State) ->
    {reply, #{java_node => State#state.java_node,
              mbox      => State#state.mbox,
              stations  => length(State#state.last),
              published => State#state.published}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({publish, Stations}, State) ->
    {noreply, send_stations(Stations, State)};

handle_cast(announce_leader, State) ->
    send(State, {leader, node()}),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(announce, State) ->
    send(State, {leader, node()}),
    {noreply, State};

%% Periodic resend, so a back office that started late, or missed a message,
%% converges without anybody having to ask.
handle_info(republish, State) ->
    erlang:send_after(?REPUBLISH_INTERVAL_MS, self(), republish),
    {noreply, send_stations(State#state.last, State)};

handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% internal
%%%===================================================================

send_stations(Stations, State) ->
    send(State, {stations_update, Stations}),
    State#state{last = Stations, published = State#state.published + 1}.

%% `{RegisteredName, Node} ! Msg' does not fail when the node is unreachable,
%% so no guard is needed here — but it also gives no confirmation, which is
%% why the state counts what it sent rather than what arrived.
send(#state{mbox = Mbox, java_node = Java}, Message) ->
    {Mbox, Java} ! Message,
    ok.
