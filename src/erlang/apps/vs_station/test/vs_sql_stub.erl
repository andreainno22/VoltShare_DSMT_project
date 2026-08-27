%%%-------------------------------------------------------------------
%%% @doc mysql-otp stand-in for the tests (`sql_mod').
%%%
%%% The half of `vs_station_db' worth testing is what it does when the
%%% database is *not* cooperating, and a real MySQL cannot be asked to
%%% refuse a row or to drop a connection on cue. This module can:
%%%
%%%   `ok'        the INSERT succeeds and hands back an id
%%%   `refuse'    the server answers with an error — a bad row, which
%%%               will still be bad next time
%%%   `raise'     the call blows up — the connection is gone and the row
%%%               never arrived
%%%
%%% The connection it hands out is a real process, because the writer
%%% links to it and has to notice when it dies.
%%%-------------------------------------------------------------------
-module(vs_sql_stub).

-export([start_link/1, query/4, insert_id/1]).
-export([reset/0, set_mode/1, set_connect/1, set_vehicle/1,
         queries/0, last_insert_id/0]).

-define(MODE,    {?MODULE, mode}).
-define(CONNECT, {?MODULE, connect}).
-define(VEHICLE, {?MODULE, vehicle}).
-define(QUERIES, {?MODULE, queries}).
-define(NEXT_ID, {?MODULE, next_id}).

reset() ->
    persistent_term:put(?MODE, ok),
    persistent_term:put(?CONNECT, ok),
    persistent_term:put(?VEHICLE, {ok, 2}),
    persistent_term:put(?QUERIES, []),
    persistent_term:put(?NEXT_ID, 1000).

%% ok | refuse | raise
set_mode(Mode)       -> persistent_term:put(?MODE, Mode).
%% ok | refuse | raise — what start_link/1 does
set_connect(What)    -> persistent_term:put(?CONNECT, What).
%% what the vehicles SELECT answers
set_vehicle(Reply)   -> persistent_term:put(?VEHICLE, Reply).

queries()            -> lists:reverse(persistent_term:get(?QUERIES, [])).
last_insert_id()     -> persistent_term:get(?NEXT_ID, 1000).

start_link(_Opts) ->
    case persistent_term:get(?CONNECT, ok) of
        ok     -> {ok, spawn_link(fun idle/0)};
        refuse -> {error, econnrefused};
        raise  -> error(no_database)
    end.

%% A connection is a process and nothing more: the writer never sends it
%% anything directly, it only needs it to be alive or not.
idle() ->
    receive _ -> idle() end.

query(_Conn, Sql, Params, _Timeout) ->
    record({Sql, Params}),
    case lists:prefix("SELECT", Sql) of
        true  -> vehicle_reply();
        false -> insert_reply()
    end.

insert_reply() ->
    case persistent_term:get(?MODE, ok) of
        ok ->
            persistent_term:put(?NEXT_ID, persistent_term:get(?NEXT_ID, 1000) + 1),
            ok;
        refuse ->
            %% the shape mysql-otp gives a server-side error
            {error, {1452, <<"23000">>, <<"Cannot add or update a child row">>}};
        raise ->
            exit({noproc, {gen_server, call, []}})
    end.

vehicle_reply() ->
    case persistent_term:get(?VEHICLE, {ok, 2}) of
        {ok, UserId} -> {ok, [<<"user_id">>], [[UserId]]};
        empty        -> {ok, [<<"user_id">>], []};
        raise        -> exit({noproc, {gen_server, call, []}});
        Other        -> Other
    end.

insert_id(_Conn) -> persistent_term:get(?NEXT_ID, 1000).

record(Q) -> persistent_term:put(?QUERIES, [Q | persistent_term:get(?QUERIES, [])]).
