<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  ============================================================================
  OWNED BY A.  Same skeleton as station.jsp, and the same three values.

  This page needs a servlet of B's that does for /session what StationPageServlet
  does for /station — nothing more than the contract of contracts/jwt.md §2, on
  the `vs-live-config' element below:

      data-token        the JWT the station verifies on `join`
      data-ws-url       the driver endpoint, as the coordinator advertised it
      data-station-id   the station id

  It is the same driver socket station.jsp opens; only what the page listens to
  differs (§5.2 `session` instead of §5.1 `state`).  Until that servlet exists
  this file is not reachable, and it is committed ready rather than kept back:
  the request is in contracts/nota-per-B-m2a.md §4, and when it lands there is
  nothing left to write on this side.

  Everything below that element is A's.
  ============================================================================
--%>
<t:page title="Your session" active="stations">

    <%-- Same three values, same reason, same shape as station.jsp: see the note
         there. `station.wsUrl' comes from a station node's environment by way of
         the coordinator, so it is not ours to trust as JavaScript source. --%>
    <div id="vs-live-config" hidden
         data-token="<c:out value='${sessionScope.jwt}'/>"
         data-ws-url="<c:out value='${station.wsUrl}'/>"
         data-station-id="<c:out value='${station.id}'/>"></div>

    <%--
      The styles of this view live here rather than in css/app.css, which
      belongs to B and is shared by every page; only variables already declared
      on :root are used, so this cannot drift from the rest of the palette.
      .badge/.muted/.mono/.head-row come from app.css.
    --%>
    <style>
        .session-card {
            background: var(--surface);
            border: 1px solid var(--line);
            border-left: 4px solid var(--line);
            border-radius: 10px;
            padding: 18px 20px;
            display: flex;
            flex-direction: column;
            gap: 18px;
            max-width: 640px;
        }
        .session-head {
            display: flex;
            align-items: baseline;
            justify-content: space-between;
            gap: 12px;
        }
        .session-conn { font-weight: 700; font-size: 18px; }

        /* The phase is readable without colour — the badge spells it out.
           The stripe is a second, faster channel for the same fact. */
        .session-charging  { border-left-color: var(--good); }
        .session-suspended { border-left-color: var(--warn); }
        .session-complete  { border-left-color: var(--good); }
        .session-overstay  { border-left-color: var(--copper); }
        .session-closed    { border-left-color: var(--ink-3); }

        .soc { display: flex; align-items: center; gap: 12px; }
        .soc-bar {
            flex: 1;
            height: 14px;
            background: #eef2f5;
            border: 1px solid var(--line);
            border-radius: 20px;
            overflow: hidden;
        }
        /* No transition on the width, deliberately. The bar is rebuilt from
           scratch on every frame, exactly like the rest of the card, so there
           is nothing for a transition to animate -- and a bar that crept
           between frames would be the client inventing values it was not
           sent, which is what §7.1 forbids. */
        .soc-fill { height: 100%; background: var(--good); }
        .soc-pct { font-weight: 700; min-width: 56px; text-align: right; }

        .figures {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
            gap: 14px;
        }
        .figure { display: flex; flex-direction: column; gap: 4px; }
        .figure-label {
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: .07em;
            color: var(--ink-3);
        }
        .figure-value { font-size: 20px; font-weight: 600; }

        /* Mirrors .badge.warn of app.css, which is B's file: the paused phase
           is not an error and must not look like one. */
        .session-note {
            background: #fff5e0;
            border-left: 3px solid #e2c68a;
            color: var(--warn);
            padding: 10px 14px;
            border-radius: 0 6px 6px 0;
            font-size: 14px;
            margin: 0;
        }
    </style>

    <div class="head-row">
        <h1>Your session</h1>
        <span class="badge" id="conn-status">connecting…</span>
    </div>

    <p class="muted">
        <c:out value="${station.name}"/> ·
        <a href="${pageContext.request.contextPath}/station?id=${station.id}">back to the station</a>
    </p>

    <%-- §5.2 sends nothing at all to a driver with no session running, so
         this placeholder is also the answer to "you are not charging". --%>
    <div id="session">
        <p class="muted">Waiting for the station…</p>
    </div>

    <script src="${pageContext.request.contextPath}/js/ws.js"></script>
    <script src="${pageContext.request.contextPath}/js/session.js"></script>
</t:page>
