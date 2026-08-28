package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.dao.NotificationDao;
import it.unipi.dsmt.voltshare.model.Notification;
import it.unipi.dsmt.voltshare.model.User;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.sql.SQLException;
import java.util.List;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * What the system had to tell this driver while they were away.
 *
 * <p>The other half of the notification story: the station page pushes events live over the
 * WebSocket, and whatever the driver did not see there ends up here. With no mobile push, this
 * page is the only way a notice reaches someone who closed the browser — a limitation of the
 * client channel, not of the coordination logic (DESIGN-NOTES).
 */
@WebServlet("/notifications")
public class NotificationsServlet extends HttpServlet {

    private static final Logger LOG = Logger.getLogger(NotificationsServlet.class.getName());
    private static final int PAGE_LIMIT = 100;

    private final NotificationDao notifications = new NotificationDao();

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        User user = (User) req.getSession().getAttribute("user");

        try {
            List<Notification> list = notifications.findByUser(user.getId(), PAGE_LIMIT);
            // Read them before rendering, so the badge is right on the next page: opening the
            // list IS reading it. Done after the SELECT so this render still shows which ones
            // were new.
            notifications.markAllRead(user.getId());

            req.setAttribute("notifications", list);
            req.getRequestDispatcher("/WEB-INF/views/notifications.jsp").forward(req, res);

        } catch (SQLException e) {
            LOG.log(Level.SEVERE, "Cannot read notifications for user " + user.getId(), e);
            req.setAttribute("message", "Notifications are temporarily unavailable.");
            req.getRequestDispatcher("/WEB-INF/views/error.jsp").forward(req, res);
        }
    }
}
