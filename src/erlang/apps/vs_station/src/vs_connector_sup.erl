%%%-------------------------------------------------------------------
%%% @doc Supervisor of the connector processes.
%%%
%%% `simple_one_for_one': every child is the same kind of process — a
%%% `vs_connector' — differing only in its start argument. Children are
%%% started dynamically by `vs_station_mgr' at boot, one per physical
%%% connector.
%%%
%%% `restart => transient': a connector that terminates normally is gone
%%% on purpose and must not come back; one that crashes is restarted with
%%% its original options and re-enters `free' — the safe state, because
%%% without a claim it grants nothing. The restarted process announces
%%% itself to the manager (see vs_connector init), which is how the
%%% registry heals without anyone polling.
%%%-------------------------------------------------------------------
-module(vs_connector_sup).
-behaviour(supervisor).

-export([start_link/0, start_connector/1, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start one connector. Opts as accepted by vs_connector:start_link/1.
-spec start_connector(map()) -> {ok, pid()} | {error, term()}.
start_connector(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).

init([]) ->
    SupFlags = #{strategy  => simple_one_for_one,
                 intensity => 5,
                 period    => 10},
    Child = #{id       => vs_connector,
              start    => {vs_connector, start_link, []},
              restart  => transient,
              shutdown => 5000,
              type     => worker,
              modules  => [vs_connector]},
    {ok, {SupFlags, [Child]}}.
