%%%-------------------------------------------------------------------
%%% @doc Time helpers.
%%%
%%% The claim contract exchanges `epoch_ms()' — milliseconds since the
%%% Unix epoch — because it is unambiguous across nodes and languages,
%%% while `erlang:monotonic_time/0' is comparable only within one node.
%%% All timestamps that leave a node go through here.
%%%-------------------------------------------------------------------
-module(vs_time).

-export([now_ms/0, in_ms/1, in_seconds/1, expired/1, remaining_ms/1, to_datetime/1]).

-type epoch_ms() :: pos_integer().
-export_type([epoch_ms/0]).

-spec now_ms() -> epoch_ms().
now_ms() -> erlang:system_time(millisecond).

%% @doc Timestamp N milliseconds from now.
-spec in_ms(non_neg_integer()) -> epoch_ms().
in_ms(Ms) -> now_ms() + Ms.

%% @doc Timestamp N seconds from now — the usual form for a lease.
-spec in_seconds(non_neg_integer()) -> epoch_ms().
in_seconds(Sec) -> now_ms() + Sec * 1000.

-spec expired(epoch_ms()) -> boolean().
expired(ExpiresAt) -> now_ms() >= ExpiresAt.

%% @doc Milliseconds left before ExpiresAt; never negative, so the result
%% can be handed straight to a timer.
-spec remaining_ms(epoch_ms()) -> non_neg_integer().
remaining_ms(ExpiresAt) -> max(0, ExpiresAt - now_ms()).

%% @doc UTC calendar datetime, for the DATETIME columns of `sessions'.
-spec to_datetime(epoch_ms()) -> calendar:datetime().
to_datetime(Ms) ->
    calendar:system_time_to_universal_time(Ms, millisecond).
