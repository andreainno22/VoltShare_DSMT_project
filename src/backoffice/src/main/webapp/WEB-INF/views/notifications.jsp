<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  Notices the driver did not see live.

  Everything here was already pushed over the station WebSocket when it happened; this page
  exists for the driver who had the browser closed. Opening it marks them read, so the list is
  a log rather than an inbox to manage.
--%>
<t:page title="Notifications" active="notifications">

    <h1>Notifications</h1>

    <c:choose>
        <c:when test="${empty notifications}">
            <div class="card">
                <p>Nothing to report.</p>
                <p class="muted">Reservations that expired, charges that finished and suspensions
                    show up here. While the station page is open you see them as they happen.</p>
            </div>
        </c:when>
        <c:otherwise>
            <ul class="feed">
                <c:forEach items="${notifications}" var="n">
                    <li class="${n.read ? '' : 'unread'} ${n.important ? 'warn' : ''}">
                        <div class="feed-head">
                            <%-- kind comes from a fixed vocabulary (schema.sql), but it is
                                 written by a station, so it goes through c:out like any other
                                 value that did not originate here. --%>
                            <span class="badge"><c:out value="${n.kind}"/></span>
                            <span class="muted mono">${n.createdText}</span>
                        </div>
                        <p><c:out value="${n.text}"/></p>
                    </li>
                </c:forEach>
            </ul>
        </c:otherwise>
    </c:choose>
</t:page>
