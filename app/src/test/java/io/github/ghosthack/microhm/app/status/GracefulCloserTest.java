package io.github.ghosthack.microhm.app.status;

import io.github.ghosthack.microhm.app.harness.ClaudeCodePlugin;
import io.github.ghosthack.microhm.app.harness.CodexPlugin;
import io.github.ghosthack.microhm.app.harness.CursorAgentPlugin;
import io.github.ghosthack.microhm.app.harness.HarnessPlugin;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.harness.ShellPlugin;
import io.github.ghosthack.microhm.app.state.SessionState;
import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The graceful-close decision tree, driven through {@link FakeSessionHost} with scripted pane
 * reactions ({@code onSendKeys}). Timeouts are tiny real durations — the timeout
 * fixtures wait them out for real, which at 50ms is cheaper than injecting a clock into
 * what is otherwise a sleep-and-poll loop.
 */
final class GracefulCloserTest {

    private static final String SESSION = "mhm-proj";

    private final FakeSessionHost host = new FakeSessionHost();
    private final GracefulCloser closer = new GracefulCloser(host,
            Duration.ofMillis(1), Duration.ofMillis(50), Duration.ofMillis(50));

    private GracefulCloser.Result close(HarnessPlugin plugin, SessionState lastPolled) {
        return closer.close(SESSION, plugin, lastPolled);
    }

