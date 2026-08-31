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
%%%    ▲                                 │                              │      │
%%%    │◀──cancel │ lease expired │ revoked                  stop │ full │      │
%%%    │                                                           ▼      │
%%%    │                                                       complete   │ unplug
%%%    │                                                           │ unplug│
%%%    │                                                           ▼      ▼
%%%    └──────session written · claim released────────────────── closing
%%%   free ──plugged, no reservation (walk-in)──────────────────▶ charging
%%%
%%%   any ──charge point faulted │ gone past the grace──▶ out_of_service
%%%   out_of_service ──charge point boots `available'──▶ free
%%%
%%% M4 — `complete' is the state that exists so that two facts the domain
%%% keeps apart stop being conflated: **the charge is over** and **the
%%% cable is out**. Every soft ending (the driver's stop, a full battery,
%%% a revoked claim) tells the hardware to stop and comes here; the row is
%%% written at the `unplugged', and the seconds in between, less the
%%% grace, are the overstay. `overstay' is not a seventh state: it is
%%% `complete' past the grace, derived in `reported_state/2' exactly as
%%% `suspended' is derived from a limit of zero.
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
%%%
%%% ## The charge point (ws-chargepoint.md, M2 step 1)
%%%
%%% `#data.cp' holds the pid of the socket process that speaks for the
%%% hardware on this connector, monitored. **That field is the registry**:
%%% one connection per connector (§1) means the connector's own state is
%%% the only place a lookup could consult, so there is no second ETS and
%%% no gproc. A newly connected socket calls `attach_cp/2'; the one being
%%% replaced is told `{cp_replaced}' and closes itself with 4409.
%%%
%%% The direction of the calls is unchanged from M1: socket → connector in
%%% call/cast, connector → socket with `!' only. The connector still makes
%%% no remote call of its own.
%%%
%%% Losing the socket does **not** take the connector out of service at
%%% once: §1 of the contract plans for the network blip with a one second
%%% reconnect, and a reservation must not die of a one second fault. The
%%% `DOWN' arms `{timeout, cp_grace}' — a *generic* timeout, so it
%%% survives the state changes that a `state_timeout' would cancel — and
%%% `attach_cp/2' cancels it. Its length is three missed heartbeats
%%% (§3.2), the same window cowboy uses as the socket's `idle_timeout'.
%%%-------------------------------------------------------------------
-module(vs_connector).
-behaviour(gen_statem).

%% API
-export([start_link/1, reserve/3, cancel/2, plugged/2, unplugged/2,
         meter/2, stop_session/2, revoke/2, claims_rebuild/2, snapshot/1,
         attach_cp/2, set_limit/2, cp_status/2]).
%% gen_statem
-export([init/1, callback_mode/0, terminate/3]).
%% pure — exported so that the halving of the heartbeat budget (D-9) can be
%% asserted against `vs_cp_ws:idle_timeout_ms/0' rather than restated in a
%% test, the same way vs_station_db exports its row and clock helpers.
%%
%% M4 — `overstay_seconds/3' is here for the same reason and a sharper
%% one: it is the arithmetic a `sessions' row is billed on, and the only
%% way to test it on the numbers that matter (seven minutes, four, the
%% boundary) without an hour of wall clock is to hand it timestamps.
%% `vs_time' is the real clock and is not injectable, and P11 forbids
%% tests that wait.
-export([cp_grace_ms/0, overstay_seconds/3]).
%% state functions
-export([free/3, held/3, charging/3, complete/3, closing/3, out_of_service/3]).

-type conn_id()    :: pos_integer().
-type user_id()    :: pos_integer().
-type vehicle_id() :: pos_integer().

%% ws-chargepoint.md §4.1 — the four the hardware may report.
-type cp_status()  :: available | occupied | faulted | unavailable.
%% ws-chargepoint.md §5 — the reasons a `stop' command may carry. The
%% connector raises four of the six; `not_your_reservation' is built by
%% `vs_cp_proto' (it answers a refused `plugged', which never becomes a
%% transition here) and `station_shutdown' by `vs_cp_ws' on the way down.
%%
%% M4 — `target_reached' is the fourth, and until now it was in the
%% contract and in nobody's code: the comment here said it "waits for the
%% allocator of M2 step 2", the allocator arrived, and the wire was never
%% pulled. It is raised by `charging/3' on the first `meter' that reports
%% a full battery, which is the only place the station learns that a car
%% has stopped needing power.
-type stop_reason() :: driver_stopped | target_reached | claim_revoked | faulted.

-export_type([cp_status/0, stop_reason/0]).

%% What the driver channel is allowed to see as a refusal. `vs_driver_ws'
%% turns these into the wire codes of ws-driver.md §6; keeping them as
%% atoms here means the state machine never formats a message.
%% `already_held' and `vehicle_committed' are two different refusals and
%% ws-driver.md §4.1 gives them two different rows: `already_held' is
%% raised HERE, by held/3 and charging/3 — *this connector* is taken, try
%% the next one. `vehicle_committed' comes back from the COORDINATOR
%% through claim_mod — *your vehicle* is reserved somewhere else, and no
%% other connector will help. This state machine never matches either: it
%% rebounds whatever claim_mod answered (see free/3), so the distinction
%% costs a word in this declaration and no branch anywhere.
-type refusal() :: already_held | vehicle_committed | no_claim | suspended
                 | retry_later | not_yours | not_your_reservation | invalid_state.

-export_type([refusal/0]).

