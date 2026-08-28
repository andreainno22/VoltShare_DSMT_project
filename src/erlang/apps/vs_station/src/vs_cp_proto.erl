%%%-------------------------------------------------------------------
%%% @doc The charge point protocol of contracts/ws-chargepoint.md, with no
%%% cowboy in it.
%%%
%%% Same split as the driver channel, for the same reason (see the module
%%% doc of `vs_driver_proto'): a cowboy handler cannot be exercised from
%%% EUnit without a listener and a WebSocket client, and a client would be
%%% a dependency carried for the tests alone. Everything that decides
%%% something is here — the handshake verdict, the envelope, the dispatch
%%% of the six actions, the authorisation outcome of `plugged' and the
%%% frames that go back — and `vs_cp_ws' keeps only the callbacks.
%%%
%%% The session is a plain map, threaded through by the caller:
%%%
%%%   station_id            of this node, for the query-string check
%%%   connector_id          this socket *is* this connector (§1)
%%%   booted                whether `boot' has been seen (§3.1)
%%%   heartbeat_interval_s,
%%%   meter_interval_s      §10; handed to the equipment in the boot ack
%%%   conn_mod, mgr_mod,
%%%   db_mod                injected collaborators
%%%
%%% ## Three things this channel does NOT do, and why
%%%
%%% **No request cache.** §2 is explicit: `request_id' "is not a
%%% deduplication key here — the events of the two sides are naturally
%%% idempotent or naturally ordered". A repeated `meter' is absorbed by
%%% the monotonic max, a repeated `plugged' by the state machine. The
%%% driver channel needs at-most-once because a repeated `reserve' would
%%% take a second connector; nothing here has that shape.
%%%
%%% **No error frame.** §2 gives this channel exactly two station→charge
%%% point frame types, `ack' and `command'. There is no `error', so a
%%% malformed envelope is logged and dropped rather than answered with a
%%% frame the contract does not define — and the contract is A's, not
%%% something to be widened from the implementation side. It is still
%%% loud: §7.6 asks for divergence to be logged, and it is.
%%%
%%% **No ack on events.** §9's ladder shows `plugged', `meter' and
%%% `unplugged' answered by a command or by nothing at all; only `boot'
%%% and `heartbeat' carry an ack (§3.1, §3.2). Acknowledging the rest
%%% would be inventing traffic on a link that a real unit shares with
%%% every other connector of the site.
%%%
%%% ## The connector is looked up per event, never cached
%%%
%%% `mgr_mod:lookup_pid/1' is a dirty read of the manager's ETS — the same
%%% idiom `vs_claim_client' uses, and for the same reason: the socket must
%%% not queue behind a manager that is booting. Holding on to the pid from
%%% the handshake would be faster and wrong: a connector that crashes is
%%% restarted with a new pid, and this socket would go on casting meters
%%% into a dead mailbox instead of into the live process — where the
%%% "meter with no session" log of §4.3 is what tells us the two sides
%%% have diverged.
%%%-------------------------------------------------------------------
-module(vs_cp_proto).

-export([new/1, handshake/2, handle_text/2,
         boot_ack/3, command_frame/1, stop_command/1]).

-type frame()   :: map().
-type session() :: map().

-export_type([frame/0, session/0]).

%%%===================================================================
%%% session
%%%===================================================================

%% @doc A fresh session. Every key has a default, so a test builds one
%% with `new(#{connector_id => 3, conn_mod => Stub})'.
-spec new(map()) -> session().
new(Opts) ->
    #{station_id   => opt(station_id, Opts,
                          fun() -> vs_env:get_int("STATION_ID", 1) end),
      connector_id => maps:get(connector_id, Opts, undefined),
      booted       => false,
      heartbeat_interval_s =>
          opt(heartbeat_interval_s, Opts,
              fun() -> vs_env:get_int("CP_HEARTBEAT_INTERVAL_S", 30) end),
      meter_interval_s =>
          opt(meter_interval_s, Opts,
              fun() -> vs_env:get_int("METER_INTERVAL_S", 5) end),
      conn_mod     => opt(conn_mod, Opts, fun() -> vs_connector end),
      mgr_mod      => opt(mgr_mod, Opts, fun() -> vs_station_mgr end),
      db_mod       => opt(db_mod, Opts, fun() -> vs_station_db end)}.

