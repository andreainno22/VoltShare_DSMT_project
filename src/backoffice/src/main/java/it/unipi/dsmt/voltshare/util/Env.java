package it.unipi.dsmt.voltshare.util;

/** Environment lookup with defaults, so the application runs outside Docker too. */
public final class Env {

    private Env() {
    }

    public static String get(String name, String fallback) {
        String v = System.getenv(name);
        if (v == null || v.isBlank()) {
            v = System.getProperty(name);
        }
        return (v == null || v.isBlank()) ? fallback : v.trim();
    }

    public static int getInt(String name, int fallback) {
        try {
            return Integer.parseInt(get(name, String.valueOf(fallback)));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
