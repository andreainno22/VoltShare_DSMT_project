%%%-------------------------------------------------------------------
%%% @doc Application entry point for the station node.
%%%
%%% The two listeners are started **here**, after the supervision tree, and
%%% not as children of `vs_station_sup'. `cowboy:start_clear/3' hands the
%%% listener to ranch's own supervision tree; declaring it in our tree as
%%% well would give a supervisor that names a child it does not actually
%%% supervise — an ordering diagram that lies. The accepted consequence is
%%% that a listener crash is repaired by ranch rather than by us, which is
%%% the right way round: ranch knows how to bring back an acceptor pool, we
%%% do not.
%%%
%%% Two of them, since M2: the driver channel on `DRIVER_WS_PORT' (8080,
%%% ws-driver.md §1) and the charge point channel on `CP_WS_PORT' (8081,
%%% ws-chargepoint.md §1). They are separate ranch listeners with separate
%%% names and separate routers, not two routes on one port, because they
%%% are separate boundaries: the driver channel faces the public internet
%%% through a JWT, the charge point channel faces a site-local network with
%%% no authentication at all (§2). Two ports means the site link can be
%%% firewalled to the equipment VLAN without touching the public one.
%%%
%%% Order matters. The tree comes up first, so that a browser — or a charge
%%% point — connecting in the same millisecond as the boot finds a manager
%%% to subscribe to.
%%%-------------------------------------------------------------------
-module(vs_station_app).
-behaviour(application).

-export([start/2, stop/1]).

-define(DRIVER_LISTENER, vs_driver_listener).
-define(CP_LISTENER, vs_cp_listener).

start(_StartType, _StartArgs) ->
    StationId = vs_env:get_int("STATION_ID", 1),
    logger:notice("vs_station starting on ~p (station_id=~p)", [node(), StationId]),
    {ok, Sup} = vs_station_sup:start_link(),
    start_listener(?DRIVER_LISTENER, "DRIVER_WS_PORT", 8080,
                   "/ws/driver", vs_driver_ws,
                   "no page can reach it"),
    start_listener(?CP_LISTENER, "CP_WS_PORT", 8081,
                   "/ws/cp", vs_cp_ws,
                   "no charge point can reach it"),
    {ok, Sup}.

stop(_State) ->
    %% Both channels are told the station is going away before their
    %% listener stops, because after that there is nobody left to tell.
    %% The two messages differ in what the peer is expected to do with
    %% them: a page reconnects with backoff (ws-driver.md §3, close 1001),
    %% a charge point stops delivering power first (ws-chargepoint.md §5,
    %% `stop' with reason `station_shutdown') and then reconnects.
    lists:foreach(fun(Pid) -> Pid ! station_shutdown end,
                  live_connections(?DRIVER_LISTENER)),
    lists:foreach(fun(Pid) -> Pid ! station_shutdown end,
                  live_connections(?CP_LISTENER)),
    _ = cowboy:stop_listener(?DRIVER_LISTENER),
    _ = cowboy:stop_listener(?CP_LISTENER),
    ok.

%%%===================================================================
%%% the listeners — ws-driver.md §1/§10 and ws-chargepoint.md §1/§10
%%%===================================================================

start_listener(Name, PortVar, PortDefault, Path, Handler, Consequence) ->
    Port = vs_env:get_int(PortVar, PortDefault),
    Dispatch = cowboy_router:compile([{'_', [{Path, Handler, #{}}]}]),
    case cowboy:start_clear(Name, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} ->
            logger:notice("~p listening on port ~p at ~s", [Name, Port, Path]),
            ok;
        {error, Reason} ->
            %% Loud, but not fatal. A station whose port is taken must
            %% still charge the cars already plugged into it: the whole
            %% design says the station degrades rather than stops
            %% (ws-driver.md §7.6), and refusing to boot would take the
            %% connectors down with the web page. The same rule applies to
            %% the charge point port, with more force rather than less —
            %% the sessions already running are the thing being protected.
            logger:error("~p could NOT start on port ~p: ~p - this node will "
                         "keep its connectors but ~s", [Name, Port, Reason, Consequence]),
            ok
    end.

%% ranch owns the connection processes, so it is ranch that can list
%% them. An empty list when the listener never started is the normal
%% answer, not an error.
live_connections(Name) ->
    try ranch:procs(Name, connections)
    catch _:_ -> []
    end.
