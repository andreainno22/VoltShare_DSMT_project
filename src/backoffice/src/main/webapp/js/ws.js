/* VoltShare — the driver channel, transport half.  Owned by A.
 *
 * Speaks contracts/ws-driver.md and knows nothing about the DOM: connection,
 * handshake, request ids, at-most-once retries, reconnection, frame routing.
 * The rendering half is station.js.
 *
 * Why the split: this file is the same for every page that speaks the driver
 * contract — the station view, the session view of M2, and the emulated
 * drivers of the load generator (ws-driver.md, header).  Only the rendering
 * changes from one to the next.  In one file, the second page would copy it.
 *
 * No library and no bundler, like the rest of the application.
 *
 * ── About ping frames ────────────────────────────────────────────────────
 * There is deliberately NO ping code here, and this comment exists because
 * it is the first thing somebody will come looking for.  The station sends a
 * WebSocket ping alongside every state tick; the browser answers it with a
 * pong entirely on its own, below the JavaScript API — RFC 6455 §5.5.2 makes
 * that mandatory, and the WebSocket API exposes no hook for it.  That pong is
 * inbound traffic, which is what keeps the station's WS_IDLE_TIMEOUT_MS from
 * closing a page that has joined and is only watching.  Nothing to write.
 */

'use strict';

/**
 * @param {{url: string, station: number, token: string}} config
 * @returns a channel with connect(), send(action, payload) -> Promise,
 *          and the onState / onNotification / onStatusChange callbacks.
 */
