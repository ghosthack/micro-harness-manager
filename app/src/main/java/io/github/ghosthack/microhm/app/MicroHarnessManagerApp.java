package io.github.ghosthack.microhm.app;

import io.github.ghosthack.microhm.app.control.ClientDaemonControl;
import io.github.ghosthack.microhm.app.control.LauncherSpawner;
import io.github.ghosthack.microhm.app.control.SessionController;
import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.session.SessionLauncher;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.app.ui.MacWindowAppearance;
import io.github.ghosthack.microhm.app.ui.MainWindow;
import com.formdev.flatlaf.themes.FlatMacDarkLaf;
import com.formdev.flatlaf.themes.FlatMacLightLaf;

import javax.swing.JOptionPane;
import javax.swing.SwingUtilities;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Clock;
import java.util.concurrent.atomic.AtomicReference;

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

    /**
     * Exclusive lock held for the process lifetime — saves are full-snapshot rewrites,
     * so a second instance on the same registry would silently clobber this one's
     * entries. Never closed deliberately; the OS releases it on exit.
     */
    @SuppressWarnings("unused")
    private static FileChannel instanceLock;

    public static void main(String[] args) {
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
        // The MCP server: off unless mcp.server=on. Sessions launched while it runs get
        // its URL in their launch command (the token rides in their environment or an
        // owner-only config file, never on the command line); its tools are the session
        // controller over the daemon, which spawns through the window's own launcher, and
        // SessionEvents carries what agents create or kill into the window's sidebar. The
        // launcher asks the service for URLs and tokens and the service hosts the
        // controller that uses the launcher, hence the late-bound reference.
        AtomicReference<McpService> mcpRef = new AtomicReference<>();
        SessionEvents sessionEvents = new SessionEvents();
        SessionLauncher launcher = new SessionLauncher(registry, host, session -> {
            McpService service = mcpRef.get();
            return service != null ? service.linkFor(session) : null;
        }, RegistryPaths.resolveMcpConfigDir(), host::label, host::newSession);
        SessionController controller = new SessionController(new ClientDaemonControl(host.client()),
                registry, new LauncherSpawner(launcher, host, sessionEvents), Clock.systemUTC());
        McpService mcpService = new McpService(controller);
        mcpRef.set(mcpService);
        startMcpServer(mcpService);
        SwingUtilities.invokeLater(() -> new MainWindow(registry, host, launcher, mcpService, sessionEvents)
                .setVisible(true));
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
     * Takes the single-instance lock: an {@code instance.lock} file beside the resolved
     * registry file, so scratch registries don't contend with the real one. Failure to
     * even attempt the lock (unwritable directory, exotic filesystem) runs unguarded —
     * a working session manager beats refusing to start.
     */
    private static boolean lockInstance(Path registryFile) {
        Path lockFile = registryFile.toAbsolutePath().resolveSibling("instance.lock");
        try {
            Path parent = lockFile.getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            FileChannel channel = FileChannel.open(lockFile,
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
            try {
                if (channel.tryLock() == null) {
                    channel.close();
                    return false;
                }
            } catch (OverlappingFileLockException e) {
                channel.close();
                return false;
            }
            instanceLock = channel;
            return true;
        } catch (IOException e) {
            return true;
        }
    }

    private MicroHarnessManagerApp() {
    }
}
