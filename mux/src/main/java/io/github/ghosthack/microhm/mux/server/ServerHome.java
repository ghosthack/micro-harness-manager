package io.github.ghosthack.microhm.mux.server;

import java.nio.file.Path;

/**
 * Where one server lives: a directory holding the socket, the lock and the log. One
 * server per home; the app and the CLI share the default home, and tests use a
 * temporary one so they never touch (or spawn) the user's real server.
 *
 * <p>Default: {@code ~/.micro-harness-manager/mux}. Override with
 * {@code -Dmicrohm.mux.home=DIR} or {@code MICROHM_MUX_HOME}.
 * Unix-domain socket paths have a small length ceiling (104 bytes on macOS, 108 on Linux), so a deeply nested override may fail to bind with a clear error; the
 * default is well inside the limit for any sane home directory.
 */
public final class ServerHome {

    public static final String HOME_PROPERTY = "microhm.mux.home";
    public static final String HOME_ENV = "MICROHM_MUX_HOME";
    public static final String SOCKET_FILE = "server.sock";
    public static final String LOCK_FILE = "server.lock";
    public static final String LOG_FILE = "server.log";

    public static Path resolve() {
        String configured = System.getProperty(HOME_PROPERTY);
        if (configured == null || configured.isBlank()) {
            configured = System.getenv(HOME_ENV);
        }
        if (configured != null && !configured.isBlank()) {
            return Path.of(configured).toAbsolutePath().normalize();
        }
        return Path.of(System.getProperty("user.home"), ".micro-harness-manager", "mux");
    }

    public static Path socket(Path home) {
        return home.resolve(SOCKET_FILE);
    }

    public static Path lock(Path home) {
        return home.resolve(LOCK_FILE);
    }

    public static Path log(Path home) {
        return home.resolve(LOG_FILE);
    }

    private ServerHome() {
    }
}
