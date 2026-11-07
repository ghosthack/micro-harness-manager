package io.github.ghosthack.microhm.app.session;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SessionShellTest {

    /** A Unix machine with zsh and bash in /bin and fish from Homebrew (not on PATH). */
    private static SessionShell unix() {
        Set<String> installed = Set.of("/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", "/usr/bin/xonsh");
        return new SessionShell(false, Map.of("PATH", "/usr/bin:/bin"),
                path -> installed.contains(path.toString().replace('\\', '/')));
    }

    @Test
    void theDefaultLeavesTheChoiceToTheDaemon() {
        assertEquals(Optional.empty(), unix().command(""));
        assertEquals(Optional.empty(), unix().command(null));
    }

    @Test
    void namesResolveToLoginShellsWherePathOrTheUsualPlacesHaveThem() {
        assertEquals(Optional.of(List.of(Path.of("/bin/bash").toString(), "-l")), unix().command("bash"));
        assertEquals(Optional.of(List.of(Path.of("/opt/homebrew/bin/fish").toString(), "-l")), unix().command("fish"),
                "an app started from the Dock has a short PATH; Homebrew's directory is searched too");
        assertEquals(Optional.of(List.of("/usr/bin/xonsh", "-l")), unix().command("/usr/bin/xonsh"));
    }

    @Test
    void aShellThatIsNotThereFallsBackToTheDefaultRatherThanFailingToStart() {
        assertEquals(Optional.empty(), unix().command("tcsh"));
        assertEquals(Optional.empty(), unix().command("/nope/zsh"));
        assertTrue(unix().describe("tcsh").endsWith("(not found; your default is used)"));
    }

    @Test
    void onlyInstalledShellsAreOffered() {
        assertEquals(List.of("zsh", "bash", "fish", "sh"), unix().installedNames());
    }

    @Test
    void oneStepRunsTheAgentInsideTheShellThenLeavesALoginShell() {
        String bash = Path.of("/bin/bash").toString();
        assertEquals(Optional.of(List.of(bash, "-l", "-i", "-c", "claude --resume x; exec '" + bash + "' -l")),
                unix().oneStep("bash", "claude --resume x"));
        String fish = Path.of("/opt/homebrew/bin/fish").toString();
        assertEquals(Optional.of(List.of(fish, "-l", "-i", "-c", "codex; exec '" + fish + "' -l")),
                unix().oneStep("fish", "codex"));
    }

    @Test
    void shellsThatCannotDoItKeepTypingTheCommand() {
        assertEquals(Optional.empty(), unix().oneStep("/usr/bin/xonsh", "claude"), "unknown -c/exec semantics");
        assertEquals(Optional.empty(), unix().oneStep("bash", "  "), "a plain shell session has nothing to run");
        SessionShell windows = new SessionShell(true, Map.of("Path", "C:\\Windows\\System32"), path -> true);
        assertEquals(Optional.empty(), windows.oneStep("pwsh", "claude"));
    }

    @Test
    void wellKnownShellsReadAsTheirNameAndOthersAsTheirPath() {
        assertEquals("zsh", unix().displayName("/bin/zsh"));
        assertEquals("fish", unix().displayName("/opt/homebrew/bin/fish"));
        assertEquals("/usr/bin/xonsh", unix().displayName("/usr/bin/xonsh"));
    }

    @Test
    void quotingSurvivesQuotesInThePath() {
        assertEquals("'/Users/o'\\''brien/bin/zsh'", SessionShell.quote("/Users/o'brien/bin/zsh"));
    }

    @Test
    void windowsShellsGetFriendlyNamesAndNoLoginFlag() {
        SessionShell windows = new SessionShell(true, Map.of("Path", "C:\\Program Files\\PowerShell\\7"),
                path -> path.toString().endsWith("pwsh.exe"));
        assertEquals("PowerShell 7", windows.displayName("pwsh"));
        assertEquals("Command Prompt", windows.displayName("C:\\Windows\\System32\\cmd.exe"));
        assertEquals(Optional.of(List.of(Path.of("C:\\Program Files\\PowerShell\\7", "pwsh.exe").toString())),
                windows.command("pwsh"));
    }
}
