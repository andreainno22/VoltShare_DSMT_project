-- VoltShare — database schema
-- Status: frozen after joint review. Changing this file requires a PR reviewed by both developers.
--
-- OWNERSHIP RULES — the point of this section is that no row is ever written by two runtimes.
--
--   A (Erlang, station)  writes ONLY  sessions   (one INSERT when a session closes)
--   B (Java, back office) writes      users, vehicles, notifications
--                         updates     sessions.cost_cents   (billing, after the INSERT)
--   seed data, read-only for both:    stations, connectors
--
-- The no-show counter and the suspension deadline live in `users` and belong to B alone.
-- The station never UPDATEs them: it reports {no_show, ...} / {show_up, ...} to the
-- coordinator, which forwards to Java (see contracts/erlang-java.md). This is deliberate —
-- it keeps a counter written from several nodes from becoming a contended value.

CREATE DATABASE IF NOT EXISTS voltshare
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE voltshare;

-- ---------------------------------------------------------------- accounts

CREATE TABLE IF NOT EXISTS users (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    username        VARCHAR(50)  NOT NULL UNIQUE,
    password_hash   VARCHAR(255) NOT NULL,          -- BCrypt
    created_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,

    -- penalty state (SCOPE §3.3) — written by B only
    no_show_count   INT          NOT NULL DEFAULT 0,
    suspended_until DATETIME     NULL,

    INDEX idx_suspended (suspended_until)
) ENGINE=InnoDB;

-- One vehicle per account in the delivered scope. The single-vehicle assumption is what
-- makes the no-show counter free of contention (DESIGN-NOTES §4b); if it is ever relaxed,
-- that counter needs an atomic increment.
CREATE TABLE IF NOT EXISTS vehicles (
    id           INT AUTO_INCREMENT PRIMARY KEY,
    user_id      INT NOT NULL,
    battery_kwh  DECIMAL(6,2) NOT NULL,
    max_kw       INT          NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE KEY uq_vehicle_user (user_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------- topology (seed)

CREATE TABLE IF NOT EXISTS stations (
    id                INT PRIMARY KEY,              -- fixed ids, matching the Erlang config
    name              VARCHAR(80)  NOT NULL,
    ws_url            VARCHAR(200) NOT NULL,        -- public URL the browser connects to
    site_power_kw     INT          NOT NULL,
    tariff_cents_kwh  INT          NOT NULL,
    tariff_cents_min_overstay INT  NOT NULL DEFAULT 50
) ENGINE=InnoDB;

-- connector ids are globally unique, not per-station: it keeps every message and log line
-- unambiguous without carrying the station id everywhere.
CREATE TABLE IF NOT EXISTS connectors (
    id         INT PRIMARY KEY,
    station_id INT NOT NULL,
    rated_kw   INT NOT NULL,
    FOREIGN KEY (station_id) REFERENCES stations(id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------- sessions

-- INSERTed by the station when a session closes; cost_cents filled in afterwards by B.
CREATE TABLE IF NOT EXISTS sessions (
    id               BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id          INT NOT NULL,
    station_id       INT NOT NULL,
    connector_id     INT NOT NULL,
    started_at       DATETIME     NOT NULL,
    ended_at         DATETIME     NOT NULL,
    energy_kwh       DECIMAL(10,3) NOT NULL DEFAULT 0,
    overstay_seconds INT          NOT NULL DEFAULT 0,
    cost_cents       INT          NULL,             -- NULL = not billed yet
    FOREIGN KEY (user_id)    REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (station_id) REFERENCES stations(id),
    INDEX idx_user_time (user_id, started_at),
    INDEX idx_unbilled (cost_cents)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------- notifications

CREATE TABLE IF NOT EXISTS notifications (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id    INT NOT NULL,
    kind       VARCHAR(40) NOT NULL,   -- reservation_expired | charge_complete |
                                       -- waitlist_offer | session_interrupted | suspended
    text       VARCHAR(255) NOT NULL,
    is_read    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    INDEX idx_user_unread (user_id, is_read)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------- seed

INSERT IGNORE INTO stations (id, name, ws_url, site_power_kw, tariff_cents_kwh) VALUES
  (1, 'Pisa Centro',  'ws://localhost:9101/ws/driver', 350, 45),
  (2, 'Livorno Port', 'ws://localhost:9102/ws/driver', 180, 42);

INSERT IGNORE INTO connectors (id, station_id, rated_kw) VALUES
  (1, 1, 150), (2, 1, 150), (3, 1, 150), (4, 1,  50),
  (5, 2, 150), (6, 2,  50), (7, 2,  50);

-- site_power_kw is deliberately below the sum of the connectors' ratings, so that
-- power sharing is observable with two or three cars rather than only in theory:
--   station 1:  350 kW budget  vs  500 kW installed
--   station 2:  180 kW budget  vs  250 kW installed
-- Two cars on station 2 already contend. See SCOPE §3.5.
