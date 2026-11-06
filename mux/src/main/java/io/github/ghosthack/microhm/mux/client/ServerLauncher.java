package io.github.ghosthack.microhm.mux.client;

import io.github.ghosthack.microhm.mux.server.ServerHome;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * How a client starts a server when none is listening. Resolution order:
 * <ol>
 *   <li>{@code -Dmicrohm.mux.launcher=/path} or {@code MICROHM_MUX_LAUNCHER}
 *       — an executable (the jpackage launcher, or a script) run as
 *       {@code <launcher> serve --daemon --home <home>};</li>
 *   <li>a sibling jpackage launcher named {@value #NATIVE_LAUNCHER} next to the current
 *       process's executable;</li>
 *   <li>{@code <java.home>/bin/java -cp <absolutized java.class.path> …Main serve --daemon
 *       --home <home>} — works from the app's shaded jar, which carries this module. The
 *       classpath is absolutized because the child is started from the user's home
 *       directory, not the parent's cwd.</li>
 * </ol>
 * The child is started from the user's home directory with
 * {@code redirectErrorStream(true).redirectOutput(Redirect.appendTo(<home>/server.log))}
 * and stdin left as the default pipe — never {@code inheritIO}, so it holds no descriptor
 * of the parent's terminal (and on Windows the JVM passes {@code CREATE_NO_WINDOW} only
 * when no std handle is inherited, which gives the daemon its own hidden console). ({@code serve --daemon} redirects its own stdio too and
 * ignores SIGHUP/SIGINT; see {@code DaemonMode}.)
 */
public final class ServerLauncher {

    public static final String LAUNCHER_PROPERTY = "microhm.mux.launcher";
    public static final String LAUNCHER_ENV = "MICROHM_MUX_LAUNCHER";
    public static final String MAIN_CLASS = "io.github.ghosthack.microhm.mux.Main";
    public static final String NATIVE_LAUNCHER = "microhm-mux";

    /** The subcommand and flag every resolved command ends with, before {@code --home}. */
    static final List<String> SERVE_ARGS = List.of("serve", "--daemon");

    private static final boolean WINDOWS = System.getProperty("os.name", "").startsWith("Windows");

    /** {@code <java.home>/bin/java} ({@code java.exe} on Windows). */
    public static Path javaBinary(String javaHome) {
        return Path.of(javaHome, "bin", WINDOWS ? "java.exe" : "java");
    }

    public static Path javaBinary() {
        return javaBinary(System.getProperty("java.home"));
    }

    /** The argv that would be used, ending in {@code serve --daemon} ({@link #spawn} appends
     * {@code --home <home>}), or empty when nothing resolves. Never spawns. Parameterised
     * for tests. */
    public static Optional<List<String>> resolveCommand(String launcherProperty, String launcherEnv,
                                                        Optional<Path> currentExecutable,
                                                        String javaHome, String classpath,
                                                        boolean mainClassPresent) {
        Optional<String> explicit = firstNonBlank(launcherProperty, launcherEnv);
        if (explicit.isPresent()) {
            // Configured on purpose: used as given, so a wrong path fails loudly at spawn
            // instead of silently falling through to a different server build.
            return Optional.of(withServeArgs(Path.of(explicit.get()).toAbsolutePath().normalize().toString()));
        }
        Optional<Path> sibling = currentExecutable
                .map(exe -> exe.toAbsolutePath().normalize().getParent())
                .flatMap(ServerLauncher::packagedLauncher);
        if (sibling.isPresent()) {
            return Optional.of(withServeArgs(sibling.get().toString()));
        }
        if (mainClassPresent && javaHome != null && !javaHome.isBlank()
                && classpath != null && !classpath.isBlank()) {
            // -jar would honour the manifest's Enable-Native-Access; a -cp launch does not,
            // and the FFM PTY layer would print restricted-method warnings into server.log.
            return Optional.of(withServeArgs(javaBinary(javaHome).toString(),
                    "--enable-native-access=ALL-UNNAMED", "-cp", absolutize(classpath), MAIN_CLASS));
        }
        return Optional.empty();
    }

    public static Optional<List<String>> resolveCommand() {
        return resolveCommand(System.getProperty(LAUNCHER_PROPERTY), System.getenv(LAUNCHER_ENV),
                ProcessHandle.current().info().command().map(Path::of),
                System.getProperty("java.home"), System.getProperty("java.class.path", ""),
                mainClassPresent());
    }

    /** Spawns the server for {@code home}; returns the process. Throws
     * {@link SessionServerException} when nothing resolves or the spawn fails. */
    public static Process spawn(Path home) {
        List<String> command = new ArrayList<>(resolveCommand().orElseThrow(() -> new SessionServerException(
                "cannot start the session daemon: no launcher configured (" + LAUNCHER_PROPERTY
                        + " / " + LAUNCHER_ENV + "), no sibling launcher, and " + MAIN_CLASS
                        + " is not on the classpath")));
        command.add("--home");
        command.add(home.toAbsolutePath().normalize().toString());
        try {
            Files.createDirectories(home);
            return new ProcessBuilder(command)
                    .directory(new File(System.getProperty("user.home")))
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.appendTo(ServerHome.log(home).toFile()))
                    .start();
        } catch (IOException e) {
            throw new SessionServerException("cannot start the session daemon: " + String.join(" ", command), e);
        }
    }

    private static Optional<Path> packagedLauncher(Path directory) {
        if (directory == null) {
            return Optional.empty();
        }
        Path launcher = directory.resolve(WINDOWS ? NATIVE_LAUNCHER + ".exe" : NATIVE_LAUNCHER);
        return Files.isRegularFile(launcher) ? Optional.of(launcher) : Optional.empty();
    }

    private static List<String> withServeArgs(String... prefix) {
        List<String> command = new ArrayList<>(Arrays.asList(prefix));
        command.addAll(SERVE_ARGS);
        return List.copyOf(command);
    }

    private static Optional<String> firstNonBlank(String property, String env) {
        if (property != null && !property.isBlank()) {
            return Optional.of(property);
        }
        if (env != null && !env.isBlank()) {
            return Optional.of(env);
        }
        return Optional.empty();
    }

    private static String absolutize(String classpath) {
        return Arrays.stream(classpath.split(Pattern.quote(File.pathSeparator)))
                .filter(entry -> !entry.isBlank())
                .map(entry -> Path.of(entry).toAbsolutePath().normalize().toString())
                .collect(Collectors.joining(File.pathSeparator));
    }

    private static boolean mainClassPresent() {
        try {
            Class.forName(MAIN_CLASS, false, ServerLauncher.class.getClassLoader());
            return true;
        } catch (ClassNotFoundException | LinkageError e) {
            return false;
        }
    }

    private ServerLauncher() {
    }
}
