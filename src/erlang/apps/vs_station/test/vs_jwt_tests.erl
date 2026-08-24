%%%-------------------------------------------------------------------
%%% @doc Tests for the token verification, built on the three literal
%%% fixtures of contracts/sample-tokens.md.
%%%
%%% The fixtures are pasted in verbatim rather than minted here on
%%% purpose: they are the tokens B's `SampleTokenGenerator' actually
%%% produced, so these tests fail if the two sides ever drift on the
%%% secret, the algorithm or the claim names — which a locally minted
%%% token could never detect.
%%%-------------------------------------------------------------------
-module(vs_jwt_tests).
-include_lib("eunit/include/eunit.hrl").

%% sample-tokens.md: the development secret, 32 chars (HS256 wants 256 bits).
-define(SECRET, <<"dev-secret-change-me-0123456789ab">>).

%% §1 — valid, user 12 / vehicle 88, exp 2027-12-31, iat 2027-12-31.
-define(VALID,
        <<"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZC"
          "I6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxODMwMjkzOTQwLCJleHAiOjE4"
          "MzAyOTc1NDB9.VjbzuBTej0HI5PFV-Fl5x4WE5yfyxzWn58Qj4aNr3yQ">>).

%% §2 — expired (exp 2026-08-22T14:17Z), signature good.
-define(EXPIRED,
        <<"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZC"
          "I6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxNzg3Mzk3NDY2LCJleHAiOjE3"
          "ODc0MDEwNjZ9.xNtU08G70bYR15Ws67c4ecyuSzbvLZN24BVv8JJ7ThA">>).

%% §3 — signed with a different secret. Also expired (exp 2026-08-22T15:17Z):
%% that overlap is the whole reason the order of the checks is fixed.
-define(BAD_SIGNATURE,
        <<"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZC"
          "I6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxNzg3NDA4MjY2LCJleHAiOjE3"
          "ODc0MTE4NjZ9.Nr4iyC7Nbr-jMgYqCLpd8eQvOBI734jkVcwTbVgSwnI">>).

%%%===================================================================
%%% fixture
%%%===================================================================

%% `rebar3 eunit' starts no application, and jose keeps its algorithm
%% table in an ETS owned by jose_server. Starting it here rather than
%% leaning on jose's own lazy start keeps the first test from paying for
%% a race nobody else would reproduce.
jwt_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(jose), Started end,
     fun(_) -> ok end,
     [fun valid_token_yields_the_identity/0,
      fun expired_token_is_refused_on_expiry/0,
      fun forged_token_is_refused_on_the_signature_not_the_clock/0,
      fun the_forged_fixture_really_is_expired_too/0,
      fun wrong_issuer_is_refused/0,
      fun malformed_tokens_are_refused/0,
      fun issued_in_the_future_is_accepted/0,
      fun alg_none_is_not_a_signature/0,
      fun a_different_algorithm_does_not_bypass_the_key/0,
      fun claims_that_cannot_carry_an_identity_are_malformed/0,
      fun the_wrong_secret_refuses_the_good_token/0]}.

%%%===================================================================
%%% the three fixtures
%%%===================================================================

valid_token_yields_the_identity() ->
    {ok, Claims} = vs_jwt:verify(?VALID, ?SECRET),
    ?assertMatch(#{user_id := 12, vehicle_id := 88}, Claims),
    ?assertEqual(<<"andrea">>, maps:get(username, Claims)),
    ?assertEqual(1830297540, maps:get(exp, Claims)).

expired_token_is_refused_on_expiry() ->
    ?assertEqual({error, expired}, vs_jwt:verify(?EXPIRED, ?SECRET)).

%% The most important test of the module: a forged token must be refused
%% *as a forgery*. `expired' here would still close the socket today, and
%% would silently start accepting forgeries the day someone re-mints the
%% fixture with a later expiry.
forged_token_is_refused_on_the_signature_not_the_clock() ->
    ?assertEqual({error, invalid_signature}, vs_jwt:verify(?BAD_SIGNATURE, ?SECRET)).

%% Pins the premise the test above rests on: the fixture is a forgery
%% *and* stale, so checking the clock first would hide the forgery.
the_forged_fixture_really_is_expired_too() ->
    #{<<"exp">> := Exp} = payload_of(?BAD_SIGNATURE),
    ?assert(Exp < vs_time:now_ms() div 1000).

%%%===================================================================
%%% the checks the fixtures cannot cover
%%%===================================================================

wrong_issuer_is_refused() ->
    Token = mint(#{<<"sub">> => <<"12">>, <<"username">> => <<"andrea">>,
                   <<"vehicle_id">> => 88, <<"iss">> => <<"evil-backoffice">>,
                   <<"exp">> => future()}),
    ?assertEqual({error, wrong_issuer}, vs_jwt:verify(Token, ?SECRET)),
    NoIssuer = mint(#{<<"sub">> => <<"12">>, <<"vehicle_id">> => 88,
                      <<"exp">> => future()}),
    ?assertEqual({error, wrong_issuer}, vs_jwt:verify(NoIssuer, ?SECRET)).

