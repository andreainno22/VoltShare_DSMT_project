%%%-------------------------------------------------------------------
%%% @doc Durable state written by the station.
%%%
%%% The station owns exactly one table — `sessions' — and touches it once
%%% per session, at the end (schema.sql, ownership rules). Cost is left
%%% NULL: billing is the back office's, and it runs after the fact on
%%% purpose, so that money is never a contended resource.
%%%
%%% ## Why this is a process, and why the INSERT is a cast
%%%
%%% The interesting decision in this module is not the SQL, it is **who
%%% waits**. `vs_connector:closing/3' used to call `insert_session/1' in
%%% line, inside the gen_statem that governs a physical outlet. With a
%%% stub behind it that was a microsecond; with MySQL behind it, it would
%%% be a network round trip inside a state machine — and if the database
%%% were slow the connector would sit in `closing', if it were gone it
%%% would sit there for the timeout, and the station would stop freeing
%%% outlets because of a component that has nothing to do with delivering
%%% power. That is exactly what SCOPE §4 (station autonomy) forbids, and
%%% it also breaks the structural rule agreed with B: **connectors make no
%%% remote calls.**
%%%
%%% So `insert_session/1' is a cast. It queues the row and returns, and
%%% this process carries on alone:
%%%
%%%   connector closing(enter) --cast--> vs_station_db --INSERT--> MySQL
%%%                                            |
%%%                                            +--> vs_claim_client:session_closed/1
%%%
%%% Three consequences, all of them wanted:
%%%
%%%   * the connector returns to `free' at the speed of its own state
%%%     machine, whatever the database is doing;
%%%   * the `session_closed' event towards Java leaves **after** the
%%%     INSERT and is sent by the claim client, never by the connector —
%%%     the boundary rule realises itself here instead of being a
%%%     recommendation;
%%%   * the `SessionId' the event needs (erlang-java.md §2.3) only exists
%%%     once the row has an id, so this is the only place the chain can
%%%     start from. `insert_session/1' no longer returns it to anybody:
%%%     the connector has no use for it, and returning it would mean
%%%     making the connector wait.
%%%
%%% **The price, declared rather than hidden:** a row still in the queue
%%% when the node dies is lost. The window is one INSERT plus whatever is
%%% queued ahead of it — milliseconds when MySQL is healthy, and as long
%%% as the outage when it is not. The alternative (a write-ahead log, or a
%%% synchronous INSERT with confirmation) would buy back an unbilled
%%% session in a rare fault by paying with station autonomy in *every*
%%% database fault. That is the wrong trade, and it is the one this
%%% milestone is about.
%%%
%%% **Retry, and the cap.** The queue is in memory and is retried every
%%% `DB_RETRY_MS'. Past `DB_QUEUE_MAX' rows the **oldest** is dropped with
%%% a `logger:error' carrying the whole row: if the database has been down
%%% for eight minutes the session most worth keeping is the most recent
%%% one, and the log line is the last copy left of the one being dropped.
%%% Nothing is deduplicated and nothing is reordered — the back office's
%%% UPDATE is conditional on `cost_cents IS NULL' (erlang-java.md §2.3),
%%% so a row written twice cannot bill twice. **At-least-once delivery
%%% over an idempotent write**, which is how effectively-once behaviour is
%%% obtained without an exactly-once channel.
%%%
%%% ## Three failures, three prices, three answers
%%%
%%% `flush/1' writes the head and stops if the head cannot be written, so
%%% *how* a write fails decides whether every session behind it moves.
%%% Lumping the three together is how the queue used to wedge on one bad
%%% row, and it is why they are now told apart before anything else:
%%%
%%%   * **the row cannot be encoded** — `insert_params/1' raises, because
%%%     a field is missing or is not what the column takes. Nothing was
%%%     sent, nothing ever will be: the row will raise again in an hour.
%%%     Dropped at once, with the `logger:error' that is its last copy.
%%%     Evaluated **outside** the `try' around the query, so that "we
%%%     cannot build this" and "we could not send it" stop being the same
%%%     event.
%%%   * **the server answered an error** — `{error, _}' comes back. The
%%%     row reached MySQL and MySQL said no. A `server_reason()' is
%%%     dropped as before; anything else is counted against the row
%%%     (`MAX_ROW_ATTEMPTS') and dropped once the count is spent. No
%%%     attempt is made to decide which MySQL codes are permanent: that
%%%     list depends on the server version and would be wrong the day
%%%     after. Five failed attempts are the empirical proof.
%%%   * **the write could not be sent** — the call raises. The connection
%%%     is gone and the row never left. Retried for ever, and **not
%%%     counted**: an outage must not spend the attempts of rows that
%%%     never had their turn. `flush/1' does not even reach `write/3'
%%%     while `conn' is `undefined', so a plain outage costs nothing.
%%%
%%% ## The announcement is not protected together with the INSERT
%%%
%%% `announce/3' used to sit in the body after `of', which in Erlang is
%%% **not** covered by that `try''s `catch' — a rule of the language, not
%%% an oversight. An `insert_id/1' on a connection that has just died, or
%%% anything raising on the way to the claim client, therefore left the
%%% gen_server and took the whole queue with it. The two failures are not
%%% worth the same: a lost announcement costs one receipt priced a minute
%%% late (B sweeps `cost_cents IS NULL'), a dead writer costs every row
%%% still queued. They get one net each.
%%%
%%% ## Times: epoch milliseconds in, DATETIME out, UTC in between
%%%
%%% `sessions.started_at'/`ended_at' are `DATETIME' and the connector
%%% produces epoch milliseconds. The conversion happens **here, in
%%% Erlang, towards UTC** (`calendar:system_time_to_universal_time/2`) and
%%% not with `FROM_UNIXTIME()' in SQL: `FROM_UNIXTIME' works off the MySQL
%%% session's `time_zone', which is an environment variable of somebody
%%% else's container rather than a decision we took — the same class of
%%% invisible error as the seconds-versus-milliseconds discussion on the
%%% Java boundary.
%%%
%%% UTC is also what B already does: `Db.java' opens the connection with
%%% `serverTimezone=UTC' and `SessionDao' reads through
%%% `getTimestamp(...).toLocalDateTime()'. It is a convention already in
%%% force on the other side, so it is respected and verified end to end,
%%% not negotiated again.
%%%
%%% ## One connection, no pool
%%%
%%% A pool would be over-built for a station with four outlets, and one
%%% connection shared by many processes would need a lock. This process
%%% holds a single connection and is the only thing that touches it, which
%%% makes the serialisation structural instead of configured.
%%% `user_for_vehicle/1' is the one **synchronous** entry point, and it is
%%% allowed to be: it sits on the `plugged' path, its caller is a socket
%%% process rather than a connector, and nothing can decide whether to
%%% authorise a walk-in without the answer. It has an explicit timeout, so
%%% the worst case is a refused walk-in with a log line, never a hung
%%% socket.
%%%-------------------------------------------------------------------
-module(vs_station_db).
-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, insert_session/1, user_for_vehicle/1]).
%% pure — exported so the row and the clock can be tested without MySQL
-export([insert_params/1, to_datetime/1, session_event/2]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2, terminate/2]).

-define(SERVER, ?MODULE).

-define(INSERT_SQL,
        "INSERT INTO sessions (user_id, station_id, connector_id, started_at, "
        "ended_at, energy_kwh, overstay_seconds) VALUES (?, ?, ?, ?, ?, ?, ?)").

-define(VEHICLE_SQL, "SELECT user_id FROM vehicles WHERE id = ?").

%% How many times the server may answer an error we do not recognise
%% before the row is given up on. Per row, never per queue.
-define(MAX_ROW_ATTEMPTS, 5).

-record(state, {conn      = undefined :: pid() | undefined,
                conn_opts            :: list(),
                %% oldest first: the head is the next row to write, and the
                %% head is also what the cap drops. Each entry carries the
                %% number of times the *server* has refused it in a way we
                %% could not classify; `queued_rows' unwraps it, so the
                %% counter is invisible outside this module.
                queue     = []        :: [{map(), non_neg_integer()}],
                retry     = undefined :: reference() | undefined,
                retry_ms              :: pos_integer(),
                queue_max             :: pos_integer(),
                query_timeout_ms      :: pos_integer(),
                %% Injected, exactly as claim_mod/db_mod/conn_mod are
                %% elsewhere in this application. `sql_mod' is what makes
                %% the interesting half of this module testable: what has
                %% to be got right is the behaviour when the database
                %% refuses, or vanishes mid-write, and a test that needed a
                %% real MySQL could not produce either on demand.
                sql_mod               :: module(),
                claim_mod             :: module()}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

%% @doc Queue a closed session for writing. Returns immediately, always.
%%
%% A cast on purpose — see the module doc. `gen_server:cast/2' to a name
%% that is not registered is dropped silently rather than raising, which
%% is the behaviour wanted here too: a station whose database process is
%% restarting must still free its connectors.
-spec insert_session(map()) -> ok.
insert_session(Row) ->
    gen_server:cast(?SERVER, {insert_session, Row}).

%% @doc The account a vehicle belongs to (ws-chargepoint.md §4.2 — the
%% charge point identifies the car, the station bills the person).
%%
%% Synchronous, with an explicit timeout. The caller is `vs_cp_proto',
%% which already wraps this in a `try', so a timeout or a dead process
%% comes back as `{error, _}' and the walk-in is refused with a log line
%% instead of leaving a socket waiting.
-spec user_for_vehicle(pos_integer()) -> {ok, pos_integer()} | {error, term()}.
user_for_vehicle(VehicleId) ->
    gen_server:call(?SERVER, {user_for_vehicle, VehicleId}, call_timeout_ms()).

%%%===================================================================
%%% pure — the row, the clock, the event
%%%===================================================================

%% @doc Epoch milliseconds → the UTC `calendar:datetime()' mysql-otp
%% encodes as a DATETIME. Sub-second precision is dropped because the
%% column has none; nothing bills on it (erlang-java.md §2.3 keeps the
%% millisecond figures in the event instead).
-spec to_datetime(integer()) -> calendar:datetime().
to_datetime(EpochMs) ->
    calendar:system_time_to_universal_time(EpochMs, millisecond).

%% @doc The row the connector produced → the parameters of ?INSERT_SQL,
%% in the column order written there. `cost_cents' is not among them: the
%% schema defaults it to NULL and NULL is what "not billed yet" means.
-spec insert_params(map()) -> [term()].
insert_params(Row) ->
    [maps:get(user_id, Row),
     maps:get(station_id, Row),
     maps:get(connector_id, Row),
     to_datetime(maps:get(started_at, Row)),
     to_datetime(maps:get(ended_at, Row)),
     float(maps:get(energy_kwh, Row, 0.0)),
     maps:get(overstay_seconds, Row, 0)].

%% @doc The event of erlang-java.md §2.3, field for field and in order.
%%
%% The timestamps stay in **milliseconds** here while the row carries
%% DATETIME: the contract is explicit that every figure on this boundary
%% is milliseconds, and `OverstaySeconds' is the one exception because it
%% carries its unit in its name. Java does not read the payload — it is a
%% wake-up, and the row is the truth — which is precisely why a field out
%% of order here would raise no error anywhere and would only ever be
%% visible on an invoice.
-spec session_event(integer(), map()) -> tuple().
session_event(SessionId, Row) ->
    {session_closed,
     SessionId,
     maps:get(user_id, Row),
     maps:get(station_id, Row),
     maps:get(connector_id, Row),
     float(maps:get(energy_kwh, Row, 0.0)),
     maps:get(overstay_seconds, Row, 0),
     maps:get(started_at, Row),
     maps:get(ended_at, Row)}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    %% The connection is linked to us by mysql-otp. Trapping exits is what
    %% turns its death into a message we can answer with a reconnection,
    %% instead of taking this process — and the queue it is holding — down
    %% with it.
    process_flag(trap_exit, true),
    State = #state{conn_opts        = conn_opts(Opts),
                   retry_ms         = opt(retry_ms, Opts, "DB_RETRY_MS", 5000),
                   queue_max        = opt(queue_max, Opts, "DB_QUEUE_MAX", 100),
                   query_timeout_ms = opt(query_timeout_ms, Opts,
                                          "DB_QUERY_TIMEOUT_MS", 5000),
                   sql_mod          = maps:get(sql_mod, Opts, mysql),
                   claim_mod        = maps:get(claim_mod, Opts, vs_claim_client)},
    {ok, State, {continue, connect}}.

