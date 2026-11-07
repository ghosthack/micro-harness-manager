package io.github.ghosthack.microhm.app.session;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/** A host that can start a session running a given command, for one-step agent launches. */
public interface DirectSessionStarter {

    /**
     * Starts the session running {@code command} (argv) with {@code env} (empty = none)
     * and returns whether {@code env} was applied: false only when a non-empty {@code env}
     * went to a daemon that predates per-session environments.
     */
    boolean newSession(String session, Path workdir, int columns, int rows, List<String> command,
                       Map<String, String> env);
}
