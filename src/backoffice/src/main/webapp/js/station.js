/* VoltShare — the driver channel, rendering half.  Owned by A.
 *
 * Takes a `state` payload and draws it.  Everything about sockets, request
 * ids and retries is in ws.js.
 *
 * ── The rule this file exists to obey (ws-driver.md §7.1) ────────────────
 * THE CLIENT KEEPS NO STATE.  Every `state` frame redraws the whole grid
 * from scratch.  An `ack` of `reserve` colours nothing: the connector turns
 * `held` when the `state` that follows says so.  There is no optimistic
 * update and no local copy patched piece by piece.
 *
 * It looks wasteful — why not colour the box I know I just reserved?  Because
 * a client that applies deltas has a model of its own, and a model of its own
 * can drift from the server after a single missed frame.  That drift is the
 * failure P6 exists to prevent.  The payload is four connectors; sending all
 * of it costs nothing and removes an entire class of bug.
 *
 * The only two things kept between frames are deliberately NOT a model of the
 * station: the deadline written on each box (so the countdown can tick once a
 * second without asking the server), re-anchored on every frame; and the last
 * error the server sent for a connector, which is a reply addressed to this
 * user, not a fact about the station.
 *
 * Server-supplied strings (`name`, `message`) go in through textContent and
 * never innerHTML — see §8 of the design note.
 */

'use strict';

