%%%-------------------------------------------------------------------
%%% @doc Tests for the allocator.
%%%
%%% No processes, no ETS, no clock: every test here is a list and a
%%% number. That is the whole reason `vs_power' is a module of its own —
%%% the policy of SCOPE §3.5 is the part worth showing, and it should be
%%% readable without a station around it.
%%%
%%% The six scenarios of the plan's §8 are transcribed with their exact
%%% expected numbers, computed by hand from the seed topology. They are
%%% the specification: if the allocator disagrees, the allocator is
%%% wrong.
%%%-------------------------------------------------------------------
-module(vs_power_tests).
-include_lib("eunit/include/eunit.hrl").

-define(MIN_KW, 6).
-define(TAPER_SOC, 80).
-define(TAPER_MARGIN, 5).

%% Floats come out of a division: comparing them with =:= would be a test
%% that fails for the wrong reason. One watt of tolerance is far below
%% anything the domain cares about and far above the arithmetic noise.
-define(EPS, 0.001).

%%%===================================================================
%%% helpers
%%%===================================================================

%% Sessions in arrival order: the first element started first. Only the
%% *ordering* of started_at matters to the policy, so the literal values
%% are an arithmetic sequence rather than a clock.
sessions(Demands) ->
    {Sessions, _} =
        lists:foldl(fun(Demand, {Acc, N}) ->
                            {[#{conn_id    => N,
                                demand_kw  => Demand,
                                started_at => 1000 + N} | Acc], N + 1}
                    end, {[], 1}, Demands),
    lists:reverse(Sessions).

assert_alloc(Expected, Alloc) ->
    ?assertEqual(length(Expected), maps:size(Alloc)),
    lists:foreach(fun({N, Want}) ->
                          Got = maps:get(N, Alloc),
                          ?assert(is_float(Got)),
                          case abs(Got - Want) =< ?EPS of
                              true  -> ok;
                              false -> ?assertEqual({conn, N, Want}, {conn, N, Got})
                          end
                  end, lists:zip(lists:seq(1, length(Expected)), Expected)).

total(Alloc) -> lists:sum(maps:values(Alloc)).

near(Expected, Actual) -> abs(Expected - Actual) =< ?EPS.

%% A property that fails must say on which input. `?assert(Cond)' would
%% print the condition and nothing else, and the sweep below has 112 of
%% them.
check(_Context, true)     -> ok;
check(Context,  false)    -> erlang:error({property_failed, Context}).

%%%===================================================================
%%% the six scenarios of §8 — the numbers are the specification
%%%===================================================================

%% One 150 kW car alone on station 2. The budget is not the binding
%% constraint; the car is.
one_car_takes_its_own_demand_test() ->
    Alloc = vs_power:allocate(180, sessions([150]), ?MIN_KW),
    assert_alloc([150.0], Alloc),
    ?assert(abs(total(Alloc) - 150.0) =< ?EPS).

%% Two cars, 200 kW of demand against 180 of budget. The 50 kW car cannot
%% absorb its 90 kW share, hands back 40, and the big one takes it: 130.
%% This is the case the whole step exists for — before it, the station
%% handed out 150 + 50 = 200 on a 180 kW site.
two_cars_the_small_one_hands_back_its_surplus_test() ->
    Alloc = vs_power:allocate(180, sessions([150, 50]), ?MIN_KW),
    assert_alloc([130.0, 50.0], Alloc),
    ?assert(abs(total(Alloc) - 180.0) =< ?EPS).

%% Three cars: 60 each to start with, both 50 kW cars are satisfied and
%% return 20, the big one ends on 80.
three_cars_on_station_two_test() ->
    Alloc = vs_power:allocate(180, sessions([150, 50, 50]), ?MIN_KW),
    assert_alloc([80.0, 50.0, 50.0], Alloc),
    ?assert(abs(total(Alloc) - 180.0) =< ?EPS).

%% Station 1 full: 87.5 each, the 50 kW car returns 37.5, the three big
%% ones split 300 into 100 apiece.
four_cars_on_station_one_test() ->
    Alloc = vs_power:allocate(350, sessions([150, 150, 150, 50]), ?MIN_KW),
    assert_alloc([100.0, 100.0, 100.0, 50.0], Alloc),
    ?assert(abs(total(Alloc) - 350.0) =< ?EPS).

