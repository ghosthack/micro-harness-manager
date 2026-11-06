package io.github.ghosthack.microhm.app.status;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import io.github.ghosthack.microhm.app.host.SessionConnection;
import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.host.SessionHostException;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.state.Classification;
import io.github.ghosthack.microhm.app.state.Confidence;
import io.github.ghosthack.microhm.app.state.Screen;
import io.github.ghosthack.microhm.app.state.SessionState;
import io.github.ghosthack.microhm.app.testutil.MutableClock;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Exercises the poll -> publish wiring against {@link FakeSessionHost}, with both the
 * "background" and "result" executors running same-thread so results are visible
 * immediately (no EDT involved — that part is production-only wiring, not tested here).
 */
final class SessionStatusPollerTest {

    private static final Duration SHORT = Duration.ofSeconds(5);
    private static final Duration LONG = Duration.ofSeconds(20);

    private static SessionEntry entry(String sessionName, HarnessType type) {
        return new SessionEntry(sessionName, "/Users/x/Projects/foo", type, null, Instant.EPOCH);
    }

    @Test
    void firstSnapshotsRemainPendingInsteadOfPresentingUnknownAsWorking() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.seedLiveSession("mhm-b");
        host.screen("mhm-a", "working output");
        host.screen("mhm-b", "more output");

        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run,
                new MutableClock(), SHORT, LONG);
        Map<String, SessionStatusPoller.PollResult> results = new HashMap<>();
        poller.pollAll(List.of(entry("mhm-a", HarnessType.CLAUDE_CODE), entry("mhm-b", HarnessType.CURSOR_AGENT)),
                results::put);

        assertEquals(2, results.size());
        assertTrue(results.containsKey("mhm-a"));
        assertTrue(results.containsKey("mhm-b"));
        assertEquals(SessionState.WORKING, results.get("mhm-a").classification().state());
        assertFalse(results.get("mhm-a").stateConfirmed());
        assertFalse(results.get("mhm-b").stateConfirmed());
    }

    @Test
    void quiescenceAccumulatesAcrossPolls() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "checked off item 3\n❯ ");
        MutableClock clock = new MutableClock();

        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run, clock, SHORT, LONG);
        Map<String, SessionStatusPoller.PollResult> results = new HashMap<>();
        List<SessionEntry> sessions = List.of(entry("mhm-a", HarnessType.CURSOR_AGENT));

        poller.pollAll(sessions, results::put);
        assertFalse(results.get("mhm-a").stateConfirmed());

        clock.advance(Duration.ofSeconds(3));
        poller.pollAll(sessions, results::put);
        assertFalse(results.get("mhm-a").stateConfirmed());
        assertEquals(Confidence.MEDIUM, results.get("mhm-a").classification().confidence());

        clock.advance(Duration.ofSeconds(3));
        poller.pollAll(sessions, results::put);
        assertTrue(results.get("mhm-a").stateConfirmed());
        assertEquals(SessionState.IDLE, results.get("mhm-a").classification().state());
    }

    @Test
    void detectorStateIsIndependentPerSession() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.seedLiveSession("mhm-b");
        host.screen("mhm-a", "same text");
        host.screen("mhm-b", "same text");
        MutableClock clock = new MutableClock();

        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run, clock, SHORT, LONG);
        Map<String, Classification> results = new HashMap<>();
        List<SessionEntry> sessions = List.of(
                entry("mhm-a", HarnessType.CLAUDE_CODE), entry("mhm-b", HarnessType.CLAUDE_CODE));

        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        clock.advance(Duration.ofSeconds(6));
        // mhm-b's text changes, mhm-a's doesn't — they must classify independently
        host.screen("mhm-b", "different text now");
        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));

        assertEquals(SessionState.IDLE, results.get("mhm-a").state());
        assertEquals(SessionState.WORKING, results.get("mhm-b").state());
    }

    @Test
    void aFailingSessionDoesNotBlockOthersOrPublishAResultForItself() {
        SessionHost flaky = new SessionHost() {
            @Override
            public boolean hasSession(String session) {
                return true;
            }

            @Override
            public List<String> listSessions() {
                return List.of("mhm-good", "mhm-bad");
            }

            @Override
            public void newSession(String session, Path workdir, int columns, int rows) {
            }

            @Override
            public void sendKeys(String session, String command) {
            }

            @Override
            public void killSession(String session) {
            }

            @Override
            public Screen capture(String session) {
                if (session.equals("mhm-bad")) {
                    throw new SessionHostException("simulated daemon failure");
                }
                return new Screen("output", false, Instant.EPOCH, "");
            }

            @Override
            public SessionConnection attach(String session, int columns, int rows) {
                throw new SessionHostException("not attachable in this test");
            }
        };

        SessionStatusPoller poller = new SessionStatusPoller(flaky, Runnable::run, Runnable::run,
                new MutableClock(), SHORT, LONG);
        Map<String, Classification> results = new HashMap<>();
        poller.pollAll(List.of(entry("mhm-good", HarnessType.CLAUDE_CODE), entry("mhm-bad", HarnessType.CLAUDE_CODE)),
                (n, r) -> results.put(n, r.classification()));

        assertEquals(1, results.size());
        assertTrue(results.containsKey("mhm-good"));
    }

    @Test
    void forgetDropsDetectorSoANewLifecycleStartsFresh() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "same text");
        MutableClock clock = new MutableClock();

        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run, clock, SHORT, LONG);
        Map<String, Classification> results = new HashMap<>();
        List<SessionEntry> sessions = List.of(entry("mhm-a", HarnessType.CLAUDE_CODE));

        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        clock.advance(Duration.ofSeconds(6));
        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        assertEquals(SessionState.IDLE, results.get("mhm-a").state());

        poller.forget("mhm-a");
        Map<String, SessionStatusPoller.PollResult> freshResults = new HashMap<>();
        poller.pollAll(sessions, freshResults::put);
        // A fresh detector has no comparison baseline, so its provisional WORKING
        // classification must not be presented as a confirmed green state.
        assertFalse(freshResults.get("mhm-a").stateConfirmed());
    }

    /** Background "executor" that queues tasks for the test to run by hand, so overlap
     * and forget/poll interleavings can be exercised deterministically. */
    private static final class ManualExecutor implements java.util.concurrent.Executor {
        final java.util.ArrayDeque<Runnable> queued = new java.util.ArrayDeque<>();

        @Override
        public void execute(Runnable task) {
            queued.add(task);
        }

        void runAll() {
            while (!queued.isEmpty()) {
                queued.poll().run();
            }
        }
    }

    @Test
    void pollsSerializePerSessionInsteadOfStacking() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "output");
        ManualExecutor background = new ManualExecutor();

        SessionStatusPoller poller = new SessionStatusPoller(host, background, Runnable::run,
                new MutableClock(), SHORT, LONG);
        Map<String, Classification> results = new HashMap<>();
        List<SessionEntry> sessions = List.of(entry("mhm-a", HarnessType.CLAUDE_CODE));

        // three ticks land while the first capture is still "in flight" (unrun)
        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        assertEquals(1, background.queued.size()); // ticks 2 and 3 skipped, not stacked

        background.runAll();
        assertEquals(1, results.size());

        // with the first task done, the next tick polls again
        poller.pollAll(sessions, (n, r) -> results.put(n, r.classification()));
        assertEquals(1, background.queued.size());
    }

    @Test
    void forgetDuringAnInFlightPollDropsTheResultAndTheStaleDetector() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "old lifecycle output");
        ManualExecutor background = new ManualExecutor();

        SessionStatusPoller poller = new SessionStatusPoller(host, background, Runnable::run,
                new MutableClock(), SHORT, LONG);
        Map<String, Classification> results = new HashMap<>();

        poller.pollAll(List.of(entry("mhm-a", HarnessType.CLAUDE_CODE)), (n, r) -> results.put(n, r.classification()));
        poller.forget("mhm-a"); // lifecycle ends while the capture task is still queued
        background.runAll();

        assertTrue(results.isEmpty(), "a poll of the ended lifecycle must not publish");
        assertTrue(!poller.hasDetector("mhm-a"),
                "the ended lifecycle's detector must not be resurrected");
    }

    @Test
    void forgetWhileTheResultSitsInTheDispatchQueueDropsIt() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "old lifecycle output");
        ManualExecutor background = new ManualExecutor();
        ManualExecutor dispatcher = new ManualExecutor();

        SessionStatusPoller poller = new SessionStatusPoller(host, background, dispatcher,
                new MutableClock(), SHORT, LONG);
        Map<String, Classification> results = new HashMap<>();

        poller.pollAll(List.of(entry("mhm-a", HarnessType.CLAUDE_CODE)), (n, r) -> results.put(n, r.classification()));
        background.runAll(); // capture+classify done; the result now sits in the dispatch queue
        poller.forget("mhm-a"); // production equivalent: forget() on the EDT before the result task runs
        dispatcher.runAll();

        assertTrue(results.isEmpty(), "a result dispatched after forget() must not be published");
    }

    @Test
    void forgetBetweenCaptureAndPublishEvictsTheResurrectedDetector() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "old lifecycle output");

        // Fires forget() from inside StateDetector.classify (which reads the injected
        // clock) — i.e. after the capture-time generation check passed and after
        // computeIfAbsent re-inserted a detector, the exact window the conditional
        // self-eviction exists for.
        SessionStatusPoller[] pollerRef = new SessionStatusPoller[1];
        boolean[] fired = new boolean[1];
        Clock hookClock = new Clock() {
            private final Instant now = Instant.parse("2026-08-17T00:00:00Z");

            @Override
            public Instant instant() {
                if (!fired[0] && pollerRef[0] != null) {
                    fired[0] = true;
                    pollerRef[0].forget("mhm-a");
                }
                return now;
            }

            @Override
            public java.time.ZoneId getZone() {
                return java.time.ZoneOffset.UTC;
            }

            @Override
            public Clock withZone(java.time.ZoneId zone) {
                return this;
            }
        };

        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run,
                hookClock, SHORT, LONG);
        pollerRef[0] = poller;
        Map<String, Classification> results = new HashMap<>();
        poller.pollAll(List.of(entry("mhm-a", HarnessType.CLAUDE_CODE)), (n, r) -> results.put(n, r.classification()));

        assertTrue(fired[0], "the hook must actually have run inside classify");
        assertTrue(results.isEmpty(), "a classification of the ended lifecycle must not be published");
        assertTrue(!poller.hasDetector("mhm-a"),
                "the detector re-inserted mid-poll must be evicted, not resurrected");
    }

    @Test
    void publishesThePaneTitleAlongsideTheClassification() {
        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "output");
        host.paneTitle("mhm-a", "✳ refactor the poller");

        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run,
                new MutableClock(), SHORT, LONG);
        Map<String, SessionStatusPoller.PollResult> results = new HashMap<>();
        poller.pollAll(List.of(entry("mhm-a", HarnessType.CLAUDE_CODE)), results::put);

        assertEquals("✳ refactor the poller", results.get("mhm-a").paneTitle());
        assertEquals(SessionState.WORKING, results.get("mhm-a").classification().state());
        assertFalse(results.get("mhm-a").stateConfirmed());
    }

    @Test
    void codexSavedRenameOverridesItsGenericOscTitle(@TempDir Path codexHome) throws Exception {
        String id = "01a0299e-d978-7651-871e-e746fedd1186";
        Path rollout = codexHome.resolve("rollout-" + id + ".jsonl");
        Files.writeString(rollout, "");
        Files.writeString(codexHome.resolve("session_index.jsonl"),
                "{\"id\":\"" + id + "\",\"thread_name\":\"saved Codex name\"}\n");

        FakeSessionHost host = new FakeSessionHost();
        host.seedLiveSession("mhm-a");
        host.screen("mhm-a", "output");
        host.paneProcessId("mhm-a", 42);
        host.paneTitle("mhm-a", "⠼ project-directory");
        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(rollout));
        SessionStatusPoller poller = new SessionStatusPoller(host, Runnable::run, Runnable::run,
                new MutableClock(), SHORT, LONG, resolver);
        Map<String, SessionStatusPoller.PollResult> results = new HashMap<>();

        poller.pollAll(List.of(entry("mhm-a", HarnessType.CODEX)), results::put);

        assertEquals("saved Codex name", results.get("mhm-a").paneTitle());
    }
}
