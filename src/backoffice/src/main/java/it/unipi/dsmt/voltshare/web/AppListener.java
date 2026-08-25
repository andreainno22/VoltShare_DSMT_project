package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.erlang.ErlangBridge;
import it.unipi.dsmt.voltshare.service.BillingService;

import jakarta.servlet.ServletContextEvent;
import jakarta.servlet.ServletContextListener;
import jakarta.servlet.annotation.WebListener;

/** Joins the Erlang cluster when the application starts, leaves it when it stops. */
@WebListener
public class AppListener implements ServletContextListener {

    @Override
    public void contextInitialized(ServletContextEvent sce) {
        // Billing first: its first sweep settles whatever was closed while this node was
        // down, and it must be ready before the bridge can start waking it.
        BillingService.getInstance().start();
        ErlangBridge.getInstance().start();
    }

    @Override
    public void contextDestroyed(ServletContextEvent sce) {
        ErlangBridge.getInstance().stop();
        BillingService.getInstance().stop();
    }
}
