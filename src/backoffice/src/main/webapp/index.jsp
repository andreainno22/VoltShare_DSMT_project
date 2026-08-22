<%@ page contentType="text/html;charset=UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<c:redirect url="${empty sessionScope.user ? '/login.jsp' : '/stations'}"/>
