import Foundation
import MicrohmShared

/// The real `SessionManager` over `PtySession`s. Creation, removal and the idle timer are
/// serialized on this instance; lookups take the same lock briefly.
///
/// Idle timer: armed at construction and whenever the session count drops to zero — a
/// kill, or the pump reporting an exit — and cancelled by a successful `create`. When it
/// fires with no session it calls the listener off this lock, so the listener may call back
/// into `killAll`. A timer that fires before any listener is set is re-armed by
/// `setListener`, so the notification is never lost.
public final class SessionManagerImpl: SessionManager, @unchecked Sendable {

    public static let DEFAULT_IDLE_DELAY: TimeInterval = 2

    private let historyLines: Int
    private let idleDelay: TimeInterval
    private let lock = NSRecursiveLock()
    private var table: [String: PtySession] = [:]   // guarded by lock
    private static let timer = DispatchQueue(label: "microhm-mux-idle-timer")
    private var idle: DispatchWorkItem?              // guarded by lock
    private var idleGeneration = 0                   // guarded by lock
    private var closed = false                       // guarded by lock
    private var listener: (() -> Void)?              // guarded by lock
    private var createdListeners: [CreatedListener] = [] // guarded by lock

    /// `idleDelay`: how long the manager waits with zero sessions before notifying.
    public init(historyLines: Int, idleDelay: TimeInterval = SessionManagerImpl.DEFAULT_IDLE_DELAY) {
        precondition(historyLines >= 0, "historyLines must be >= 0")
        self.historyLines = historyLines
        self.idleDelay = idleDelay
        lock.lock()
        armIdleTimer()
        lock.unlock()
    }

    public func create(name: String, workdir: URL, columns: Int, rows: Int, command: [String]?,
                       labels: [String: String], environment: [String: String]) throws -> Session {
        let session = try createLocked(name, workdir, columns, rows, command, labels, environment)
        lock.lock()
        let listeners = createdListeners
        lock.unlock()
        for created in listeners {
            created.callback(session)
        }
        return session
    }

    private func createLocked(_ name: String, _ workdir: URL, _ columns: Int, _ rows: Int, _ command: [String]?,
                              _ labels: [String: String], _ environment: [String: String]) throws -> Session {
        lock.lock(); defer { lock.unlock() }
        if closed {
            // Refused rather than created and then lost to the exit already under way.
            throw MuxError(SessionManagerConstants.CLOSED)
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MuxError("session name is required")
        }
        if table[name] != nil {
            throw MuxError("session \(name) already exists")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: workdir.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            throw MuxError("\(workdir.path): not a directory")
        }
        let shell = ShellCommand.forSession(name, command, environment)
        let session: PtySession
        do {
            session = try PtySession.spawn(name: name, workdir: workdir, columns: columns, rows: rows, shell: shell,
                                           historyLines: historyLines, labels: labels) { [weak self] session, code in
                self?.onSessionEnded(session, code)
            }
        } catch {
            throw MuxError("cannot start \(javaList(shell.command)): \(error)")
        }
        table[name] = session
        cancelIdleTimer()
        Log.info("session \(name) started: \(javaList(shell.command)) (pid \(session.info().pid), \(PtySession.BACKEND))", tag: "mux")
        return session
    }

    public func find(_ name: String) -> Session? {
        lock.lock(); defer { lock.unlock() }
        return table[name]
    }

    /// Live sessions in creation order.
    public func sessions() -> [Session] {
        lock.lock()
        let list = Array(table.values)
        lock.unlock()
        return list.map { ($0, $0.info().createdAt) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
            .map { $0.0 }
    }

    public func kill(_ name: String) {
        lock.lock()
        let session = table.removeValue(forKey: name)
        lock.unlock()
        guard let session else { return }
        // Kill outside the lock: it waits up to KILL_GRACE and the pump's exit callback
        // needs the lock to run.
        session.kill()
        lock.lock()
        if table.isEmpty { armIdleTimer() }
        lock.unlock()
    }

    public func killAll() {
        for session in sessions() {
            kill(session.name)
        }
    }

    public func close() {
        lock.lock()
        // Under the lock create takes: every session that will ever exist is either in this
        // list or refused.
        closed = true
        cancelIdleTimer()
        lock.unlock()
        let remaining = sessions()
        for session in remaining {
            kill(session.name)
        }
    }

    public func closeIfIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !table.isEmpty { return false }
        closed = true
        return true
    }

    public func setListener(_ listener: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.listener = listener
        // The boot timer may already have fired into the void; give the listener its turn.
        if table.isEmpty && idle == nil {
            armIdleTimer()
        }
    }

    public func addCreatedListener(_ listener: CreatedListener) {
        lock.lock(); defer { lock.unlock() }
        createdListeners.append(listener)
    }

    public func removeCreatedListener(_ listener: CreatedListener) {
        lock.lock(); defer { lock.unlock() }
        createdListeners.removeAll { $0 === listener }
    }

    /// The pump's exit callback. A session removed by `kill` is not counted twice.
    private func onSessionEnded(_ session: PtySession, _ exitCode: Int32) {
        lock.lock(); defer { lock.unlock() }
        if let current = table[session.name], current === session {
            table.removeValue(forKey: session.name)
            if table.isEmpty { armIdleTimer() }
        }
    }

    /// Must hold the lock.
    private func armIdleTimer() {
        cancelIdleTimer()
        if closed { return } // the exit is already under way
        idleGeneration += 1
        let generation = idleGeneration
        let item = DispatchWorkItem { [weak self] in self?.fireIdle(generation) }
        idle = item
        SessionManagerImpl.timer.asyncAfter(deadline: .now() + idleDelay, execute: item)
    }

    /// Must hold the lock.
    private func cancelIdleTimer() {
        idle?.cancel()
        idle = nil
    }

    private func fireIdle(_ generation: Int) {
        lock.lock()
        if generation == idleGeneration {
            idle = nil // done: setListener re-arms a timer that fired before it
        }
        if !table.isEmpty {
            lock.unlock()
            return // a create slipped in while the timer was already running
        }
        let current = listener
        lock.unlock()
        current?()
    }
}

/// A list as Java's `List.toString` prints it (`[a, b]`), for messages and the log.
func javaList(_ items: [String]) -> String {
    "[" + items.joined(separator: ", ") + "]"
}
