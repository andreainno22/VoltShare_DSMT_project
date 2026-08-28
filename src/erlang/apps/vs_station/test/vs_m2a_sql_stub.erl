%%%-------------------------------------------------------------------
%%% @doc REVIEW M2-A — a mysql-otp stand-in that can also fail on
%%% `insert_id/1', which vs_sql_stub cannot.
%%%-------------------------------------------------------------------
-module(vs_m2a_sql_stub).

-export([start_link/1, query/4, insert_id/1]).
-export([reset/0, set_mode/1, set_insert_id/1, queries/0]).

-define(MODE,    {?MODULE, mode}).
-define(ID,      {?MODULE, id_mode}).
-define(QUERIES, {?MODULE, queries}).
-define(NEXT_ID, {?MODULE, next_id}).

reset() ->
    persistent_term:put(?MODE, ok),
    persistent_term:put(?ID, ok),
    persistent_term:put(?QUERIES, []),
    persistent_term:put(?NEXT_ID, 1000).

set_mode(Mode)      -> persistent_term:put(?MODE, Mode).
%% ok | raise
set_insert_id(What) -> persistent_term:put(?ID, What).

queries() -> lists:reverse(persistent_term:get(?QUERIES, [])).

start_link(_Opts) -> {ok, spawn_link(fun idle/0)}.

idle() -> receive _ -> idle() end.

query(_Conn, Sql, Params, _Timeout) ->
    persistent_term:put(?QUERIES, [{Sql, Params} | persistent_term:get(?QUERIES, [])]),
    case persistent_term:get(?MODE, ok) of
        ok ->
            persistent_term:put(?NEXT_ID, persistent_term:get(?NEXT_ID, 1000) + 1),
            ok;
        refuse ->
            {error, {1205, <<"HY000">>, <<"Lock wait timeout exceeded">>}};
        raise ->
            exit({noproc, {gen_server, call, []}})
    end.

insert_id(_Conn) ->
    case persistent_term:get(?ID, ok) of
        ok    -> persistent_term:get(?NEXT_ID, 1000);
        raise -> exit({noproc, {gen_server, call, []}})
    end.
