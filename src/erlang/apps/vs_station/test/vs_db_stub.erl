%%%-------------------------------------------------------------------
%%% @doc Database stand-in for the tests: keeps the rows in memory.
%%%
%%% Same interface as `vs_station_db', so the connector cannot tell the
%%% difference — and the assertions about *what* gets written stay valid
%%% when the real INSERT arrives in M2.
%%%-------------------------------------------------------------------
-module(vs_db_stub).

-export([insert_session/1, rows/0, reset/0, fail_next/0]).

-define(ROWS, {?MODULE, rows}).
-define(FAIL, {?MODULE, fail}).

reset() ->
    persistent_term:put(?ROWS, []),
    persistent_term:put(?FAIL, false).

rows() -> lists:reverse(persistent_term:get(?ROWS, [])).

%% Makes the next write fail, to check the connector frees itself anyway.
fail_next() -> persistent_term:put(?FAIL, true).

insert_session(Row) ->
    case persistent_term:get(?FAIL, false) of
        true ->
            persistent_term:put(?FAIL, false),
            {error, connection_lost};
        false ->
            persistent_term:put(?ROWS, [Row | persistent_term:get(?ROWS, [])]),
            ok
    end.
