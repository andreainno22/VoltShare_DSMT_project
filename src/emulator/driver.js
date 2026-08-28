#!/usr/bin/env node
'use strict';

/*
 * VoltShare — driver emulator and load generator (contracts/ws-driver.md).
 *
 * Zero npm dependencies, same as cp.js and for the same reasons: `WebSocket`
 * and `crypto` are both in the Node runtime, so there is nothing to install
 * and nothing that can be broken on the machine where the demo is shown.
 *
 * It speaks the driver channel the way the browser speaks it — `join` with a
 * JWT, then `reserve`, `cancel_reservation`, `stop_session`, reading `state`
 * and `session` — but it is NOT a copy of js/ws.js. That file is page code,
 * with a DOM around it. Where the two could differ, js/ws.js is right: it is
 * the one that runs in front of a user. The semantics deliberately mirrored
 * from it are marked below, one by one.
 *
 * The point is not big numbers. It is that the invariants hold when things
 * overlap: one connector goes to exactly one driver, one vehicle holds
 * exactly one reservation in the whole network, and nothing is left held by
 * nobody when the load stops.
 *
 * ── THE TOKENS ARE SIGNED HERE, AND THAT IS A TEST CONVENIENCE ────────────
 *
 * This program mints its own JWTs, one per emulated driver, each with its
 * own `vehicle_id`. It can only do that because the DEVELOPMENT secret is
 * published in contracts/sample-tokens.md, and a load generator that needed
 * a running Tomcat to produce forty logins would not be a load generator.
 *
 * In service this is impossible and must stay impossible: `VOLTSHARE_JWT_SECRET`
 * is injected at deploy time and never committed, and the back office is the
 * only issuer (jwt.md §1, "Owners: B signs, A verifies"). Nothing about this
 * file argues that a station should trust anybody else — the station's own
 * `vs_jwt:secret/0` already logs a warning when it finds itself verifying
 * with the published secret. Signing here is the mirror image of that
 * warning: both exist because the development secret is known, and both stop
 * being true the moment a real one is injected.
 *
 * Run `--self-test` to see the point: it re-signs the claims of
 * sample-tokens.md §1 and prints whether the result is the published fixture,
 * byte for byte. It is, which is what makes the tokens below credible.
 */

const crypto = require('crypto');

const MIN_NODE_MAJOR = 22;

// ---------------------------------------------------------------- CLI

const USAGE = `
usage: node driver.js --scenario contention|one-vehicle|sustained [options]

  --scenario      contention   N drivers race for ONE connector
                  one-vehicle  ONE vehicle races for connectors on both stations
                  sustained    M drivers join/reserve/cancel in a loop

  --url <u>       station 1 driver channel   (default ws://localhost:9101/ws/driver)
  --station <id>  station 1 id               (default 1)
  --url2 <u>      station 2, for one-vehicle (default ws://localhost:9102/ws/driver)
  --station2 <id> station 2 id               (default 2)

  --connector <n>    the contended connector          (default 3)
  --connectors <l>   station 1's connectors, comma-separated  (default 1,2,3,4)
  --connectors2 <l>  station 2's                              (default 5,6,7)

  --drivers <n>      how many emulated drivers        (default 20)
  --seconds <s>      how long 'sustained' runs        (default 60)
  --think <ms>       pause between a driver's actions (default 250)

  --first-user <n>   user ids are n, n+1, ...         (default 101)
  --first-vehicle <n> vehicle ids likewise            (default 101)

  --charging-connector <n>  'sustained' only: a connector where a charge
                            point is delivering, so the run can also show
                            the 'session' frame and 'stop_session'. 0 = off
  --owner-user <n>          who that car belongs to           (default 12)
  --owner-vehicle <n>       and its vehicle                   (default 88)
  --secret <s>       HS256 secret (dev fixture by default)
  --issuer <s>       'iss' claim  (default voltshare-backoffice)

  --self-test     re-sign the fixture of sample-tokens.md and exit
  --quiet         only the final report
`;

