%%%-------------------------------------------------------------------
%%% @doc Top of the coordinator supervision tree.
%%%
%%% M1 has two children. The election and quorum processes arrive with M3:
%%%
%%%   vs_coord_sup
%%%     ├── vs_coord_srv        claims, cluster map, node monitors
%%%     ├── vs_coord_bo         the JInterface push towards the back office
%%%     ├── vs_coord_election   (M3) bully
%%%     └── vs_coord_membership (M3) quorum
%%%
%%% `rest_for_one': `vs_coord_bo' publishes what `vs_coord_srv' holds, so if
%%% the server is restarted the bridge must be restarted after it — otherwise
%%% it would keep pushing a snapshot of a table that no longer exists. The
%%% reverse is not true, and a crash of the bridge leaves the claims alone.
%%%-------------------------------------------------------------------
-module(vs_coord_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy  => rest_for_one,
                 intensity => 5,
                 period    => 10},

    Children = [
        #{id       => vs_coord_srv,
          start    => {vs_coord_srv, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_coord_srv]},

        #{id       => vs_coord_bo,
          start    => {vs_coord_bo, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_coord_bo]}
    ],

    {ok, {SupFlags, Children}}.
