%%%-------------------------------------------------------------------
%%% @doc Top of the coordinator supervision tree.
%%%
%%% ```
%%%   vs_coord_sup
%%%     ├── vs_coord_srv        claims, cluster map, node monitors
%%%     ├── vs_coord_bo         the JInterface push towards the back office
%%%     ├── vs_coord_election   bully: who decides
%%%     └── vs_coord_membership liveness and quorum: who is up
%%% '''
%%%
%%% `rest_for_one', and the order above is the dependency order.
%%%
%%% `vs_coord_bo' publishes what `vs_coord_srv' holds, so if the server is
%%% restarted the bridge must be restarted after it — otherwise it would keep
%%% pushing a snapshot of a table that no longer exists.
%%%
%%% The election calls into `vs_coord_srv' (`become_leader', `suspend') and
%%% membership calls into the election, so both must start after what they
%%% drive and restart with it. Membership is last on purpose: its first
%%% heartbeat is what sets the whole thing in motion, and it must not fire at
%%% a process that is not there yet.
%%%
%%% A restarted election loses which node it believed to be leader, which is
%%% the right outcome — `rest_for_one' has just wiped the claim table below it,
%%% so a fresh election and a fresh rebuild are exactly what is needed.
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
          modules  => [vs_coord_bo]},

        #{id       => vs_coord_election,
          start    => {vs_coord_election, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_coord_election]},

        #{id       => vs_coord_membership,
          start    => {vs_coord_membership, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_coord_membership]}
    ],

    {ok, {SupFlags, Children}}.
