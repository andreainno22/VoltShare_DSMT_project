%%%-------------------------------------------------------------------
%%% @doc Application entry point for the station node.
%%%
%%% The driver listener is started **here**, after the supervision tree,
%%% and not as a child of `vs_station_sup'. `cowboy:start_clear/3' hands
%%% the listener to ranch's own supervision tree; declaring it in our
%%% tree as well would give a supervisor that names a child it does not
%%% actually supervise — an ordering diagram that lies. The accepted
%%% consequence is that a listener crash is repaired by ranch rather than
%%% by us, which is the right way round: ranch knows how to bring back an
%%% acceptor pool, we do not.
%%%
%%% Order matters. The tree comes up first, so that a browser connecting
%%% in the same millisecond as the boot finds a manager to subscribe to.
%%%-------------------------------------------------------------------
-module(vs_station_app).
-behaviour(application).

-export([start/2, stop/1]).

-define(LISTENER, vs_driver_listener).

start(_StartType, _StartArgs) ->
    StationId = vs_env:get_int("STATION_ID", 1),
    logger:notice("vs_station starting on ~p (station_id=~p)", [node(), StationId]),
    {ok, Sup} = vs_station_sup:start_link(),
    start_driver_listener(),
    {ok, Sup}.

stop(_State) ->
    %% §3: the page is told the station is going away (1001) so it comes
    %% back with backoff instead of showing an error. Sent before the
    %% listener stops, because after that there is nobody left to tell.
    lists:foreach(fun(Pid) -> Pid ! station_shutdown end, live_connections()),
    _ = cowboy:stop_listener(?LISTENER),
    ok.

%%%===================================================================
%%% the driver listener — contracts/ws-driver.md §1 and §10
%%%===================================================================

start_driver_listener() ->
    Port = vs_env:get_int("DRIVER_WS_PORT", 8080),
    Dispatch = cowboy_router:compile([{'_', [{"/ws/driver", vs_driver_ws, #{}}]}]),
    case cowboy:start_clear(?LISTENER,
                            [{port, Port}],
                            #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} ->
            logger:notice("driver channel listening on port ~p at /ws/driver", [Port]),
            ok;
        {error, Reason} ->
            %% Loud, but not fatal. A station whose port is taken must
            %% still charge the cars already plugged into it: the whole
            %% design says the station degrades rather than stops
            %% (ws-driver.md §7.6), and refusing to boot would take the
            %% connectors down with the web page.
            logger:error("driver channel could NOT start on port ~p: ~p — "
                         "this node will charge but no page can reach it",
                         [Port, Reason]),
            ok
    end.

%% ranch owns the connection processes, so it is ranch that can list
%% them. An empty list when the listener never started is the normal
%% answer, not an error.
live_connections() ->
    try ranch:procs(?LISTENER, connections)
    catch _:_ -> []
    end.
