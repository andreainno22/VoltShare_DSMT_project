<%@ tag pageEncoding="UTF-8" body-content="scriptless" %>
<%@ attribute name="title" required="true" %>
<%@ attribute name="active" required="false" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>

<%--
  Shared page frame: header, navigation, footer.
  Owned by B. Pages written by A use it too, so the whole application looks like one thing.
--%>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${title} · VoltShare</title>
    <link rel="stylesheet" href="${pageContext.request.contextPath}/css/app.css">
</head>
<body>
<header class="topbar">
    <a class="brand" href="${pageContext.request.contextPath}/stations">VoltShare</a>
    <c:if test="${not empty sessionScope.user}">
        <nav>
            <a class="${active eq 'stations' ? 'on' : ''}"
               href="${pageContext.request.contextPath}/stations">Stations</a>
            <a class="${active eq 'history' ? 'on' : ''}"
               href="${pageContext.request.contextPath}/history">History</a>
            <a class="${active eq 'notifications' ? 'on' : ''}"
               href="${pageContext.request.contextPath}/notifications">Notifications</a>
            <a class="${active eq 'profile' ? 'on' : ''}"
               href="${pageContext.request.contextPath}/profile">Profile</a>
        </nav>
        <div class="who">
            <span>${sessionScope.user.username}</span>
            <a href="${pageContext.request.contextPath}/logout">Log out</a>
        </div>
    </c:if>
</header>

<main>
    <jsp:doBody/>
</main>

<footer>
    VoltShare · Distributed Systems and Middleware Technologies · University of Pisa
</footer>
</body>
</html>
