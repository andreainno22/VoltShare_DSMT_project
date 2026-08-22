package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.dao.UserDao;
import it.unipi.dsmt.voltshare.model.User;
import it.unipi.dsmt.voltshare.util.JwtUtil;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import java.io.IOException;
import java.sql.SQLException;
import java.util.logging.Level;
import java.util.logging.Logger;

@WebServlet("/login")
public class LoginServlet extends HttpServlet {

    private static final Logger LOG = Logger.getLogger(LoginServlet.class.getName());
    private final UserDao users = new UserDao();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        String username = trim(req.getParameter("username"));
        String password = req.getParameter("password");

        if (username.isEmpty() || password == null || password.isEmpty()) {
            fail(req, res, "Enter username and password");
            return;
        }

        try {
            User user = users.authenticate(username, password);
            if (user == null) {
                fail(req, res, "Wrong username or password");
                return;
            }
            startSession(req, user);
            res.sendRedirect(next(req));
        } catch (SQLException e) {
            LOG.log(Level.SEVERE, "Login failed for " + username, e);
            fail(req, res, "Service temporarily unavailable, try again");
        }
    }

    /**
     * Puts the user in session and mints the token the stations will verify.
     * Both live in the session: the JWT never reaches JavaScript through storage,
     * only through the page markup (contracts/jwt.md §2).
     */
    static void startSession(HttpServletRequest req, User user) {
        HttpSession old = req.getSession(false);
        if (old != null) {
            old.invalidate();   // new login, new session id: avoids session fixation
        }
        HttpSession session = req.getSession(true);
        session.setAttribute("user", user);
        session.setAttribute("jwt", JwtUtil.issue(user));
        session.setMaxInactiveInterval(60 * 60);
    }

    private String next(HttpServletRequest req) {
        String next = req.getParameter("next");
        if (next != null && next.startsWith("/") && !next.startsWith("//")) {
            return req.getContextPath() + next;
        }
        return req.getContextPath() + "/stations";
    }

    private void fail(HttpServletRequest req, HttpServletResponse res, String message)
            throws ServletException, IOException {
        req.setAttribute("error", message);
        req.setAttribute("username", req.getParameter("username"));
        req.getRequestDispatcher("/login.jsp").forward(req, res);
    }

    private String trim(String s) {
        return s == null ? "" : s.trim();
    }
}