(function () {

    var NOTICE_MS = 8000;      // how long a server error stays next to its box
    var TICK_MS   = 1000;      // countdown repaint

    var grid    = document.getElementById('connectors');
    var pill    = document.getElementById('conn-status');
    var notices = new Map();   // connector_id -> {message, until}

    /* From the JSP, jwt.md §2 — through the data attributes of
     * `vs-live-config', not through three globals.  See ws.js. */
    var channel = createDriverChannel(driverChannelConfig());

    /* ── status pill ───────────────────────────────────────────────────── */

    /* Reads the close code rather than inventing a diagnosis: 4401/4408 are
     * about the token in this page, so the only cure is a reload; 4400 means
     * the station refused the page itself, which is a bug on our side and is
     * said plainly instead of being retried away. */
    function statusText(s) {
        if (s.state === 'online')       { return 'live'; }
        if (s.state === 'connecting')   { return 'connecting…'; }
        if (s.state === 'reconnecting') { return 'reconnecting…'; }
        if (s.reason === 'token_expired')  { return 'session expired — reload the page'; }
        if (s.reason === 'token_rejected') { return 'not authorised — reload the page'; }
        if (s.reason === 'bad_request')    { return 'the station refused this page'; }
        return 'disconnected';
    }

    channel.onStatusChange = function (s) {
        if (!pill) { return; }
        pill.textContent = statusText(s);
        pill.classList.toggle('warn', s.state !== 'online');
    };

    /* ── notifications (§5.3) ──────────────────────────────────────────── */

    channel.onNotification = function (payload) {
        if (payload && typeof payload.connector_id === 'number') {
            note(payload.connector_id, payload.text || payload.kind || '');
        }
    };

    /* ── the snapshot ──────────────────────────────────────────────────── */

    channel.onState = function (state) {
        render(state);
    };

    function render(state) {
        renderHeader(state);
        renderCoordinatorWarning(state);
        renderConnectors(state.connectors || []);
    }

    /* The JSP paints these from the database once, so the page is not blank
     * before the socket answers; from the first frame on they come from the
     * station itself, which is the half that actually knows. */
    function renderHeader(state) {
        var title = document.querySelector('.head-row h1');
        if (title && state.name) { title.textContent = state.name; }

        var line = document.getElementById('station-line');
        if (!line) { return; }
        clear(line);
        line.appendChild(document.createTextNode(
            'Site power ' + state.site_power_kw + ' kW · ' +
            'allocated ' + round1(state.allocated_kw) + ' kW · € ' +
            (state.tariff_cents_kwh / 100).toFixed(2) + '/kWh'
        ));
    }

    /* §5.1: "a hint for the interface, not an error: reservations are refused
     * while it is false, but charging carries on and the page should say so."
     * Both halves are said, because a page that only said "unavailable" would
     * frighten a driver whose car is charging perfectly well. */
    function renderCoordinatorWarning(state) {
        var box = document.getElementById('coord-warning');
        if (!box) { return; }
        if (state.coordinator_reachable === false) {
            box.textContent = 'The coordinator is unreachable: new reservations are ' +
                              'unavailable right now. Charging sessions already running ' +
                              'are unaffected and continue normally.';
            box.hidden = false;
        } else {
            box.hidden = true;
            box.textContent = '';
        }
    }

    function renderConnectors(connectors) {
        clear(grid);
        if (connectors.length === 0) {
            grid.appendChild(el('p', 'muted', 'This station reports no connectors.'));
            return;
        }
        connectors.forEach(function (c) { grid.appendChild(connectorBox(c)); });
        tick();   // paint the countdowns immediately, not a second late
    }

    function connectorBox(c) {
        var box = el('div', 'conn conn-' + c.state);

        var head = el('div', 'conn-head');
        head.appendChild(el('span', 'conn-id', '#' + c.connector_id));
        head.appendChild(el('span', 'muted', c.rated_kw + ' kW'));
        box.appendChild(head);

        box.appendChild(el('span', 'badge conn-state', label(c.state)));

        /* §4.1: the countdown is read from expires_at, never from a
         * Date.now() + lease worked out here — the browser's clock is not the
         * station's, and the contract says the client never computes the
         * deadline itself.  The value is parked on the node so the once-a-
         * second repaint needs nothing but the DOM. */
        if (c.held_by_me && typeof c.expires_at === 'number') {
            box.dataset.expiresAt = String(c.expires_at);
            box.appendChild(el('span', 'countdown mono', ''));
        }

        if (c.state === 'charging') {
            box.appendChild(el('span', 'mono conn-power', round1(c.power_kw) + ' kW'));
        }

        var action = actionFor(c);
        if (action) {
            box.appendChild(button(action.label, action.act, c.connector_id));
        }

        var notice = notices.get(c.connector_id);
        if (notice && notice.until > Date.now()) {
            box.appendChild(el('p', 'error conn-error', notice.message));
        }
        return box;
    }

    /* What cannot be done is NOT DRAWN — not drawn greyed out.  A disabled
     * button still says "this is a thing you could have"; an absent one says
     * the truth, which is that this connector is somebody else's business. */
    function actionFor(c) {
        if (c.state === 'free')                      { return { label: 'Reserve', act: 'reserve' }; }
        if (c.state === 'held' && c.held_by_me)      { return { label: 'Cancel',  act: 'cancel_reservation' }; }
        if (c.state === 'charging' && c.mine)        { return { label: 'Stop',    act: 'stop_session' }; }
        return null;
    }

    function button(text, action, connectorId) {
        var b = el('button', 'btn', text);
        b.addEventListener('click', function () {
            b.disabled = true;
            notices.delete(connectorId);
            channel.send(action, { connector_id: connectorId })
                .then(function () {
                    /* Deliberately empty.  The ack confirms the station
                     * accepted the command; what the connector now LOOKS like
                     * is the business of the `state` that follows (§7.1). */
                })
                .catch(function (err) {
                    b.disabled = false;
                    note(connectorId, err.message);
                });
        });
        return b;
    }

    /* The server's own sentence, shown verbatim.  It is the half of an error
     * the driver actually reads: "your vehicle already holds a reservation
     * elsewhere" sends him to cancel it, while "held by another driver" would
     * send him down the row trying every other connector. */
    function note(connectorId, message) {
        if (!message) { return; }
        notices.set(connectorId, { message: message, until: Date.now() + NOTICE_MS });
        var box = boxOf(connectorId);
        if (box && !box.querySelector('.conn-error')) {
            box.appendChild(el('p', 'error conn-error', message));
        }
    }

    function boxOf(connectorId) {
        var boxes = grid.querySelectorAll('.conn');
        for (var i = 0; i < boxes.length; i++) {
            var id = boxes[i].querySelector('.conn-id');
            if (id && id.textContent === '#' + connectorId) { return boxes[i]; }
        }
        return null;
    }

    /* ── the countdown ─────────────────────────────────────────────────── */

    function tick() {
        var boxes = grid.querySelectorAll('[data-expires-at]');
        for (var i = 0; i < boxes.length; i++) {
            var span = boxes[i].querySelector('.countdown');
            if (!span) { continue; }
            var left = Number(boxes[i].dataset.expiresAt) - Date.now();
            span.textContent = (left > 0)
                ? 'expires in ' + mmss(left)
                : 'expiring…';   /* the station frees it; we only stop counting */
        }
    }

    function mmss(ms) {
        var total = Math.floor(ms / 1000);
        var m = Math.floor(total / 60);
        var s = total % 60;
        return m + ':' + (s < 10 ? '0' : '') + s;
    }

    /* ── small DOM helpers — createElement only, never innerHTML ───────── */

    function el(tag, className, text) {
        var node = document.createElement(tag);
        if (className) { node.className = className; }
        if (text !== undefined && text !== null) { node.textContent = text; }
        return node;
    }

    function clear(node) {
        while (node.firstChild) { node.removeChild(node.firstChild); }
    }

    function label(state) {
        return (state === 'out_of_service') ? 'out of service' : state;
    }

    function round1(n) {
        return (typeof n === 'number') ? Math.round(n * 10) / 10 : 0;
    }

    /* ── go ────────────────────────────────────────────────────────────── */

    window.setInterval(tick, TICK_MS);
    channel.connect();
})();