%% The third car is above TAPER_SOC_PCT and is only absorbing 40, so its
%% demand has fallen to 45. The two full-rate cars pick up what it no
%% longer wants: 127.5 each instead of 100. Nothing is wasted, which is
%% the property the round-robin hand-back is there for.
taper_frees_power_for_the_others_test() ->
    Alloc = vs_power:allocate(350, sessions([150, 150, 45, 50]), ?MIN_KW),
    assert_alloc([127.5, 127.5, 45.0, 50.0], Alloc),
    ?assert(abs(total(Alloc) - 350.0) =< ?EPS).

%% Suspension, with a budget no real station has: 15 kW between three
%% cars is 5 each, below MIN_CHARGE_KW. The most recent arrival is
%% suspended and the other two rise to 7.5 — above the floor, which is
%% the point: two cars charging beats three cars trickling.
suspension_drops_the_most_recent_arrival_test() ->
    Alloc = vs_power:allocate(15, sessions([50, 50, 50]), ?MIN_KW),
    assert_alloc([7.5, 7.5, 0.0], Alloc),
    ?assert(abs(total(Alloc) - 15.0) =< ?EPS).

%%%===================================================================
%%% the properties — true of every allocation, not of one
%%%===================================================================

%% A deliberate sweep rather than random input: a property test that
%% cannot be re-run on the same input is a property test that reports a
%% failure nobody can reproduce.
cases() ->
    [{Budget, Demands}
     || Budget  <- [0, 1, 6, 15, 42, 180, 350, 1000],
        Demands <- [[], [150], [150, 50], [150, 50, 50], [150, 150, 150, 50],
                    [150, 150, 45, 50], [50, 50, 50], [3, 50], [50, 3],
                    [3, 3, 3], [6, 6], [7, 7, 7], [0, 50], [22.5, 22.5]]].

allocations_never_exceed_the_budget_test() ->
    lists:foreach(
      fun({Budget, Demands}) ->
              Alloc = vs_power:allocate(Budget, sessions(Demands), ?MIN_KW),
              %% the tolerance is on the *sum*: repeated splitting can
              %% land a few ulps above the budget without anything being
              %% wrong with the policy
              check({budget, Budget, Demands, total(Alloc)},
                    total(Alloc) =< Budget + ?EPS)
      end, cases()).

