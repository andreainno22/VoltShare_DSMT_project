# Sample tokens — development fixtures

Produced by `backoffice/src/test/java/.../SampleTokenGenerator.java`
(`mvn test -Dtest=SampleTokenGenerator`). They let **A** build and test the Erlang side of
the handshake without running Tomcat.

Development secret: `dev-secret-change-me-0123456789ab` (32 characters — HS256 needs 256 bits).
The real secret arrives as `VOLTSHARE_JWT_SECRET` at deploy time and is never committed.

---

## 1. Valid — expires 2027-12-31

Verification must succeed; the socket proceeds to `join`.

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZCI6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxODMwMjkzOTQwLCJleHAiOjE4MzAyOTc1NDB9.VjbzuBTej0HI5PFV-Fl5x4WE5yfyxzWn58Qj4aNr3yQ
```

Decoded payload:

```json
{
  "sub": "12",
  "username": "andrea",
  "vehicle_id": 88,
  "iss": "voltshare-backoffice",
  "iat": 1830293940,
  "exp": 1830297540
}
```

## 2. Expired

Verification must fail on `exp`; the station closes the socket with **4408**.

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZCI6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxNzg3Mzk3NDY2LCJleHAiOjE3ODc0MDEwNjZ9.xNtU08G70bYR15Ws67c4ecyuSzbvLZN24BVv8JJ7ThA
```

## 3. Wrong signature

Same payload, signed with a different secret. Verification must fail on the signature;
the station closes with **4401**. This one matters: a station that accepts it would let
anybody impersonate any driver.

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwidmVoaWNsZV9pZCI6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxNzg3NDA4MjY2LCJleHAiOjE3ODc0MTE4NjZ9.Nr4iyC7Nbr-jMgYqCLpd8eQvOBI734jkVcwTbVgSwnI
```

---

## Verifying in Erlang

```erlang
Secret = <<"dev-secret-change-me-0123456789ab">>,
JWK    = jose_jwk:from_oct(Secret),
case jose_jwt:verify(JWK, Token) of
    {true, {jose_jwt, Claims}, _} ->
        %% then check iss and exp by hand: verify/2 only checks the signature
        ok;
    {false, _, _} ->
        {error, invalid_signature}
end.
```

Note the trap, the same one BlackNet's WebSocket handler had to deal with: `jose_jwt:verify/2`
validates **only the signature**. Issuer and expiry are ordinary claims and must be checked
explicitly — a token that verifies is not necessarily a token you should accept.
