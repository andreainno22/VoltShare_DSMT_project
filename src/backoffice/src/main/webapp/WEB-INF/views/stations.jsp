<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  The station list.

  Refreshed by the browser every 15 seconds rather than over a WebSocket: this is a list,
  not a live view. Real time belongs on the station page, where a second of delay is visible
  and matters. Stating the choice here because it is a deliberate one (see SCOPE §6).
--%>
<t:page title="Stations" active="stations">
    <meta http-equiv="refresh" content="15">

    <div class="head-row">
        <h1>Stations</h1>
        <c:if test="${stale or not clusterUp}">
            <span class="badge warn">Cluster unreachable — these figures may be out of date</span>
        </c:if>
    </div>

    <c:choose>
        <c:when test="${empty stations}">
            <div class="card">
                <p>No station is reporting right now.</p>
                <p class="muted">The coordinator pushes the list as stations announce themselves;
                    if this stays empty, the Erlang cluster is not reachable from the back office.</p>
            </div>
        </c:when>
        <c:otherwise>
            <table class="grid">
                <thead>
                <tr>
                    <th>Station</th>
                    <th>Free</th>
                    <th>Held</th>
                    <th>Charging</th>
                    <th>Out of service</th>
                    <th>Site power</th>
                    <th>Tariff</th>
                    <th></th>
                </tr>
                </thead>
                <tbody>
                <c:forEach items="${stations}" var="s">
                    <tr class="${s.busy ? 'busy' : ''}">
                        <td>
                            <strong><c:out value="${s.name}"/></strong>
                            <span class="muted mono">${s.node}</span>
                        </td>
                        <td class="num ${s.free gt 0 ? 'good' : 'none'}">${s.free}</td>
                        <td class="num">${s.held}</td>
                        <td class="num">${s.charging}</td>
                        <%--
                          Free + held + charging can add up to less than the total: a connector
                          that is offline or faulted counts in none of them (station_stats
                          convention). Showing the difference keeps the row honest — otherwise
                          a broken connector would simply vanish from the page.
                        --%>
                        <td class="num ${s.unavailable gt 0 ? 'none' : ''}">
                            <c:choose>
                                <c:when test="${s.unavailable gt 0}">${s.unavailable}</c:when>
                                <c:otherwise>&mdash;</c:otherwise>
                            </c:choose>
                        </td>
                        <td class="num">${s.sitePowerKw} kW</td>
                        <td class="num">€ ${s.tariffEuroKwh}/kWh</td>
                        <td>
                            <a class="btn" href="${pageContext.request.contextPath}/station?id=${s.id}">
                                Open
                            </a>
                        </td>
                    </tr>
                </c:forEach>
                </tbody>
            </table>
            <p class="muted">A station shows the total of its connectors; open it to reserve one.</p>
        </c:otherwise>
    </c:choose>
</t:page>
