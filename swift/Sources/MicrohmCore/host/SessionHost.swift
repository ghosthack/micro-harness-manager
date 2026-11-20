import Foundation

/// The substrate that hosts named sessions — the app's session daemon. This is the seam
/// the rest of the app talks through: status polling, graceful close, reconciliation and
/// the terminal widget only ever call `SessionHost.<method>(sessionName, …)`, so tests run
/// them against an in-memory fake. The one production implementation is
/// `SessionServerHost`.
///
/// "No server running" semantics: `listSessions` is empty, `hasSession` is false,
/// `capture` reports a dead pane, `killSession` returns normally (already gone);
/// `sendKeys` and `attach` throw `SessionHostException`. Only `newSession` may start a
/// server.
///
/// Refines `StatusSessionHost` (`hasSession`, `sendKeys`, `capture`), the slice status
/// polling and graceful close need.
public protocol SessionHost: StatusSessionHost {

    /// Names of all live sessions.
    func listSessions() throws -> [String]

    /// Creates a detached session running the default shell in `workdir`.
    func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int) throws

    /// Kills the session outright (and whatever it's running). No-op if already gone.
    func killSession(_ session: String) throws

    /// Opens a live connection at the given size. May block (daemon connect) and is
    /// therefore never called on the main thread.
    func attach(_ session: String, _ columns: Int, _ rows: Int) throws -> SessionConnection
}

/// A live, bidirectional byte stream plus resize, attached to one session on the
/// `SessionHost` — what a terminal widget renders. `close()` detaches; it never kills the
/// session.
///
/// Two ways to read it: pull (`read`, blocking, as Java's `SessionConnection`), or push
/// (`onBytes`/`onEnd` set, then `start()`, which pumps the stream on a reader thread — the
/// shape of `MicrohmTerminal.TerminalTransport`). Use one or the other, not both.
public protocol SessionConnection: AnyObject {

    /// Short label for diagnostics (the widget's connector name).
    var name: String { get }

    /// Reads output bytes into `buffer`; -1 once the connection has ended. Blocks.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// Sends input bytes. A read-only connection drops them silently.
    func write(_ bytes: [UInt8]) throws

    func resize(_ columns: Int, _ rows: Int)

    var isAlive: Bool { get }

    /// Blocks until the connection ends; the exit status of the session's process, or 0
    /// after a detach or a lost server, which have no process status.
    @discardableResult
    func waitFor() -> Int32

    /// Detaches. Idempotent; never kills the session.
    func close()
}

/// A session-host operation failed: the daemon could not be reached or refused a request.
/// Kept separate from the daemon client's own error so nothing above the `SessionHost`
/// seam has to depend on the client library to report a failure. `cause` keeps the
/// original, so a log still shows which side failed.
public struct SessionHostException: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public let cause: Error?

    public init(_ message: String, cause: Error? = nil) {
        self.message = message
        self.cause = cause
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The message of any error, the way Java's `getMessage()` (falling back to `toString()`)
/// reads in user-facing text.
func errorMessage(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription {
        return d
    }
    return String(describing: error)
}
