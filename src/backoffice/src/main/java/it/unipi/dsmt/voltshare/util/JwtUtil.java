package it.unipi.dsmt.voltshare.util;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;

import it.unipi.dsmt.voltshare.model.User;

/**
 * Mints the token the Erlang stations verify on their own.
 * See contracts/jwt.md — that file is the agreement, this class must follow it.
 */
public final class JwtUtil {

    private static final String ISSUER = "voltshare-backoffice";
    private static final long TTL_SECONDS = 3600;

    /** HS256 needs at least 256 bits of key material, hence a 32-character minimum. */
    private static final SecretKey KEY = Keys.hmacShaKeyFor(
            Env.get("VOLTSHARE_JWT_SECRET", "dev-secret-change-me-0123456789ab")
               .getBytes(StandardCharsets.UTF_8));

    private JwtUtil() {
    }

    public static String issue(User user) {
        Instant now = Instant.now();
        return Jwts.builder()
                .subject(String.valueOf(user.getId()))
                .claim("username", user.getUsername())
                .claim("vehicle_id", user.getVehicleId())
                .issuer(ISSUER)
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plusSeconds(TTL_SECONDS)))
                .signWith(KEY)
                .compact();
    }

    /** Used by the unit tests and by the sample-token generator; the stations verify on their side. */
    public static Claims parse(String token) {
        return Jwts.parser()
                .verifyWith(KEY)
                .requireIssuer(ISSUER)
                .build()
                .parseSignedClaims(token)
                .getPayload();
    }

    /** True when the token is missing or within five minutes of expiring. */
    public static boolean needsRefresh(String token) {
        if (token == null || token.isBlank()) {
            return true;
        }
        try {
            Date exp = parse(token).getExpiration();
            return exp.toInstant().isBefore(Instant.now().plusSeconds(300));
        } catch (Exception e) {
            return true;
        }
    }
}
