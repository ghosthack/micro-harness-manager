import Foundation
@testable import MicrohmCore

/// In-memory session host (Java's `host.FakeSessionHost`): the test sets up live sessions
/// and screens directly; no process is ever spawned. Per-session screen state so a test can
/// drive several sessions independently. Thread-safe enough for the launcher's concurrent
/// launches (one lock around the state).
class FakeSessionHost: SessionHost, @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var sessions: [String] = []
    private var killed: [String] = []
    private var _newSessionCalls: [String] = []
    private var _sentCommands: [String] = []
    private var _captureCalls: [String] = []
    private var _attachCalls: [String] = []
    /// When set, `listSessions` and `hasSession` throw it.
    private var listFailure: Error?
    private var currentScreen: [String: Screen] = [:]
    private var captureQueue: [String: [Screen]] = [:]

    /// Invoked with `"session: command"` after each successful `sendKeys`; may throw to
    /// fail the send.
    var onSendKeys: (String) throws -> Void = { _ in }
    /// Runs on every `hasSession` once its answer is decided — a test can stall a probe
    /// here, as a slow daemon round trip would.
    var onHasSession: (String) -> Void = { _ in }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    var newSessionCalls: [String] { locked { _newSessionCalls } }
    var sentCommands: [String] { locked { _sentCommands } }
    var captureCalls: [String] { locked { _captureCalls } }
    var attachCalls: [String] { locked { _attachCalls } }
    var killedSessions: [String] { locked { killed } }

    /// Seeds a live session without going through `newSession`.
    func seedLiveSession(_ session: String) {
        locked { if !sessions.contains(session) { sessions.append(session) } }
    }

    func failListing(_ failure: Error?) {
        locked { listFailure = failure }
    }

    func screen(_ session: String, _ text: String) {
        screen(session, text, locked { currentScreen[session] ?? FakeSessionHost.blank() }.foregroundCommand)
    }

    func screen(_ session: String, _ text: String, _ foregroundCommand: String) {
        locked {
            // title survives text updates, same as the daemon (OSC titles outlive redraws)
            let current = currentScreen[session] ?? FakeSessionHost.blank()
            currentScreen[session] = Screen(text, false, Date(timeIntervalSince1970: 0), foregroundCommand,
                                            current.paneProcessId, current.paneTitle)
        }
    }

    func paneTitle(_ session: String, _ title: String) {
        locked {
            let c = currentScreen[session] ?? FakeSessionHost.blank()
            currentScreen[session] = Screen(c.text, c.paneDead, c.capturedAt, c.foregroundCommand, c.paneProcessId, title)
        }
    }

    func queueCapture(_ session: String, _ text: String) {
        locked { captureQueue[session, default: []].append(Screen(text, false, Date(timeIntervalSince1970: 0), "")) }
    }

    /// The session's process exited on its own — nothing is recorded as killed.
    func endSession(_ session: String) {
        locked { sessions.removeAll { $0 == session } }
    }

    private static func blank() -> Screen {
        Screen("", false, Date(timeIntervalSince1970: 0), "")
    }

    func hasSession(_ session: String) throws -> Bool {
        let live: Bool = try locked {
            if let listFailure { throw listFailure }
            return sessions.contains(session)
        }
        onHasSession(session) // after answering, so a stalled probe's answer can go stale
        return live
    }

    func listSessions() throws -> [String] {
        try locked {
            if let listFailure { throw listFailure }
            return sessions
        }
    }

    func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int) throws {
        locked {
            if !sessions.contains(session) { sessions.append(session) }
            _newSessionCalls.append("\(session) \(workdir.path) \(columns)x\(rows)")
        }
    }

    func sendKeys(_ session: String, _ command: String) throws {
        try locked {
            guard sessions.contains(session) else { throw SessionHostException("no such session: " + session) }
            _sentCommands.append(session + ": " + command)
        }
        try onSendKeys(session + ": " + command)
    }

    func killSession(_ session: String) throws {
        locked {
            sessions.removeAll { $0 == session }
            killed.append(session)
        }
    }

    func capture(_ session: String) throws -> Screen {
        locked {
            _captureCalls.append(session)
            if !sessions.contains(session) {
                return Screen("", true, Date(timeIntervalSince1970: 0), "")
            }
            if var queue = captureQueue[session], !queue.isEmpty {
                let next = queue.removeFirst()
                captureQueue[session] = queue
                return next
            }
            return currentScreen[session] ?? FakeSessionHost.blank()
        }
    }

    /// An in-memory connection that has already reached end-of-stream.
    func attach(_ session: String, _ columns: Int, _ rows: Int) throws -> SessionConnection {
        try locked {
            guard sessions.contains(session) else { throw SessionHostException("no such session: " + session) }
            _attachCalls.append("\(session) \(columns)x\(rows)")
        }
        return EndedConnection(session)
    }

    private final class EndedConnection: SessionConnection {
        let name: String
        private var open = true
        init(_ name: String) { self.name = name }
        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { -1 }
        func write(_ bytes: [UInt8]) throws {}
        func resize(_ columns: Int, _ rows: Int) {}
        var isAlive: Bool { open }
        func waitFor() -> Int32 { 0 }
        func close() { open = false }
    }
}

/// A fake host that can also start a session running a command (one-step launches).
final class FakeDirectSessionHost: FakeSessionHost, DirectSessionStarter, @unchecked Sendable {
    private let directLock = NSLock()
    private var _directStarts: [String] = []
    var envApplied = true

    var directStarts: [String] {
        directLock.lock(); defer { directLock.unlock() }
        return _directStarts
    }

    func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int, command: [String],
                    env: [String: String]) throws -> Bool {
        seedLiveSession(session)
        directLock.lock()
        _directStarts.append("\(session) \(command) \(env.sorted { $0.key < $1.key })")
        directLock.unlock()
        return envApplied
    }
}
