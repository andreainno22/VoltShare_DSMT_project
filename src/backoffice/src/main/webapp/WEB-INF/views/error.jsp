<%@ page contentType="text/html;charset=UTF-8" isErrorPage="true" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<t:page title="Something went wrong">
    <div class="card narrow">
        <h1>Something went wrong</h1>
        <p class="muted">Status ${pageContext.errorData.statusCode}
            on ${pageContext.errorData.requestURI}</p>
        <a class="btn" href="${pageContext.request.contextPath}/stations">Back to the stations</a>
    </div>
</t:page>
