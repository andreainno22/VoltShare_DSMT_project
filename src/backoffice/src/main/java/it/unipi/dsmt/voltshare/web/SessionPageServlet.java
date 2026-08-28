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
 * Prepares the live session page — the twin of {@link StationPageServlet}.
 *
 * <p>Requested in contracts/nota-per-B-m2a.md §4. The two pages open the <em>same</em> driver
 * WebSocket and need the same three values from the back office (contracts/jwt.md §2); they
 * differ only in what they listen to once connected — {@code session} frames (ws-driver.md
 * §5.2) instead of {@code state} frames (§5.1). That is A's side of the page and none of it
 * concerns this class.
 *
 * <p>Deliberately a separate servlet rather than a parameter on {@code /station}: the two are
 * different pages with different URLs, and a driver who bookmarks the one showing their
 * charge should not land on the connector grid. The duplication is four lines and it keeps
 * both routes obvious to read.
 */
@WebServlet("/session")
public class SessionPageServlet extends HttpServlet {

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
            // Unknown to the directory: it never existed, or its node is down and the
            // coordinator has dropped it. Both read the same way to the driver.
            //
            // Worth being clear about what this does NOT mean: a station missing here does not
            // imply the charging session stopped. Power delivery does not pass through the
            // coordinator or the back office, so a session can be running perfectly well while
            // this page cannot be drawn.
            req.setAttribute("stationId", id);
            req.getRequestDispatcher("/WEB-INF/views/station-unavailable.jsp").forward(req, res);
            return;
        }

        refreshTokenIfNeeded(req);
        req.setAttribute("station", station.get());
        req.getRequestDispatcher("/WEB-INF/views/session.jsp").forward(req, res);
    }

    /**
     * A charging session outlives an hour more easily than a glance at the connector list, so
     * reissuing the token matters more here than on the station page: the socket stays open
     * for as long as the car is plugged in. The HTTP session, not the token, is what says the
     * driver is still logged in.
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