%% Same trick as vs_driver_proto: the default is a thunk, so a session
%% built by a test never reads the environment for keys it supplied.
opt(Key, Opts, Default) ->
    case Opts of
        #{Key := Value} -> Value;
        _NotGiven       -> Default()
    end.

%%%===================================================================
%%% §1 — the handshake
%%%===================================================================

%% @doc The verdict on `?station_id=<id>&connector_id=<n>'.
%%
%% "A connector id that does not belong to `station_id' is refused at the
%% handshake with close code 4404" (§1). Three ways to earn it, and the
%% log line says which: a query string that does not parse, a station that
%% is not this node, and a connector this station does not own. The last
%% is decided by the dirty read, never by a call to the manager: a charge
%% point dialling in while the manager is booting must not queue behind
%% it, and the honest answer for "the registry is not there yet" is the
%% same one as for "not mine" — come back later.
-spec handshake([{binary(), binary() | true}], map()) ->
          {ok, session()} | {refuse, 4404}.
handshake(Qs, Opts) ->
    Session = new(Opts),
    Mine = maps:get(station_id, Session),
    case {qs_int(<<"station_id">>, Qs), qs_int(<<"connector_id">>, Qs)} of
        {{ok, Mine}, {ok, ConnId}} ->
            Session1 = Session#{connector_id := ConnId},
            case connector(Session1) of
                {ok, _Pid} ->
                    {ok, Session1};
                {error, _} ->
                    logger:notice("charge point channel: refused connector ~p - "
                                  "not a connector of station ~p", [ConnId, Mine]),
                    {refuse, 4404}
            end;
        {{ok, Other}, _} ->
            logger:notice("charge point channel: refused a charge point for "
                          "station ~p (this node serves ~p)", [Other, Mine]),
            {refuse, 4404};
        _Unparsable ->
            logger:notice("charge point channel: refused a connection with no "
                          "usable station_id/connector_id in the query string"),
            {refuse, 4404}
    end.

qs_int(Key, Qs) ->
    case lists:keyfind(Key, 1, Qs) of
        {_, Value} when is_binary(Value) ->
            try {ok, binary_to_integer(Value)}
            catch error:badarg -> error
            end;
        _Missing ->
            error
    end.

%%%===================================================================
%%% the entry point
%%%===================================================================

%% @doc One text frame in, the frames to send out and the new session.
%%
%% No close verdict in the return: nothing a charge point can *say* closes
%% this socket. The two close codes of the contract come from elsewhere —
%% 4404 from the handshake above, 4409 from the connector telling this
%% process it has been replaced.
-spec handle_text(binary(), session()) -> {[frame()], session()}.
handle_text(Bin, Session) ->
    case decode(Bin) of
        {ok, Msg} when is_map(Msg) ->
            envelope(Msg, Session);
        {ok, _NotAnObject} ->
            drop(Session, "frame is not an object", []);
        {error, malformed} ->
            drop(Session, "malformed JSON (~p bytes)", [byte_size(Bin)])
    end.

decode(Bin) ->
    try {ok, jsx:decode(Bin)}
    catch _:_ -> {error, malformed}
    end.

%% There is no error frame on this channel (§2), so a frame we cannot read
%% leaves a log line and nothing else.
drop(Session, Fmt, Args) ->
    logger:error("charge point channel (connector ~p): dropping a frame - " ++ Fmt,
                 [maps:get(connector_id, Session) | Args]),
    {[], Session}.

%%%===================================================================
%%% §2 — the envelope
%%%===================================================================

