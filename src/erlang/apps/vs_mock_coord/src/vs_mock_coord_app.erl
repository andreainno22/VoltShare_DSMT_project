%%%-------------------------------------------------------------------
%%% @doc Entry point of the mock coordinator application.
%%%
%%% Deployed with `ERL_APP: vs_mock_coord' on the coord1 container:
%%% start-node.sh needs nothing else (it just ensure_all_starts whatever
%%% ERL_APP names). B replaces the container with the real vs_coord and
%%% this application simply stops being deployed — it stays in the repo
%%% as the executable reference of the claim contract and as the test
%%% double of vs_claim_client.
%%%-------------------------------------------------------------------
-module(vs_mock_coord_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    vs_mock_coord_sup:start_link().

stop(_State) ->
    ok.
