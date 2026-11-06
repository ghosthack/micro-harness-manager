package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import io.github.ghosthack.microhm.app.host.SessionConnection;
import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.registry.RegistryPaths;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.session.SessionLabeller;
import io.github.ghosthack.microhm.app.session.SessionLauncher;
import io.github.ghosthack.microhm.app.state.Screen;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import javax.swing.SwingUtilities;
import java.awt.Component;
import java.awt.GraphicsEnvironment;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

/**
 * Drives a real {@link MainWindow} (never shown) over a fake host whose attach for one
 * session blocks until the test releases it. Pins the landing rule: a connection that
 * lands while another row is selected is cached but never shown — it must never cover
 * the terminal of whichever other session the user has selected meanwhile (keystrokes
 * must never land in the wrong harness). Needs a display: {@code MainWindow} is a
 * {@code JFrame}.
 */
final class MainWindowAttachLandingTest {

    private static final Duration WAIT = Duration.ofSeconds(10);
    private static final String A = "mhm-a";
    private static final String B = "mhm-b";

    @TempDir
    Path dir;

    private String previousRegistryOverride;
    private MainWindow window;

    @BeforeEach
    void pointSettingsAtTempDir() {
        // AppSettings resolves settings.properties beside the registry file
        previousRegistryOverride = System.getProperty(RegistryPaths.OVERRIDE_PROPERTY);
        System.setProperty(RegistryPaths.OVERRIDE_PROPERTY, dir.resolve("sessions.json").toString());
    }

    @AfterEach
    void tearDown() throws Exception {
        if (window != null) {
            SwingUtilities.invokeAndWait(window::shutdown);
        }
        if (previousRegistryOverride == null) {
            System.clearProperty(RegistryPaths.OVERRIDE_PROPERTY);
        } else {
            System.setProperty(RegistryPaths.OVERRIDE_PROPERTY, previousRegistryOverride);
        }
    }

    @Test
    void aSlowAttachLandingUnderAnotherSelectionNeverHidesItsTerminal() throws Exception {
        assumeFalse(GraphicsEnvironment.isHeadless(), "MainWindow is a JFrame");

        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        for (String name : List.of(A, B)) {
            registry.put(SessionEntry.newlyCreated(name, Files.createDirectories(dir.resolve(name)).toString(),
                    HarnessType.SHELL, null));
        }
        FakeSessionHost fake = new FakeSessionHost();
        fake.seedLiveSession(A);
        fake.seedLiveSession(B);
        BlockingAttachHost host = new BlockingAttachHost(fake, A);

        window = onEdt(() -> new MainWindow(registry, host,
                SessionLauncher.withoutMcp(registry, host, SessionLabeller.NONE),
                new McpService(McpService.NO_TOOLS), new SessionEvents()));

        // B selected and attached: its terminal is the visible card
        awaitOnEdt("the sidebar to list B", () -> window.selectSidebarRowForTesting(B));
        awaitOnEdt("B's attach to land", () -> window.terminalCardForTesting(B) != null);
        Component terminalB = onEdt(() -> window.terminalCardForTesting(B));
        assertSame(terminalB, onEdt(window::visibleCardForTesting));

        // A selected: its attach is dispatched and blocks; the user goes back to B
        assertTrue(onEdt(() -> window.selectSidebarRowForTesting(A)));
        host.awaitAttachStarted(A);
        assertTrue(onEdt(() -> window.hasAttachmentForTesting(A)));
        assertTrue(onEdt(() -> window.selectSidebarRowForTesting(B)));
        assertSame(terminalB, onEdt(window::visibleCardForTesting));

        // A's attach lands while B is selected: cached, but B's terminal is still showing
        host.releaseAttach(A);
        awaitOnEdt("A's attach to land", () -> window.terminalCardForTesting(A) != null);
        assertNotSame(terminalB, onEdt(() -> window.terminalCardForTesting(A)));
        assertSame(terminalB, onEdt(window::visibleCardForTesting),
                "a landing under another selection must not replace the selected session's terminal");
        assertNotNull(onEdt(() -> window.terminalCardForTesting(B)), "B's terminal was never evicted");
    }

