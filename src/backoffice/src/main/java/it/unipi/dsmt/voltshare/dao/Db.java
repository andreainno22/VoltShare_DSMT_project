package it.unipi.dsmt.voltshare.dao;

import it.unipi.dsmt.voltshare.util.Env;

import javax.naming.Context;
import javax.naming.InitialContext;
import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Connection source for the whole back office.
 *
 * <p>Inside Tomcat it uses the pooled {@code jdbc/VoltShareDS} declared in
 * {@code META-INF/context.xml}. Outside a container — unit tests, a quick main — it falls
 * back to a direct connection built from environment variables, so the DAOs stay testable
 * without deploying anything.
 */
public final class Db {

    private static final Logger LOG = Logger.getLogger(Db.class.getName());
    private static volatile DataSource pool;
    private static volatile boolean poolLookupDone;

    private Db() {
    }

    public static Connection getConnection() throws SQLException {
        DataSource ds = pooled();
        if (ds != null) {
            return ds.getConnection();
        }
        return direct();
    }

    private static DataSource pooled() {
        if (!poolLookupDone) {
            synchronized (Db.class) {
                if (!poolLookupDone) {
                    try {
                        Context ctx = (Context) new InitialContext().lookup("java:comp/env");
                        pool = (DataSource) ctx.lookup("jdbc/VoltShareDS");
                        LOG.info("Using the JNDI connection pool jdbc/VoltShareDS");
                    } catch (Exception e) {
                        LOG.log(Level.INFO, "No JNDI pool available, falling back to DriverManager: {0}",
                                e.getMessage());
                        pool = null;
                    }
                    poolLookupDone = true;
                }
            }
        }
        return pool;
    }

    private static Connection direct() throws SQLException {
        String host = Env.get("DB_HOST", "localhost");
        String port = Env.get("DB_PORT", "3306");
        String name = Env.get("DB_NAME", "voltshare");
        String user = Env.get("DB_USER", "voltshare");
        String pass = Env.get("DB_PASSWORD", "voltshare");
        String url = "jdbc:mysql://" + host + ":" + port + "/" + name
                + "?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC";
        return DriverManager.getConnection(url, user, pass);
    }
}
