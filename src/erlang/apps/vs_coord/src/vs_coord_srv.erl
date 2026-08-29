%%%-------------------------------------------------------------------
%%% @doc The coordinator: it decides who may hold a vehicle.
%%%
%%% This process enforces the invariant the whole system is built around —
%%% a vehicle holds at most one active reservation across the network
%%% (SCOPE §5, P2). Stations ask before committing anything; this server is
%%% the only place where the answer is decided, which is what makes the
%%% decision serialisable: concurrent requests queue in one mailbox and are
%%% served one at a time, no locks involved.
%%%
%%% It implements contracts/claim.md. Read that file before changing
%%% anything here: the station side is written by A against it.
%%%
%%% M1 is a single coordinator, always the leader. Election, quorum and the
%%% rebuild after a failover arrive with M3; the `mode' field already exists
%%% so that adding them does not mean rewriting the request handlers.
%%%
%%% Claims and stations live in maps inside the state rather than in ETS:
%%% only this process reads them, and a map keeps the code honest about who
%%% owns what. If M3 needs concurrent reads, ETS is a local change.
%%%-------------------------------------------------------------------
-module(vs_coord_srv).
-behaviour(gen_server).

%% API used by the stations (through the contract) and by the tests
-export([start_link/0,
         claim/5, renew/2, release/2,
         station_up/1, station_stats/4, session_closed/1,
         stations/0, claims/0, mode/0,
         become_leader/0, become_follower/1, suspend/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(SWEEP_INTERVAL_MS, 5000).

%% A granted claim. `granted_at' is what decides conflicts after a failover,
%% so it is preserved verbatim when a claim is adopted from a station.
-record(claim, {claim_id   :: binary(),
                vehicle_id :: pos_integer(),
                user_id    :: pos_integer(),
                station_id :: pos_integer(),
                conn_id    :: pos_integer(),
                granted_at :: vs_time:epoch_ms(),
                expires_at :: vs_time:epoch_ms()}).

%% What a station told us about itself, plus its latest counters.
-record(station, {id               :: pos_integer(),
                  node             :: node(),
                  name             :: binary(),
                  ws_url           :: binary(),
                  site_power_kw    :: pos_integer(),
                  tariff_cents_kwh :: pos_integer(),
                  total            :: non_neg_integer(),
                  free     = 0     :: non_neg_integer(),
                  held     = 0     :: non_neg_integer(),
                  charging = 0     :: non_neg_integer(),
                  last_seen        :: vs_time:epoch_ms()}).

