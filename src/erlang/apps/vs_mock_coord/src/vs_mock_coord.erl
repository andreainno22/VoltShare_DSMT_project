%%%-------------------------------------------------------------------
%%% @doc Fake coordinator: always grants. The stand-in for vs_coord_srv
%%% while B's real coordinator does not exist yet (piano §8).
%%%
%%% It is registered under the REAL name — `vs_coord_srv' — because its
%%% whole point is that vs_claim_client cannot tell the difference: it
%%% speaks the wire protocol of contracts/claim.md, so swapping in the
%%% real coordinator at the end of M1 changes a compose service and
%%% nothing else.
%%%
%%% Because of that, this module doubles as the *executable reference*
%%% of the contract, transport included:
%%%
%%%   * {claim, ...} and {renew, ...} are gen_server:call — §1;
%%%   * {release, ...}, {station_up, ...}, {station_stats, ...} arrive
%%%     as gen_server:cast: the contract marks them fire-and-forget /
%%%     announcements, with no reply defined.  ← B: this is the framing
%%%     the station uses; vs_coord_srv must accept the same;
%%%   * {no_show, ...} and {show_up, ...} likewise, added in M4-A —
%%%     erlang-java.md §2.4, the two the coordinator relays to Java.
%%%
%%% For the tests (and for poking at a live node) it records everything
%%% it receives and can be told to refuse: `history/0', `reset/0',
%%% `set_reply/1', `set_renew/1'.
%%%-------------------------------------------------------------------
-module(vs_mock_coord).
-behaviour(gen_server).

%% test / inspection API
-export([start_link/0, history/0, reset/0, set_reply/1, set_renew/1]).
%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% The name every station addresses — from the contract, not ours to pick.
-define(SRV, vs_coord_srv).

-record(state, {claim_reply = grant :: grant
                                     | {error, already_held | suspended
                                              | rebuilding | unknown_station}
                                     | {not_serving, node() | undefined},
                renew_reply = auto  :: auto | revoke_all,
                history     = []    :: [tuple()]}).   %% newest first

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SRV}, ?MODULE, [], []).

%% @doc Everything received so far, oldest first.
-spec history() -> [tuple()].
history() -> gen_server:call(?SRV, history).

-spec reset() -> ok.
reset() -> gen_server:call(?SRV, reset).

%% @doc Reply to the next {claim, ...} requests: grant (default), a
%% refusal from the contract, or a redirect.
-spec set_reply(term()) -> ok.
set_reply(Reply) -> gen_server:call(?SRV, {set_reply, Reply}).

