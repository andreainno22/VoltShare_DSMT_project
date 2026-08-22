%%%-------------------------------------------------------------------
%%% @doc Configuration read from the environment.
%%%
%%% Every tunable in the contracts (lease, renew interval, coordinator
%%% node list...) is an environment variable with a default, so that the
%%% demo can shorten timers without touching the code — see
%%% contracts/claim.md §8.
%%%-------------------------------------------------------------------
-module(vs_env).

-export([get_str/2, get_int/2, get_atom/2, get_nodes/2]).

%% @doc String value of Var, or Default when unset or empty.
-spec get_str(string(), string()) -> string().
get_str(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        ""    -> Default;
        Value -> Value
    end.

%% @doc Integer value of Var. An unparsable value falls back to Default:
%% a typo in compose must not stop a node from booting.
-spec get_int(string(), integer()) -> integer().
get_int(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        ""    -> Default;
        Value ->
            try list_to_integer(string:trim(Value))
            catch error:badarg -> Default
            end
    end.

-spec get_atom(string(), atom()) -> atom().
get_atom(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        ""    -> Default;
        Value -> list_to_atom(string:trim(Value))
    end.

%% @doc Comma-separated node list, as in
%% COORD_NODES=coord1@coord1,coord2@coord2,coord3@coord3
-spec get_nodes(string(), [node()]) -> [node()].
get_nodes(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        ""    -> Default;
        Value ->
            Parts = string:lexemes(Value, ","),
            [list_to_atom(string:trim(P)) || P <- Parts, string:trim(P) =/= ""]
    end.
