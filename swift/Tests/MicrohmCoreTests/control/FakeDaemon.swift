import Foundation
@testable import MicrohmCore
import MicrohmMux

/// An error with a message, standing in for Java's unchecked exceptions in fakes.
struct FakeError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

/// An in-memory daemon for controller tests: sessions with a scripted screen. With `old`
/// set it plays a daemon that predates input, wait, watch, labels, capture formats and the
/// output counter, as an old daemon does. (Java's `control.FakeDaemon`.)
final class FakeDaemon: DaemonControl, @unchecked Sendable {

    final class FakeSession {
        let name: String
        var labels: [String: String] = [:]
        var workdir = URL(fileURLWithPath: "/work")
        var text = ""
        var foreground = "zsh"
        var title = ""
        var outputBytes: Int64 = 0
        var columns = 120
        var rows = 32
        var alive = true
        /// Whether its program enabled bracketed paste (DEC 2004), as agents do.
        var bracketedPaste = true
        /// The scrollback above the screen, oldest first.
        var history: [String] = []
        /// Scrollback lines that fell out before `history`: added = this + its size.
        var historyDropped: Int64 = 0
        /// Whether a full-screen program shows the alternate screen.
        var alternateScreen = false
        /// The pid capture reports.
        var processId: Int64 = 4242

        init(_ name: String) {
            self.name = name
        }

        /// Replaces the screen, counting the new text as output.
        @discardableResult
        func show(_ screen: String) -> FakeSession {
            text = screen
            outputBytes += Int64(screen.utf16.count + 1)
            return self
        }
    }

    /// One `input` call.
    struct Input: Equatable, CustomStringConvertible {
        let session: String
        let text: String?
        let paste: Bool
        let keys: [String]?

        init(_ session: String, _ text: String?, _ paste: Bool, _ keys: [String]?) {
            self.session = session
            self.text = text
            self.paste = paste
            self.keys = keys
        }

        var description: String { "Input[\(session), \(text ?? "nil"), \(paste), \(keys ?? [])]" }
    }

    /// One `sendKeys` call (the old daemon's only way to type).
    struct SendKeys: Equatable {
        let session: String
        let text: String
        let enter: Bool

        init(_ session: String, _ text: String, _ enter: Bool) {
            self.session = session
            self.text = text
            self.enter = enter
        }
    }

    /// One `awaitQuiet` call that was not a non-blocking probe.
    struct Wait: Equatable {
        let session: String
        let sinceBytes: Int64
        let quietMs: Int64
        let timeoutMs: Int64

        init(_ session: String, _ sinceBytes: Int64, _ quietMs: Int64, _ timeoutMs: Int64) {
            self.session = session
            self.sinceBytes = sinceBytes
            self.quietMs = quietMs
            self.timeoutMs = timeoutMs
        }
    }

    private let lock = NSRecursiveLock()

    private var order: [String] = []
    private var byName: [String: FakeSession] = [:]
    private var _inputs: [Input] = []
    private var _waits: [Wait] = []
    private var _sentKeys: [SendKeys] = []
    private var _bracketedRequired: [Input] = []
    private var _watches: [FakeWatch] = []
    var labelled: [String] = []
    /// Plays an unreachable daemon: list and capture come back empty, ping fails, every
    /// other call reports no server — as the client does when no daemon answers.
    @Atomic var down = false
    /// Runs after every successful `list` — e.g. to take the daemon down between a list and
    /// the captures that follow it.
    @Atomic var afterList: () -> Void = {}
    /// Plays a daemon that predates everything but list/capture-text/send-keys/kill.
    @Atomic var old = false
    /// Plays a daemon that has everything but capture history.
    @Atomic var noHistory = false
    /// What ping reports; -1 = no daemon answers.
    @Atomic var pid: Int64 = 100
    @Atomic var pings = 0
    @Atomic var unsupportedCalls = 0
    /// Per session: how many captures still fail with a transient error.
    var captureFailures: [String: Int] = [:]
    /// Input calls matching this fail with a transient error (before anything is written).
    @Atomic var failInput: (Input) -> Bool = { _ in false }
    /// Answer to the controller's "quiet for this long already?" probes.
    @Atomic var quietProbe = false
    /// How many watch() calls fail before one succeeds; -1 = always fail.
    @Atomic var watchFailures = 0
    @Atomic var watchAttempts = 0