const DEFAULTS = {
  scenario: 'contention',
  url: 'ws://localhost:9101/ws/driver',
  station: 1,
  url2: 'ws://localhost:9102/ws/driver',
  station2: 2,
  connector: 3,
  connectors: '1,2,3,4',
  connectors2: '5,6,7',
  drivers: 20,
  seconds: 60,
  think: 250,
  'first-user': 101,
  'first-vehicle': 101,
  'charging-connector': 0,
  // The walk-in of the charge point emulator's own defaults: cp.js announces
  // vehicle 88, and vehicles.user_id maps it to user 12.
  'owner-user': 12,
  'owner-vehicle': 88,
  // sample-tokens.md: 32 characters, because HS256 needs 256 bits of key.
  secret: 'dev-secret-change-me-0123456789ab',
  issuer: 'voltshare-backoffice',
  'self-test': false,
  quiet: false,
};

const FLAGS = ['self-test', 'quiet'];

function parseArgs(argv) {
  const out = Object.assign({}, DEFAULTS);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      process.stdout.write(USAGE);
      process.exit(0);
    }
    if (!arg.startsWith('--')) die(`unexpected argument ${arg}${USAGE}`);
    const key = arg.slice(2);
    if (!(key in DEFAULTS)) die(`unknown option --${key}${USAGE}`);
    if (FLAGS.includes(key)) { out[key] = true; continue; }
    const value = argv[++i];
    if (value === undefined) die(`--${key} needs a value`);
    out[key] = typeof DEFAULTS[key] === 'number' ? Number(value) : value;
    if (typeof out[key] === 'number' && Number.isNaN(out[key])) {
      die(`--${key} must be a number, got ${value}`);
    }
  }
  return out;
}

function die(message) {
  process.stderr.write(`driver.js: ${message}\n`);
  process.exit(2);
}

const cfg = parseArgs(process.argv.slice(2));

const major = Number(process.versions.node.split('.')[0]);
if (major < MIN_NODE_MAJOR || typeof WebSocket !== 'function') {
  die(`needs Node >= ${MIN_NODE_MAJOR} for the built-in WebSocket client `
      + `(this is ${process.versions.node})`);
}

function log(...parts) {
  if (cfg.quiet) return;
  const t = new Date().toISOString().slice(11, 23);
  process.stdout.write(`${t} ${parts.join(' ')}\n`);
}

function say(...parts) {
  process.stdout.write(`${parts.join(' ')}\n`);
}

// ---------------------------------------------------------------- tokens

const b64url = (buf) => Buffer.from(buf).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/*
 * jwt.md §1 — HS256, and exactly these claims. `sub` is the user id as a
 * STRING (the JWT spec requires it) while `vehicle_id` is a number: the
 * station needs `sub` to attribute the session and `vehicle_id` because the
 * claim is per vehicle, and getting the two types the wrong way round is the
 * one mistake this signer could make that the station would not catch.
 *
 * `iat` is here because the fixtures of sample-tokens.md carry it. It is not
 * verified — vs_jwt checks the signature, `iss` and `exp`, in that order and
 * nothing else — but re-signing the fixture is only a proof if what is signed
 * is what was signed then.
 */
function signToken(userId, vehicleId, username, lifetimeS, iat) {
  const now = iat !== undefined ? iat : Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'HS256' }));
  const payload = b64url(JSON.stringify({
    sub: String(userId),
    username: username,
    vehicle_id: vehicleId,
    iss: cfg.issuer,
    iat: now,
    exp: now + lifetimeS,
  }));
  const signature = b64url(
    crypto.createHmac('sha256', cfg.secret).update(`${header}.${payload}`).digest());
  return `${header}.${payload}.${signature}`;
}