%% P14 — four timestamps in two pairs, and the pairs are not the same
%% thing. `granted_at'/`expires_at' are the STATION's reservation: this
%% clock, and the lease of §3.1, which is what the driver is shown and
%% what `held(enter, …)' arms its timer on. `claim_granted_at' and
%% `claim_expires_at' are the COORDINATOR's, copied verbatim out of
%% `claim_mod:acquire/4' and never touched.
%%
%% They are here because this process is the half that survives a restart
%% of the claim client, so it is the only place those two numbers can
%% wait. The station's own pair could not stand in for them: claim.md
%% §5.5 settles conflicts on `GrantedAt', and reporting a local clock
%% would put back the cross-station skew the contract PR of 24/08 removed.
-record(hold, {user_id     :: user_id(),
               vehicle_id  :: vehicle_id(),
               claim_id    :: binary(),
               granted_at  :: vs_time:epoch_ms(),
               expires_at  :: vs_time:epoch_ms(),
               claim_granted_at :: vs_time:epoch_ms(),
               claim_expires_at :: vs_time:epoch_ms()}).

-record(session, {user_id     :: user_id(),
                  vehicle_id  :: vehicle_id(),
                  claim_id    :: binary() | undefined,
                  %% The coordinator's two, carried across held → charging
                  %% with the claim id. `undefined' for a walk-in and for
                  %% the §6 adoption from reconnected hardware, which have
                  %% no claim at all — and a session with no claim id has
                  %% nothing to present.
                  claim_granted_at :: vs_time:epoch_ms() | undefined,
                  claim_expires_at :: vs_time:epoch_ms() | undefined,
                  started_at  :: vs_time:epoch_ms(),
                  %% M4 — when the charge ended, on the station's clock.
                  %% `undefined' for every session that never passed
                  %% through `complete': a fault, a charge point gone past
                  %% the grace, an unplug straight out of `charging'. Those
                  %% endings leave no measurable overstay — the cable came
                  %% out, or the hardware stopped talking and no
                  %% `unplugged' will ever arrive — and `undefined' is what
                  %% makes `overstay_seconds/3' answer 0 for them without a
                  %% branch at the call site.
                  charge_ended_at = undefined :: vs_time:epoch_ms() | undefined,
                  energy_kwh  = 0.0 :: float(),
                  %% D-1. The charge point counts from *its* start and
                  %% knows nothing about sessions ending (§4.3, §6), so a
                  %% cable that was never unplugged keeps reporting totals
                  %% that include energy already written to `sessions'.
                  %% This is how much of every reading belongs to a row
                  %% that exists already; it is subtracted before the
                  %% monotone `max', never after.
                  energy_offset = 0.0 :: float(),
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
               session    = undefined :: #session{} | undefined,
               %% the charge point socket of this connector, and its monitor
               cp          = undefined :: pid() | undefined,
               cp_mon      = undefined :: reference() | undefined,
               cp_grace_ms :: pos_integer(),
               %% D-2: how long `closing' listens before it writes.
               settle_ms   :: pos_integer(),
               %% M4: the tolerance between the end of the charge and the
               %% first billable second of overstay (ws-chargepoint.md
               %% §10). Photographed at the birth of the process and never
               %% read again — the same note of method every other env var
               %% in this module carries: a session must be billed by the
               %% rule that was in force when it started, not by whatever
               %% the environment says at the settle.
               overstay_grace_s :: non_neg_integer(),
               %% D-1: the cumulative the hardware will report next, if it
               %% still has the cable. Set by `settle/1' on the two paths
               %% that end a session without the cable coming out; read and
               %% cleared by the next adoption, whichever door it uses.
               %% Zero in a freshly started process, which is why a station
               %% restart keeps the full adoption of §6 with no branch.
               energy_billed = 0.0 :: float(),
               %% D4: `closing' is the one exit every ending session goes
               %% through, and it has two destinations. The default is the
               %% only one M1 knew; the fault paths set it for one trip and
               %% `closing' puts it back (see closing/3).
               after_closing = free :: free | out_of_service}).

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

%% @doc The claim client has restarted with an empty table and is asking
%% what this connector holds (P14).
%%
%% A cast, and the client's pid travels inside it: a cast carries no
%% sender, and the client monitors whoever owns the claim. Answered in
%% `held' and in `charging', where a claim id exists; everywhere else the
%% state functions absorb it and say nothing, which is the right answer —
%% there is nothing to present.
-spec claims_rebuild(pid(), pid()) -> ok.
claims_rebuild(Pid, ClientPid) ->
    gen_statem:cast(Pid, {claims_rebuild, ClientPid}).

%% @doc Current view of the connector, for the `state' push.
-spec snapshot(pid()) -> map().
snapshot(Pid) ->
    gen_statem:call(Pid, snapshot).

%% @doc Bind a charge point socket to this connector (ws-chargepoint.md §1).
%%
%% A **call**, not a cast, and that is the whole point: the socket must
%% know it is the live one before it acknowledges the `boot', and the
%% reply is the synchronisation. Any previous socket is told
%% `{cp_replaced}' and its monitor is dropped with `flush', so the death
%% of the socket we ourselves replaced cannot arm the grace timer and take
%% a perfectly healthy connector out of service.
-spec attach_cp(pid(), pid()) -> ok.
attach_cp(Pid, CpPid) ->
    gen_statem:call(Pid, {attach_cp, CpPid}).