    // ---- helpers

    private static <T> T onEdt(Callable<T> call) throws Exception {
        AtomicReference<T> result = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        SwingUtilities.invokeAndWait(() -> {
            try {
                result.set(call.call());
            } catch (Exception e) {
                failure.set(e);
            }
        });
        if (failure.get() != null) {
            throw failure.get();
        }
        return result.get();
    }

    /** Polls {@code condition} on the EDT until it holds; every poll also flushes
     * whatever the background executor has posted there in the meantime. */
    private static void awaitOnEdt(String what, BooleanSupplier condition) throws Exception {
        long deadline = System.nanoTime() + WAIT.toNanos();
        while (!onEdt(condition::getAsBoolean)) {
            if (System.nanoTime() > deadline) {
                fail("timed out waiting for " + what + " after " + WAIT);
            }
            Thread.sleep(25);
        }
    }

    /**
     * A {@link FakeSessionHost} whose {@link #attach} for {@code blockedSession} parks
     * until {@link #releaseAttach} — the fake's analogue of a slow daemon connect — and whose connections block on read until closed, so a landed
     * terminal stays alive (the fake's own connections end at once, which would make
     * the cached widget look dead on the next selection).
     */
    private static final class BlockingAttachHost implements SessionHost {
        private final FakeSessionHost delegate;
        private final String blockedSession;
        private final CountDownLatch started = new CountDownLatch(1);
        private final CountDownLatch release = new CountDownLatch(1);

        BlockingAttachHost(FakeSessionHost delegate, String blockedSession) {
            this.delegate = delegate;
            this.blockedSession = blockedSession;
        }

        void awaitAttachStarted(String session) throws InterruptedException {
            assertEquals(blockedSession, session);
            assertTrue(started.await(WAIT.toMillis(), java.util.concurrent.TimeUnit.MILLISECONDS),
                    "the attach for " + session + " was never dispatched");
        }

        void releaseAttach(String session) {
            assertEquals(blockedSession, session);
            release.countDown();
        }

        @Override
        public SessionConnection attach(String session, int columns, int rows) {
            delegate.attach(session, columns, rows); // records the call, checks liveness
            if (session.equals(blockedSession)) {
                started.countDown();
                try {
                    release.await();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            return new HeldConnection(session);
        }

        @Override
        public boolean hasSession(String session) {
            return delegate.hasSession(session);
        }

        @Override
        public List<String> listSessions() {
            return delegate.listSessions();
        }

        @Override
        public void newSession(String session, Path workdir, int columns, int rows) {
            delegate.newSession(session, workdir, columns, rows);
        }

        @Override
        public void sendKeys(String session, String command) {
            delegate.sendKeys(session, command);
        }

        @Override
        public void killSession(String session) {
            delegate.killSession(session);
        }

        @Override
        public Screen capture(String session) {
            return delegate.capture(session);
        }
    }

    /** Alive, producing nothing, until closed; then reads return end-of-stream. */
    private static final class HeldConnection implements SessionConnection {
        private final String name;
        private final CountDownLatch closed = new CountDownLatch(1);

        HeldConnection(String name) {
            this.name = name;
        }

        @Override
        public String name() {
            return name;
        }

        @Override
        public int read(byte[] buf, int off, int len) {
            try {
                closed.await();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            return -1;
        }

        @Override
        public void write(byte[] bytes) {
        }

        @Override
        public void resize(int columns, int rows) {
        }

        @Override
        public boolean isAlive() {
            return closed.getCount() > 0;
        }

        @Override
        public int waitFor() throws InterruptedException {
            closed.await();
            return 0;
        }

        @Override
        public void close() {
            closed.countDown();
        }
    }
}
