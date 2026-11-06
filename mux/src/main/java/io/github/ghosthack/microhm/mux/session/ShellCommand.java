package io.github.ghosthack.microhm.mux.session;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * What a session runs and the environment it runs in.
 *
 * <p>Command: an explicit command when the caller gave one; otherwise the login shell —
 * {@code $SHELL} (fallback {@code /bin/sh}) with {@code -l}.
 *
 * <p>Environment: the daemon's own, plus {@code TERM=xterm-256color},
 * {@code COLORTERM=truecolor}, {@code LANG} defaulted to {@code en_US.UTF-8} and
 * {@code MICROHM_SESSION=<name>}, then the caller's extra variables (which may override
 * {@code COLORTERM}, {@code LANG} or anything inherited, but never {@code TERM} or
 * {@code MICROHM_SESSION}).
 *
 * @param command     argv, never empty
 * @param environment the complete environment for the PTY process
 */
public record ShellCommand(List<String> command, Map<String, String> environment) {

    static final String TERM = "xterm-256color";
    static final String DEFAULT_LANG = "en_US.UTF-8";

    public ShellCommand {
        if (command == null || command.isEmpty()) {
            throw new IllegalArgumentException("command must not be empty");
        }
        command = List.copyOf(command);
        environment = Map.copyOf(environment);
    }

    /** The command for {@code sessionName} on this machine: {@code explicitCommand}
     * (null/empty = the platform login shell) with the session environment. */
    public static ShellCommand forSession(String sessionName, List<String> explicitCommand) {
        return forSession(sessionName, explicitCommand, Map.of());
    }

    /** As above, with {@code extraEnvironment} (null = none) merged over the defaults. */
    public static ShellCommand forSession(String sessionName, List<String> explicitCommand,
                                          Map<String, String> extraEnvironment) {
        return build(sessionName, explicitCommand, System.getenv(), extraEnvironment);
    }

    /** The pure core of {@link #forSession}: the inherited environment is a parameter so
     * each branch is unit-testable. */
    static ShellCommand build(String sessionName, List<String> explicitCommand, Map<String, String> inherited) {
        return build(sessionName, explicitCommand, inherited, Map.of());
    }

    /** {@link #build} with the caller's {@code extra} variables (null = none). */
    static ShellCommand build(String sessionName, List<String> explicitCommand, Map<String, String> inherited,
                              Map<String, String> extra) {
        List<String> command = explicitCommand != null && !explicitCommand.isEmpty()
                ? explicitCommand
                : loginShell(inherited);

        Map<String, String> env = new HashMap<>(inherited);
        env.put("TERM", TERM);
        env.put("COLORTERM", "truecolor");
        env.putIfAbsent("LANG", DEFAULT_LANG);
        if (extra != null) {
            env.putAll(extra);
        }
        // Not overridable: the emulator is xterm-256color and the name is the session's.
        env.put("TERM", TERM);
        env.put("MICROHM_SESSION", sessionName);
        return new ShellCommand(command, env);
    }

    private static List<String> loginShell(Map<String, String> inherited) {
        String shell = inherited.get("SHELL");
        if (shell == null || shell.isBlank()) {
            shell = "/bin/sh";
        }
        return List.of(shell, "-l");
    }
}