// The claims of sample-tokens.md §1, verbatim, and the token B published for
// them. If these two agree then this file signs what Tomcat signs.
function selfTest() {
  const FIXTURE = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMiIsInVzZXJuYW1lIjoiYW5kcmVhIiwi'
    + 'dmVoaWNsZV9pZCI6ODgsImlzcyI6InZvbHRzaGFyZS1iYWNrb2ZmaWNlIiwiaWF0IjoxODMwMjkz'
    + 'OTQwLCJleHAiOjE4MzAyOTc1NDB9.VjbzuBTej0HI5PFV-Fl5x4WE5yfyxzWn58Qj4aNr3yQ';
  const mine = signToken(12, 88, 'andrea', 3600, 1830293940);
  say('sample-tokens.md §1, re-signed here:');
  say(`  ${mine}`);
  say(`  ${mine === FIXTURE ? 'identical to the published fixture'
                            : 'DIFFERENT from the published fixture'}`);
  process.exit(mine === FIXTURE ? 0 : 1);
}

// ---------------------------------------------------------------- the channel

/*
 * One emulated driver: one socket, one identity, one action at a time.
 *
 * The semantics below are js/ws.js's, kept deliberately identical because
 * ws-driver.md's header says the emulated drivers of the load generator speak
 * the same contract as the page, and a load test run against different
 * semantics would be measuring something nobody uses:
 *
 *   §2/§7.2  one request_id per USER ACTION, reused on every retry, so the
 *            station answers a duplicate from its cache instead of executing
 *            the command twice;
 *   §3       nothing but `join` travels before the join is acked — actions
 *            raised earlier wait rather than being refused;
 *   §7.5     4400/4401/4408 are fatal and end the channel; anything else
 *            reconnects with backoff from 500 ms, capped at 10 s;
 *   §1       `?station_id=` is appended by the client, because
 *            `stations.ws_url` carries no query string.
 */
