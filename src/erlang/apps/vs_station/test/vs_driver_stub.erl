%%%-------------------------------------------------------------------
%%% @doc Stand-in for the three collaborators of `vs_driver_proto':
%%% the connector (`conn_mod'), the manager (`mgr_mod') and the claim
%%% client (`claim_mod').
%%%
%%% One module for all three because the protocol talks to them in one
%%% breath and a test wants one place to arrange the world. Same
%%% `persistent_term' style as vs_claim_stub and vs_db_stub.
%%%
%%% It counts calls, which is the point: the at-most-once rule of §7.2
%%% cannot be demonstrated by looking at the replies — a cached reply and
%%% a freshly executed one are identical by definition. The only visible
%%% difference is whether the connector was asked a second time.
%%%-------------------------------------------------------------------
-module(vs_driver_stub).

%% arranging
-export([reset/0, set_reserve/1, set_cancel/1, set_stop/1,
         set_connectors/1, set_pid/1, set_state/1, set_reachable/1]).
%% inspecting
-export([calls/0, count/1]).
%% conn_mod
-export([reserve/3, cancel/2, stop_session/2]).
%% mgr_mod
-export([connector_pid/1, station_state/0]).
%% claim_mod
-export([coordinator_reachable/0]).

-define(K(Name), {?MODULE, Name}).

reset() ->
    persistent_term:put(?K(calls), []),
    persistent_term:put(?K(reserve), {ok, 1755792000000}),
    persistent_term:put(?K(cancel), ok),
    persistent_term:put(?K(stop), ok),
    persistent_term:put(?K(connectors), [1, 2, 3, 4]),
    persistent_term:put(?K(pid), self),
    persistent_term:put(?K(state), default_state()),
    persistent_term:put(?K(reachable), true).

%% Reply :: {ok, ExpiresAt} | {error, Refusal} | timeout | manager_down
set_reserve(Reply)     -> persistent_term:put(?K(reserve), Reply).
set_cancel(Reply)      -> persistent_term:put(?K(cancel), Reply).
set_stop(Reply)        -> persistent_term:put(?K(stop), Reply).
set_connectors(Ids)    -> persistent_term:put(?K(connectors), Ids).
%% Which pid the row carries (P13). `self' — the default, and what every
%% test before this one wanted — is the calling process. `undefined' is
%% the third thing a real row can hold: configured, but no process behind
%% it right now, which is exactly what the manager writes into the row on
%% the connector's `DOWN' and leaves there until the supervisor is done.
set_pid(Pid)           -> persistent_term:put(?K(pid), Pid).
set_state(Map)         -> persistent_term:put(?K(state), Map).
set_reachable(Bool)    -> persistent_term:put(?K(reachable), Bool).

calls() -> lists:reverse(persistent_term:get(?K(calls), [])).

%% How many times a given kind of call was made — `count(reserve)'.
count(Kind) ->
    length([C || C <- calls(), element(1, C) =:= Kind]).

record(Call) ->
    persistent_term:put(?K(calls), [Call | persistent_term:get(?K(calls), [])]).

%%%===================================================================
%%% conn_mod
%%%===================================================================

reserve(_Pid, UserId, VehicleId) ->
    record({reserve, UserId, VehicleId}),
    answer(persistent_term:get(?K(reserve), {ok, 1755792000000})).

cancel(_Pid, UserId) ->
    record({cancel, UserId}),
    answer(persistent_term:get(?K(cancel), ok)).

stop_session(_Pid, UserId) ->
    record({stop_session, UserId}),
    answer(persistent_term:get(?K(stop), ok)).

%% `timeout' reproduces exactly what a `gen_statem:call/2' raises when the
%% callee takes longer than its implicit 5 s — the case that would kill
%% the WebSocket process if the protocol did not catch it.
answer(timeout) -> exit({timeout, {gen_statem, call, [fake_pid, reserve]}});
answer(Reply)   -> Reply.

%%%===================================================================
%%% mgr_mod
%%%===================================================================

%% P13 — the three answers of `vs_station_mgr:connector_pid/1', arranged
%% with the two knobs the real registry has: which ids the table holds,
%% and which pid the row carries.
%%
%%   set_connectors(manager_down)  ->  an exit, and the protocol's own
%%                                     wrapper makes it `no_manager'
%%   ConnId not in the list        ->  {error, unknown_connector}
%%   set_pid(undefined)            ->  {error, no_pid}
%%
%% Three and not four, unlike vs_cp_stub: `connector_pid/1' is a *call*,
%% so "the manager is not up" is not one of its replies — it is the exit
%% below, which is what a call to an unregistered name really raises.
connector_pid(ConnId) ->
    record({connector_pid, ConnId}),
    case persistent_term:get(?K(connectors), []) of
        manager_down ->
            %% What `gen_server:call' raises against a dead registered name.
            exit({noproc, {gen_server, call, [vs_station_mgr, {connector_pid, ConnId}]}});
        Ids ->
            case lists:member(ConnId, Ids) of
                true  -> case registered_pid() of
                             undefined -> {error, no_pid};
                             Pid       -> {ok, Pid}
                         end;
                false -> {error, unknown_connector}
            end
    end.

registered_pid() ->
    case persistent_term:get(?K(pid), self) of
        self -> self();
        Pid  -> Pid
    end.

station_state() ->
    record({station_state}),
    case persistent_term:get(?K(state), default_state()) of
        manager_down -> exit({noproc, {gen_server, call, [vs_station_mgr, station_state]}});
        Map          -> Map
    end.

%%%===================================================================
%%% claim_mod
%%%===================================================================

coordinator_reachable() ->
    persistent_term:get(?K(reachable), true).

%%%===================================================================
%%% internal
%%%===================================================================

%% The shape `vs_station_mgr:build_state/1' produces after the M1 step 3
%% additions: four free connectors, station 1.
default_state() ->
    #{station_id       => 1,
      name             => <<"Pisa Centro">>,
      site_power_kw    => 350,
      allocated_kw     => 0,
      tariff_cents_kwh => 45,
      connectors       => [free_connector(Id, Kw)
                           || {Id, Kw} <- [{1, 150}, {2, 150}, {3, 150}, {4, 50}]]}.

free_connector(Id, Kw) ->
    #{connector_id => Id, rated_kw => Kw, state => free,
      held_by => undefined, expires_at => undefined, power_kw => 0.0}.