no_session_gets_more_than_it_asked_for_test() ->
    lists:foreach(
      fun({Budget, Demands}) ->
              Sessions = sessions(Demands),
              Alloc = vs_power:allocate(Budget, Sessions, ?MIN_KW),
              lists:foreach(
                fun(#{conn_id := Id, demand_kw := Demand}) ->
                        Got = maps:get(Id, Alloc),
                        check({over_demand, Budget, Demands, Id, Got, Demand},
                              Got =< Demand + ?EPS)
                end, Sessions)
      end, cases()).

%% The floor is a floor: an allocation is either zero — suspended, and the
%% contract's own way of saying so — or at least MIN_CHARGE_KW. Nothing
%% trickles.
nothing_is_allocated_between_zero_and_the_floor_test() ->
    lists:foreach(
      fun({Budget, Demands}) ->
              Alloc = vs_power:allocate(Budget, sessions(Demands), ?MIN_KW),
              maps:foreach(
                fun(Id, Kw) ->
                        check({trickle, Budget, Demands, Id, Kw},
                              Kw =:= +0.0 orelse Kw >= ?MIN_KW - ?EPS)
                end, Alloc)
      end, cases()).

%% Every session gets an answer, suspended ones included: the manager
%% sends `set_limit' to all of them on every recomputation (§5), so a
%% missing key would be a connector left on a stale limit.
every_session_appears_in_the_result_test() ->
    lists:foreach(
      fun({Budget, Demands}) ->
              Sessions = sessions(Demands),
              Alloc = vs_power:allocate(Budget, Sessions, ?MIN_KW),
              ?assertEqual(length(Sessions), maps:size(Alloc)),
              lists:foreach(fun(#{conn_id := Id}) ->
                                    ?assert(maps:is_key(Id, Alloc))
                            end, Sessions)
      end, cases()).

%%%===================================================================
%%% the corners the six scenarios do not reach
%%%===================================================================

nothing_charging_allocates_nothing_test() ->
    ?assertEqual(#{}, vs_power:allocate(180, [], ?MIN_KW)).

%% A site with no power to give suspends everybody rather than handing
%% out a row of zeros that pretend to be allocations.
a_zero_budget_suspends_everyone_test() ->
    Alloc = vs_power:allocate(0, sessions([150, 50]), ?MIN_KW),
    assert_alloc([0.0, 0.0], Alloc).

%% The refinement of the plan's rule. A session whose *own demand* is
%% below the floor cannot be helped by suspending anybody else — no
%% amount of freed budget lifts it above what it is asking for. So it is
%% the one that goes, and the 50 kW car keeps charging. Under the literal
%% "always the most recent" rule the 50 would be suspended first, the 3
%% would still be under the floor, and the site would end up allocating
%% nothing at all with 180 kW free.
a_session_asking_less_than_the_floor_suspends_itself_test() ->
    %% the small one arrived *first*: the literal rule would take the 50
    Alloc = vs_power:allocate(180, sessions([3, 50]), ?MIN_KW),
    assert_alloc([0.0, 50.0], Alloc),
    ?assert(abs(total(Alloc) - 50.0) =< ?EPS).

%% Same shape, the other arrival order: the answer must not depend on it.
a_session_asking_less_than_the_floor_suspends_itself_either_order_test() ->
    Alloc = vs_power:allocate(180, sessions([50, 3]), ?MIN_KW),
    assert_alloc([50.0, 0.0], Alloc).

%% Budget contention is still resolved by arrival: this is the plan's
%% rule, untouched, in the case it was designed for. 17/3 is 5.67, under
%% the floor; with the newest gone the other two get 8.5 each.
under_budget_pressure_the_newest_still_goes_test() ->
    Alloc = vs_power:allocate(17, sessions([50, 50, 50]), ?MIN_KW),
    assert_alloc([8.5, 8.5, 0.0], Alloc).

%% And one notch above, nobody is suspended at all: 20/3 is 6.67, over the
%% floor. The rule only fires when it has to.
just_above_the_floor_nobody_is_suspended_test() ->
    Alloc = vs_power:allocate(20, sessions([50, 50, 50]), ?MIN_KW),
    assert_alloc([6.6667, 6.6667, 6.6667], Alloc).

%% Two sessions that started in the same millisecond: the rule needs a
%% total order or it is not a rule. The higher connector id is treated as
%% the more recent arrival, so the outcome is the same on every node and
%% on every tick.
a_tie_on_started_at_is_broken_by_connector_id_test() ->
    Sessions = [#{conn_id => 1, demand_kw => 50, started_at => 1000},
                #{conn_id => 2, demand_kw => 50, started_at => 1000},
                #{conn_id => 3, demand_kw => 50, started_at => 1000}],
    Alloc = vs_power:allocate(15, Sessions, ?MIN_KW),
    ?assertEqual(0.0, maps:get(3, Alloc)),
    ?assert(abs(maps:get(1, Alloc) - 7.5) =< ?EPS),
    ?assert(abs(maps:get(2, Alloc) - 7.5) =< ?EPS).

%% Suspension is stable by construction: started_at does not change, so
%% recomputing the same input twice cannot make the set of suspended
%% sessions oscillate. This is why the rule is arrival-based and not
%% SoC-based — a SoC rule changes its own mind between two readings.
the_same_input_allocates_the_same_way_test() ->
    Sessions = sessions([50, 50, 50]),
    ?assertEqual(vs_power:allocate(15, Sessions, ?MIN_KW),
                 vs_power:allocate(15, Sessions, ?MIN_KW)),
    %% and the order the sessions arrive in the list is not the policy
    ?assertEqual(vs_power:allocate(15, Sessions, ?MIN_KW),
                 vs_power:allocate(15, lists:reverse(Sessions), ?MIN_KW)).

%%%===================================================================
%%% demand_kw/3 — the charging curve of §3
%%%===================================================================

%% A session that is being given power. The limit defaults to the pair of
%% ceilings because a snapshot with current flowing and `limit_kw = 0' is
%% a state that cannot exist: zero is what the station sends to stop the
%% flow. Tests that want a *suspended* session pass the limit explicitly.
snapshot(RatedKw, MaxKw, PowerKw, SocPct) ->
    snapshot(RatedKw, MaxKw, PowerKw, SocPct, float(min(RatedKw, MaxKw))).

snapshot(RatedKw, MaxKw, PowerKw, SocPct, LimitKw) ->
    #{connector_id => 5, rated_kw => RatedKw, state => charging,
      power_kw => PowerKw,
      session  => #{user_id => 88, vehicle_id => 88, started_at => 1000,
                    energy_kwh => 1.0, soc_pct => SocPct,
                    max_kw => MaxKw, limit_kw => LimitKw}}.