function createDriver(id, url, stationId, userId, vehicleId) {
  const ACTION_TIMEOUT_MS = 5000;
  const MAX_ATTEMPTS = 3;
  const BACKOFF_MIN_MS = 500;
  const BACKOFF_MAX_MS = 10000;
  const FATAL = { 4400: 'bad_request', 4401: 'token_rejected', 4408: 'token_expired' };

  const token = signToken(userId, vehicleId, `load${userId}`, 3600);

  let socket = null;
  let joined = false;
  let refused = null;
  let backoff = BACKOFF_MIN_MS;
  let closing = false;
  const pending = new Map();
  let queue = [];
  let joinWaiters = [];

  const self = {
    id, userId, vehicleId, stationId,
    lastState: null,
    lastSession: null,
    connect, send, joinedPromise, close,
  };

  function connect() {
    if (socket && (socket.readyState === 0 || socket.readyState === 1)) return;
    refused = null;
    socket = new WebSocket(`${url}?station_id=${encodeURIComponent(stationId)}`);
    socket.onopen = onOpen;
    socket.onmessage = (event) => onFrame(event.data);
    // onerror carries nothing useful and onclose always follows, so the
    // reconnection decision is taken in one place only.
    socket.onerror = () => { };
    socket.onclose = onClose;
  }

  function onOpen() {
    joined = false;
    // js/ws.js yields to the event loop here rather than writing inline: the
    // station refuses a bad `station_id` in its very first act (§3, close
    // 4400), and writing into that instant loses the race with the read, so
    // the 4400 arrives as a bare 1006. One turn of the loop, same as there.
    setTimeout(() => {
      const call = makeCall('join', { token });
      // Nobody holds this promise — a refused join is answered with a bare
      // close code, not an error frame — so it is neutralised here, exactly
      // as js/ws.js does, rather than surfacing as an unhandled rejection.
      call.promise.catch(() => { });
      transmit(call);
    }, 0);
  }

  function makeCall(action, payload) {
    const call = {
      // §2: UUID v4, one per action. `crypto.randomUUID` is in the runtime.
      id: crypto.randomUUID(),
      action, payload: payload || {},
      attempts: 0, timer: null, resolve: null, reject: null,
      raisedAt: Date.now(),
    };
    call.promise = new Promise((resolve, reject) => {
      call.resolve = resolve;
      call.reject = reject;
    });
    return call;
  }

  function transmit(call) {
    if (!socket || socket.readyState !== 1) {
      fail(call, 'offline', 'not connected to the station');
      return;
    }
    call.attempts += 1;
    pending.set(call.id, call);
    socket.send(JSON.stringify({
      action: call.action, request_id: call.id, payload: call.payload,
    }));
    call.timer = setTimeout(() => onTimeout(call), ACTION_TIMEOUT_MS);
  }

  function onTimeout(call) {
    if (!pending.has(call.id)) return;          // answered in the meantime
    if (call.attempts >= MAX_ATTEMPTS) {
      pending.delete(call.id);
      fail(call, 'TIMEOUT', 'the station did not answer');
      return;
    }
    // §7.2: the SAME request_id. This is the half of P7 that lives in the
    // client, and without it the station's cache is code nobody exercises.
    transmit(call);
  }

  function send(action, payload) {
    const call = makeCall(action, payload);
    if (refused) {
      fail(call, FATAL[refused], `the station refused this connection (${refused})`);
      return call.promise;
    }
    if (!joined) queue.push(call); else transmit(call);
    return call.promise;
  }

  function onFrame(data) {
    let frame;
    try {
      frame = JSON.parse(data);
    } catch (e) {
      log(`d${id} ! unparsable frame`, String(data).slice(0, 120));
      return;
    }
    switch (frame.type) {
      case 'ack':
      case 'error':
        settle(frame);
        break;
      case 'state':
        // §5.1: a complete snapshot, always. Replace, never patch — §7.1.
        self.lastState = frame.payload;
        break;
      case 'session':
        self.lastSession = frame.payload;
        break;
      case 'notification':
        log(`d${id} notification: ${frame.payload && frame.payload.kind}`);
        break;
      default:
        log(`d${id} ! unknown frame type`, frame.type);
    }
  }

  function settle(frame) {
    const call = pending.get(frame.request_id);
    if (!call) return;                          // already given up on
    clearTimeout(call.timer);
    pending.delete(call.id);
    if (frame.type === 'ack') {
      if (call.action === 'join') onJoined();
      call.resolve(frame.payload || {});
      return;
    }
    const p = frame.payload || {};
    call.reject({ code: p.code || 'ERROR', message: p.message || 'refused' });
  }

  function onJoined() {
    joined = true;
    // The backoff resets on a successful JOIN, not on a TCP open: a station
    // that accepts the socket and then closes it 4401 has not given us a
    // working connection.
    backoff = BACKOFF_MIN_MS;
    const waiting = queue.splice(0, queue.length);
    waiting.forEach(transmit);
    const waiters = joinWaiters.splice(0, joinWaiters.length);
    waiters.forEach((w) => w.resolve(self));
  }

  function onClose(event) {
    joined = false;
    socket = null;
    // §2: the at-most-once cache is per CONNECTION, so no id in flight may be
    // replayed on the next socket — the new connection starts with an empty
    // cache and would execute the command a second time. They fail here.
    failAll('DISCONNECTED', 'the connection dropped before the station answered');
    if (closing) return;
    if (FATAL[event.code]) {
      refused = event.code;
      joinWaiters.splice(0, joinWaiters.length)
        .forEach((w) => w.reject(new Error(`join refused ${event.code}`)));
      log(`d${id} ! refused ${event.code} (${FATAL[event.code]}) — not reconnecting`);
      return;
    }
    const wait = backoff;
    backoff = Math.min(backoff * 2, BACKOFF_MAX_MS);
    log(`d${id} disconnected (${event.code}); reconnecting in ${wait} ms`);
    setTimeout(connect, wait);
  }

  function fail(call, code, message) {
    clearTimeout(call.timer);
    call.reject({ code, message });
  }

  function failAll(code, message) {
    const inFlight = Array.from(pending.values());
    pending.clear();
    inFlight.forEach((call) => fail(call, code, message));
    queue.splice(0, queue.length).forEach((call) => fail(call, code, message));
  }

  function joinedPromise() {
    if (joined) return Promise.resolve(self);
    return new Promise((resolve, reject) => joinWaiters.push({ resolve, reject }));
  }

  function close() {
    closing = true;
    if (socket && socket.readyState === 1) socket.close(1000, 'done');
    socket = null;
  }

  return self;
}

