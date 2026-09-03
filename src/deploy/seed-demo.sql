-- VoltShare — seed della demo. Caricare DOPO `docker compose up` (schema.sql gira al
-- primo boot):  docker exec -i mysql mysql -uvoltshare -pvoltshare voltshare < seed-demo.sql
-- Idempotente. Si può rilanciare tra una prova e l'altra.
--
-- `reserve`/`cancel` non toccano MySQL (il claim è per vehicle_id). `plugged` sì: un
-- walk-in per un veicolo sconosciuto è rifiutato. Quindi ogni --vehicle usato da cp.js in
-- world.sh vuole una riga qui. Convenzione: id utente == id veicolo.

USE voltshare;

INSERT IGNORE INTO users (id, username, password_hash) VALUES
  (101,'load101','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (102,'load102','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (103,'load103','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (104,'load104','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (105,'load105','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
  (106,'load106','$2a$10$demoSeedHashNotForLoginxxxxxxxxxxxxxxxxxxxxxxxxxxx');

INSERT IGNORE INTO vehicles (id, user_id, battery_kwh, max_kw) VALUES
  (101,101, 60.00, 50),
  (102,102, 40.00, 50),
  (103,103, 75.00,150),
  (104,104, 50.00,150),
  (105,105, 80.00,150),
  (106,106, 55.00, 50);
