package it.unipi.dsmt.voltshare.web;

import it.unipi.dsmt.voltshare.erlang.ErlangBridge;

import jakarta.servlet.ServletContextEvent;
import jakarta.servlet.ServletContextListener;
import jakarta.servlet.annotation.WebListener;

/** Joins the Erlang cluster when the application starts, leaves it when it stops. */
@WebListener
public class AppListener implements ServletContextListener {

    @Override
    public void contextInitialized(ServletContextEvent sce) {
        ErlangBridge.getInstance().start();
    }

    @Override
    public void contextDestroyed(ServletContextEvent sce) {
        ErlangBridge.getInstance().stop();
    }
}
