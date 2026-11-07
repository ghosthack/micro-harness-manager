package io.github.ghosthack.microhm.app.mcphost;

import io.github.ghosthack.microhm.app.control.ClientDaemonControl;
import io.github.ghosthack.microhm.app.control.LauncherSpawner;
import io.github.ghosthack.microhm.app.control.SessionController;
import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.session.SessionLauncher;

import java.time.Clock;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The session launcher, the MCP tools (the session controller over the daemon) and the
 * MCP service, wired together. Built the same way by the window and by the headless host,
 * so an agent sees the same tools whichever one is serving.
 *
 * <p>Sessions launched while the service runs get its URL in their launch command (the
 * token rides in their environment or an owner-only config file, never on the command
 * line). The launcher asks the service for URLs and tokens and the service hosts the
 * controller that uses the launcher, hence the late-bound reference. {@link #events}
 * carries what agents create or kill to whoever listens (the window's sidebar).
 */
public record McpStack(SessionLauncher launcher, SessionController controller, McpService service,
                       SessionEvents events) {

    public static McpStack create(SessionRegistry registry, SessionServerHost host) {
        AtomicReference<McpService> serviceRef = new AtomicReference<>();
        SessionEvents events = new SessionEvents();
        SessionLauncher launcher = new SessionLauncher(registry, host, session -> {
            McpService service = serviceRef.get();
            return service != null ? service.linkFor(session) : null;
        }, RegistryPaths.resolveMcpConfigDir(), host::label, host::newSession);
        SessionController controller = new SessionController(new ClientDaemonControl(host.client()),
                registry, new LauncherSpawner(launcher, host, events), Clock.systemUTC());
        McpService service = new McpService(controller);
        serviceRef.set(service);
        return new McpStack(launcher, controller, service, events);
    }
}
