%%%-------------------------------------------------------------------
%%% @doc Application entry point for the station node.
%%%-------------------------------------------------------------------
-module(vs_station_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    logger:notice("vs_station starting on ~p (station_id=~p)",
                  [node(), vs_env:get_int("STATION_ID", 1)]),
    vs_station_sup:start_link().

stop(_State) ->
    ok.