%% Below the taper threshold the car is in the constant-current phase and
%% takes everything it is given: the outlet's rating and the car's own
%% ceiling are the only limits.
below_the_taper_threshold_demand_is_the_pair_of_ceilings_test() ->
    ?assertEqual(150.0, vs_power:demand_kw(snapshot(150, 150, 0.0, 22),
                                           ?TAPER_SOC, ?TAPER_MARGIN)),
    ?assertEqual(50.0,  vs_power:demand_kw(snapshot(150, 50, 0.0, 22),
                                           ?TAPER_SOC, ?TAPER_MARGIN)),
    ?assertEqual(50.0,  vs_power:demand_kw(snapshot(50, 150, 0.0, 22),
                                           ?TAPER_SOC, ?TAPER_MARGIN)).

%% This is the lock-in the SoC threshold exists to avoid: right after
%% `plugged' the measured power is 0, and a rule that read "asks for what
%% it is absorbing plus a margin" would start this car at 5 kW and let it
%% climb 5 kW per tick. At 22 % it asks for its full 150.
a_just_plugged_car_is_not_throttled_by_its_own_zero_meter_test() ->
    ?assertEqual(150.0, vs_power:demand_kw(snapshot(150, 150, 0.0, 22),
                                           ?TAPER_SOC, ?TAPER_MARGIN)).

%% Above the threshold the car asks for what it is actually taking plus
%% the margin. 40 + 5 = 45, which is scenario 5 of §8.
above_the_taper_threshold_demand_follows_the_meter_test() ->
    ?assertEqual(45.0, vs_power:demand_kw(snapshot(150, 150, 40.0, 85),
                                          ?TAPER_SOC, ?TAPER_MARGIN)).

%% The margin is what lets a demand climb back: without it the allocator
%% would record the lowest reading it ever saw and never let the car
%% recover.
the_margin_lets_a_recovering_demand_climb_back_test() ->
    ?assertEqual(45.0, vs_power:demand_kw(snapshot(150, 150, 40.0, 85),
                                          ?TAPER_SOC, ?TAPER_MARGIN)),
    ?assertEqual(65.0, vs_power:demand_kw(snapshot(150, 150, 60.0, 85),
                                          ?TAPER_SOC, ?TAPER_MARGIN)).

%% The ceilings still apply above the threshold: the margin cannot push a
%% demand past what the outlet or the car can do.
the_taper_never_raises_demand_above_the_ceilings_test() ->
    ?assertEqual(50.0, vs_power:demand_kw(snapshot(150, 50, 50.0, 95),
                                          ?TAPER_SOC, ?TAPER_MARGIN)).

%% Exactly at the threshold the taper rule applies: §3 writes `soc >= 80'.
the_threshold_itself_is_inside_the_taper_test() ->
    ?assertEqual(45.0, vs_power:demand_kw(snapshot(150, 150, 40.0, 80),
                                          ?TAPER_SOC, ?TAPER_MARGIN)).

