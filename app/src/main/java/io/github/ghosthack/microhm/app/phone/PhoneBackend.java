package io.github.ghosthack.microhm.app.phone;

import com.fasterxml.jackson.databind.JsonNode;
import io.github.ghosthack.microhm.app.control.SessionController;
import io.github.ghosthack.microhm.app.control.SessionController.EndedSession;
import io.github.ghosthack.microhm.app.control.SessionController.HistoryView;
import io.github.ghosthack.microhm.app.control.SessionController.ScreenView;
import io.github.ghosthack.microhm.app.control.SessionController.SessionSummary;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.mcp.ToolResult;
import io.github.ghosthack.microhm.app.state.SessionState;

import java.util.List;
import java.util.Optional;

/**
 * What the phone page can do with the sessions. In the app it is the session controller
 * behind the MCP tools ({@link #of}), so the phone sees and drives sessions exactly as an
 * agent does; tests give a fake.
 */
public interface PhoneBackend {

    /** The running sessions; throws when the daemon does not answer. */
    List<SessionSummary> sessions();

    /** One session's screen; empty once it has exited; throws with a message for the user
     * when no session matches. */
    Optional<ScreenView> screen(String session);

    /** Resizes {@code session}'s terminal, for every viewer. */
    void resize(String session, int columns, int rows);

    /** {@code session}'s screen with its styles, to draw in colour; empty when unavailable. */
    default Optional<SessionController.AnsiView> ansi(String session) {
        return Optional.empty();
    }

    /** Scrollback added after the first {@code since} lines (0: all still held); empty when
     * there is none to give. */
    Optional<HistoryView> history(String session, long since);

    /** Saved sessions that are not running, newest first. */
    List<EndedSession> ended();

    /** Starts an ended session again, resuming its conversation; returns its name. Throws
     * with a message for the user when it cannot. */
    String resume(String session);

    /** Why {@code session} cannot be closed right now, or empty when it can. */
    Optional<String> closeBlocker(String session);

    /** Closes {@code session} politely, as the window's Close does; refuses rather than
     * interrupting work. */
    PhoneCloser.Outcome close(String session);

    /** Runs {@code send}, {@code keys} or {@code spawn} with MCP-style arguments. */
    ToolResult call(String tool, JsonNode arguments);

    static PhoneBackend of(SessionController controller, PhoneCloser closer) {
        return new PhoneBackend() {
            /** The session's name, harness and state, as the closer needs them. */
            private ScreenView live(String session) {
                return controller.screen(session).orElseThrow(
                        () -> new IllegalStateException(session + " has already ended"));
            }

            @Override
            public Optional<String> closeBlocker(String session) {
                ScreenView view = live(session);
                return closer.blocker(view.name(), HarnessType.fromId(view.harness()),
                        SessionState.valueOf(view.state()));
            }

            @Override
            public PhoneCloser.Outcome close(String session) {
                ScreenView view = live(session);
                return closer.close(view.name(), HarnessType.fromId(view.harness()),
                        SessionState.valueOf(view.state()));
            }

            @Override
            public List<SessionSummary> sessions() {
                return controller.summaries();
            }

            @Override
            public Optional<ScreenView> screen(String session) {
                return controller.screen(session);
            }

            @Override
            public void resize(String session, int columns, int rows) {
                controller.resize(session, columns, rows);
            }

            @Override
            public Optional<SessionController.AnsiView> ansi(String session) {
                return controller.ansi(session);
            }

            @Override
            public Optional<HistoryView> history(String session, long since) {
                return controller.history(session, since);
            }

            @Override
            public List<EndedSession> ended() {
                return controller.ended();
            }

            @Override
            public String resume(String session) {
                return controller.resume(session);
            }

            @Override
            public ToolResult call(String tool, JsonNode arguments) {
                // no caller: the phone is not a session, so nothing is "your own session"
                // and a spawned session carries no spawned-by label
                return controller.call(null, tool, arguments);
            }
        };
    }
}
