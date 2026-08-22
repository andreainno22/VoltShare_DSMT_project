package it.unipi.dsmt.voltshare.util;

import io.jsonwebtoken.Claims;
import it.unipi.dsmt.voltshare.model.User;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The station verifies these tokens in Erlang, so what matters is that the claim names and
 * types match contracts/jwt.md exactly. A rename here silently breaks the other half of the
 * project, which is precisely what this test is here to prevent.
 */
class JwtUtilTest {

    private final User user = new User(12, "andrea", 88, 58.0, 150, 0, null);

    @Test
    void tokenCarriesTheClaimsTheStationExpects() {
        Claims claims = JwtUtil.parse(JwtUtil.issue(user));

        assertEquals("12", claims.getSubject(), "sub must be the user id, as a string");
        assertEquals("andrea", claims.get("username", String.class));
        assertEquals(88, claims.get("vehicle_id", Integer.class));
        assertEquals("voltshare-backoffice", claims.getIssuer());
        assertNotNull(claims.getExpiration());
    }

    @Test
    void freshTokenDoesNotNeedRefreshing() {
        assertFalse(JwtUtil.needsRefresh(JwtUtil.issue(user)));
    }

    @Test
    void missingOrGarbledTokenNeedsRefreshing() {
        assertTrue(JwtUtil.needsRefresh(null));
        assertTrue(JwtUtil.needsRefresh(""));
        assertTrue(JwtUtil.needsRefresh("not-a-token"));
    }

    @Test
    void tamperedTokenIsRejected() {
        String token = JwtUtil.issue(user);
        String tampered = token.substring(0, token.lastIndexOf('.') + 1) + "Zm9yZ2Vk";

        assertThrows(Exception.class, () -> JwtUtil.parse(tampered),
                "a token whose signature does not verify must never parse");
    }
}
