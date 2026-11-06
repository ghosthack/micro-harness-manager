package io.github.ghosthack.microhm.app.host;

import io.github.ghosthack.microhm.app.state.Screen;

import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * In-memory session host: the test sets up live sessions and screens directly; no
 * process is ever spawned. Per-session screen state (keyed the same way real sessions
 * are) so a test can drive several sessions independently.
 */
public final class FakeSessionHost implements SessionHost {

    private final Set<String> sessions = new LinkedHashSet<>();
    private final List<String> killed = new ArrayList<>();
    public final List<String> newSessionCalls = new ArrayList<>();
    public final List<String> sentCommands = new ArrayList<>();
    /** Every {@link #capture} call, by session name. */
    public final List<String> captureCalls = new ArrayList<>();
    /** Every {@link #attach} call as {@code session columnsxrows}. */
    public final List<String> attachCalls = new ArrayList<>();
    /** When set, {@link #listSessions} and {@link #hasSession} throw it — the fake's
     * analogue of a substrate whose binary or daemon is absent. */
    private RuntimeException listFailure;

    private final Map<String, Screen> currentScreen = new HashMap<>();
    private final Map<String, Deque<Screen>> captureQueue = new HashMap<>();

    /** Seeds a live session without going through {@link #newSession}. */
    public void seedLiveSession(String session) {
        sessions.add(session);
    }

    /** Makes every list/has probe fail with {@code failure} until called with null. */
    public void failListing(RuntimeException failure) {
        this.listFailure = failure;
    }

    public List<String> killedSessions() {
        return killed;
    }

    /** Sets what {@link #capture} returns for {@code session} until changed again. */
    public void screen(String session, String text) {
        screen(session, text, currentScreen.getOrDefault(session, blank()).foregroundCommand());
    }

    public void screen(String session, String text, String foregroundCommand) {
        // title survives text updates, same as the daemon (OSC titles outlive redraws)
        Screen current = currentScreen.getOrDefault(session, blank());
        currentScreen.put(session, new Screen(text, false, Instant.EPOCH, foregroundCommand,
                current.paneProcessId(), current.paneTitle()));
    }

    /** Sets the pane title reported with subsequent captures — the fake's equivalent of
     * the program in the pane setting an OSC title (e.g. Claude Code's /rename). */
    public void paneTitle(String session, String title) {
        Screen current = currentScreen.getOrDefault(session, blank());
        currentScreen.put(session, new Screen(current.text(), current.paneDead(),
                current.capturedAt(), current.foregroundCommand(), current.paneProcessId(), title));
    }

    /** Sets the pane shell PID used for harness-specific metadata discovery. */
    public void paneProcessId(String session, long processId) {
        Screen current = currentScreen.getOrDefault(session, blank());
        currentScreen.put(session, new Screen(current.text(), current.paneDead(),
                current.capturedAt(), current.foregroundCommand(), processId, current.paneTitle()));
    }

    /** Queues a one-shot capture result, consumed before falling back to {@link #screen}. */
    public void queueCapture(String session, String text) {
        captureQueue.computeIfAbsent(session, k -> new ArrayDeque<>())
                .add(new Screen(text, false, Instant.EPOCH, ""));
    }

    /** The session's process exited on its own — unlike {@link #killSession}, nothing
     * is recorded as killed. The fake's analogue of a shell reaching {@code exit}. */
    public void endSession(String session) {
        sessions.remove(session);
    }

    /**
     * Invoked with {@code "session: command"} after each successful {@link #sendKeys} —
     * lets a test script the pane's reaction to input, e.g. the harness handing the
     * pane back to the shell in response to its quit command.
     */
    public java.util.function.Consumer<String> onSendKeys = command -> {
    };

    /** Runs on every {@link #hasSession} once its answer is decided — a test can stall a
     * probe here, as a slow daemon round trip would. */
    public volatile java.util.function.Consumer<String> onHasSession = session -> {
    };

    public void paneDies(String session) {
        currentScreen.put(session, new Screen("", true, Instant.EPOCH, ""));
    }

    private static Screen blank() {
        return new Screen("", false, Instant.EPOCH, "");
    }

    private void requireLive(String session) {
        if (!sessions.contains(session)) {
            throw new SessionHostException("no such session: " + session);
        }
    }

    @Override
    public boolean hasSession(String session) {
        if (listFailure != null) {
            throw listFailure;
        }
        boolean live = sessions.contains(session);
        onHasSession.accept(session); // after answering, so a stalled probe's answer can go stale
        return live;
    }

    @Override
    public List<String> listSessions() {
        if (listFailure != null) {
            throw listFailure;
        }
        return List.copyOf(sessions);
    }

    @Override
    public void newSession(String session, Path workdir, int columns, int rows) {
        sessions.add(session);
        newSessionCalls.add(session + " " + workdir + " " + columns + "x" + rows);
    }

    @Override
    public void sendKeys(String session, String command) {
        requireLive(session);
        sentCommands.add(session + ": " + command);
        onSendKeys.accept(session + ": " + command);
    }

    @Override
    public void killSession(String session) {
        sessions.remove(session);
        killed.add(session);
    }

    @Override
    public Screen capture(String session) {
        captureCalls.add(session);
        if (!sessions.contains(session)) {
            return new Screen("", true, Instant.EPOCH, "");
        }
        Deque<Screen> queue = captureQueue.get(session);
        if (queue != null && !queue.isEmpty()) {
            return queue.poll();
        }
        return currentScreen.getOrDefault(session, blank());
    }

    /** An in-memory connection that has already reached end-of-stream; enough to prove
     * the attach lifecycle, since no test renders it. */
    @Override
    public SessionConnection attach(String session, int columns, int rows) {
        requireLive(session);
        attachCalls.add(session + " " + columns + "x" + rows);
        return new SessionConnection() {
            private boolean open = true;

            @Override
            public String name() {
                return session;
            }

            @Override
            public int read(byte[] buf, int off, int len) {
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
                return open;
            }

            @Override
            public int waitFor() {
                return 0;
            }

            @Override
            public void close() {
                open = false;
            }
        };
    }
}
