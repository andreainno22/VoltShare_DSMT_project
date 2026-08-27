%%%-------------------------------------------------------------------
%%% @doc Durable state written by the station.
%%%
%%% The station owns exactly one table — `sessions' — and touches it once
%%% per session, at the end (schema.sql, ownership rules). Cost is left
%%% NULL: billing is the back office's, and it runs after the fact on
%%% purpose, so that money is never a contended resource.
%%%
%%% M1 logs the row. M2 replaces the body with an INSERT over a
%%% `mysql-otp' pool; the interface does not change, which is why the
%%% connector already depends on it.
%%%
%%% `user_for_vehicle/1' is the second read this module will own. It is
%%% here rather than at the coordinator on purpose (D1): `vehicles' is a
%%% back office table the coordinator does not hold, and the walk-in path
%%% has to work while the site is cut off from everything else — station
%%% autonomy, SCOPE §4. Asking a coordinator for it would put a remote
%%% call in the one path that must survive without one.
%%%-------------------------------------------------------------------
-module(vs_station_db).

-export([insert_session/1, user_for_vehicle/1]).

-spec insert_session(map()) -> ok | {error, term()}.
insert_session(Row) ->
    logger:notice("session closed (not yet persisted): ~p", [Row]),
    ok.

%% @doc The account a vehicle belongs to (ws-chargepoint.md §4.2 — the
%% charge point identifies the car, the station bills the person).
%%
%% **A stub, and it says so in the log.** The mapping is 1:1 in the schema
%% (`vehicles.user_id' is unique), so the identity answer is well-formed
%% and lets the whole `plugged' path be exercised end to end; it is simply
%% not the truth for any seed row where the two ids differ. M2 step 3
%% replaces the body with `SELECT user_id FROM vehicles WHERE id = ?' and
%% this interface does not change.
-spec user_for_vehicle(pos_integer()) -> {ok, pos_integer()} | {error, term()}.
user_for_vehicle(VehicleId) ->
    logger:notice("vehicle ~p resolved to user ~p by the identity STUB "
                  "(no vehicles table yet: M2 step 3 replaces this with a SELECT)",
                  [VehicleId, VehicleId]),
    {ok, VehicleId}.
