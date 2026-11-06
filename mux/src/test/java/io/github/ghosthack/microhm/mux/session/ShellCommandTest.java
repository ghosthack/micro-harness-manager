package io.github.ghosthack.microhm.mux.session;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** The session's command (the login shell) and its environment. */
class ShellCommandTest {

    private static final Map<String, String> UNIX_ENV = Map.of("SHELL", "/bin/zsh", "PATH", "/usr/bin", "HOME", "/Users/x");

    @Test
    void unixUsesShellAsLoginShell() {
        ShellCommand cmd = ShellCommand.build("hm-foo", null, UNIX_ENV);
        assertEquals(List.of("/bin/zsh", "-l"), cmd.command());
    }

    @Test
    void unixFallsBackToBinSh() {
        ShellCommand cmd = ShellCommand.build("hm-foo", List.of(), Map.of("SHELL", " "));
        assertEquals(List.of("/bin/sh", "-l"), cmd.command());
        ShellCommand noShell = ShellCommand.build("hm-foo", null, Map.of());
        assertEquals(List.of("/bin/sh", "-l"), noShell.command());
    }

    @Test
    void environmentInheritsAndAddsTheSessionVariables() {
        ShellCommand cmd = ShellCommand.build("hm-foo", null, UNIX_ENV);
        Map<String, String> env = cmd.environment();
        assertEquals("/Users/x", env.get("HOME"));
        assertEquals("/usr/bin", env.get("PATH"));
        assertEquals("xterm-256color", env.get("TERM"));
        assertEquals("truecolor", env.get("COLORTERM"));
        assertEquals("en_US.UTF-8", env.get("LANG"));
        assertEquals("hm-foo", env.get("MICROHM_SESSION"));
    }

    @Test
    void langIsOnlyDefaulted() {
        Map<String, String> inherited = Map.of("LANG", "de_DE.UTF-8", "TERM", "dumb", "COLORTERM", "no");
        Map<String, String> env = ShellCommand.build("s", null, inherited).environment();
        assertEquals("de_DE.UTF-8", env.get("LANG"));
        assertEquals("xterm-256color", env.get("TERM"), "TERM is always ours");
        assertEquals("truecolor", env.get("COLORTERM"), "COLORTERM is always ours");
    }

    @Test
    void explicitCommandOverridesTheShell() {
        ShellCommand cmd = ShellCommand.build("s", List.of("/usr/bin/top", "-l", "1"), UNIX_ENV);
        assertEquals(List.of("/usr/bin/top", "-l", "1"), cmd.command());
        assertEquals("s", cmd.environment().get("MICROHM_SESSION"));
    }

    @Test
    void rejectsAnEmptyCommand() {
        assertThrows(IllegalArgumentException.class, () -> new ShellCommand(List.of(), Map.of()));
    }

    @Test
    void extraEnvironmentIsMergedAfterTheDefaultsButNeverOverridesTermOrTheSessionName() {
        Map<String, String> extra = Map.of("HM_MCP_TOKEN", "t0k", "LANG", "fr_FR.UTF-8", "COLORTERM", "24bit",
                "PATH", "/opt/bin", "TERM", "dumb", "MICROHM_SESSION", "spoofed");
        Map<String, String> env = ShellCommand.build("hm-foo", null, UNIX_ENV, extra)
                .environment();
        assertEquals("t0k", env.get("HM_MCP_TOKEN"));
        assertEquals("fr_FR.UTF-8", env.get("LANG"));
        assertEquals("24bit", env.get("COLORTERM"));
        assertEquals("/opt/bin", env.get("PATH"), "inherited variables can be replaced");
        assertEquals("/Users/x", env.get("HOME"));
        assertEquals("xterm-256color", env.get("TERM"));
        assertEquals("hm-foo", env.get("MICROHM_SESSION"));
        assertEquals(ShellCommand.build("hm-foo", null, UNIX_ENV).environment(),
                ShellCommand.build("hm-foo", null, UNIX_ENV, null).environment(),
                "null extra = none");
    }
}
