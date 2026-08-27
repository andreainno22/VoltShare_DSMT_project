%%%-------------------------------------------------------------------
%%% @doc Top of the station supervision tree.
%%%
%%% The tree as of M1 (start order matters: the manager boots the
%%% connectors, so their supervisor must already exist):
%%%
%%%   vs_station_sup
%%%     ├── vs_ping            (M0) connectivity probe; retired when the
%%%     │                            claim client takes over its job
%%%     ├── vs_connector_sup   simple_one_for_one, one child per connector
%%%     ├── vs_station_mgr     connector registry, aggregate state,
%%%     │                            power budget (value only until M2)
%%%     ├── vs_claim_client    the only process talking to the coordinator
%%%     └── vs_station_db      the only process talking to MySQL (M2 step 3)
%%%
%%% `one_for_one': the children are independent. A crash of the manager
%%% must not restart the connectors (it re-adopts them instead — see
%%% vs_station_mgr), and a crash of the claim client must not take down
%%% sessions in progress.
%%%
%%% `vs_station_db' is last, and being last costs nothing: it connects from
%%% a `handle_continue', so a database that is down delays no sibling, and
%%% the connectors above it only ever cast to it. The one thing its restart
%%% does cost is the rows still queued in it — the declared loss window,
%%% written up in scelte_di_progetto.md.
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
          modules  => [vs_ping]},

        #{id       => vs_connector_sup,
          start    => {vs_connector_sup, start_link, []},
          restart  => permanent,
          shutdown => infinity,        %% a supervisor is given time to stop its children
          type     => supervisor,
          modules  => [vs_connector_sup]},

        #{id       => vs_station_mgr,
          start    => {vs_station_mgr, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_station_mgr]},

        %% After the manager: its first announcement reads the connector
        %% list from the manager's table (dirty read, but the table must
        %% exist). Connectors only call it at reserve time, never at boot.
        #{id       => vs_claim_client,
          start    => {vs_claim_client, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_claim_client]},

        %% After the claim client: it is the one this calls once a row is
        %% written, and starting in this order means the wake-up towards
        %% Java never finds a mailbox that is not there yet.
        #{id       => vs_station_db,
          start    => {vs_station_db, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [vs_station_db]}
    ],

    {ok, {SupFlags, Children}}.
