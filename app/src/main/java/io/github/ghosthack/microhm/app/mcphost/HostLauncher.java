package io.github.ghosthack.microhm.app.mcphost;

import io.github.ghosthack.microhm.app.MicroHarnessManagerApp;
import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.mux.client.JvmOptions;
import io.github.ghosthack.microhm.mux.server.ServerHome;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.IOException;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.IntSupplier;

/**
 * Starts the {@linkplain McpHost background host} as the app quits, and the app from the
 * host's tray menu. Through the
 * packaged launcher when there is one ({@code jpackage.app-path}), else the same JVM and
 * classpath as this process. The child is detached in the way that matters here: started
 * from the user's home directory, output appended to {@code mcp-host.log} beside the
 * registry, holding none of this process's terminal.
 */
public final class HostLauncher {

    private static final Logger LOG = LoggerFactory.getLogger(HostLauncher.class);

    /**
     * Launches the host when a registered session is live and it has something to do: the
     * MCP server or the tray icon is on. True when a host process was started.
     */
    public static boolean launchIfNeeded(SessionRegistry registry, SessionServerHost host, Duration wait) {
        if (!AppSettings.mcpServerEnabled() && !AppSettings.trayIconEnabled() && !AppSettings.phoneServerEnabled()) {
            return false;
        }
        if (!anyLive(() -> McpHost.liveRegistered(registry, host), wait)) {
            return false;
        }
        return start(withState(launcher(), McpHost.FLAG), "mcp-host.log", "the background host") != null;
    }

    /**
     * Whether {@code liveCount} finds a registered session live, waiting at most
     * {@code wait} for it (it asks the daemon). No answer in time counts as yes: the host
     * checks again itself and exits when nothing is live, whereas giving up here would leave
     * live sessions without MCP and the phone page until the app is back.
     */
    static boolean anyLive(IntSupplier liveCount, Duration wait) {
        FutureTask<Integer> check = new FutureTask<>(liveCount::getAsInt);
        Thread.ofPlatform().daemon().name("mhm-mcp-handoff-check").start(check);
        try {
            return check.get(wait.toMillis(), TimeUnit.MILLISECONDS) > 0;
        } catch (TimeoutException e) {
            LOG.info("the session daemon did not answer within {} ms; starting the background host to check for itself",
                    wait.toMillis());
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return true;
        } catch (ExecutionException e) {
            LOG.debug("could not count live sessions", e.getCause());
            return false;
        }
    }

    /** The app this host last started from its tray menu, while it may still be starting. */
    private static Process openedApp;

    /**
     * Opens the app (from the tray menu); it stops this host as it starts. A second Open
     * while the app started by the first is still running does nothing: that app is about
     * to take over, and another would only find the registry taken and say so.
     */
    static synchronized boolean openApp() {
        if (openedApp != null && openedApp.isAlive()) {
            LOG.info("the app is already starting; not opening another");
            return false;
        }
        openedApp = start(withState(launcher()), "app.log", "the app");
        return openedApp != null;
    }

    /** How long the tray probe may take; a JVM start, so seconds, not milliseconds. */
    static final Duration TRAY_PROBE_WAIT = Duration.ofSeconds(15);

    /**
     * Whether the desktop has a tray, asked by a throwaway process ({@link McpHost#probeTray})
     * so this one never connects to the display. No answer in time counts as no tray: the
     * host then runs headless, which keeps MCP and the phone page safe from a logout.
     */
    static boolean trayAvailable() {
        List<String> command = new ArrayList<>(launcher());
        command.add(McpHost.TRAY_PROBE_FLAG);
        try {
            Process probe = new ProcessBuilder(command)
                    .directory(new File(System.getProperty("user.home")))
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .start();
            if (!probe.waitFor(TRAY_PROBE_WAIT.toMillis(), TimeUnit.MILLISECONDS)) {
                probe.destroyForcibly();
                LOG.info("the tray probe did not answer within {} s; no tray icon", TRAY_PROBE_WAIT.toSeconds());
                return false;
            }
            return probe.exitValue() == McpHost.TRAY_PRESENT;
        } catch (IOException e) {
            LOG.warn("could not run the tray probe: {}", e.toString());
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    /** The started process, or null when it could not be started. */
    private static Process start(List<String> command, String logName, String what) {
        Path log = RegistryPaths.resolve().toAbsolutePath().resolveSibling(logName);
        try {
            Process process = new ProcessBuilder(command)
                    .directory(new File(System.getProperty("user.home")))
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.appendTo(log.toFile()))
                    .start();
            LOG.info("started {}", what);
            return process;
        } catch (IOException e) {
            LOG.warn("could not start {} ({}): {}", what, String.join(" ", command), e.toString());
            return null;
        }
    }

    /** The host or app command: {@code launcher} then {@code mode} (if any), then this
     * process's registry and daemon home spelled out, so the child serves exactly the same
     * state however this process was started (overrides, environment, home). */
    private static List<String> withState(List<String> launcher, String... mode) {
        return command(launcher, RegistryPaths.resolve().toAbsolutePath(), ServerHome.resolve().toAbsolutePath(),
                mode);
    }

    private static List<String> launcher() {
        return launcher(System.getProperty("jpackage.app-path"), System.getProperty("java.home"),
                System.getProperty("java.class.path"));
    }

    static List<String> command(List<String> launcher, Path registry, Path muxHome, String... mode) {
        List<String> command = new ArrayList<>(launcher);
        command.addAll(List.of(mode));
        command.add(McpHost.REGISTRY_OPTION + registry);
        command.add(McpHost.MUX_HOME_OPTION + muxHome);
        return command;
    }

    /** The packaged launcher when there is one, else this JVM, classpath and main class. */
    static List<String> launcher(String appPath, String javaHome, String classPath) {
        List<String> command = new ArrayList<>();
        if (appPath != null && !appPath.isBlank()) {
            command.add(appPath);
        } else {
            boolean windows = System.getProperty("os.name", "").toLowerCase().startsWith("windows");
            command.add(Path.of(javaHome, "bin", windows ? "java.exe" : "java").toString());
            command.addAll(JvmOptions.RESIDENT);
            command.add("--enable-native-access=ALL-UNNAMED");
            command.add("-cp");
            command.add(absolutize(classPath));
            command.add(MicroHarnessManagerApp.class.getName());
        }
        return command;
    }

    /** The child starts in the home directory, so relative classpath entries would break. */
    private static String absolutize(String classPath) {
        List<String> entries = new ArrayList<>();
        for (String entry : classPath.split(File.pathSeparator)) {
            if (!entry.isBlank()) {
                entries.add(Path.of(entry).toAbsolutePath().toString());
            }
        }
        return String.join(File.pathSeparator, entries);
    }

    private HostLauncher() {
    }
}
