package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.dao.SessionDao;
import it.unipi.dsmt.voltshare.model.SessionView;
import it.unipi.dsmt.voltshare.model.User;
import it.unipi.dsmt.voltshare.service.BillingService;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.sql.SQLException;
import java.util.List;
import java.util.Locale;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * The driver's own charging history.
 *
 * <p>Straight from MySQL, with no involvement from the cluster: these are closed sessions,
 * a station wrote them and nothing will change them again. The one live element is the cost,
 * which may still be missing on a session that ended seconds ago — the page says so rather
 * than showing a zero that would read as "free".
 *
 * <p>AuthFilter guarantees a logged-in user before this runs, so the session attribute is
 * never null here.
 */
@WebServlet("/history")
public class HistoryServlet extends HttpServlet {

    private static final Logger LOG = Logger.getLogger(HistoryServlet.class.getName());
    private static final int PAGE_LIMIT = 100;

    private final SessionDao sessions = new SessionDao();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        User user = (User) req.getSession().getAttribute("user");

        try {
            List<SessionView> history = sessions.findByUser(user.getId(), PAGE_LIMIT);

            int totalCents = 0;
            double totalKwh = 0;
            for (SessionView s : history) {
                totalKwh += s.getEnergyKwh();
                if (s.isBilled()) {
                    totalCents += s.getCostCents();
                }
            }

            req.setAttribute("sessions", history);
            req.setAttribute("totalEuro", String.format(Locale.ROOT, "%.2f", totalCents / 100.0));
            req.setAttribute("totalKwh", String.format(Locale.ROOT, "%.2f", totalKwh));
            // No global overstay rate is passed any more: it is set per station
            // (stations.tariff_cents_min_overstay), so a single figure on a page listing
            // sessions from several sites would be wrong for some of them.
            req.getRequestDispatcher("/WEB-INF/views/history.jsp").forward(req, res);

        } catch (SQLException e) {
            LOG.log(Level.SEVERE, "Cannot read the history of user " + user.getId(), e);
            req.setAttribute("message", "The charging history is temporarily unavailable.");
            req.getRequestDispatcher("/WEB-INF/views/error.jsp").forward(req, res);
        }
    }
}
