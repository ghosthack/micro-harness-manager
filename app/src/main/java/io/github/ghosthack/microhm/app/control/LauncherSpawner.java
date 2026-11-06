package io.github.ghosthack.microhm.app.control;

import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.session.SessionLauncher;

import java.util.Objects;
import java.util.Optional;

/**
 * The production {@link SessionSpawner}: launches through the window's own
 * {@link SessionLauncher} (so the session is named, registered,
 * labelled and MCP-injected exactly like one opened from the toolbar), then tells the
 * window through {@link SessionEvents} so the sidebar picks it up without stealing focus.
 */
public final class LauncherSpawner implements SessionSpawner {

    private final SessionLauncher launcher;
    private final SessionHost host;
    private final SessionEvents events;

    public LauncherSpawner(SessionLauncher launcher, SessionHost host, SessionEvents events) {
        this.launcher = Objects.requireNonNull(launcher, "launcher");
        this.host = Objects.requireNonNull(host, "host");
        this.events = Objects.requireNonNull(events, "events");
    }

    @Override
    public String spawn(SpawnRequest request) {
        String name = launcher.create(request.project(), request.harness(), Optional.empty(),
                request.displayName(), request.labels());
        events.fireSessionsChanged(name);
        return name;
    }

    @Override
    public void kill(String session) {
        host.killSession(session);
        launcher.discardMcpConfig(session);
        events.fireSessionKilled(session);
    }
}
