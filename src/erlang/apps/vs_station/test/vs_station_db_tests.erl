%%%-------------------------------------------------------------------
%%% @doc Tests for the session writer.
%%%
%%% **None of these need MySQL.** The row and the clock are pure
%%% functions, and the parts that are not — the queue, the cap, the retry,
%%% the wake-up towards Java — are exercised against a fake connection
%%% module, because what is worth testing here is the behaviour when the
%%% database is *not* answering, and a test that needs a working database
%%% cannot show that.
%%%-------------------------------------------------------------------
-module(vs_station_db_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ROW, #{user_id      => 2,
               station_id   => 2,
               connector_id => 5,
               started_at   => 1787836472573,
               ended_at     => 1787836547891,
               energy_kwh   => 1.206,
               overstay_seconds => 0}).

%%%===================================================================
%%% the clock — epoch ms → DATETIME, in UTC
%%%===================================================================

%% The conversion is ours and it goes to UTC, deliberately not through
%% `FROM_UNIXTIME()' — that would read the MySQL session's `time_zone',
%% which is an environment variable of somebody else's container.
a_known_instant_becomes_its_utc_datetime_test() ->
    %% 2026-08-27 13:14:32.573 UTC
    ?assertEqual({{2026, 8, 27}, {13, 14, 32}},
                 vs_station_db:to_datetime(1787836472573)),
    %% the epoch itself, as the fixed point that catches an offset applied
    %% in the wrong direction
    ?assertEqual({{1970, 1, 1}, {0, 0, 0}}, vs_station_db:to_datetime(0)).

%% The case where a timezone bug is actually visible. Europe/Rome is UTC+2
%% in August and UTC+1 in January: a conversion that went through local
%% time would put these two an hour apart from the truth, and in opposite
%% directions, which is why both are here. On a machine running in UTC a
%% single test would pass either way and prove nothing.
summer_and_winter_convert_the_same_way_test() ->
    %% 2026-08-27 13:14:32 UTC — CEST, local time would read 15:14
    ?assertEqual({{2026, 8, 27}, {13, 14, 32}},
                 vs_station_db:to_datetime(1787836472000)),
    %% 2026-01-15 13:14:32 UTC — CET, local time would read 14:14
    ?assertEqual({{2026, 1, 15}, {13, 14, 32}},
                 vs_station_db:to_datetime(1768482872000)),
    %% and one second before a DST changeover, where an off-by-an-hour is
    %% at its most convincing: 2026-03-29 00:59:59 UTC
    ?assertEqual({{2026, 3, 29}, {0, 59, 59}},
                 vs_station_db:to_datetime(1774745999000)).

%% The column is DATETIME and has no sub-second part; the event towards
%% Java keeps the milliseconds instead (erlang-java.md §2.3).
milliseconds_are_dropped_not_rounded_test() ->
    ?assertEqual({{2026, 8, 27}, {13, 14, 32}},
                 vs_station_db:to_datetime(1787836472000)),
    ?assertEqual({{2026, 8, 27}, {13, 14, 32}},
                 vs_station_db:to_datetime(1787836472999)).

%%%===================================================================
%%% the row — the parameters, in the column order of the INSERT
%%%===================================================================

the_row_matches_the_columns_test() ->
    ?assertEqual([2, 2, 5,
                  {{2026, 8, 27}, {13, 14, 32}},
                  {{2026, 8, 27}, {13, 15, 47}},
                  1.206,
                  0],
                 vs_station_db:insert_params(?ROW)).

