package it.unipi.dsmt.voltshare.util;

import org.mindrot.jbcrypt.BCrypt;

public final class PasswordUtil {

    private PasswordUtil() {
    }

    public static String hash(String plain) {
        return BCrypt.hashpw(plain, BCrypt.gensalt(10));
    }

    public static boolean matches(String plain, String hash) {
        if (plain == null || hash == null || hash.isBlank()) {
            return false;
        }
        try {
            return BCrypt.checkpw(plain, hash);
        } catch (IllegalArgumentException e) {
            // malformed hash in the database: treat as a failed login, not as a crash
            return false;
        }
    }
}
