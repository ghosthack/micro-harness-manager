import Foundation
import MicrohmMux

/// What the `SessionController` needs from the session daemon — a seam so tests can drive
/// the controller without a daemon. The production implementation is
/// `ClientDaemonControl` over the app's `SessionServerClient`. Every call may block on a
/// socket round trip and may throw (no server, no such session, a refused request); the
/// controller turns those into tool errors.
///
/// A daemon outlives app upgrades, so the one running may predate some of these calls
/// (input, wait, watch, label, capture formats other than text, capture history): it
/// refuses them with a `SessionServerException` whose `isUnsupported` is true, and capture
/// reports `outputBytes` as -1 (unknown). The controller degrades on those.
public protocol DaemonControl: AnyObject {

    /// Every session the daemon hosts; empty when no daemon runs.
    func list() throws -> [SessionInfo]

    /// The screen in `format`; nil when the session (or the daemon) is gone.
    func capture(_ name: String, _ format: CaptureFormat) throws -> SessionCapture?

    /// `capture` plus the scrollback lines added after the first `since` ever added, those
    /// still held (`SessionCapture.history`): pass back the previous capture's `added` to
    /// get each line once. A daemon that predates history refuses it as unsupported.
    func captureSince(_ name: String, _ format: CaptureFormat, _ since: Int64) throws -> SessionCapture?

    /// `text` (nil = none) pasted or typed, then the named `keys` (nil or empty = none).
    /// With `requireBracketedPaste` a paste into a program that has not enabled bracketed
    /// paste is refused with nothing written — a `SessionServerException` whose message is
    /// `MuxProtocol.ERROR_BRACKETED_PASTE_DISABLED` — instead of being typed raw. An unknown
    /// key name fails before anything is written.
    func input(_ name: String, _ text: String?, _ paste: Bool, _ requireBracketedPaste: Bool, _ keys: [String]?) throws

    /// Blocks until the output is quiet; see `Session.awaitQuiet`.
    func awaitQuiet(_ name: String, _ sinceBytes: Int64, _ quietMs: Int64, _ timeoutMs: Int64) throws -> WaitResult

    /// Streams the events of every session, including later ones, to `onEvent` until
    /// closed or until the daemon ends the stream (`DaemonWatch.isOpen` false).
    func watch(_ quietMs: Int64, _ onEvent: @escaping (SessionEvent) -> Void) throws -> DaemonWatch

    /// The old `send-keys` op every daemon supports: `text` typed as is (not a paste — a
    /// newline in it submits), then when `enter` the server's 400 ms pause and Enter. Only
    /// used when the daemon predates `input`.
    func sendKeys(_ name: String, _ text: String, _ enter: Bool) throws

    /// Resizes `name`'s terminal for every viewer: a moment's attach at that size, which
    /// the daemon applies and keeps after the detach.
    func resize(_ name: String, _ columns: Int, _ rows: Int) throws

    /// The running daemon's process id (from ping); nil when none answers.
    func daemonPid() throws -> Int64?

    /// Whether a daemon answers a ping right now — what tells "the session is gone" from
    /// "the daemon is unreachable" when `list` or `capture` comes back empty.
    func ping() throws -> Bool

    func kill(_ name: String) throws

    /// Merges `changes` into the session's labels (a nil value removes a key).
    func label(_ name: String, _ changes: [String: String?]) throws
}

public extension DaemonControl {
    func input(_ name: String, _ text: String?, _ paste: Bool, _ keys: [String]?) throws {
        try input(name, text, paste, false, keys)
    }

    func resize(_ name: String, _ columns: Int, _ rows: Int) throws {
        throw SessionHostException("resize is not supported")
    }
}

/// A live event stream.
public protocol DaemonWatch: AnyObject {
    var isOpen: Bool { get }
    func close()
}

/// `DaemonControl` over the daemon client library — a pass-through; the client never
/// spawns a daemon for any of these calls.
public final class ClientDaemonControl: DaemonControl, @unchecked Sendable {

    private let client: SessionServerClient

    public init(_ client: SessionServerClient) {
        self.client = client
    }

    public func list() throws -> [SessionInfo] {
        try client.list()
    }

    public func capture(_ name: String, _ format: CaptureFormat) throws -> SessionCapture? {
        try client.capture(name, format: format)
    }

    public func captureSince(_ name: String, _ format: CaptureFormat, _ since: Int64) throws -> SessionCapture? {
        try client.captureSince(name, format: format, since: since)
    }

    public func input(_ name: String, _ text: String?, _ paste: Bool, _ requireBracketedPaste: Bool,
                      _ keys: [String]?) throws {
        try client.input(name, text: text, paste: paste, requireBracketedPaste: requireBracketedPaste, keys: keys)
    }

    public func awaitQuiet(_ name: String, _ sinceBytes: Int64, _ quietMs: Int64, _ timeoutMs: Int64) throws -> WaitResult {
        try client.awaitQuiet(name, sinceBytes: sinceBytes, quietMs: quietMs, timeoutMs: timeoutMs)
    }

    public func watch(_ quietMs: Int64, _ onEvent: @escaping (SessionEvent) -> Void) throws -> DaemonWatch {
        ClientWatch(try client.watch(names: nil, quietMs: quietMs, onEvent: onEvent))
    }

    public func sendKeys(_ name: String, _ text: String, _ enter: Bool) throws {
        try client.sendKeys(name, text: text, enter: enter)
    }

    public func resize(_ name: String, _ columns: Int, _ rows: Int) throws {
        // attaching at a size resizes the session; closing detaches and the size stays
        try client.attach(name, columns: columns, rows: rows).close()
    }

    public func daemonPid() throws -> Int64? {
        try client.ping()?.pid
    }

    public func ping() throws -> Bool {
        try client.isServerRunning()
    }

    public func kill(_ name: String) throws {
        try client.kill(name)
    }

    public func label(_ name: String, _ changes: [String: String?]) throws {
        _ = try client.label(name, changes: changes)
    }

    private final class ClientWatch: DaemonWatch {
        let watch: SessionServerClient.Watch
        init(_ watch: SessionServerClient.Watch) { self.watch = watch }
        var isOpen: Bool { watch.isOpen }
        func close() { watch.close() }
    }
}
