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
%%%   conn_pid, conn_mon    the connector this socket attached to, and the
%%%                         monitor on it. NOT a routing cache — see below
%%%   reattach_ms,
%%%   reattach_tries_max,
%%%   reattach_tries        the reattach of §6, and how far it has got
%%%   last_status,
%%%   last_plugged,
%%%   last_meter            the hardware's last word, kept for that same
%%%                         reconciliation (see "What this socket
%%%                         remembers" below)
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
%%%
%%% `conn_pid' does **not** change that. Every event still routes through a
%%% fresh `lookup_pid/1'; the pid is remembered only so that the monitor
%%% below has something to be about, and so that the reattach can tell "the
%%% connector came back as a new process" from "the registry still holds
%%% the one that just died". Routing never reads it.
%%%
%%% ## Why this socket reattaches, and what it remembers to do it
%%%
%%% The surveillance used to run one way only: the connector monitors the
%%% socket and starts the grace of §3.2 when it dies. The return direction
%%% was missing, and the hole it left was the quietest defect in the
%%% system. When the **connector** is the one that dies, `vs_connector_sup'
%%% restarts it with a new pid and `cp = undefined', while the TCP socket
%%% of the charge point is perfectly healthy and has no reason to
%%% reconnect. Measured, not deduced (a walk-in on connector 3, then
%%% `exit(Pid, kill)' from the shell):
%%%
%%%   * the registry heals within a second, so the meters do reach the new
%%%     connector — and it has no session, so every one of them becomes a
%%%     "meter for a connector with no session (state free)" line and is
%%%     dropped;
%%%   * the new connector's `cp' is `undefined', so `send_cp/2' is a no-op:
%%%     no `set_limit' and no `stop' can reach the hardware ever again;
%%%   * the car goes on drawing 150 kW while the station shows the
%%%     connector `free', and the final `unplugged' lands on an idle
%%%     connector and is ignored (§4.4) — the `sessions' row is never
%%%     written and the energy is never billed.
%%%
%%% So the socket monitors the connector it attached to. On the `DOWN' it
%%% waits `reattach_ms' — an `erlang:send_after', never a blocking wait:
%%% this process must go on reading frames — then looks the pid up again
%%% and reattaches, up to `reattach_tries_max' times, and gives up with a
%%% 1012: the connector is missing for now, not for ever, and §1 keeps the
%%% two apart on purpose (see `retry/2').
%%%
%%% Reattaching is not enough on its own: the new connector has no memory,
%%% and the hardware does. That is exactly the reconciliation §6 describes
%%% for "the station restarted" — here the station is alive and only one
%%% connector was reborn, but from that connector's point of view the
%%% situation is identical. §6.2 has the equipment resend its true `status'
%%% and, under a live session, a `plugged' with the cumulative energy; this
%%% socket replays the two on its behalf, which is why it keeps
%%% `last_status', `last_plugged' and `last_meter'. It is the only state
%%% this process holds beyond the handshake, and it is justified by being
%%% *the same copy the charge point would send if it reconnected* — kept on
%%% this side so the hardware is not asked to redo something it has already
%%% done. `last_plugged' and `last_meter' are dropped on `unplugged',
%%% because after that the copy would describe a cable that is out.
%%%
%%% The session that comes back is a **walk-in adoption**: §6 says
%%% rebuilding the reservation is deliberately not attempted, so the hold
%%% is gone and the account is resolved from the vehicle, exactly as for a
%%% car that never reserved.
%%%-------------------------------------------------------------------
-module(vs_cp_proto).

-export([new/1, handshake/2, handle_text/2, handle_info/2,
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
      %% The connector we are attached to and watching. Never read to
      %% route an event — see the module doc.
      conn_pid     => undefined,
      conn_mon     => undefined,
      reattach_ms  => opt(reattach_ms, Opts, fun reattach_ms/0),
      reattach_tries_max =>
          opt(reattach_tries_max, Opts, fun reattach_tries_max/0),
      reattach_tries => 0,
      %% The hardware's last word, for the reconciliation of §6.
      last_status  => undefined,
      last_plugged => undefined,
      last_meter   => undefined,
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
%% handshake with close code 4404" (§1) — and P10 made that sentence true
%% of the code as well. Three ways to earn the refusal, and the log line
%% says which: a query string that does not parse, a station that is not
%% this node, and a connector this station does not own.
%%
%% The last is decided by the dirty read, never by a call to the manager:
%% a charge point dialling in while the manager is booting must not queue
%% behind it. That read used to answer "not mine" to "the registry is not
%% there yet" and to "the connector died a moment ago" too, and the socket
%% turned all three into 4404 — the permanent code, the one cp.js dies on.
%% The comment here argued, correctly, that the honest answer to a
%% temporary fact is "come back later"; the code sent "never come back".
%%
%% Now `no_pid' and `no_manager' are ADMITTED: the socket is opened and
%% the boot of §3.1 answers, which is the one place in this contract that
%% can say `accepted: false' with a reason and let the equipment retry on
%% its own backoff. In the ordinary case the supervisor has rebuilt the
%% connector by then and the boot simply attaches.
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
                {error, Temporary} when Temporary =:= no_pid;
                                        Temporary =:= no_manager ->
                    %% Configured, just not servable this instant. §3.1 is
                    %% the answer, not §1: admit and let the boot speak.
                    logger:notice("charge point channel: connector ~p admitted "
                                  "with nothing behind it yet (~p) - the boot "
                                  "will answer", [ConnId, Temporary]),
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
%% this socket. The three close codes of §1 all come from elsewhere — 4404
%% from the handshake above, 4409 from the connector telling this process
%% it has been replaced, 1012 from the reattach giving up (`retry/2').
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
            %% Remembered for the replay of §6.2: a connector reborn under
            %% a live socket has to be told the physical state again, and
            %% the hardware only sends it on change.
            {[], Session#{last_status := Status}};
        error ->
            logger:error("charge point channel (connector ~p): unusable status ~p",
                         [maps:get(connector_id, Session),
                          maps:get(<<"status">>, Payload, undefined)]),
            {[], Session}
    end;

%% Remembered **whatever the station makes of it**, and on purpose: the
%% copy is here to stand in for the one the charge point would resend, and
%% the charge point resends it whenever the cable is in — it has no idea
%% whether we authorised anything (§7.1, the equipment reports and the
%% station decides). A `plugged' that was refused here is refused again on
%% the replay, which is the honest outcome rather than a silent one.
event(<<"plugged">>, _ReqId, Payload, Session) ->
    plugged(Payload, Session#{last_plugged := Payload});

event(<<"meter">>, _ReqId, Payload, Session) ->
    Reading = #{power_kw   => num(<<"power_kw">>, Payload, 0.0),
                energy_kwh => num(<<"energy_kwh">>, Payload, 0.0),
                soc_pct    => int(<<"soc_pct">>, Payload, 0)},
    _ = with_connector(Session, fun(Conn, Pid) -> Conn:meter(Pid, Reading) end),
    {[], Session#{last_meter := Payload}};

%% The cable is out. The copy of §6.2 is dropped with it — kept, it would
%% describe a car that is no longer there, and the next reattach would
%% open a session for it.
event(<<"unplugged">>, _ReqId, Payload, Session) ->
    Energy = num(<<"energy_kwh">>, Payload, 0.0),
    _ = with_connector(Session, fun(Conn, Pid) -> Conn:unplugged(Pid, Energy) end),
    {[], Session#{last_plugged := undefined, last_meter := undefined}};

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
            Session1 = attach_to(Session, Pid),
            Session2 = case cp_status(Payload) of
                           {ok, Status} ->
                               (conn_mod(Session1)):cp_status(Pid, Status),
                               Session1#{last_status := Status};
                           error ->
                               Session1
                       end,
            {[boot_ack(ReqId, limit_kw(Session2, Pid), Session2)],
             Session2#{booted := true}};
        {error, Reason} ->
            %% §3.1: "`accepted: false' with a `reason' ... the charge
            %% point closes and retries with backoff". Since P10 this is
            %% not only the manager-vanished-between-upgrade-and-boot
            %% race: the handshake now ADMITS a connector that is merely
            %% without a process, and this is where that socket gets its
            %% answer.
            %%
            %% `accepted: false' for all three reasons on purpose, the
            %% permanent one included. `unknown_connector' can only reach
            %% here if the manager restarted with a different
            %% configuration between the upgrade and the first frame;
            %% refusing the boot and letting the 4404 arrive at the NEXT
            %% handshake is simpler than a second place in this module
            %% that closes 4404, and costs the equipment one reconnect.
            %% The `reason' is what tells the two apart, and it is the
            %% only part of the ack a charge point can read: cp.js logs
            %% it and closes either way (§3.1).
            logger:warning("charge point channel: connector ~p unreachable at "
                           "boot (~p)", [ConnId, Reason]),
            {[ack(ReqId, #{accepted => false,
                           reason   => boot_refusal(Reason)})],
             Session}
    end.

%% The two natures of §3.1's `reason', in the contract's own words.
boot_refusal(no_pid)     -> <<"connector not ready">>;
boot_refusal(no_manager) -> <<"connector not ready">>;
boot_refusal(_Permanent) -> <<"unknown connector">>.

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
%%
%% A refused attach is logged and the session goes on unwatched: `boot' has
%% an ack to produce and a charge point that cannot be bound is one the
%% handshake already said we own, so the honest answer is a log line rather
%% than a dead socket. The next `boot' — the equipment retries — binds it.
attach_to(Session, Pid) ->
    case attach(Session, Pid) of
        {ok, Session1} ->
            Session1;
        {error, Reason} ->
            logger:warning("charge point channel: connector ~p refused the "
                           "attach (~p)", [maps:get(connector_id, Session), Reason]),
            Session
    end.

%% Attach **and watch**. The monitor is the return direction of the
%% surveillance: the connector has watched this socket since M2 step 1, and
%% this is how the socket learns that the connector died under it.
%%
%% `demonitor(..., [flush])' on the way in for the same reason
%% `vs_connector:attach/2' has one: without the flush, the `DOWN' of the
%% connector we are replacing may already be in the mailbox, and it would
%% start a reattach cycle against a connector we are attached to already.
attach(Session, Pid) ->
    try (conn_mod(Session)):attach_cp(Pid, self()) of
        ok ->
            Session1 = demonitor_connector(Session),
            Ref = erlang:monitor(process, Pid),
            {ok, Session1#{conn_pid       := Pid,
                           conn_mon       := Ref,
                           reattach_tries := 0}}
    catch exit:Reason ->
            {error, Reason}
    end.

demonitor_connector(Session = #{conn_mon := undefined}) ->
    Session;
demonitor_connector(Session = #{conn_mon := Ref}) ->
    _ = erlang:demonitor(Ref, [flush]),
    Session#{conn_mon := undefined}.

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

%% §6 — the other half of the reconciliation, and the opposite of `max_kw'
%% in every way that matters. `max_kw' is mandatory and its absence refuses
%% the session; this one is **optional and must stay optional**, because
%% §6 promises a contract that equipment unable to answer the question can
%% still implement. Absent or not positive, the key is simply not in the
%% map and `vs_connector' starts the session the way it always has.
%%
%% Adding the key rather than defaulting it to zero is what makes that
%% promise structural instead of conventional: every payload that does not
%% carry the field builds the **same map, key for key**, that it built
%% before the field existed, so no path can drift into depending on it.
with_charging_seconds(Info, Payload, ConnId) ->
    case charging_seconds(Payload) of
        {ok, Secs} -> Info#{charging_seconds => Secs};
        error      -> Info;
        {error, Secs} ->
            %% Positive but not a duration this station can have lived
            %% through: subtracting it would date the session before the
            %% epoch. §7.6 — said out loud, and the field is dropped rather
            %% than clamped, because a clamped duration is a plausible
            %% number that is false.
            logger:error("charge point channel (connector ~p): plugged with an "
                         "impossible charging_seconds (~p) - ignored, started_at "
                         "will be the instant of the adoption", [ConnId, Secs]),
            Info
    end.

charging_seconds(Payload) ->
    case int(<<"charging_seconds">>, Payload, undefined) of
        undefined       -> error;
        %% "absent or not positive" is one answer in §6, so a zero from a
        %% cable that has just gone in is not a divergence and says nothing
        Secs when Secs =< 0 -> error;
        Secs ->
            case Secs * 1000 < vs_time:now_ms() of
                true  -> {ok, Secs};
                false -> {error, Secs}
            end
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
    Info1 = with_charging_seconds(Info, Payload, ConnId),
    case with_connector(Session, fun(Conn, Pid) -> Conn:plugged(Pid, Info1) end) of
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
            %%
            %% This is also the ordinary landing place of the §6.2
            %% re-announcement: a charge point whose socket blipped under a
            %% live session boots, re-sends its `plugged', and the connector
            %% — which never left `charging' (or, since M4, `complete') —
            %% refuses it here. Nothing is lost by that: the `attach_cp' of
            %% the boot has already cancelled the connector's grace timer,
            %% and the session, its energy and its overstay clock were never
            %% touched. The line is a divergence report, not a failure.
            logger:error("charge point channel: plugged on connector ~p, which "
                         "already has a session (charging, complete or closing) - "
                         "physical and logical state have diverged", [ConnId]),
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
%%% §6 — the connector died under us: reattach and reconcile
%%%===================================================================

%% @doc The messages that are not frames: the `DOWN' of the connector this
%% socket is attached to, and the timer that retries the reattach.
%%
%% Same two shapes as `vs_driver_proto:handle_text/2', because the caller
%% has the same two things to do with them: write the frames, or write the
%% frames and then close.
-spec handle_info(term(), session()) ->
          {[frame()], session()} | {close, 1012, [frame()], session()}.

%% The connector is gone. Not the socket's death — this process is fine,
%% and so is the cable — so nothing is torn down: a timer is armed and the
%% socket goes straight back to reading frames. The meters that arrive in
%% the meantime are dropped by the reborn connector with the "no session"
%% line of §4.3, which is the correct thing for it to say until the
%% reconciliation below tells it otherwise.
handle_info({'DOWN', Ref, process, Pid, Reason},
            Session = #{conn_mon := Ref, connector_id := ConnId,
                        reattach_ms := Ms}) ->
    logger:warning("charge point channel: connector ~p (~p) died under a live "
                   "socket (~p) - reattaching in ~p ms", [ConnId, Pid, Reason, Ms]),
    _ = erlang:send_after(Ms, self(), cp_reattach),
    %% `conn_pid' is deliberately kept, dead as it is: it is what the next
    %% lookup is compared against.
    {[], Session#{conn_mon := undefined, reattach_tries := 0}};

%% A monitor we no longer hold — the connector we replaced, or one whose
%% `DOWN' outran the `demonitor'. Nothing to repair.
handle_info({'DOWN', _Ref, _Type, _Pid, _Reason}, Session) ->
    {[], Session};

handle_info(cp_reattach, Session = #{conn_pid := undefined}) ->
    %% Never attached, so there is nothing to reattach to. Only reachable
    %% from a timer that outlived its reason; said out loud rather than
    %% silently absorbed (§7.6).
    logger:notice("charge point channel (connector ~p): reattach timer with no "
                  "connector to go back to", [maps:get(connector_id, Session)]),
    {[], Session};

handle_info(cp_reattach, Session = #{conn_pid := Dead, connector_id := ConnId}) ->
    case connector(Session) of
        {ok, Pid} when Pid =/= Dead ->
            reattach(Pid, Session);
        {ok, Dead} ->
            %% The registry still holds the process that died: the
            %% manager's own `DOWN' has not been handled yet. Not back.
            retry(Session, "the registry still names the connector that died");
        {error, Reason} ->
            retry(Session, io_lib:format("no connector ~p yet (~p)",
                                         [ConnId, Reason]))
    end;

handle_info(Info, Session) ->
    logger:debug("charge point channel (connector ~p) ignoring ~p",
                 [maps:get(connector_id, Session), Info]),
    {[], Session}.

%% A new process for this connector. Attach first and reconcile after, and
%% the order carries weight: the replayed `plugged' takes the connector
%% into `charging', whose entry callback sends the interim `set_limit'
%% through `send_cp/2'. Reconciling before attaching would drop that
%% command into a `cp = undefined' and leave the car on the limit it
%% happened to be holding until the manager's next tick.
reattach(Pid, Session = #{connector_id := ConnId}) ->
    case attach(Session, Pid) of
        {ok, Session1} ->
            logger:notice("charge point channel: connector ~p is back as ~p - "
                          "reattached", [ConnId, Pid]),
            reconcile(Pid, Session1);
        {error, Reason} ->
            %% It was alive a moment ago and is not now. Same answer as
            %% "not there yet": the supervisor is still working.
            retry(Session, io_lib:format("connector ~p refused the attach (~p)",
                                         [Pid, Reason]))
    end.

%% §6.2 — "It sends `boot' with its true `status' and, if a session is
%% running, a `plugged' with the vehicle and the cumulative energy it has
%% counted." The charge point is not asked to do it again; this socket has
%% the same two things written down and says them on its behalf.
%%
%% No `boot' of our own: `boot' is a frame the equipment sends and this
%% side answers, and the connector never sees one — what it sees is the
%% `attach_cp' that has just happened and the two events below.
reconcile(Pid, Session = #{connector_id := ConnId, last_status := Status,
                           last_plugged := Plugged, last_meter := Meter}) ->
    case Status of
        undefined -> ok;
        _         -> (conn_mod(Session)):cp_status(Pid, Status)
    end,
    case Plugged of
        undefined ->
            logger:notice("charge point channel: connector ~p reconciled to "
                          "status ~p, nothing plugged in", [ConnId, Status]),
            {[], Session};
        _ ->
            Replay = replayed_plugged(Plugged, Meter),
            logger:notice("charge point channel: connector ~p reconciled to "
                          "status ~p, re-announcing vehicle ~p with ~p kWh",
                          [ConnId, Status,
                           int(<<"vehicle_id">>, Replay, undefined),
                           num(<<"energy_kwh">>, Replay, 0.0)]),
            %% Straight through the ordinary `plugged' path: the account is
            %% resolved from the vehicle, `max_kw' is insisted on, and the
            %% state machine authorises. A reborn connector is `free', so
            %% this is a walk-in — which is §6's answer in full: the claim
            %% is not rebuilt, the car keeps charging, the session is
            %% billed. Whatever frames that path produces are the caller's
            %% to send, exactly as for a live `plugged'.
            plugged(Replay, Session)
    end.

%% What the charge point would put in the `plugged' of §6.2: the vehicle it
%% announced when the cable went in, and the cumulative it has counted
%% since. §4.3 makes that cumulative monotonic, so the `max' can only ever
%% pick the meter; it is written as a `max' because that is the rule the
%% contract states, not because the two could arrive out of order.
%%
%% `charging_seconds' is the one field of the copy that goes **stale**, and
%% it is dropped rather than replayed. The energy can be refreshed from the
%% meter that arrived a moment ago; a duration cannot — the hardware states
%% it once, and by the time this replay happens it has grown by however
%% long the copy has been sitting here. Sending the old number would date
%% the session too late by exactly that much: a plausible figure that is
%% false, which §6 already prefers to avoid over a visibly wrong one. Left
%% out, the adoption falls back to its instant, which is where every
%% adoption started before the field existed.
%%
%% The socket could keep the number honest by writing down when the frame
%% arrived, and that is a second piece of state on the most delicate
%% boundary of this milestone for a path the equipment cannot even see.
%% Noted in scelte_di_progetto.md instead, next to the defect it is a
%% narrower survivor of.
replayed_plugged(Plugged, undefined) ->
    maps:remove(<<"charging_seconds">>, Plugged);
replayed_plugged(Plugged, Meter) ->
    (maps:remove(<<"charging_seconds">>, Plugged))#{
      <<"energy_kwh">> => max(num(<<"energy_kwh">>, Plugged, 0.0),
                              num(<<"energy_kwh">>, Meter, 0.0)),
      <<"soc_pct">>    => int(<<"soc_pct">>, Meter,
                              int(<<"soc_pct">>, Plugged, 0))}.

%% Not back yet. One more timer until the budget runs out, then 1012.
%%
%% Closing beats hanging on — a socket bound to nothing accepts frames it
%% can do nothing with, while a charge point that is hung up on reconnects
%% on its own (§6.1) and boots against whatever the station has by then.
%%
%% **1012 (Service Restart), and not the 4404 this used to send.** The old
%% code read the situation as "this station has no such connector", which
%% after `reattach_tries_max' attempts is literally true and was still the
%% wrong thing to say: §1 gives 4404 to a **permanent** condition — the
%% connector is not this station's — and equipment that believes it has no
%% reason ever to come back. Our own emulator read it exactly that way and
%% died on it (`cp.js', `die(...)'), so the sentence this branch ends with,
%% "the charge point will reconnect", was false against the one charge
%% point we have. The condition here is temporary: a connector process died
%% and its supervisor is behind. 1012 is the standard code for precisely
%% that, it falls into the ordinary backoff branch of any client, and a
%% charge point that has never heard of connector processes does the right
%% thing without being taught anything.
retry(Session = #{connector_id := ConnId, reattach_tries := Tries,
                  reattach_tries_max := Max, reattach_ms := Ms}, Why) ->
    case Tries + 1 of
        N when N >= Max ->
            logger:error("charge point channel: connector ~p did not come back "
                         "in ~p attempts (~s) - closing 1012, the charge point "
                         "will reconnect", [ConnId, N, Why]),
            {close, 1012, [], Session#{reattach_tries := N}};
        N ->
            logger:notice("charge point channel: connector ~p not back yet "
                          "(~s), attempt ~p of ~p", [ConnId, Why, N, Max]),
            _ = erlang:send_after(Ms, self(), cp_reattach),
            {[], Session#{reattach_tries := N}}
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

%%%===================================================================
%%% configuration
%%%===================================================================

%% Deliberately **not** in ws-chargepoint.md §10, and the same rule as the
%% allocator's two variables (scelte §12.8): §10 configures the wire — what
%% the equipment is told and what it is held to — while these two describe
%% how the station repairs itself behind that wire. A charge point neither
%% knows nor needs to know that a connector process was reborn under it.
%% They are written up in scelte_di_progetto.md instead.

%% Long enough for `simple_one_for_one' to have run the child's `init/1'
%% and for the manager to have handled its own `DOWN' and the
%% `connector_up' behind it — measured at well under a second — and short
%% enough that the car spends a fraction of one meter interval unattached.
reattach_ms() -> vs_env:get_int("CP_REATTACH_MS", 500).

%% Five attempts, so two and a half seconds. Past that the supervisor has
%% not merely been slow, it has given up (`intensity 5, period 10'), and
%% waiting longer only keeps a socket bound to nothing.
reattach_tries_max() -> vs_env:get_int("CP_REATTACH_TRIES", 5).