// ---------------------------------------------------------------- measuring

/*
 * One record per action raised. The clock starts when the driver asks, not
 * when the frame goes out: a request that waited in the queue behind a slow
 * join waited, and hiding that would measure the station rather than the
 * experience. Retries are inside the same measurement for the same reason.
 */
function makeStats(name) {
  return { name, requests: 0, accepted: 0, outcomes: new Map(), latencies: [] };
}

function attempt(stats, driver, action, payload) {
  const t0 = Date.now();
  stats.requests += 1;
  return driver.send(action, payload).then(
    (ack) => record(stats, t0, 'ACK', { ok: true, payload: ack }),
    (err) => record(stats, t0, err.code || 'ERROR', { ok: false, error: err }));
}

function record(stats, t0, code, result) {
  const ms = Date.now() - t0;
  stats.latencies.push(ms);
  stats.outcomes.set(code, (stats.outcomes.get(code) || 0) + 1);
  if (result.ok) stats.accepted += 1;
  return Object.assign({ code, ms }, result);
}

function report(stats) {
  const l = stats.latencies;
  const max = l.length ? Math.max(...l) : 0;
  const mean = l.length ? Math.round(l.reduce((a, b) => a + b, 0) / l.length) : 0;
  const refused = stats.requests - stats.accepted;
  say('');
  say(`── ${stats.name} ────────────────────────────────────────`);
  say(`  requests        ${stats.requests}`);
  say(`  accepted        ${stats.accepted}`);
  say(`  refused         ${refused}`);
  for (const [code, n] of [...stats.outcomes].sort()) {
    if (code !== 'ACK') say(`      ${code.padEnd(14)} ${n}`);
  }
  // The number that matters is the MAX: a reservation that takes eight
  // seconds is a broken experience even when the mean is 200 ms.
  say(`  response time   max ${max} ms, mean ${mean} ms`);
  return { max, mean, refused };
}

// A count that has to come out exact: one accepted and N-1 refused, no
// remainder. A single different outcome and the invariant is violated.
function checkExact(stats, expectAccepted, expectCode) {
  const refused = stats.requests - stats.accepted;
  const byCode = stats.outcomes.get(expectCode) || 0;
  const ok = stats.accepted === expectAccepted
    && byCode === stats.requests - expectAccepted;
  say(`  invariant       ${expectAccepted} + ${stats.requests - expectAccepted}`
      + ` = ${stats.requests} as ${expectCode}: `
      + `${ok ? 'HOLDS' : 'VIOLATED'}`);
  if (!ok) {
    say(`                  got ${stats.accepted} accepted, ${refused} refused,`
        + ` ${byCode} of them ${expectCode}`);
  }
  return ok;
}

// ---------------------------------------------------------------- helpers

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const list = (s) => String(s).split(',').map((x) => Number(x.trim())).filter((n) => n > 0);

// Every driver connected AND joined before anything is asked of anybody: a
// "simultaneous" reserve sent while half the sockets are still handshaking
// would measure the handshake, not the contention.
async function barrier(drivers) {
  drivers.forEach((d) => d.connect());
  await Promise.all(drivers.map((d) => d.joinedPromise()));
}

function makeDrivers(n, url, stationId, firstUser, firstVehicle) {
  const out = [];
  for (let i = 0; i < n; i++) {
    out.push(createDriver(i + 1, url, stationId, firstUser + i, firstVehicle + i));
  }
  return out;
}