%% @doc The ceiling this connector may draw, in kW (§5 `set_limit').
%%
%% A cast, and idempotent by repetition: §5 has the station re-send the
%% limit on every recomputation rather than diffing, so a charge point
%% that missed a frame is right again within one tick. Meaningful only
%% while charging; anywhere else there is nothing to limit and the event
%% is absorbed.
-spec set_limit(pid(), number()) -> ok.
set_limit(Pid, Kw) ->
    gen_statem:cast(Pid, {set_limit, Kw}).

%% @doc Physical status reported by the hardware (§4.1). The hardware is
%% authoritative on this and the station never argues with it.
-spec cp_status(pid(), cp_status()) -> ok.
cp_status(Pid, Status) ->
    gen_statem:cast(Pid, {cp_status, Status}).

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
                 notify_to  = maps:get(notify_to, Opts, undefined),
                 cp_grace_ms = maps:get(cp_grace_ms, Opts, cp_grace_ms()),
                 settle_ms   = maps:get(closing_settle_ms, Opts,
                                        closing_settle_ms()),
                 overstay_grace_s = maps:get(overstay_grace_s, Opts,
                                             overstay_grace_s())},
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
        {ok, ClaimId, ClaimGrantedAt, ClaimExpiresAt} ->
            %% The reservation deadline is the station's lease, not the
            %% claim's: the claim is granted longer on purpose (claim.md
            %% §3.1) so it never dies under a live reservation.
            ExpiresAt = vs_time:in_ms(Data#data.lease_ms),
            %% P14 — the coordinator's two timestamps are kept beside the
            %% station's. `ClaimExpiresAt' was already coming back here
            %% and was only being logged; `ClaimGrantedAt' is the field
            %% `acquire/4' grew. Neither is used by this state machine:
            %% they are held for the claim client to ask back.
            Hold = #hold{user_id    = UserId,
                         vehicle_id = VehicleId,
                         claim_id   = ClaimId,
                         granted_at = vs_time:now_ms(),
                         expires_at = ExpiresAt,
                         claim_granted_at = ClaimGrantedAt,
                         claim_expires_at = ClaimExpiresAt},
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
    Session = adopt(Info, undefined, Data),
    logger:notice("connector ~p walk-in session for user ~p",
                  [Data#data.conn_id, Session#session.user_id]),
    {next_state, charging, consumed(Data#data{session = Session}),
     [{reply, From, ok}]};

%% §4.3: "a meter for a connector with no session is dropped and logged".
%% Logged and nothing else — no `notify', because a charge point sends one
%% of these every METER_INTERVAL_S and turning each into a state push
%% would flood every open page with a change that never happened. The log
%% line is what §7.6 asks for: divergence is found, never patched.
free(cast, {meter, Reading}, Data) ->
    logger:warning("connector ~p: meter for a connector with no session "
                   "(state free): ~p", [Data#data.conn_id, Reading]),
    keep_state_and_data;

free(cast, {cp_status, Status}, Data) when Status =:= faulted;
                                           Status =:= unavailable ->
    logger:warning("connector ~p: charge point reports ~p - out of service",
                   [Data#data.conn_id, Status]),
    {next_state, out_of_service, Data};

free(cast, {cp_status, Status}, Data) ->
    logger:debug("connector ~p: charge point reports ~p while free",
                 [Data#data.conn_id, Status]),
    keep_state_and_data;

%% D3: the socket has been gone for three heartbeats. Nothing was
%% reserved and nothing was charging, so there is nothing to unwind.
free({timeout, cp_grace}, _Content, Data) ->
    logger:warning("connector ~p: no charge point for ~p ms - out of service",
                   [Data#data.conn_id, Data#data.cp_grace_ms]),
    {next_state, out_of_service, Data};

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
    %% M4-A — and now also *said to somebody who can act on it*. The
    %% `notify' above goes to the station manager and from there to the
    %% open pages; it never left this station, which is why the counter
    %% stayed at zero while every no-show was being observed. This line is
    %% the other half: claim client → coordinator → Java → the column
    %% (erlang-java.md §2.4).
    %%
    %% **Only from here.** The other three ways out of `held' are not
    %% no-shows and must not become strikes: a `cancel' is the driver
    %% keeping their word ahead of time, a `revoke' is the system closing
    %% the window (the coordinator decided, not the driver), and a charge
    %% point that stops answering is our fault, not theirs. SCOPE §3.3
    %% penalises a reservation that *expires*, and this timer is the only
    %% thing in the system that measures that.
    %%
    %% One call, no retry: see the note on `vs_claim_client:no_show/2' —
    %% a duplicate here is a doubled counter, which is worse than a lost
    %% strike.
    (Data#data.claim_mod):no_show(Hold#hold.user_id, Data#data.conn_id),
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
            %% D1: the session opens on the **holder**, not on whoever the
            %% payload names. The charge point identifies a vehicle (§4.2)
            %% and has no voice on the account: the person billed is the
            %% one the claim was granted to.
            Session = adopt(Info#{user_id => Hold#hold.user_id},
                            claim_of(Hold), Data),
            notify(Data, {session_started, Hold#hold.user_id}),
            %% M4-A — the reservation has been honoured, so the
            %% consecutive streak resets: "turning up resets the counter"
            %% (SCOPE §3.3, erlang-java.md §2.4).
            %%
            %% `Hold#hold.user_id', never `maps:get(user_id, Info)': D1
            %% again. The charge point identifies a vehicle and has no
            %% voice on the account, so the streak that is cleared is the
            %% holder's — the same person the session was just opened on.
            %%
            %% This clause and no other. The walk-in of `free/3' honours
            %% no reservation (there was none to miss, and a walk-in is
            %% exactly what a suspended account is still allowed to do),
            %% and the §6 adoption is hardware finding its cable again,
            %% not a driver arriving.
            (Data#data.claim_mod):show_up(Hold#hold.user_id),
            %% D-8: the reservation has done its work and is discarded
            %% here. Left in place it went on being reported by
            %% `build_snapshot/2', so a connector that was charging still
            %% showed `held_by_me: true' and the `expires_at' of a lease
            %% that had already been consumed — and ws-driver.md §5.1
            %% computes `held_by_me' server-side precisely so that the
            %% page never has to reason about identity. Feeding it a false
            %% one is worse than making it think.
            %%
            %% The claim is not lost with it: `session_from/3' has just
            %% copied the claim id into the session, and `release/2' looks
            %% there when the hold is `undefined'.
            {next_state, charging,
             consumed(Data#data{session = Session, hold = undefined}),
             [{reply, From, ok}]};
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

%% P14 — the claim client restarted and is asking. This is where the
%% claim lives before the cable goes in.
held(cast, {claims_rebuild, Client}, Data = #data{hold = Hold}) ->
    present_claim(Client, claim_of(Hold),
                  Hold#hold.vehicle_id, Hold#hold.user_id, Data),
    keep_state_and_data;

held(cast, {meter, Reading}, Data) ->
    logger:warning("connector ~p: meter for a connector with no session "
                   "(state held): ~p", [Data#data.conn_id, Reading]),
    keep_state_and_data;

%% §3.2: "any reservation on it is released with a session_interrupted
%% notification". `cancelled' is the release reason — claim.md §5.6 fixes
%% the four allowed words and this is the station cancelling, not the
%% lease running out.
held(cast, {cp_status, Status}, Data = #data{hold = #hold{user_id = U}})
  when Status =:= faulted; Status =:= unavailable ->
    logger:warning("connector ~p: charge point reports ~p while reserved by "
                   "user ~p - releasing", [Data#data.conn_id, Status, U]),
    release(Data, cancelled),
    notify(Data, {session_interrupted, U}),
    {next_state, out_of_service, Data};

held(cast, {cp_status, _Status}, _Data) ->
    keep_state_and_data;

held({timeout, cp_grace}, _Content, Data = #data{hold = #hold{user_id = U}}) ->
    logger:warning("connector ~p: no charge point for ~p ms while reserved by "
                   "user ~p - releasing", [Data#data.conn_id,
                                           Data#data.cp_grace_ms, U]),
    release(Data, cancelled),
    notify(Data, {session_interrupted, U}),
    {next_state, out_of_service, Data};

held(EventType, Event, Data) ->
    handle_common(EventType, Event, held, Data).

%%%===================================================================
%%% charging
%%%===================================================================

%% D5 — the interim allocation. The contract wants a limit after the
%% authorisation and reads `limit_kw: 0' as "suspended", so a session that
%% never received one would sit at zero and the emulator would never
%% charge. One value, computed once, on the single transition into the
%% state: `min(rated_kw, max_kw)' — the outlet cannot give more than it is
%% rated for and the car cannot take more than it is built for. M2 step 2
%% moves the *calculation* into the manager's allocator and calls
%% `set_limit/2' on every arrival and departure; the *transport* below
%% does not change again.
%%
%% A `plugged' payload with no `max_kw' would therefore start suspended,
%% and **stay** suspended: `vs_power:demand_kw/3' reads the same field, so
%% the demand is zero too and no later `set_limit' can lift it. An earlier
%% version of this comment promised that the next tick would correct it.
%% It never could, and the car sat at zero for ever with nothing in any log
%% to say why (D-4).
%%
%% The field is mandatory in §4.2, so the place to insist on it is the
%% payload validation in `vs_cp_proto' — which now refuses such a `plugged'
%% outright, and never opens a session at all. Inventing a limit for a car
%% that never declared one would instead be the station deciding what
%% hardware can take, which is exactly the split §7.2 forbids. What is left
%% here is the connector's own defence: `min' with a zero is zero, said
%% honestly, for a payload that should no longer be able to reach it.
charging(enter, _Old, Data = #data{session = S, rated_kw = Rated}) ->
    Limit = float(min(Rated, S#session.max_kw)),
    Data1 = Data#data{session = S#session{limit_kw = Limit}},
    notify(Data1, {state_changed, charging}),
    send_cp(Data1, #{command => set_limit, limit_kw => Limit}),
    {keep_state, Data1};

%% M4 — the reading that ends the charge, and the only way the station
%% ever learns that a battery is full. `target_reached' has been in
%% ws-chargepoint.md §5 since M2 and had no sender: the equipment reports
%% the state of charge (§4.3) and it is the station that has to draw the
%% conclusion, because the split of §7.1 gives the equipment no say in
%% when a session ends.
%%
%% The reading is applied **before** the transition, not dropped with it:
%% the last few hundred watt-hours are energy that was delivered, and the
%% snapshot the page reads a millisecond later should show the full
%% battery it just reported rather than the reading before it.
charging(cast, {meter, Reading}, Data = #data{session = S}) ->
    S2 = (apply_meter(Reading, S))#session{
           power_kw = maps:get(power_kw, Reading, S#session.power_kw),
           soc_pct  = maps:get(soc_pct,  Reading, S#session.soc_pct)},
    case S2#session.soc_pct >= 100 of
        true ->
            logger:notice("connector ~p: battery full for user ~p - stopping "
                          "the charge", [Data#data.conn_id, S2#session.user_id]),
            send_cp(Data, stop_cmd(target_reached)),
            {next_state, complete, charge_ended(Data#data{session = S2})};
        false ->
            {keep_state, Data#data{session = S2}}
    end;

%% §5: stored **and** forwarded. Stored because the page and the allocator
%% both read it back off the snapshot; forwarded because the hardware is
%% the only thing that can actually apply it.
charging(cast, {set_limit, Kw}, Data = #data{session = S}) ->
    Limit = float(Kw),
    Data1 = Data#data{session = S#session{limit_kw = Limit}},
    send_cp(Data1, #{command => set_limit, limit_kw => Limit}),
    {keep_state, Data1};

%% M4 — `complete', not `closing'. The driver's stop ends the *charge*;
%% it does not pull the cable, and ws-driver.md §120 has always said so
%% ("stopping does not end the overstay clock: the cable is still in the
%% car"). Going straight to `closing' wrote the row in the same breath,
%% which left no interval for anyone to measure and made §4.3 contradict
%% §120 in the same document. The ack the driver gets is unchanged.
charging({call, From}, {stop_session, UserId}, Data = #data{session = #session{user_id = UserId}}) ->
    send_cp(Data, stop_cmd(driver_stopped)),
    {next_state, complete, charge_ended(Data), [{reply, From, ok}]};

charging({call, From}, {stop_session, _Other}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_yours}}]};

%% The cable is out and the hardware has said its last word. The event is
%% posted forward instead of being applied here: `closing' knows how to
%% take a final total and settle on it at once, so there is one place that
%% reads an `unplugged' rather than two that must agree.
charging(cast, {unplugged, EnergyKwh}, Data) ->
    {next_state, closing, Data, [{next_event, cast, {unplugged, EnergyKwh}}]};

%% A revocation while charging still wins (claim.md §5.4). It is the rarest
%% path in the system and the one most worth getting right: the contract
%% says the station obeys, so the session stops and the driver is told why.
%%
%% M4 — a third soft ending, so `complete' like the other two: the
%% coordinator took the reservation away, it did not pull the cable, and a
%% car left plugged in after a revocation is an overstay like any other.
%% The `claim_revoked' notification stays here, at the moment of the
%% revocation; only the row moves to the unplug. `release(completed)' on a
%% claim the coordinator has already revoked was happening on this path
%% before M4 too — a few seconds earlier, and just as harmlessly (claim.md
%% §5.6 makes a release best-effort).
charging(cast, {revoke, ClaimId}, Data = #data{session = #session{claim_id = ClaimId, user_id = U}}) ->
    logger:warning("connector ~p claim ~s revoked mid-session", [Data#data.conn_id, ClaimId]),
    notify(Data, {claim_revoked, U}),
    send_cp(Data, stop_cmd(claim_revoked)),
    {next_state, complete, charge_ended(Data)};

%% P14, the other half. `held → charging' hands the reservation in and
%% throws the `#hold' away (D-8), so after the cable goes in the claim
%% lives here — and a client that restarts mid-session has to be able to
%% get it back, or §6.1 stays open for every connector that is charging.
%% A walk-in falls into the same clause and presents nothing: its
%% `claim_id' is `undefined' and `present_claim/5' says so.
charging(cast, {claims_rebuild, Client}, Data = #data{session = S}) ->
    present_claim(Client, claim_of(S),
                  S#session.vehicle_id, S#session.user_id, Data),
    keep_state_and_data;

charging({call, From}, {reserve, _U, _V}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, already_held}}]};

%% §4.1: "`faulted' immediately takes the connector out of service and
%% stops any session". The row is still written, with the energy last
%% measured — §3.2, a session that cannot be measured must not keep
%% accruing cost, but the energy already delivered was delivered.
charging(cast, {cp_status, Status}, Data = #data{session = #session{user_id = U}})
  when Status =:= faulted; Status =:= unavailable ->
    logger:error("connector ~p: charge point reports ~p mid-session - closing "
                 "with the last measured energy", [Data#data.conn_id, Status]),
    send_cp(Data, stop_cmd(faulted)),
    notify(Data, {session_interrupted, U}),
    {next_state, closing, Data#data{after_closing = out_of_service}};

charging(cast, {cp_status, _Status}, _Data) ->
    keep_state_and_data;

%% D3, the mirror case of §3.2: the hardware stopped talking. No `stop'
%% command goes out — there is nobody left to send it to.
charging({timeout, cp_grace}, _Content, Data = #data{session = #session{user_id = U}}) ->
    logger:warning("connector ~p: no charge point for ~p ms mid-session - closing "
                   "with the last measured energy",
                   [Data#data.conn_id, Data#data.cp_grace_ms]),
    notify(Data, {session_interrupted, U}),
    {next_state, closing, Data#data{after_closing = out_of_service}};

charging(EventType, Event, Data) ->
    handle_common(EventType, Event, charging, Data).

%%%===================================================================
%%% complete — M4
%%%===================================================================

%% The charge is over and the cable is still in. One state for the three
%% soft endings, and the only place in the machine where time passing is
%% itself the thing being measured.
%%
%% What it is **not**: a timer. `overstay' is derived in
%% `reported_state/2' from the clock and `charge_ended_at', the way
%% `suspended' is derived from a limit of zero, and for the same reason —
%% a state that entered and left on a value which moves by itself would
%% fire `enter' callbacks for nothing. A `{state_timeout, Grace, overstay}'
%% is what the notification of ws-driver §5.3 will need when R2 opens; it
%% would slot in here and change nothing else.
%%
%% What it costs, stated rather than discovered: the session stays in RAM
%% until the cable comes out, which may be minutes. That was already true
%% for the whole charge, and it is the price of the alternative being two
%% writes per session and a `sessions' row that changes under the back
%% office (see PIANO_OVERSTAY §4).
%%
%% `plugged' has no clause on purpose. A charge point that reconnects
%% during the overstay re-announces the cable (§6.2), and `handle_common'
%% answers `invalid_state' — which is **exactly** what a connector in
%% `charging' answers today, and what `vs_cp_proto' logs and drops without
%% sending any command. The blip therefore costs nothing here either: the
%% `attach_cp' of the boot has already cancelled the grace timer in
%% `handle_common', the session is untouched and `charge_ended_at' keeps
%% running. A clause of our own could only do worse — it would restart the
%% clock on a car that never moved.
complete(enter, _Old, Data = #data{session = S}) ->
    %% Delivery is over, so the two numbers that describe delivery say so.
    %% Not cosmetics: `power_kw' travels to the driver's page in the §5.2
    %% frame and `meter' is absorbed below, so a stale reading would sit
    %% there for the whole overstay claiming the car is still drawing
    %% ninety kilowatts. `limit_kw' matters on a different path — a charge
    %% point that reboots mid-overstay reads it back out of the boot ack
    %% (`vs_cp_proto:limit_kw/2') and would resume delivering on a ceiling
    %% the station cancelled a minute ago. Zero is §5's own word for "the
    %% session stays open and draws nothing".
    Data1 = Data#data{session = S#session{power_kw = 0.0, limit_kw = 0.0}},
    %% The manager reallocates and broadcasts on any connector event, so
    %% this one hands the power back to the pool (`vs_power:is_live/1'
    %% admits only `charging' and `suspended') and puts the new state on
    %% every open page in the same step.
    notify(Data1, {state_changed, complete}),
    {keep_state, Data1};

%% The cable is out. Same shape as `charging': the event is posted
%% forward so that `closing' stays the one place that reads an
%% `unplugged' and settles on the total it carries.
complete(cast, {unplugged, EnergyKwh}, Data) ->
    {next_state, closing, Data, [{next_event, cast, {unplugged, EnergyKwh}}]};

%% P14, the third half. A state that did not answer the rebuild would
%% reopen the regression in the place where a session now spends minutes
%% rather than milliseconds: the claim still exists, this process still
%% owns it, and a claim client that restarted has no other way to find it.
%% Presented exactly as `charging/3' presents it, walk-in clause included.
complete(cast, {claims_rebuild, Client}, Data = #data{session = S}) ->
    present_claim(Client, claim_of(S),
                  S#session.vehicle_id, S#session.user_id, Data),
    keep_state_and_data;

%% The claim of a session that is already over. Absorbed, not obeyed:
%% there is no charge left to stop and no reservation left to release —
%% `settle/1' will release it at the unplug, and a release of a claim the
%% coordinator has already revoked is a no-op it expects (claim.md §5.6).
%% This is the ordinary ending of a long overstay, where the lease simply
%% runs out under a car nobody has moved, so it is a log line and not a
%% warning.
complete(cast, {revoke, ClaimId}, Data = #data{session = #session{claim_id = ClaimId}}) ->
    logger:notice("connector ~p: claim ~s revoked after the charge ended - "
                  "nothing to stop", [Data#data.conn_id, ClaimId]),
    keep_state_and_data;

%% §4.3's monotone total stops here. The charge is over, so energy must
%% not grow on a reading: the true final figure comes with the
%% `unplugged' and goes through `final_energy/2' exactly as it always
%% has. Measured on the emulator (`cp.js:343-344'): after a `stop' it
%% sets `delivering = false' and the meter goes silent, so in practice
%% this clause is a defence against equipment that keeps talking rather
%% than a path anything walks.
complete(cast, {meter, Reading}, Data) ->
    logger:debug("connector ~p: meter after the charge ended, ignored: ~p",
                 [Data#data.conn_id, Reading]),
    keep_state_and_data;

complete({call, From}, {reserve, _U, _V}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, already_held}}]};

%% §4.1, as in `charging': the hardware is authoritative, the row is
%% written with the energy last measured and the overstay accrued so far,
%% and the connector goes out of service. The `stop' goes out again even
%% though the charge is already over — it is idempotent by contract and
%% it is what makes cp.js report its final total on this path too.
complete(cast, {cp_status, Status}, Data = #data{session = #session{user_id = U}})
  when Status =:= faulted; Status =:= unavailable ->
    logger:error("connector ~p: charge point reports ~p after the charge ended - "
                 "closing with the last measured energy", [Data#data.conn_id, Status]),
    send_cp(Data, stop_cmd(faulted)),
    notify(Data, {session_interrupted, U}),
    {next_state, closing, Data#data{after_closing = out_of_service}};

complete(cast, {cp_status, _Status}, _Data) ->
    keep_state_and_data;

%% D3, in the state where it hurts most: the hardware went quiet during
%% the overstay, so no `unplugged' will ever arrive. Write what has
%% accrued up to now — the overstay is real up to the moment measurement
%% stopped — and go out of service, as `charging' does.
complete({timeout, cp_grace}, _Content, Data = #data{session = #session{user_id = U}}) ->
    logger:warning("connector ~p: no charge point for ~p ms after the charge "
                   "ended - closing with the last measured energy",
                   [Data#data.conn_id, Data#data.cp_grace_ms]),
    notify(Data, {session_interrupted, U}),
    {next_state, closing, Data#data{after_closing = out_of_service}};

complete(EventType, Event, Data) ->
    handle_common(EventType, Event, complete, Data).

%%%===================================================================
%%% closing
%%%===================================================================

%% Everything that must happen exactly once when a session ends still
%% happens in one place — `settle/1' — but that place is now the way
%% **out** of this state rather than the way in.
%%
%% D-2. The old shape wrote on entry, and on the paths that get here by
%% *telling the hardware to stop* that is a frame too early: §5 has the
%% charge point apply the command and report back, and it reports back
%% with the `unplugged' carrying the true total (cp.js answers `stop'
%% with exactly that). The row was written from the last `meter' instead,
%% losing up to METER_INTERVAL_S of energy — at 150 kW, a fifth of a
%% kilowatt-hour off every driver-ended session.
%%
%% So `closing' listens for `settle_ms' before it writes. In that window a
%% `meter' still counts and an `unplugged' ends the wait at once, because
%% an `unplugged' is the hardware's last word and there is nothing further
%% to wait for. Nothing else about the state changes: late casts are
%% absorbed as before, calls still rebound `invalid_state', and
%% `after_closing' still decides where the connector goes next.
%%
%% M4 narrowed which endings still need that window, and it is worth
%% saying which. The three soft ones no longer arrive here from
%% `charging' at all: they go to `complete' and wait for the `unplugged'
%% for as long as it takes, because that wait is the overstay and a two
%% second deadline would be an arbitrary cap on it. What is left is the
%% fault paths — a `faulted' status, a charge point past its grace,
%% raised from `charging' or from `complete' — where the hardware may
%% still get one last word in and where no `unplugged' is ever coming if
%% it does not. Those are the sessions this timeout exists for now.
%%
%% What it costs, stated rather than discovered: the outlet stays in
%% `closing' up to `settle_ms' longer, the claim is released that much
%% later (its lease is minutes, so nothing notices), and the allocation
%% this session held returns to the pool only at the settle. A connector
%% reached by an `unplugged' — the common ending — pays none of it: the
%% transition posts the event forward and the window closes immediately.
closing(enter, _Old, Data) ->
    {keep_state, Data, [{state_timeout, Data#data.settle_ms, settle}]};

%% The hardware has finished talking. Take the total and write.
closing(cast, {unplugged, EnergyKwh}, Data = #data{session = S}) ->
    settle(Data#data{session = final_energy(EnergyKwh, S)});

%% Still talking. A reading that arrives between the `stop' command and
%% the `unplugged' is energy that was really delivered, and the monotone
%% `max' of §4.3 applies here exactly as it does in `charging'.
closing(cast, {meter, Reading}, Data = #data{session = S}) ->
    {keep_state, Data#data{session = apply_meter(Reading, S)}};

%% Nothing more came. Write what we measured — which is what §3.2 asks for
%% on the fault paths anyway: "closed with the energy last reported".
closing(state_timeout, settle, Data) ->
    settle(Data);

%% Late events from a charge point that is one step behind are expected
%% here, not exceptional: absorb them.
closing(cast, _Ignored, _Data) ->
    keep_state_and_data;

closing(EventType, Event, Data) ->
    handle_common(EventType, Event, closing, Data).

%% The one place a session becomes a row.
%%
%% D4: where `closing' lets out. `free' for every path M1 knew; the fault
%% paths of §3.2 and §4.1 ask for `out_of_service' instead. The field is
%% put back in the same step it is read, so the *next* session to end here
%% leaves the normal way — a one-trip flag, not a mode.
settle(Data = #data{session = S, after_closing = Next}) ->
    EndedAt = vs_time:now_ms(),
    Row = #{user_id      => S#session.user_id,
            station_id   => Data#data.station_id,
            connector_id => Data#data.conn_id,
            started_at   => S#session.started_at,
            %% M4 — still the instant the occupation ended, which is now
            %% the unplug rather than the stop on the soft paths. It
            %% describes how long the outlet was taken; the overstay has
            %% its own column and B reads that one (BillingService), never
            %% the difference of the two timestamps.
            ended_at     => EndedAt,
            energy_kwh   => S#session.energy_kwh,
            overstay_seconds => overstay_seconds(S#session.charge_ended_at,
                                                 EndedAt,
                                                 Data#data.overstay_grace_s)},
    %% A cast: it queues the row and returns. The connector must never wait
    %% for a database — if it did, a slow MySQL would hold an outlet in
    %% `closing' and a dead one would hold it there for the timeout, which
    %% is a component that cannot deliver power deciding whether a
    %% connector may be reused (SCOPE §4). There is no error branch here
    %% because there is no longer an error to branch on: the retry, the
    %% queue and its cap all live in vs_station_db, which is the only
    %% process that knows whether the write got through.
    ok = (Data#data.db_mod):insert_session(Row),
    release(Data, completed),
    notify(Data, {session_closed, Row}),
    {next_state, Next, Data#data{after_closing = free,
                                 energy_billed = carried(Next, S)}}.

%% D-1. `out_of_service' is reached by the two endings that leave the cable
%% in the car — the fault of §4.1 and the grace of §3.2 — and neither of
%% them tells the charge point to forget anything. It goes on counting from
%% its own start, so the `plugged' that re-announces the cable (§6.2) will
%% carry a cumulative that includes the row just written. What is
%% remembered is that cumulative, not this session's share of it: chained
%% faults on one cable then subtract the whole history, not the last slice.
%%
%% Every other ending has been told the cable is out, and carries nothing.
carried(out_of_service, #session{energy_kwh = Kwh, energy_offset = Offset}) ->
    Kwh + Offset;
carried(free, _Session) ->
    0.0.

%%%===================================================================
%%% out_of_service
%%%===================================================================

%% D2 — a fifth state, not a flag on the other four. "Not reservable,
%% invisible as free, session closed" is what a state says and what a flag
%% would leave to a `case' in every branch. `reserve' refuses itself here:
%% there is no clause for it, so `handle_common' answers `invalid_state',
%% which is exactly the right answer.
%%
%% It is reached from a fault (§4.1) or from the charge point going quiet
%% past the grace (§3.2), and left only when the hardware says it is
%% `available' again — the station never decides on its own that a
%% connector has healed (§7.2: the hardware is authoritative on physical
%% state).
out_of_service(enter, _Old, Data) ->
    notify(Data, {state_changed, out_of_service}),
    {keep_state, Data#data{hold = undefined, session = undefined}};

%% §3.1: "booting resets nothing" — the charge point reports its true
%% status and the station reconciles. An `available' is that reconciliation.
out_of_service(cast, {cp_status, available}, Data) ->
    logger:notice("connector ~p: charge point reports available - back in service",
                  [Data#data.conn_id]),
    {next_state, free, Data};

out_of_service(cast, {cp_status, _Status}, _Data) ->
    keep_state_and_data;

%% The second way out, and the one that is easy to leave missing. A charge
%% point that went quiet past the grace **while delivering** does not come
%% back saying `available': it says `occupied', which lifts nothing, and
%% then re-announces the cable (§6.2). This connector no longer has the
%% session — it was closed with the last measured energy on the way in
%% here — so it adopts what the hardware reports, exactly as `free' does
%% for a walk-in.
%%
%% Without this clause the reconnection would be refused `invalid_state',
%% the boot ack would have handed out `limit_kw: 0', and a car that is
%% physically plugged in would sit suspended forever waiting for an
%% `available' that occupied hardware never sends.
%%
%% No claim, on purpose: §6 says reconstructing the reservation is
%% deliberately not attempted — "the car keeps charging, the session is
%% billed, the reservation is gone".
out_of_service({call, From}, {plugged, Info}, Data) ->
    Session = adopt(Info, undefined, Data),
    logger:notice("connector ~p: adopting a session from reconnected hardware "
                  "for user ~p (~p kWh already counted, ~p kWh already billed "
                  "and taken off)",
                  [Data#data.conn_id, Session#session.user_id,
                   Session#session.energy_kwh, Session#session.energy_offset]),
    {next_state, charging, consumed(Data#data{session = Session}),
     [{reply, From, ok}]};

out_of_service(cast, {meter, Reading}, Data) ->
    logger:warning("connector ~p: meter for a connector with no session "
                   "(state out_of_service): ~p", [Data#data.conn_id, Reading]),
    keep_state_and_data;

%% Already out of service: the grace timer of a second disconnection has
%% nothing left to take away.
out_of_service({timeout, cp_grace}, _Content, _Data) ->
    keep_state_and_data;

out_of_service(EventType, Event, Data) ->
    handle_common(EventType, Event, out_of_service, Data).

%%%===================================================================
%%% common
%%%===================================================================

%% One place for the events every state must answer, so that adding a state
%% cannot silently drop `snapshot' or leave a caller hanging forever.
handle_common({call, From}, snapshot, State, Data) ->
    {keep_state_and_data, [{reply, From, build_snapshot(State, Data)}]};

%% Valid in every state on purpose: a charge point may reconnect while the
%% connector is charging, closing or out of service, and the contract's
%% "the newest socket wins" (§1) must not depend on what the station
%% happens to be doing. Cancelling the grace timer here is the other half
%% of D3 — a blip that heals inside the window leaves no trace at all.
handle_common({call, From}, {attach_cp, CpPid}, _State, Data) ->
    Data1 = attach(CpPid, Data),
    {keep_state, Data1, [{reply, From, ok}, {{timeout, cp_grace}, cancel}]};

handle_common({call, From}, _Event, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, invalid_state}}]};

handle_common(cast, _Event, _State, _Data) ->
    keep_state_and_data;

%% The states that have something to unwind match this themselves; this
%% clause is what keeps a stray firing — in `closing', say — from being a
%% `function_clause' crash instead of a no-op.
handle_common({timeout, cp_grace}, _Content, _State, _Data) ->
    keep_state_and_data;

%% The socket died. Not "the connector is broken": §1 plans for the blip,
%% so the verdict is deferred by exactly three missed heartbeats and
%% `attach_cp/2' cancels it if the hardware comes back in time.
handle_common(info, {'DOWN', Ref, process, _Pid, Reason}, State,
              Data = #data{cp_mon = Ref, conn_id = ConnId, cp_grace_ms = Grace}) ->
    logger:warning("connector ~p: charge point socket gone in ~p (~p); "
                   "~p ms of grace", [ConnId, State, Reason, Grace]),
    {keep_state, Data#data{cp = undefined, cp_mon = undefined},
     [{{timeout, cp_grace}, Grace, lost}]};

handle_common(info, Info, State, Data) ->
    logger:debug("connector ~p ignoring ~p in ~p", [Data#data.conn_id, Info, State]),
    keep_state_and_data.

%%%===================================================================
%%% internal
%%%===================================================================

build_snapshot(State, Data = #data{hold = Hold, session = S}) ->
    Base = #{connector_id => Data#data.conn_id,
             rated_kw     => Data#data.rated_kw,
             state        => reported_state(State, Data),
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
        _ -> Base#{session => #{user_id     => S#session.user_id,
                                vehicle_id  => S#session.vehicle_id,
                                started_at  => S#session.started_at,
                                energy_kwh  => S#session.energy_kwh,
                                soc_pct     => S#session.soc_pct,
                                %% the numerator of `eta_seconds'
                                %% (ws-driver.md §5.2). Same story as the
                                %% two below: it has been in #session since
                                %% the first `plugged' and only the
                                %% snapshot was missing it.
                                battery_kwh => S#session.battery_kwh,
                                %% what the car can take, for the
                                %% allocator's demand (SCOPE §3.5); it was
                                %% in #session already and only the
                                %% snapshot was missing it
                                max_kw      => S#session.max_kw,
                                %% for the `boot' ack of §3.1, which hands
                                %% the charge point the limit in force
                                limit_kw    => S#session.limit_kw,
                                %% M4, ws-driver.md §5.2 — the live net,
                                %% zero while the grace is running.
                                %% Computed **here** and nowhere else: one
                                %% process owns the grace and the clock,
                                %% and `vs_driver_proto' reads a number
                                %% instead of re-deriving one from fields
                                %% it would have to be handed anyway. The
                                %% same figure `settle/1' will write, one
                                %% call earlier.
                                overstay_seconds =>
                                    overstay_seconds(S#session.charge_ended_at,
                                                     vs_time:now_ms(),
                                                     Data#data.overstay_grace_s)}}
    end.

%% M2 step 2 — `suspended' is derived here, and is deliberately **not** a
%% sixth state of the machine: it is `charging' at a limit of zero, which
%% is how ws-driver.md §5.1 defines it and how ws-chargepoint.md §5
%% expresses it on the wire ("0 means suspended: the session stays open
%% and draws nothing").
%%
%% Unlike `out_of_service' (D2), nothing about the connector's *behaviour*
%% changes: the authorisation is the same, the session is alive, the
%% events it answers are the same — only how much flows. A real state
%% would enter and leave on every recomputation that crossed the floor,
%% firing `enter' and `exit' callbacks for a value that changed; a derived
%% one cannot oscillate because there is nothing to oscillate.
%% M4 — `overstay' is the second derived name, on exactly the same
%% argument. It is `complete' once the grace has run out, and it is shown
%% on the station page as well as on the driver's: whoever is waiting for
%% an outlet is entitled to know that it is blocked by a car that has
%% finished, not by one that is charging. `suspended' already leaks there
%% the same way — one `reported_state', two pages that agree.
%%
%% The comparison is `>=', and that is deliberate rather than sloppy:
%% with a grace of zero — which is how the tests get a deterministic
%% overstay without waiting for one — the very millisecond the charge
%% ends must already read `overstay', or the assertion depends on how
%% fast the machine is.
reported_state(charging, #data{session = #session{limit_kw = Limit}})
  when Limit =:= +0.0 ->
    suspended;
reported_state(complete, #data{session = #session{charge_ended_at = EndedAt},
                               overstay_grace_s = GraceS})
  when is_integer(EndedAt) ->
    case vs_time:now_ms() >= EndedAt + GraceS * 1000 of
        true  -> overstay;
        false -> complete
    end;
reported_state(State, _Data) ->
    State.

%% The three doorways into `charging' all go through these two, so the
%% offset is applied and cleared in one place rather than three. Splitting
%% them keeps the clearing visible at the call site: an adoption *consumes*
%% what a previous session left behind, whichever door it came through.
%% The second argument is the whole claim now — `{ClaimId, GrantedAt,
%% ExpiresAt}' — or `undefined' for a session that never had one. The two
%% callers that passed `undefined' before still pass it and still mean the
%% same thing: the walk-in of `free/3' and the §6 re-adoption of
%% `out_of_service/3' have no claim, not merely no claim id.
adopt(Info, Claim, #data{energy_billed = Billed}) ->
    session_from(Info, Claim, Billed).

consumed(Data) ->
    Data#data{energy_billed = 0.0}.

%% M4 — the instant the charge ended, stamped once on the way into
%% `complete'. Written by all three soft transitions and by none of the
%% others, which is the whole of the rule "a session that never reached
%% `complete' has no measurable overstay". The station's clock, like every
%% timestamp that ends up in a row (ws-chargepoint.md §7.4).
charge_ended(Data = #data{session = S}) ->
    Data#data{session = S#session{charge_ended_at = vs_time:now_ms()}}.

%% @doc Billable overstay seconds: how long the cable stayed in after the
%% charge ended, less the grace, never negative.
%%
%% The **net**, and this is the one place in the system that subtracts it
%% — agreed with B in `risposta-per-B-M2.md' §2 and written into
%% ws-chargepoint.md §10 and erlang-java.md: six minutes past the end of
%% the charge with a five minute grace is `60', four minutes is `0'. The
%% back office multiplies by the station's rate and never re-derives the
%% seconds from `started_at'/`ended_at' (BillingService, SessionView).
%%
%% `div', so the last incomplete second is not billed; the boundary
%% second is free for the same reason. B rounds the *minutes* up, which is
%% where the deterrent lives.
-spec overstay_seconds(vs_time:epoch_ms() | undefined, vs_time:epoch_ms(),
                       non_neg_integer()) -> non_neg_integer().
overstay_seconds(undefined, _EndedAt, _GraceS) ->
    0;
overstay_seconds(ChargeEndedAt, EndedAt, GraceS) ->
    max(0, (EndedAt - ChargeEndedAt) div 1000 - GraceS).

%% The claim a `#hold' or a `#session' carries, in the shape `adopt/3' and
%% `present_claim/5' both want. One function over two records because it
%% is one fact: the claim outlives the transition between them.
claim_of(#hold{claim_id = Id, claim_granted_at = G, claim_expires_at = E}) ->
    {Id, G, E};
claim_of(#session{claim_id = Id, claim_granted_at = G, claim_expires_at = E}) ->
    {Id, G, E}.

%% P14 — the answer to a `{claims_rebuild, …}'.
%%
%% The six fields of claim.md, in the order the client stores them, with
%% `self()' in front: a cast carries no sender and the client monitors
%% whoever owns the claim, so the pid has to be in the message.
%%
%% A session with no claim says nothing. That clause is not a formality:
%% a walk-in reaches `charging' through the same door, and casting
%% `undefined' as a claim id would put into the client's table — and from
%% there into the coordinator's, on the next renew — a claim nobody ever
%% granted.
present_claim(_Client, {undefined, _GrantedAt, _ExpiresAt}, _VehicleId, _UserId, _Data) ->
    ok;
present_claim(Client, {ClaimId, GrantedAt, ExpiresAt}, VehicleId, UserId,
              #data{conn_id = ConnId}) ->
    logger:notice("connector ~p: presenting claim ~s (vehicle ~p, user ~p) to a "
                  "claim client that asked", [ConnId, ClaimId, VehicleId, UserId]),
    gen_server:cast(Client, {claim_present, self(), ClaimId, VehicleId, UserId,
                             ConnId, GrantedAt, ExpiresAt}).

%% §4.3 — every figure the charge point sends is cumulative since *its*
%% start. `energy_offset' is how much of that has already been written to
%% `sessions' by an earlier session on the same cable; the subtraction
%% comes first, the monotone `max' of §4.3 second. The `max(0.0, ...)'
%% costs nothing when the offset is zero, which is every ordinary session.
delivered(Reported, #session{energy_offset = Offset}) ->
    max(0.0, float(Reported) - Offset).

%% A `meter' reading applied to a session. A payload with no `energy_kwh'
%% changes nothing rather than reading as zero.
apply_meter(Reading, S) ->
    case maps:get(energy_kwh, Reading, undefined) of
        undefined -> S;
        Reported  -> S#session{energy_kwh = max(S#session.energy_kwh,
                                                delivered(Reported, S))}
    end.

%% The total on an `unplugged' — same arithmetic, said once for the one
%% caller that has a bare number rather than a reading map.
final_energy(Reported, S) ->
    S#session{energy_kwh = max(S#session.energy_kwh, delivered(Reported, S))}.

%% §6 — reconciliation. `energy_kwh' is seeded from the payload because a
%% charge point that reconnects after a station restart reports the total
%% it has counted, and it is the only side that counted it. The default is
%% 0.0, so every caller that never heard of reconciliation — the tests,
%% the walk-in path — behaves exactly as before.
%%
%% D-1 — the same frame arrives in two situations and they are not the
%% same session. If the reported cumulative is at least what a previous
%% session on this cable was already billed for, the hardware is still
%% counting the same physical delivery: the offset applies and this
%% session starts from the difference. If it reports **less**, its counter
%% has restarted — a different car, a firmware reset, a real unplug we
%% never saw — and an offset from a delivery that is over means nothing:
%% it is dropped and the payload is taken at face value. Deciding it once,
%% here, is what keeps a later `unplugged' from having to guess.
session_from(Info, Claim, Offset) ->
    {ClaimId, ClaimGrantedAt, ClaimExpiresAt} = claim_fields(Claim),
    Reported = float(maps:get(energy_kwh, Info, 0.0)),
    {Offset1, Energy} =
        case Offset > 0.0 andalso Reported >= Offset of
            true  -> {Offset, Reported - Offset};
            false -> {0.0, Reported}
        end,
    #session{user_id     = maps:get(user_id, Info),
             vehicle_id  = maps:get(vehicle_id, Info),
             claim_id    = ClaimId,
             claim_granted_at = ClaimGrantedAt,
             claim_expires_at = ClaimExpiresAt,
             started_at  = started_at_from(Info),
             energy_kwh  = Energy,
             energy_offset = Offset1,
             soc_pct     = maps:get(soc_pct, Info, 0),
             battery_kwh = maps:get(battery_kwh, Info, 0.0),
             max_kw      = maps:get(max_kw, Info, 0)}.

%% The three `undefined' of a session with no claim, said once so that
%% `session_from/3' has a single shape to fill in either case.
claim_fields(undefined) ->
    {undefined, undefined, undefined};
claim_fields({ClaimId, GrantedAt, ExpiresAt}) ->
    {ClaimId, GrantedAt, ExpiresAt}.

%% §6 — when the session began, and the one date the reconciliation is
%% allowed to move. It used to be the adoption instant unconditionally, on
%% the argument that the station has no memory of what happened before the
%% crash and that §6 bills the meter total, not the duration. Both halves
%% are still true and the conclusion was wrong: nothing was miscounted, but
%% the row said twenty-three seconds over energy that took an hour, and a
%% document of record whose own two numbers contradict each other is a
%% defect whether or not anybody prices it (measured: 5.956 kWh over 65
%% recorded seconds, 330 kW implied on a 150 kW outlet).
%%
%% The hardware now sends how long it has been delivering, and the station
%% subtracts that from **its own** clock. A duration is a quantity the
%% equipment measured, like `energy_kwh'; an absolute start would be a
%% reading of the equipment's clock, which §7.4 keeps out of anything that
%% counts. That is the whole reason the field is a duration, and it is why
%% two boxes whose clocks disagree still write the same row.
%%
%% Nothing here is coupled to `energy_offset': the offset answers "how much
%% of this cumulative belongs to a row that exists already", this answers
%% "when did the delivery start", and one is not derivable from the other.
%% They are applied side by side and neither reads the other.
%%
%% The key is absent for every payload that does not carry a usable
%% duration — `vs_cp_proto' does not put it there — so a walk-in, a
%% reserved plug and a charge point that has never heard of the field all
%% fall through to the clock, which is exactly what they did before.
started_at_from(Info) ->
    Now = vs_time:now_ms(),
    case maps:get(charging_seconds, Info, undefined) of
        Secs when is_integer(Secs), Secs > 0, Secs * 1000 < Now ->
            Now - Secs * 1000;
        _NoneOrUnusable ->
            Now
    end.

%% Monitor the newcomer, drop the incumbent. `demonitor(..., [flush])'
%% matters more than it looks: without the flush, the DOWN of the socket
%% we just replaced may already be in the mailbox, and it would arm the
%% grace timer of a connector whose charge point is perfectly healthy.
attach(CpPid, Data = #data{cp = CpPid}) ->
    Data;                                   %% the same socket, re-announcing
attach(CpPid, Data = #data{cp = Old, cp_mon = OldRef, conn_id = ConnId}) ->
    case Old of
        undefined ->
            ok;
        _ ->
            _ = erlang:demonitor(OldRef, [flush]),
            logger:notice("connector ~p: charge point socket replaced", [ConnId]),
            Old ! {cp_replaced}
    end,
    Ref = erlang:monitor(process, CpPid),
    Data#data{cp = CpPid, cp_mon = Ref}.

%% The one direction the connector talks to hardware: a plain message, never
%% a call. A socket that is busy or gone must never be able to block the
%% process that owns a physical outlet.
send_cp(#data{cp = undefined}, _Cmd) ->
    ok;
send_cp(#data{cp = Pid}, Cmd) ->
    Pid ! {cp_cmd, Cmd},
    ok.

stop_cmd(Reason) -> #{command => stop, reason => Reason}.

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

%%%===================================================================
%%% configuration — ws-chargepoint.md §10
%%%===================================================================

%% D-9 — the second half of the three missed heartbeats of §3.2, not a
%% second copy of them.
%%
%% This timer and cowboy's `idle_timeout' on the charge point socket used
%% to compute the same product, and they act **in series**: cowboy waits
%% for the silence, and only when it gives up does the `DOWN' arrive here
%% and start this. Three missed heartbeats therefore took six — a faulted
%% connector stayed reservable for three minutes instead of ninety
%% seconds. The comment that used to sit here said the two expired
%% together; they never did.
%%
%% So the ninety seconds are one budget, split rather than paid twice:
%% `CP_HEARTBEAT_MISSED - 1' intervals go to the socket
%% (`vs_cp_ws:idle_timeout_ms/0') and the last one to this grace. The
%% grace is not redundant and cannot simply go: §1 plans for the network
%% blip — a socket that dies of a FIN or an error rather than of silence,
%% with the charge point reconnecting in about a second — and one
%% heartbeat interval is ample for that reconnection while staying inside
%% the budget.
cp_grace_ms() ->
    vs_env:get_int("CP_HEARTBEAT_INTERVAL_S", 30) * 1000.

%% D-2 — how long `closing' waits for the charge point's last word before
%% writing the row without it. §5 gives the equipment `LIMIT_APPLY_SECONDS'
%% to honour a limit and says it "reflects the result" of a command; two
%% seconds is the same order of magnitude and well inside the five of
%% `METER_INTERVAL_S', so a session never waits for a meter tick it was
%% not going to get. A charge point that is simply gone costs exactly this
%% much and nothing more.
closing_settle_ms() ->
    vs_env:get_int("CLOSING_SETTLE_MS", 2000).

%% M4 — §10's `OVERSTAY_GRACE_SECONDS'. Read once, in `init/1', and kept
%% in `#data': the note of method on environment variables in this system
%% is that they are photographed at the birth of the process, so a session
%% is billed by the tolerance that was in force when it started rather
%% than by whatever the environment says minutes later at the settle.
%% The override from `Opts' exists for the same reason
%% `closing_settle_ms' has one — a test needs the behaviour, not the wait.
overstay_grace_s() ->
    vs_env:get_int("OVERSTAY_GRACE_SECONDS", 300).
