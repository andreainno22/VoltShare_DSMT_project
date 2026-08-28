%%%-------------------------------------------------------------------
%%% @doc The cowboy end of the charge point channel — callbacks only.
%%%
%%% Same split as `vs_driver_ws': everything with a decision in it lives in
%%% `vs_cp_proto', what is left here is the shape cowboy asks for. One
%%% process per connector, because ws-chargepoint.md §1 gives each
%%% connector its own socket — "it costs a few file descriptors and buys a
%%% direct mapping from socket to owning process, which is the shape the
%%% actor model wants".
%%%
%%% ## Why there is no ping here, and the driver channel has one
%%%
%%% The two channels use cowboy's `idle_timeout' for opposite purposes. A
%%% driver's page can sit and watch for an hour without saying anything, so
%%% the timeout would hang up on a healthy browser and `vs_driver_ws' rides
%%% a `ping' along with each tick to keep it alive. A charge point is the
%%% other way round: the contract already obliges it to speak — a
%%% `heartbeat' every 30 s, a `meter' every 5 s while charging — so the
%%% timeout *is* the "three missed heartbeats" rule of §3.2. It counts only
%%% inbound traffic (measured in M1), which is exactly the semantics
%%% wanted: equipment that is charging and reporting never expires,
%%% equipment that has gone quiet does, after 3 x 30 s.
%%%
%%% Silence is therefore not handled here at all. The socket dies of its
%%% own timeout, the connector sees the `DOWN' and starts its grace timer,
%%% and the verdict is that one process's — the one that owns the outlet.
%%%-------------------------------------------------------------------
-module(vs_cp_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2,
         terminate/3]).

%%%===================================================================
%%% init — still HTTP here
%%%===================================================================

%% §1: `ws://<station-host>:8081/ws/cp?station_id=<id>&connector_id=<n>'.
%%
%% As on the driver channel, the verdict is computed here and carried into
%% `websocket_init/1': this callback runs on an HTTP request that has not
%% been upgraded, and there is no socket yet to put a close code on.
init(Req, _Opts) ->
    State = case vs_cp_proto:handshake(cowboy_req:parse_qs(Req), #{}) of
                {ok, Session}  -> {open, Session};
                {refuse, Code} -> {refuse, Code}
            end,
    {cowboy_websocket, Req, State, #{idle_timeout => idle_timeout_ms()}}.

%%%===================================================================
%%% websocket
%%%===================================================================

%% §1: "A connector id that does not belong to station_id is refused at
%% the handshake with close code 4404."
websocket_init({refuse, Code}) ->
    {[{close, Code, <<>>}], {refuse, Code}};

%% Nothing is sent on connect: §3.1 makes `boot' the first frame and the
%% station answers rather than opens.
websocket_init({open, Session}) ->
    {[], #{session => Session}}.

%% §1: "Frames are text, one JSON object each."
websocket_handle({text, Bin}, State = #{session := Session}) ->
    {Frames, Session1} = vs_cp_proto:handle_text(Bin, Session),
    {text_frames(Frames), State#{session := Session1}};

websocket_handle({binary, _Data}, State) ->
    logger:error("charge point channel: binary frame on a text-only channel"),
    {[], State};

websocket_handle(_Frame, State) ->
    {[], State}.

%% §5 — commands. They come from the connector as `{cp_cmd, Payload}',
%% already in the contract's vocabulary, so nothing is decided here.
websocket_info({cp_cmd, Payload}, State) when is_map(Payload) ->
    {text_frames([vs_cp_proto:command_frame(Payload)]), State};

%% §1: "The old socket is closed with 4409." Sent by the connector when a
%% newer socket has taken this connector over.
websocket_info({cp_replaced}, State) ->
    {[{close, 4409, <<>>}], State};

%% The station is going away. The equipment is told to stop delivering
%% before the listener disappears, because after that there is nobody left
%% to tell — and a car left drawing power from a station that no longer
%% counts it is the one outcome §7.3 rules out. The frame goes first, the
%% close after: cowboy writes the list in order.
websocket_info(station_shutdown, State) ->
    {text_frames([vs_cp_proto:stop_command(station_shutdown)])
     ++ [{close, 1001, <<>>}], State};

websocket_info(Info, State) ->
    logger:debug("charge point channel ignoring ~p", [Info]),
    {[], State}.

%% Nothing to unwind: the connector monitors this process and starts the
%% grace of §3.2 on the `DOWN', which covers a socket that dies without
%% terminating politely as well as one that does.
terminate(_Reason, _Req, _State) ->
    ok.

%%%===================================================================
%%% internal
%%%===================================================================

text_frames(Frames) ->
    [{text, jsx:encode(F)} || F <- Frames].

%%%===================================================================
%%% configuration — ws-chargepoint.md §10
%%%===================================================================

%% D-9 — the first half of the three missed heartbeats of §3.2.
%%
%% This used to compute the whole product, and so did
%% `vs_connector:cp_grace_ms/0'; the old comment here claimed the two
%% expired "on the same clock". They compute the same *duration*, which is
%% not the same instant: they run **in series**. Cowboy waits out the
%% silence and closes the socket; only then does the connector see the
%% `DOWN' and start its own grace. Three missed heartbeats became six, and
%% a charge point that had gone quiet stayed reservable for three minutes.
%%
%% The ninety seconds are one budget, split: `CP_HEARTBEAT_MISSED - 1'
%% intervals here, the last interval as the connector's grace. Sixty plus
%% thirty is ninety, which is what §3.2 asks for.
%%
%% The more faithful alternative was to tell the two deaths of the socket
%% apart — closed for idle timeout means the heartbeats are already spent
%% and `out_of_service' is due at once; closed for anything else deserves
%% the full grace — by passing cowboy's `terminate/3' reason on to the
%% connector. It is the better model and it costs a new message on the most
%% delicate boundary of step 1; it is written up in
%% `scelte_di_progetto.md' as the road to take if this split turns out too
%% rigid. Not now: this batch closes defects, it does not add mechanisms.
idle_timeout_ms() ->
    (vs_env:get_int("CP_HEARTBEAT_MISSED", 3) - 1)
        * vs_env:get_int("CP_HEARTBEAT_INTERVAL_S", 30) * 1000.
