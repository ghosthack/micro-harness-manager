import Foundation
import MicrohmShared

/// The sessions-changed hub between code that creates or kills sessions off the UI (the
/// MCP session controller, the phone page) and the main window, which otherwise only
/// reconciles its sidebar after its own actions. Thread-safe: fire from any thread;
/// listeners run on the firing thread and must hand UI work to the main thread
/// themselves. A listener's thrown error is logged and does not stop the others.
///
/// Java removed listeners by identity; Swift closures have none, so each `add…` returns a
/// token that `remove…` takes.
public final class SessionEvents: @unchecked Sendable {

    /// Something outside the window created, renamed or ended a session; the argument is
    /// the session just created, or nil for any other change.
    public typealias SessionsChangedListener = (String?) -> Void
    /// A session was killed by something other than the window's own Kill action.
    public typealias SessionKilledListener = (String) -> Void
    /// A session's run ended or is being replaced by something other than the window's own
    /// Close or Resume (the phone page): a terminal still showing that run must go, while
    /// the saved session stays.
    public typealias SessionRunEndedListener = (String) -> Void

    /// What `add…` returns, for `remove…`.
    public struct Token: Hashable, Sendable {
        fileprivate let id: Int
    }

    private let lock = NSLock()
    private var nextId = 0
    private var changed: [(Int, SessionsChangedListener)] = []
    private var killed: [(Int, SessionKilledListener)] = []
    private var runEnded: [(Int, SessionRunEndedListener)] = []

    public init() {
    }

    @discardableResult
    public func addSessionsChangedListener(_ listener: @escaping SessionsChangedListener) -> Token {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        changed.append((nextId, listener))
        return Token(id: nextId)
    }

    public func removeSessionsChangedListener(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        changed.removeAll { $0.0 == token.id }
    }

    @discardableResult
    public func addSessionKilledListener(_ listener: @escaping SessionKilledListener) -> Token {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        killed.append((nextId, listener))
        return Token(id: nextId)
    }

    public func removeSessionKilledListener(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        killed.removeAll { $0.0 == token.id }
    }

    @discardableResult
    public func addSessionRunEndedListener(_ listener: @escaping SessionRunEndedListener) -> Token {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        runEnded.append((nextId, listener))
        return Token(id: nextId)
    }

    public func removeSessionRunEndedListener(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        runEnded.removeAll { $0.0 == token.id }
    }

    /// Announces that a session's run ended or is being replaced; run-ended listeners run
    /// first, then a sessions-changed.
    public func fireSessionRunEnded(_ session: String) {
        for listener in snapshot(\.runEnded) {
            listener(session)
        }
        fireSessionsChanged(nil)
    }

    public func fireSessionsChanged(_ createdOrNull: String?) {
        for listener in snapshot(\.changed) {
            listener(createdOrNull)
        }
    }

    /// Announces an external kill; killed-listeners run first, then a sessions-changed.
    public func fireSessionKilled(_ session: String) {
        for listener in snapshot(\.killed) {
            listener(session)
        }
        fireSessionsChanged(nil)
    }

    /// A copy of the listeners (copy-on-write in Java), so one may add or remove others.
    private func snapshot<L>(_ list: KeyPath<SessionEvents, [(Int, L)]>) -> [L] {
        lock.lock(); defer { lock.unlock() }
        return self[keyPath: list].map(\.1)
    }
}
