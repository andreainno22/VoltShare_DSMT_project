package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.erlang.ErlangBridge;
import it.unipi.dsmt.voltshare.erlang.StationDirectory;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;

/**
 * The station list.
 *
 * <p>Served entirely from the in-memory directory: a lobby refresh never reaches the Erlang
 * cluster, which is the point of having the coordinator push its state instead of being
 * polled. If the push has gone quiet the page says so rather than showing stale numbers as
 * if they were current.
 */
@WebServlet("/stations")
public class StationsServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse res)
            throws ServletException, IOException {

        StationDirectory directory = StationDirectory.getInstance();
        req.setAttribute("stations", directory.all());
        req.setAttribute("stale", directory.isStale());
        req.setAttribute("clusterUp", ErlangBridge.getInstance().isConnected());
        req.getRequestDispatcher("/WEB-INF/views/stations.jsp").forward(req, res);
    }
}