envelope(Msg, Session) ->
    case {request_id(Msg), payload(Msg), action(Msg)} of
        {{ok, ReqId}, {ok, Payload}, Action} when is_binary(Action) ->
            dispatch(Action, ReqId, Payload, Session);
        {error, _, _} ->
            drop(Session, "request_id is mandatory", []);
        {_, error, _} ->
            drop(Session, "payload must be an object", []);
        _NoAction ->
            drop(Session, "action is mandatory", [])
    end.

%% Generated by the charge point and echoed back on the acks that exist:
%% "it lets a log line be followed end to end, which is worth its weight
%% when a session goes wrong during the demo" (§2).
request_id(#{<<"request_id">> := ReqId}) when is_binary(ReqId), ReqId =/= <<>> ->
    {ok, ReqId};
request_id(_Msg) ->
    error.

payload(#{<<"payload">> := P}) when is_map(P) -> {ok, P};
payload(_Msg)                                 -> error.

action(#{<<"action">> := A}) when is_binary(A) -> A;
action(_Msg)                                   -> undefined.

%%%===================================================================
%%% §3 and §4 — dispatch
%%%===================================================================

dispatch(<<"boot">>, ReqId, Payload, Session) ->
    boot(ReqId, Payload, Session);

%% §3.1 puts `boot' first "before anything else". An event that arrives
%% before it is still handled — the connector is found the same way and
%% the reading is real — but the order is a divergence and gets said out
%% loud rather than quietly tolerated.
dispatch(Action, ReqId, Payload, Session = #{booted := false}) ->
    logger:warning("charge point channel (connector ~p): ~s before boot",
                   [maps:get(connector_id, Session), Action]),
    event(Action, ReqId, Payload, Session);

dispatch(Action, ReqId, Payload, Session) ->
    event(Action, ReqId, Payload, Session).

%% §3.2: the ack carries `server_time' and nothing else — "timestamps that
%% matter for billing are always taken by the station", and this is how
%% the equipment keeps its own clock honest.
event(<<"heartbeat">>, ReqId, _Payload, Session) ->
    {[ack(ReqId, #{server_time => vs_time:now_ms()})], Session};

event(<<"status">>, _ReqId, Payload, Session) ->
    case cp_status(Payload) of
        {ok, Status} ->
            _ = with_connector(Session,
                               fun(Conn, Pid) -> Conn:cp_status(Pid, Status) end),
            {[], Session};
        error ->
            logger:error("charge point channel (connector ~p): unusable status ~p",
                         [maps:get(connector_id, Session),
                          maps:get(<<"status">>, Payload, undefined)]),
            {[], Session}
    end;

event(<<"plugged">>, _ReqId, Payload, Session) ->
    plugged(Payload, Session);

event(<<"meter">>, _ReqId, Payload, Session) ->
    Reading = #{power_kw   => num(<<"power_kw">>, Payload, 0.0),
                energy_kwh => num(<<"energy_kwh">>, Payload, 0.0),
                soc_pct    => int(<<"soc_pct">>, Payload, 0)},
    _ = with_connector(Session, fun(Conn, Pid) -> Conn:meter(Pid, Reading) end),
    {[], Session};

event(<<"unplugged">>, _ReqId, Payload, Session) ->
    Energy = num(<<"energy_kwh">>, Payload, 0.0),
    _ = with_connector(Session, fun(Conn, Pid) -> Conn:unplugged(Pid, Energy) end),
    {[], Session};

event(Action, _ReqId, _Payload, Session) ->
    logger:warning("charge point channel (connector ~p): unknown action ~p",
                   [maps:get(connector_id, Session), Action]),
    {[], Session}.

%%%===================================================================
%%% §3.1 — boot
%%%===================================================================

%% Everything the equipment needs in order to behave, so that it carries no
%% configuration of its own. In order: bind this socket to the connector
%% (which is what evicts a stale one with 4409), hand the reported physical
%% status over for reconciliation, then read back the limit in force.
%%
%% The cast goes in before the snapshot call on purpose — two messages from
%% this process to that one keep their order, so a charge point that boots
%% `available' onto an out-of-service connector is already back in service
%% by the time the limit is read.
boot(ReqId, Payload, Session = #{connector_id := ConnId}) ->
    case connector(Session) of
        {ok, Pid} ->
            logger:notice("charge point channel: connector ~p booted by ~s ~s "
                          "(firmware ~s, rated ~p kW, status ~s)",
                          [ConnId,
                           bin(<<"vendor">>, Payload), bin(<<"model">>, Payload),
                           bin(<<"firmware">>, Payload),
                           int(<<"rated_kw">>, Payload, 0),
                           bin(<<"status">>, Payload)]),
            ok = attach_to(Session, Pid),
            case cp_status(Payload) of
                {ok, Status} -> (conn_mod(Session)):cp_status(Pid, Status);
                error        -> ok
            end,
            {[boot_ack(ReqId, limit_kw(Session, Pid), Session)],
             Session#{booted := true}};
        {error, Reason} ->
            %% §3.1: "`accepted: false' with a `reason' means the station
            %% does not recognise this connector; the charge point closes
            %% and retries with backoff". The handshake already checked
            %% this, so reaching here means the manager went away between
            %% the upgrade and the first frame — a restart, and backoff is
            %% exactly the right answer to it.
            logger:warning("charge point channel: connector ~p unreachable at "
                           "boot (~p)", [ConnId, Reason]),
            {[ack(ReqId, #{accepted => false,
                           reason   => <<"unknown connector">>})],
             Session}
    end.

%% @doc The `boot' ack of §3.1. Public so the tests read it from the
%% contract's own vocabulary rather than from a literal in two places.
-spec boot_ack(binary(), float(), session()) -> frame().
boot_ack(ReqId, LimitKw, #{heartbeat_interval_s := Hb, meter_interval_s := Meter}) ->
    ack(ReqId, #{accepted             => true,
                 heartbeat_interval_s => Hb,
                 meter_interval_s     => Meter,
                 %% epoch milliseconds, like every timestamp that leaves a
                 %% node in this system (vs_time)
                 server_time          => vs_time:now_ms(),
                 limit_kw             => LimitKw}).

%% 0 when there is no session: the contract's own example boots at
%% `limit_kw: 0' and reads it as "suspended", which is the truth for a
%% connector with nothing plugged into it.
limit_kw(Session, Pid) ->
    try (conn_mod(Session)):snapshot(Pid) of
        Snap ->
            case maps:get(session, Snap, undefined) of
                undefined -> 0.0;
                S         -> float(maps:get(limit_kw, S, 0.0))
            end
    catch exit:Reason ->
            logger:warning("charge point channel: no snapshot for connector ~p "
                           "at boot (~p)", [maps:get(connector_id, Session), Reason]),
            0.0
    end.

%% Bind this process to its connector. Called from the socket process, so
%% `self()' is the socket the connector will send its commands to.
%%
%% **On `boot', not on connect**, and the difference is deliberate. §1 has
%% the newest connection replace the incumbent, and a charge point always
%% boots first (§3.1), so a real reconnection still evicts the stale socket
%% within a millisecond of arriving. Binding at the upgrade instead would
%% let a half-open TCP connection — a port scan, a proxy probe — throw a
%% working charge point off its own connector before saying a single word.
attach_to(Session, Pid) ->
    try (conn_mod(Session)):attach_cp(Pid, self())
    catch exit:Reason ->
            logger:warning("charge point channel: connector ~p refused the "
                           "attach (~p)", [maps:get(connector_id, Session), Reason]),
            ok
    end.

%%%===================================================================
%%% §4.2 — plugged, the one place authorisation happens
%%%===================================================================

%% The payload names a *vehicle*; the connector wants a user. D1: the
%% mapping is 1:1 in the schema (`vehicles.user_id' is unique), so the
%% station resolves it locally instead of asking a coordinator that does
%% not own the table — a path that has to work while the site is isolated.
%%
%% The resolved user only ever matters for a walk-in. On a reserved
%% connector the session opens on the holder, and the state machine
%% overrides whatever arrives here: the equipment has no voice on who is
%% billed (§7.1).
plugged(Payload, Session = #{connector_id := ConnId}) ->
    case int(<<"vehicle_id">>, Payload, undefined) of
        undefined ->
            logger:error("charge point channel (connector ~p): plugged without a "
                         "vehicle_id", [ConnId]),
            {[], Session};
        VehicleId ->
            case max_kw(Payload) of
                {ok, MaxKw} ->
                    with_account(Payload, VehicleId, MaxKw, Session);
                error ->
                    %% §4.2 makes `max_kw' mandatory, and this is the place
                    %% that enforces it. Without it the session would open
                    %% with a ceiling of zero, the allocator would compute a
                    %% demand of zero from it, and the car would sit at zero
                    %% kW for ever with nothing in any log to say why — a
                    %% charge point that is silently broken looking exactly
                    %% like one that is charging.
                    %%
                    %% Refused the way `invalid_state' is refused: loudly,
                    %% with the payload, and with no frame. There is no
                    %% `stop' reason in §5 for "your payload is incomplete",
                    %% and inventing one would widen a contract that is A's;
                    %% the next `status' reconciles (§7.6).
                    logger:error("charge point channel (connector ~p): plugged "
                                 "with no usable max_kw - refused, no session "
                                 "opened. Payload: ~p", [ConnId, Payload]),
                    {[], Session}
            end
    end.

with_account(Payload, VehicleId, MaxKw, Session = #{connector_id := ConnId}) ->
    case user_for_vehicle(Session, VehicleId) of
        {ok, UserId} ->
            authorise(Payload, VehicleId, UserId, MaxKw, Session);
        {error, Reason} ->
            %% Nothing to answer with: refusing would need a `stop'
            %% reason the contract does not have, and the fault is
            %% on this side of the cable. §7.6 — logged, loudly.
            logger:error("charge point channel (connector ~p): no account "
                         "for vehicle ~p (~p)", [ConnId, VehicleId, Reason]),
            {[], Session}
    end.

%% §4.2 — `max_kw' is what the car can take, and it drives both the
%% charging curve and the ceiling of the allocation. Absent, non-numeric or
%% not positive are the same answer: this payload does not say what the
%% hardware can do, so the station has nothing to authorise.
max_kw(Payload) ->
    case int(<<"max_kw">>, Payload, undefined) of
        undefined            -> error;
        Kw when Kw =< 0      -> error;
        Kw                   -> {ok, Kw}
    end.

authorise(Payload, VehicleId, UserId, MaxKw, Session = #{connector_id := ConnId}) ->
    Info = #{user_id     => UserId,
             vehicle_id  => VehicleId,
             soc_pct     => int(<<"soc_pct">>, Payload, 0),
             battery_kwh => num(<<"battery_kwh">>, Payload, 0.0),
             %% validated by max_kw/1 above: never absent, never <= 0
             max_kw      => MaxKw,
             %% §6: a charge point that reconnects after a station restart
             %% brings the energy it has counted, and it is the only side
             %% that counted it.
             energy_kwh  => num(<<"energy_kwh">>, Payload, 0.0)},
    case with_connector(Session, fun(Conn, Pid) -> Conn:plugged(Pid, Info) end) of
        ok ->
            %% No frame from here: the connector sends `set_limit' itself on
            %% entering `charging', so the command reaches the socket by the
            %% same route it will take for every later recomputation.
            {[], Session};
        {error, not_your_reservation} ->
            %% §4.2: the reservation stays, the car is told to stop. The
            %% only refusal on this channel that gets an answer.
            logger:notice("charge point channel: vehicle ~p at connector ~p is "
                          "not the one reserved", [VehicleId, ConnId]),
            {[stop_command(not_your_reservation)], Session};
        {error, invalid_state} ->
            %% §7.6, and §4.2's last row: "the physical state and ours have
            %% diverged, and the station logs it loudly". No command — the
            %% next `status' reconciles, and stopping a car that may be
            %% charging perfectly well would turn our bug into its problem.
            logger:error("charge point channel: plugged on connector ~p, which is "
                         "already charging or closing - physical and logical state "
                         "have diverged", [ConnId]),
            {[], Session};
        {error, Other} ->
            logger:error("charge point channel: connector ~p refused plugged (~p)",
                         [ConnId, Other]),
            {[], Session};
        unreachable ->
            {[], Session}
    end.

user_for_vehicle(#{db_mod := Db}, VehicleId) ->
    try Db:user_for_vehicle(VehicleId)
    catch Class:Reason -> {error, {Class, Reason}}
    end.

%%%===================================================================
%%% §5 — commands
%%%===================================================================

%% @doc A `{cp_cmd, Map}' from the connector, as a wire frame. The
%% connector builds the payload in the contract's own words
%% (`#{command => set_limit, limit_kw => 60.0}'), so this is only the
%% envelope: server-initiated, hence `request_id: null'.
-spec command_frame(map()) -> frame().
command_frame(Payload) ->
    #{type => command, request_id => null, payload => Payload}.

-spec stop_command(atom()) -> frame().
stop_command(Reason) ->
    command_frame(#{command => stop, reason => Reason}).

ack(ReqId, Payload) ->
    #{type => ack, request_id => ReqId, payload => Payload}.

%%%===================================================================
%%% collaborators
%%%===================================================================

conn_mod(#{conn_mod := Conn}) -> Conn.

connector(#{connector_id := ConnId, mgr_mod := Mgr}) ->
    try Mgr:lookup_pid(ConnId)
    catch _:_ -> {error, unknown_connector}
    end.

%% Every event routes itself: look the connector up, then talk to it. The
%% `exit' catch is the same guard the driver channel carries — a connector
%% that dies mid-call must not take the socket with it (scelte §9.4).
with_connector(Session = #{connector_id := ConnId}, Fun) ->
    case connector(Session) of
        {ok, Pid} ->
            try Fun(conn_mod(Session), Pid)
            catch exit:Reason ->
                    logger:warning("charge point channel: connector ~p call failed "
                                   "(~p)", [ConnId, Reason]),
                    unreachable
            end;
        {error, Reason} ->
            logger:warning("charge point channel: no connector ~p right now (~p)",
                           [ConnId, Reason]),
            unreachable
    end.

%%%===================================================================
%%% payload readers
%%%===================================================================

%% Keys are mapped one by one, never with `binary_to_atom': a peer that
%% can mint atoms in this node is a peer that can exhaust the atom table.

%% §4.1 — the four the hardware may report, and nothing else becomes an
%% atom in this node.
cp_status(#{<<"status">> := <<"available">>})   -> {ok, available};
cp_status(#{<<"status">> := <<"occupied">>})    -> {ok, occupied};
cp_status(#{<<"status">> := <<"faulted">>})     -> {ok, faulted};
cp_status(#{<<"status">> := <<"unavailable">>}) -> {ok, unavailable};
cp_status(_Payload)                             -> error.

%% JSON gives integers where the contract says a number, so everything the
%% connector stores as a float is converted here rather than in five
%% places downstream.
num(Key, Payload, Default) ->
    case maps:get(Key, Payload, undefined) of
        V when is_number(V) -> float(V);
        _NotANumber         -> Default
    end.

int(Key, Payload, Default) ->
    case maps:get(Key, Payload, undefined) of
        V when is_integer(V) -> V;
        V when is_float(V)   -> trunc(V);
        _NotANumber          -> Default
    end.

bin(Key, Payload) ->
    case maps:get(Key, Payload, undefined) of
        V when is_binary(V) -> V;
        _Missing            -> <<"?">>
    end.
