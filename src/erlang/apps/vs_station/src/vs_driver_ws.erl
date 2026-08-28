%%%-------------------------------------------------------------------
%%% @doc The cowboy end of the driver channel — callbacks only.
%%%
%%% Everything with a decision in it lives in `vs_driver_proto'; what is
%%% left here is the shape cowboy asks for: read a frame, hand it over,
%%% write back what comes out. The split is what makes the contract
%%% testable in EUnit without a listener and without a WebSocket client
%%% (see the module doc of vs_driver_proto).
%%%
%%% One process per open page. It holds no reservation and no session:
%%% those live in the connector processes and survive the browser being
%%% closed, which is exactly why ws-driver.md §7.5 can put reconnection
%%% entirely on the client and keep no server-side session. The one thing
%%% it does remember is the last `session' frame it sent, and only so that
%%% the final `closed' of §5.2 can be recognised — see `push/2'.
%%%
%%% ## Why the socket is pinged
%%%
%%% cowboy closes a WebSocket after `idle_timeout' (60 s by default) with
%%% **no data received**, and it does not count what the server sends: a
%%% page that has joined and is quietly watching would be hung up on
%%% every minute, and the contract's backoff would turn a healthy station
%%% into a reconnect loop. A `ping' rides along with each state tick; the
%%% browser answers `pong' by itself, and that inbound frame resets the
%%% timer. Setting `idle_timeout => infinity' would have fixed the
%%% symptom and thrown away the cure: with the ping, a peer that has
%%% really gone away stops answering and the timeout does its job.
%%%-------------------------------------------------------------------
-module(vs_driver_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2,
         terminate/3]).

%%%===================================================================
%%% init — still HTTP here
%%%===================================================================

