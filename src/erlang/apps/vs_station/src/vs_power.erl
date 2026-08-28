%%%-------------------------------------------------------------------
%%% @doc The power allocator: SCOPE §3.5, as arithmetic.
%%%
%%% A pure module. No process, no ETS, no clock, no environment: every
%%% function here is a list and a number in, a map out. That is
%%% deliberate — the allocation policy is the part of this milestone
%%% worth defending, and it should be readable and testable without a
%%% station around it. The manager is what has the budget, the sessions
%%% and the timer; this is what has the rule.
%%%
%%% ## The policy — fair share with hand-back (max-min fairness)
%%%
%%% Start from `budget / N'. A session that cannot absorb its share — a
%%% small car, or one that is tapering — takes only what it asks for and
%%% hands the surplus back, which is then split again among the rest.
%%% Repeat until nobody hands anything back or there is no budget left.
%%%
%%% Chosen over the two alternatives of §3.5 for what it yields and how
%%% it is defended. Yield: the hand-back is what keeps a kilowatt from
%%% sitting unused while somebody could absorb it — the flaw of plain
%%% equal shares. Proportional-to-demand does not deliver *more*; it
%%% saturates the same budget and only changes who gets what. Defence:
%%% "everyone gets the same share, and whoever cannot use it gives it
%%% back" is one sentence, and it is the textbook max-min fair share.
%%% Proportional has to be argued as a *political* choice ("big cars
%%% matter more"), and reservation-holders-first would starve a walk-in
%%% down to suspension, which contradicts §3.3 — the penalty there takes
%%% away the booking, not the charging.
%%%
%%% ## The floor, and who gets suspended
%%%
%%% §3.5 asks for a minimum viable power below which a session is
%%% suspended rather than starved. A session is suspended — given `0.0',
%%% which is exactly how ws-chargepoint.md §5 expresses it: the session
%%% stays open and draws nothing — when its share is under
%%% `MIN_CHARGE_KW' **and under what it asked for**. Both halves.
%%%
%%% The floor talks about **scarcity**, not about demand. It is there so
%%% that a site with too many cars stops twenty of them trickling at 3 kW
%%% and lets ten charge properly. A session that receives exactly what it
%%% asks for is not being starved by anyone: a nearly full car drawing
%%% 4 kW, or a small one that can only take 5, is getting its charge, and
%%% taking it to zero frees nothing for anybody — the budget removed from
%%% it was not wanted by anyone else.
%%%
%%% *Which* session, when the budget really is short: the most recent
%%% arrival (`started_at' greatest, `conn_id' breaking a tie on the
%%% millisecond). Stable by construction — `started_at' never changes, so
%%% the suspended set cannot oscillate between two ticks while nobody
%%% arrives or leaves. A rule based on SoC would change its own mind at
%%% every meter reading.
%%%
%%% **What was here before, and why it was wrong.** An earlier version
%%% split the starved in two — short of budget, or short by their own
%%% demand — and suspended the demand-bound ones first, on the argument
%%% that no amount of freed budget can lift a session above what it is
%%% asking for. The argument is true and the conclusion does not follow:
%%% such a session does not need lifting, because nobody is holding it
%%% down. Making it suspendable produced a two-tick oscillation on an
%%% empty site — suspending zeroed the limit, a zero limit put the demand
%%% back to the ceiling (see `tapering/2'), the ceiling let the session
%%% straight back in, and the round began again. The fix is not a better
%%% victim order: it is that there was never a victim to choose.
%%%
%%% The corner that motivated the old rule — demands of 3 and 50 kW
%%% against 180 kW of budget — comes out right without it: the 3 kW car
%%% receives its 3 kW and the 50 kW car its 50. Nobody is suspended,
%%% because nobody is short.
%%%
%%% ## The demand of a session, and the taper
%%%
%%% `demand_kw/3' is not `max_kw'. §3.5 wants the tick to account for the
%%% charging curve, so above `TAPER_SOC_PCT' a session asks for what it
%%% is actually absorbing plus `TAPER_MARGIN_KW', and below it for
%%% everything it can take.
%%%
%%% The threshold is on the **SoC**, not on "it is absorbing less than I
%%% gave it", and that is the whole design of this function. The latter
%%% bites its own tail: a `meter' right after `plugged' reports 0, the
%%% demand would become 0 + margin, and the car would be throttled to
%%% climbing 5 kW per tick — a session starved by an algorithm that
%%% thought it was being careful. A SoC threshold has no such lock-in (a
%%% session starts low) and matches the physics the emulator already
%%% reproduces. The margin is what lets a demand climb back up: without
%%% it the allocator would record the taper and never let the car out of
%%% it.
%%%
%%% **The same trap has a twin, and the SoC threshold alone does not shut
%%% it.** A suspended session is at `limit_kw = 0', so its next meter
%%% reports `power_kw = 0' — because the station took the current away,
%%% not because the battery is full. Above the threshold the taper branch
%%% would read that zero and answer 5 kW: under `MIN_CHARGE_KW', which
%%% makes the session `demand'-bound, which makes `victim/1' prefer it to
%%% everybody else. It would be suspended again at every recomputation,
%%% at any budget, for ever — a car left at zero on an empty site.
%%%
%%% So the taper branch asks for two things, not one: above the threshold
%%% **and** receiving power. A meter taken while the limit is zero
%%% measures the station's decision, not the car's curve, and the honest
%%% reading of a session we are not feeding is that it wants everything
%%% it can take.
%%%-------------------------------------------------------------------
-module(vs_power).

