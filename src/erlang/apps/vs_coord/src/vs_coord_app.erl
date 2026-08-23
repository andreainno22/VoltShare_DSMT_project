%%%-------------------------------------------------------------------
%%% @doc Coordinator application.
%%%-------------------------------------------------------------------
-module(vs_coord_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    vs_coord_sup:start_link().

stop(_State) ->
    ok.
