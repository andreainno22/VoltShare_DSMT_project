%%%-------------------------------------------------------------------
%%% @doc Stand-in for the three collaborators of `vs_cp_proto': the
%%% connector (`conn_mod'), the manager (`mgr_mod') and the database
%%% (`db_mod').
%%%
%%% Same shape and the same reasons as `vs_driver_stub': one module for
%%% all three because the protocol talks to them in one breath, and
%%% `persistent_term' so a test arranges the world in one line.
%%%
%%% It records every call, which is what most of the charge point contract
%%% is actually about: `meter', `unplugged' and `status' produce **no
%%% frame at all** (§9's ladder), so the only way to show they were
%%% honoured is to look at what the connector was asked to do.
%%%-------------------------------------------------------------------
-module(vs_cp_stub).

%% arranging
-export([reset/0, set_connectors/1, set_plugged/1, set_snapshot/1, set_user/1,
         set_pid/1]).
%% inspecting
-export([calls/0, count/1, last/1]).
%% conn_mod
-export([attach_cp/2, plugged/2, meter/2, unplugged/2, cp_status/2, snapshot/1]).
%% mgr_mod
-export([lookup_pid/1]).
%% db_mod
-export([user_for_vehicle/1]).

-define(K(Name), {?MODULE, Name}).

reset() ->
    persistent_term:put(?K(calls), []),
    persistent_term:put(?K(connectors), [3]),
    persistent_term:put(?K(plugged), ok),
    persistent_term:put(?K(snapshot), free_snapshot()),
    persistent_term:put(?K(user), identity),
    persistent_term:put(?K(pid), self).

%% Ids this station owns. `manager_down' stands for the missing ETS table:
%% the real `lookup_pid/1' catches its own `badarg' there and answers
%% `no_manager', so this stub answers it directly (P10).
set_connectors(Ids)   -> persistent_term:put(?K(connectors), Ids).
%% Which pid the registry hands back. `self' — the default, and what every
%% test before the reattach wanted — is the calling process. A real pid is
%% how a test says "the connector came back as a NEW process", which is the
%% one thing the reattach of §6 has to be able to tell apart from "the
%% registry still names the one that just died". `undefined' is the third
%% thing a real row can hold: configured, but no process behind it right
%% now — the `no_pid' of P10.
set_pid(Pid)          -> persistent_term:put(?K(pid), Pid).
%% Reply :: ok | {error, Refusal} | unreachable
set_plugged(Reply)    -> persistent_term:put(?K(plugged), Reply).
set_snapshot(Map)     -> persistent_term:put(?K(snapshot), Map).
%% Reply :: identity | {ok, UserId} | {error, Reason} | raise
set_user(Reply)       -> persistent_term:put(?K(user), Reply).

calls() -> lists:reverse(persistent_term:get(?K(calls), [])).

count(Kind) ->
    length([C || C <- calls(), element(1, C) =:= Kind]).

%% The most recent call of a kind, or `undefined'. Most assertions here
%% are about the *arguments* of one call — what energy the connector was
%% handed, which user the vehicle resolved to.
last(Kind) ->
    case [C || C <- lists:reverse(calls()), element(1, C) =:= Kind] of
        [C | _] -> C;
        []      -> undefined
    end.

record(Call) ->
    persistent_term:put(?K(calls), [Call | persistent_term:get(?K(calls), [])]).

%%%===================================================================
%%% conn_mod
%%%===================================================================

%% Both pids are recorded, not just the socket's: since the reattach of §6
%% the question "which connector did it bind to" is the whole point, and a
%% call that only said "it bound to somebody" could not answer it.
attach_cp(Pid, CpPid) ->
    record({attach_cp, Pid, CpPid}),
    ok.

plugged(_Pid, Info) ->
    record({plugged, Info}),
    case persistent_term:get(?K(plugged), ok) of
        unreachable -> exit({noproc, {gen_statem, call, [fake_pid, plugged]}});
        Reply       -> Reply
    end.

meter(_Pid, Reading) ->
    record({meter, Reading}),
    ok.

unplugged(_Pid, EnergyKwh) ->
    record({unplugged, EnergyKwh}),
    ok.

cp_status(_Pid, Status) ->
    record({cp_status, Status}),
    ok.

snapshot(_Pid) ->
    record({snapshot}),
    persistent_term:get(?K(snapshot), free_snapshot()).

%%%===================================================================
%%% mgr_mod
%%%===================================================================

%% P10 — the three answers of `vs_station_mgr:lookup_pid/1', arranged with
%% the two knobs the stub already had, because the real registry has the
%% same two: which ids the table holds, and which pid the row carries.
%%
%%   set_connectors(manager_down)  ->  {error, no_manager}
%%   ConnId not in the list        ->  {error, unknown_connector}
%%   set_pid(undefined)            ->  {error, no_pid}
%%
%% `undefined' is not a stand-in here: it is exactly what the manager puts
%% in the row at init and puts back on the connector's `DOWN'.
lookup_pid(ConnId) ->
    record({lookup_pid, ConnId}),
    case persistent_term:get(?K(connectors), []) of
        manager_down ->
            {error, no_manager};
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

%%%===================================================================
%%% db_mod
%%%===================================================================

user_for_vehicle(VehicleId) ->
    record({user_for_vehicle, VehicleId}),
    case persistent_term:get(?K(user), identity) of
        identity -> {ok, VehicleId};      %% what the real stub does today
        raise    -> error(no_db);
        Reply    -> Reply
    end.

%%%===================================================================
%%% internal
%%%===================================================================

free_snapshot() ->
    #{connector_id => 3, rated_kw => 150, state => free,
      held_by => undefined, expires_at => undefined, power_kw => 0.0}.
