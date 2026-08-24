%%%-------------------------------------------------------------------
%%% @doc One process per physical connector.
%%%
%%% This is the guardian of a physical outlet: every request touching that
%%% outlet becomes a message in this process's mailbox, so concurrent
%%% drivers are serialised without a single lock (P1 — actor model).
%%%
%%% States, and the events that move between them:
%%%
%%%   free ──reserve (claim granted)──▶ held ──plugged (right vehicle)──▶ charging
%%%    ▲                                 │                                   │
%%%    │◀──cancel │ lease expired │ revoked                    stop │ unplug │
%%%    │                                                             ▼
%%%    └──────session written · claim released────────────────── closing
%%%   free ──plugged, no reservation (walk-in)──────────────────▶ charging
%%%
%%% Two rules are structural rather than checked:
%%%
%%%   * **Claim first, commit after.** `free' asks the coordinator and moves
%%%     to `held' only on a grant. A crash in between leaves an unused claim,
%%%     which expires — the harmless direction (claim.md §5.1).
%%%   * **Events that do not apply simply do not match.** There is no branch
%%%     that could start a session on a connector held by someone else,
%%%     because `charging' is not reachable from `held' with the wrong
%%%     vehicle. The state machine is the enforcement.
%%%
%%% The claim client and the database are injected as modules (`claim_mod',
%%% `db_mod'). The connector knows the interface, not the transport, which
%%% is what makes it testable without a coordinator and without MySQL.
%%%-------------------------------------------------------------------
-module(vs_connector).
-behaviour(gen_statem).

%% API
-export([start_link/1, reserve/3, cancel/2, plugged/2, unplugged/2,
         meter/2, stop_session/2, revoke/2, snapshot/1]).
%% gen_statem
-export([init/1, callback_mode/0, terminate/3]).
%% state functions
-export([free/3, held/3, charging/3, closing/3]).

-type conn_id()    :: pos_integer().
-type user_id()    :: pos_integer().
-type vehicle_id() :: pos_integer().

%% What the driver channel is allowed to see as a refusal. `vs_driver_ws'
%% turns these into the wire codes of ws-driver.md §6; keeping them as
%% atoms here means the state machine never formats a message.
-type refusal() :: already_held | no_claim | suspended | retry_later
                 | not_yours | not_your_reservation | invalid_state.

-export_type([refusal/0]).

-record(hold, {user_id     :: user_id(),
               vehicle_id  :: vehicle_id(),
               claim_id    :: binary(),
               granted_at  :: vs_time:epoch_ms(),
               expires_at  :: vs_time:epoch_ms()}).

-record(session, {user_id     :: user_id(),
                  vehicle_id  :: vehicle_id(),
                  claim_id    :: binary() | undefined,
                  started_at  :: vs_time:epoch_ms(),
                  energy_kwh  = 0.0 :: float(),
                  power_kw    = 0.0 :: float(),
                  soc_pct     = 0   :: non_neg_integer(),
                  battery_kwh = 0.0 :: float(),
                  max_kw      = 0   :: non_neg_integer(),
                  limit_kw    = 0.0 :: float()}).

-record(data, {conn_id    :: conn_id(),
               station_id :: pos_integer(),
               rated_kw   :: pos_integer(),
               lease_ms   :: pos_integer(),
               claim_mod  :: module(),
               db_mod     :: module(),
               notify_to  :: pid() | atom() | undefined,
               hold       = undefined :: #hold{} | undefined,
               session    = undefined :: #session{} | undefined}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Options: conn_id and rated_kw are required; the rest have defaults
%% so that a connector can be started from the shell with two keys.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% @doc Reserve on behalf of a driver. Returns only after the coordinator
%% has answered: the caller is the driver's WebSocket process, and it has
%% nothing useful to do in the meantime.
-spec reserve(pid(), user_id(), vehicle_id()) ->
          {ok, vs_time:epoch_ms()} | {error, refusal()}.
reserve(Pid, UserId, VehicleId) ->
    gen_statem:call(Pid, {reserve, UserId, VehicleId}).

-spec cancel(pid(), user_id()) -> ok | {error, refusal()}.
cancel(Pid, UserId) ->
    gen_statem:call(Pid, {cancel, UserId}).

%% @doc Cable plugged in — reported by the charge point (ws-chargepoint.md §4.2).
-spec plugged(pid(), map()) -> ok | {error, refusal()}.
plugged(Pid, Info) ->
    gen_statem:call(Pid, {plugged, Info}).

-spec unplugged(pid(), float()) -> ok.
unplugged(Pid, EnergyKwh) ->
    gen_statem:cast(Pid, {unplugged, EnergyKwh}).

%% @doc Meter reading. A cast: a charge point must never be held up waiting
%% for the station, and a lost reading is corrected by the next one.
-spec meter(pid(), map()) -> ok.
meter(Pid, Reading) ->
    gen_statem:cast(Pid, {meter, Reading}).

-spec stop_session(pid(), user_id()) -> ok | {error, refusal()}.
stop_session(Pid, UserId) ->
    gen_statem:call(Pid, {stop_session, UserId}).

%% @doc The coordinator revoked the claim (claim.md §3.2). Authoritative:
%% obeyed even though this process believes the claim is valid.
-spec revoke(pid(), binary()) -> ok.
revoke(Pid, ClaimId) ->
    gen_statem:cast(Pid, {revoke, ClaimId}).

%% @doc Current view of the connector, for the `state' push.
-spec snapshot(pid()) -> map().
snapshot(Pid) ->
    gen_statem:call(Pid, snapshot).

%%%===================================================================
%%% gen_statem
%%%===================================================================

%% `state_enter' gives every state an entry callback: the lease timer is
%% armed on entering `held' and nowhere else, so no code path can reach
%% `held' without a deadline attached.
callback_mode() -> [state_functions, state_enter].

init(Opts) ->
    Data = #data{conn_id    = maps:get(conn_id, Opts),
                 station_id = maps:get(station_id, Opts, vs_env:get_int("STATION_ID", 1)),
                 rated_kw   = maps:get(rated_kw, Opts, 150),
                 lease_ms   = maps:get(lease_seconds, Opts,
                                       vs_env:get_int("LEASE_SECONDS", 900)) * 1000,
                 claim_mod  = maps:get(claim_mod, Opts, vs_claim_null),
                 db_mod     = maps:get(db_mod, Opts, vs_station_db),
                 notify_to  = maps:get(notify_to, Opts, undefined)},
    %% Announce to whoever tracks connectors (vs_station_mgr). This runs
    %% at first boot AND at every supervisor restart, which is how the
    %% manager's registry heals after a crash without polling anyone. It
    %% is a message, never a call: the manager may be blocked in its own
    %% handle_continue starting this very process (scelte §4.4).
    notify(Data, {connector_up, self()}),
    {ok, free, Data}.

terminate(_Reason, State, #data{conn_id = ConnId}) ->
    logger:notice("connector ~p terminating in state ~p", [ConnId, State]),
    ok.

%%%===================================================================
%%% free
%%%===================================================================

%% Initial entry: gen_statem calls the enter callback with Old =:= New
%% for the start state, and `free' is reachable from `free' in no other
%% way. Nothing observable changed, so nothing is announced — otherwise
%% every station boot (or manager readoption) would spray subscribers
%% with pushes describing a change that never happened.
free(enter, free, Data) ->
    {keep_state, Data#data{hold = undefined, session = undefined}};
free(enter, _Old, Data) ->
    notify(Data, {state_changed, free}),
    {keep_state, Data#data{hold = undefined, session = undefined}};

free({call, From}, {reserve, UserId, VehicleId}, Data) ->
    %% The claim is asked for before anything local changes. Whatever the
    %% coordinator answers, this connector is still `free' until it says ok.
    case (Data#data.claim_mod):acquire(VehicleId, UserId,
                                       Data#data.station_id, Data#data.conn_id) of
        {ok, ClaimId, ClaimExpiresAt} ->
            %% The reservation deadline is the station's lease, not the
            %% claim's: the claim is granted longer on purpose (claim.md
            %% §3.1) so it never dies under a live reservation.
            ExpiresAt = vs_time:in_ms(Data#data.lease_ms),
            Hold = #hold{user_id    = UserId,
                         vehicle_id = VehicleId,
                         claim_id   = ClaimId,
                         granted_at = vs_time:now_ms(),
                         expires_at = ExpiresAt},
            logger:notice("connector ~p reserved by user ~p (claim ~s, claim expiry ~p)",
                          [Data#data.conn_id, UserId, ClaimId, ClaimExpiresAt]),
            notify(Data, {reserved, UserId, ExpiresAt}),
            {next_state, held, Data#data{hold = Hold},
             [{reply, From, {ok, ExpiresAt}}]};
        {error, Refusal} ->
            {keep_state_and_data, [{reply, From, {error, Refusal}}]}
    end;

%% Walk-in: a free connector, a driver who never reserved. Allowed on
%% purpose — a reservation is a promise about the future, not a licence to
%% charge, and refusing a plugged-in car at a free outlet would be absurd.
%% No claim is involved, which is also why a suspended account can still
%% charge this way (SCOPE §3.3).
free({call, From}, {plugged, Info}, Data) ->
    Session = session_from(Info, undefined),
    logger:notice("connector ~p walk-in session for user ~p",
                  [Data#data.conn_id, Session#session.user_id]),
    {next_state, charging, Data#data{session = Session}, [{reply, From, ok}]};

free(EventType, Event, Data) ->
    handle_common(EventType, Event, free, Data).

%%%===================================================================
%%% held
%%%===================================================================

held(enter, _Old, Data = #data{hold = Hold}) ->
    %% state_timeout is cancelled automatically by any state change, so the
    %% lease cannot outlive the state it belongs to.
    Remaining = vs_time:remaining_ms(Hold#hold.expires_at),
    {keep_state, Data, [{state_timeout, Remaining, lease_expired}]};

%% No-show. The connector frees itself: no operator action, no cooperation
%% from a client that may well be offline (P3 — leasing).
held(state_timeout, lease_expired, Data = #data{hold = Hold}) ->
    logger:notice("connector ~p lease expired for user ~p",
                  [Data#data.conn_id, Hold#hold.user_id]),
    release(Data, expired),
    notify(Data, {reservation_expired, Hold#hold.user_id}),
    %% Reported, never written: the penalty counter belongs to the back
    %% office alone (schema.sql, ownership rules).
    notify(Data, {no_show, Hold#hold.user_id}),
    {next_state, free, Data};

held({call, From}, {cancel, UserId}, Data = #data{hold = #hold{user_id = UserId}}) ->
    release(Data, cancelled),
    notify(Data, {reservation_cancelled, UserId}),
    {next_state, free, Data, [{reply, From, ok}]};

held({call, From}, {cancel, _Other}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_yours}}]};

held({call, From}, {reserve, _UserId, _VehicleId}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, already_held}}]};

%% The authorisation check, and the only one in the system: the vehicle at
%% the cable must be the vehicle the claim was granted for.
held({call, From}, {plugged, Info}, Data = #data{hold = Hold}) ->
    case maps:get(vehicle_id, Info) =:= Hold#hold.vehicle_id of
        true ->
            Session = session_from(Info, Hold#hold.claim_id),
            notify(Data, {session_started, Hold#hold.user_id}),
            {next_state, charging, Data#data{session = Session}, [{reply, From, ok}]};
        false ->
            %% The reservation survives: someone else's car at the cable is
            %% not a reason to punish the holder.
            {keep_state_and_data, [{reply, From, {error, not_your_reservation}}]}
    end;

held(cast, {revoke, ClaimId}, Data = #data{hold = #hold{claim_id = ClaimId, user_id = U}}) ->
    logger:warning("connector ~p claim ~s revoked", [Data#data.conn_id, ClaimId]),
    notify(Data, {claim_revoked, U}),
    %% No release message: the coordinator revoked it, it already knows.
    {next_state, free, Data};

held(EventType, Event, Data) ->
    handle_common(EventType, Event, held, Data).

%%%===================================================================
%%% charging
%%%===================================================================

charging(enter, _Old, Data) ->
    notify(Data, {state_changed, charging}),
    keep_state_and_data;

charging(cast, {meter, Reading}, Data = #data{session = S}) ->
    %% Energy is cumulative and monotonic: a meter that resets on a
    %% firmware glitch must not subtract energy already delivered
    %% (ws-chargepoint.md §4.3).
    Energy = max(S#session.energy_kwh, maps:get(energy_kwh, Reading, S#session.energy_kwh)),
    S2 = S#session{energy_kwh = Energy,
                   power_kw   = maps:get(power_kw, Reading, S#session.power_kw),
                   soc_pct    = maps:get(soc_pct,  Reading, S#session.soc_pct)},
    {keep_state, Data#data{session = S2}};

charging({call, From}, {stop_session, UserId}, Data = #data{session = #session{user_id = UserId}}) ->
    {next_state, closing, Data, [{reply, From, ok}]};

charging({call, From}, {stop_session, _Other}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_yours}}]};

charging(cast, {unplugged, EnergyKwh}, Data = #data{session = S}) ->
    Final = max(S#session.energy_kwh, EnergyKwh),
    {next_state, closing, Data#data{session = S#session{energy_kwh = Final}}};

%% A revocation while charging still wins (claim.md §5.4). It is the rarest
%% path in the system and the one most worth getting right: the contract
%% says the station obeys, so the session stops and the driver is told why.
charging(cast, {revoke, ClaimId}, Data = #data{session = #session{claim_id = ClaimId, user_id = U}}) ->
    logger:warning("connector ~p claim ~s revoked mid-session", [Data#data.conn_id, ClaimId]),
    notify(Data, {claim_revoked, U}),
    {next_state, closing, Data};

charging({call, From}, {reserve, _U, _V}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, already_held}}]};

charging(EventType, Event, Data) ->
    handle_common(EventType, Event, charging, Data).

%%%===================================================================
%%% closing
%%%===================================================================

%% Everything that must happen exactly once when a session ends happens
%% here, on entry: write the row, release the claim, tell whoever is
%% listening. Then the connector returns to `free' on a zero timeout, so
%% the work is done in a state of its own rather than smeared across the
%% transitions that can reach it.
closing(enter, _Old, Data = #data{session = S}) ->
    EndedAt = vs_time:now_ms(),
    Row = #{user_id      => S#session.user_id,
            station_id   => Data#data.station_id,
            connector_id => Data#data.conn_id,
            started_at   => S#session.started_at,
            ended_at     => EndedAt,
            energy_kwh   => S#session.energy_kwh,
            overstay_seconds => 0},          %% overstay arrives in M4
    case (Data#data.db_mod):insert_session(Row) of
        ok -> ok;
        {error, Reason} ->
            %% The car has already charged; losing the row must not lose the
            %% connector. Logged loudly, retried by the DB layer in M2.
            logger:error("connector ~p could not write session: ~p",
                         [Data#data.conn_id, Reason])
    end,
    release(Data, completed),
    notify(Data, {session_closed, Row}),
    {keep_state, Data, [{state_timeout, 0, done}]};

closing(state_timeout, done, Data) ->
    {next_state, free, Data};

%% Late events from a charge point that is one step behind are expected
%% here, not exceptional: absorb them.
closing(cast, _Ignored, _Data) ->
    keep_state_and_data;

closing(EventType, Event, Data) ->
    handle_common(EventType, Event, closing, Data).

%%%===================================================================
%%% common
%%%===================================================================

%% One place for the events every state must answer, so that adding a state
%% cannot silently drop `snapshot' or leave a caller hanging forever.
handle_common({call, From}, snapshot, State, Data) ->
    {keep_state_and_data, [{reply, From, build_snapshot(State, Data)}]};

handle_common({call, From}, _Event, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, invalid_state}}]};

handle_common(cast, _Event, _State, _Data) ->
    keep_state_and_data;

handle_common(info, Info, State, Data) ->
    logger:debug("connector ~p ignoring ~p in ~p", [Data#data.conn_id, Info, State]),
    keep_state_and_data.

%%%===================================================================
%%% internal
%%%===================================================================

build_snapshot(State, Data = #data{hold = Hold, session = S}) ->
    Base = #{connector_id => Data#data.conn_id,
             rated_kw     => Data#data.rated_kw,
             state        => State,
             held_by      => case Hold of
                                 #hold{user_id = U} -> U;
                                 _ -> undefined
                             end,
             expires_at   => case Hold of
                                 #hold{expires_at = E} -> E;
                                 _ -> undefined
                             end,
             power_kw     => case S of
                                 #session{power_kw = P} -> P;
                                 _ -> 0.0
                             end},
    case S of
        undefined -> Base;
        _ -> Base#{session => #{user_id    => S#session.user_id,
                                vehicle_id => S#session.vehicle_id,
                                started_at => S#session.started_at,
                                energy_kwh => S#session.energy_kwh,
                                soc_pct    => S#session.soc_pct}}
    end.

session_from(Info, ClaimId) ->
    #session{user_id     = maps:get(user_id, Info),
             vehicle_id  = maps:get(vehicle_id, Info),
             claim_id    = ClaimId,
             started_at  = vs_time:now_ms(),
             soc_pct     = maps:get(soc_pct, Info, 0),
             battery_kwh = maps:get(battery_kwh, Info, 0.0),
             max_kw      = maps:get(max_kw, Info, 0)}.

%% Releasing is best-effort by contract (claim.md §5.6): the claim expires
%% on its own, so a failed release is logged and forgotten rather than
%% retried into a queue nobody drains.
release(#data{hold = undefined, session = undefined}, _Reason) ->
    ok;
release(#data{claim_mod = Mod, conn_id = ConnId, hold = Hold, session = S}, Reason) ->
    ClaimId = case {Hold, S} of
                  {#hold{claim_id = C}, _} -> C;
                  {_, #session{claim_id = C}} -> C;
                  _ -> undefined
              end,
    case ClaimId of
        undefined ->
            ok;   %% walk-in: there was never a claim
        _ ->
            %% `try', not the old `catch Expr': that form is deprecated from
            %% OTP 29 and, with warnings_as_errors, stops the build. It also
            %% swallowed the reason, while the contract above says a failed
            %% release is *logged* and forgotten.
            try Mod:release(ClaimId, Reason) of
                _ -> ok
            catch
                Class:Why ->
                    logger:warning("connector ~p release of claim ~s failed: ~p:~p",
                                   [ConnId, ClaimId, Class, Why]),
                    ok
            end
    end.

notify(#data{notify_to = undefined}, _Event) -> ok;
%% A registered name may be momentarily unregistered while the manager
%% restarts; `Atom ! Msg' would then badarg and crash the connector — a
%% cascade that would turn a manager hiccup into a station outage. The
%% manager re-adopts the connectors on its way back up, so skipping the
%% notification here is safe.
notify(#data{notify_to = To, conn_id = ConnId}, Event) when is_atom(To) ->
    case whereis(To) of
        undefined -> ok;
        Pid       -> Pid ! {connector_event, ConnId, Event}, ok
    end;
notify(#data{notify_to = To, conn_id = ConnId}, Event) ->
    To ! {connector_event, ConnId, Event},
    ok.
