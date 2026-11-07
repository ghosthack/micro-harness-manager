package io.github.ghosthack.microhm.app;

import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.mcphost.HostLauncher;
import io.github.ghosthack.microhm.app.mcphost.HostOwner;
import io.github.ghosthack.microhm.app.mcphost.InstanceLock;
import io.github.ghosthack.microhm.app.mcphost.McpHost;
import io.github.ghosthack.microhm.app.mcphost.McpStack;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.app.ui.MacWindowAppearance;
import io.github.ghosthack.microhm.app.ui.MainWindow;
import com.formdev.flatlaf.themes.FlatMacDarkLaf;
import com.formdev.flatlaf.themes.FlatMacLightLaf;

import javax.swing.JOptionPane;
import javax.swing.SwingUtilities;
import java.io.IOException;
import java.nio.file.Path;
import java.time.Duration;

/**
 * Entry point: multi-session Swing app over harnesses hosted on the session daemon.
 * Loads the session registry, reconciles it against the daemon, and shows the main
 * window. The only place concrete host classes are wired together.
 *
 * <p>All state lives under {@code ~/.micro-harness-manager}, never harness-manager's
 * {@code ~/.harness-manager}: the registry defaults to {@code sessions.json} there
 * (override with {@code -Dmicrohm.registry=/path/to/sessions.json}, used by smoke tests;
 * settings, MCP configs and the instance lock follow it), and the daemon's home is its
 * {@code mux} directory (override with {@code -Dmicrohm.mux.home} or
 * {@code MICROHM_MUX_HOME}).
 */
public final class MicroHarnessManagerApp {

    /** How long a running MCP host gets to exit when the app takes the registry back. */
    private static final Duration HOST_STOP_WAIT = Duration.ofSeconds(5);

    /**
     * Packaging only: start up as usual (point {@code -Dmicrohm.registry} at a scratch
     * directory), show the window, and quit a moment later. Run under
     * {@code -XX:AOTCacheOutput} it records the classes a start loads into the AOT cache
     * the launcher then uses, which halves the time to a visible window.
     */
    public static final String AOT_TRAIN_FLAG = "--aot-train";

    /** How long a training run keeps the window up, for the first paints and the timers. */
    private static final int AOT_TRAIN_MILLIS = 3000;

    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("--package-smoke")) {
            PackageSmoke.run();
            return;
        }
        if (args.length >= 1 && args[0].equals(McpHost.FLAG)) {
            McpHost.run(args);
            return;
        }
        // The background host opens the app with its own state locations spelled out.
        McpHost.applyStateOptions(args);
        // Same pair the MainWindow toolbar toggle switches between at runtime.
        AppSettings.UiTheme theme = AppSettings.uiTheme();
        // Before any AWT/Swing call: the JDK reads the appearance property once, while
        // starting AppKit. Setting it later is silently ignored (the toolbar toggle uses
        // MacWindowAppearance.apply instead). Same timing constraint for the menu-bar/
        // Dock name, which otherwise shows the main class name.
        System.setProperty("apple.awt.application.name", MainWindow.APP_NAME);
        MacWindowAppearance.applyBeforeAwt(theme);
        if (theme == AppSettings.UiTheme.LIGHT) {
            FlatMacLightLaf.setup();
        } else {
            FlatMacDarkLaf.setup();
        }
        Path registryFile = RegistryPaths.resolve();
        if (!lockInstance(registryFile)) {
            SwingUtilities.invokeLater(() -> {
                JOptionPane.showMessageDialog(null,
                        MainWindow.APP_NAME + " is already running for this registry ("
                                + registryFile + ").",
                        "Already running", JOptionPane.ERROR_MESSAGE);
                System.exit(1);
            });
            return;
        }
        SessionRegistry registry = SessionRegistry.load(registryFile);
        // Only newSession ever spawns the daemon; every other call on a dead daemon home
        // answers "no server", so an app with no sessions costs nothing.
        SessionServerHost host = SessionServerHost.forDefaultHome();
        // The MCP server: off unless mcp.server=on; its tools are the session controller
        // over the daemon, spawning through the window's own launcher (see McpStack).
        McpStack stack = McpStack.create(registry, host);
        McpService mcpService = stack.service();
        startMcpServer(mcpService);
        // However the app ends, agents keep their MCP tools while sessions live: a
        // headless host takes over the server (and the registry) until the app is back.
        Runtime.getRuntime().addShutdownHook(Thread.ofPlatform().name("mhm-mcp-handoff").unstarted(
                () -> HostLauncher.launchIfNeeded(registry, host)));
        boolean training = java.util.Arrays.asList(args).contains(AOT_TRAIN_FLAG);
        SwingUtilities.invokeLater(() -> {
            new MainWindow(registry, host, stack.launcher(), mcpService, stack.events()).setVisible(true);
            if (training) {
                javax.swing.Timer quit = new javax.swing.Timer(AOT_TRAIN_MILLIS, e -> System.exit(0));
                quit.setRepeats(false);
                quit.start();
            }
        });
    }

    /** Starts the MCP server when the setting is on. A taken port is logged by the
     * service and leaves the app running without it — Settings can pick another. */
    private static void startMcpServer(McpService mcpService) {
        if (!AppSettings.mcpServerEnabled()) {
            return;
        }
        try {
            mcpService.start(AppSettings.mcpPort(), AppSettings.mcpToken());
        } catch (IOException | RuntimeException e) {
            // logged by the service; tell the user too, once the window is up
            SwingUtilities.invokeLater(() -> JOptionPane.showMessageDialog(null,
                    "The MCP server could not start on port " + AppSettings.mcpPort() + ": " + e.getMessage()
                            + "\n" + MainWindow.APP_NAME + " runs without it; pick another port in Settings.",
                    "MCP server", JOptionPane.WARNING_MESSAGE));
        }
    }

    /**
     * Takes the registry's instance lock. A headless MCP host holding it (the app was
     * closed while sessions ran) is stopped and the lock taken over; anything else holding
     * it is another app. A lock that cannot even be attempted runs unguarded.
     */
    private static boolean lockInstance(Path registryFile) throws InterruptedException {
        InstanceLock.Result lock = InstanceLock.tryAcquire(registryFile);
        if (lock == InstanceLock.Result.HELD) {
            // A host that just took the lock writes its record right after; give it a moment.
            for (int i = 0; i < 20 && HostOwner.read(registryFile).isEmpty(); i++) {
                Thread.sleep(50);
            }
            if (HostOwner.read(registryFile).isPresent() && HostOwner.stop(registryFile, HOST_STOP_WAIT)) {
                lock = InstanceLock.acquire(registryFile, HOST_STOP_WAIT);
            }
        }
        return lock != InstanceLock.Result.HELD;
    }

    private MicroHarnessManagerApp() {
    }
}
