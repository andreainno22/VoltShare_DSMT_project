#!/usr/bin/env node
'use strict';

/*
 * VoltShare — charge point emulator (contracts/ws-chargepoint.md, CP side).
 *
 * Zero npm dependencies, on purpose. `WebSocket` is a global in Node >= 22,
 * so this file is the whole client: nothing to install, nothing to keep in
 * sync with a lockfile, and one less thing that can be broken on the
 * machine where the demo is shown. Node 24 measured here; the version check
 * below fails loudly rather than dying on `WebSocket is not defined`.
 *
 * This is half of a contract, not a toy. Everything the station is entitled
 * to expect is here: boot, heartbeat, plugged, meter, unplugged, the two
 * commands, and the reconnection of §6 that carries the cumulative energy
 * across a station restart. The station is only as credible as the thing
 * that talks to it.
 */

const MIN_NODE_MAJOR = 22;

// ---------------------------------------------------------------- CLI

const USAGE = `
usage: node cp.js --url ws://host:port/ws/cp --station <id> --connector <id>
                  --vehicle <id> --soc <pct> --battery <kwh> --max-kw <kw>
                  [--plug-after <s>] [--unplug-at-soc <pct>]
                  [--limit-apply <s>] [--quiet]
`;

const DEFAULTS = {
  url: 'ws://localhost:9201/ws/cp',
  station: 1,
  connector: 3,
  vehicle: 88,
  soc: 22,
  battery: 58,
  'max-kw': 150,
  'plug-after': 2,
  'unplug-at-soc': null,
  // ws-chargepoint.md §10: the window within which a new limit must be
  // honoured. The station does not hand it over at boot — it is the
  // station's own tolerance — so it is a flag with the contract's default.
  'limit-apply': 5,
  quiet: false,
  // §3.1 says the equipment carries no configuration of its own, so these
  // are placeholders until the boot ack replaces them.
  vendor: 'VoltShare-Emu',
  model: 'EMU-150',
  firmware: '0.1.0',
  'rated-kw': 150,
};

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
    if (key === 'quiet') { out.quiet = true; continue; }
    const value = argv[++i];
    if (value === undefined) die(`--${key} needs a value`);
    out[key] = typeof DEFAULTS[key] === 'number' || DEFAULTS[key] === null
      ? Number(value)
      : value;
    if (typeof out[key] === 'number' && Number.isNaN(out[key])) {
      die(`--${key} must be a number, got ${value}`);
    }
  }
  return out;
}

function die(message) {
  process.stderr.write(`cp.js: ${message}\n`);
  process.exit(2);
}

// ---------------------------------------------------------------- state

const cfg = parseArgs(process.argv.slice(2));

const major = Number(process.versions.node.split('.')[0]);
if (major < MIN_NODE_MAJOR || typeof WebSocket !== 'function') {
  die(`needs Node >= ${MIN_NODE_MAJOR} for the built-in WebSocket client `
      + `(this is ${process.versions.node})`);
}

// What survives a reconnection, and why each one does:
//   energyKwh — §4.3, cumulative and monotonic; the charge point is the
//               only side that counts it, so it is the one thing a station
//               restart cannot reconstruct (§6.4).
//   socPct    — the car's, not the station's.
//   plugged   — the cable does not come out because a socket died.
const car = {
  energyKwh: 0,
  socPct: cfg.soc,
  plugged: false,
  delivering: false,
};

// What the station told us at boot. Replaced on every boot ack, never
// remembered across runs: §3.1, the equipment carries no configuration.
const station = {
  heartbeatIntervalS: 30,
  meterIntervalS: 5,
  clockSkewMs: 0,
};

// The limit, and the ramp towards it. Real hardware does not step, and §5
// gives it LIMIT_APPLY_SECONDS to get there.
const limit = { from: 0, target: 0, atMs: 0 };

let ws = null;
let requestSeq = 0;
let backoffMs = 1000;
const timers = { heartbeat: null, meter: null, plug: null };
let stopping = false;

// ---------------------------------------------------------------- log

function log(...parts) {
  if (cfg.quiet) return;
  const t = new Date().toISOString().slice(11, 23);
  process.stdout.write(`${t} conn${cfg.connector} ${parts.join(' ')}\n`);
}

// ---------------------------------------------------------------- wire

function requestId() {
  requestSeq += 1;
  return `cp-${requestSeq}`;
}

function send(action, payload) {
  if (!ws || ws.readyState !== 1) return null;
  const id = requestId();
  ws.send(JSON.stringify({ action, request_id: id, payload }));
  return id;
}

function connect() {
  const url = `${cfg.url}?station_id=${cfg.station}&connector_id=${cfg.connector}`;
  log('connecting to', url);
  ws = new WebSocket(url);
  ws.onopen = onOpen;
  ws.onmessage = (event) => onFrame(event.data);
  ws.onerror = () => { /* onclose always follows; the reason is there */ };
  ws.onclose = onClose;
}

