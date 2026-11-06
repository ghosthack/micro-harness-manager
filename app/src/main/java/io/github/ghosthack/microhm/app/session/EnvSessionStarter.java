package io.github.ghosthack.microhm.app.session;

import java.nio.file.Path;
import java.util.Map;

/**
 * Starts a session with extra environment variables — the one thing
 * {@link io.github.ghosthack.microhm.app.host.SessionHost#newSession} cannot express,
 * kept to this seam rather than widened onto the host. Production is
 * {@code SessionServerHost::newSession}.
 */
@FunctionalInterface
public interface EnvSessionStarter {

    /** Starts the session and returns whether {@code env} was applied — false when the
     * running daemon predates {@code env} and started the session without it. */
    boolean newSession(String session, Path workdir, int columns, int rows, Map<String, String> env);
}
