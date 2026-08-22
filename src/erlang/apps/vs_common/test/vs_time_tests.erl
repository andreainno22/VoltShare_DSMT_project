-module(vs_time_tests).
-include_lib("eunit/include/eunit.hrl").

now_is_epoch_ms_test() ->
    Now = vs_time:now_ms(),
    ?assert(Now > 1_700_000_000_000),   %% after Nov 2023: it really is ms, not s
    ?assert(Now < 4_000_000_000_000).

in_seconds_test() ->
    Lease = vs_time:in_seconds(900),
    Delta = Lease - vs_time:now_ms(),
    ?assert(Delta =< 900_000),
    ?assert(Delta > 899_000).

expiry_test() ->
    ?assert(vs_time:expired(vs_time:now_ms() - 1)),
    ?assertNot(vs_time:expired(vs_time:in_seconds(10))).

remaining_never_negative_test() ->
    %% the result feeds a timer, so a past deadline must give 0, not a
    %% negative number that would crash erlang:send_after/3
    ?assertEqual(0, vs_time:remaining_ms(vs_time:now_ms() - 5000)),
    ?assert(vs_time:remaining_ms(vs_time:in_seconds(5)) > 4000).

to_datetime_test() ->
    %% 2024-01-01T00:00:00Z
    ?assertEqual({{2024, 1, 1}, {0, 0, 0}}, vs_time:to_datetime(1_704_067_200_000)).
