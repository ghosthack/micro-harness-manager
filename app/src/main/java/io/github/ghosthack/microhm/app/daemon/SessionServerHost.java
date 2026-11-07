package io.github.ghosthack.microhm.app.daemon;

import io.github.ghosthack.microhm.app.host.SessionConnection;
import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.host.SessionHostException;
import io.github.ghosthack.microhm.app.session.DirectSessionStarter;
import io.github.ghosthack.microhm.app.session.SessionShell;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.app.state.Screen;
import io.github.ghosthack.microhm.mux.client.AttachedSession;
import io.github.ghosthack.microhm.mux.client.SessionServerClient;
import io.github.ghosthack.microhm.mux.client.SessionServerException;
import io.github.ghosthack.microhm.mux.session.Session;

import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;

/**
 * The {@link SessionHost}: the session daemon, spoken to in-process through its client
 * library. One instance per server home; the default home is
 * {@code ~/.micro-harness-manager/mux} ({@code server.sock}, {@code server.lock},
 * {@code server.log}; override with {@code -Dmicrohm.mux.home} or
 * {@code MICROHM_MUX_HOME}).
 *
 * <p>The seam's contract is the client's: only {@link #newSession} ever spawns the
 * daemon, and on a dead home {@link #listSessions} is empty, {@link #hasSession} false,
 * {@link #capture} a dead pane and {@link #killSession} a no-op, while
 * {@link #sendKeys} and {@link #attach} throw. The daemon has
 * neither panes nor a server-side copy mode, so the terminal widget pages its own
 * scrollback. The 400 ms pause between typed text and Enter lives inside the daemon's
 * {@code send-keys}, so {@link #sendKeys} is one round trip.
 *
 * <p>Every {@link SessionServerException} surfaces as a {@link SessionHostException}
 * with the same message and the original as its cause — including the daemon's
 * protocol-mismatch message verbatim, which names the running server's version and pid
 * and tells the user how to retire it (the client never spawns, kills or replaces a
 * mismatched server: it still hosts live sessions).
 */
public final class SessionServerHost implements SessionHost, DirectSessionStarter {

    private final SessionServerClient client;

    /** Over an explicit client — tests pass one bound to an in-process server on a
     * temporary home with spawning disabled, so no test can ever fork a real daemon. */
    public SessionServerHost(SessionServerClient client) {
        this.client = client;
    }

    /** The host the app wires: the default home, auto-spawning on {@link #newSession}. */
    public static SessionServerHost forDefaultHome() {
        return new SessionServerHost(SessionServerClient.forDefaultHome());
    }

    /**
     * The underlying daemon client, for what the {@link SessionHost} seam does not carry:
     * labels, named-key input, annotated captures, quiet waits and event watches (the
     * MCP session controller). Its calls throw {@link SessionServerException}, not
     * {@link SessionHostException}.
     */
    public SessionServerClient client() {
        return client;
    }

    /** Merges {@code labels} into the session's daemon-side labels (a null value removes
     * a key); a {@link io.github.ghosthack.microhm.app.session.SessionLabeller}. */
    public void label(String session, Map<String, String> labels) {
        run(() -> client.label(session, labels));
    }

    @Override
    public boolean hasSession(String session) {
        return call(() -> client.has(session));
    }

    @Override
    public List<String> listSessions() {
        return call(() -> client.list().stream().map(Session.Info::name).toList());
    }

    /** The only call that may start the daemon: the client spawns it and poll-connects
     * when no server answers. A null command is the daemon's platform login shell. */
    @Override
    public void newSession(String session, Path workdir, int columns, int rows) {
        run(() -> client.newSession(session, workdir, columns, rows, shellCommand()));
    }

    /** {@link #newSession(String, Path, int, int)} with extra environment variables for
     * the session's shell (null/empty = none); a
     * {@link io.github.ghosthack.microhm.app.session.EnvSessionStarter}. A daemon that
     * predates {@code env} ignores it and still starts the session.
     *
     * @return whether {@code env} was applied: false only when a non-empty {@code env}
     *         went to a daemon that did not acknowledge it */
    public boolean newSession(String session, Path workdir, int columns, int rows, Map<String, String> env) {
        return call(() -> client.newSession(session, workdir, columns, rows, shellCommand(), null, env)).envApplied();
    }

    @Override
    public boolean newSession(String session, Path workdir, int columns, int rows, List<String> command,
                              Map<String, String> env) {
        Map<String, String> extra = env == null || env.isEmpty() ? null : env;
        return call(() -> client.newSession(session, workdir, columns, rows, command, null, extra)).envApplied();
    }

    /** The shell the Settings pick for new sessions; null keeps the daemon's default. */
    private static List<String> shellCommand() {
        return SessionShell.system().command(AppSettings.sessionShell()).orElse(null);
    }

    @Override
    public void sendKeys(String session, String command) {
        run(() -> client.sendKeys(session, command, true));
    }

    /** Absent — or the whole daemon gone — already counts as killed. */
    @Override
    public void killSession(String session) {
        run(() -> client.kill(session));
    }

    /**
     * A missing session (or no server) is a dead pane; a present one maps field for
     * field — the daemon's {@code alive} is the inverse of {@code paneDead},
     * {@code processId} is the shell's PID and {@code title} the last OSC 0/2 title,
     * empty when never set.
     */
    @Override
    public Screen capture(String session) {
        Optional<Session.Capture> captured = call(() -> client.capture(session));
        if (captured.isEmpty()) {
            return new Screen("", true, Instant.now());
        }
        Session.Capture c = captured.get();
        return new Screen(c.text(), !c.alive(), Instant.now(), c.foregroundCommand(), c.processId(), c.title());
    }

    /**
     * A dedicated attach-mode connection; the first bytes readable are the daemon's
     * redraw of the session at this size. The daemon runs every session with
     * {@code COLORTERM=truecolor} and forwards 24-bit SGR untouched.
     */
    @Override
    public SessionConnection attach(String session, int columns, int rows) {
        AttachedSession attached = call(() -> client.attach(session, columns, rows));
        return new SessionServerConnection(attached);
    }

    /** One daemon request, with its failure translated for the seam: same message, the
     * daemon's exception kept as the cause so a log still shows which side failed. */
    private static <T> T call(Supplier<T> request) {
        try {
            return request.get();
        } catch (SessionServerException e) {
            throw new SessionHostException(e.getMessage(), e);
        }
    }

    private static void run(Runnable request) {
        call(() -> {
            request.run();
            return null;
        });
    }
}
