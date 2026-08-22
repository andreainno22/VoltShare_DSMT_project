package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.dao.UserDao;
import it.unipi.dsmt.voltshare.model.User;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.sql.SQLException;
import java.util.logging.Level;
import java.util.logging.Logger;

@WebServlet("/register")
public class RegisterServlet extends HttpServlet {

    private static final Logger LOG = Logger.getLogger(RegisterServlet.class.getName());
    private final UserDao users = new UserDao();

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        String username = trim(req.getParameter("username"));
        String password = req.getParameter("password");
        String battery = trim(req.getParameter("batteryKwh"));
        String maxKw = trim(req.getParameter("maxKw"));

        String problem = validate(username, password, battery, maxKw);
        if (problem != null) {
            fail(req, res, problem);
            return;
        }

        try {
            User user = users.register(username, password,
                    Double.parseDouble(battery), Integer.parseInt(maxKw));
            LoginServlet.startSession(req, user);
            res.sendRedirect(req.getContextPath() + "/stations");
        } catch (UserDao.DuplicateUsernameException e) {
            fail(req, res, "That username is already taken");
        } catch (SQLException e) {
            LOG.log(Level.SEVERE, "Registration failed for " + username, e);
            fail(req, res, "Service temporarily unavailable, try again");
        }
    }

    /** The vehicle is part of registration: an account without one could not reserve. */
    private String validate(String username, String password, String battery, String maxKw) {
        if (username.length() < 3 || username.length() > 50) {
            return "Username must be between 3 and 50 characters";
        }
        if (password == null || password.length() < 6) {
            return "Password must be at least 6 characters";
        }
        double kwh;
        int kw;
        try {
            kwh = Double.parseDouble(battery);
            kw = Integer.parseInt(maxKw);
        } catch (NumberFormatException e) {
            return "Battery capacity and maximum power must be numbers";
        }
        if (kwh < 5 || kwh > 250) {
            return "Battery capacity should be between 5 and 250 kWh";
        }
        if (kw < 3 || kw > 400) {
            return "Maximum charging power should be between 3 and 400 kW";
        }
        return null;
    }

    private void fail(HttpServletRequest req, HttpServletResponse res, String message)
            throws ServletException, IOException {
        req.setAttribute("error", message);
        req.setAttribute("username", req.getParameter("username"));
        req.setAttribute("batteryKwh", req.getParameter("batteryKwh"));
        req.setAttribute("maxKw", req.getParameter("maxKw"));
        req.getRequestDispatcher("/register.jsp").forward(req, res);
    }

    private String trim(String s) {
        return s == null ? "" : s.trim();
    }
}
