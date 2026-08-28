package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.dao.UserDao;
import it.unipi.dsmt.voltshare.model.User;
import it.unipi.dsmt.voltshare.service.PenaltyService;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.sql.SQLException;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * The account: vehicle, and the state of the no-show penalty.
 *
 * <p>Re-read from the database rather than taken from the session. The copy in the session was
 * made at login and knows nothing about a suspension incurred since — and a page whose whole
 * purpose is to say "you may not reserve until Thursday" must not be the one showing stale
 * information.
 */
@WebServlet("/profile")
public class ProfileServlet extends HttpServlet {

    private static final Logger LOG = Logger.getLogger(ProfileServlet.class.getName());

    private final UserDao users = new UserDao();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        User session = (User) req.getSession().getAttribute("user");

        try {
            User fresh = users.findById(session.getId());
            if (fresh == null) {
                // The account was deleted under an open session.
                req.getSession().invalidate();
                res.sendRedirect(req.getContextPath() + "/login.jsp");
                return;
            }

            PenaltyService penalty = PenaltyService.getInstance();
            req.setAttribute("account", fresh);
            req.setAttribute("strikesAllowed", penalty.getStrikesAllowed());
            req.setAttribute("suspensionDays", penalty.getSuspensionDays());
            req.getRequestDispatcher("/WEB-INF/views/profile.jsp").forward(req, res);

        } catch (SQLException e) {
            LOG.log(Level.SEVERE, "Cannot read the profile of user " + session.getId(), e);
            req.setAttribute("message", "The profile is temporarily unavailable.");
            req.getRequestDispatcher("/WEB-INF/views/error.jsp").forward(req, res);
        }
    }
}
