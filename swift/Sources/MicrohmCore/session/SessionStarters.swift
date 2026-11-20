import Foundation

/// A host that can start a session running a given command, for one-step agent launches.
public protocol DirectSessionStarter: AnyObject {

    /// Starts the session running `command` (argv) with `env` (empty = none) and returns
    /// whether `env` was applied: false only when a non-empty `env` went to a daemon that
    /// predates per-session environments.
    func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int, command: [String],
                    env: [String: String]) throws -> Bool
}

/// Starts a session with extra environment variables — the one thing
/// `SessionHost.newSession` cannot express, kept to this seam rather than widened onto the
/// host. Production is `SessionServerHost.newSession(_:_:_:_:env:)`. Returns whether `env`
/// was applied — false when the running daemon predates `env` and started the session
/// without it.
public typealias EnvSessionStarter = (_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int,
                                      _ env: [String: String]) throws -> Bool

/// Sets daemon-side labels on a session (`harness`, `project`, `display`), so other daemon
/// clients — and the session controller after a restart — can tell what runs in it without
/// the registry. Best effort by contract: callers swallow failures, since a label is never
/// worth failing a launch over. Merges `labels` into the session's labels.
public typealias SessionLabeller = (_ session: String, _ labels: [String: String]) throws -> Void

public enum SessionLabellers {
    /// Labels nothing — for tests.
    public static let none: SessionLabeller = { _, _ in }
}