%% `standby'    — someone else is the leader (or nobody is yet): redirect.
%% `rebuilding' — we just won and are still asking the stations what they hold.
%% `serving'    — leader, in quorum, table rebuilt: the only state that grants.
%% `suspended'  — out of quorum: refuse everything, leader or not (SCOPE §9).
-record(state, {mode      = serving :: serving | rebuilding | suspended | standby,
                leader              :: node() | undefined,
                claims    = #{}     :: #{pos_integer() => #claim{}},
                by_id     = #{}     :: #{binary() => pos_integer()},
                stations  = #{}     :: #{pos_integer() => #station{}},
                suspended = #{}     :: #{pos_integer() => non_neg_integer()},
                grace_s             :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Acquire, as a station would. Exposed for the tests and the shell.
-spec claim(binary(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) -> term().
claim(ReqId, VehicleId, UserId, StationId, ConnId) ->
    gen_server:call(?SERVER, {claim, ReqId, VehicleId, UserId, StationId, ConnId}).

%% The five-field entry is the contract (claim.md §3.2) and the only shape any
%% real station sends. The earlier three- and four-field forms are no longer
%% honoured — anything else is skipped and logged by renew_one/4, one entry at
%% a time, without taking the coordinator down with it.
-spec renew(pos_integer(),
            [{binary(), pos_integer(), pos_integer(), non_neg_integer(), vs_time:epoch_ms()}]) ->
          {renewed, [binary()], [binary()], vs_time:epoch_ms()}.
renew(StationId, Claims) ->
    gen_server:call(?SERVER, {renew, StationId, Claims}).

-spec release(binary(), atom()) -> ok.
release(ClaimId, Reason) ->
    gen_server:cast(?SERVER, {release, ClaimId, Reason}).

station_up(Announcement) ->
    gen_server:cast(?SERVER, Announcement).

station_stats(StationId, Free, Held, Charging) ->
    gen_server:cast(?SERVER, {station_stats, StationId, Free, Held, Charging}).

%% @doc A station has closed a session and written its row to MySQL.
%%
%% Forwarded to the back office and otherwise not acted upon: the coordinator
%% keeps no billing state, and the row it refers to is already in the database.
%% The station calls this instead of talking to Java itself, so that the whole
%% cluster keeps exactly one door onto the back office (piano.md §5.2).
%%
%% The tuple is passed through untouched — same shape on both hops, so there is
%% no translation step that could disagree with contracts/erlang-java.md.
-spec session_closed(tuple()) -> ok.
session_closed(Event) ->
    gen_server:cast(?SERVER, {session_closed, Event}).

%% @doc Cluster map in the shape contracts/erlang-java.md defines.
-spec stations() -> [tuple()].
stations() ->
    gen_server:call(?SERVER, stations).

-spec claims() -> [map()].
claims() ->
    gen_server:call(?SERVER, claims).

-spec mode() -> serving | rebuilding | suspended | standby.
mode() ->
    gen_server:call(?SERVER, mode).

%% @doc Called by vs_coord_election on victory.
%%
%% Winning does not mean serving: the table is empty and the claims the
%% previous leader granted are still out there. The coordinator goes to
%% `rebuilding', asks the stations, and only then serves — granting before
%% that would break P2 exactly while recovering from a failure.
-spec become_leader() -> ok.
become_leader() ->
    gen_server:cast(?SERVER, become_leader).

%% @doc Someone else won. Stations that ask us are redirected to them.
-spec become_follower(node()) -> ok.
become_follower(Leader) ->
    gen_server:cast(?SERVER, {become_follower, Leader}).

%% @doc Out of quorum. Refuse everything until the majority is back.
-spec suspend() -> ok.
suspend() ->
    gen_server:cast(?SERVER, suspend).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    %% Claims outlive the reservation they protect by this margin, so that a
    %% claim never expires while the lease it guards is still running.
    Grace = vs_env:get_int("CLAIM_GRACE_SECONDS", 60),
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),

    %% Where a coordinator starts depends on whether it has peers.
    %%
    %% Alone — M1, the tests, a compose with coord2/coord3 still commented out
    %% — there is nothing to elect and no partition to be on the wrong side of,
    %% so it serves immediately. With peers it starts in `standby' and waits to
    %% be told: assuming authority on boot is how two leaders appear after a
    %% cluster-wide restart.
    case vs_env:get_nodes("COORD_NODES", [node()]) -- [node()] of
        [] ->
            logger:notice("coordinator ~p ready, serving (single node)", [node()]),
            {ok, #state{grace_s = Grace, mode = serving, leader = node()}};
        Peers ->
            logger:notice("coordinator ~p on standby, ~p peer(s), awaiting election",
                          [node(), length(Peers)]),
            {ok, #state{grace_s = Grace, mode = standby, leader = undefined}}
    end.

%% --- acquire --------------------------------------------------------

handle_call({claim, ReqId, VehicleId, UserId, StationId, ConnId}, _From, State) ->
    {Reply, State1} = do_claim(ReqId, VehicleId, UserId, StationId, ConnId, State),
    {reply, Reply, State1};

handle_call({renew, StationId, Claims}, _From, State) ->
    {Reply, State1} = do_renew(StationId, Claims, State),
    {reply, Reply, State1};

handle_call(stations, _From, State) ->
    {reply, station_tuples(State), State};

handle_call(claims, _From, State) ->
    {reply, [claim_to_map(C) || C <- maps:values(State#state.claims)], State};

handle_call(mode, _From, State) ->
    {reply, State#state.mode, State};

handle_call(Unknown, _From, State) ->
    logger:warning("coordinator: unexpected call ~p", [Unknown]),
    {reply, {error, unknown_request}, State}.

%% --- release, announcements ------------------------------------------

handle_cast({release, ClaimId, Reason}, State) ->
    {noreply, drop_claim(ClaimId, Reason, State)};

%% Announcements are casts, and a cast has no reply channel — so unlike a claim
%% or a renewal they cannot be answered with `not_serving'. A station therefore
%% keeps announcing itself to whichever coordinator it tried first, which after
%% an election is very often not the leader, and the leader ends up not knowing
%% that station exists at all.
%%
%% A follower fixes that on the station's behalf: it records the announcement
%% (useful to itself if it is ever elected — it will know whom to ask) and
%% passes it on to the leader it knows about. Wrapped in `forwarded' so the
%% second hop handles it and never relays again: two coordinators that briefly
%% disagree about who leads cannot bounce a message between them.
handle_cast({forwarded, Msg}, State) ->
    {noreply, apply_announcement(Msg, State)};

handle_cast(Msg, State) when element(1, Msg) =:= station_up;
                             element(1, Msg) =:= station_stats ->
    State1 = apply_announcement(Msg, State),
    case State1#state.leader of
        undefined -> ok;
        Leader when Leader =:= node() -> ok;
        Leader -> gen_server:cast({?SERVER, Leader}, {forwarded, Msg})
    end,
    {noreply, State1};

%% Straight through to Java. Not stored: if the back office is down the event is
%% dropped, and that is acceptable precisely because it is not the record of the
%% session — the row in MySQL is, and the back office finds it again by sweeping
%% for unpriced sessions. Queueing here would add a second, weaker copy of state
%% the database already keeps.
handle_cast({session_closed, Event}, State) ->
    vs_coord_bo:session_closed(Event),
    {noreply, State};

%% Penalty accounting (M4). Same shape as session_closed and for the same
%% reason: the station observes, the coordinator relays, and **only Java writes
%% the counter** — nothing here keeps a second copy of it.
%%
%% Note what is not done: this coordinator does not suspend anybody on its own
%% initiative. It learns of a suspension when Java tells it (`user_suspended'),
%% because the rule "two consecutive no-shows" needs history that lives in the
%% database, not in a process that any election can replace.
handle_cast({no_show, _UserId, _StationId, _ConnId} = Event, State) ->
    vs_coord_bo:penalty_event(Event),
    {noreply, State};

handle_cast({show_up, _UserId} = Event, State) ->
    vs_coord_bo:penalty_event(Event),
    {noreply, State};

%% --- what the election tells us (M3) ---------------------------------

handle_cast(become_leader, State) ->
    logger:notice("coordinator ~p elected: rebuilding before serving", [node()]),
    _ = vs_coord_rebuild:run(self()),
    vs_coord_bo:announce_leader(),
    {noreply, State#state{mode = rebuilding, leader = node()}};

handle_cast({become_follower, Leader}, State) ->
    logger:notice("coordinator ~p standing by, leader is ~p", [node(), Leader]),
    vs_coord_bo:standing_by(),
    %% The claim table is dropped on purpose. A follower that kept a stale copy
    %% would answer `claims()' with reservations it no longer knows anything
    %% about, and would carry that staleness into its own rebuild if it were
    %% later elected. The stations hold the authoritative copy; a follower that
    %% wins asks them again from scratch.
    {noreply, State#state{mode = standby, leader = Leader,
                          claims = #{}, by_id = #{}}};

handle_cast(suspend, State) ->
    vs_coord_bo:standing_by(),
    {noreply, State#state{mode = suspended, leader = undefined,
                          claims = #{}, by_id = #{}}};

handle_cast(Unknown, State) ->
    logger:warning("coordinator: unexpected cast ~p", [Unknown]),
    {noreply, State}.

%% --- messages from the back office, and housekeeping ------------------
%%
%% JInterface sends plain messages, not gen_server calls, so they land here.

handle_info({From, get_stations}, State) ->
    From ! {stations_update, station_tuples(State)},
    {noreply, State};

handle_info({From, get_suspensions}, State) ->
    From ! {suspensions, maps:to_list(State#state.suspended)},
    {noreply, State};

handle_info({user_suspended, UserId, UntilEpochSeconds}, State) ->
    logger:notice("user ~p suspended until ~p", [UserId, UntilEpochSeconds]),
    Suspended = maps:put(UserId, UntilEpochSeconds, State#state.suspended),
    {noreply, State#state{suspended = Suspended}};

handle_info({user_unsuspended, UserId}, State) ->
    {noreply, State#state{suspended = maps:remove(UserId, State#state.suspended)}};

handle_info(sweep, State) ->
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {noreply, sweep_expired(State)};

%% A station node died: its reservations cannot be honoured, so the vehicles
%% it was holding are freed. Doing nothing here would lock those drivers out
%% of the whole network until their claims expired.
handle_info({nodedown, Node}, State) ->
    {noreply, forget_node(Node, State)};

%% The stations have answered the rebuild query (M3). Adopt what they hold and
%% start serving.
handle_info({rebuilt, Holds}, State = #state{mode = rebuilding}) ->
    State1 = lists:foldl(fun adopt_station/2, State, Holds),
    Count = maps:size(State1#state.claims),
    logger:notice("coordinator ~p serving with ~p adopted claim(s)", [node(), Count]),
    publish(State1),
    {noreply, State1#state{mode = serving}};

%% Late or irrelevant: we lost quorum, or were deposed, while the query was in
%% flight. Adopting now would rebuild a table we have no right to serve from.
handle_info({rebuilt, _Holds}, State) ->
    logger:info("coordinator: discarding a rebuild answer, mode is ~p", [State#state.mode]),
    {noreply, State};

handle_info(Info, State) ->
    logger:debug("coordinator: ignoring ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% claims
%%%===================================================================

do_claim(ReqId, VehicleId, UserId, StationId, ConnId, State) ->
    case check_can_grant(VehicleId, UserId, StationId, State) of
        ok ->
            Now = vs_time:now_ms(),
            Lease = vs_env:get_int("LEASE_SECONDS", 900),
            Claim = #claim{claim_id   = new_claim_id(),
                           vehicle_id = VehicleId,
                           user_id    = UserId,
                           station_id = StationId,
                           conn_id    = ConnId,
                           granted_at = Now,
                           expires_at = Now + (Lease + State#state.grace_s) * 1000},
            %% GrantedAt travels back with the grant (contract PR of 24/08): the
            %% station stores it and echoes it in every renew, so that ordering
            %% is decided by one clock — this one — instead of comparing
            %% timestamps produced by machines that were never synchronised.
            {{ok, ReqId, Claim#claim.claim_id, Claim#claim.granted_at, Claim#claim.expires_at},
             store(Claim, State)};
        {error, Reason} ->
            {{error, ReqId, Reason}, State};
        {not_serving, Leader} ->
            %% Note the shape: `not_serving' carries no ReqId, because it is
            %% not an answer about this request — it is a routing correction
            %% (claim.md §3.1).
            {{not_serving, Leader}, State}
    end.

check_can_grant(VehicleId, UserId, StationId, State) ->
    case State#state.mode of
        %% Not the leader: send the station to whoever is, so it can retry
        %% without waiting for a timeout (claim.md §4). `undefined' is a valid
        %% answer — it means we do not know either, and the station should
        %% work through COORD_NODES itself.
        standby   -> {not_serving, State#state.leader};
        %% Out of quorum we do not even name a leader: whatever we last
        %% believed may well be on the other side of the partition, and
        %% sending the station there would be worse than saying nothing.
        suspended -> {not_serving, undefined};
        serving ->
            case is_suspended(UserId, State) of
                true -> {error, suspended};
                false ->
                    case maps:is_key(StationId, State#state.stations) of
                        false -> {error, unknown_station};
                        true ->
                            case live_claim(VehicleId, State) of
                                none -> ok;
                                _    -> {error, already_held}
                            end
                    end
            end;
        %% We are the leader but do not yet know what the previous one had
        %% granted. Refusing for a second is the safe direction; granting
        %% blind is the one that breaks P2.
        rebuilding -> {error, rebuilding}
    end.

%% A claim past its expiry is treated as absent: the sweep will remove it,
%% but a request must not be refused because of a row nobody cleaned up yet.
live_claim(VehicleId, State) ->
    case maps:find(VehicleId, State#state.claims) of
        {ok, Claim} ->
            case vs_time:expired(Claim#claim.expires_at) of
                true  -> none;
                false -> Claim
            end;
        error -> none
    end.

is_suspended(UserId, State) ->
    case maps:find(UserId, State#state.suspended) of
        {ok, Until} -> Until > erlang:system_time(second);
        error       -> false
    end.

%%%===================================================================
%%% renewal — where a new leader learns about claims it never granted
%%%===================================================================

%% A renewal to a coordinator that is not serving is redirected, not answered.
%% Renewals are also how a leader adopts claims it never granted, so answering
%% them while in standby would build a table this node has no right to hold —
%% and, worse, would let the station believe its claims are safe here.
do_renew(_StationId, _Claims, State) when State#state.mode =:= standby ->
    {{not_serving, State#state.leader}, State};
do_renew(_StationId, _Claims, State) when State#state.mode =:= suspended ->
    {{not_serving, undefined}, State};

do_renew(StationId, Claims, State) ->
    Lease = vs_env:get_int("LEASE_SECONDS", 900),
    NewExpiry = vs_time:now_ms() + (Lease + State#state.grace_s) * 1000,
    {Ok, Revoked, State1} =
        lists:foldl(
          fun(Entry, Acc) -> renew_one(Entry, StationId, NewExpiry, Acc) end,
          {[], [], State},
          Claims),
    {{renewed, lists:reverse(Ok), lists:reverse(Revoked), NewExpiry}, State1}.

%% Once per renewal rather than once per claim: a station on the old form sends
%% one every 10 seconds, and a line per claim would drown the log.
%% Current form, five fields (contract PR of 24/08): `UserId' lets a leader that
%% adopts a claim enforce suspensions straight away, without waiting for the
%% who_do_you_hold of M3, and `GrantedAt' is the one this coordinator issued.
%%
%% The two shorter forms below are tolerated rather than refused. A
%% function_clause here would take the whole coordinator down on a routine
%% renewal — every ten seconds, losing every claim it holds — which is a far
%% worse failure than a missing field we can substitute. They cost three lines
%% and remove an entire class of integration accident.
renew_one({ClaimId, VehicleId, ConnId, UserId, GrantedAt}, StationId, NewExpiry, {Ok, Revoked, State}) ->
    case maps:find(VehicleId, State#state.claims) of
        {ok, #claim{claim_id = ClaimId} = Existing} ->
            %% Ours, still valid: push the expiry forward.
            Updated = Existing#claim{expires_at = NewExpiry},
            {[ClaimId | Ok], Revoked, store(Updated, State)};

        {ok, #claim{granted_at = OtherGrantedAt} = Other} when GrantedAt < OtherGrantedAt ->
            %% Two stations hold the same vehicle and this one got it first.
            %% Oldest wins (contracts/claim.md §5): adopt this, revoke that.
            logger:warning("claim conflict on vehicle ~p: ~p wins over ~p",
                           [VehicleId, ClaimId, Other#claim.claim_id]),
            State1 = erase_claim(Other, State),
            Adopted = #claim{claim_id   = ClaimId,
                             vehicle_id = VehicleId,
                             user_id    = pick_user(UserId, Other#claim.user_id),
                             station_id = StationId,
                             conn_id    = ConnId,
                             granted_at = GrantedAt,
                             expires_at = NewExpiry},
            {[ClaimId | Ok], [Other#claim.claim_id | Revoked], store(Adopted, State1)};

        {ok, _Older} ->
            %% Someone else holds this vehicle and got it first: this one loses.
            {Ok, [ClaimId | Revoked], State};

        error ->
            %% Unknown claim for a free vehicle: the failover case. The previous
            %% leader granted it and we never saw it, so we adopt it with the
            %% granted_at the station reports — inventing one here would make the
            %% claim look brand new and lose every "oldest wins" comparison.
            %% UserId comes with it too, which is what lets suspensions apply to
            %% an adopted claim immediately instead of from M3 onwards.
            Adopted = #claim{claim_id   = ClaimId,
                             vehicle_id = VehicleId,
                             user_id    = UserId,
                             station_id = StationId,
                             conn_id    = ConnId,
                             granted_at = GrantedAt,
                             expires_at = NewExpiry},
            {[ClaimId | Ok], Revoked, store(Adopted, State)}
    end;

%% Anything that is not a five-field entry: skipped and logged, never fatal.
%%
%% This replaces the three- and four-field clauses that used to be tolerated here. A agreed to
%% removing them (nota-per-B-m2a.md §6): no station has sent those shapes since the contract
%% settled on 24/08, so they were branches nobody could reach — and an unreachable branch is
%% one more thing to explain, not one less.
%%
%% What is NOT restored along with them is the crash. The lesson of 24/08 was never "support
%% the old tuples": it was that one unexpected message killed the process holding every claim
%% in the network, on a message that arrives every ten seconds. So a malformed entry now costs
%% **one claim**, not the coordinator. The station will find that claim in neither `Ok` nor
%% `Revoked` and will renew it again on the next tick, which is the right outcome for a
%% transient fault and a loud one for a permanent bug.
renew_one(Malformed, StationId, _NewExpiry, Acc) ->
    logger:warning("renew from station ~p: unusable entry ~p, skipped", [StationId, Malformed]),
    Acc.

%% The two announcement casts, applied to our own table. Separated out so that
%% a forwarded copy takes exactly the same path as a direct one.
apply_announcement({station_up, StationId, Node, Name, WsUrl, SitePowerKw, Tariff, Connectors},
                   State) ->
    do_station_up(StationId, Node, Name, WsUrl, SitePowerKw, Tariff, Connectors, State);
apply_announcement({station_stats, StationId, Free, Held, Charging}, State) ->
    do_station_stats(StationId, Free, Held, Charging, State);
apply_announcement(Other, State) ->
    logger:warning("coordinator: unexpected announcement ~p", [Other]),
    State.

%% Adopt everything one station reports (claim.md §3.4).
%%
%% Reuses renew_one/4, which already knows how to adopt an unknown claim and
%% how to settle a conflict by "oldest wins" — the two things a rebuild needs.
%% The station's own `ExpiresAt' is passed as the new expiry, so adoption
%% preserves the lease the driver was promised instead of silently extending
%% it.
%%
%% Anything revoked here is dropped without telling the loser directly: it
%% learns on its next renewal, within ten seconds, through the ordinary
%% `Revoked' list. Convergence needs no extra message, and there is no push
%% path to keep working.
adopt_station({StationId, Holds}, State) ->
    {_Ok, _Revoked, State1} =
        lists:foldl(
          fun({VehicleId, UserId, ConnId, ClaimId, GrantedAt, ExpiresAt}, Acc) ->
                  renew_one({ClaimId, VehicleId, ConnId, UserId, GrantedAt},
                            StationId, ExpiresAt, Acc);
             (Malformed, Acc) ->
                  logger:warning("rebuild: station ~p sent an unusable claim ~p",
                                 [StationId, Malformed]),
                  Acc
          end,
          {[], [], State}, Holds),
    State1.

%%%===================================================================
%%% stations
%%%===================================================================

do_station_up(StationId, Node, Name, WsUrl, SitePowerKw, Tariff, Connectors, State) ->
    monitor_once(Node, State),
    Station = #station{id               = StationId,
                       node             = Node,
                       name             = Name,
                       ws_url           = WsUrl,
                       site_power_kw    = SitePowerKw,
                       tariff_cents_kwh = Tariff,
                       total            = length(Connectors),
                       free             = length(Connectors),
                       last_seen        = vs_time:now_ms()},
    Known = maps:is_key(StationId, State#state.stations),
    Stations = maps:put(StationId, keep_counters(Station, State), State#state.stations),
    State1 = State#state{stations = Stations},
    case Known of
        true  -> ok;
        false -> logger:notice("station ~p announced from ~p", [StationId, Node])
    end,
    publish(State1),
    State1.

%% A re-announcement (every 30 s) must not reset the counters to "all free":
%% the station keeps sending stats separately, and losing them would make the
%% lobby flicker between the real figures and an empty station.
keep_counters(New = #station{id = Id}, State) ->
    case maps:find(Id, State#state.stations) of
        {ok, Old} -> New#station{free     = Old#station.free,
                                 held     = Old#station.held,
                                 charging = Old#station.charging};
        error -> New
    end.

do_station_stats(StationId, Free, Held, Charging, State) ->
    case maps:find(StationId, State#state.stations) of
        {ok, Station} ->
            Updated = Station#station{free      = Free,
                                      held      = Held,
                                      charging  = Charging,
                                      last_seen = vs_time:now_ms()},
            State1 = State#state{stations = maps:put(StationId, Updated, State#state.stations)},
            publish(State1),
            State1;
        error ->
            %% Stats before the announcement: harmless, the announcement follows.
            State
    end.

%% `monitor_node/2' is idempotent per process, but asking twice would deliver
%% two `nodedown' messages, so it is only set for a node we do not know yet.
monitor_once(Node, State) ->
    Known = lists:any(fun(#station{node = N}) -> N =:= Node end,
                      maps:values(State#state.stations)),
    case Known of
        true  -> ok;
        false -> erlang:monitor_node(Node, true)
    end.

forget_node(Node, State) ->
    Gone = [Id || #station{id = Id, node = N} <- maps:values(State#state.stations), N =:= Node],
    case Gone of
        [] -> State;
        _  ->
            %% Stop monitoring: the stations are about to be forgotten, so
            %% monitor_once/2 would install a second monitor when the node
            %% comes back and every later crash would arrive twice.
            erlang:monitor_node(Node, false),
            logger:warning("node ~p is down, dropping stations ~p and their claims", [Node, Gone]),
            Stations = maps:without(Gone, State#state.stations),
            State1 = lists:foldl(fun(Id, Acc) -> drop_station_claims(Id, Acc) end,
                                 State#state{stations = Stations}, Gone),
            publish(State1),
            State1
    end.

drop_station_claims(StationId, State) ->
    Doomed = [C || C <- maps:values(State#state.claims), C#claim.station_id =:= StationId],
    lists:foldl(fun erase_claim/2, State, Doomed).

%%%===================================================================
%%% housekeeping
%%%===================================================================

%% The backstop of the whole design: whatever else goes wrong — a station that
%% never releases, a crash between granting and committing — a claim stops
%% blocking its vehicle once it expires.
sweep_expired(State) ->
    Expired = [C || C <- maps:values(State#state.claims),
                    vs_time:expired(C#claim.expires_at)],
    case Expired of
        [] -> State;
        _  ->
            logger:notice("sweeping ~p expired claim(s)", [length(Expired)]),
            lists:foldl(fun erase_claim/2, State, Expired)
    end.

drop_claim(ClaimId, Reason, State) ->
    case maps:find(ClaimId, State#state.by_id) of
        {ok, VehicleId} ->
            case maps:find(VehicleId, State#state.claims) of
                {ok, #claim{claim_id = ClaimId} = Claim} ->
                    logger:debug("claim ~p released (~p)", [ClaimId, Reason]),
                    erase_claim(Claim, State);
                {ok, _Newer} ->
                    %% The vehicle has already moved on to a different claim, so
                    %% this release is stale. Drop the index entry, never the
                    %% claim that is currently valid. This is the check that
                    %% keeps a late release from breaking P2.
                    logger:notice("stale release for ~p ignored (~p)", [ClaimId, Reason]),
                    State#state{by_id = maps:remove(ClaimId, State#state.by_id)};
                error ->
                    State#state{by_id = maps:remove(ClaimId, State#state.by_id)}
            end;
        error ->
            %% Releases are best effort: a duplicate or late one is not an error.
            State
    end.

%% Storing a claim must also retire the one it replaces.
%%
%% A vehicle whose claim has expired is treated as free (see live_claim/2), so a
%% new claim legitimately overwrites `claims[VehicleId]' while the old claim id
%% is still sitting in `by_id'. Left there, those entries accumulate for the
%% life of the node: nothing else removes them, because the sweep only walks
%% `claims'.
%%
%% Note that what protects P2 against a stale release is the identity check in
%% drop_claim/3, not this: this keeps the index from growing without bound.
store(Claim = #claim{vehicle_id = VehicleId, claim_id = ClaimId}, State) ->
    ByIdClean =
        case maps:find(VehicleId, State#state.claims) of
            {ok, #claim{claim_id = Previous}} when Previous =/= ClaimId ->
                maps:remove(Previous, State#state.by_id);
            _ ->
                State#state.by_id
        end,
    State#state{claims = maps:put(VehicleId, Claim, State#state.claims),
                by_id  = maps:put(ClaimId, VehicleId, ByIdClean)}.

erase_claim(#claim{vehicle_id = VehicleId, claim_id = ClaimId}, State) ->
    State#state{claims = maps:remove(VehicleId, State#state.claims),
                by_id  = maps:remove(ClaimId, State#state.by_id)}.

%% A renewal in one of the tolerated short forms carries no user: keep whatever
%% the coordinator already knew rather than overwriting it with a placeholder.
pick_user(0, Known)     -> Known;
pick_user(UserId, _)    -> UserId.

%% encode_hex/1 rather than /2: uppercase is fine for an identifier that only
%% has to be readable in a log, and the default costs one argument less.
new_claim_id() ->
    <<"c-", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>.

%%%===================================================================
%%% publishing towards the back office
%%%===================================================================

%% The tuple shape is fixed by contracts/erlang-java.md; Java parses it
%% positionally, so the order matters more than it looks.
station_tuples(State) ->
    [{S#station.id,
      S#station.node,
      S#station.name,
      S#station.free,
      S#station.held,
      S#station.charging,
      S#station.total,
      S#station.site_power_kw,
      S#station.tariff_cents_kwh,
      S#station.ws_url}
     || S <- maps:values(State#state.stations)].

%% Fire and forget: if the bridge is not up yet, the back office will ask for a
%% snapshot itself when it connects. The expression form `catch Expr' is
%% deprecated from OTP 29, so the guarding is written out in full.
publish(State) ->
    try
        vs_coord_bo:publish(station_tuples(State))
    catch
        _:_ -> ok
    end,
    ok.

claim_to_map(#claim{} = C) ->
    #{claim_id   => C#claim.claim_id,
      vehicle_id => C#claim.vehicle_id,
      user_id    => C#claim.user_id,
      station_id => C#claim.station_id,
      conn_id    => C#claim.conn_id,
      granted_at => C#claim.granted_at,
      expires_at => C#claim.expires_at}.
