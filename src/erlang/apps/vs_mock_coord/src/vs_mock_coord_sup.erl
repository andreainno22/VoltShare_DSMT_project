%%%-------------------------------------------------------------------
%%% @doc Supervisor of the mock coordinator: one child.
%%%-------------------------------------------------------------------
-module(vs_mock_coord_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{id       => vs_mock_coord,
          start    => {vs_mock_coord, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_mock_coord]}
    ],
    {ok, {SupFlags, Children}}.
