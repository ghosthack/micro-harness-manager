import Foundation

/// A request the session layer refused (Java: `IllegalStateException`,
/// `IllegalArgumentException`, `UncheckedIOException`). The message is meant for the user.
public struct MuxError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Input the session did not take: the program has stopped reading its terminal and the
/// bound on what is held for it is reached. The message is meant for the sender.
public struct InputRejectedError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// How the server sees a client: output bytes and the end of the session (Java
/// `Session.Client`).
public protocol SessionClient: AnyObject {
    /// Called under the session lock; must be non-blocking (enqueue only).
    func onOutput(_ bytes: [UInt8])

    /// The PTY process ended; the client connection should be closed after this.
    func onExit(_ exitCode: Int32)

    /// A re-sync snapshot requested through `Session.snapshotFor`, handed over under the
    /// session lock. A client that discards live output while BEHIND must re-enable delivery
    /// *inside* this call: nothing else can enqueue while the session lock is held, so the
    /// snapshot is guaranteed to precede every later live batch. The default treats it like
    /// ordinary output.
    func onSnapshot(_ bytes: [UInt8])
}

extension SessionClient {
    public func onSnapshot(_ bytes: [UInt8]) { onOutput(bytes) }
}

/// A watch on one session's activity: see `Session.addWatcher` (Java `Session.Watcher`).
public protocol SessionWatcher: AnyObject {
    /// Called under the session lock (from the pump, the quiet timer or the exit path);
    /// must be non-blocking (enqueue only).
    func onEvent(_ event: SessionEvent)

    /// How long without output after activity raises `quiet` for this watcher.
    var quietMs: Int64 { get }
}

extension SessionWatcher {
    public var quietMs: Int64 { MuxProtocol.WATCH_DEFAULT_QUIET_MS }
}

/// Something a `SessionWatcher` is told about. `type` is one of `EVENT_OUTPUT`,
/// `EVENT_QUIET`, `EVENT_TITLE` (`title` carries the new one), `EVENT_BELL` and
/// `EVENT_EXIT` (`exitCode` set). `outputBytes` is the session's byte counter when the
/// event was raised.
public struct SessionEvent: Equatable, Sendable {
    public let name: String
    public let type: String
    public let outputBytes: Int64
    public let title: String?
    public let exitCode: Int32?

    public init(name: String, type: String, outputBytes: Int64, title: String? = nil, exitCode: Int32? = nil) {
        self.name = name
        self.type = type
        self.outputBytes = outputBytes
        self.title = title
        self.exitCode = exitCode
    }
}

/// `backend`: `unix`. `labels` never nil; `outputBytes` the raw PTY byte count (-1 =
/// unknown: decoded from a daemon that predates the counter). (Java `Session.Info`.)
public struct SessionInfo: Equatable, Sendable {
    public let name: String
    public let workdir: URL
    public let columns: Int
    public let rows: Int
    public let pid: Int64
    public let createdAt: Date
    public let clients: Int
    public let alive: Bool
    public let backend: String
    public let labels: [String: String]
    public let outputBytes: Int64

    public init(name: String, workdir: URL, columns: Int, rows: Int, pid: Int64, createdAt: Date,
                clients: Int, alive: Bool, backend: String, labels: [String: String] = [:], outputBytes: Int64 = 0) {
        self.name = name
        self.workdir = workdir
        self.columns = columns
        self.rows = rows
        self.pid = pid
        self.createdAt = createdAt
        self.clients = clients
        self.alive = alive
        self.backend = backend
        self.labels = labels
        self.outputBytes = outputBytes
    }
}

/// Scrollback above the screen as a capture reports it (Java `HeadlessTerminal.History`):
/// the lines oldest first, each ending in a newline; the lines held in all; the lines ever
/// added (monotonic); and whether the alternate screen (no scrollback) is showing.
public struct CaptureHistory: Equatable, Sendable {
    public let text: String
    public let held: Int
    public let added: Int64
    public let alternateScreen: Bool

    public init(text: String, held: Int, added: Int64, alternateScreen: Bool) {
        self.text = text
        self.held = held
        self.added = added
        self.alternateScreen = alternateScreen
    }

    /// The history of a session that keeps none.
    public static let none = CaptureHistory(text: "", held: 0, added: 0, alternateScreen: false)
}

/// Foreground command, PID and title as `capture` reports them, plus the byte counter the
/// text corresponds to (-1 = unknown) and whether the cursor is shown. `history` is the
/// scrollback a capture asked for; nil when none was asked for (Java `Session.Capture`).
public struct SessionCapture: Equatable, Sendable {
    public let text: String
    public let alive: Bool
    public let foregroundCommand: String
    public let processId: Int64
    public let title: String
    public let columns: Int
    public let rows: Int
    public let outputBytes: Int64
    public let cursorVisible: Bool
    public let history: CaptureHistory?

