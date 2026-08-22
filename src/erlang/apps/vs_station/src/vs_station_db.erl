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
%%%-------------------------------------------------------------------
-module(vs_station_db).

-export([insert_session/1]).

-spec insert_session(map()) -> ok | {error, term()}.
insert_session(Row) ->
    logger:notice("session closed (not yet persisted): ~p", [Row]),
    ok.
