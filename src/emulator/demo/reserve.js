#!/usr/bin/env node
/**
 * reserve.js — one driver, one action, then out.
 *
 * The smallest possible client of contracts/ws-driver.md: open the socket, `join`
 * with a signed JWT, send exactly one action, print what came back, close.
 *
 * It exists for one beat of the demo. `driver.js --scenario one-vehicle` cannot be
 * used to leave a reservation standing, because it deliberately cancels the
 * surviving one at the end of its run; and a walk-in through `cp.js` never creates
 * a claim at all (`vs_connector:free/3` adopts the session with `claim_id =
 * undefined`). So without this, the failover beat of DEMO.md §10.1 would show the
 * new leader rebuilding an empty table — the coordinator working perfectly and
 * proving nothing.
 *
 * The reservation outlives this process: it lives in the connector's state
 * machine, not in the socket (ws-driver.md §7.5). Fire and walk away.
 *
 *   node demo/reserve.js --station 1 --connector 3 --user 103 --vehicle 103 --action reserve
 *   node demo/reserve.js --station 1 --connector 3 --user 103 --vehicle 103 --action cancel_reservation
 *   node demo/reserve.js --station 2 --connector 5 --user 104 --vehicle 104 --action none
 *
 * `--action none` joins and prints the first `state` frame without touching
 * anything: useful to read a station's connectors from a terminal.
 *
 * Node >= 22, no dependencies: WebSocket and crypto are built in.
 *
 * On the signing: this uses the DEVELOPMENT secret from contracts/sample-tokens.md,
 * exactly as driver.js does, and for the same stated reason — the secret is
 * published, so a tool that signs with it can only ever work against a development
 * deployment. `vs_jwt:secret/0` logs a warning when it verifies with that secret;
 * this is the mirror image of that warning.
 */

'use strict';

const crypto = require('crypto');

// ---------------------------------------------------------------- arguments

const DEFAULTS = {
  station: 1,
  connector: 3,
  user: 103,
  vehicle: 103,
  action: 'reserve',
  url: null,                                   // derived from --station if absent
  secret: 'dev-secret-change-me-0123456789ab', // sample-tokens.md: 32 chars for HS256
  issuer: 'voltshare-backoffice',
  timeout: 8000,
};

const ACTIONS = ['reserve', 'cancel_reservation', 'stop_session', 'none'];

function parseArgs(argv) {
  const cfg = { ...DEFAULTS };
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) usage(`unexpected argument: ${key}`);
    const name = key.slice(2);
    if (!(name in cfg)) usage(`unknown option: ${key}`);
    const value = argv[i + 1];
    if (value === undefined) usage(`${key} needs a value`);
    cfg[name] = /^\d+$/.test(value) && name !== 'action' && name !== 'url'
      && name !== 'secret' && name !== 'issuer' ? Number(value) : value;
    i += 1;
  }
  if (!ACTIONS.includes(cfg.action)) usage(`--action must be one of ${ACTIONS.join(', ')}`);
  // Station 1 answers on 9101, station 2 on 9102 (docker-compose.yml).
  if (!cfg.url) cfg.url = `ws://localhost:${cfg.station === 2 ? 9102 : 9101}/ws/driver`;
  return cfg;
}

function usage(problem) {
  console.error(`reserve.js: ${problem}
usage: node demo/reserve.js [--station 1|2] [--connector N] [--user N] [--vehicle N]
                            [--action reserve|cancel_reservation|stop_session|none]
                            [--url ws://…] [--secret S] [--issuer S] [--timeout ms]`);
  process.exit(2);
}

// ---------------------------------------------------------------- the token

const b64url = (buf) => Buffer.from(buf).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function signToken(cfg) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'HS256' }));
  // The claims jwt.md §1 fixes, and no others beyond `iat`.
  const payload = b64url(JSON.stringify({
    sub: String(cfg.user),
    username: `demo${cfg.user}`,
    vehicle_id: cfg.vehicle,
    iss: cfg.issuer,
    iat: now,
    exp: now + 3600,
  }));
  const signature = b64url(
    crypto.createHmac('sha256', cfg.secret).update(`${header}.${payload}`).digest());
  return `${header}.${payload}.${signature}`;
}

// ---------------------------------------------------------------- the run

const cfg = parseArgs(process.argv);
const stamp = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(stamp(), ...a);

const socket = new WebSocket(`${cfg.url}?station_id=${cfg.station}`);
let done = false;

// A hard stop, so this can never hang a script that runs it in sequence.
const giveUp = setTimeout(() => finish(3, `no answer within ${cfg.timeout} ms`), cfg.timeout);

function finish(code, message) {
  if (done) return;
  done = true;
  clearTimeout(giveUp);
  if (message) log(message);
  try { socket.close(); } catch { /* already closing */ }
  // Let the close frame leave before the process does.
  setTimeout(() => process.exit(code), 50);
}

function send(action, payload) {
  const id = crypto.randomUUID();
  socket.send(JSON.stringify({ action, request_id: id, payload: payload || {} }));
  return id;
}

let joinId = null;
let actionId = null;

socket.addEventListener('open', () => {
  log(`connected to ${cfg.url} (station ${cfg.station})`);
  joinId = send('join', { token: signToken(cfg) });
});

socket.addEventListener('message', (event) => {
  let frame;
  try {
    frame = JSON.parse(event.data);
  } catch {
    log('unparsable frame, ignored');
    return;
  }

  // §5.1: the station pushes `state` unprompted. With --action none that is the
  // whole point of running this; otherwise it is noise between the two acks.
  if (frame.type === 'state') {
    if (cfg.action === 'none') {
      const conns = (frame.payload && frame.payload.connectors) || [];
      log(`state · ${conns.length} connector(s)`);
      for (const c of conns) {
        log(`   conn ${c.connector_id}: ${c.state}` +
            (c.held_by_me ? ' (held by me)' : '') +
            (c.rated_kw ? ` · ${c.rated_kw} kW` : ''));
      }
      finish(0, 'read the state, nothing changed');
    }
    return;
  }

  if (frame.request_id === joinId) {
    if (frame.type !== 'ack') {
      const p = frame.payload || {};
      finish(1, `join refused: ${p.code || 'ERROR'} — ${p.message || ''}`);
      return;
    }
    log(`joined as user ${cfg.user}, vehicle ${cfg.vehicle}`);
    if (cfg.action === 'none') return;          // wait for the state frame
    actionId = send(cfg.action, { connector_id: cfg.connector });
    log(`sent ${cfg.action} on connector ${cfg.connector}`);
    return;
  }

  if (frame.request_id === actionId) {
    if (frame.type === 'ack') {
      // The reservation stays behind: it belongs to the connector, not to this
      // socket, so closing here does not give it back (ws-driver.md §7.5).
      finish(0, `${cfg.action} accepted — it survives this process`);
    } else {
      const p = frame.payload || {};
      finish(1, `${cfg.action} refused: ${p.code || 'ERROR'} — ${p.message || ''}`);
    }
  }
});

socket.addEventListener('close', (event) => {
  // 4401 is "no join within 5 s", 4400 a malformed request: both mean the frame
  // never reached the connector, so say so instead of exiting quietly.
  if (!done) finish(1, `socket closed (${event.code}) before the action was answered`);
});

socket.addEventListener('error', () => {
  if (!done) finish(1, `cannot reach ${cfg.url} — is the station up?`);
});