%% Connecting from handle_continue and not from init is what keeps a
%% database that is down from delaying the boot of the station: start_link
%% has already returned by the time this runs, and a failure here is a
%% retry rather than a crash.
handle_continue(connect, State) ->
    {noreply, connect(State)}.

handle_call({user_for_vehicle, _VehicleId}, _From, State = #state{conn = undefined}) ->
    {reply, {error, no_connection}, State};

handle_call({user_for_vehicle, VehicleId}, _From,
            State = #state{conn = Conn, sql_mod = Sql, query_timeout_ms = Timeout}) ->
    Reply = try Sql:query(Conn, ?VEHICLE_SQL, [VehicleId], Timeout) of
                {ok, _Cols, [[UserId]]} ->
                    {ok, UserId};
                {ok, _Cols, []} ->
                    %% Not an error of ours: the charge point named a car
                    %% this back office has never heard of. §4.2 has the
                    %% station refuse, and vs_cp_proto logs it.
                    {error, unknown_vehicle};
                {error, Reason} ->
                    {error, Reason}
            catch
                Class:CatchReason ->
                    {error, {Class, CatchReason}}
            end,
    {reply, Reply, State};

%% Introspection, for the tests. Reaching into the record positionally
%% from a test file works until somebody adds a field in the middle, and
%% then fails somewhere unrelated; two named questions cost nothing and
%% say what the tests are actually asking about.
%% The rows, without the attempt counter: what a test asks about is which
%% sessions are still unwritten, never how often they have been tried.
handle_call(queued_rows, _From, State) ->
    {reply, [Row || {Row, _Attempts} <- State#state.queue], State};

handle_call(connection, _From, State) ->
    {reply, State#state.conn, State};

handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({insert_session, Row}, State) ->
    {noreply, flush(enqueue(Row, State))};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(retry, State) ->
    State1 = State#state{retry = undefined},
    {noreply, flush(case State1#state.conn of
                        undefined -> connect(State1);
                        _         -> State1
                    end)};

%% The connection died — MySQL restarted, the network blinked, or the
%% server hung up. Not our death: the queue is the thing worth keeping.
handle_info({'EXIT', Conn, Reason}, State = #state{conn = Conn}) ->
    logger:warning("station db: connection lost (~p); ~p row(s) queued",
                   [Reason, length(State#state.queue)]),
    {noreply, schedule_retry(State#state{conn = undefined})};

handle_info({'EXIT', _Old, _Reason}, State) ->
    %% A connection we already replaced. Nothing to do.
    {noreply, State};

handle_info(Info, State) ->
    logger:debug("station db ignoring ~p", [Info]),
    {noreply, State}.

%% The declared loss, said out loud rather than discovered later.
terminate(_Reason, #state{queue = []}) ->
    ok;
terminate(_Reason, #state{queue = Queue}) ->
    logger:error("station db stopping with ~p unwritten session row(s), "
                 "which are lost: ~p", [length(Queue), Queue]),
    ok.

%%%===================================================================
%%% internal — the queue
%%%===================================================================

%% Newest at the tail. Past the cap the **oldest** goes, because after a
%% long outage the recent sessions are the ones still worth saving, and
%% the log line is the last copy of the one being dropped.
enqueue(Row, State = #state{queue = Queue, queue_max = Max}) ->
    case Queue ++ [{Row, 0}] of
        Full when length(Full) > Max ->
            [{Dropped, _} | Kept] = Full,
            logger:error("station db: queue full at ~p rows, dropping the oldest "
                         "unwritten session (this line is its last copy): ~p",
                         [Max, Dropped]),
            State#state{queue = Kept};
        Ok ->
            State#state{queue = Ok}
    end.

%% The order of these two clauses is the whole of a defect found end to
%% end. The retry timer does two jobs — drain the queue **and** get the
%% connection back — so an empty queue is not "nothing left to do" while
%% there is no connection. With the clauses the other way round, a station
%% that had written every row it had and then lost MySQL would cancel its
%% own reconnection and never open another one: the queue stayed empty, so
%% nothing ever rearmed the timer, and `user_for_vehicle/1' went on
%% answering `no_connection' long after the database was back — every
%% walk-in refused, with no error anywhere to say why.
flush(State = #state{conn = undefined}) ->
    schedule_retry(State);
flush(State = #state{queue = []}) ->
    cancel_retry(State);
flush(State = #state{conn = Conn, queue = [{Row, Attempts} | Rest]}) ->
    case write(Conn, Row, Attempts, State) of
        ok ->
            flush(State#state{queue = Rest});
        refused ->
            %% The row is not going in — the server said no, or it cannot
            %% be built at all. Retrying forever would wedge every session
            %% behind this one, so it is dropped here and the log keeps it.
            flush(State#state{queue = Rest});
        {retry, Attempts1} ->
            %% Back at the head, with whatever the attempt cost it. The
            %% queue does not move until this row does or gives up.
            schedule_retry(State#state{queue = [{Row, Attempts1} | Rest]})
    end.

%% Three failures that look alike and are not — see the module doc.
write(Conn, Row, Attempts, #state{query_timeout_ms = Timeout, sql_mod = Sql,
                                  claim_mod = ClaimMod}) ->
    case params(Row) of
        {ok, Params} ->
            send(Conn, Row, Params, Attempts, Timeout, Sql, ClaimMod);
        error ->
            refused
    end.

%% Building the parameters is not talking to the database, and must not be
%% mistaken for it: a row that cannot be encoded is dropped, not retried.
params(Row) ->
    try {ok, insert_params(Row)}
    catch Class:Reason ->
            logger:error("station db: a session row cannot be turned into "
                         "INSERT parameters (~p:~p), dropping it (this line is "
                         "its last copy): ~p", [Class, Reason, Row]),
            error
    end.

send(Conn, Row, Params, Attempts, Timeout, Sql, ClaimMod) ->
    Result = try Sql:query(Conn, ?INSERT_SQL, Params, Timeout)
             catch
                 SendClass:SendReason ->
                     %% The connection is gone and the row never got there.
                     %% Not counted: an outage must not spend the attempts
                     %% of a row that never had its turn.
                     logger:warning("station db: INSERT could not be sent "
                                    "(~p:~p), will retry",
                                    [SendClass, SendReason]),
                     not_sent
             end,
    case Result of
        ok ->
            %% Out of the try on purpose: the row is already safe, and the
            %% announcement must never be able to take the writer down
            %% with it (module doc).
            announce(Sql, Conn, Row, ClaimMod),
            ok;
        not_sent ->
            {retry, Attempts};
        {error, {Code, SqlState, Msg}} ->
            logger:error("station db: MySQL refused a session row "
                         "(~p ~s ~s), dropping it: ~p",
                         [Code, SqlState, Msg, Row]),
            refused;
        {error, Reason} when Attempts + 1 >= ?MAX_ROW_ATTEMPTS ->
            logger:error("station db: INSERT failed ~p times (~p), giving up on "
                         "this row so the queue can move (this line is its last "
                         "copy): ~p", [Attempts + 1, Reason, Row]),
            refused;
        {error, Reason} ->
            logger:warning("station db: INSERT failed (~p), will retry "
                           "(attempt ~p of ~p)",
                           [Reason, Attempts + 1, ?MAX_ROW_ATTEMPTS]),
            {retry, Attempts + 1};
        Other ->
            %% A shape this code does not know. Treated like any other
            %% answer from the server: counted, not retried for ever.
            logger:warning("station db: unexpected INSERT result ~p, will retry "
                           "(attempt ~p of ~p)",
                           [Other, Attempts + 1, ?MAX_ROW_ATTEMPTS]),
            {retry, Attempts + 1}
    end.

%% Reading the insert id is itself a call to the connection, so it lives
%% inside the announcement's own net rather than the INSERT's: if it
%% raises, the row is still written and only the wake-up is lost.
announce(Sql, Conn, Row, ClaimMod) ->
    try announce(Sql:insert_id(Conn), Row, ClaimMod)
    catch Class:Reason ->
            logger:warning("station db: a session row was written but the back "
                           "office wake-up did not leave (~p:~p); the sweep "
                           "will price it within the minute: ~p",
                           [Class, Reason, Row])
    end,
    ok.

%% After the INSERT, never before: the id the event carries does not exist
%% until the row does.
announce(SessionId, Row, ClaimMod) when is_integer(SessionId) ->
    logger:notice("session ~p written: connector ~p, user ~p, ~p kWh",
                  [SessionId, maps:get(connector_id, Row), maps:get(user_id, Row),
                   maps:get(energy_kwh, Row, 0.0)]),
    %% The wake-up must never be able to take the writer down with it: the
    %% row is already safe, and this is the part the contract calls
    %% best-effort.
    try ClaimMod:session_closed(session_event(SessionId, Row))
    catch Class:Reason ->
            logger:warning("station db: session ~p written but the back office "
                           "wake-up did not leave (~p:~p); the sweep will price "
                           "it within the minute", [SessionId, Class, Reason])
    end,
    ok;
announce(Other, Row, _ClaimMod) ->
    %% No id means no event: erlang-java.md §2.3 has SessionId as an
    %% integer, and inventing one would be worse than the missed wake-up
    %% — the sweep prices the row a minute later anyway.
    logger:error("station db: wrote a session but got no insert id (~p): ~p",
                 [Other, Row]),
    ok.

schedule_retry(State = #state{retry = Ref}) when is_reference(Ref) ->
    State;
schedule_retry(State = #state{retry_ms = Ms}) ->
    State#state{retry = erlang:send_after(Ms, self(), retry)}.

cancel_retry(State = #state{retry = undefined}) ->
    State;
cancel_retry(State = #state{retry = Ref}) ->
    _ = erlang:cancel_timer(Ref),
    State#state{retry = undefined}.

%%%===================================================================
%%% internal — the connection
%%%===================================================================

connect(State = #state{conn_opts = Opts, sql_mod = Sql}) ->
    try Sql:start_link(Opts) of
        {ok, Conn} ->
            logger:notice("station db: connected to MySQL"),
            State#state{conn = Conn};
        {error, Reason} ->
            logger:warning("station db: cannot reach MySQL (~p), retrying in ~p ms",
                           [Reason, State#state.retry_ms]),
            schedule_retry(State#state{conn = undefined})
    catch
        Class:Reason ->
            logger:warning("station db: cannot reach MySQL (~p:~p), retrying in ~p ms",
                           [Class, Reason, State#state.retry_ms]),
            schedule_retry(State#state{conn = undefined})
    end.

%% MYSQL_HOST is the name the compose already gives the station; the rest
%% default to the credentials in the same file, so a stock deployment needs
%% no new variable.
conn_opts(Opts) ->
    maps:get(conn_opts, Opts,
             [{host,     vs_env:get_str("MYSQL_HOST", "mysql")},
              {port,     vs_env:get_int("MYSQL_PORT", 3306)},
              {user,     vs_env:get_str("MYSQL_USER", "voltshare")},
              {password, vs_env:get_str("MYSQL_PASSWORD", "voltshare")},
              {database, vs_env:get_str("MYSQL_DATABASE", "voltshare")},
              %% bounded, so a black-holed host is a retry and not a wedge
              {connect_timeout, vs_env:get_int("DB_CONNECT_TIMEOUT_MS", 5000)},
              %% mysql-otp pings on this and notices a dead peer for us
              {keep_alive, true}]).

opt(Key, Opts, Var, Default) ->
    maps:get(Key, Opts, vs_env:get_int(Var, Default)).

%% Comfortably above the query timeout: the call must be allowed to come
%% back with the process's own `{error, _}' rather than being cut off by
%% its caller, which would leave a late reply in a socket's mailbox.
call_timeout_ms() ->
    vs_env:get_int("DB_QUERY_TIMEOUT_MS", 5000) + 1000.
