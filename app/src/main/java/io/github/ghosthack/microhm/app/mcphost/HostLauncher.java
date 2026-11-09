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
import java.util.ArrayList;
import java.util.List;

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
    public static boolean launchIfNeeded(SessionRegistry registry, SessionServerHost host) {
        if (!AppSettings.mcpServerEnabled() && !AppSettings.trayIconEnabled()) {
            return false;
        }
        if (McpHost.liveRegistered(registry, host) == 0) {
            return false;
        }
        return start(withState(launcher(), McpHost.FLAG), "mcp-host.log", "the background host");
    }

    /** Opens the app (from the tray menu); it stops this host as it starts. */
    static boolean openApp() {
        return start(withState(launcher()), "app.log", "the app");
    }

    private static boolean start(List<String> command, String logName, String what) {
        Path log = RegistryPaths.resolve().toAbsolutePath().resolveSibling(logName);
        try {
            new ProcessBuilder(command)
                    .directory(new File(System.getProperty("user.home")))
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.appendTo(log.toFile()))
                    .start();
            LOG.info("started {}", what);
            return true;
        } catch (IOException e) {
            LOG.warn("could not start {} ({}): {}", what, String.join(" ", command), e.toString());
            return false;
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
