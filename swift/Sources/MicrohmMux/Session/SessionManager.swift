import Foundation

/// A registration for `SessionManager.addCreatedListener` (Java passed a `Consumer` and
/// removed it by identity; Swift closures have none, so this box carries it).
public final class CreatedListener: @unchecked Sendable {
    let callback: (Session) -> Void
    public init(_ callback: @escaping (Session) -> Void) { self.callback = callback }
}

/// The server's table of live sessions. Thread-safe. Session names are opaque strings
/// (the app uses `mhm-<basename>`); uniqueness is enforced here.
///
/// Auto-exit: the 2 s idle timer arms at construction (a server that boots and never gets
/// a `new` exits) and again whenever the session count drops to zero (process exit or
/// kill); `create` cancels it. When it fires the manager notifies the listener. The server
/// uses it to exit like tmux does when no sessions remain; `serve --keep-alive` simply
/// ignores the callback. Because only `new` ever spawns a server, this cannot loop.
public protocol SessionManager: AnyObject {

    /// Creates and starts a session. `command` nil/empty = the platform login shell
    /// (`ShellCommand`), `labels` the initial labels, `environment` merged into the
    /// session's environment after the defaults. Throws `MuxError` if the name is taken,
    /// the manager is closed, or the PTY cannot be spawned.
    func create(name: String, workdir: URL, columns: Int, rows: Int, command: [String]?,
                labels: [String: String], environment: [String: String]) throws -> Session

    func find(_ name: String) -> Session?

    func sessions() -> [Session]

    /// Kills and removes; absent is a no-op.
    func kill(_ name: String)

    /// Kills every session.
    func killAll()

    /// Server shutdown: from here on `create` throws (`SessionManagerConstants.CLOSED`),
    /// and every session is killed.
    func close()

    /// The idle exit's commit point: closes the manager as `close` does if it has no
    /// session, and says whether it did.
    func closeIfIdle() -> Bool

    func setListener(_ listener: @escaping () -> Void)

    /// Tells `listener` about every session created from now on, after it is listed.
    /// Called on the creating thread, outside the manager's lock; must not block.
    func addCreatedListener(_ listener: CreatedListener)

    func removeCreatedListener(_ listener: CreatedListener)
}

extension SessionManager {
    public func create(name: String, workdir: URL, columns: Int, rows: Int, command: [String]?) throws -> Session {
        try create(name: name, workdir: workdir, columns: columns, rows: rows, command: command,
                   labels: [:], environment: [:])
    }
}

public enum SessionManagerConstants {
    /// What every refused `create` says once the manager is closed.
    public static let CLOSED = "the session server is shutting down"
}
