%%%-------------------------------------------------------------------
%%% @doc Database stand-in for the tests: keeps the rows in memory.
%%%
%%% Same interface as `vs_station_db', so the connector cannot tell the
%%% difference — and the assertions about *what* gets written stay valid
%%% now that the real INSERT has arrived.
%%%
%%% Since M2 step 3 `insert_session/1' is a cast and always answers `ok':
%%% there is no failure for the caller to see any more, because the
%%% failure — and the retry, and the queue — belong to the process behind
%%% it. `fail_next/0' therefore no longer makes the *call* fail; it makes
%%% the write disappear, which is what a real queued row that never
%%% reaches MySQL looks like from the connector's side: nothing.
%%%-------------------------------------------------------------------
-module(vs_db_stub).

-export([insert_session/1, user_for_vehicle/1, rows/0, reset/0, fail_next/0]).

-define(ROWS, {?MODULE, rows}).
-define(FAIL, {?MODULE, fail}).

reset() ->
    persistent_term:put(?ROWS, []),
    persistent_term:put(?FAIL, false).

rows() -> lists:reverse(persistent_term:get(?ROWS, [])).

%% Makes the next write vanish, to check the connector frees itself anyway.
%% A dropped row is exactly what the real module's queue cap does when the
%% database has been unreachable for long enough.
fail_next() -> persistent_term:put(?FAIL, true).

insert_session(Row) ->
    case persistent_term:get(?FAIL, false) of
        true ->
            persistent_term:put(?FAIL, false);
        false ->
            persistent_term:put(?ROWS, [Row | persistent_term:get(?ROWS, [])])
    end,
    ok.

%% The identity answer the real module used to give. Kept so that the
%% tests injecting this module as `db_mod' can still walk the `plugged'
%% path without a `vehicles' table.
user_for_vehicle(VehicleId) -> {ok, VehicleId}.