%% jose answers these with an exception rather than `{false, _, _}', so
%% this test is what keeps the catch-all in vs_jwt:signature/2 honest.
malformed_tokens_are_refused() ->
    lists:foreach(fun(T) ->
                          ?assertEqual({error, malformed}, vs_jwt:verify(T, ?SECRET))
                  end,
                  [<<>>, <<"not-a-token">>, <<"a.b.c">>, <<"one.two">>,
                   <<"eyJhbGciOiJIUzI1NiJ9..">>]),
    %% and a token that is not a binary at all
    ?assertEqual({error, malformed}, vs_jwt:verify(undefined, ?SECRET)).

%% Documents a deliberate omission: jwt.md §3 lists three checks, and
%% `iat' is not among them. The valid fixture was issued in 2027 — a
%% verifier that rejected a future `iat' would reject the only token that
%% has to work.
issued_in_the_future_is_accepted() ->
    #{<<"iat">> := Iat} = payload_of(?VALID),
    ?assert(Iat > vs_time:now_ms() div 1000),
    ?assertMatch({ok, _}, vs_jwt:verify(?VALID, ?SECRET)).

%%%===================================================================
%%% algorithm substitution
%%%===================================================================

%% The oldest JWT attack: strip the signature, set `alg' to none. It must
%% look exactly like any other bad signature.
alg_none_is_not_a_signature() ->
    Token = unsigned(#{<<"alg">> => <<"none">>},
                     #{<<"sub">> => <<"12">>, <<"vehicle_id">> => 88,
                       <<"iss">> => <<"voltshare-backoffice">>,
                       <<"exp">> => future()}),
    ?assertEqual({error, invalid_signature}, vs_jwt:verify(Token, ?SECRET)).

%% Its cousin: claim an asymmetric algorithm and hope the verifier trusts
%% the header instead of the key it was given.
a_different_algorithm_does_not_bypass_the_key() ->
    Token = unsigned(#{<<"alg">> => <<"RS256">>},
                     #{<<"sub">> => <<"12">>, <<"vehicle_id">> => 88,
                       <<"iss">> => <<"voltshare-backoffice">>,
                       <<"exp">> => future()}),
    ?assertEqual({error, invalid_signature}, vs_jwt:verify(Token, ?SECRET)).

%%%===================================================================
%%% identity extraction
%%%===================================================================

%% A correctly signed token from the right issuer is still refused when
%% the identity it carries is unusable: `user_id' and `vehicle_id' are
%% never defaulted (ws-driver.md §7.3).
claims_that_cannot_carry_an_identity_are_malformed() ->
    Base = #{<<"iss">> => <<"voltshare-backoffice">>, <<"exp">> => future()},
    Cases = [Base#{<<"vehicle_id">> => 88},                              %% no sub
             Base#{<<"sub">> => <<"12">>},                               %% no vehicle_id
             Base#{<<"sub">> => <<"andrea">>, <<"vehicle_id">> => 88},   %% sub not a number
             Base#{<<"sub">> => 12, <<"vehicle_id">> => 88},             %% sub not a string
             Base#{<<"sub">> => <<"0">>, <<"vehicle_id">> => 88},        %% not a user id
             Base#{<<"sub">> => <<"12">>, <<"vehicle_id">> => <<"88">>}],
    lists:foreach(fun(Claims) ->
                          ?assertEqual({error, malformed},
                                       vs_jwt:verify(mint(Claims), ?SECRET))
                  end, Cases),
    %% no `exp' at all is malformed, not eternal
    ?assertEqual({error, malformed},
                 vs_jwt:verify(mint(#{<<"sub">> => <<"12">>, <<"vehicle_id">> => 88,
                                      <<"iss">> => <<"voltshare-backoffice">>}),
                               ?SECRET)),
    %% `username' decides nothing, so its absence is not a refusal
    Ok = mint(#{<<"sub">> => <<"12">>, <<"vehicle_id">> => 88,
                <<"iss">> => <<"voltshare-backoffice">>, <<"exp">> => future()}),
    ?assertMatch({ok, #{username := <<>>}}, vs_jwt:verify(Ok, ?SECRET)).

%% The deployment failure this module is meant to make loud: two sides
%% with different secrets refuse each other rather than trusting blindly.
the_wrong_secret_refuses_the_good_token() ->
    ?assertEqual({error, invalid_signature},
                 vs_jwt:verify(?VALID, <<"another-secret-0123456789abcdefgh">>)).

%%%===================================================================
%%% helpers
%%%===================================================================

future() -> vs_time:now_ms() div 1000 + 3600.

mint(Claims) ->
    JWK = jose_jwk:from_oct(?SECRET),
    {_, Token} = jose_jws:compact(
                   jose_jwt:sign(JWK, #{<<"alg">> => <<"HS256">>}, Claims)),
    Token.

%% Hand-assembled: a token whose signature segment is empty, which is
%% precisely what jose must not accept on our behalf.
unsigned(Header, Claims) ->
    <<(b64(jsx:encode(Header)))/binary, ".", (b64(jsx:encode(Claims)))/binary, ".">>.

b64(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

payload_of(Token) ->
    [_Header, Payload | _] = binary:split(Token, <<".">>, [global]),
    jsx:decode(base64:decode(Payload, #{mode => urlsafe, padding => false})).