    public init(text: String, alive: Bool, foregroundCommand: String, processId: Int64, title: String,
                columns: Int, rows: Int, outputBytes: Int64 = 0, cursorVisible: Bool = true,
                history: CaptureHistory? = nil) {
        self.text = text
        self.alive = alive
        self.foregroundCommand = foregroundCommand
        self.processId = processId
        self.title = title
        self.columns = columns
        self.rows = rows
        self.outputBytes = outputBytes
        self.cursorVisible = cursorVisible
        self.history = history
    }

    /// This capture with `history` attached.
    public func withHistory(_ history: CaptureHistory?) -> SessionCapture {
        SessionCapture(text: text, alive: alive, foregroundCommand: foregroundCommand, processId: processId,
                       title: title, columns: columns, rows: rows, outputBytes: outputBytes,
                       cursorVisible: cursorVisible, history: history)
    }
}

/// What `Session.awaitQuiet` ended with: `quiet` false means the timeout elapsed while
/// output was still flowing.
public struct WaitResult: Equatable, Sendable {
    public let quiet: Bool
    public let outputBytes: Int64
    public let alive: Bool

    public init(quiet: Bool, outputBytes: Int64, alive: Bool) {
        self.quiet = quiet
        self.outputBytes = outputBytes
        self.alive = alive
    }
}

/// What `Session.capture` renders the visible screen as.
public enum CaptureFormat: String, CaseIterable, Sendable {
    /// Plain rows, trailing whitespace trimmed (tmux `capture-pane -p` shape).
    case TEXT = "text"
    /// TEXT plus `▶ ` before selected rows and `▮` at the visible cursor.
    case ANNOTATED = "annotated"
    /// The attach redraw stream without history, as a UTF-8 string.
    case ANSI = "ansi"

    /// The wire name (`text` / `annotated` / `ansi`).
    public var wireName: String { rawValue }

    /// The format with this wire name (case-insensitive), or nil.
    public static func fromWireName(_ name: String?) -> CaptureFormat? {
        guard let name else { return nil }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CaptureFormat.allCases.first { $0.wireName == wanted }
    }
}

/// One hosted session: a shell (or explicit command) in a PTY, the headless terminal that
/// shadows its output, and the set of attached clients. The load-bearing rules:
///
/// **One pump thread and one lock.** The pump reads PTY bytes → `VtTokenizer` →
/// `SgrNormalizer` → under the session lock: apply the complete tokens to the
/// `HeadlessTerminal`, then for every attached client enqueue the bytes of every token
/// `QueryFilter` does not strip followed by the batch's open-string fragment. Emulator
/// state and broadcast position are identical at every lock release.
///
/// **Per-client outbound queue.** A client is handed bytes through `onOutput`, which must
/// only enqueue; the connection's own writer thread drains it. The session never blocks on
/// a client.
///
/// **PTY input** (`write`, `sendKeys`, emulator replies) goes through a per-session writer
/// queue and thread, never from under the session lock.
///
/// **Attach** takes the session lock between pump batches, resizes to the client's size if
/// it differs (announcing `CSI 8 ; rows ; columns t` to the others), serializes, hands the
/// new client the snapshot followed by `tokenizer.openStringBytes()`, registers it, and
/// releases.
///
/// **Watchers** are told about activity, quiet, title, bell and exit; like clients they
/// are called under the session lock and must only enqueue. `awaitQuiet` blocks the
/// caller, never the pump.
public protocol Session: AnyObject {

    var name: String { get }

    func info() -> SessionInfo

    func isAlive() -> Bool

    /// Enqueues raw bytes for the PTY (client keystrokes). Throws `InputRejectedError`,
    /// having enqueued nothing, when the program is not reading and too much is already
    /// pending; `sendKeys`, `input`, `paste` and `pasteIfBracketed` do the same.
    func write(_ bytes: [UInt8]) throws

    /// `text`, then when `enter` a `SEND_KEYS_ENTER_DELAY_MS` pause and CR. The pause
    /// happens on the calling thread, never under a lock.
    func sendKeys(_ text: String, enter: Bool) throws

    /// Resizes the PTY and the headless terminal under the session lock and announces the
    /// new size in-band to every attached client except `except` (nil = all).
    func resize(columns: Int, rows: Int, except: SessionClient?)

    /// The visible screen in `format`, taken under the session lock.
    func capture(_ format: CaptureFormat) -> SessionCapture

