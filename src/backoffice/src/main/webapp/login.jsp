<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%-- User-supplied values always go through <c:out>, which escapes: plain ${...} does not. --%>
<t:page title="Sign in">
    <div class="card narrow">
        <h1>Sign in</h1>

        <c:if test="${not empty error}">
            <p class="error"><c:out value="${error}"/></p>
        </c:if>

        <form method="post" action="${pageContext.request.contextPath}/login">
            <c:if test="${not empty param.next}">
                <input type="hidden" name="next" value="<c:out value='${param.next}'/>">
            </c:if>
            <label>Username
                <input type="text" name="username" value="<c:out value='${username}'/>"
                       required autofocus>
            </label>
            <label>Password
                <input type="password" name="password" required>
            </label>
            <button type="submit">Sign in</button>
        </form>

        <p class="muted">No account yet?
            <a href="${pageContext.request.contextPath}/register.jsp">Create one</a>
        </p>
    </div>
</t:page>
