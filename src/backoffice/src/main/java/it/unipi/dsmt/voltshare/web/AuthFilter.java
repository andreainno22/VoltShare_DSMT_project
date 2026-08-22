package it.unipi.dsmt.voltshare.web;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.annotation.WebFilter;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import java.io.IOException;

/**
 * Guards the pages that require a logged-in driver.
 *
 * <p>Login state lives in the {@code HttpSession}, managed by Tomcat. The JWT held alongside
 * it is a different thing: it is not what authenticates these pages, it is what the browser
 * hands to an Erlang station when it opens a WebSocket (contracts/jwt.md).
 */
@WebFilter(urlPatterns = {"/stations", "/station", "/session", "/profile", "/history", "/notifications"})
public class AuthFilter implements Filter {

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest req = (HttpServletRequest) request;
        HttpServletResponse res = (HttpServletResponse) response;

        HttpSession session = req.getSession(false);
        if (session == null || session.getAttribute("user") == null) {
            res.sendRedirect(req.getContextPath() + "/login.jsp?next="
                    + java.net.URLEncoder.encode(pathWithQuery(req), java.nio.charset.StandardCharsets.UTF_8));
            return;
        }
        chain.doFilter(request, response);
    }

    private String pathWithQuery(HttpServletRequest req) {
        String path = req.getRequestURI().substring(req.getContextPath().length());
        return req.getQueryString() == null ? path : path + "?" + req.getQueryString();
    }
}
