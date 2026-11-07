package io.github.ghosthack.microhm.app.mcphost;

import io.github.ghosthack.microhm.app.MicroHarnessManagerApp;
import io.github.ghosthack.microhm.app.daemon.SessionServerHost;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.mux.server.ServerHome;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Starts the {@linkplain McpHost headless MCP host} as the app quits. Through the
 * packaged launcher when there is one ({@code jpackage.app-path}), else the same JVM and
 * classpath as this process. The child is detached in the way that matters here: started
 * from the user's home directory, output appended to {@code mcp-host.log} beside the
 * registry, holding none of this process's terminal.
 */
public final class HostLauncher {

    private static final Logger LOG = LoggerFactory.getLogger(HostLauncher.class);

    /**
     * Launches the host when the MCP server is on and a registered session is live (there
     * would be nothing to serve otherwise). True when a host process was started.
     */
    public static boolean launchIfNeeded(SessionRegistry registry, SessionServerHost host) {
        if (!AppSettings.mcpServerEnabled()) {
            return false;
        }
        if (McpHost.liveRegistered(registry, host) == 0) {
            return false;
        }
        Path registryFile = RegistryPaths.resolve();
        List<String> command = command();
        try {
            new ProcessBuilder(command)
                    .directory(new File(System.getProperty("user.home")))
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.appendTo(
                            registryFile.toAbsolutePath().resolveSibling("mcp-host.log").toFile()))
                    .start();
            LOG.info("started the MCP host to serve while the app is closed");
            return true;
        } catch (IOException e) {
            LOG.warn("could not start the MCP host ({}): {}", String.join(" ", command), e.toString());
            return false;
        }
    }

    /** The host gets this app's registry and daemon home spelled out, so it serves exactly
     * the same state however the app was started (overrides, environment, home). */
    static List<String> command() {
        return command(System.getProperty("jpackage.app-path"), System.getProperty("java.home"),
                System.getProperty("java.class.path"), RegistryPaths.resolve().toAbsolutePath(),
                ServerHome.resolve().toAbsolutePath());
    }

    static List<String> command(String appPath, String javaHome, String classPath, Path registry, Path muxHome) {
        List<String> command = new ArrayList<>();
        if (appPath != null && !appPath.isBlank()) {
            command.add(appPath);
        } else {
            boolean windows = System.getProperty("os.name", "").toLowerCase().startsWith("windows");
            command.add(Path.of(javaHome, "bin", windows ? "java.exe" : "java").toString());
            command.add("--enable-native-access=ALL-UNNAMED");
            command.add("-cp");
            command.add(absolutize(classPath));
            command.add(MicroHarnessManagerApp.class.getName());
        }
        command.add(McpHost.FLAG);
        command.add(McpHost.REGISTRY_OPTION + registry);
        command.add(McpHost.MUX_HOME_OPTION + muxHome);
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
