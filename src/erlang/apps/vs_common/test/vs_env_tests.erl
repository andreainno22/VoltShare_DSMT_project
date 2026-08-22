-module(vs_env_tests).
-include_lib("eunit/include/eunit.hrl").

%% os:putenv/2 is process-global: each test sets what it needs and clears it.

default_when_unset_test() ->
    os:unsetenv("VS_TEST_X"),
    ?assertEqual("fallback", vs_env:get_str("VS_TEST_X", "fallback")),
    ?assertEqual(42, vs_env:get_int("VS_TEST_X", 42)),
    ?assertEqual(undefined, vs_env:get_atom("VS_TEST_X", undefined)).

reads_value_test() ->
    os:putenv("VS_TEST_X", "hello"),
    ?assertEqual("hello", vs_env:get_str("VS_TEST_X", "fallback")),
    os:unsetenv("VS_TEST_X").

int_parsing_test() ->
    os:putenv("VS_TEST_N", "900"),
    ?assertEqual(900, vs_env:get_int("VS_TEST_N", 15)),
    %% whitespace from a compose file must not break the boot
    os:putenv("VS_TEST_N", " 30 "),
    ?assertEqual(30, vs_env:get_int("VS_TEST_N", 15)),
    %% a typo falls back instead of crashing the node
    os:putenv("VS_TEST_N", "abc"),
    ?assertEqual(15, vs_env:get_int("VS_TEST_N", 15)),
    os:unsetenv("VS_TEST_N").

node_list_test() ->
    os:putenv("VS_TEST_NODES", "coord1@coord1,coord2@coord2,coord3@coord3"),
    ?assertEqual(['coord1@coord1', 'coord2@coord2', 'coord3@coord3'],
                 vs_env:get_nodes("VS_TEST_NODES", [])),
    %% spaces and a trailing comma are tolerated
    os:putenv("VS_TEST_NODES", "a@h1, b@h2,"),
    ?assertEqual(['a@h1', 'b@h2'], vs_env:get_nodes("VS_TEST_NODES", [])),
    os:unsetenv("VS_TEST_NODES").