// The state of a station as one of its own drivers sees it, which is the only
// view this program is entitled to (§7.1: the server owns the truth).
function connectorsOf(driver) {
  return (driver.lastState && driver.lastState.connectors) || [];
}

function heldConnectors(driver) {
  return connectorsOf(driver).filter((c) => c.state === 'held');
}

// ---------------------------------------------------------------- scenario 1

/*
 * SCOPE §4, exclusive use, and ws-driver.md §4.1: N drivers ask for the same
 * free connector in the same instant. One is accepted; the rest are
 * ALREADY_HELD, raised by the connector itself — "this outlet is taken, try
 * the next one" — and not by the coordinator, which is a different refusal
 * with a different name (NO_CLAIM) and a different meaning.
 *
 * What it demonstrates: the actor serialises without a lock. Every request
 * for that outlet became a message in one process's mailbox, and the process
 * answered them one at a time in the order they arrived.
 */
async function contention() {
  const drivers = makeDrivers(cfg.drivers, cfg.url, cfg.station,
                              cfg['first-user'], cfg['first-vehicle']);
  const stats = makeStats(`contention — ${cfg.drivers} drivers, connector ${cfg.connector}`);
  log(`joining ${cfg.drivers} drivers on station ${cfg.station}`);
  await barrier(drivers);
  log(`all joined; firing ${cfg.drivers} reserves at connector ${cfg.connector}`);

  const results = await Promise.all(drivers.map(
    (d) => attempt(stats, d, 'reserve', { connector_id: cfg.connector })));

  const ok = report(stats);
  const exact = checkExact(stats, 1, 'ALREADY_HELD');

  // The station's own view has to agree: exactly one connector held, and by
  // the driver whose ack said so.
  const winner = drivers[results.findIndex((r) => r.ok)];
  await sleep(1500);                            // one state tick
  const held = winner ? heldConnectors(winner) : [];
  say(`  station says    ${held.length} connector(s) held: `
      + `${held.map((c) => c.connector_id).join(', ') || 'none'}`);

  if (winner) {
    log(`d${winner.id} cancelling, so the next run starts from a free connector`);
    await attempt(makeStats('cleanup'), winner, 'cancel_reservation',
                  { connector_id: cfg.connector });
  }
  drivers.forEach((d) => d.close());
  return exact && ok.max >= 0;
}

// ---------------------------------------------------------------- scenario 2

/*
 * claim.md's whole reason to exist: one vehicle, one reservation in the
 * NETWORK. The same `vehicle_id` asks for connectors on two different
 * stations at the same instant, so no single station can settle it — the
 * coordinator does, and the losers come back `{error, _, already_held}`,
 * which ws-driver.md §4.1 maps to NO_CLAIM: "your vehicle already holds a
 * reservation elsewhere".
 *
 * Every driver here carries the SAME token: identity comes from the token and
 * never from a payload (§7.3), so one vehicle asking twice is exactly one
 * token used twice.
 */
