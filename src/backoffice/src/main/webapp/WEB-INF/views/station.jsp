<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  ============================================================================
  OWNED BY A.  This is the skeleton B guarantees, not the finished page.

  StationPageServlet (B) always provides exactly these three values, as fixed in
  contracts/jwt.md §2. A may rely on them and on nothing else from the back office:

      TOKEN    the JWT the station verifies on `join`
      WS_URL   the driver endpoint, as the coordinator advertised it
      STATION  the station id

  Everything below the script block is A's to replace: connector grid, reserve
  buttons, lease countdown, live state from the WebSocket.
  ============================================================================
--%>
<t:page title="${station.name}" active="stations">

    <script>
        const TOKEN   = '${sessionScope.jwt}';
        const WS_URL  = '${station.wsUrl}';
        const STATION = ${station.id};
    </script>

    <div class="head-row">
        <h1><c:out value="${station.name}"/></h1>
        <span class="badge" id="conn-status">connecting…</span>
    </div>

    <p class="muted">
        Site power ${station.sitePowerKw} kW · € ${station.tariffEuroKwh}/kWh ·
        <span class="mono">${station.node}</span>
    </p>

    <div id="connectors" class="connectors">
        <p class="muted">Waiting for the station to send its state…</p>
    </div>

    <script src="${pageContext.request.contextPath}/js/ws.js"></script>
    <script src="${pageContext.request.contextPath}/js/station.js"></script>
</t:page>
