%%%-------------------------------------------------------------------
%%% @doc Verification of the back office's JWT — contracts/jwt.md §3.
%%%
%%% The whole point of the token is that a station recognises a driver
%%% **without calling Tomcat**: this module is what keeps the driver
%%% channel working while the back office is down, and it is why no code
%%% path here does any I/O at all. Pure function, no process, no state.
%%%
%%% Three checks and three only, **in this order**:
%%%
%%%   1. the HS256 signature, with the shared secret;
%%%   2. `iss' is exactly `voltshare-backoffice';
%%%   3. `exp' is in the future.
%%%
%%% The order is load-bearing, not tidiness. In contracts/sample-tokens.md
%%% the "wrong signature" fixture carries `exp' = 2026-08-22, so **it is
%%% also expired today**. A verifier that looked at the clock first would
%%% answer `expired' (close 4408) for a forged token, and the test that
%%% proves nobody can impersonate another driver would pass for the wrong
%%% reason — it would still pass the day the forgery stopped being stale.
%%%
%%% Symmetrically, `iat' and `nbf' are **not** checked. The valid fixture
%%% was issued with `iat' = 2027-12-31, i.e. in the future relative to the
%%% demo clock, and a verifier that checked it would reject the one token
%%% that must work. jwt.md §3 lists three checks; these are those three.
%%%
%%% `jose_jwt:verify/2' validates the signature and nothing else — the
%%% trap sample-tokens.md closes with. Issuer and expiry are ordinary
%%% claims: a token that verifies is not a token you should accept.
%%%-------------------------------------------------------------------
-module(vs_jwt).

-export([verify/2, secret/0]).

%% jwt.md §1: the only issuer this station trusts.
-define(ISSUER, <<"voltshare-backoffice">>).
%% Same string as docker-compose.yml's fallback and sample-tokens.md.
-define(DEV_SECRET, "dev-secret-change-me-0123456789ab").

-type claims() :: #{user_id    := pos_integer(),
                    vehicle_id := pos_integer(),
                    username   := binary(),
                    exp        := pos_integer()}.
-type error()  :: invalid_signature | wrong_issuer | expired | malformed.

-export_type([claims/0, error/0]).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Verify a token against the shared secret and extract the identity
%% the connection is bound to. `user_id' and `vehicle_id' come from here
%% and from nowhere else — ws-driver.md §7.3.
-spec verify(binary(), binary()) -> {ok, claims()} | {error, error()}.
verify(Token, Secret) when is_binary(Token), is_binary(Secret) ->
    case signature(Token, Secret) of
        {ok, Claims} -> issuer(Claims);
        {error, Why} -> {error, Why}
    end;
verify(_Token, _Secret) ->
    {error, malformed}.

%% @doc The shared secret, from the environment. The default is the
%% development fixture of sample-tokens.md, so a node started from the
%% shell can be talked to.
%%
%% The warning fires on the *value*, not on the variable being unset:
%% docker-compose.yml passes that same string as its own fallback, so a
%% deployment that forgot to inject the real secret would otherwise look
%% perfectly configured. What matters is that this station is verifying
%% tokens with a secret that is published in the repository — anybody
%% could mint one — and that is worth saying however it got here.
-spec secret() -> binary().
secret() ->
    case vs_env:get_str("VOLTSHARE_JWT_SECRET", ?DEV_SECRET) of
        ?DEV_SECRET ->
            logger:warning("VOLTSHARE_JWT_SECRET is the development secret of "
                           "contracts/sample-tokens.md: tokens are verifiable "
                           "by anyone with the repository"),
            list_to_binary(?DEV_SECRET);
        Value ->
            list_to_binary(Value)
    end.

%%%===================================================================
%%% the three checks, in order
%%%===================================================================

%% Step 1. Malformed input reaches jose as an exception, not as a return
%% value (`{invalid_byte, _}' on non-base64, `case_clause' on the wrong
%% number of segments), so the catch-all is part of the contract of this
%% function rather than defensive padding.
signature(Token, Secret) ->
    try jose_jwt:verify(jose_jwk:from_oct(Secret), Token) of
        {true,  {jose_jwt, Claims}, _JWS} -> {ok, Claims};
        %% Covers `alg: none' and an RS256 header against our oct key:
        %% jose answers `false' for both rather than trusting the header.
        {false, _Claims, _JWS}            -> {error, invalid_signature};
        _Other                            -> {error, malformed}
    catch
        _:_ -> {error, malformed}
    end.

%% Step 2. Exact match, never a prefix or a case-insensitive compare: the
%% issuer is the name of the only key holder we accept.
issuer(Claims = #{<<"iss">> := ?ISSUER}) -> expiry(Claims);
issuer(#{<<"iss">> := _Other})           -> {error, wrong_issuer};
issuer(_NoIssuer)                        -> {error, wrong_issuer}.

%% Step 3. `exp' is in **seconds** (RFC 7519), our clock is in
%% milliseconds. A token with no `exp' is malformed rather than eternal:
%% jwt.md §1 lists it among the claims that are always present, and the
%% failure that never expires is the one worth refusing.
expiry(Claims = #{<<"exp">> := Exp}) when is_integer(Exp), Exp > 0 ->
    case Exp > vs_time:now_ms() div 1000 of
        true  -> identity(Claims, Exp);
        false -> {error, expired}
    end;
expiry(_NoExpiry) ->
    {error, malformed}.

%% Step 4. `sub' is the user id as a **string** (the JWT spec requires
%% it), `vehicle_id' a number. Both must be usable positive integers:
%% they are the identity the whole channel is bound to, so an unusable
%% one is a refusal, never a default.
identity(#{<<"sub">> := Sub, <<"vehicle_id">> := VehicleId} = Claims, Exp)
  when is_binary(Sub), is_integer(VehicleId), VehicleId > 0 ->
    try binary_to_integer(Sub) of
        UserId when UserId > 0 ->
            {ok, #{user_id    => UserId,
                   vehicle_id => VehicleId,
                   %% Display only — it decides nothing, so its absence
                   %% is not a reason to refuse a driver.
                   username   => username(Claims),
                   exp        => Exp}};
        _NonPositive ->
            {error, malformed}
    catch
        error:badarg -> {error, malformed}
    end;
identity(_Claims, _Exp) ->
    {error, malformed}.

username(#{<<"username">> := U}) when is_binary(U) -> U;
username(_Claims)                                  -> <<>>.