    var inputs: [Input] { locked { _inputs } }
    var waits: [Wait] { locked { _waits } }
    var sentKeys: [SendKeys] { locked { _sentKeys } }
    var bracketedRequired: [Input] { locked { _bracketedRequired } }
    var watches: [FakeWatch] { locked { _watches } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    @discardableResult
    func add(_ name: String) -> FakeSession {
        locked {
            let s = FakeSession(name)
            if byName[name] == nil { order.append(name) }
            byName[name] = s
            return s
        }
    }

    func session(_ name: String) -> FakeSession? {
        locked { byName[name] }
    }

    /// Removes a session without a kill call (the daemon lost it).
    func remove(_ name: String) {
        locked {
            byName.removeValue(forKey: name)
            order.removeAll { $0 == name }
        }
    }

    func list() throws -> [SessionInfo] {
        try locked {
            if down {
                return []
            }
            let infos = order.compactMap { byName[$0] }.map { s in
                SessionInfo(name: s.name, workdir: s.workdir, columns: 120, rows: 32, pid: 100,
                            createdAt: Date(timeIntervalSince1970: 0), clients: 0, alive: s.alive, backend: "pty",
                            labels: old ? [:] : s.labels, outputBytes: old ? -1 : s.outputBytes)
            }
            afterList()
            return infos
        }
    }

    func capture(_ name: String, _ format: CaptureFormat) throws -> SessionCapture? {
        try locked {
            guard let s = byName[name], !down else {
                return nil
            }
            if old && format != .TEXT {
                throw unsupported("capture format " + format.wireName)
            }
            if let failures = captureFailures[name], failures > 0 {
                captureFailures[name] = failures - 1
                throw SessionServerException("capture failed: java.io.IOException: Broken pipe")
            }
            let text = format == .TEXT ? ScreenDiff.plain(s.text) : s.text
            return SessionCapture(text: text, alive: s.alive, foregroundCommand: s.foreground, processId: s.processId,
                                  title: s.title, columns: s.columns, rows: s.rows,
                                  outputBytes: old ? -1 : s.outputBytes, cursorVisible: true)
        }
    }

    func captureSince(_ name: String, _ format: CaptureFormat, _ since: Int64) throws -> SessionCapture? {
        try locked {
            let s = byName[name]
            if s != nil && !down && (old || noHistory) {
                throw unsupported("capture history")
            }
            historyRequests.append(since)
            guard let c = try capture(name, format), let s else { return nil }
            let added = s.historyDropped + Int64(s.history.count)
            let start = since < 0 || since > added ? 0 : since
            let n = Int(min(added - start, Int64(s.history.count)))
            let text = s.history.suffix(n).map { $0 + "\n" }.joined()
            return c.withHistory(CaptureHistory(text: text, held: s.history.count, added: added,
                                                alternateScreen: s.alternateScreen))
        }
    }

    /// The since of every history capture.
    var historyRequests: [Int64] = []

    func input(_ name: String, _ text: String?, _ paste: Bool, _ requireBracketedPaste: Bool,
               _ keys: [String]?) throws {
        try locked {
            if old {
                throw unsupported("input")
            }
            if down {
                throw SessionServerException.noServer(name)
            }
            let input = Input(name, text, paste, keys)
            if failInput(input) {
                throw SessionServerException("input failed: java.io.IOException: Broken pipe")
            }
            guard let s = byName[name] else {
                throw FakeError("no such session: " + name)
            }
            if let keys, keys.contains("Bogus") {
                throw FakeError("unknown key: Bogus")
            }
            if requireBracketedPaste {
                _bracketedRequired.append(input)
                if paste, let text, !text.isEmpty, !s.bracketedPaste {
                    throw SessionServerException(MuxProtocol.ERROR_BRACKETED_PASTE_DISABLED)
                }
            }
            _inputs.append(input)
            s.outputBytes += 1
        }
    }

    func awaitQuiet(_ name: String, _ sinceBytes: Int64, _ quietMs: Int64, _ timeoutMs: Int64) throws -> WaitResult {
        try locked {
            if old {
                throw unsupported("wait")
            }
            guard let s = byName[name] else {
                throw FakeError("no such session: " + name)
            }
            if sinceBytes < 0 && timeoutMs == 0 {
                return WaitResult(quiet: quietProbe, outputBytes: s.outputBytes, alive: s.alive)
            }
            _waits.append(Wait(name, sinceBytes, quietMs, timeoutMs))
            return WaitResult(quiet: true, outputBytes: s.outputBytes, alive: s.alive)
        }
    }

    func watch(_ quietMs: Int64, _ onEvent: @escaping (SessionEvent) -> Void) throws -> DaemonWatch {
        try locked {
            watchAttempts += 1
            if old {
                throw unsupported("watch")
            }
            let attempt = watchAttempts
            if watchFailures < 0 || attempt <= watchFailures {
                throw FakeError("no session server is running")
            }
            let watch = FakeWatch(onEvent)
            _watches.append(watch)
            return watch
        }
    }

    func sendKeys(_ name: String, _ text: String, _ enter: Bool) throws {
        try locked {
            guard let s = byName[name] else {
                throw FakeError("no such session: " + name)
            }
            _sentKeys.append(SendKeys(name, text, enter))
            s.outputBytes += 1
        }
    }

    func daemonPid() throws -> Int64? {
        pings += 1
        return pid < 0 || down ? nil : pid
    }

    func ping() throws -> Bool {
        pid >= 0 && !down
    }

    private func unsupported(_ what: String) -> SessionServerException {
        unsupportedCalls += 1
        return SessionServerException.unsupported(what)
    }

    func resize(_ name: String, _ columns: Int, _ rows: Int) throws {
        locked {
            if let s = byName[name] {
                s.columns = columns
                s.rows = rows
            }
        }
    }

    func kill(_ name: String) throws {
        remove(name)
    }

    func label(_ name: String, _ changes: [String: String?]) throws {
        try locked {
            if old {
                throw unsupported("label")
            }
            labelled.append(name)
            if let s = byName[name] {
                for (k, v) in changes {
                    s.labels[k] = v
                }
            }
        }
    }

    final class FakeWatch: DaemonWatch, @unchecked Sendable {
        let onEvent: (SessionEvent) -> Void
        @Atomic var open = true

        init(_ onEvent: @escaping (SessionEvent) -> Void) {
            self.onEvent = onEvent
        }

        var isOpen: Bool { open }

        func close() {
            open = false
        }
    }
}