function createDriverChannel(config) {

    /* ws-driver.md §10 and §7.2/§7.5. */
    var ACTION_TIMEOUT_MS = 5000;   // per attempt, not per action
    var MAX_ATTEMPTS      = 3;      // first send + two retries
    var BACKOFF_MIN_MS    = 500;
    var BACKOFF_MAX_MS    = 10000;

    /* §3: the close codes that mean "do not come back".  Reconnecting on
     * these would be a page hammering the station forever with a token that
     * is never going to become valid (4401/4408), or a loop that hides a bug
     * of ours behind a retry (4400). */
    var FATAL = {
        4400: 'bad_request',     // missing station_id, malformed frame — our bug
        4401: 'token_rejected',  // invalid signature, wrong issuer, or no join in time
        4408: 'token_expired'
    };

    var socket   = null;
    var joined   = false;
    var backoff  = BACKOFF_MIN_MS;
    var pending  = new Map();   // request_id -> call, in flight right now
    var queue    = [];          // actions raised before the join was acked
    var handlers = { onState: null, onNotification: null, onStatusChange: null };

    /* ── the endpoint ──────────────────────────────────────────────────── */

    function endpoint() {
        /* stations.ws_url is what the station announced about itself and what
         * the coordinator stored (ws-driver.md §1) — "ws://localhost:9101/ws/driver",
         * with NO query string.  vs_driver_ws closes 4400 when station_id is
         * missing from the query, and also when it names a different station
         * than the node serves.  Appending it is therefore the client's job,
         * and this is the only place that knows it. */
        return config.url + '?station_id=' + encodeURIComponent(config.station);
    }

    /* §2: UUID v4.  crypto.randomUUID needs a secure context, which
     * http://localhost is; the fallback exists so that serving the page from
     * a plain-http host degrades to a working id instead of a TypeError that
     * would break every action silently. */
    function newRequestId() {
        if (window.crypto && typeof window.crypto.randomUUID === 'function') {
            return window.crypto.randomUUID();
        }
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
            var r = (window.crypto && window.crypto.getRandomValues)
                ? window.crypto.getRandomValues(new Uint8Array(1))[0] % 16
                : Math.floor(Math.random() * 16);
            var v = (c === 'x') ? r : ((r & 0x3) | 0x8);
            return v.toString(16);
        });
    }

    function status(state, code) {
        if (handlers.onStatusChange) {
            handlers.onStatusChange({
                state: state,
                code: (code === undefined) ? null : code,
                reason: (code && FATAL[code]) ? FATAL[code] : null
            });
        }
    }

    /* ── connecting ────────────────────────────────────────────────────── */

    function connect() {
        if (socket && (socket.readyState === WebSocket.CONNECTING ||
                       socket.readyState === WebSocket.OPEN)) {
            return;
        }
        status('connecting');
        socket = new WebSocket(endpoint());
        socket.onopen    = onOpen;
        socket.onmessage = onMessage;
        socket.onclose   = onClose;
        /* onerror carries no useful detail in browsers and is always followed
         * by onclose (with 1006 when the failure was at the network level),
         * so the reconnection decision is taken in one place only. */
        socket.onerror   = function () { };
    }

    function onOpen() {
        joined = false;
        /* §3: the socket opens unauthenticated and is useless until the first
         * frame; the station closes 4401 if no join arrives within
         * JOIN_TIMEOUT_MS (5 s).  A fresh request_id every time — see onClose
         * for why an old one must never be reused on a new socket. */
        /* Yielded to the event loop instead of sent inline, and the reason is
         * measured, not stylistic.  The station refuses a bad `station_id` in
         * its very first act (§3, close 4400), so the close frame is often
         * already in the receive buffer when `open` fires.  Writing to the
         * socket in that instant makes the write lose the race with the read:
         * the peer is gone, the connection resets, and the close arrives as a
         * bare 1006 with the 4400 thrown away — which would send the page
         * into exactly the reconnect loop §7.5 forbids for 4400, hiding a bug
         * of ours behind an infinite retry.  One turn of the event loop lets
         * the close be delivered first; the join still leaves far inside
         * JOIN_TIMEOUT_MS, and `transmit` refuses to write to a socket that
         * is no longer OPEN. */
        window.setTimeout(sendJoin, 0);
    }

    function sendJoin() {
        var join = makeCall('join', { token: config.token });
        /* This one call is raised by the channel itself, so nobody is holding
         * its promise.  A refused join does not come back as an error frame —
         * §3 answers it with a bare close code — so the rejection would land
         * nowhere and surface as "Uncaught (in promise)" in the console of
         * every driver whose token expired.  The outcome is reported through
         * onStatusChange, which is where the page is actually looking; the
         * promise is neutralised here on purpose. */
        join.promise.catch(function () { });
        transmit(join);
    }

    /* ── sending ───────────────────────────────────────────────────────── */

    function makeCall(action, payload) {
        var call = {
            /* §2: one id per USER ACTION, not per transmission.  Every retry
             * of this action reuses it, which is precisely what lets the
             * station recognise the retry and answer from its cache. */
            id: newRequestId(),
            action: action,
            payload: payload || {},
            attempts: 0,
            timer: null,
            resolve: null,
            reject: null
        };
        call.promise = new Promise(function (resolve, reject) {
            call.resolve = resolve;
            call.reject = reject;
        });
        return call;
    }

    function transmit(call) {
        if (!socket || socket.readyState !== WebSocket.OPEN) {
            fail(call, 'offline', 'not connected to the station');
            return;
        }
        call.attempts += 1;
        pending.set(call.id, call);
        socket.send(JSON.stringify({
            action: call.action,
            request_id: call.id,
            payload: call.payload
        }));
        call.timer = window.setTimeout(function () { onTimeout(call); }, ACTION_TIMEOUT_MS);
    }

    function onTimeout(call) {
        if (!pending.has(call.id)) {
            return;                       // answered in the meantime
        }
        if (call.attempts >= MAX_ATTEMPTS) {
            pending.delete(call.id);
            fail(call, 'timeout', 'the station did not answer');
            return;
        }
        /* §7.2, and the half of P7 that lives in the browser: retry with the
         * SAME request_id.  The station keeps the last REQUEST_CACHE_SIZE ids
         * with the reply each produced, so a duplicate is answered from the
         * cache and the command is NOT executed a second time.  Without this
         * retry the server's cache is code that nobody ever exercises, and
         * at-most-once stays a table in a test file. */
        transmit(call);
    }

    function send(action, payload) {
        var call = makeCall(action, payload);
        if (!joined) {
            /* §3: nothing but join may travel before the join is acked, so
             * the action waits rather than being refused — the page can be
             * clicked while the socket is still coming up. */
            queue.push(call);
        } else {
            transmit(call);
        }
        return call.promise;
    }

    /* ── receiving ─────────────────────────────────────────────────────── */

    function onMessage(event) {
        var frame;
        try {
            frame = JSON.parse(event.data);
        } catch (e) {
            console.error('[ws] unparsable frame from the station', event.data);
            return;
        }
        switch (frame.type) {
            case 'ack':
            case 'error':
                /* §2: correlated by request_id, echoed on these two only. */
                settle(frame);
                break;
            case 'state':
                /* §5.1, request_id null: a complete snapshot, always. */
                if (handlers.onState) { handlers.onState(frame.payload); }
                break;
            case 'notification':
                if (handlers.onNotification) { handlers.onNotification(frame.payload); }
                break;
            default:
                console.warn('[ws] unknown frame type', frame.type);
        }
    }

    function settle(frame) {
        var call = pending.get(frame.request_id);
        if (!call) {
            return;    // a reply to something already given up on
        }
        window.clearTimeout(call.timer);
        pending.delete(call.id);

        if (frame.type === 'ack') {
            if (call.action === 'join') { onJoined(); }
            call.resolve(frame.payload || {});
            return;
        }
        var payload = frame.payload || {};
        call.reject({
            code: payload.code || 'ERROR',
            message: payload.message || 'the station refused the request'
        });
    }

    function onJoined() {
        joined = true;
        /* The backoff resets on a successful JOIN, not on a TCP open.  A
         * station that accepts the socket and then closes it 4401 has not
         * given us a working connection, and resetting on open would retry
         * that at full speed forever. */
        backoff = BACKOFF_MIN_MS;
        status('online');

        var waiting = queue.splice(0, queue.length);
        waiting.forEach(transmit);
    }

    /* ── closing ───────────────────────────────────────────────────────── */

    function onClose(event) {
        joined = false;
        socket = null;

        /* The at-most-once cache is per CONNECTION (§2: "The station keeps,
         * per connection, the last REQUEST_CACHE_SIZE identifiers").  Every
         * id in flight died with the socket, so none of them may be replayed
         * on the next one: the new connection starts with an empty cache and
         * would execute the command a second time.  They are failed here,
         * visibly, and the user decides whether to ask again — which is also
         * safe, because §7.1 makes the next `state` the truth either way. */
        failAll('disconnected', 'the connection dropped before the station answered');

        if (FATAL[event.code]) {
            /* No reconnection.  The token lives in the page (jwt.md §2), so
             * sending it again would send the identical token; and a loop on
             * 4400 would bury a bug of ours under retries. */
            status('refused', event.code);
            return;
        }

        /* §7.5: 1001 (station shutting down), 1006 (network), anything else —
         * exponential backoff from 500 ms, capped at 10 s, with a fresh join. */
        status('reconnecting', event.code);
        var wait = backoff;
        backoff = Math.min(backoff * 2, BACKOFF_MAX_MS);
        window.setTimeout(connect, wait);
    }

    function fail(call, code, message) {
        window.clearTimeout(call.timer);
        call.reject({ code: code, message: message });
    }

    function failAll(code, message) {
        var inFlight = Array.from(pending.values());
        pending.clear();
        inFlight.forEach(function (call) { fail(call, code, message); });

        var waiting = queue.splice(0, queue.length);
        waiting.forEach(function (call) { fail(call, code, message); });
    }

    /* ── the channel ───────────────────────────────────────────────────── */

    return {
        connect: connect,
        send: send,
        set onState(fn)          { handlers.onState = fn; },
        set onNotification(fn)   { handlers.onNotification = fn; },
        set onStatusChange(fn)   { handlers.onStatusChange = fn; }
    };
}
