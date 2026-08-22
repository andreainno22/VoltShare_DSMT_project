# Contract — JWT (back office ↔ station)

**Status: frozen after joint review. Changing this file requires a PR reviewed by both developers.**

The station must recognise a driver without calling the back office: that is what keeps a station working while Tomcat is down, and what keeps gameplay traffic off the Java container. The token is the only thing the two sides share.

Owners: **B** signs (`util.JwtUtil`), **A** verifies (`vs_driver_ws`).

---

## 1. The token

| | |
|---|---|
| Algorithm | **HS256** (HMAC-SHA256), symmetric |
| Secret | environment variable `VOLTSHARE_JWT_SECRET`, identical on Tomcat and on every station |
| Lifetime | 60 minutes |
| Library, Java | `io.jsonwebtoken:jjwt` |
| Library, Erlang | `jose` |

Claims — exactly these, no others:

```json
{
  "sub": "12",
  "username": "andrea",
  "vehicle_id": 88,
  "iss": "voltshare-backoffice",
  "exp": 1755792000
}
```

`sub` is the user id as a **string** (the JWT spec requires it); `vehicle_id` is a number. The station needs both: `sub` to attribute the session, `vehicle_id` because the claim is per vehicle.

There is no refresh token. The login session lives in Tomcat's `HttpSession`; when it is still valid and the token is close to expiry, the servlet mints a new one. A driver whose token expires mid-session is not disconnected — expiry is checked only when the WebSocket opens.

---

## 2. How the token reaches the browser

It never passes through JavaScript storage. The servlet puts it in the session, the JSP prints it into the page, the WebSocket code reads the constant:

```jsp
<%-- station.jsp, prepared by StationPageServlet --%>
<script>
  const TOKEN   = '${sessionScope.jwt}';
  const WS_URL  = '${station.wsUrl}';
  const STATION = ${station.id};
</script>
<script src="js/station.js"></script>
```

`StationPageServlet` (B) guarantees these three variables are always present and non-empty when the page renders. `station.js` and `session.js` (A) may rely on them and on nothing else.

---

## 3. How the station verifies

On the first frame of the WebSocket (`join`), within 5 seconds of the connection opening:

1. verify the signature with the shared secret;
2. check `iss` is exactly `voltshare-backoffice`;
3. check `exp` is in the future;
4. extract `sub` and `vehicle_id`.

Any failure closes the socket with a WebSocket close code:

| Code | Cause |
|---|---|
| `4401` | invalid signature, wrong issuer, malformed token, or no `join` within 5 s |
| `4408` | token expired |

The station **never** calls the back office to validate a token, not even on failure.

---

## 4. Development fixtures

B produces `contracts/sample-tokens.md` in M0: three tokens signed with the development secret `dev-secret-change-me`, together with their decoded payloads —

- one valid, user 12 / vehicle 88;
- one expired;
- one signed with the wrong secret.

A uses them to build and test verification without running Tomcat. They are development fixtures: the real secret is injected as an environment variable at deploy time and is never committed.
