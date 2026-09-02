%%%-------------------------------------------------------------------
%%% @doc What a freshly elected leader does before it starts serving.
%%%
%%% A new leader inherits nothing. Claims were granted by its predecessor and
%%% live in that process's memory, which died with it — so the first thing it
%%% must do is find out which vehicles are already held, and it must do that
%%% before granting anything, or it will hand the same vehicle to a second
%%% station while the first is still charging it.
%%%
%%% == Why asking is enough, and no log has to be replicated ==
%%%
%%% This is the design decision the whole failover story rests on, and it is
%%% worth stating plainly: **the coordinator is an index, not the owner of the
%%% state it indexes.** The authoritative copy of "connector 3 is held for
%%% vehicle 88 until 15:42" lives on the station, which is also the only place
%%% that can act on it. The coordinator holds a derived view whose only purpose
%%% is to make the uniqueness check (P2) a local lookup.
%%%
%%% A derived view can be rebuilt from its sources. That is why there is no
%%% replicated log, no consensus on a state machine, no persistence: the new
%%% leader asks the stations, and they answer from memory. Replicating the
%%% claims would mean maintaining a second copy of something the stations
%%% already hold authoritatively — more machinery, more ways to disagree, and
%%% nothing gained.
%%%
%%% == Two paths converge ==
%%%
%%% This explicit query is the fast path. There is a second, slower one that
%%% works even if this query reaches nobody: renewals arrive every ten seconds
%%% carrying `ClaimId', `GrantedAt' and `UserId', and an unknown claim in a
%%% renewal is adopted rather than refused (claim.md §3.2, §7). The system
%%% would converge on its own within one renew interval; the query just makes
%%% recovery take a second instead of ten.
%%%
%%% Keeping both is deliberate. The query can miss a station that is briefly
%%% unreachable, and adoption catches it; adoption alone would leave a window
%%% in which the new leader grants claims it should have refused.
%%%
%%% == Which stations to ask ==
%%%
%%% The new leader has no station list — stations only announce themselves to
%%% the leader, and this node was not it. So it asks every connected node that
%%% is not a coordinator. Erlang's distribution is fully connected by default,
%%% so a station talking to any coordinator is visible here.
%%%
%%% Asking a node that turns out not to be a station costs one message that
%%% nobody answers, which is why the collection is bounded by a timeout rather
%%% than by a count of expected replies.
%%%-------------------------------------------------------------------
-module(vs_coord_rebuild).

-export([run/1, deadline_ms/0, station_nodes/0]).

-define(CLIENT, vs_claim_client).

%% @doc Ask every reachable station what it holds, then hand the answers to the
%% caller as `{rebuilt, [{StationId, Holds}]}'.
%%
%% Runs in its own process: it waits on the network, and the coordinator must
%% stay responsive while it does — it is still answering `not_serving' and
%% still accepting renewals, which are themselves a source of adoptions.
%%
%% **Monitored, never linked.** This was `spawn_link', and a link points both
%% ways: an exception in here — a malformed `{holds, …}' from any node reaching
%% the arithmetic below — would have killed `vs_coord_srv', the one process
%% holding every claim in the network, and `rest_for_one' would then have taken
%% the whole coordinator subtree with it. That is precisely the failure the
%% catch-all in `renew_one/4' exists to prevent, reintroduced two milestones
%% later by one word.
%%
%% A monitor gives the coordinator the same news without the lethality: it
%% learns that the worker died and can decide what to do, which is what
%% `vs_coord_srv' now does.
-spec run(pid()) -> {pid(), reference()}.
run(ReplyTo) ->
    TimeoutMs = vs_env:get_int("COORD_REBUILD_TIMEOUT_MS", 2000),
    spawn_monitor(fun() -> do_run(ReplyTo, TimeoutMs) end).

%% @doc How long the caller should wait before giving up on the answer.
%%
%% Comfortably longer than the worker's own window, so that on a healthy
%% rebuild the answer always arrives first and this deadline never fires.
-spec deadline_ms() -> pos_integer().
deadline_ms() ->
    vs_env:get_int("COORD_REBUILD_TIMEOUT_MS", 2000) * 2 + 1000.

%% @doc Connected nodes that are not coordinators. Exported for the tests.
-spec station_nodes() -> [node()].
station_nodes() ->
    Coords = lists:usort([node() | vs_env:get_nodes("COORD_NODES", [])]),
    [N || N <- nodes(), not lists:member(N, Coords)].

%%%===================================================================
%%% internal
%%%===================================================================

do_run(ReplyTo, TimeoutMs) ->
    Targets = station_nodes(),
    Self = self(),
    [{?CLIENT, N} ! {who_do_you_hold, Self, node()} || N <- Targets],

    logger:notice("rebuild: asked ~p station node(s), waiting up to ~p ms",
                  [length(Targets), TimeoutMs]),

    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Holds = collect(length(Targets), Deadline, []),

    %% Counted defensively: `Claims' comes from another node, and a non-list
    %% there would raise inside the log line — harmless now that the worker is
    %% only monitored, but it would still cost the rebuild for no reason.
    Counted = lists:sum([length(H) || {_, H} <- Holds, is_list(H)]),
    logger:notice("rebuild: ~p station(s) answered with ~p claim(s) in total",
                  [length(Holds), Counted]),

    ReplyTo ! {rebuilt, Holds},
    ok.

%% Stops as soon as everyone asked has answered, so a healthy cluster recovers
%% in a round trip rather than always paying the full timeout.
%%
%% With one exception: having asked *nobody* is not the same as having heard
%% from everybody. A leader elected while the stations are briefly disconnected
%% would otherwise conclude in a microsecond that the network holds no claims,
%% and start granting vehicles that are already charging. Zero answers is when
%% we know least, so that is the one case that waits out the full window — the
%% stations reconnect and renew during it, and adoption catches what the query
%% could not reach.
collect(0, Deadline, []) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 of
        true ->
            receive
                {holds, StationId, Claims} -> collect(0, Deadline, [{StationId, Claims}])
            after Left -> []
            end;
        false -> []
    end;
collect(0, _Deadline, Acc) ->
    lists:reverse(Acc);
collect(Remaining, Deadline, Acc) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left =< 0 of
        true ->
            %% Whoever did not answer is either not a station or unreachable.
            %% Their claims arrive through renewal adoption instead.
            lists:reverse(Acc);
        false ->
            receive
                {holds, StationId, Claims} ->
                    collect(Remaining - 1, Deadline, [{StationId, Claims} | Acc])
            after Left ->
                lists:reverse(Acc)
            end
    end.
