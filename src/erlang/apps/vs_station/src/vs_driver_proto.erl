%%%-------------------------------------------------------------------
%%% @doc The driver protocol of contracts/ws-driver.md, with no cowboy
%%% in it.
%%%
%%% Everything that decides something lives here: envelope validation,
%%% the handshake, the at-most-once cache, the dispatch of the three
%%% actions, and the translation of the manager's state into the wire
%%% snapshot of §5.1 and the live session of §5.2. `vs_driver_ws' keeps
%%% only the callbacks — it reads frames off a socket and hands them to
%%% `handle_text/2'.
%%%
%%% **Why the split.** A cowboy handler cannot be exercised from EUnit
%%% without starting a listener and a WebSocket client, and a client
%%% would mean a fourth dependency (`gun') carried for the tests alone.
%%% Split this way, every rule of the contract is an ordinary function
%%% call on an ordinary map, and the tests depend on the contract instead
%%% of on cowboy's shape. It is the same move already made in the
%%% connector with `claim_mod'/`db_mod': `conn_mod', `mgr_mod' and
%%% `claim_mod' are injected here too, so the protocol can be tested
%%% with a stub connector, without a manager and without a coordinator.
%%%
%%% The session is a plain map, threaded through by the caller:
%%%
%%%   authenticated  bound by a successful `join', never by a payload
%%%   user_id        from the token (§7.3) — the client never sends it
%%%   vehicle_id     idem; the claim is per vehicle
%%%   station_id     of this node, for the query-string check
%%%   cache          [{RequestId, ReplyFrames, InsertedAtMs}], newest first
%%%   secret         the HS256 secret; injectable so tests never read env
%%%   lease_seconds  what `reserve' reports to the page
%%%   cache_size,
%%%   cache_ttl_ms   §10; in the session so a test can expire an entry
%%%                  without sleeping a minute
%%%   conn_mod,
%%%   mgr_mod,
%%%   claim_mod      injected collaborators
%%%
%%% Frames are returned as maps and encoded to JSON by the transport:
%%% the tests assert on terms, not on strings, so a reordering of the
%%% keys by the codec can never fail a test about the protocol.
%%%-------------------------------------------------------------------
-module(vs_driver_proto).

-export([new/1, handle_text/2, state_frame/2, wire_state/3,
         session_frame/2, session_push/3,
         coordinator_reachable/1]).

-type frame()      :: map().
-type session()    :: map().
-type close_code() :: 4400 | 4401 | 4408.

-export_type([frame/0, session/0, close_code/0]).

%%%===================================================================
%%% session
%%%===================================================================

%% @doc A fresh, unauthenticated session. Every key has a default, so a
%% test builds one with `new(#{conn_mod => Stub})'.
-spec new(map()) -> session().
new(Opts) ->
    #{authenticated => false,
      user_id       => undefined,
      vehicle_id    => undefined,
      station_id    => opt(station_id, Opts, fun() -> vs_env:get_int("STATION_ID", 1) end),
      cache         => [],
      secret        => opt(secret, Opts, fun vs_jwt:secret/0),
      lease_seconds => opt(lease_seconds, Opts,
                           fun() -> vs_env:get_int("LEASE_SECONDS", 900) end),
      cache_size    => opt(cache_size, Opts,
                           fun() -> vs_env:get_int("REQUEST_CACHE_SIZE", 64) end),
      cache_ttl_ms  => opt(cache_ttl_ms, Opts,
                           fun() -> vs_env:get_int("REQUEST_CACHE_TTL_MS", 60000) end),
      conn_mod      => opt(conn_mod, Opts, fun() -> vs_connector end),
      mgr_mod       => opt(mgr_mod, Opts, fun() -> vs_station_mgr end),
      claim_mod     => opt(claim_mod, Opts, fun() -> vs_claim_client end)}.

%% `maps:get/3' would do, except that Erlang evaluates the default
%% eagerly: every session would read the environment for keys the caller
%% supplied, and `vs_jwt:secret/0' would warn about a secret nobody was
%% going to use. The default is a thunk so it is paid for only when it
%% is needed.
opt(Key, Opts, Default) ->
    case Opts of
        #{Key := Value} -> Value;
        _NotGiven       -> Default()
    end.

%%%===================================================================
%%% the entry point
%%%===================================================================

%% @doc One text frame in, the frames to send out and the new session.
%%
%% The return shape carries frames alongside a close code, which the
%% two-element form of the design note could not express: §3 requires an
%% `error/UNAUTHENTICATED' to be **sent** and only then the socket closed
%% with 4401. A failed `join' is the opposite case — the contract's table
%% gives a close code and no frame — and comes back with an empty list.
-spec handle_text(binary(), session()) ->
          {[frame()], session()} | {close, close_code(), [frame()], session()}.
handle_text(Bin, Session) ->
    case decode(Bin) of
        {ok, Msg} when is_map(Msg) ->
            envelope(Msg, Session);
        {ok, _NotAnObject} ->
            %% Valid JSON, but §2 says every frame is an object. It parsed,
            %% so this is a client that got the shape wrong rather than a
            %% broken stream: answer, do not hang up.
            {[error_frame(null, <<"BAD_REQUEST">>, <<"frame is not an object">>)],
             Session};
        {error, malformed} ->
            %% §3: malformed JSON closes with 4400. Nothing can be echoed —
            %% there is no request_id to correlate an error to.
            {close, 4400, [], Session}
    end.

decode(Bin) ->
    try {ok, jsx:decode(Bin)}
    catch _:_ -> {error, malformed}
    end.

%%%===================================================================
%%% §2 — the envelope
%%%===================================================================

envelope(Msg, Session) ->
    case request_id(Msg) of
        {ok, ReqId} ->
            case payload(Msg) of
                {ok, Payload} -> replayable(action(Msg), ReqId, Payload, Session);
                error -> reply(bad_request(ReqId, <<"payload must be an object">>),
                               Session)
            end;
        error ->
            %% §2: mandatory on every action. With no identifier the reply
            %% cannot be correlated, so it goes out with `null' — the same
            %% value server-initiated frames carry.
            reply(bad_request(null, <<"request_id is mandatory">>), Session)
    end.

request_id(#{<<"request_id">> := ReqId}) when is_binary(ReqId), ReqId =/= <<>> ->
    {ok, ReqId};
request_id(_Msg) ->
    error.

%% §2: "object; `{}' when there is nothing to say, never absent". Both
%% ends of this channel are ours, so the rule is enforced rather than
%% papered over with a default.
payload(#{<<"payload">> := P}) when is_map(P) -> {ok, P};
payload(_Msg)                                 -> error.

action(#{<<"action">> := A}) when is_binary(A) -> A;
action(_Msg)                                   -> undefined.

%%%===================================================================
%%% §2 and §7.2 — at most once
%%%===================================================================

%% The cache is consulted before anything is executed: that is the whole
%% point. A retried `reserve' must return the first reply, not reserve a
%% second time — which is also what the test asserts, by counting the
%% calls the stub connector receives.
replayable(Action, ReqId, Payload, Session) ->
    {Hit, Session1} = cache_lookup(ReqId, Session),
    case Hit of
        {ok, Frames} ->
            {Frames, Session1};
        miss ->
            case dispatch(Action, ReqId, Payload, Session1) of
                {Frames, Session2} ->
                    {Frames, cache_put(ReqId, cacheable(Frames), Session2)};
                {close, Code, Frames, Session2} ->
                    %% Nothing is cached on a close: the connection that
                    %% owns the cache is about to go away.
                    {close, Code, Frames, Session2}
            end
    end.

%% What gets *stored* is the answer, not everything that went out with
%% it. Only `join' returns a second frame — the first `state' — and a
%% snapshot is the one thing that must never be replayed: repeating it a
%% minute later would hand the page a photograph of a station that has
%% moved on, and §7.1 makes that photograph the client's whole truth.
%% The live pushes are what keep the page current; the cache exists so a
%% retried *command* is not executed twice.
cacheable(Frames) ->
    [F || F <- Frames, maps:get(type, F) =/= state].

%% Expired entries are dropped when the cache is touched rather than by a
%% timer: a connection nobody uses has no work to do.
cache_lookup(ReqId, Session = #{cache := Cache}) ->
    Live = purge(Cache, Session),
    Session1 = Session#{cache := Live},
    case lists:keyfind(ReqId, 1, Live) of
        %% A hit does not refresh the entry: the TTL measures the age of
        %% the reply, not the frequency of the retries.
        {ReqId, Frames, _At} -> {{ok, Frames}, Session1};
        false                -> {miss, Session1}
    end.

cache_put(ReqId, Frames, Session = #{cache := Cache, cache_size := Size}) ->
    Live = purge(Cache, Session),
    %% Newest first, so eviction past REQUEST_CACHE_SIZE drops the oldest.
    Session#{cache := lists:sublist([{ReqId, Frames, vs_time:now_ms()} | Live], Size)}.

purge(Cache, #{cache_ttl_ms := Ttl}) ->
    Cutoff = vs_time:now_ms() - Ttl,
    [E || E = {_Id, _Frames, At} <- Cache, At > Cutoff].

%%%===================================================================
%%% §3 and §4 — the handshake and the actions
%%%===================================================================

dispatch(<<"join">>, ReqId, Payload, Session) ->
    join(ReqId, Payload, Session);

%% §3: anything else before a successful join is answered and then cut
%% off. The error frame goes first — a bare close code would leave the
%% page guessing why.
dispatch(_Action, ReqId, _Payload, Session = #{authenticated := false}) ->
    {close, 4401,
     [error_frame(ReqId, <<"UNAUTHENTICATED">>, <<"join first">>)],
     Session};

dispatch(<<"reserve">>, ReqId, Payload, Session) ->
    with_connector(ReqId, Payload, Session, fun do_reserve/4);

dispatch(<<"cancel_reservation">>, ReqId, Payload, Session) ->
    with_connector(ReqId, Payload, Session, fun do_cancel/4);

dispatch(<<"stop_session">>, ReqId, Payload, Session) ->
    with_connector(ReqId, Payload, Session, fun do_stop/4);

%% §6: unknown action. `join_waitlist'/`leave_waitlist' land here on
%% purpose — the waiting list is out of M1 (see the note in ws-driver.md
%% §4.4). Answering BAD_REQUEST is the honest reply: the station really
%% does not know how to do it yet.
dispatch(Action, ReqId, _Payload, Session) ->
    logger:info("driver channel: unsupported action ~p", [Action]),
    reply(bad_request(ReqId, <<"unknown action">>), Session).

%%%===================================================================
%%% join
%%%===================================================================

join(ReqId, Payload, Session = #{secret := Secret}) ->
    case maps:get(<<"token">>, Payload, undefined) of
        Token when is_binary(Token) ->
            joined(vs_jwt:verify(Token, Secret), ReqId, Session);
        _Missing ->
            %% jwt.md §3 puts a malformed token and a missing one in the
            %% same row: 4401.
            {close, 4401, [], Session}
    end.

joined({ok, #{user_id := UserId, vehicle_id := VehicleId}}, ReqId, Session0) ->
    Session = Session0#{authenticated := true,
                        user_id       := UserId,
                        vehicle_id    := VehicleId},
    logger:notice("driver channel: user ~p (vehicle ~p) joined station ~p",
                  [UserId, VehicleId, maps:get(station_id, Session)]),
    %% §3.3: ack and *immediately* a first state, so the page renders
    %% without asking for anything. Only the ack is cached — a replayed
    %% join repeats the answer, not the snapshot, which would be stale by
    %% then anyway and is pushed on every change regardless.
    Ack = ack_frame(ReqId, #{}),
    {[Ack | first_state(Session)], Session};
%% The expiry gets its own close code (jwt.md §3): the page can tell "log
%% in again" from "something is wrong with you".
joined({error, expired}, _ReqId, Session) ->
    {close, 4408, [], Session};
joined({error, Why}, _ReqId, Session) ->
    logger:notice("driver channel: join refused (~p)", [Why]),
    {close, 4401, [], Session}.

first_state(Session) ->
    case station_state(Session) of
        {ok, StateMap} ->
            [state_frame(StateMap, Session)];
        error ->
            %% The manager is momentarily down. The socket stays: the
            %% periodic tick pushes a state as soon as there is one, and
            %% a live connection with a blank page beats a hang-up.
            logger:warning("driver channel: no station state to push on join"),
            []
    end.

%%%===================================================================
%%% the three actions
%%%===================================================================

%% All three take a connector_id and all three must survive the connector
%% being unreachable, so the shared part is factored out rather than
%% copied three times.
with_connector(ReqId, Payload, Session, Fun) ->
    case maps:get(<<"connector_id">>, Payload, undefined) of
        ConnId when is_integer(ConnId), ConnId > 0 ->
            case connector_pid(ConnId, Session) of
                {ok, Pid} ->
                    Fun(Pid, ConnId, ReqId, Session);
                {error, unknown_connector} ->
                    reply(error_frame(ReqId, <<"UNKNOWN_CONNECTOR">>,
                                      <<"connector does not belong to this station">>),
                          Session);
                {error, no_manager} ->
                    reply(error_frame(ReqId, <<"RETRY_LATER">>,
                                      <<"the station is restarting">>),
                          Session);
                %% P13. The row exists and carries `undefined': this
                %% connector IS of this station, its process died and the
                %% supervisor is a few milliseconds behind. It used to
                %% fall into the clause above it and be answered
                %% UNKNOWN_CONNECTOR — a permanent code for something
                %% that lasts an instant, the same mistake as the 4404 of
                %% P4 and the one of P10.
                %%
                %% Same code as `no_manager' and a sentence of its own:
                %% §6 gives the code what the client must DO — try again
                %% in a moment, identical in both — and leaves the
                %% message to say what happened, which is the only part
                %% that differs and the only part a person reads.
                {error, no_pid} ->
                    reply(error_frame(ReqId, <<"RETRY_LATER">>,
                                      <<"the connector is restarting; "
                                        "try again in a moment">>),
                          Session)
            end;
        _Missing ->
            reply(bad_request(ReqId, <<"connector_id must be a positive integer">>),
                  Session)
    end.

do_reserve(Pid, ConnId, ReqId, Session = #{user_id := UserId, vehicle_id := VehicleId,
                                           conn_mod := Conn,
                                           lease_seconds := LeaseSeconds}) ->
    case call_connector(fun() -> Conn:reserve(Pid, UserId, VehicleId) end) of
        {ok, ExpiresAt} ->
            %% §4.1: epoch milliseconds, exactly the value the connector
            %% computed. The page counts down from it and never works out
            %% a deadline of its own.
            reply(ack_frame(ReqId, #{connector_id  => ConnId,
                                     expires_at    => ExpiresAt,
                                     lease_seconds => LeaseSeconds}), Session);
        {error, Refusal} ->
            reply(refusal_frame(ReqId, Refusal, ConnId), Session)
    end.

do_cancel(Pid, ConnId, ReqId, Session = #{user_id := UserId, conn_mod := Conn}) ->
    case call_connector(fun() -> Conn:cancel(Pid, UserId) end) of
        ok ->
            reply(ack_frame(ReqId, #{connector_id => ConnId}), Session);
        {error, Refusal} ->
            reply(refusal_frame(ReqId, Refusal, ConnId), Session)
    end.

do_stop(Pid, ConnId, ReqId, Session = #{user_id := UserId, conn_mod := Conn}) ->
    case call_connector(fun() -> Conn:stop_session(Pid, UserId) end) of
        ok ->
            reply(ack_frame(ReqId, #{connector_id => ConnId}), Session);
        {error, Refusal} ->
            reply(refusal_frame(ReqId, Refusal, ConnId), Session)
    end.

%% **The reason this exists**, measured on the code rather than guessed:
%% `vs_connector:reserve/3' is a `gen_statem:call/2' with the implicit
%% 5000 ms timeout, and inside it `vs_claim_client:acquire/4' runs a
%% discovery pass of up to 3 nodes × CLAIM_CALL_TIMEOUT_MS (2000) plus one
%% retry after `unknown_station' — about 8 s in the worst case. Without
%% this catch the caller exits, the WebSocket process dies with it, and
%% the browser sees a disconnection where it asked a question.
%%
%% `NO_CLAIM' is the honest answer: §4.1 gives that code to "unreachable,
%% timeout, no leader". The connector may still complete the reservation
%% afterwards — the next `state' push will show it, and §7.1 makes the
%% server's snapshot the truth, so the page simply believes it.
call_connector(Fun) ->
    try Fun()
    catch
        exit:Reason ->
            logger:warning("driver channel: connector call failed (~p)", [Reason]),
            {error, no_claim}
    end.

connector_pid(ConnId, #{mgr_mod := Mgr}) ->
    try Mgr:connector_pid(ConnId)
    catch exit:_ -> {error, no_manager}
    end.

%%%===================================================================
%%% §4.1 and §6 — refusals
%%%===================================================================

refusal_frame(ReqId, Refusal, ConnId) ->
    {Code, Message} = refusal(Refusal, ConnId),
    error_frame(ReqId, Code, Message).

refusal(already_held, ConnId) ->
    {<<"ALREADY_HELD">>, bin(["connector ", integer_to_list(ConnId),
                              " is held by another driver"])};
%% The second row of §4.1, and the reason it is worth its own clause: the
%% code is the same NO_CLAIM, but the sentence is what changes the
%% driver's next move — cancel the other reservation, instead of walking
%% down the row of connectors trying each one.
%%
%% P12: it used to end in "elsewhere", and the first case a driver
%% actually meets is the second reservation on the SAME station — two
%% connectors along the row, where the adverb is simply false. It was
%% false only because it was too precise; without it the sentence is true
%% wherever the other reservation is, and still does the job above.
%% Changed here and in the §4.1 table together: a sentence the contract
%% quotes and the code no longer says is a contract that has stopped
%% describing the code.
refusal(vehicle_committed, _ConnId) ->
    {<<"NO_CLAIM">>, <<"your vehicle already holds a reservation">>};
refusal(no_claim, _ConnId) ->
    {<<"NO_CLAIM">>, <<"reservations are unavailable right now">>};
refusal(suspended, _ConnId) ->
    {<<"SUSPENDED">>, <<"the account is serving a no-show penalty; "
                        "walk-in charging still works">>};
refusal(retry_later, _ConnId) ->
    {<<"RETRY_LATER">>, <<"a new coordinator is rebuilding; try again shortly">>};
refusal(not_yours, _ConnId) ->
    {<<"NOT_YOURS">>, <<"that reservation or session belongs to another account">>};
refusal(invalid_state, ConnId) ->
    {<<"INVALID_STATE">>, bin(["connector ", integer_to_list(ConnId),
                               " is not in a state where that applies"])};
%% Deliberately last, and loud. `not_your_reservation' is a real value of
%% `vs_connector:refusal()' with no code in §6, because it is raised by
%% `plugged' — an event of the charge point channel, not of any action a
%% driver can send here. Reaching this clause means something arrived
%% from a direction nobody designed, so it is logged rather than mapped
%% silently onto a code that would read as normal.
refusal(Other, ConnId) ->
    logger:warning("driver channel: unmapped refusal ~p on connector ~p",
                   [Other, ConnId]),
    {<<"INVALID_STATE">>, <<"the action does not apply">>}.

%%%===================================================================
%%% §5.1 — the station snapshot
%%%===================================================================

%% @doc A `state' frame for this session, from a manager state map. Used
%% on join and by the transport on every push and tick.
-spec state_frame(map(), session()) -> frame().
state_frame(StateMap, Session = #{user_id := UserId}) ->
    #{type       => state,
      request_id => null,                       %% §5: server-initiated
      payload    => wire_state(StateMap, UserId, coordinator_reachable(Session))}.

%% @doc Manager state → wire state. A function of three values and
%% nothing else, so the whole of §5.1 can be tested on a map built by
%% hand, with no manager, no connectors and no coordinator.
-spec wire_state(map(), pos_integer() | undefined, boolean()) -> map().
wire_state(StateMap, UserId, CoordReachable) ->
    Connectors = maps:get(connectors, StateMap, []),
    #{station_id            => maps:get(station_id, StateMap, 0),
      name                  => maps:get(name, StateMap, <<>>),
      site_power_kw         => maps:get(site_power_kw, StateMap, 0),
      allocated_kw          => maps:get(allocated_kw, StateMap, 0),
      tariff_cents_kwh      => maps:get(tariff_cents_kwh, StateMap, 0),
      coordinator_reachable => CoordReachable,
      connectors            => [wire_connector(C, UserId) || C <- Connectors],
      %% §4.4 is out of M1: the field is a declared constant rather than
      %% a missing key, so the page renders the same shape it always will.
      waitlist              => #{length => 0, my_position => null}}.

%% A connector the manager sees as down carries three keys only, so every
%% read here has a default: an `offline' entry has no `held_by', no
%% `expires_at' and no `power_kw'.
wire_connector(C, UserId) ->
    HeldBy   = maps:get(held_by, C, undefined),
    Session  = maps:get(session, C, #{}),
    %% §7.3: both flags are computed here from the token's identity, and
    %% are never read from anything the client sent.
    HeldByMe = is_integer(UserId) andalso HeldBy =:= UserId,
    Mine     = HeldByMe orelse
               (is_integer(UserId) andalso maps:get(user_id, Session, undefined) =:= UserId),
    #{connector_id => maps:get(connector_id, C, 0),
      rated_kw     => maps:get(rated_kw, C, 0),
      state        => wire_connector_state(maps:get(state, C, offline)),
      held_by_me   => HeldByMe,
      mine         => Mine,
      expires_at   => null_if_undefined(maps:get(expires_at, C, undefined)),
      power_kw     => maps:get(power_kw, C, 0)}.

%% `offline' is the manager's word for "no process answers for this
%% connector"; the enum of §5.1 does not have it. `out_of_service' is
%% what it means to a driver: it exists, it cannot be used. The other
%% four names of the machine are identical on both sides and pass
%% through, and so — through the catch-all — do the three the connector
%% *derives* rather than lives in: `suspended' since M2 step 2,
%% `complete' and `overstay' since M4. There is one translation to make
%% here and it is `offline'; a whitelist would only be a second place to
%% forget a name in.
wire_connector_state(offline)  -> out_of_service;
wire_connector_state(free)     -> free;
wire_connector_state(held)     -> held;
wire_connector_state(charging) -> charging;
wire_connector_state(closing)  -> closing;
wire_connector_state(Other)    -> Other.

%% jsx renders the atom `undefined' as the string "undefined"; only the
%% atom `null' becomes JSON null. §5.1 wants `expires_at: null', never a
%% missing key and never the word.
null_if_undefined(undefined) -> null;
null_if_undefined(Value)     -> Value.

%%%===================================================================
%%% §5.2 — the live session
%%%===================================================================

%% @doc The `session' frame for the driver on the other end of this
%% socket, or `undefined' when that driver has no session running.
%%
%% Everything it needs is already in the snapshot the socket receives for
%% the `state' frame: the driver's session is the connector entry whose
%% `session' sub-map carries his `user_id'. **No subscription of its own
%% and no call to the manager** — one `lists:search' over data that was
%% passing through anyway. Like `wire_state/3' it is a function of a map
%% and an identity and nothing else, which is what lets the whole of §5.2
%% be exercised in EUnit on maps built by hand.
%%
%% Nothing is sent to a driver who is not charging. §5.2 addresses "the
%% owner of a running session", and a frame of zeroes would be worse than
%% silence: the page could not tell "you have no session" from "your
%% session is stopped".
-spec session_frame(map(), session()) -> frame() | undefined.
session_frame(StateMap, #{user_id := UserId}) when is_integer(UserId) ->
    case lists:search(fun(C) -> owned_by(C, UserId) end,
                      maps:get(connectors, StateMap, [])) of
        {value, Connector} ->
            #{type       => session,
              request_id => null,                   %% §5: server-initiated
              payload    => session_payload(Connector)};
        false ->
            undefined
    end;
%% Before `join' there is no identity to look for. Not an error: the
%% transport asks on every tick, and the ticks of a socket that has not
%% joined yet land here.
session_frame(_StateMap, _Session) ->
    undefined.

%% §7.3 again: the owner is read from the snapshot and compared with the
%% identity the token bound, never with anything the client sent. A
%% connector with no session has no `session' key at all, so the default
%% has to be a map rather than `undefined'.
owned_by(Connector, UserId) ->
    maps:get(user_id, maps:get(session, Connector, #{}), undefined) =:= UserId.

%% A connector snapshot → the §5.2 payload. `power_kw' sits at the top of
%% the snapshot and the rest inside its `session' sub-map — the shape
%% `vs_connector:build_snapshot/2' builds, read here rather than reshaped
%% by the caller, exactly as `vs_power:demand_kw/3' does.
session_payload(Connector) ->
    Session = maps:get(session, Connector, #{}),
    PowerKw = maps:get(power_kw, Connector, 0),
    SocPct  = maps:get(soc_pct, Session, 0),
    #{connector_id     => maps:get(connector_id, Connector, 0),
      phase            => phase(maps:get(state, Connector, charging), SocPct),
      power_kw         => PowerKw,
      energy_kwh       => maps:get(energy_kwh, Session, 0),
      soc_pct          => SocPct,
      eta_seconds      => eta_seconds(maps:get(battery_kwh, Session, 0),
                                      SocPct, PowerKw),
      started_at       => maps:get(started_at, Session, 0),
      %% M4. Read, not computed: the connector owns the grace and the
      %% clock and puts the live net into its own snapshot, so this
      %% channel reports a number rather than deriving a second one that
      %% could disagree with the one written to `sessions'. The default
      %% keeps §5.2's shape for a snapshot that has no such key — a
      %% hand-built map in a test, a session sub-map from an older node —
      %% the same reason `waitlist' is a declared constant in §5.1.
      overstay_seconds => maps:get(overstay_seconds, Session, 0)}.

%% §5.2's enum is `charging | suspended | complete | overstay | closed'.
%% Four of the five are producible from a snapshot: `closed' is not
%% derived at all — it is what `session_push/3' sends once the session has
%% left the snapshot.
%%
%% The order of the clauses is the contract's own precedence, and since M4
%% the first two carry the weight. `complete' and `overstay' are states of
%% the connector, decided by the state machine that owns the session and
%% the clock, and they must win over anything derived here: a session that
%% reached `complete' through a full battery reports `soc_pct: 100' for
%% the whole overstay, so a `soc >= 100' clause read first would say
%% `complete' for ever and `overstay' would never be producible at all.
%%
%% `suspended' is read off the connector's reported state, where M2 step 2
%% already derives it from a limit of zero. It is deliberately **not**
%% derived from a power near zero, and that is §5.2's own reason: zero
%% power is ambiguous between a starved allocation and a deep taper, and
%% the two mean opposite things to whoever is waiting for the car.
%%
%% The `soc >= 100' clause stays, below the two states, and still earns
%% its place: it covers the window between the `meter' that fills the
%% battery and the transition that acts on it, and the case the station
%% cannot act on at all — a car that reports 100 % while the connector is
%% `suspended' by the allocator. `complete' wins over `suspended' there on
%% purpose: a full battery is finished whatever the allocator did with the
%% last few kilowatts, and telling a driver that his full car is "paused"
%% would be a worse answer than none. If `soc_pct' never reaches 100 the
%% phase stays `charging': the station does not know that a car has
%% stopped asking, and saying so is better than simulating it.
phase(complete, _SocPct)                                    -> complete;
phase(overstay, _SocPct)                                    -> overstay;
phase(_State, SocPct) when is_number(SocPct), SocPct >= 100 -> complete;
phase(suspended, _SocPct)                                   -> suspended;
phase(_State, _SocPct)                                      -> charging.

%% §5.2 — how long the rest of the battery takes at the power flowing
%% right now, in seconds.
%%
%% Deliberately raw. The contract: it "is advisory and may jump when
%% another car arrives and the allocation is recomputed — that jump is the
%% visible proof of P5 and should not be smoothed away". So no moving
%% average, no floor and no memory of the previous value: the number the
%% driver sees is the one the current allocation implies, and it jumps
%% because the allocation did.
%%
%% `null' rather than an enormous number when nothing is flowing: an
%% estimate that does not exist is not an estimate of infinity. The atom
%% has to be `null' and not `undefined' — jsx renders the latter as the
%% string "undefined", the same trap `expires_at' has in §5.1.
%%
%% A battery whose size is unknown gets the same answer, and the case is
%% real: ws-chargepoint.md §4.2 makes `max_kw' mandatory in a way it does
%% not make `battery_kwh', so a charge point may legitimately never send
%% it and `vs_cp_proto' reads a missing one as 0.0. Running the formula
%% anyway would print "0 seconds" — "ready now" — over a car that has just
%% been plugged in.
eta_seconds(BatteryKwh, SocPct, PowerKw)
  when is_number(BatteryKwh), BatteryKwh > 0,
       is_number(SocPct),
       is_number(PowerKw), PowerKw > 0 ->
    RemainingKwh = BatteryKwh * max(0, 100 - SocPct) / 100,
    round(RemainingKwh / PowerKw * 3600);
eta_seconds(_BatteryKwh, _SocPct, _PowerKw) ->
    null.

%% @doc The session frames to send alongside a `state', and the frame to
%% remember for the next round.
%%
%% §5.2 asks for one more send "when it ends", and a socket has no other
%% way of noticing the end: the session it was reporting is simply not in
%% the next snapshot. So the last frame sent is carried along — the one
%% piece of state this channel keeps, and it earns it — and becomes a
%% `closed' with the values it had when the session disappears. Without
%% it the page would stop being updated and never learn that it was over,
%% which is the one thing it cannot work out for itself.
%%
%% The transition lives here rather than in the transport for the reason
%% the whole module exists: it is a decision, and a decision is testable
%% in EUnit only when no socket is involved.
-spec session_push(map(), session(), frame() | undefined) ->
          {[frame()], frame() | undefined}.
session_push(StateMap, Session, Last) ->
    case {session_frame(StateMap, Session), Last} of
        {undefined, undefined} -> {[], undefined};
        {undefined, LastFrame} -> {[closed_frame(LastFrame)], undefined};
        {Frame, _Last}         -> {[Frame], Frame}
    end.

%% The values of the last frame with the phase that says it is over, so
%% the page shows the energy and the duration of the session that has just
%% ended instead of freezing on the last live reading.
closed_frame(Frame = #{payload := Payload}) ->
    Frame#{payload := Payload#{phase := closed}}.

%%%===================================================================
%%% collaborators
%%%===================================================================

station_state(#{mgr_mod := Mgr}) ->
    try {ok, Mgr:station_state()}
    catch exit:_ -> error
    end.

%% @doc Whether the last renew round found a coordinator. A dirty read of
%% the claim client's table; `true' when the client is not up yet, which
%% is the optimistic direction on purpose — `acquire' is what really
%% decides, and refusing reservations before the first tick would refuse
%% them for no measured reason.
-spec coordinator_reachable(session()) -> boolean().
coordinator_reachable(#{claim_mod := Claim}) ->
    try Claim:coordinator_reachable()
    catch _:_ -> true
    end.

%%%===================================================================
%%% frames
%%%===================================================================

reply(Frame, Session) -> {[Frame], Session}.

ack_frame(ReqId, Payload) ->
    #{type => ack, request_id => ReqId, payload => Payload}.

error_frame(ReqId, Code, Message) ->
    #{type       => error,
      request_id => ReqId,
      payload    => #{code => Code, message => Message}}.

bad_request(ReqId, Message) ->
    error_frame(ReqId, <<"BAD_REQUEST">>, Message).

bin(IoList) -> iolist_to_binary(IoList).
