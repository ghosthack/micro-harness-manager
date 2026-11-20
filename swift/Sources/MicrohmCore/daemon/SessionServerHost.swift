import Foundation
import MicrohmMux
import MicrohmShared

/// The `SessionHost`: the session daemon, spoken to in-process through its client library.
/// One instance per server home; the default home is `MicrohmPaths.muxHome`
/// (`server.sock`, `server.lock`, `server.log`; override with `MICROHM_MUX_HOME`).
///
/// The seam's contract is the client's: only `newSession` ever spawns the daemon, and on a
/// dead home `listSessions` is empty, `hasSession` false, `capture` a dead pane and
/// `killSession` a no-op, while `sendKeys` and `attach` throw. The daemon has neither
/// panes nor a server-side copy mode, so the terminal widget pages its own scrollback. The
/// 400 ms pause between typed text and Enter lives inside the daemon's `send-keys`, so
/// `sendKeys` is one round trip.
///
/// Every `SessionServerException` surfaces as a `SessionHostException` with the same
/// message and the original as its cause — including the daemon's protocol-mismatch
/// message verbatim, which names the running server's version and pid and tells the user
/// how to retire it (the client never spawns, kills or replaces a mismatched server: it
/// still hosts live sessions).
public final class SessionServerHost: SessionHost, DirectSessionStarter, @unchecked Sendable {

    private let daemonClient: SessionServerClient
    /// The shell the Settings pick for new sessions; nil keeps the daemon's default.
    var shellCommand: () -> [String]? = { SessionShell.system().command(AppSettings.sessionShell()) }

    /// Over an explicit client — tests pass one bound to an in-process server on a
    /// temporary home with spawning disabled, so no test can ever fork a real daemon.
    public init(_ client: SessionServerClient) {
        self.daemonClient = client
    }

    /// The host the app wires: the default home, auto-spawning on `newSession` with the
    /// `microhm-mux` executable beside this one.
    public static func forDefaultHome() -> SessionServerHost {
        SessionServerHost(SessionServerClient.forDefaultHome(launcher: MicrohmPaths.siblingExecutable("microhm-mux")))
    }

    /// The underlying daemon client, for what the `SessionHost` seam does not carry: labels,
    /// named-key input, annotated captures, quiet waits and event watches (the MCP session
    /// controller). Its calls throw `SessionServerException`, not `SessionHostException`.
    public func client() -> SessionServerClient {
        daemonClient
    }

    /// Merges `labels` into the session's daemon-side labels; a `SessionLabeller`.
    public func label(_ session: String, _ labels: [String: String]) throws {
        try run { _ = try daemonClient.label(session, changes: labels.mapValues { Optional($0) }) }
    }

    public func hasSession(_ session: String) throws -> Bool {
        try call { try daemonClient.has(session) }
    }

    public func listSessions() throws -> [String] {
        try call { try daemonClient.list().map(\.name) }
    }

    /// The only call that may start the daemon: the client spawns it and poll-connects when
    /// no server answers.
    public func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int) throws {
        let shell = shellCommand()
        try run { try daemonClient.newSession(session, workdir: workdir, columns: columns, rows: rows, command: shell) }
    }

    /// `newSession` with extra environment variables for the session's shell (empty =
    /// none); an `EnvSessionStarter`. A daemon that predates `env` ignores it and still
    /// starts the session. Returns whether `env` was applied: false only when a non-empty
    /// `env` went to a daemon that did not acknowledge it.
    public func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int,
                           env: [String: String]) throws -> Bool {
        let shell = shellCommand()
        return try call {
            try daemonClient.newSession(session, workdir: workdir, columns: columns, rows: rows, command: shell,
                                  env: env.isEmpty ? nil : env).envApplied
        }
    }

    public func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int, command: [String],
                           env: [String: String]) throws -> Bool {
        try call {
            try daemonClient.newSession(session, workdir: workdir, columns: columns, rows: rows, command: command,
                                  env: env.isEmpty ? nil : env).envApplied
        }
    }

    public func sendKeys(_ session: String, _ command: String) throws {
        try run { try daemonClient.sendKeys(session, text: command, enter: true) }
    }

    /// Absent — or the whole daemon gone — already counts as killed.
    public func killSession(_ session: String) throws {
        try run { try daemonClient.kill(session) }
    }

    /// A missing session (or no server) is a dead pane; a present one maps field for field
    /// — the daemon's `alive` is the inverse of `paneDead`, `processId` is the shell's PID
    /// and `title` the last OSC 0/2 title, empty when never set.
    public func capture(_ session: String) throws -> Screen {
        guard let c = try call({ try daemonClient.capture(session) }) else {
            return Screen("", true, Date())
        }
        return Screen(c.text, !c.alive, Date(), c.foregroundCommand, c.processId, c.title)
    }

    /// A dedicated attach-mode connection; the first bytes readable are the daemon's redraw
    /// of the session at this size.
    public func attach(_ session: String, _ columns: Int, _ rows: Int) throws -> SessionConnection {
        try attachConnection(session, columns, rows)
    }

    /// `attach` as the concrete type, which is also the app's terminal transport.
    public func attachConnection(_ session: String, _ columns: Int, _ rows: Int) throws -> SessionServerConnection {
        SessionServerConnection(try call { try daemonClient.attach(session, columns: columns, rows: rows) })
    }

    /// One daemon request, with its failure translated for the seam: same message, the
    /// daemon's error kept as the cause.
    private func call<T>(_ request: () throws -> T) throws -> T {
        do {
            return try request()
        } catch let e as SessionServerException {
            throw SessionHostException(e.message, cause: e)
        }
    }

    private func run(_ request: () throws -> Void) throws {
        try call(request)
    }
}
