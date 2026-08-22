<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<t:page title="Create account">
    <div class="card narrow">
        <h1>Create account</h1>
        <p class="muted">The vehicle is part of the account: its battery and maximum charging
            power are what the station uses to work out your share of the site's power.</p>

        <c:if test="${not empty error}">
            <p class="error"><c:out value="${error}"/></p>
        </c:if>

        <form method="post" action="${pageContext.request.contextPath}/register">
            <label>Username
                <input type="text" name="username" value="<c:out value='${username}'/>"
                       minlength="3" maxlength="50" required autofocus>
            </label>
            <label>Password
                <input type="password" name="password" minlength="6" required>
            </label>

            <fieldset>
                <legend>Your vehicle</legend>
                <label>Battery capacity (kWh)
                    <input type="number" name="batteryKwh" step="0.1" min="5" max="250"
                           value="<c:out value='${empty batteryKwh ? 58 : batteryKwh}'/>" required>
                </label>
                <label>Maximum charging power (kW)
                    <input type="number" name="maxKw" min="3" max="400"
                           value="<c:out value='${empty maxKw ? 150 : maxKw}'/>" required>
                </label>
            </fieldset>

            <button type="submit">Create account</button>
        </form>

        <p class="muted">Already registered?
            <a href="${pageContext.request.contextPath}/login.jsp">Sign in</a>
        </p>
    </div>
</t:page>
