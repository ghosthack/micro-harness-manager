package io.github.ghosthack.microhm.app.session;

import io.github.ghosthack.microhm.mux.session.ShellCommand;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.function.Predicate;

/**
 * The shell new sessions start in. The {@code session.shell} setting is empty for the
 * user's default (what the daemon picks: {@code $SHELL} on macOS and Linux, PowerShell or
 * cmd on Windows), a well-known name ({@code zsh}, {@code bash}, {@code fish}, {@code sh};
 * {@code pwsh}, {@code powershell}, {@code cmd} on Windows), or a path to any shell.
 * Unix shells start as login shells ({@code -l}) so they read the user's profile, as the
 * default does.
 */
public final class SessionShell {

    /** The default: let the daemon choose, exactly as before this setting existed. */
    public static final String DEFAULT = "";

    static final List<String> UNIX_NAMES = List.of("zsh", "bash", "fish", "sh");
    static final List<String> WINDOWS_NAMES = List.of("pwsh", "powershell", "cmd");

    /** Where Unix shells live when PATH (often minimal for an app started from the Dock)
     * does not list them. */
    private static final List<String> UNIX_DIRS =
            List.of("/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin");

    private final boolean windows;
    private final Map<String, String> env;
    private final Predicate<Path> executable;

    SessionShell(boolean windows, Map<String, String> env, Predicate<Path> executable) {
        this.windows = windows;
        this.env = env;
        this.executable = executable;
    }

    public static SessionShell system() {
        return new SessionShell(System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows"),
                System.getenv(), path -> Files.isRegularFile(path) && Files.isExecutable(path));
    }

    /**
     * The command a session with {@code setting} starts, or empty for the daemon's default
     * (also when the chosen shell cannot be found, so a session always starts).
     */
    public Optional<List<String>> command(String setting) {
        if (setting == null || setting.isBlank()) {
            return Optional.empty();
        }
        return resolve(setting.trim()).map(path -> windows ? List.of(path) : List.of(path, "-l"));
    }

    /** Shells that take {@code -l -i -c COMMAND} and {@code exec}, so an agent can start in
     * one step: the shell loads the user's setup, runs the agent, then becomes a login
     * shell again. */
    static final Set<String> ONE_STEP_SHELLS = Set.of("zsh", "bash", "sh", "dash", "ksh", "fish");

    /**
     * The argv that starts {@code agentCommand} in one step inside the shell {@code setting}
     * picks (the default shell when empty), leaving a login shell when the agent exits;
     * empty when that shell cannot do it (Windows shells, unknown ones), so the caller
     * types the command instead.
     */
    public Optional<List<String>> oneStep(String setting, String agentCommand) {
        if (windows || agentCommand == null || agentCommand.isBlank()) {
            return Optional.empty();
        }
        String shell = setting == null || setting.isBlank()
                ? ShellCommand.forSession("probe", null).command().getFirst()
                : resolve(setting.trim()).orElse(null);
        if (shell == null || !ONE_STEP_SHELLS.contains(baseName(shell).toLowerCase(Locale.ROOT))) {
            return Optional.empty();
        }
        return Optional.of(List.of(shell, "-l", "-i", "-c", agentCommand + "; exec " + quote(shell) + " -l"));
    }

    /** {@code value} as one single-quoted word, for the shells in {@link #ONE_STEP_SHELLS}. */
    static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    /** The installed choices, in menu order: the well-known shells found on this machine. */
    public List<String> installedNames() {
        List<String> found = new ArrayList<>();
        for (String name : windows ? WINDOWS_NAMES : UNIX_NAMES) {
            if (resolve(name).isPresent()) {
                found.add(name);
            }
        }
        return found;
    }

    /** What the user's default is called, e.g. {@code zsh} or {@code PowerShell 7}. */
    public String defaultName() {
        String program = ShellCommand.forSession("probe", null).command().getFirst();
        return displayName(program);
    }

    /** How {@code setting} reads in the UI: "zsh (your default)", "bash", "fish (not found)". */
    public String describe(String setting) {
        if (setting == null || setting.isBlank()) {
            return defaultName() + " (your default)";
        }
        String name = displayName(setting.trim());
        return resolve(setting.trim()).isPresent() ? name : name + " (not found; your default is used)";
    }

    /** A friendly name for a shell name or path. */
    public String displayName(String nameOrPath) {
        String base = baseName(nameOrPath).toLowerCase(Locale.ROOT);
        if (base.endsWith(".exe")) {
            base = base.substring(0, base.length() - 4);
        }
        return switch (base) {
            case "pwsh" -> "PowerShell 7";
            case "powershell" -> "Windows PowerShell";
            case "cmd" -> "Command Prompt";
            // a well-known shell reads as its name wherever it lives; anything else as its path
            default -> isPath(nameOrPath) && !ONE_STEP_SHELLS.contains(base) ? nameOrPath : base;
        };
    }

    private Optional<String> resolve(String nameOrPath) {
        if (isPath(nameOrPath)) {
            return executable.test(Path.of(nameOrPath)) ? Optional.of(nameOrPath) : Optional.empty();
        }
        String file = windows && !nameOrPath.toLowerCase(Locale.ROOT).endsWith(".exe") ? nameOrPath + ".exe" : nameOrPath;
        for (String dir : searchDirs()) {
            Path candidate = Path.of(dir, file);
            if (executable.test(candidate)) {
                return Optional.of(candidate.toString());
            }
        }
        return Optional.empty();
    }

    private Set<String> searchDirs() {
        Set<String> dirs = new LinkedHashSet<>();
        String path = env.get(windows ? pathKey() : "PATH");
        if (path != null) {
            for (String dir : path.split(windows ? ";" : ":")) {
                if (!dir.isBlank()) {
                    dirs.add(dir);
                }
            }
        }
        if (!windows) {
            dirs.addAll(UNIX_DIRS);
        }
        return dirs;
    }

    /** Windows spells it Path, PATH or path. */
    private String pathKey() {
        return env.keySet().stream().filter(k -> k.equalsIgnoreCase("PATH")).findFirst().orElse("PATH");
    }

    private static boolean isPath(String value) {
        return value.contains("/") || value.contains("\\");
    }

    private static String baseName(String value) {
        int cut = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
        return value.substring(cut + 1);
    }
}
