package io.github.ghosthack.microhm.app.phone;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.state.SessionState;
import io.github.ghosthack.microhm.app.status.GracefulCloser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The phone's close over the window's graceful closer, on a fake host. */
final class PhoneCloserTest {

    private static final String SESSION = "mhm-proj";

    @TempDir
    Path dir;

    private final FakeSessionHost host = new FakeSessionHost();
    private final SessionEvents events = new SessionEvents();
    private final List<String> runEnded = new ArrayList<>();

    private PhoneCloser closer(SessionRegistry registry) {
        events.addSessionRunEndedListener(runEnded::add);
        return new PhoneCloser(new GracefulCloser(host, Duration.ofMillis(1), Duration.ofMillis(50),
                Duration.ofMillis(50)), registry, events);
    }

    @Test
    void closesAnIdleAgentKeepsItsConversationAndTellsTheWindow() {
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        registry.put(SessionEntry.newlyCreated(SESSION, "/proj", HarnessType.CLAUDE_CODE, null));
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "❯ ", "claude");
        host.onSendKeys = command -> {
            if (command.equals(SESSION + ": /exit")) {
                host.screen(SESSION, """
                        Resume this session with:
                        claude --resume fd626959-efe0-414b-a3f5-9261602748ed
                        sample@host proj %
                        """, "zsh");
            } else if (command.equals(SESSION + ": exit")) {
                host.endSession(SESSION);
            }
        };
        PhoneCloser closer = closer(registry);

        assertEquals(Optional.empty(), closer.blocker(SESSION, HarnessType.CLAUDE_CODE, SessionState.IDLE));
        PhoneCloser.Outcome outcome = closer.close(SESSION, HarnessType.CLAUDE_CODE, SessionState.IDLE);

        assertTrue(outcome.closed());
        assertEquals("fd626959-efe0-414b-a3f5-9261602748ed",
                registry.find(SESSION).orElseThrow().harnessSessionId());
        assertEquals(List.of(SESSION), runEnded);
    }

    @Test
    void refusesAWorkingAgentWithoutTypingAnything() {
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "✻ Thinking… (esc to interrupt)", "claude");
        PhoneCloser closer = closer(registry);

        assertEquals(Optional.of("It's still working. Close it once it's done."),
                closer.blocker(SESSION, HarnessType.CLAUDE_CODE, SessionState.WORKING));
        PhoneCloser.Outcome outcome = closer.close(SESSION, HarnessType.CLAUDE_CODE, SessionState.WORKING);
        assertFalse(outcome.closed());
        assertEquals("It's still working. Close it once it's done.", outcome.message());
        assertTrue(host.sentCommands.isEmpty());
        assertTrue(runEnded.isEmpty());
    }

    @Test
    void namesAProgramStillRunningInFront() {
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        host.seedLiveSession(SESSION);
        host.screen(SESSION, "", "vim");
        assertEquals(Optional.of("'vim' is still running in it. Stop that first."),
                closer(registry).blocker(SESSION, HarnessType.SHELL, SessionState.IDLE));
    }
}