%% @doc auto renews everything (default); revoke_all revokes everything —
%% the lever the tests pull to exercise the revocation path end to end.
-spec set_renew(auto | revoke_all) -> ok.
set_renew(Mode) -> gen_server:call(?SRV, {set_renew, Mode}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    {ok, #state{}}.

%% -- the contract: calls ---------------------------------------------

handle_call({claim, ReqId, VehicleId, UserId, StationId, ConnId} = Msg, _From,
            State = #state{claim_reply = Mode}) ->
    State1 = remember(Msg, State),
    case Mode of
        grant ->
            ClaimId = list_to_binary(
                        "mock-" ++ integer_to_list(erlang:unique_integer([positive]))),
            logger:notice("mock-coord: granting ~s (vehicle ~p, user ~p, "
                          "station ~p, connector ~p)",
                          [ClaimId, VehicleId, UserId, StationId, ConnId]),
            %% Contract PR of 24/08: the coordinator issues GrantedAt too —
            %% ONE clock decides oldest-wins, the station only echoes it.
            {reply, {ok, ReqId, ClaimId, vs_time:now_ms(), expiry()}, State1};
        {error, Reason} ->
            {reply, {error, ReqId, Reason}, State1};
        {not_serving, _} = Redirect ->
            {reply, Redirect, State1}
    end;

handle_call({renew, _StationId, Claims} = Msg, _From,
            State = #state{renew_reply = Mode}) ->
    State1 = remember(Msg, State),
    %% Five fields per contract PR of 24/08 — enforced strictly here: this
    %% module is the executable reference, an old-form renew must fail
    %% loudly in OUR tests rather than silently at integration time.
    %% (lists:map, not a comprehension: a comprehension would silently
    %% SKIP a malformed tuple, which is the opposite of failing loudly.)
    Ids = lists:map(fun({ClaimId, _VehicleId, _ConnId, _UserId, _GrantedAt}) ->
                            ClaimId
                    end, Claims),
    Reply = case Mode of
                auto       -> {renewed, Ids, [], expiry()};
                revoke_all -> {renewed, [], Ids, expiry()}
            end,
    {reply, Reply, State1};

%% -- inspection ------------------------------------------------------

handle_call(history, _From, State = #state{history = H}) ->
    {reply, lists:reverse(H), State};
handle_call(reset, _From, _State) ->
    {reply, ok, #state{}};
handle_call({set_reply, Reply}, _From, State) ->
    {reply, ok, State#state{claim_reply = Reply}};
handle_call({set_renew, Mode}, _From, State) ->
    {reply, ok, State#state{renew_reply = Mode}};

handle_call(Other, _From, State) ->
    logger:warning("mock-coord: unexpected call ~p", [Other]),
    {reply, {not_serving, undefined}, State}.

%% -- the contract: fire-and-forget -----------------------------------

handle_cast({release, ClaimId, Reason} = Msg, State) ->
    logger:notice("mock-coord: release ~s (~p)", [ClaimId, Reason]),
    {noreply, remember(Msg, State)};

handle_cast({station_up, StationId, Node, _Name, _WsUrl, _SiteKw, _Tariff,
             Connectors} = Msg, State) ->
    logger:notice("mock-coord: station ~p up on ~p with ~p connectors",
                  [StationId, Node, length(Connectors)]),
    {noreply, remember(Msg, State)};

handle_cast({station_stats, _StationId, _Free, _Held, _Charging} = Msg, State) ->
    {noreply, remember(Msg, State)};

%% M4-A — the penalty pair of erlang-java.md §2.4, in the arities the real
%% coordinator matches (vs_coord_srv:247-252). Written as shape-matched
%% heads rather than as a match on the tag alone, and that is the point of
%% having them here at all: a `no_show' with one element too many falls
%% into the catch-all below **in silence**, exactly as it would fall into
%% the coordinator's own, so the test that asserts the four-element form
%% goes red here instead of a message going missing at integration time.
handle_cast({no_show, UserId, StationId, ConnId} = Msg, State) ->
    logger:notice("mock-coord: no-show for user ~p at station ~p, connector ~p",
                  [UserId, StationId, ConnId]),
    {noreply, remember(Msg, State)};

handle_cast({show_up, UserId} = Msg, State) ->
    logger:notice("mock-coord: show-up for user ~p", [UserId]),
    {noreply, remember(Msg, State)};

%% M4-A — the driver notification of erlang-java.md §2.4, in the arity
%% `ErlangBridge:onNotify' reads (user id, kind, text) behind the tag.
%%
%% ← B: **this clause does not exist in `vs_coord_srv' yet** — it is R2
%% of nota-per-B-review-pr5.md §2, and it is the only hop missing between
%% a station that now really sends these and a row in `notifications'.
%% Until it is applied the real coordinator logs the tuple below as an
%% "unexpected cast" and drops it. The head here is shape-matched for the
%% same reason the penalty pair is: a `notify' of the wrong arity would
%% fall into the catch-all in silence on both sides, and this way the
%% test goes red here instead of the message going missing at integration.
handle_cast({notify, UserId, Kind, Text} = Msg, State) ->
    logger:notice("mock-coord: notification ~s for user ~p (~s)",
                  [Kind, UserId, Text]),
    {noreply, remember(Msg, State)};

handle_cast(Other, State) ->
    logger:warning("mock-coord: unexpected cast ~p", [Other]),
    {noreply, State}.

handle_info(Info, State) ->
    logger:debug("mock-coord: ignoring ~p", [Info]),
    {noreply, State}.

%%%===================================================================
%%% internal
%%%===================================================================

%% ExpiresAt is always lease + grace (claim.md §3.1): a claim must never
%% expire while the reservation it protects is still alive.
expiry() ->
    Lease = vs_env:get_int("LEASE_SECONDS", 900),
    Grace = vs_env:get_int("CLAIM_GRACE_SECONDS", 60),
    vs_time:in_seconds(Lease + Grace).

remember(Msg, State = #state{history = H}) ->
    State#state{history = [Msg | H]}.
