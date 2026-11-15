package io.github.ghosthack.microhm.app.phone;

import io.github.ghosthack.microhm.app.harness.HarnessPlugins;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.host.SessionHostException;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.state.SessionState;
import io.github.ghosthack.microhm.app.status.GracefulCloser;

import java.time.Duration;
import java.util.Objects;
import java.util.Optional;

/**
 * Close for the phone page: the window's polite close ({@link GracefulCloser}), with its
 * refusals. It never closes a session whose agent is working or waiting for you, or that
 * has a program running in front; otherwise it asks the agent to quit, then the shell to
 * exit, and keeps the conversation's id so Resume picks it up again.
 */
public final class PhoneCloser {

    /** {@code message} explains a refusal or a close that did not finish. */
    public record Outcome(boolean closed, String message) {
    }

    private final GracefulCloser closer;
    private final SessionRegistry registry;
    private final SessionEvents events;

    public PhoneCloser(SessionHost host, SessionRegistry registry, SessionEvents events) {
        this(new GracefulCloser(host, Duration.ofMillis(250), Duration.ofSeconds(10), Duration.ofSeconds(5)),
                registry, events);
    }

    PhoneCloser(GracefulCloser closer, SessionRegistry registry, SessionEvents events) {
        this.closer = Objects.requireNonNull(closer, "closer");
        this.registry = Objects.requireNonNull(registry, "registry");
        this.events = Objects.requireNonNull(events, "events");
    }

    /** Why {@code session} cannot be closed now, or empty when it can (nothing is sent). */
    public Optional<String> blocker(String session, HarnessType harness, SessionState state) {
        try {
            return closer.preflight(session, HarnessPlugins.of(harness), state)
                    .filter(r -> r.outcome() != GracefulCloser.Outcome.ALREADY_GONE)
                    .map(r -> explain(r, state));
        } catch (SessionHostException e) {
            return Optional.of("Couldn't check it: " + e.getMessage());
        }
    }

    public Outcome close(String session, HarnessType harness, SessionState state) {
        GracefulCloser.Result result;
        try {
            result = closer.close(session, HarnessPlugins.of(harness), state);
        } catch (SessionHostException e) {
            return new Outcome(false, "Couldn't close it: " + e.getMessage());
        }
        result.harnessSessionIdOpt().ifPresent(id -> registry.recordHarnessSessionId(session, id));
        boolean closed = result.outcome() == GracefulCloser.Outcome.CLOSED
                || result.outcome() == GracefulCloser.Outcome.ALREADY_GONE;
        if (closed) {
            events.fireSessionRunEnded(session);
            return new Outcome(true, "Closed");
        }
        events.fireSessionsChanged(null);
        return new Outcome(false, explain(result, state));
    }

    /** The phone's words for why a close did not happen. */
    static String explain(GracefulCloser.Result result, SessionState state) {
        return switch (result.outcome()) {
            case BUSY_STATE -> state == SessionState.WORKING ? "It's still working. Close it once it's done."
                    : state == SessionState.WAITING_FOR_INPUT ? "It's waiting for you. Answer it first, or stop it with ^C."
                    : "Its status isn't known yet. Try again in a moment.";
            case BUSY_FOREGROUND -> "'" + result.detail() + "' is still running in it. Stop that first.";
            case NO_QUIT_SYNTAX -> result.detail() + " has no safe way to be asked to quit. Close it from Microhm on the Mac.";
            case QUIT_TIMEOUT -> "Sent " + result.detail() + ", but the agent didn't exit in time. It's still running.";
            case EXIT_TIMEOUT -> "Sent exit, but the shell didn't end in time. Something may still be running in it.";
            case CLOSED, ALREADY_GONE -> "Closed";
        };
    }
}
