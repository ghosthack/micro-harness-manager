package io.github.ghosthack.microhm.app.host;

import io.github.ghosthack.microhm.app.state.Screen;

import java.nio.file.Path;
import java.util.List;

/**
 * The substrate that hosts named sessions — the app's session daemon. This is the seam
 * the rest of the app talks through: status polling, graceful close, reconciliation and
 * the terminal widget only ever call {@code SessionHost.<method>(sessionName, ...)}, so
 * tests run them against an in-memory fake. The one production implementation is
 * {@code daemon.SessionServerHost}.
 *
 * <p>"No server running" semantics: {@link #listSessions} is empty, {@link #hasSession}
 * is false, {@link #capture} reports a dead pane, {@link #killSession} returns normally
 * (already gone); {@link #sendKeys} and {@link #attach} throw
 * {@link SessionHostException}. Only {@link #newSession} may start a server.
 */
public interface SessionHost {

    boolean hasSession(String session);

    /** Names of all live sessions. */
    List<String> listSessions();

    /** Creates a detached session running the default shell in {@code workdir}. */
    void newSession(String session, Path workdir, int columns, int rows);

    /** Sends {@code command} literally to the session, pauses 400ms, then Enter — TUIs
     * with paste detection treat a CR arriving within milliseconds of the text as a
     * literal newline, not a submit. */
    void sendKeys(String session, String command);

    /** Kills the session outright (and whatever it's running). No-op if already gone. */
    void killSession(String session);

    /**
     * Captures the rendered screen for status polling. A missing session or dead pane
     * yields {@code paneDead=true}. Read-only — never attaches a client. The
     * {@link Screen} contract: visible text trimmed per line and {@code \n}-joined, the
     * foreground process's basename, the shell PID, and the last OSC title (empty when
     * never set).
     */
    Screen capture(String session);

    /**
     * Opens a live connection at the given size. May block (daemon connect) and is
     * therefore never called on the EDT.
     */
    SessionConnection attach(String session, int columns, int rows);
}