%% The twin of the lock-in above, and the one that bit. A session that has
%% been suspended is at `limit_kw = 0', so its next meter reports
%% `power_kw = 0' — not because the battery is nearly full, but because we
%% took the current away. Reading the taper off that meter would give
%% 0 + margin = 5 kW, under MIN_CHARGE_KW, which makes the session
%% `demand'-bound and therefore the first one victim/1 suspends: it could
%% never come back, at any budget. While the limit is zero the meter says
%% nothing about the charging curve, so the demand is the pair of
%% ceilings, exactly as below the threshold.
a_suspended_session_above_the_threshold_asks_for_its_ceiling_test() ->
    ?assertEqual(150.0, vs_power:demand_kw(snapshot(150, 150, 0.0, 85, +0.0),
                                           ?TAPER_SOC, ?TAPER_MARGIN)),
    %% the car's own ceiling still binds it
    ?assertEqual(50.0,  vs_power:demand_kw(snapshot(150, 50, 0.0, 85, +0.0),
                                           ?TAPER_SOC, ?TAPER_MARGIN)),
    %% and a session that *is* being given power still tapers
    ?assertEqual(45.0,  vs_power:demand_kw(snapshot(150, 150, 40.0, 85, 45.0),
                                           ?TAPER_SOC, ?TAPER_MARGIN)).

%% §4.2 makes max_kw mandatory, and D5 already reads a missing one as
%% "suspended". The allocator agrees: a car that never said what it can
%% take is asking for nothing, not for everything.
a_session_with_no_max_kw_demands_nothing_test() ->
    Snap = #{connector_id => 5, rated_kw => 150, state => charging,
             power_kw => 0.0,
             session  => #{user_id => 88, vehicle_id => 88, started_at => 1000,
                           soc_pct => 22, limit_kw => 0.0}},
    ?assertEqual(0.0, vs_power:demand_kw(Snap, ?TAPER_SOC, ?TAPER_MARGIN)).

%%%===================================================================
%%% demands/3 — which connectors take part at all
%%%===================================================================

connector(ConnId, State, Extra) ->
    maps:merge(#{connector_id => ConnId, rated_kw => 150, state => State,
                 power_kw => 0.0,
                 session => #{user_id => 88, vehicle_id => 88,
                              started_at => 1000 + ConnId, energy_kwh => 1.0,
                              soc_pct => 22, max_kw => 150, limit_kw => 150.0}},
               Extra).

only_charging_sessions_take_part_test() ->
    Connectors = [connector(1, charging, #{}),
                  connector(2, closing, #{}),
                  #{connector_id => 3, rated_kw => 150, state => free,
                    power_kw => 0.0},
                  #{connector_id => 4, rated_kw => 50, state => offline},
                  #{connector_id => 5, rated_kw => 150, state => held,
                    power_kw => 0.0}],
    Demands = vs_power:demands(Connectors, ?TAPER_SOC, ?TAPER_MARGIN),
    ?assertEqual([1], [Id || #{conn_id := Id} <- Demands]).

%% The one that would be easy to get wrong. `suspended' is what a
%% charging session at limit 0 *reports*; it is still a live session and
%% it must keep competing, or it could never be un-suspended — the
%% allocator would stop seeing it the moment it suspended it, and the
%% starvation would be permanent.
a_suspended_session_still_takes_part_test() ->
    Connectors = [connector(1, charging, #{}),
                  connector(2, suspended, #{power_kw => 0.0})],
    Demands = vs_power:demands(Connectors, ?TAPER_SOC, ?TAPER_MARGIN),
    ?assertEqual([1, 2], lists:sort([Id || #{conn_id := Id} <- Demands])).

demands_carry_the_arrival_instant_test() ->
    [D] = vs_power:demands([connector(7, charging, #{})], ?TAPER_SOC, ?TAPER_MARGIN),
    ?assertEqual(1007, maps:get(started_at, D)),
    ?assertEqual(7, maps:get(conn_id, D)),
    ?assertEqual(150.0, maps:get(demand_kw, D)).

%%%===================================================================
%%% the two halves together: demands/3 feeding allocate/3, twice
%%%===================================================================

live(ConnId, StartedAt, PowerKw, SocPct, LimitKw) ->
    #{connector_id => ConnId, rated_kw => 150, state => charging,
      power_kw => PowerKw,
      session  => #{user_id => 88, vehicle_id => ConnId, started_at => StartedAt,
                    energy_kwh => 1.0, soc_pct => SocPct,
                    max_kw => 150, limit_kw => LimitKw}}.

split(Connectors, Budget) ->
    vs_power:allocate(Budget,
                      vs_power:demands(Connectors, ?TAPER_SOC, ?TAPER_MARGIN),
                      ?MIN_KW).

%% The lock-in described in full, which is the only way to see it: one
%% recomputation suspends a tapering session, the next one has to be able
%% to bring it back. The unit test above says what the demand is; this one
%% says what happens over time, and it is the failure that matters — a car
%% left at zero for ever on a site with nothing else plugged in.
a_session_suspended_above_the_threshold_comes_back_test() ->
    %% Round 1: three cars, 12 kW between them. Everybody's share is 4,
    %% under the floor, so the budget rule suspends the most recent
    %% arrival — which happens to be the one that is tapering.
    Round1 = [live(1, 1001, 0.0,  22, 150.0),
              live(2, 1002, 0.0,  22, 150.0),
              live(3, 1003, 40.0, 85, 45.0)],
    Alloc1 = split(Round1, 12),
    ?assertEqual(+0.0, maps:get(3, Alloc1)),
    ?assert(near(6.0, maps:get(1, Alloc1))),
    ?assert(near(6.0, maps:get(2, Alloc1))),

    %% Round 2: the other two unplug, and the suspended one has obeyed —
    %% its limit is 0 and so is its meter. The whole 12 kW is free and
    %% there is nobody else to give it to.
    Alloc2 = split([live(3, 1003, 0.0, 85, +0.0)], 12),
    ?assert(near(12.0, maps:get(3, Alloc2))),

    %% and once it is drawing again the taper applies as it always did:
    %% 11 absorbed plus the 5 of margin, with budget to spare
    Alloc3 = split([live(3, 1003, 11.0, 85, 12.0)], 20),
    ?assert(near(16.0, maps:get(3, Alloc3))).
