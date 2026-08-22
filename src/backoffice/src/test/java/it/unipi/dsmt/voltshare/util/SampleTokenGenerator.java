package it.unipi.dsmt.voltshare.util;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import it.unipi.dsmt.voltshare.model.User;
import org.junit.jupiter.api.Test;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;

/**
 * Produces the fixtures in contracts/sample-tokens.md, so that A can build and test the
 * Erlang side of the handshake without running Tomcat.
 *
 * <p>Run it with:  mvn test -Dtest=SampleTokenGenerator
 * and paste the output into the contract file.
 */
class SampleTokenGenerator {

    private static final String DEV_SECRET = "dev-secret-change-me-0123456789ab";
    private static final String WRONG_SECRET = "wrong-secret-wrong-secret-000000";

    @Test
    void printTokens() {
        // A long expiry on purpose: this is a fixture checked into the contract, and one
        // that stops working after an hour would be worse than useless.
        System.out.println("=== VALID (user 12, vehicle 88) ===");
        System.out.println(signed(DEV_SECRET, Instant.parse("2027-12-31T23:59:00Z")));

        System.out.println("=== EXPIRED ===");
        System.out.println(signed(DEV_SECRET, Instant.now().minusSeconds(7200)));

        System.out.println("=== WRONG SIGNATURE ===");
        System.out.println(signed(WRONG_SECRET, Instant.now().plusSeconds(3600)));
    }

    private String signed(String secret, Instant expiry) {
        SecretKey key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        return Jwts.builder()
                .subject("12")
                .claim("username", "andrea")
                .claim("vehicle_id", 88)
                .issuer("voltshare-backoffice")
                .issuedAt(Date.from(expiry.minusSeconds(3600)))
                .expiration(Date.from(expiry))
                .signWith(key)
                .compact();
    }
}