async function oneVehicle() {
  const targets = [
    ...list(cfg.connectors).map((c) => ({ url: cfg.url, station: cfg.station, connector: c })),
    ...list(cfg.connectors2).map((c) => ({ url: cfg.url2, station: cfg.station2, connector: c })),
  ];
  const user = cfg['first-user'];
  const vehicle = cfg['first-vehicle'];
  const drivers = targets.map((t, i) =>
    createDriver(i + 1, t.url, t.station, user, vehicle));
  const stats = makeStats(
    `one vehicle, one reservation — vehicle ${vehicle}, ${targets.length} connectors`);

  log(`joining vehicle ${vehicle} on ${targets.length} sockets across two stations`);
  await barrier(drivers);
  log(`all joined; firing ${targets.length} reserves at once`);

  const results = await Promise.all(drivers.map(
    (d, i) => attempt(stats, d, 'reserve', { connector_id: targets[i].connector })));

  report(stats);
  // NO_CLAIM is the expected refusal, but ALREADY_HELD is a legitimate second
  // one: two of these sockets may hit connectors that a previous run or a
  // charge point left busy. Counted separately so a run that is merely dirty
  // does not read as a violated invariant.
  const noClaim = stats.outcomes.get('NO_CLAIM') || 0;
  const alsoHeld = stats.outcomes.get('ALREADY_HELD') || 0;
  const ok = stats.accepted === 1 && noClaim + alsoHeld === stats.requests - 1;
  say(`  invariant       exactly one reservation survives: ${ok ? 'HOLDS' : 'VIOLATED'}`);
  say(`                  ${stats.accepted} accepted, ${noClaim} NO_CLAIM,`
      + ` ${alsoHeld} ALREADY_HELD (connector busy for another reason)`);

  const idx = results.findIndex((r) => r.ok);
  if (idx >= 0) {
    log(`cancelling the surviving reservation on connector ${targets[idx].connector}`);
    await attempt(makeStats('cleanup'), drivers[idx], 'cancel_reservation',
                  { connector_id: targets[idx].connector });
  }
  drivers.forEach((d) => d.close());
  return ok;
}

// ---------------------------------------------------------------- scenario 3

/*
 * M drivers joining, looking, reserving and cancelling in a loop while the
 * charge points deliver power. Nothing here is meant to be fast; it is meant
 * to run long enough for something to leak.
 *
 * What is checked at the end: no crash, and no connector left `held` by
 * nobody. The second is the one that would bite — a reservation whose owner
 * went away and whose lease has not run out yet is a connector nobody can use
 * and nobody is paying for. (`LEASE_SECONDS` is 900 by default, so a leak
 * here would sit there for fifteen minutes.)
 *
 * Memory is deliberately NOT measured from in here: this program only knows
 * what ws-driver.md tells it, and `erlang:memory/1` is not in that contract.
 * It is sampled from outside, next to the run.
 */
async function sustained() {
  const half = Math.max(1, Math.floor(cfg.drivers / 2));
  const drivers = [
    ...makeDrivers(half, cfg.url, cfg.station,
                   cfg['first-user'], cfg['first-vehicle']),
    ...makeDrivers(cfg.drivers - half, cfg.url2, cfg.station2,
                   cfg['first-user'] + half, cfg['first-vehicle'] + half),
  ];
  const pools = [list(cfg.connectors), list(cfg.connectors2)];
  const stats = makeStats(`sustained — ${cfg.drivers} drivers, ${cfg.seconds} s`);

  log(`joining ${cfg.drivers} drivers across two stations`);
  await barrier(drivers);
  const deadline = Date.now() + cfg.seconds * 1000;
  log(`looping until ${new Date(deadline).toISOString().slice(11, 19)}`);

  async function cycle(driver, index) {
    const pool = pools[index < half ? 0 : 1];
    let picked = 0;
    while (Date.now() < deadline) {
      const connector = pool[Math.floor(Math.random() * pool.length)];
      const got = await attempt(stats, driver, 'reserve', { connector_id: connector });
      if (got.ok) {
        picked += 1;
        await sleep(cfg.think);
        // An explicit cancellation costs no penalty; a no-show does
        // (§4.2). A load generator that walked away would be teaching the
        // station to hand out penalties, not testing it.
        await attempt(stats, driver, 'cancel_reservation', { connector_id: connector });
      }
      await sleep(cfg.think);
    }
    return picked;
  }

  const picked = await Promise.all(drivers.map(cycle));
  report(stats);
  say(`  reservations    ${picked.reduce((a, b) => a + b, 0)} granted and released`);

  // One state tick, then look: after everybody has cancelled, nothing on
  // either station may still be held.
  await sleep(2000);
  let leaked = 0;
  for (const station of [0, half]) {
    const d = drivers[station];
    const held = heldConnectors(d);
    leaked += held.length;
    say(`  station ${d.stationId}       ${connectorsOf(d).length} connectors, `
        + `${held.length} still held${held.length ? ': ' + held.map((c) => c.connector_id).join(', ') : ''}`);
    const charging = connectorsOf(d).filter((c) => c.state === 'charging'
                                                || c.state === 'suspended');
    say(`                  ${charging.length} charging throughout`);
  }
  say(`  invariant       no connector held by nobody: ${leaked === 0 ? 'HOLDS' : 'VIOLATED'}`);

  let owned = true;
  if (cfg['charging-connector'] > 0) {
    owned = await ownershipProbe(drivers[0]);
  }
  drivers.forEach((d) => d.close());
  return leaked === 0 && owned;
}

