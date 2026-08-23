package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.erlang.StationDirectory;
import it.unipi.dsmt.voltshare.model.StationView;
import it.unipi.dsmt.voltshare.model.User;
import it.unipi.dsmt.voltshare.util.JwtUtil;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import java.io.IOException;
import java.util.Optional;

/**
 * Prepares the live station page.
 *
 * <p>This is the one servlet the two halves of the project meet in: it belongs to B, while
 * {@code station.jsp} and {@code station.js} belong to A. Whatever else changes, this class
 * must always leave the same three things in place for the page — {@code station},
 * {@code sessionScope.jwt} and the station id — as fixed in contracts/jwt.md §2.
 */
@WebServlet("/station")
public class StationPageServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        int id;
        try {
            id = Integer.parseInt(req.getParameter("id"));
        } catch (NumberFormatException e) {
            res.sendError(HttpServletResponse.SC_BAD_REQUEST, "Missing or invalid station id");
            return;
        }

        Optional<StationView> station = StationDirectory.getInstance().byId(id);
        if (station.isEmpty()) {
            // Unknown to the directory: either it never existed, or its node is down and the
            // coordinator has dropped it. Both are "not available right now" to the driver.
            req.setAttribute("stationId", id);
            req.getRequestDispatcher("/WEB-INF/views/station-unavailable.jsp").forward(req, res);
            return;
        }

        refreshTokenIfNeeded(req);
        req.setAttribute("station", station.get());
        req.getRequestDispatcher("/WEB-INF/views/station.jsp").forward(req, res);
    }

    /**
     * The page hands the token to a WebSocket that may stay open for an hour, so it is
     * reissued whenever it is close to expiring — the HTTP session, not the token, is what
     * says the driver is still logged in.
     */
    private void refreshTokenIfNeeded(HttpServletRequest req) {
        HttpSession session = req.getSession(false);
        if (session == null) {
            return;
        }
        String jwt = (String) session.getAttribute("jwt");
        if (JwtUtil.needsRefresh(jwt)) {
            User user = (User) session.getAttribute("user");
            if (user != null) {
                session.setAttribute("jwt", JwtUtil.issue(user));
            }
        }
    }
}
