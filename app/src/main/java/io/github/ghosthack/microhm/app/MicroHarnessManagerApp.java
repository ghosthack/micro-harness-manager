package io.github.ghosthack.microhm.app;

import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.mcphost.HostLauncher;
import io.github.ghosthack.microhm.app.mcphost.HostOwner;
import io.github.ghosthack.microhm.app.mcphost.InstanceLock;
import io.github.ghosthack.microhm.app.mcphost.McpHost;
import io.github.ghosthack.microhm.app.mcphost.McpStack;
import io.github.ghosthack.microhm.app.perf.AotCache;
import io.github.ghosthack.microhm.app.perf.StartupTimes;
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

    /** How long a recording run for the AOT cache lives after building its window. */
    private static final int AOT_TRAIN_MILLIS = 3000;

    /** How long after the window is up the AOT cache is made, when missing: out of the
     * way of the first session attaching. */
    private static final Duration AOT_CREATE_DELAY = Duration.ofSeconds(10);

    public static void main(String[] args) throws Exception {
        StartupTimes.markMain();
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
        // A recording run for the AOT cache (see AotCache): never a Dock icon or a window.
        boolean training = java.util.Arrays.asList(args).contains(AotCache.TRAIN_FLAG);
        if (training) {
            System.setProperty("apple.awt.UIElement", "true");
        }
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
        SwingUtilities.invokeLater(() -> {
            MainWindow window = new MainWindow(registry, host, stack.launcher(), mcpService, stack.events());
            if (training) {
                recordStart(window);
                return;
            }
            window.addWindowListener(new java.awt.event.WindowAdapter() {
                @Override
                public void windowOpened(java.awt.event.WindowEvent e) {
                    StartupTimes.markWindowShown();
                    AotCache.current().createLaterIfMissing(AOT_CREATE_DELAY, MicroHarnessManagerApp.class.getName());
                }
            });
            window.setVisible(true);
        });
    }

    /**
     * A recording run's stand-in for showing the window: the native window is created and
     * the whole window painted (into an image), which loads what a real start loads,
     * without anything appearing on screen. Then the run quits.
     */
    private static void recordStart(MainWindow window) {
        window.addNotify();
        java.awt.image.BufferedImage image = new java.awt.image.BufferedImage(Math.max(1, window.getWidth()),
                Math.max(1, window.getHeight()), java.awt.image.BufferedImage.TYPE_INT_ARGB);
        java.awt.Graphics2D g = image.createGraphics();
        try {
            window.printAll(g);
        } finally {
            g.dispose();
        }
        javax.swing.Timer quit = new javax.swing.Timer(AOT_TRAIN_MILLIS, e -> System.exit(0));
        quit.setRepeats(false);
        quit.start();
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