    @Test
    void idleHarnessQuitsThenShellExitsThenSessionIsClosed() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "claude");
        host.onSendKeys = command -> {
            if (command.equals(SESSION + ": /exit")) {
                host.screen(SESSION, """
                        Resume this session with:
                        claude --resume fd626959-efe0-414b-a3f5-9261602748ed
                        sample@host proj %
                        """, "zsh"); // harness hands back the shell
            } else if (command.equals(SESSION + ": exit")) {
                host.endSession(SESSION);
            }
        };
        GracefulCloser.Result result = close(new ClaudeCodePlugin(), SessionState.IDLE);
        assertEquals(GracefulCloser.Outcome.CLOSED, result.outcome());
        assertEquals("fd626959-efe0-414b-a3f5-9261602748ed", result.harnessSessionId());
        assertEquals(List.of(SESSION + ": /exit", SESSION + ": exit"), host.sentCommands);
    }

    @Test
    void codexExitReceiptSurvivesAShellExitTimeout() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "› Ask Codex to do anything", "codex");
        host.onSendKeys = command -> {
            if (command.equals(SESSION + ": /quit")) {
                host.screen(SESSION, """
                        To continue this session, run codex resume 0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f
                        sample@host proj %
                        """, "zsh");
            }
            // Deliberately ignore shell exit: metadata must not be tied to full closure.
        };

        GracefulCloser.Result result = close(new CodexPlugin(), SessionState.IDLE);

        assertEquals(GracefulCloser.Outcome.EXIT_TIMEOUT, result.outcome());
        assertEquals("0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f", result.harnessSessionId());
    }

    @Test
    void cursorAgentQuitsAndReturnsItsResumeBreadcrumb() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "> ", "cursor-agent");
        host.onSendKeys = command -> {
            if (command.equals(SESSION + ": /quit")) {
                host.screen(SESSION, """
                        To resume this session: agent --resume=bc-abc123
                        sample@host proj %
                        """, "zsh");
            } else if (command.equals(SESSION + ": exit")) {
                host.endSession(SESSION);
            }
        };

        GracefulCloser.Result result = close(new CursorAgentPlugin(), SessionState.IDLE);

        assertEquals(GracefulCloser.Outcome.CLOSED, result.outcome());
        assertEquals("bc-abc123", result.harnessSessionId());
        assertEquals(List.of(SESSION + ": /quit", SESSION + ": exit"), host.sentCommands);
    }

    /** The shell harness (and a harness that already died back to its shell) needs no
     * quit stage — a bare prompt goes straight to {@code exit}. */
    @Test
    void shellAtPromptSkipsTheQuitStage() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "sample@host proj %", "zsh");
        host.onSendKeys = command -> host.endSession(SESSION);
        GracefulCloser.Result result = close(new ShellPlugin(), null); // never-polled is fine at a prompt
        assertEquals(GracefulCloser.Outcome.CLOSED, result.outcome());
        assertEquals(List.of(SESSION + ": exit"), host.sentCommands);
    }

    @Test
    void workingSessionIsRefusedUntouched() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "esc to interrupt", "claude");
        GracefulCloser.Result result = close(new ClaudeCodePlugin(), SessionState.WORKING);
        assertEquals(GracefulCloser.Outcome.BUSY_STATE, result.outcome());
        assertTrue(host.sentCommands.isEmpty(), "a refused close must send nothing");
    }

    @Test
    void waitingForInputIsRefusedUntouched() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "Do you want to make this edit?", "claude");
        assertEquals(GracefulCloser.Outcome.BUSY_STATE,
                close(new ClaudeCodePlugin(), SessionState.WAITING_FOR_INPUT).outcome());
        assertTrue(host.sentCommands.isEmpty());
    }

    @Test
    void preflightReturnsKnownBusyStateWithoutSendingInput() {
        host.seedLiveSession(SESSION);

        GracefulCloser.Result blocker = closer.preflight(
                SESSION, new ClaudeCodePlugin(), SessionState.WORKING).orElseThrow();

        assertEquals(GracefulCloser.Outcome.BUSY_STATE, blocker.outcome());
        assertTrue(host.sentCommands.isEmpty());
    }

    @Test
    void preflightAllowsIdleHarnessWithoutSendingItsQuitCommand() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "claude");

        assertFalse(closer.preflight(
                SESSION, new ClaudeCodePlugin(), SessionState.IDLE).isPresent());
        assertTrue(host.sentCommands.isEmpty());
    }

    /** The caffeinate case: quiet enough to poll as IDLE forever, but killing it would
     * kill work in flight — only the fresh foreground check can catch it. */
    @Test
    void foregroundProgramIsRefusedByName() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "", "caffeinate");
        GracefulCloser.Result result = close(new ShellPlugin(), SessionState.IDLE);
        assertEquals(GracefulCloser.Outcome.BUSY_FOREGROUND, result.outcome());
        assertEquals("caffeinate", result.detail());
        assertTrue(host.sentCommands.isEmpty());
    }

    @Test
    void preflightReturnsForegroundBlockerWithoutSendingInput() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "", "caffeinate");

        GracefulCloser.Result blocker = closer.preflight(
                SESSION, new ShellPlugin(), SessionState.IDLE).orElseThrow();

        assertEquals(GracefulCloser.Outcome.BUSY_FOREGROUND, blocker.outcome());
        assertEquals("caffeinate", blocker.detail());
        assertTrue(host.sentCommands.isEmpty());
    }

    /** Never type quit text into a harness whose status has never been polled — the
     * whole point of the busy checks is not to submit into a possibly-running turn. */
    @Test
    void unpolledHarnessIsRefused() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "claude");
        assertEquals(GracefulCloser.Outcome.BUSY_STATE,
                close(new ClaudeCodePlugin(), null).outcome());
        assertTrue(host.sentCommands.isEmpty());
    }

    /** A future plugin without grounded quit syntax must still be refused rather than
     * having guessed text typed into its conversation. */
    @Test
    void harnessWithoutQuitSyntaxIsRefused() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "mystery-harness");
        HarnessPlugin unknown = new HarnessPlugin() {
            @Override
            public HarnessType type() {
                return HarnessType.CURSOR_AGENT;
            }

            @Override
            public String launchCommand() {
                return "mystery-harness";
            }

            @Override
            public String processName() {
                return "mystery-harness";
            }
        };
        GracefulCloser.Result result = close(unknown, SessionState.IDLE);
        assertEquals(GracefulCloser.Outcome.NO_QUIT_SYNTAX, result.outcome());
        assertTrue(host.sentCommands.isEmpty());
    }

    @Test
    void harnessThatIgnoresItsQuitCommandTimesOutWithoutCleanup() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "claude"); // never reacts to /exit
        GracefulCloser.Result result = close(new ClaudeCodePlugin(), SessionState.IDLE);
        assertEquals(GracefulCloser.Outcome.QUIT_TIMEOUT, result.outcome());
        assertEquals(List.of(SESSION + ": /exit"), host.sentCommands);
        assertTrue(host.hasSession(SESSION), "a timed-out close must leave the session alone");
    }

    @Test
    void shellThatIgnoresExitTimesOut() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "sample@host proj %", "zsh"); // never reacts to exit
        assertEquals(GracefulCloser.Outcome.EXIT_TIMEOUT,
                close(new ShellPlugin(), SessionState.IDLE).outcome());
        assertTrue(host.hasSession(SESSION));
    }

    @Test
    void alreadyGoneSessionJustReportsGone() {
        // never seeded: capture reports a dead pane
        assertEquals(GracefulCloser.Outcome.ALREADY_GONE,
                close(new ClaudeCodePlugin(), SessionState.IDLE).outcome());
        assertTrue(host.sentCommands.isEmpty());
    }

    /** A harness running as the session's root process takes the whole session with it on
     * quit — the exit stage must notice the session is gone instead of sending
     * {@code exit} into the void (FakeSessionHost would throw; the daemon would error). */
    @Test
    void sessionCollapsingWithTheHarnessSkipsTheExitStage() {
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "claude");
        host.onSendKeys = command -> host.endSession(SESSION); // /exit ends everything
        GracefulCloser.Result result = close(new ClaudeCodePlugin(), SessionState.IDLE);
        assertEquals(GracefulCloser.Outcome.CLOSED, result.outcome());
        assertEquals(List.of(SESSION + ": /exit"), host.sentCommands);
    }
}