function onOpen() {
  backoffMs = 1000;
  log('connected');
  // §3.1: "First frame after connecting, before anything else."
  send('boot', {
    vendor: cfg.vendor,
    model: cfg.model,
    firmware: cfg.firmware,
    rated_kw: cfg['rated-kw'],
    // §3.1: "reports its true physical status" — the hardware is
    // authoritative on this, and it is what lets the station take a
    // connector back out of out_of_service.
    status: car.plugged ? 'occupied' : 'available',
  });
}

// §6: the socket died under a live session. Reconnect with backoff, boot
// again, and re-announce the cable with the energy counted so far — the
// station has no memory of it and adopts what the hardware reports.
function onClose(event) {
  clearTimers();
  if (stopping) return;
  const code = event && event.code;
  if (code === 4404) {
    die(`the station refused connector ${cfg.connector} (4404): it does not `
        + `belong to station ${cfg.station}`);
  }
  if (code === 4409) {
    die(`another socket took connector ${cfg.connector} over (4409): a second `
        + `emulator is already running against it`);
  }
  log(`disconnected (code ${code}); retrying in ${backoffMs} ms`);
  setTimeout(connect, backoffMs);
  // §6.1: 1 s, doubling, capped at 30 s.
  backoffMs = Math.min(backoffMs * 2, 30000);
}

function onFrame(data) {
  let msg;
  try {
    msg = JSON.parse(data);
  } catch (_) {
    log('! unreadable frame from the station:', String(data).slice(0, 120));
    return;
  }
  if (msg.type === 'ack') return onAck(msg);
  if (msg.type === 'command') return onCommand(msg);
  log('! unknown frame type', msg.type);
}

function onAck(msg) {
  const p = msg.payload || {};
  if (p.accepted === false) {
    // §3.1: "the charge point closes and retries with backoff".
    log(`! boot refused (${p.reason || 'no reason given'}); backing off`);
    ws.close();
    return;
  }
  if (p.heartbeat_interval_s !== undefined) {
    station.heartbeatIntervalS = p.heartbeat_interval_s;
    station.meterIntervalS = p.meter_interval_s;
    setLimit(p.limit_kw || 0, 'boot ack');
    log(`boot accepted (${msg.request_id}): heartbeat ${station.heartbeatIntervalS}s, `
        + `meter ${station.meterIntervalS}s, limit ${p.limit_kw} kW`);
    afterBoot();
  }
  if (p.server_time !== undefined) {
    // §3.2: "timestamps that matter for billing are always taken by the
    // station" — this clock is a convenience, and nothing here bills on it.
    station.clockSkewMs = p.server_time - Date.now();
  }
}

function onCommand(msg) {
  const p = msg.payload || {};
  if (p.command === 'set_limit') {
    // §5: "It applies them and reflects the result in its next meter or
    // status; it never argues."
    setLimit(Number(p.limit_kw) || 0, 'set_limit');
    return;
  }
  if (p.command === 'stop') return onStop(p.reason);
  log('! unknown command', p.command);
}

// ---------------------------------------------------------------- bring-up

function afterBoot() {
  clearTimers();
  timers.heartbeat = setInterval(heartbeat, station.heartbeatIntervalS * 1000);
  timers.meter = setInterval(meter, station.meterIntervalS * 1000);
  if (car.plugged) {
    // §6.2: reconnecting under a live session. The cable never came out.
    plugged('re-announcing after a reconnection');
  } else {
    timers.plug = setTimeout(() => plugged('cable in'), cfg['plug-after'] * 1000);
  }
}

function heartbeat() {
  send('heartbeat', {});
}

function plugged(why) {
  car.plugged = true;
  car.delivering = true;
  const id = send('plugged', {
    vehicle_id: cfg.vehicle,
    soc_pct: Math.round(car.socPct),
    battery_kwh: cfg.battery,
    max_kw: cfg['max-kw'],
    // §6.2: "a plugged with the vehicle and the cumulative energy it has
    // counted". Zero on a first plug, which is the same statement.
    energy_kwh: round3(car.energyKwh),
  });
  log(`plugged (${id}): vehicle ${cfg.vehicle}, soc ${Math.round(car.socPct)}%, `
      + `carried energy ${round3(car.energyKwh)} kWh — ${why}`);
}

// ---------------------------------------------------------------- charging

