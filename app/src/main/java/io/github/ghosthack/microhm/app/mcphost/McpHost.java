package io.github.ghosthack.microhm.app.mcphost;

import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.mux.server.ServerHome;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Duration;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The background host: what keeps running for the user while the app is closed and their
 * sessions run on. It serves the app's MCP server, so agents keep their session tools,
 * when that is on, and shows a menu-bar or tray icon ({@link StatusIcon}) when that is on
 * and the desktop has a tray; with neither it does not run. Started by the app as it quits
 * (see {@link HostLauncher}) while registered sessions are live; it
 *
 * <ul>
 *   <li>waits for the registry's instance lock, which the quitting app releases as it
 *       exits, and records itself in {@link HostOwner#file};</li>
 *   <li>when MCP is on, serves the same tools on the same port and token as the app, so every session's
 *       MCP config keeps working unchanged;</li>
 *   <li>exits once no registered session is live on the daemon, and when the app starts
 *       again, which stops it ({@link HostOwner#stop}) and takes the lock over.</li>
 * </ul>
 *
 * State an agent built up in the server is not carried across a hand-off: an incremental
 * {@code read} starts over with the whole screen, and pending {@code notify} waits end.
 */
public final class McpHost {

    private static final Logger LOG = LoggerFactory.getLogger(McpHost.class);

    /** The command-line flag that selects this mode. */
    public static final String FLAG = "--mcp-host";
    /** The app's registry file, so the host finds the same settings, MCP configs and lock. */
    public static final String REGISTRY_OPTION = "--registry=";
    /** The app's daemon home, so the host talks to the same daemon. */
    public static final String MUX_HOME_OPTION = "--mux-home=";

    /** How long to wait for the quitting app to release the lock. */
    static final Duration LOCK_WAIT = Duration.ofSeconds(30);
    /** How often to check whether any registered session is still live. */
    static final Duration CHECK_EVERY = Duration.ofSeconds(15);
    /** Consecutive checks that must find nothing live before exiting: one daemon hiccup
     * must not end the host. */
    static final int EMPTY_CHECKS_TO_EXIT = 2;
    /** The macOS glyph follows a dark/light switch about once a minute (every 4th check). */
    static final int APPEARANCE_CHECK_TICKS = 4;

    public static void run(String[] args) throws InterruptedException {
        applyStateOptions(args);
        boolean mcp = AppSettings.mcpServerEnabled();
        boolean wantIcon = AppSettings.trayIconEnabled();
        if (!mcp && !wantIcon) {
            LOG.info("neither the MCP server nor the tray icon is on; nothing to host");
            return;
        }
        // Before anything touches AWT: headless when there is no icon to show, else a
        // menu-bar-only process on macOS (no Dock icon, no app menu).
        if (wantIcon) {
            System.setProperty("apple.awt.UIElement", "true");
        } else {
            System.setProperty("java.awt.headless", "true");
        }
        Path registryFile = RegistryPaths.resolve();
        InstanceLock.Result lock = InstanceLock.acquire(registryFile, LOCK_WAIT);
        if (lock == InstanceLock.Result.HELD) {
            LOG.info("the registry at {} is in use (the app is open); not hosting", registryFile);
            return;
        }
        Optional<HostOwner.Record> self = HostOwner.current();
        if (self.isPresent()) {
            try {
                HostOwner.write(registryFile, self.get());
            } catch (IOException e) {
                LOG.warn("could not record the background host in {}: {}", HostOwner.file(registryFile), e.toString());
            }
        }

        SessionRegistry registry = SessionRegistry.load(registryFile);
        SessionServerHost host = SessionServerHost.forDefaultHome();
        int live = liveRegistered(registry, host);
        if (live == 0) {
            LOG.info("no registered session is live; not hosting");
            self.ifPresent(record -> HostOwner.clear(registryFile, record));
            return;
        }

        McpStack stack = McpStack.create(registry, host);
        int servingPort = -1;
        if (mcp) {
            try {
                stack.service().start(AppSettings.mcpPort(), AppSettings.mcpToken());
                servingPort = AppSettings.mcpPort();
            } catch (IOException | RuntimeException e) {
                LOG.warn("background host could not serve MCP on port {}: {}", AppSettings.mcpPort(), e.toString());
            }
        }
        AtomicBoolean iconHidden = new AtomicBoolean(!wantIcon);
        boolean serving = servingPort > 0;
        Optional<StatusIcon> icon = wantIcon ? StatusIcon.show(new StatusIcon.Actions() {
            @Override
            public void open() {
                HostLauncher.openApp();
            }

            @Override
            public void shutDownSessions() {
                Thread.ofVirtual().start(() -> {
                    try {
                        host.client().shutdown();
                    } catch (RuntimeException e) {
                        LOG.warn("could not shut the session daemon down: {}", e.toString());
                    }
                    System.exit(0);
                });
            }

            @Override
            public void hide() {
                AppSettings.saveTrayIconEnabled(false);
                iconHidden.set(true);
                if (!serving) {
                    System.exit(0);
                }
            }
        }) : Optional.empty();
        if (!serving && icon.isEmpty()) {
            LOG.info("nothing to show or serve (no tray on this desktop, MCP off or unavailable); exiting");
            self.ifPresent(record -> HostOwner.clear(registryFile, record));
            return;
        }
        Runtime.getRuntime().addShutdownHook(Thread.ofPlatform().unstarted(() -> {
            stack.service().stop();
            icon.ifPresent(StatusIcon::remove);
            self.ifPresent(record -> HostOwner.clear(registryFile, record));
        }));
        LOG.info("background host running while the app is closed: {}, {} ({})",
                serving ? "MCP on 127.0.0.1:" + servingPort : "no MCP",
                icon.isPresent() ? "tray icon shown" : "no tray icon",
                self.map(HostOwner::describe).orElse("pid " + ProcessHandle.current().pid()));

        int empty = 0;
        long ticks = 0;
        while (empty < EMPTY_CHECKS_TO_EXIT) {
            if (icon.isPresent()) {
                if (iconHidden.get()) {
                    icon.get().remove();
                } else {
                    icon.get().update(live, servingPort, ticks % APPEARANCE_CHECK_TICKS == 0 && ticks > 0);
                }
            }
            Thread.sleep(CHECK_EVERY);
            ticks++;
            live = liveRegistered(registry, host);
            empty = live == 0 ? empty + 1 : 0;
        }
        LOG.info("no registered session is live any more; background host exiting");
        System.exit(0);
    }

    /** Applies {@link #REGISTRY_OPTION} and {@link #MUX_HOME_OPTION} as the overrides every
     * path resolution reads, for the app and the host alike. */
    public static void applyStateOptions(String[] args) {
        for (String arg : args) {
            if (arg.startsWith(REGISTRY_OPTION)) {
                System.setProperty(RegistryPaths.OVERRIDE_PROPERTY, arg.substring(REGISTRY_OPTION.length()));
            } else if (arg.startsWith(MUX_HOME_OPTION)) {
                System.setProperty(ServerHome.HOME_PROPERTY, arg.substring(MUX_HOME_OPTION.length()));
            }
        }
    }

    /** How many registered sessions the daemon still runs; 0 when it does not answer. */
    static int liveRegistered(SessionRegistry registry, SessionServerHost host) {
        List<String> live;
        try {
            live = host.listSessions();
        } catch (RuntimeException e) {
            return 0;
        }
        Set<String> names = new HashSet<>(live);
        int count = 0;
        for (SessionEntry entry : registry.sessions()) {
            if (names.contains(entry.sessionName())) {
                count++;
            }
        }
        return count;
    }

    private McpHost() {
    }
}