    /// `capture(format)` plus up to `historyLines` lines of the scrollback just above the
    /// screen, taken together. 0 = none (the capture's `history` is then nil).
    func capture(_ format: CaptureFormat, historyLines: Int) -> SessionCapture

    /// `capture(format)` plus the scrollback lines added after the first `since` ever added,
    /// taken together: a reader that passes back the `added` it got sees each line once.
    func captureSince(_ format: CaptureFormat, since: Int64) -> SessionCapture

    /// Raw PTY bytes read so far (before any filtering); monotonic.
    func outputBytes() -> Int64

    /// The session's labels: a copy, never nil.
    func labels() -> [String: String]

    /// Merges `changes` into the labels; a nil value removes its key.
    func label(_ changes: [String: String?])

    /// Presses named keys (`KeyNames`), encoded for the current cursor-key mode. Throws on
    /// an unknown name, before writing anything.
    func input(_ keys: [String]) throws

    /// Writes `text` as a paste: wrapped in `CSI 200~ … CSI 201~` when the program enabled
    /// bracketed paste, raw otherwise. Inside the bracket every ESC and C1 CSI character is
    /// removed, so the text cannot close the bracket early.
    func paste(_ text: String) throws

    /// `paste` only when the program enabled bracketed paste: returns false, having written
    /// nothing, when it has not.
    func pasteIfBracketed(_ text: String) throws -> Bool

    /// Blocks until the output is quiet. With `sinceBytes >= 0` it first waits for the byte
    /// counter to pass `sinceBytes`; then until no output arrived for `quietMs`. Returns
    /// `quiet=false` when `timeoutMs` elapses first, and promptly with `quiet=true,
    /// alive=false` once the session has exited.
    func awaitQuiet(sinceBytes: Int64, quietMs: Int64, timeoutMs: Int64) -> WaitResult

    /// Registers a watcher (idempotent): `output`, `quiet`, `title`, `bell`, and finally
    /// `exit` — immediately, when the session has already exited.
    func addWatcher(_ watcher: SessionWatcher)

    func removeWatcher(_ watcher: SessionWatcher)

    /// OSC 7 / 9;9 hint → platform probe → launch workdir. Never nil.
    func currentPath() -> URL

    /// Registers a client: the redraw-on-attach handshake described above.
    func attach(_ client: SessionClient, columns: Int, rows: Int)

    /// A fresh snapshot at the session's current size for a client that fell BEHIND, taken
    /// under the session lock, prefixed with ST (`ESC \`).
    func snapshotFor(_ client: SessionClient)

    func detach(_ client: SessionClient)

    func clients() -> [SessionClient]

    /// Snapshot descendants; SIGHUP; wait up to 2 s for the shell and every snapshot pid;
    /// then SIGKILL whatever survives. Returns once the process is gone.
    func kill()
}

extension Session {
    /// The visible screen as TEXT.
    public func capture() -> SessionCapture { capture(.TEXT) }
}

/// Labels as the wire carries them: key-sorted, without nil values.
func sortedLabels(_ labels: [String: String]) -> [(String, String)] {
    labels.sorted { $0.key < $1.key }
}

/// Java `Instant.toString()` / `Instant.parse` for `createdAt`: ISO-8601 UTC with 0, 3, 6
/// or 9 fraction digits as needed.
enum InstantFormat {
    static func format(_ date: Date) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        var seconds = micros / 1_000_000
        var fraction = micros % 1_000_000
        if fraction < 0 { fraction += 1_000_000; seconds -= 1 }
        var t = time_t(seconds)
        var parts = tm()
        gmtime_r(&t, &parts)
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1,
                          Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
        if fraction == 0 { return base + "Z" }
        if fraction % 1000 == 0 { return base + String(format: ".%03d", Int(fraction / 1000)) + "Z" }
        return base + String(format: ".%06d", Int(fraction)) + "Z"
    }

    /// Epoch when unparseable.
    static func parse(_ text: String) -> Date {
        let pattern = try! Regex(#"^(\d{4,})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$"#, as: (Substring, Substring, Substring, Substring, Substring, Substring, Substring, Substring?).self)
        guard let m = text.wholeMatch(of: pattern) else { return Date(timeIntervalSince1970: 0) }
        var parts = tm()
        parts.tm_year = Int32(m.1)! - 1900
        parts.tm_mon = Int32(m.2)! - 1
        parts.tm_mday = Int32(m.3)!
        parts.tm_hour = Int32(m.4)!
        parts.tm_min = Int32(m.5)!
        parts.tm_sec = Int32(m.6)!
        let seconds = timegm(&parts)
        var fraction = 0.0
        if let f = m.7 {
            fraction = Double("0." + f) ?? 0
        }
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