/*
 * The two halves of the contract that only the OWNER of a running session can
 * show, and the reason `stop_session` and the `session` frame are in this
 * program at all.
 *
 *   §5.2  `session` is pushed to the owner of a running session and to
 *         nobody else — a driver who is merely watching the station gets
 *         `state` and nothing more;
 *   §4.3  `stop_session` on somebody else's charge is NOT_YOURS. Identity
 *         comes from the token (§7.3), so a stranger cannot borrow it by
 *         editing a payload — there is no field to edit.
 *
 * Once, after the loop rather than inside it: the subject is an authorisation
 * rule, and repeating it a thousand times would add noise to the numbers
 * above without adding a fact. It ends the charge, which is the point — the
 * station tells the charge point to stop and writes the row.
 */
async function ownershipProbe(stranger) {
  const connector = cfg['charging-connector'];
  const stats = makeStats(`ownership — connector ${connector}`);
  const owner = createDriver(0, cfg.url, cfg.station,
                             cfg['owner-user'], cfg['owner-vehicle']);
  owner.connect();
  await owner.joinedPromise();
  // §5.2 is pushed on a tick, not on demand: give it one.
  await sleep(6000);

  say('');
  say(`── ownership on connector ${connector} ────────────────────────────────`);
  say(`  stranger sees session frames: ${stranger.lastSession ? 'YES' : 'no'}`);
  const s = owner.lastSession;
  say(`  owner sees session frames:    ${s ? 'YES' : 'no'}`);
  if (s) {
    say(`      phase ${s.phase}, ${s.power_kw} kW, ${s.energy_kwh} kWh,`
        + ` soc ${s.soc_pct}%, eta ${s.eta_seconds}s`);
  }

  const byStranger = await attempt(stats, stranger, 'stop_session',
                                   { connector_id: connector });
  say(`  stranger stop_session:        ${byStranger.code}`);
  const byOwner = await attempt(stats, owner, 'stop_session',
                                { connector_id: connector });
  say(`  owner stop_session:           ${byOwner.code}`);
  report(stats);

  const ok = !stranger.lastSession && !!s
    && byStranger.code === 'NOT_YOURS' && byOwner.ok;
  say(`  invariant       the session is the owner's alone: `
      + `${ok ? 'HOLDS' : 'VIOLATED'}`);
  owner.close();
  return ok;
}

// ---------------------------------------------------------------- main

async function main() {
  if (cfg['self-test']) selfTest();
  const scenarios = { contention, 'one-vehicle': oneVehicle, sustained };
  const run = scenarios[cfg.scenario];
  if (!run) die(`unknown scenario ${cfg.scenario}${USAGE}`);
  say(`voltshare driver emulator — scenario ${cfg.scenario}`);
  const ok = await run();
  say('');
  say(ok ? 'all invariants held.' : 'AN INVARIANT WAS VIOLATED — see above.');
  // A beat for the close frames to leave before the loop is torn down.
  setTimeout(() => process.exit(ok ? 0 : 1), 300);
}

process.on('SIGINT', () => {
  say('\ninterrupted');
  process.exit(130);
});

main().catch((err) => {
  process.stderr.write(`driver.js: ${err && err.stack ? err.stack : err}\n`);
  process.exit(2);
});
