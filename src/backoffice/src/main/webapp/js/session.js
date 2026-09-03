/* VoltShare — the driver channel, session view.  Owned by A.
 *
 * Takes a `session` payload (ws-driver.md §5.2) and draws the charge the
 * driver is watching: power, energy, state of charge, estimated time, how
 * long it has been running, and what phase it is in.  Everything about
 * sockets, request ids and retries is in ws.js, which this page shares with
 * station.js unchanged — the second consumer that file was split out for.
 *
 * ── The rule this file exists to obey (ws-driver.md §7.1) ────────────────
 * NO LOCAL COUNTER.  The energy does not creep up between frames, the state
 * of charge does not interpolate, the estimate is not averaged with the one
 * before it.  Every number on this page changes when a frame arrives and at
 * no other moment.  A page that advanced its own counters would have a model
 * of the station, and a model of the station can be wrong — which is the
 * whole of what §7.1 forbids and what P6 exists to prevent.  With a frame
 * every five seconds the page is alive enough.
 *
 * The one thing that moves on its own is the elapsed time, and it is not an
 * exception to the rule: it is a clock reading, not a fact about the
 * station.  It is measured from `started_at`, which the station sent, and it
 * is recomputed rather than incremented, so a tab that was suspended for a
 * minute comes back with the right number instead of a minute behind.
 *
 * ── And the estimate is deliberately raw ─────────────────────────────────
 * §5.2: the estimate "is advisory and may jump when another car arrives and
 * the allocation is recomputed — that jump is the visible proof of P5 and
 * should not be smoothed away".  So there is no easing here and no moving
 * average: when a second car plugs in on the same site, this number jumps,
 * and that jump is the most honest thing on the page.
 *
 * Server-supplied strings go in through textContent and never innerHTML.
 */

'use strict';

