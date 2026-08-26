<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  Closed charging sessions, most recent first.

  No refresh meta here, unlike the station list: these rows are finished business and none of
  them will change again. The single exception is the cost of a session that has just ended,
  which the billing sweep fills in within a minute — shown as "pending" rather than as a zero.
--%>
<t:page title="History" active="history">

    <div class="head-row">
        <h1>Charging history</h1>
        <c:if test="${not empty sessions}">
            <span class="badge">${totalKwh} kWh · € ${totalEuro}</span>
        </c:if>
    </div>

    <c:choose>
        <c:when test="${empty sessions}">
            <div class="card">
                <p>No charging session yet.</p>
                <p class="muted">A session appears here once it has ended: the station writes it
                    when the cable comes out, and the cost is added shortly after.</p>
            </div>
        </c:when>
        <c:otherwise>
            <table class="grid">
                <thead>
                <tr>
                    <th>Started</th>
                    <th>Station</th>
                    <th>Conn.</th>
                    <th>Duration</th>
                    <th>Energy</th>
                    <th>Overstay</th>
                    <th>Cost</th>
                </tr>
                </thead>
                <tbody>
                <c:forEach items="${sessions}" var="s">
                    <tr>
                        <td>
                            ${s.startedText}
                            <span class="muted mono">→ ${s.endedText}</span>
                        </td>
                        <td><c:out value="${s.stationName}"/></td>
                        <td class="num">${s.connectorId}</td>
                        <td class="num">${s.durationMinutes} min</td>
                        <td class="num">${s.energyText} kWh</td>
                        <%--
                          The grace period is already subtracted by the station, so anything
                          shown here was actually charged for.
                        --%>
                        <td class="num ${s.overstayed ? 'none' : ''}">
                            <c:choose>
                                <c:when test="${s.overstayed}">${s.overstayMinutes} min</c:when>
                                <c:otherwise>&mdash;</c:otherwise>
                            </c:choose>
                        </td>
                        <td class="num">
                            <c:choose>
                                <c:when test="${s.billed}">€ ${s.costEuro}</c:when>
                                <c:otherwise><span class="muted">pending</span></c:otherwise>
                            </c:choose>
                        </td>
                    </tr>
                </c:forEach>
                </tbody>
            </table>

            <%--
              Both rates are per station, so no single figure is quoted here: it would be
              wrong for every session charged at a different site.
            --%>
            <p class="muted">
                Energy and overstay are both charged at the tariff of the station where the
                session took place, as it stood at the time of settlement. The overstay charge
                starts five minutes after the vehicle is full — unplugging inside those five
                minutes costs nothing, and the minutes shown above are the ones actually
                charged for.
            </p>
        </c:otherwise>
    </c:choose>
</t:page>
