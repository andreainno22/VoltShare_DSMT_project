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

-export([start_link/0, publish/1, announce_leader/0, standing_by/0,
         session_closed/1, penalty_event/1, notify/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(REPUBLISH_INTERVAL_MS, 30000).

-record(state, {mbox        :: atom(),
                java_node   :: node(),
                last        :: [tuple()],
                serving     :: boolean(),
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

%% @doc Tell the back office which node is serving, and start publishing.
%%
%% Called by vs_coord_srv when this node becomes the leader. Until then this
%% process stays silent — see {@link standing_by/0} for why that matters.
-spec announce_leader() -> ok.
announce_leader() ->
    gen_server:cast(?SERVER, announce_leader).

%% @doc Stop talking to the back office: this node is no longer the leader.
%%
%% This is not tidiness, it is a correctness fix that M3 made necessary. Every
%% coordinator runs this process, but a follower's station table is empty — it
%% never receives `station_up', because stations only announce to the leader.
%% If followers published on the same 30-second timer as the leader, each tick
%% would overwrite the back office's directory with an empty list and the lobby
%% would blink between the real stations and "no station is reporting".
%%
%% The same goes for the leader announcement: three coordinators announcing
%% themselves at boot would leave the back office pointing at whichever spoke
%% last, quite possibly a follower.
%%
%% So exactly one coordinator ever speaks to Java: the serving one.
-spec standing_by() -> ok.
standing_by() ->
    gen_server:cast(?SERVER, standing_by).

%% @doc Forward a station's `session_closed' event to Java.
%%
%% Sent as it arrives, with no bookkeeping: the back office treats this as a
%% wake-up rather than as data, because the session is already a row in MySQL.
%% If Tomcat is down the message is dropped and the sweep on the Java side
%% prices the session late — one interval of delay, no loss.
-spec session_closed(tuple()) -> ok.
session_closed(Event) ->
    gen_server:cast(?SERVER, {session_closed, Event}).

%% @doc Relay a `no_show' or `show_up' observed by a station (M4).
%%
%% Unlike the station list, this is **not** a snapshot: a lost `no_show' is a
%% strike that never gets counted, and no later message repairs it. So it is
%% worth one hop of effort to keep — vs_coord_srv routes it to the leader
%% instead of dropping it on a follower — but not more than that. Making the
%% cluster responsible for delivering it would put durable state back into a
%% process that any election can replace, and missing a strike only delays a
%% suspension rather than corrupting anything.
-spec penalty_event(tuple()) -> ok.
penalty_event(Event) ->
    gen_server:cast(?SERVER, {penalty_event, Event}).

%% @doc Relay a `{notify, UserId, Kind, Text}' a station wants the driver to
%% read next time they look (M4).
%%
%% Like `session_closed' and unlike the station list, this is not a snapshot:
%% nothing later repeats it. Unlike `session_closed', there is not even a row in
%% MySQL behind it — this message IS the notification. So it is never gated and
%% never dropped on purpose.
-spec notify(tuple()) -> ok.
notify(Event) ->
    gen_server:cast(?SERVER, {notify, Event}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Mbox = vs_env:get_atom("JINTERFACE_MBOX", backoffice),
    Java = vs_env:get_atom("JINTERFACE_NODE", 'voltshare_bo@backoffice'),
    erlang:send_after(?REPUBLISH_INTERVAL_MS, self(), republish),
    logger:notice("back office bridge: ready to publish to ~p on ~p", [Mbox, Java]),
    %% Silent until told we are the leader. A single-coordinator deployment
    %% gets that within milliseconds — vs_coord_srv announces itself on boot —
    %% so nothing is lost by waiting, and with three coordinators this is what
    %% keeps two of them from talking over the third.
    {ok, #state{mbox = Mbox, java_node = Java, last = [],
                serving = false, published = 0}}.

handle_call(status, _From, State) ->
    {reply, #{java_node => State#state.java_node,
              mbox      => State#state.mbox,
              serving   => State#state.serving,
              stations  => length(State#state.last),
              published => State#state.published}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({publish, Stations}, State = #state{serving = true}) ->
    {noreply, send_stations(Stations, State)};

handle_cast({publish, _Stations}, State) ->
    {noreply, State};

handle_cast(announce_leader, State) ->
    send(State, {leader, node()}),
    {noreply, State#state{serving = true}};

handle_cast(standing_by, State) ->
    %% `last' is cleared too: if this node is elected later it must publish
    %% what it has rebuilt, never a snapshot from a term it no longer holds.
    {noreply, State#state{serving = false, last = []}};

%% Not gated on `serving'. A station only ever sends this to the leader, but if
%% one arrives here during a handover it costs nothing to forward and the back
%% office treats it as a wake-up anyway — the session is already a row in
%% MySQL. Dropping it would delay a receipt for no reason.
handle_cast({session_closed, Event}, State) ->
    send(State, Event),
    {noreply, State};

%% No longer gated on `serving'. The gate was meant to stop one no-show being
%% counted twice, but a station casts to a single node, so there was never a
%% second copy to guard against — and vs_coord_srv now forwards to the leader
%% rather than letting a follower drop the event. What the gate actually did was
%% lose strikes in the window where a station still believed in the old leader.
%% Reported by A, R4 of the review of PR #5.
handle_cast({penalty_event, Event}, State) ->
    send(State, Event),
    {noreply, State};

%% A notification. Ungated for the stronger reason: a duplicate inserts one row
%% the driver reads once, while dropping one loses the only copy there is.
handle_cast({notify, Event}, State) ->
    send(State, Event),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Periodic resend, so a back office that started late, or missed a message,
%% converges without anybody having to ask. Followers stay quiet: their station
%% table is empty and republishing it would blank the lobby.
handle_info(republish, State = #state{serving = true}) ->
    erlang:send_after(?REPUBLISH_INTERVAL_MS, self(), republish),
    %% The leader announcement rides along with the station list.
    %%
    %% Without it, `{leader, _}' is sent exactly once, on winning an election. A back office
    %% that starts later never hears one and keeps addressing whichever node happens to be
    %% first in COORD_NODES — which is also the moment it would have pushed the suspensions.
    %% Both would then wait for the next election, which on a healthy cluster never comes.
    %%
    %% Repeating it every 30 s makes a restarted back office converge on its own, and costs
    %% one extra message per interval.
    send(State, {leader, node()}),
    {noreply, send_stations(State#state.last, State)};

handle_info(republish, State) ->
    erlang:send_after(?REPUBLISH_INTERVAL_MS, self(), republish),
    {noreply, State};

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
