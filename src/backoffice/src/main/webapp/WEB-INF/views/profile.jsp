<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<%@ taglib prefix="t" tagdir="/WEB-INF/tags" %>

<%--
  Account, vehicle, and the state of the no-show penalty.

  The penalty block is the reason this page exists: a driver refused a reservation needs to be
  able to find out why, and when it ends, without asking anyone.
--%>
<t:page title="Profile" active="profile">

    <h1>Profile</h1>

    <div class="card">
        <h2><c:out value="${account.username}"/></h2>
        <p class="muted">
            Vehicle #${account.vehicleId} ·
            ${account.batteryKwh} kWh battery · up to ${account.maxKw} kW
        </p>
        <p class="muted">The vehicle is what a reservation is held for: one vehicle, one
            reservation anywhere in the network.</p>
    </div>

    <h2>Reservation privilege</h2>

    <c:choose>
        <c:when test="${account.suspended}">
            <div class="card warn">
                <p><strong>Reservations are suspended until ${account.suspendedUntil}.</strong></p>
                <p>You can still charge at any free connector — walking up to a free outlet needs
                    no reservation, and that has not been taken away.</p>
                <p class="muted">The suspension followed ${strikesAllowed} missed reservations
                    in a row. It lasts ${suspensionDays} day(s) and lifts by itself.</p>
            </div>
        </c:when>
        <c:otherwise>
            <div class="card">
                <p>Reservations are available.</p>
                <c:choose>
                    <c:when test="${account.noShowCount gt 0}">
                        <p class="warn-text">
                            <strong>${account.noShowCount} of ${strikesAllowed}</strong> missed
                            reservations in a row. Showing up resets the count.
                        </p>
                    </c:when>
                    <c:otherwise>
                        <p class="muted">No missed reservations on record.</p>
                    </c:otherwise>
                </c:choose>
                <p class="muted">
                    Reserving holds an outlet nobody else can take, so ${strikesAllowed} missed
                    reservations in a row suspend the privilege for ${suspensionDays} day(s).
                    A missed reservation costs no money — the outlet being held for nothing is
                    the cost, and denying the privilege is what answers it.
                </p>
            </div>
        </c:otherwise>
    </c:choose>
</t:page>
