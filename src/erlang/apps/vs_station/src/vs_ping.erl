%%%-------------------------------------------------------------------
%%% @doc M0 connectivity probe — the "two Erlang nodes exchanging a
%%% message" smoke test.
%%%
%%% It is deliberately shaped like `vs_claim_client', the module that will
%%% replace it in M1: a `gen_server' that owns the link to a remote node,
%%% probes it from a throw-away process with an explicit timeout, and
%%% re-arms a periodic tick with `erlang:send_after/3'. The server itself
%%% never blocks on the remote node — see scelte_di_progetto.md §"Chiamate
%%% remote". What it proves is exactly what the deployment
%%% risks (piano §10): node naming, cookie, and DNS between containers.
%%%
%%% Server side  — answers `ping' from anyone.
%%% Client side  — if PING_TARGET is set, calls that node every
%%%                PING_INTERVAL_MS and logs the outcome.
%%%
%%% Read the log with: docker compose logs -f station1
%%%-------------------------------------------------------------------
-module(vs_ping).
-behaviour(gen_server).

%% API
-export([start_link/0, ping/1, status/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-record(state, {target             :: node() | undefined,
                interval_ms        :: pos_integer(),
                timeout_ms         :: pos_integer(),
                sent    = 0        :: non_neg_integer(),
                ok      = 0        :: non_neg_integer(),
                failed  = 0        :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc One-shot ping of a remote node, usable from the shell:
%%      vs_ping:ping('vs@station2').
-spec ping(node()) -> {pong, node()} | {error, term()}.
ping(Node) ->
    call_remote(Node, 2000).

%% @doc Counters, for the smoke test and for eyeballing a live node.
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    Target   = case vs_env:get_atom("PING_TARGET", undefined) of
                   undefined -> undefined;
                   Node      -> Node
               end,
    Interval = vs_env:get_int("PING_INTERVAL_MS", 3000),
    Timeout  = vs_env:get_int("PING_TIMEOUT_MS", 2000),

    case Target of
        undefined ->
            logger:notice("vs_ping ready on ~p (answering only)", [node()]);
        _ ->
            logger:notice("vs_ping ready on ~p, pinging ~p every ~p ms",
                          [node(), Target, Interval]),
            erlang:send_after(Interval, self(), tick)
    end,

    {ok, #state{target = Target, interval_ms = Interval, timeout_ms = Timeout}}.

%% --- server side: this is what a remote node reaches -----------------
handle_call(ping, _From, State) ->
    {reply, {pong, node()}, State};

handle_call(status, _From, State = #state{}) ->
    Reply = #{node    => node(),
              target  => State#state.target,
              sent    => State#state.sent,
              ok      => State#state.ok,
              failed  => State#state.failed},
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% --- client side: periodic probe ------------------------------------
handle_info(tick, State = #state{target = Target, timeout_ms = Timeout}) ->
    %% The probe runs in a throw-away process, NOT here. A gen_server is a
    %% single process: while it sits inside handle_info it cannot serve
    %% handle_call. Two stations probing each other on the same tick would
    %% each block waiting for a reply the other cannot give until it has
    %% itself timed out — a mutual deadlock that is stable, because both
    %% sides then re-arm in lockstep. Delegating keeps the server free to
    %% answer while its own probe is in flight.
    Self = self(),
    spawn(fun() -> Self ! {ping_result, call_remote(Target, Timeout)} end),
    erlang:send_after(State#state.interval_ms, self(), tick),
    {noreply, State#state{sent = State#state.sent + 1}};

handle_info({ping_result, {pong, Remote}}, State) ->
    logger:notice("ping ~p -> pong from ~p", [State#state.target, Remote]),
    {noreply, State#state{ok = State#state.ok + 1}};

handle_info({ping_result, {error, Reason}}, State) ->
    %% A dead coordinator must never stop the station: log and keep
    %% ticking. This is the failure mode M3 builds on.
    logger:warning("ping ~p failed: ~p", [State#state.target, Reason]),
    {noreply, State#state{failed = State#state.failed + 1}};

handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% internal
%%%===================================================================

%% A remote gen_server:call/3 raises on timeout or on a missing process,
%% so it is wrapped: the caller gets a value, never an exception.
call_remote(undefined, _Timeout) ->
    {error, no_target};
call_remote(Node, Timeout) ->
    try
        gen_server:call({?SERVER, Node}, ping, Timeout)
    catch
        exit:{timeout, _}          -> {error, timeout};
        exit:{noproc, _}           -> {error, noproc};
        exit:{{nodedown, _}, _}    -> {error, nodedown};
        Class:Reason               -> {error, {Class, Reason}}
    end.