%% `cost_cents' is not a parameter: the schema defaults it to NULL, and
%% NULL is what "not billed yet" means to the back office's sweep. Writing
%% a 0 there would make every session look priced at nothing.
the_row_does_not_carry_a_cost_test() ->
    ?assertEqual(7, length(vs_station_db:insert_params(?ROW))).

%% An integer energy from a connector that never took a meter reading must
%% still reach a DECIMAL column as a number, not as an integer term the
%% encoder would have to guess about.
energy_is_always_a_float_test() ->
    Params = vs_station_db:insert_params((?ROW)#{energy_kwh => 0}),
    ?assert(is_float(lists:nth(6, Params))),
    ?assertEqual(0.0, lists:nth(6, Params)).

%%%===================================================================
%%% the event — erlang-java.md §2.3, field for field
%%%===================================================================

%% Java does not read this payload, which is exactly why the test exists:
%% a field out of place would raise no error anywhere in the system and
%% would only ever show up on somebody's invoice.
the_event_is_the_contract_tuple_test() ->
    ?assertEqual({session_closed, 4242, 2, 2, 5, 1.206, 0,
                  1787836472573, 1787836547891},
                 vs_station_db:session_event(4242, ?ROW)),
    ?assertEqual(9, tuple_size(vs_station_db:session_event(4242, ?ROW))).

%% The timestamps stay in milliseconds here while the row carries
%% DATETIME. A factor of 1000 breaks no type and fails no test on the
%% other side; it shows up as a date in 1970.
the_event_keeps_milliseconds_test() ->
    Event = vs_station_db:session_event(1, ?ROW),
    ?assertEqual(1787836472573, element(8, Event)),
    ?assertEqual(1787836547891, element(9, Event)),
    %% and the row, from the same input, does not
    ?assertEqual({{2026, 8, 27}, {13, 14, 32}},
                 lists:nth(4, vs_station_db:insert_params(?ROW))).

%%%===================================================================
%%% the queue, the cap, the retry and the wake-up — no MySQL involved
%%%===================================================================

start_db(Extra) ->
    vs_claim_stub:reset(),
    Opts = maps:merge(#{retry_ms         => 40,
                        queue_max        => 100,
                        query_timeout_ms => 100,
                        sql_mod          => vs_sql_stub,
                        claim_mod        => vs_claim_stub,
                        conn_opts        => []}, Extra),
    {ok, Pid} = vs_station_db:start_link(Opts),
    Pid.

stop_db(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    wait_until(fun() -> whereis(vs_station_db) =:= undefined end).

with_db(Extra, Fun) ->
    Pid = start_db(Extra),
    try Fun(Pid) after stop_db(Pid) end.

wait_until(F) -> wait_until(F, 200).
wait_until(_F, 0) -> erlang:error(timed_out_waiting);
wait_until(F, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(10), wait_until(F, N - 1)
    end.

queued(Pid) -> length(queue(Pid)).
queue(Pid)  -> gen_server:call(Pid, queued_rows).

events() -> [E || {session_closed, E} <- vs_claim_stub:calls()].

inserts() -> [P || {Sql, P} <- vs_sql_stub:queries(), lists:prefix("INSERT", Sql)].

selects() -> [Q || {Sql, _} = Q <- vs_sql_stub:queries(), lists:prefix("SELECT", Sql)].

%% The property the whole design turns on: the caller is never held up,
%% database or no database.
insert_never_blocks_the_caller_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(_Pid) ->
        {Micros, _} = timer:tc(fun() ->
                          [vs_station_db:insert_session(?ROW) || _ <- lists:seq(1, 50)]
                      end),
        %% fifty casts against a database that will not connect
        ?assert(Micros < 200000)
    end).

%% A written row, and the wake-up that follows it — carrying the id MySQL
%% assigned, which is the reason this chain starts here and not in the
%% connector.
a_written_row_wakes_the_back_office_test() ->
    vs_sql_stub:reset(),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session(?ROW),
        wait_until(fun() -> events() =/= [] end),
        ?assertEqual(0, queued(Pid)),
        [Event] = events(),
        ?assertEqual({session_closed, vs_sql_stub:last_insert_id(),
                      2, 2, 5, 1.206, 0, 1787836472573, 1787836547891},
                     Event),
        %% and the row went in with the parameters the columns expect
        ?assertEqual([[2, 2, 5,
                       {{2026, 8, 27}, {13, 14, 32}},
                       {{2026, 8, 27}, {13, 15, 47}},
                       1.206, 0]],
                     inserts())
    end).

%% One session, one row. Never two — a second INSERT here would be a
%% second line on somebody's invoice for the same charge.
a_session_is_written_once_test() ->
    vs_sql_stub:reset(),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session(?ROW),
        wait_until(fun() -> events() =/= [] end),
        timer:sleep(120),                     %% several retry rounds
        ?assertEqual(1, length(inserts())),
        ?assertEqual(1, length(events())),
        ?assertEqual(0, queued(Pid))
    end).

%% Unreachable database: the rows are kept, not dropped, and the writer
%% keeps trying on its own timer without anybody asking.
rows_are_queued_while_the_database_is_unreachable_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session(?ROW),
        vs_station_db:insert_session(?ROW),
        timer:sleep(120),
        ?assert(erlang:is_process_alive(Pid)),
        ?assertEqual(2, queued(Pid)),
        ?assertEqual([], events())
    end).

%% ...and when it comes back the queue drains by itself, oldest first,
%% with nobody touching anything. This is the `docker start mysql'
%% scenario, as a unit test.
the_queue_drains_when_the_database_returns_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(Pid) ->
        [vs_station_db:insert_session((?ROW)#{connector_id => N}) || N <- [5, 6, 7]],
        timer:sleep(80),
        ?assertEqual(3, queued(Pid)),
        vs_sql_stub:set_connect(ok),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        ?assertEqual([5, 6, 7], [lists:nth(3, P) || P <- inserts()]),
        ?assertEqual(3, length(events()))
    end).

%% Past the cap the OLDEST goes: after a long outage the recent sessions
%% are the ones still worth keeping.
the_cap_drops_the_oldest_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{queue_max => 3}, fun(Pid) ->
        [vs_station_db:insert_session((?ROW)#{connector_id => N})
         || N <- [1, 2, 3, 4, 5]],
        timer:sleep(60),
        ?assertEqual(3, queued(Pid)),
        ?assertEqual([3, 4, 5], [maps:get(connector_id, R) || R <- queue(Pid)])
    end).

%% A row the server refuses is wrong, and will be wrong next time too.
%% Retrying it forever would wedge every later session behind it, so it is
%% dropped — loudly — and the queue keeps moving.
a_refused_row_is_dropped_and_does_not_block_the_queue_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_mode(refuse),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session((?ROW)#{connector_id => 5}),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        ?assertEqual([], events()),        %% nothing written, nothing announced
        vs_sql_stub:set_mode(ok),
        vs_station_db:insert_session((?ROW)#{connector_id => 6}),
        wait_until(fun() -> events() =/= [] end),
        ?assertEqual(1, length(events()))
    end).

%% A row that never reached the server is a different thing entirely, and
%% is kept.
a_row_that_never_arrived_is_retried_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_mode(raise),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session(?ROW),
        timer:sleep(120),
        ?assertEqual(1, queued(Pid)),
        ?assertEqual([], events()),
        vs_sql_stub:set_mode(ok),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        ?assertEqual(1, length(events()))
    end).

%% mysql-otp links its connection to us. Without trapping exits a MySQL
%% restart would take this process down and every queued row with it —
%% which is the one failure the queue exists to survive.
a_dead_connection_does_not_take_the_queue_down_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_mode(raise),
    with_db(#{retry_ms => 5000}, fun(Pid) ->
        vs_station_db:insert_session(?ROW),
        wait_until(fun() -> queued(Pid) =:= 1 end),
        Conn = gen_server:call(Pid, connection),
        ?assert(is_pid(Conn)),
        exit(Conn, kill),
        timer:sleep(100),
        ?assert(erlang:is_process_alive(Pid)),
        ?assertEqual(1, queued(Pid)),
        ?assertEqual(undefined, gen_server:call(Pid, connection))
    end).

%% The retry timer does two jobs — drain the queue, and get the
%% connection back — and an empty queue must not be read as "there is
%% nothing left to do". A station that has written every row it had and
%% then loses MySQL has an empty queue and no connection, which is
%% precisely the state it has to recover from: until it reconnects,
%% `user_for_vehicle/1' has no answer and every walk-in is refused.
%%
%% Found end to end, not here: MySQL came back and the station went on
%% refusing cars.
the_connection_comes_back_with_an_empty_queue_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(Pid) ->
        ?assertEqual(undefined, gen_server:call(Pid, connection)),
        ?assertEqual(0, queued(Pid)),
        %% Several failed rounds before the database returns — the outage
        %% has to outlast the first retry, or the timer is still armed
        %% from the boot attempt and the defect is invisible.
        timer:sleep(200),
        ?assertEqual(undefined, gen_server:call(Pid, connection)),
        vs_sql_stub:set_connect(ok),
        wait_until(fun() -> is_pid(gen_server:call(Pid, connection)) end),
        %% and with it, the lookup the walk-in path depends on
        ?assertMatch({ok, _}, vs_station_db:user_for_vehicle(2))
    end).

%% The same recovery, but reached through a connection that dies rather
%% than one that never opened.
a_lost_connection_is_reopened_with_an_empty_queue_test() ->
    vs_sql_stub:reset(),
    with_db(#{}, fun(Pid) ->
        wait_until(fun() -> is_pid(gen_server:call(Pid, connection)) end),
        Conn = gen_server:call(Pid, connection),
        exit(Conn, kill),
        wait_until(fun() ->
                           case gen_server:call(Pid, connection) of
                               undefined -> false;
                               New       -> New =/= Conn
                           end
                   end),
        ?assertEqual(0, queued(Pid))
    end).

%%%===================================================================
%%% user_for_vehicle/1 — synchronous, and never a hang
%%%===================================================================

the_vehicle_lookup_answers_from_the_table_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_vehicle({ok, 7}),
    with_db(#{}, fun(_Pid) ->
        ?assertEqual({ok, 7}, vs_station_db:user_for_vehicle(3)),
        ?assertEqual([{"SELECT user_id FROM vehicles WHERE id = ?", [3]}], selects())
    end).

%% A car this back office has never heard of. §4.2 has the station refuse,
%% and vs_cp_proto turns this into a log line and no session — which is
%% exactly what the identity stub used to hide.
an_unknown_vehicle_is_refused_not_invented_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_vehicle(empty),
    with_db(#{}, fun(_Pid) ->
        ?assertEqual({error, unknown_vehicle}, vs_station_db:user_for_vehicle(88))
    end).

%% The reason it is allowed to be synchronous at all: it always answers.
the_vehicle_lookup_answers_even_with_no_connection_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(_Pid) ->
        ?assertEqual({error, no_connection}, vs_station_db:user_for_vehicle(1))
    end).

%% And with the writer not there at all — restarting under its supervisor
%% — the caller gets an error rather than a hang, because vs_cp_proto
%% wraps the call in exactly this try.
the_vehicle_lookup_is_an_error_when_the_writer_is_gone_test() ->
    ?assertEqual(undefined, whereis(vs_station_db)),
    Result = try vs_station_db:user_for_vehicle(1)
             catch Class:Reason -> {error, {Class, Reason}}
             end,
    ?assertMatch({error, {exit, _}}, Result).

%%%===================================================================
%%% M2 fix 1 (D-6) — the announcement has its own net
%%%===================================================================

%% `announce/3' used to sit in the body after `of', which the `try' around
%% the INSERT does not cover. Reading the insert id is itself a call to the
%% connection, so a connection that dies between a successful INSERT and
%% that read used to kill the writer — and the writer takes the queue with
%% it. The row is safe by then; only the wake-up is worth losing.
a_failing_insert_id_does_not_kill_the_writer_test() ->
    vs_sql_stub:reset(),
    with_db(#{}, fun(Pid) ->
        vs_sql_stub:set_insert_id(raise),
        vs_station_db:insert_session(?ROW),
        wait_until(fun() -> inserts() =/= [] end),
        %% the row went in...
        ?assertEqual(1, length(inserts())),
        %% ...the wake-up did not, and nobody died for it
        ?assertEqual([], events()),
        ?assert(erlang:is_process_alive(Pid)),
        ?assertEqual(0, queued(Pid))
    end).

%% The same guarantee for everything behind the announcement: three rows
%% queued, the first one's announcement blowing up, and the other two are
%% still written.
a_failing_announcement_does_not_take_the_queue_down_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(Pid) ->
        [vs_station_db:insert_session((?ROW)#{connector_id => N}) || N <- [5, 6, 7]],
        wait_until(fun() -> queued(Pid) =:= 3 end),
        vs_sql_stub:set_insert_id(raise),
        vs_sql_stub:set_connect(ok),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        ?assert(erlang:is_process_alive(Pid)),
        ?assertEqual([5, 6, 7], [lists:nth(3, P) || P <- inserts()])
    end).

%%%===================================================================
%%% M2 fix 1 (D-7) — one bad row does not wedge the ones behind it
%%%===================================================================

%% A row that cannot be turned into parameters is not a transport failure,
%% and treating it as one is what used to stop the queue for ever: the
%% badarg came out of `insert_params/1' inside the same `try' as the query,
%% was read as "the row never got there", and went back to the head.
a_row_that_cannot_be_encoded_is_dropped_and_the_queue_moves_test() ->
    vs_sql_stub:reset(),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session((?ROW)#{started_at => undefined}),
        vs_station_db:insert_session((?ROW)#{connector_id => 6}),
        vs_station_db:insert_session((?ROW)#{connector_id => 7}),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        %% the poison row never reached MySQL and the good ones did
        ?assertEqual([6, 7], [lists:nth(3, P) || P <- inserts()]),
        ?assertEqual(2, length(events()))
    end).

%% An error the code cannot classify is counted, not retried for ever.
%% Five attempts are the empirical proof that the row does not go in; no
%% list of MySQL codes is consulted, because that list changes with the
%% server version.
an_unclassified_server_error_gives_up_after_the_attempts_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_mode(odd),                 %% {error, timeout}: not a server_reason()
    with_db(#{retry_ms => 10}, fun(Pid) ->
        vs_station_db:insert_session((?ROW)#{connector_id => 5}),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        ?assertEqual(5, length(inserts())),    %% MAX_ROW_ATTEMPTS
        ?assertEqual([], events()),
        %% and the queue is free again for the next session
        vs_sql_stub:set_mode(ok),
        vs_station_db:insert_session((?ROW)#{connector_id => 6}),
        wait_until(fun() -> events() =/= [] end),
        ?assertEqual(1, length(events()))
    end).

%% ...but a failure to *send* is not counted at all. A long outage must
%% not spend the attempts of a row that never had its turn: here the row
%% survives far more transport failures than the cap allows, and is
%% written the moment the database answers again.
a_transport_failure_never_spends_an_attempt_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_mode(raise),               %% the call itself blows up
    with_db(#{retry_ms => 10}, fun(Pid) ->
        vs_station_db:insert_session(?ROW),
        wait_until(fun() -> length(inserts()) >= 12 end),   %% >> MAX_ROW_ATTEMPTS
        ?assertEqual(1, queued(Pid)),
        vs_sql_stub:set_mode(ok),
        wait_until(fun() -> queued(Pid) =:= 0 end),
        ?assertEqual(1, length(events()))
    end).

%% The counter lives in the queue, and the introspection the tests use must
%% not see it: `queued_rows' answers with the sessions, never with how
%% often they have been tried.
the_queue_introspection_still_answers_with_rows_test() ->
    vs_sql_stub:reset(),
    vs_sql_stub:set_connect(refuse),
    with_db(#{}, fun(Pid) ->
        vs_station_db:insert_session((?ROW)#{connector_id => 42}),
        wait_until(fun() -> queued(Pid) =:= 1 end),
        [Row] = queue(Pid),
        ?assert(is_map(Row)),
        ?assertEqual(42, maps:get(connector_id, Row))
    end).
