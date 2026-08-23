<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<t:page title="Station unavailable" active="stations">
    <div class="card narrow">
        <h1>Station unavailable</h1>
        <p>Station ${stationId} is not reporting to the coordinator at the moment.</p>
        <p class="muted">Either its node is down, or it has not announced itself yet. Charging
            sessions already running on it are unaffected — only new reservations are.</p>
        <a class="btn" href="${pageContext.request.contextPath}/stations">Back to the list</a>
    </div>
</t:page>
