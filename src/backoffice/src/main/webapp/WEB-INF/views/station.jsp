<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  ============================================================================
  OWNED BY A.  This is the skeleton B guarantees, not the finished page.

  StationPageServlet (B) always provides exactly these three values, as fixed in
  contracts/jwt.md §2, on the `vs-live-config' element below. A may rely on them
  and on nothing else from the back office:

      data-token        the JWT the station verifies on `join`
      data-ws-url       the driver endpoint, as the coordinator advertised it
      data-station-id   the station id

  They are read once by driverChannelConfig() in js/ws.js.

  Everything below that element is A's to replace: connector grid, reserve
  buttons, lease countdown, live state from the WebSocket.
  ============================================================================
--%>
<t:page title="${station.name}" active="stations">

    <%--
      The three values jwt.md §2 promises this page, handed over as data
      attributes rather than interpolated into a <script> block.

      The block they replace built JavaScript source out of EL:

          const WS_URL = '${station.wsUrl}';

      and `station.wsUrl` is not a page constant. It comes from a station node's
      WS_URL environment variable, travels through the `station_up' announcement,
      the coordinator and StationDirectory before arriving here — so a station
      that announced itself as

          ws://h/ws/driver';alert(document.cookie);//

      would have closed the string and run script on every driver's page. The
      same file already escaped `station.name' with <c:out> a few lines below;
      it was only inside the script that EL went out raw.

      Severity was low — exploiting it means already controlling a cluster
      node's configuration — but the fix removes the *class* rather than the
      instance: an attribute rendered through <c:out> cannot become code,
      whatever it contains, because it never enters a JavaScript parser.

      `hidden`, not `display:none` in CSS: the element carries no presentation
      and nothing should have to remember to hide it.
    --%>
    <div id="vs-live-config" hidden
         data-token="<c:out value='${sessionScope.jwt}'/>"
         data-ws-url="<c:out value='${station.wsUrl}'/>"
         data-station-id="<c:out value='${station.id}'/>"></div>

    <%--
      The connector boxes are a feature of A's page, so their styles live here
      rather than in css/app.css, which belongs to B and is shared by every
      view. Only the variables already declared on :root are used, so the page
      cannot drift from the rest of the application's palette. The grid itself
      (.connectors) and .badge/.btn/.muted/.mono/.error come from app.css.
    --%>
    <style>
        .conn {
            background: var(--surface);
            border: 1px solid var(--line);
            border-left: 4px solid var(--line);
            border-radius: 10px;
            padding: 14px 16px;
            display: flex;
            flex-direction: column;
            align-items: flex-start;
            gap: 9px;
        }
        .conn-head {
            display: flex;
            width: 100%;
            align-items: baseline;
            justify-content: space-between;
            gap: 10px;
        }
        .conn-id { font-weight: 700; font-size: 18px; }
        .conn-power { color: var(--good); font-weight: 600; font-size: 14px; }
        .countdown { color: var(--warn); font-size: 13px; }
        .conn-error { margin: 2px 0 0; width: 100%; }

        /* The state is also readable without colour — the badge spells it out.
           The stripe is a second, faster channel for the same fact. */
        .conn-free           { border-left-color: var(--good); }
        .conn-held           { border-left-color: var(--copper); }
        .conn-charging       { border-left-color: var(--good); }
        .conn-closing        { border-left-color: var(--ink-3); }
        .conn-suspended      { border-left-color: var(--warn); }
        .conn-out_of_service { border-left-color: var(--ink-3); background: #eef1f4; }

        /* Mirrors .badge.warn of app.css, which is B's file and not to be
           edited for a feature of A's; ws-driver.md §5.1 calls this a hint for
           the interface, not an error, so it must not look like one. */
        #coord-warning {
            background: #fff5e0;
            border-left: 3px solid #e2c68a;
            color: var(--warn);
            padding: 10px 14px;
            border-radius: 0 6px 6px 0;
            font-size: 14px;
            margin: 0 0 18px;
        }
    </style>

    <div class="head-row">
        <h1><c:out value="${station.name}"/></h1>
        <span class="badge" id="conn-status">connecting…</span>
    </div>

    <%-- Painted once from the database so the page is not blank before the
         socket answers; from the first `state` frame on, #station-line is
         rewritten by station.js from what the station itself reports. --%>
    <p class="muted">
        <span id="station-line">Site power ${station.sitePowerKw} kW · € ${station.tariffEuroKwh}/kWh</span>
        · <span class="mono">${station.node}</span>
    </p>

    <p id="coord-warning" hidden></p>

    <div id="connectors" class="connectors">
        <p class="muted">Waiting for the station to send its state…</p>
    </div>

    <script src="${pageContext.request.contextPath}/js/ws.js"></script>
    <script src="${pageContext.request.contextPath}/js/station.js"></script>
</t:page>
