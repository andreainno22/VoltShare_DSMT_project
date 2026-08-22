%%%-------------------------------------------------------------------
%%% @doc Top of the station supervision tree.
%%%
%%% M0 supervises only `vs_ping', the connectivity probe. The real
%%% children arrive with the milestones and the tree becomes:
%%%
%%%   vs_station_sup
%%%     ├── vs_station_mgr     (M1) power budget, connector registry
%%%     ├── vs_claim_client    (M1) the only process talking to the coordinator
%%%     ├── vs_station_db      (M2) sessions INSERT
%%%     └── vs_connector_sup   (M1) simple_one_for_one, one child per connector
%%%
%%% `one_for_one': the connectors are independent of each other, and a
%%% crash of the claim client must not take down sessions in progress.
%%%-------------------------------------------------------------------
-module(vs_station_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy  => one_for_one,
                 intensity => 5,       %% at most 5 restarts
                 period    => 10},     %% in 10 seconds, else the node gives up

    Children = [
        #{id       => vs_ping,
          start    => {vs_ping, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_ping]}
    ],

    {ok, {SupFlags, Children}}.