// §5: "0 means suspended: the session stays open and draws nothing."
//
// The repetition test is against `limit.target`, NOT against the value the
// ramp happens to be passing through. §5 has the station re-send the limit
// on every recomputation even when it is unchanged, so identical commands
// arrive every tick; comparing them with the interpolated value would find
// them different for as long as the ramp is running, restart it from where
// it is with a fresh window, and stretch it by one tick each time. It still
// converges, but the applied-limit time measured in the demo would be
// longer than the hardware's real one — the emulator making the station
// look worse than it is, which is the same sin as making it look better.
//
// A genuinely new value still ramps from `appliedLimit(now)`: the hardware
// is where it is, not where it was told to go.
function setLimit(kw, why) {
  if (Math.abs(limit.target - kw) < 0.001) return;   // repeated, not changed
  const now = Date.now();
  const current = appliedLimit(now);
  limit.from = current;
  limit.target = kw;
  limit.atMs = now;
  log(`limit ${round1(current)} -> ${round1(kw)} kW over ${cfg['limit-apply']}s (${why})`);
}

// Real hardware ramps, and §5 gives it LIMIT_APPLY_SECONDS to arrive.
// Stepping instantly would make the station's power scenario look better
// than it is.
function appliedLimit(nowMs) {
  const window = cfg['limit-apply'] * 1000;
  if (window <= 0) return limit.target;
  const elapsed = nowMs - limit.atMs;
  if (elapsed >= window) return limit.target;
  return limit.from + (limit.target - limit.from) * (elapsed / window);
}

// The car's own curve. Above 80 % it tapers towards a trickle, which is
// what makes the station's redistribution worth doing (§4.3: "power_kw is
// what is actually flowing, which may be below the allocated limit when
// the car itself is tapering").
function taper(socPct) {
  if (socPct <= 80) return 1;
  return Math.max(0.05, 1 - ((socPct - 80) / 20) * 0.95);
}

function meter() {
  if (!car.plugged || !car.delivering) return;
  const power = Math.min(appliedLimit(Date.now()), cfg['max-kw']) * taper(car.socPct);
  const deltaKwh = (power * station.meterIntervalS) / 3600;
  // §4.3: cumulative and monotonic. It only ever grows here, which is the
  // property the station's max(stored, reported) is protecting.
  car.energyKwh += deltaKwh;
  if (cfg.battery > 0) {
    car.socPct = Math.min(100, car.socPct + (deltaKwh / cfg.battery) * 100);
  }
  const id = send('meter', {
    power_kw: round1(power),
    energy_kwh: round3(car.energyKwh),
    soc_pct: Math.round(car.socPct),
  });
  log(`meter (${id}): ${round1(power)} kW, ${round3(car.energyKwh)} kWh, `
      + `soc ${Math.round(car.socPct)}%`);

  const target = cfg['unplug-at-soc'];
  if (target !== null && car.socPct >= target) {
    unplug(`soc reached ${target}%`);
  }
}

// ---------------------------------------------------------------- ending

function onStop(reason) {
  car.delivering = false;
  log(`! stop from the station: ${reason}`);
  if (reason === 'station_shutdown') {
    // The station is going away, not the car. Keep the cable in and keep
    // the counter: the reconnection of §6 is exactly what this is for, and
    // the energy delivered so far comes back with the next `plugged'.
    return;
  }
  if (reason === 'not_your_reservation') {
    // §4.2: the station never authorised this car. There is no session to
    // end, so there is nothing to report.
    finish(2, 'refused: this connector is reserved for another vehicle');
    return;
  }
  // driver_stopped, claim_revoked, faulted, target_reached: delivery is
  // over. Nobody here can pull a cable, so the emulator does what the
  // driver would do next and reports the total.
  unplug(`stopped: ${reason}`);
}

function unplug(why) {
  if (!car.plugged) return finish(0, why);
  car.plugged = false;
  car.delivering = false;
  // §4.4: the final total, the number the sessions row is written with.
  const id = send('unplugged', { energy_kwh: round3(car.energyKwh) });
  log(`unplugged (${id}): ${round3(car.energyKwh)} kWh — ${why}`);
  // A beat for the frame to leave before the socket does.
  setTimeout(() => finish(0, why), 200);
}

function finish(code, why) {
  stopping = true;
  clearTimers();
  if (ws && ws.readyState === 1) ws.close(1000, 'done');
  process.stdout.write(
    `final energy_kwh = ${round3(car.energyKwh)} (soc ${Math.round(car.socPct)}%, ${why})\n`);
  // Give the close frame a moment; the socket keeps the loop alive
  // otherwise and an exit here would truncate it.
  setTimeout(() => process.exit(code), 200);
}

function clearTimers() {
  for (const key of Object.keys(timers)) {
    if (timers[key] !== null) {
      clearInterval(timers[key]);
      clearTimeout(timers[key]);
      timers[key] = null;
    }
  }
}

// Ctrl-C is a driver pulling the cable: end the session properly rather
// than leaving the station to discover it three heartbeats later.
process.on('SIGINT', () => unplug('interrupted'));

// ---------------------------------------------------------------- helpers

function round1(x) { return Math.round(x * 10) / 10; }
function round3(x) { return Math.round(x * 1000) / 1000; }

connect();