%% §1: `ws://<host>:8080/ws/driver?station_id=<id>'. The query string is
%% checked before anything else, and a mismatch is refused rather than
%% absorbed: a page talking to the wrong station is a bug worth seeing.
%%
%% The refusal cannot happen here — this callback runs on an HTTP request
%% that has not been upgraded yet, and there is no socket to put a close
%% code on. So the upgrade is always accepted and the verdict is carried
%% into `websocket_init/1', which is the first place a close frame can be
%% written. The connection is over in the same millisecond either way.
init(Req, _Opts) ->
    StationId = vs_env:get_int("STATION_ID", 1),
    State = case query_station_id(Req) of
                {ok, StationId} ->
                    {open, vs_driver_proto:new(#{station_id => StationId})};
                {ok, Other} ->
                    logger:notice("driver channel: refused a page for station ~p "
                                  "(this node serves ~p)", [Other, StationId]),
                    {refuse, 4400};
                error ->
                    logger:notice("driver channel: refused a connection with no "
                                  "usable station_id in the query string"),
                    {refuse, 4400}
            end,
    {cowboy_websocket, Req, State, #{idle_timeout => idle_timeout_ms()}}.

query_station_id(Req) ->
    case lists:keyfind(<<"station_id">>, 1, cowboy_req:parse_qs(Req)) of
        {_, Value} when is_binary(Value) ->
            try {ok, binary_to_integer(Value)}
            catch error:badarg -> error
            end;
        _Missing ->
            error
    end.

%%%===================================================================
%%% websocket
%%%===================================================================

websocket_init({refuse, Code}) ->
    {[{close, Code, <<>>}], {refuse, Code}};

websocket_init({open, Session}) ->
    %% The **call**-based subscription, not the cast one: the cast
    %% variant answers by sending the current state and is documented as
    %% the claim client's (vs_station_mgr). Two calls to the same
    %% gen_server are serialised, so nothing can change between them
    %% without also producing a push that lands in this mailbox.
    Seed = try
               ok = vs_station_mgr:subscribe(),
               {ok, vs_station_mgr:station_state()}
           catch exit:Reason ->
               %% The manager is restarting. The socket is worth keeping:
               %% the tick below will find it again.
               logger:warning("driver channel: manager unavailable at connect (~p)",
                              [Reason]),
               error
           end,
    %% §3: a socket that never joins is not a socket, it is a leak.
    _ = erlang:send_after(join_timeout_ms(), self(), join_timeout),
    _ = erlang:send_after(state_tick_ms(), self(), state_tick),
    %% `last_session' starts empty, so a socket whose driver is not
    %% charging sends nothing at all until he is (§5.2, and `push/2').
    {[], #{session => Session, last_state => Seed, last_session => undefined}}.

%% §1: "Frames are text, one JSON object per frame. Binary frames are
%% rejected with close code 4400."
websocket_handle({text, Bin}, State = #{session := Session}) ->
    case vs_driver_proto:handle_text(Bin, Session) of
        {Frames, Session1} ->
            {text_frames(Frames), State#{session := Session1}};
        {close, Code, Frames, Session1} ->
            {text_frames(Frames) ++ [{close, Code, <<>>}], State#{session := Session1}}
    end;

websocket_handle({binary, _Data}, State) ->
    {[{close, 4400, <<>>}], State};

%% cowboy answers pings by itself and hands us the pong of our own ping;
%% both matter only for having arrived, which cowboy has already noted by
%% resetting the idle timer.
websocket_handle(_Frame, State) ->
    {[], State}.

%% An event-driven push: something actually changed. §7.1 — a complete
%% snapshot every time, never a delta.
websocket_info({station_state, Map}, State) ->
    {Frames, State1} = push(Map, State),
    {Frames, State1#{last_state := {ok, Map}}};

%% The heartbeat of §5.1, and the reason it is not redundant with the
%% pushes above: meter readings reach the connector as casts that change
%% `power_kw' **without** raising a connector event, so an event-only
%% channel would show a live session at a frozen power. The tick re-reads
%% instead of replaying the cached snapshot for exactly that reason.
websocket_info(state_tick, State = #{last_state := Last}) ->
    _ = erlang:send_after(state_tick_ms(), self(), state_tick),
    Current = try {ok, vs_station_mgr:station_state()}
              catch exit:_ -> Last          %% manager restarting: repeat the last one
              end,
    {Frames, State1} = case Current of
                           {ok, Map} -> push(Map, State);
                           error     -> {[], State}
                       end,
    %% Rides with the tick rather than on a timer of its own: one timer,
    %% and the pong that comes back is what keeps cowboy's idle timeout
    %% from hanging up on a page that is only watching.
    {Frames ++ [ping], State1#{last_state := Current}};

%% §3: "4401 — ... or no join within JOIN_TIMEOUT_MS (5 s)."
websocket_info(join_timeout, State = #{session := Session}) ->
    case maps:get(authenticated, Session) of
        true  -> {[], State};
        false -> {[{close, 4401, <<>>}], State}
    end;

%% §3: 1001 when the station is shutting down, so the page knows to come
%% back with backoff instead of showing an error. Sent by
%% vs_station_app:stop/1 before the listener goes.
websocket_info(station_shutdown, State) ->
    {[{close, 1001, <<>>}], State};

websocket_info(Info, State) ->
    logger:debug("driver channel ignoring ~p", [Info]),
    {[], State}.

%% No unsubscribe: the manager monitors its subscribers and drops them on
%% DOWN, which is the only path that also covers a socket that dies
%% without terminating politely.
terminate(_Reason, _Req, _State) ->
    ok.

%%%===================================================================
%%% internal
%%%===================================================================

%% One snapshot in, both server-initiated frames out.
%%
%% The `session' of §5.2 rides with the `state' of §5.1 — same tick, same
%% pushes, same send — rather than on a timer of its own. A second timer
%% would be a second wake-up per socket and, worse, two frames describing
%% two different instants of the same station: the page would show a power
%% read at one moment next to an energy read at another. `SESSION_TICK_MS'
%% is declared in §10 with the same default as `STATE_TICK_MS' precisely
%% so that one timer can serve both.
%%
%% `last_session' is the one thing this process remembers. §5.2 asks for a
%% final frame when the session ends, and the only way a socket learns of
%% the end is that the session it was reporting is no longer in the
%% snapshot; `vs_driver_proto:session_push/3' is what turns that
%% disappearance into the `closed' frame. Note that the tick above repeats
%% the *previous* snapshot while the manager is restarting, so a manager
%% that blinks cannot fake the end of somebody's charge.
push(Map, State = #{session := Session, last_session := LastSession}) ->
    case maps:get(authenticated, Session) of
        true ->
            %% Translated per connection: `held_by_me' and `mine' depend
            %% on who is watching (§5.1), so the same manager snapshot
            %% becomes a different frame on every socket. §5.2 goes
            %% further and produces nothing at all for a driver who is not
            %% the owner of a running session.
            {SessionFrames, LastSession1} =
                vs_driver_proto:session_push(Map, Session, LastSession),
            {text_frames([vs_driver_proto:state_frame(Map, Session) | SessionFrames]),
             State#{last_session := LastSession1}};
        false ->
            %% Before `join' there is nobody to compute an identity for.
            {[], State}
    end.

text_frames(Frames) ->
    [{text, jsx:encode(F)} || F <- Frames].

%%%===================================================================
%%% configuration — ws-driver.md §10
%%%===================================================================

join_timeout_ms() -> vs_env:get_int("JOIN_TIMEOUT_MS", 5000).
state_tick_ms()   -> vs_env:get_int("STATE_TICK_MS", 5000).

%% Comfortably longer than the tick, so a pong is always due before it
%% fires; short enough that a socket whose peer vanished without a FIN is
%% reaped in about a minute.
idle_timeout_ms() -> vs_env:get_int("WS_IDLE_TIMEOUT_MS", 60000).