-export([allocate/3, demand_kw/3, demands/3]).

%% What the allocator needs to know about a session, and nothing more:
%% no pid, no user, no vehicle. `started_at' is in the map only because
%% the suspension rule orders by arrival.
-type session() :: #{conn_id := pos_integer(),
                     demand_kw := number(),
                     started_at := integer(),
                     _ => _}.

-export_type([session/0]).

%% Kilowatts compared after a division. `=:=' on floats would make the
%% suspension rule fire on arithmetic noise rather than on the domain,
%% so every comparison that decides something goes through this. One
%% milliwatt is far below anything a charge point can act on.
-define(EPS, 1.0e-9).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Split `BudgetKw' among the sessions. Every session gets a key in
%% the result, suspended ones included: the manager re-sends `set_limit'
%% to all of them on every recomputation (ws-chargepoint.md §5 —
%% idempotence by repetition, not diffing), so a missing key would leave
%% a connector on a stale limit.
%%
%% `MinChargeKw' is an argument and not a `vs_env' read on purpose: this
%% module stays a function of its inputs, and the manager reads the
%% environment once.
-spec allocate(number(), [session()], number()) -> #{pos_integer() => float()}.
allocate(BudgetKw, Sessions, MinChargeKw) ->
    allocate(BudgetKw, Sessions, MinChargeKw, #{}).

%% @doc How much a connector's snapshot is asking for, in kW. See the
%% taper discussion at the top.
%%
%% `rated_kw' and `power_kw' sit at the top of the snapshot, `max_kw' and
%% `soc_pct' inside its `session' sub-map — the shape `vs_connector'
%% builds, read here rather than reshaped by the caller.
-spec demand_kw(map(), number(), number()) -> float().
demand_kw(Snapshot, TaperSocPct, TaperMarginKw) ->
    Session = maps:get(session, Snapshot, #{}),
    %% Neither ceiling is decoration: the outlet cannot give more than it
    %% is rated for, and the car cannot take more than it is built for.
    %% A session with no `max_kw' asks for nothing — §4.2 makes the field
    %% mandatory, and D5 already reads a missing one as "suspended".
    Ceiling = min(maps:get(rated_kw, Snapshot, 0), maps:get(max_kw, Session, 0)),
    case tapering(Session, TaperSocPct) of
        false ->
            float(Ceiling);
        true ->
            float(min(Ceiling,
                      maps:get(power_kw, Snapshot, 0) + TaperMarginKw))
    end.

%% Two conditions, and the second one is not decoration. A session is in
%% the taper only if it is above the threshold **and** actually being
%% given power: while its limit is zero the meter reads zero because the
%% station took the current away, which says nothing at all about the
%% battery. See the second lock-in at the top of this module.
tapering(Session, TaperSocPct) ->
    maps:get(soc_pct, Session, 0) >= TaperSocPct
        andalso maps:get(limit_kw, Session, 0) =/= +0.0.

%% @doc The manager's connector list → the allocator's input. Only live
%% sessions take part.
%%
%% Both `charging' **and** `suspended` count as live, and the second one
%% is the trap. `suspended' is not a state of the connector's machine: it
%% is what `build_snapshot' reports for a charging session whose limit is
%% zero. Filtering on `charging' alone would drop a session from the
%% split the moment it was suspended, and nothing would ever put it back
%% — the starvation would become permanent instead of lasting one tick.
-spec demands([map()], number(), number()) -> [session()].
demands(Connectors, TaperSocPct, TaperMarginKw) ->
    [#{conn_id    => maps:get(connector_id, C),
       demand_kw  => demand_kw(C, TaperSocPct, TaperMarginKw),
       started_at => maps:get(started_at, maps:get(session, C), 0)}
     || C <- Connectors, is_live(C)].

%%%===================================================================
%%% internal — the suspension loop
%%%===================================================================

allocate(_BudgetKw, [], _MinChargeKw, Suspended) ->
    Suspended;
allocate(BudgetKw, Sessions, MinChargeKw, Suspended) ->
    Alloc = fair_share(BudgetKw, Sessions),
    case starved(Sessions, Alloc, MinChargeKw) of
        [] ->
            maps:merge(Suspended, Alloc);
        Starved ->
            Victim = victim(Starved),
            allocate(BudgetKw,
                     [S || S <- Sessions, conn_id(S) =/= conn_id(Victim)],
                     MinChargeKw,
                     Suspended#{conn_id(Victim) => 0.0})
    end.

%% Starved means **starved by scarcity**: the share landed under the floor
%% *and* under what the session was asking for. Both halves are the rule,
%% and the second one is the whole correction of D-3/D-4.
%%
%% `MIN_CHARGE_KW' exists because a session throttled by scarcity is better
%% suspended than starved: under 6 kW a car does not charge usefully, and
%% twenty cars trickling at 3 kW serve nobody. But that threshold talks
%% about **scarcity**, not about demand. A session receiving exactly what
%% it asks — a nearly full car drawing 4 kW, a small one that can take 5 —
%% is being starved by nobody, and taking it to zero frees nothing for
%% anybody: the budget removed from it was not wanted by anyone else.
starved(Sessions, Alloc, MinChargeKw) ->
    [S || S <- Sessions, starving(S, Alloc, MinChargeKw)].

starving(S, Alloc, MinChargeKw) ->
    Got = maps:get(conn_id(S), Alloc),
    Got < MinChargeKw - ?EPS andalso Got + ?EPS < demand(S).

%% Among the starved, the most recent arrival, with the connector id
%% breaking a tie on the millisecond so that the rule is a total order and
%% the same input always allocates the same way.
%%
%% There used to be a precedence here: sessions under the floor because of
%% their *own* demand went first, on the argument that no freed budget can
%% lift them. The argument was right and the conclusion was wrong — such a
%% session does not need lifting, because nobody is holding it down. That
%% precedence is what produced the flapping of D-3: suspending zeroed the
%% limit, a zero limit put the demand back to the ceiling, the ceiling let
%% the session back in, and the round started again. Sessions that are not
%% starved are no longer suspendable, so there is nothing left to flap.
victim(Starved) ->
    hd(lists:sort(fun(A, B) ->
                          {maps:get(started_at, A), conn_id(A)} >
                              {maps:get(started_at, B), conn_id(B)}
                  end, Starved)).

%%%===================================================================
%%% internal — one split, with the hand-back
%%%===================================================================

%% Each round hands every session an equal share of what is left. The
%% ones that ask for less than their share are settled at their demand
%% and leave the split, returning the difference; the round repeats on
%% the rest. It terminates because a round either settles nobody — and
%% then everybody gets the same share and it is over — or removes at
%% least one session from the list.
fair_share(BudgetKw, Sessions) ->
    fair_share(BudgetKw, Sessions, #{}).

fair_share(_BudgetKw, [], Alloc) ->
    Alloc;
fair_share(BudgetKw, Sessions, Alloc) when BudgetKw =< 0 ->
    %% Nothing left to give. Said once, here, so no caller has to guard
    %% against a negative share.
    lists:foldl(fun(S, A) -> A#{conn_id(S) => 0.0} end, Alloc, Sessions);
fair_share(BudgetKw, Sessions, Alloc) ->
    Share = BudgetKw / length(Sessions),
    case [S || S <- Sessions, demand(S) =< Share] of
        [] ->
            lists:foldl(fun(S, A) -> A#{conn_id(S) => Share} end, Alloc, Sessions);
        Settled ->
            Alloc1 = lists:foldl(fun(S, A) -> A#{conn_id(S) => demand(S)} end,
                                 Alloc, Settled),
            Ids = [conn_id(S) || S <- Settled],
            fair_share(BudgetKw - lists:sum([demand(S) || S <- Settled]),
                       [S || S <- Sessions, not lists:member(conn_id(S), Ids)],
                       Alloc1)
    end.

%%%===================================================================
%%% internal — accessors
%%%===================================================================

conn_id(#{conn_id := ConnId}) -> ConnId.

%% Always a float, so that an integer demand from a caller cannot make
%% the result of one branch an integer and of another a float.
demand(#{demand_kw := Kw}) -> float(Kw).

is_live(C) ->
    State = maps:get(state, C, offline),
    (State =:= charging orelse State =:= suspended)
        andalso is_map(maps:get(session, C, undefined)).