(function () {

    var TICK_MS = 1000;        // the elapsed-time repaint

    var panel = document.getElementById('session');
    var pill  = document.getElementById('conn-status');

    /* The last payload the station sent, kept for one reason only: the
     * elapsed clock has to repaint once a second without inventing anything,
     * so it needs `started_at` and needs to know whether the session is
     * still running.  It is never patched — it is replaced whole by the next
     * frame, exactly like station.js replaces its grid. */
    var current = null;

    /* When the final frame arrived.  §5.2's `closed` carries no `ended_at`,
     * so the duration of a finished session is measured to the instant the
     * news reached the page — within one tick, the same thing. */
    var stoppedAt = null;

    /* From the JSP, jwt.md §2 — through the data attributes of
     * `vs-live-config', not through three globals.  See ws.js. */
    var channel = createDriverChannel(driverChannelConfig());

    /* ── status pill ───────────────────────────────────────────────────── */

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
        if (pill) {
            pill.textContent = statusText(s);
            pill.classList.toggle('warn', s.state !== 'online');
        }
        /* A socket that has dropped makes this card stale, and -- unlike the
         * station grid -- it may never be corrected.  §5.2 sends nothing at
         * all to a driver with no session, so if the charge ended while the
         * page was away NO frame will ever arrive to say so: the station's
         * `last_session` is empty on the new socket by construction, and its
         * final `closed` went to a socket that no longer exists.  Keeping the
         * card would leave a live "Charging, 130 kW" over a session that has
         * been over for minutes, which is precisely the drift §7.1 exists to
         * prevent.  The honest answer is "I do not know", which is what the
         * placeholder and the pill say together; if the charge did survive,
         * the next frame redraws the card within a tick of the rejoin.
         *
         * station.js can afford to keep its grid because §3 pushes a `state`
         * on every join, so its staleness lasts exactly as long as the
         * reconnection.  There is no such guarantee here. */
        if (s.state !== 'online' && current) {
            current = null;
            stoppedAt = null;
            render();
        }
    };

    /* ── the frame ─────────────────────────────────────────────────────── */

    /* §5.2 sends nothing at all to a driver with no session running, which
     * is why this page starts on its placeholder and stays there: silence
     * means "you are not charging", and it is a different thing from a
     * session standing still.  The first frame replaces the placeholder. */
    channel.onSession = function (payload) {
        current = payload || null;
        stoppedAt = (current && isOver(current)) ? Date.now() : null;
        render();
        tick();     // put the elapsed time up immediately, not a second late
    };

    /* ── phases, in words a driver can act on ──────────────────────────── */

    /* `suspended` is the one that has to be explained rather than named.  It
     * is the only place in the whole application where the power split
     * becomes visible to the person it is happening to, and "suspended" on
     * its own reads like a fault.  It is not one: the session is alive, the
     * cable is live, and the car will start drawing again by itself. */
    var PHASE = {
        charging:  { label: 'Charging',      note: null },
        suspended: { label: 'Paused',
                     note: 'The station is sharing its power with the other cars ' +
                           'on this site, and there is not enough left for a useful ' +
                           'share right now. Nothing is wrong: your session is still ' +
                           'open and charging resumes on its own as soon as a share ' +
                           'frees up.' },
        complete:  { label: 'Charge complete',
                     note: 'The battery is full. The cable can be unplugged.' },
        overstay:  { label: 'Overstaying',
                     note: 'Charging has finished and the connector is still occupied.' },
        closed:    { label: 'Session ended',
                     note: 'This is the final reading the station sent for this ' +
                           'session. The figures below are the totals.' }
    };

    function phaseOf(payload) {
        return PHASE[payload.phase] || { label: String(payload.phase), note: null };
    }

    function isOver(payload) {
        return payload.phase === 'closed';
    }

    /* ── rendering ─────────────────────────────────────────────────────── */

    function render() {
        if (!panel) { return; }
        clear(panel);
        if (!current) {
            panel.appendChild(el('p', 'muted',
                'No charging session on this station. Plug in at a connector, ' +
                'or reserve one from the station page.'));
            return;
        }

        var phase = phaseOf(current);
        var card  = el('div', 'session-card session-' + current.phase);

        var head = el('div', 'session-head');
        head.appendChild(el('span', 'session-conn', 'Connector #' + current.connector_id));
        head.appendChild(el('span', 'badge session-phase', phase.label));
        card.appendChild(head);

        card.appendChild(soc(current.soc_pct));

        var figures = el('div', 'figures');
        /* Power is what is flowing now; when the session is over there is
         * nothing flowing, and printing "0.0 kW" next to a finished charge
         * would read as a fault rather than as an ending. */
        figures.appendChild(figure('Power',
                                   isOver(current) ? '—' : fixed1(current.power_kw) + ' kW'));
        figures.appendChild(figure('Energy', fixed3(current.energy_kwh) + ' kWh'));
        figures.appendChild(figure('Time', '', 'elapsed'));
        figures.appendChild(figure('Estimated time left', etaText(current)));
        card.appendChild(figures);

        if (phase.note) {
            card.appendChild(el('p', 'session-note', phase.note));
        }
        panel.appendChild(card);
    }

    /* The bar is a second channel for the same number, never the only one:
     * the percentage is written out beside it. */
    function soc(pct) {
        var box = el('div', 'soc');
        var n   = (typeof pct === 'number') ? Math.max(0, Math.min(100, pct)) : 0;

        var bar  = el('div', 'soc-bar');
        var fill = el('div', 'soc-fill');
        fill.style.width = n + '%';
        bar.appendChild(fill);

        box.appendChild(bar);
        box.appendChild(el('span', 'soc-pct', n + ' %'));
        return box;
    }

    function figure(label, value, id) {
        var box = el('div', 'figure');
        box.appendChild(el('span', 'figure-label', label));
        var v = el('span', 'figure-value mono', value);
        if (id) { v.id = id; }
        box.appendChild(v);
        return box;
    }

    /* §5.2 sends `null` when there is no power flowing: an estimate that does
     * not exist, not an estimate of zero.  It is shown as absent for the same
     * reason the station computes it that way. */
    function etaText(payload) {
        if (isOver(payload) || payload.phase === 'complete') { return '—'; }
        if (typeof payload.eta_seconds !== 'number')         { return 'unavailable'; }
        return remaining(payload.eta_seconds);
    }

    /* ── the elapsed clock ─────────────────────────────────────────────── */

    /* Recomputed from `started_at` on every repaint rather than incremented,
     * so the value cannot drift and a tab that was asleep is right again the
     * moment it wakes.  A `closed` session stops here: it has an end, and the
     * clock must not keep running past it. */
    function tick() {
        var span = document.getElementById('elapsed');
        if (!span || !current) { return; }
        if (typeof current.started_at !== 'number') {
            span.textContent = '—';
            return;
        }
        /* A finished session has an end, and the clock must not run past it. */
        var end = stoppedAt || Date.now();
        span.textContent = hhmm(Math.max(0, (end - current.started_at) / 1000));
    }

    /* How long it has been running: a stopwatch, so seconds are wanted. */
    function hhmm(totalSeconds) {
        var total = Math.floor(totalSeconds);
        var h = Math.floor(total / 3600);
        var m = Math.floor((total % 3600) / 60);
        var s = total % 60;
        if (h > 0) {
            return h + 'h ' + pad(m) + 'm';
        }
        return m + ':' + pad(s);
    }

    /* How long is left: an estimate, so it is written in words rather than as
     * "18:12", which a reader takes for a time of day.  Rounded to the minute
     * because the second is noise on a number that is advisory and jumps. */
    function remaining(totalSeconds) {
        var total = Math.max(0, Math.round(totalSeconds / 60));
        if (total < 1)  { return 'under a minute'; }
        if (total < 60) { return total + ' min'; }
        return Math.floor(total / 60) + ' h ' + pad(total % 60) + ' min';
    }

    function pad(n) { return (n < 10 ? '0' : '') + n; }

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

    function fixed1(n) {
        return (typeof n === 'number') ? n.toFixed(1) : '0.0';
    }

    function fixed3(n) {
        return (typeof n === 'number') ? n.toFixed(3) : '0.000';
    }

    /* ── go ────────────────────────────────────────────────────────────── */

    render();
    window.setInterval(tick, TICK_MS);
    channel.connect();
})();
