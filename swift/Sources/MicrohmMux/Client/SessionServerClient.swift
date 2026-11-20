import Foundation

/// The library the app (and the CLI) use to talk to a session server. One instance per
/// server home. Every control call opens a short-lived connection (request/response, then
/// close) — cheap on a Unix socket, and it keeps the client stateless across server
/// restarts. `attach` opens a dedicated connection that lives as long as the attachment.
///
/// **Only `newSession` spawns a server** (tmux parity: only `new-session` starts a tmux
/// server). When no server is listening (socket missing, connect refused, or EOF before
/// the response) every other call reports "no server running" the way tmux does: `list` →
/// empty, `has` → false, `capture` → nil, `kill` and `shutdown` → return normally,
/// `currentPath`, `sendKeys`, `input`, `label`, `awaitQuiet`, `watch` and `attach` →
/// `SessionServerException` whose `isNoServer` is true. `newSession` spawns through
/// `ServerLauncher` and poll-connects for up to `CONNECT_TIMEOUT_SECONDS`
/// (missing/refused/EOF all mean keep polling); spawning is serialized per client instance
/// so concurrent callers join one in-flight spawn.
///
/// Every request carries `"protocol": MuxProtocol.VERSION`. A server that answers with a
/// protocol mismatch produces a `SessionServerException` naming its version and pid and
/// telling the user to finish its sessions or run `shutdown`; the client never spawns,
/// kills or replaces a running server on a mismatch.
///
/// Every call that may fail throws `SessionServerException` (Java threw it unchecked).
public final class SessionServerClient: @unchecked Sendable {

    public static let CONNECT_TIMEOUT_SECONDS: TimeInterval = 10

    /// How long a request/response call waits for a reply that has stopped coming before it
    /// gives up (a wedged or stopped server must not hang the app's main thread at quit).
    /// `awaitQuiet` waits this long beyond its own timeout. Attach and watch never time out.
    public static let REQUEST_TIMEOUT_SECONDS: TimeInterval = 10

    /// `REQUEST_TIMEOUT_SECONDS` unless a test shortens it.
    var requestTimeout: TimeInterval = SessionServerClient.REQUEST_TIMEOUT_SECONDS

    /// How a server answers an operation it does not know (every build so far).
    private static let UNKNOWN_OP_PREFIX = "unknown op: "

    /// How often the post-spawn poll retries the connect.
    private static let SPAWN_POLL_INTERVAL: TimeInterval = 0.1

    public let home: URL
    private let spawn: Bool
    /// How a server is started (`ServerLauncher.spawn` outside tests).
    private let spawner: (URL) throws -> SpawnedProcess
    /// The one spawn in flight for this home, joined by every concurrent `newSession`.
    private let spawnLock = NSCondition()
    private var spawnInFlight = false
    private var spawnGeneration = 0
    private var spawnFailure: (generation: Int, error: Error)?

    /// A client over the default home (`ServerHome.resolve()`) with auto-spawn; `launcher`
    /// is the `microhm-mux` executable to start the daemon with (nil = resolve it, see
    /// `ServerLauncher`).
    public static func forDefaultHome(launcher: URL? = nil) -> SessionServerClient {
        SessionServerClient(home: ServerHome.resolve(), spawn: true, launcher: launcher)
    }

    /// `spawn` false disables auto-spawn entirely (tests that bind their own server
    /// in-process must use this so a race can never fork a real daemon).
    public convenience init(home: URL, spawn: Bool, launcher: URL? = nil) {
        self.init(home: home, spawn: spawn, spawner: { try ServerLauncher.spawn($0, launcher: launcher) })
    }

    /// Test seam: a client whose spawn step is `spawner` instead of the real launcher.
    init(home: URL, spawn: Bool, spawner: @escaping (URL) throws -> SpawnedProcess) {
        self.home = home.standardizedFileURL
        self.spawn = spawn
        self.spawner = spawner
    }

    private var socketFile: URL { ServerHome.socket(home) }

    /// True if a server answers `ping` right now; never spawns one. Throws on a protocol
    /// mismatch (a server is there, but not one this client can talk to).
    public func isServerRunning() throws -> Bool {
        try ping() != nil
    }

    public struct ServerInfo: Equatable, Sendable {
        public let `protocol`: Int
        public let version: String
        public let pid: Int64
    }

    /// Nil when no server is running.
    public func ping() throws -> ServerInfo? {
        try request(MuxProtocol.OP_PING, nil).map { reply in
            ServerInfo(protocol: JsonDecoding.path(reply, MuxProtocol.F_PROTOCOL).asInt(0),
                       version: JsonDecoding.text(reply, MuxProtocol.F_VERSION),
                       pid: JsonDecoding.path(reply, MuxProtocol.F_PID).asLong(0))
        }
    }

    public func list() throws -> [SessionInfo] {
        try request(MuxProtocol.OP_LIST, nil).map { JsonDecoding.infos($0[MuxProtocol.F_SESSIONS]) } ?? []
    }

    public func has(_ name: String) throws -> Bool {
        try request(MuxProtocol.OP_HAS, named(name)).map {
            JsonDecoding.path($0, MuxProtocol.F_PRESENT).asBoolean(false)
        } ?? false
    }

    /// What `new` reported: the session's `pid` (0 when the daemon did not say) and
    /// `backend` (empty likewise), and whether the requested environment was applied —
    /// false only when a non-empty `env` was sent and the reply lacks the daemon's `env`
    /// acknowledgement, i.e. a daemon that predates `env` started the session without it.
    public struct NewSessionResult: Equatable, Sendable {
        public let pid: Int64
        public let backend: String
        public let envApplied: Bool
    }

    /// `command` nil/empty = the platform login shell; `labels` the initial labels;
    /// `env` variables merged into the session's environment after the server's defaults
    /// (`TERM` and `MICROHM_SESSION` cannot be overridden). Spawns the server if needed.
    @discardableResult
    public func newSession(_ name: String, workdir: URL, columns: Int, rows: Int, command: [String]? = nil,
                           labels: [String: String]? = nil, env: [String: String]? = nil) throws -> NewSessionResult {
        var args = named(name)
            .with(MuxProtocol.F_WORKDIR, workdir.standardizedFileURL.path)
            .with(MuxProtocol.F_COLUMNS, columns)
            .with(MuxProtocol.F_ROWS, rows)
        if let command, !command.isEmpty {
            args[MuxProtocol.F_COMMAND] = .array(command.map(JSON.string))
        }
        if let labels, !labels.isEmpty {
            args[MuxProtocol.F_LABELS] = stringObject(labels)
        }
        if let env, !env.isEmpty {
            args[MuxProtocol.F_ENV] = stringObject(env)
        }
        var reply: JSONObject?
        do {
            reply = try request(MuxProtocol.OP_NEW, args)
        } catch let error as SessionServerException {
            if error.message != SessionManagerConstants.CLOSED {
                throw error
            }
            // Caught the server on its way out (idle exit or a shutdown): the same as
            // finding none, once it has let go of the home.
            awaitServerGone()
            reply = nil
        }
        if reply == nil {
            try ensureServer()
            reply = try request(MuxProtocol.OP_NEW, args)
        }
        guard let created = reply else {
            throw SessionServerException("session server at \(home.path) stopped answering after it started")
        }
        let envSent = env.map { !$0.isEmpty } ?? false
        return NewSessionResult(pid: JsonDecoding.path(created, MuxProtocol.F_PID).asLong(0),
                                backend: JsonDecoding.text(created, MuxProtocol.F_BACKEND),
                                envApplied: !envSent || JsonDecoding.path(created, MuxProtocol.F_ENV).asBoolean(false))
    }

    public func kill(_ name: String) throws {
        _ = try request(MuxProtocol.OP_KILL, named(name))
    }

    public func sendKeys(_ name: String, text: String, enter: Bool) throws {
        let args = named(name).with(MuxProtocol.F_TEXT, text).with(MuxProtocol.F_ENTER, enter)
        guard try request(MuxProtocol.OP_SEND_KEYS, args) != nil else { throw SessionServerException.noServer(name) }
    }

    /// Merges `changes` into the session's labels (a nil value removes the key) and returns
    /// the resulting labels.
    public func label(_ name: String, changes: [String: String?]) throws -> [String: String] {
        var labels = Json.object()
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            labels[key] = value.map(JSON.string) ?? .null
        }
        let args = named(name).with(MuxProtocol.F_LABELS, .object(labels))
        guard let reply = try request(MuxProtocol.OP_LABEL, args) else { throw SessionServerException.noServer(name) }
        return JsonDecoding.labels(reply[MuxProtocol.F_LABELS])
    }

    /// `text` (nil = none) as a paste or raw typing, then the named `keys` (nil/empty =
    /// none). An unknown key name fails before anything is written. With
    /// `requireBracketedPaste` a paste the program has not enabled bracketed paste for is
    /// refused, nothing written, instead of being typed raw
    /// (`MuxProtocol.ERROR_BRACKETED_PASTE_DISABLED`).
    public func input(_ name: String, text: String?, paste: Bool, requireBracketedPaste: Bool = false,
                      keys: [String]?) throws {
        var args = named(name).with(MuxProtocol.F_PASTE, paste)
        if requireBracketedPaste {
            args[MuxProtocol.F_REQUIRE_BRACKETED_PASTE] = .bool(true)
        }
        if let text {
            args[MuxProtocol.F_TEXT] = .string(text)
        }
        if let keys, !keys.isEmpty {
            args[MuxProtocol.F_KEYS] = .array(keys.map(JSON.string))
        }
        guard try request(MuxProtocol.OP_INPUT, args) != nil else { throw SessionServerException.noServer(name) }
    }

    /// Blocks until the session's output is quiet (see `Session.awaitQuiet`); the server
    /// clamps both durations to `WAIT_MAX_MS`.
    public func awaitQuiet(_ name: String, sinceBytes: Int64, quietMs: Int64, timeoutMs: Int64) throws -> WaitResult {
        let args = named(name)
            .with(MuxProtocol.F_SINCE_BYTES, sinceBytes)
            .with(MuxProtocol.F_QUIET_MS, quietMs)
            .with(MuxProtocol.F_TIMEOUT_MS, timeoutMs)
        // The server holds the reply for up to the (clamped) timeout: the read may wait
        // that long on top of the usual allowance.
        let holdSeconds = Double(max(0, min(MuxProtocol.WAIT_MAX_MS, timeoutMs))) / 1000
        guard let reply = try request(MuxProtocol.OP_WAIT, args,
                                      timeout: requestTimeout + holdSeconds) else {
            throw SessionServerException.noServer(name)
        }
        return WaitResult(quiet: JsonDecoding.path(reply, MuxProtocol.F_QUIET).asBoolean(false),
                          outputBytes: JsonDecoding.path(reply, MuxProtocol.F_OUTPUT_BYTES).asLong(0),
                          alive: JsonDecoding.path(reply, MuxProtocol.F_ALIVE).asBoolean(false))
    }

    /// A live `watch` stream; `close` ends it.
    public protocol Watch: AnyObject {
        /// False once the server ended the stream (EOF, or dropped for falling behind) or
        /// after `close`.
        var isOpen: Bool { get }

        /// The server's reason when it ended the stream with an error (a watcher that fell
        /// too far behind), else nil: an EOF, a normal end or `close`.
        var error: String? { get }

        func close()
    }

    /// Opens a dedicated connection that streams events of the `names` sessions (nil or
    /// empty = every session, including ones created later) to `onEvent`, in order, on a
    /// reader thread. `quietMs` is the silence that raises `quiet`.
    public func watch(names: [String]?, quietMs: Int64, onEvent: @escaping (SessionEvent) -> Void) throws -> Watch {
        let all = names?.isEmpty ?? true
        let noServer = {
            all ? SessionServerException("no session server is running at \(self.home.path)", noServer: true)
                : SessionServerException.noServer(names![0])
        }
        guard let connection = try ServerConnection.open(socketFile) else { throw noServer() }
        var handedOver = false
        defer { if !handedOver { connection.close() } }
        var args = Json.object().with(MuxProtocol.F_QUIET_MS, quietMs)
        if !all {
            args[MuxProtocol.F_NAMES] = .array(names!.map(JSON.string))
        }
        do {
            try checkOk(try connection.request(MuxProtocol.OP_WATCH, args))
        } catch is ServerConnection.NoServerError {
            throw noServer()
        } catch let error as SessionServerException {
            throw error
        } catch {
            throw SessionServerException("watch failed: \(error)", cause: error)
        }
        handedOver = true
        return SocketWatch(connection: connection, onEvent: onEvent)
    }

    /// A capture and the format the server says it is in.
    public struct FormattedCapture: Equatable, Sendable {
        public let capture: SessionCapture
        public let format: CaptureFormat
    }

    /// Nil when the session (or the server) does not exist. Up to `historyLines` lines of
    /// the scrollback above the screen come along (`SessionCapture.history`). A daemon that
    /// predates capture formats answers with plain text and no `format` echo; asking it for
    /// anything but TEXT (or for history) throws `SessionServerException.unsupported`
    /// instead of passing that text off as what was asked for.
    public func capture(_ name: String, format: CaptureFormat = .TEXT, historyLines: Int = 0) throws -> SessionCapture? {
        try captureWithFormat(name, format: format, historyLines: historyLines)?.capture
    }

    /// `capture` plus the server's echoed format.
    public func captureWithFormat(_ name: String, format: CaptureFormat, historyLines: Int = 0) throws -> FormattedCapture? {
        try captureWithFormat(name, format, historyLines > 0 ? MuxProtocol.F_HISTORY : nil, Int64(historyLines))
    }

    /// `capture` plus the scrollback lines added after the first `since` ever added, those
    /// the session still holds: pass back the previous reply's `history.added` to get each
    /// line once.
    public func captureSince(_ name: String, format: CaptureFormat, since: Int64) throws -> SessionCapture? {
        try captureWithFormat(name, format, MuxProtocol.F_HISTORY_SINCE, max(0, since))?.capture
    }

    private func captureWithFormat(_ name: String, _ format: CaptureFormat, _ historyField: String?,
                                   _ historyValue: Int64) throws -> FormattedCapture? {
        var query = named(name).with(MuxProtocol.F_FORMAT, format.wireName)
        if let historyField {
            query[historyField] = .int(historyValue)
        }
        let reply: JSONObject?
        do {
            reply = try request(MuxProtocol.OP_CAPTURE, query)
        } catch let error as SessionServerException where error.message.hasPrefix("no such session") {
            return nil
        }
        guard let node = reply else { return nil }
        let echoed = JsonDecoding.text(node, MuxProtocol.F_FORMAT)
        let actual = echoed.isEmpty ? CaptureFormat.TEXT : CaptureFormat.fromWireName(echoed)
        if actual != format {
            throw SessionServerException.unsupported("capture format \(format.wireName)"
                                                     + (echoed.isEmpty ? "" : " (it answered \(echoed))"))
        }
        if historyField != nil && !node.has(MuxProtocol.F_HISTORY_ADDED) {
            throw SessionServerException.unsupported("capture history")
        }
        return FormattedCapture(capture: JsonDecoding.capture(node), format: format)
    }

    public func currentPath(_ name: String) throws -> URL {
        guard let reply = try request(MuxProtocol.OP_CURRENT_PATH, named(name)) else {
            throw SessionServerException.noServer(name)
        }
        return URL(fileURLWithPath: JsonDecoding.text(reply, MuxProtocol.F_PATH))
    }

    /// Opens an attach-mode connection; the redraw bytes are the first thing readable.
    public func attach(_ name: String, columns: Int, rows: Int) throws -> AttachedSession {
        guard let connection = try ServerConnection.open(socketFile) else { throw SessionServerException.noServer(name) }
        var handedOver = false
        defer { if !handedOver { connection.close() } }
        do {
            let reply = try connection.request(MuxProtocol.OP_ATTACH,
                                               named(name).with(MuxProtocol.F_COLUMNS, columns).with(MuxProtocol.F_ROWS, rows))
            try checkOk(reply)
        } catch is ServerConnection.NoServerError {
            throw SessionServerException.noServer(name)
        } catch let error as SessionServerException {
            throw error
        } catch {
            throw SessionServerException("attach to \(name) failed: \(error)", cause: error)
        }
        handedOver = true
        return SocketAttachedSession(name: name, connection: connection)
    }

    /// Asks the server to exit (it kills its sessions); returns once the socket is closed.
    /// No-op if none runs.
    public func shutdown() throws {
        guard let connection = try ServerConnection.open(socketFile) else { return }
        defer { connection.close() }
        do {
            try checkOk(try connection.request(MuxProtocol.OP_SHUTDOWN, nil))
            connection.drainToEof()
        } catch is ServerConnection.NoServerError {
            // It went away before answering: shut down is shut down.
        } catch let error as SessionServerException {
            throw error
        } catch {
            throw SessionServerException("shutdown failed: \(error)", cause: error)
        }
    }

    /// One request/response over a fresh connection. Nil means no server is running; an
    /// `ok:false` reply (mismatch included) becomes a `SessionServerException`.
    private func request(_ op: String, _ args: JSONObject?, timeout: TimeInterval? = nil) throws -> JSONObject? {
        guard let connection = try ServerConnection.open(socketFile) else { return nil }
        defer { connection.close() }
        do {
            let reply = try connection.request(op, args, timeout: timeout ?? requestTimeout)
            try checkOk(reply)
            return reply
        } catch is ServerConnection.NoServerError {
            return nil
        } catch let error as SessionServerException {
            throw error
        } catch {
            throw SessionServerException("\(op) failed: \(error)", cause: error)
        }
    }

    private func checkOk(_ reply: JSONObject) throws {
        if JsonDecoding.path(reply, MuxProtocol.F_OK).asBoolean(false) {
            return
        }
        let error = JsonDecoding.text(reply, MuxProtocol.F_ERROR)
        if error.hasPrefix(SessionServerClient.UNKNOWN_OP_PREFIX) {
            // Same protocol, older build: it predates an operation added without a bump.
            throw SessionServerException.unsupported(String(error.dropFirst(SessionServerClient.UNKNOWN_OP_PREFIX.count)))
        }
        if error == MuxProtocol.ERROR_PROTOCOL_MISMATCH {
            let pid = JsonDecoding.path(reply, MuxProtocol.F_PID).asLong(0)
            throw SessionServerException("the session daemon \(JsonDecoding.text(reply, MuxProtocol.F_VERSION))"
                + " (pid \(pid)) speaks protocol \(JsonDecoding.path(reply, MuxProtocol.F_PROTOCOL).asInt(0));"
                + " this app needs \(MuxProtocol.VERSION). Finish its sessions or run `microhm-mux shutdown`, then"
                + " retry (a daemon too old to take that shutdown answers with this same message: stop it with"
                + " `kill \(pid)`)")
        }
        throw SessionServerException(error.isEmpty ? "request refused" : error)
    }

    /// Makes sure a server answers, spawning one when allowed. Concurrent callers share
    /// the spawn in flight; the poll ends on the first ping or at the deadline.
    private func ensureServer() throws {
        if try isServerRunning() {
            return
        }
        if !spawn {
            throw SessionServerException("no session server is running at \(home.path) and this client does not"
                                         + " spawn one", noServer: true)
        }
        spawnLock.lock()
        if spawnInFlight {
            // Join the spawn in flight.
            let generation = spawnGeneration
            while spawnInFlight && spawnGeneration == generation { spawnLock.wait() }
            let failure = spawnFailure
            spawnLock.unlock()
            if let failure, failure.generation == generation { throw failure.error }
            return
        }
        spawnInFlight = true
        let generation = spawnGeneration
        spawnLock.unlock()
        var failure: Error?
        do {
            try spawnAndWait()
        } catch {
            failure = error
        }
        spawnLock.lock()
        spawnFailure = failure.map { (generation, $0) }
        spawnInFlight = false
        spawnGeneration += 1
        spawnLock.broadcast()
        spawnLock.unlock()
        if let failure {
            if failure is SessionServerException { throw failure }
            throw SessionServerException("starting the session server failed", cause: failure)
        }
    }

    /// Waits, up to the connect deadline, for an exiting server to stop listening. Past the
    /// deadline the caller's retry simply reports whatever that server answers.
    private func awaitServerGone() {
        let deadline = Date(timeIntervalSinceNow: SessionServerClient.CONNECT_TIMEOUT_SECONDS)
        while Date() < deadline {
            guard let connection = try? ServerConnection.open(socketFile) else { return }
            connection.close()
            Thread.sleep(forTimeInterval: SessionServerClient.SPAWN_POLL_INTERVAL)
        }
    }

    private func spawnAndWait() throws {
        let process = try spawner(home)
        let deadline = Date(timeIntervalSinceNow: SessionServerClient.CONNECT_TIMEOUT_SECONDS)
        while true {
            // ping() throws on a protocol mismatch: a connected outcome that ends the poll.
            if try ping() != nil {
                return
            }
            // A spawned server that failed will never start listening (a socket path over
            // the OS limit, an unwritable home): fail now with its own words instead of
            // making the user wait out the full deadline. Exit 0 is different: it means a
            // concurrently spawned peer already owns the lock and is about to listen (see
            // SessionServer.start), so that case keeps polling.
            if let status = process.exitValue, status != 0 {
                throw SessionServerException("the session daemon exited with status \(status) before listening on "
                                             + socketFile.path + SessionServerClient.logTail(ServerHome.log(home)))
            }
            if Date() >= deadline {
                throw SessionServerException("the session daemon did not start listening on \(socketFile.path) within"
                                             + " \(Int(SessionServerClient.CONNECT_TIMEOUT_SECONDS)) s; see"
                                             + " \(ServerHome.log(home).path)")
            }
            Thread.sleep(forTimeInterval: SessionServerClient.SPAWN_POLL_INTERVAL)
        }
    }

    private func named(_ name: String) -> JSONObject {
        Json.object().with(MuxProtocol.F_NAME, name)
    }

    private func stringObject(_ map: [String: String]) -> JSON {
        var object = Json.object()
        for (key, value) in map.sorted(by: { $0.key < $1.key }) { object[key] = .string(value) }
        return .object(object)
    }

    /// The last few lines of the server log, formatted for an error message.
    private static func logTail(_ log: URL) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let tail = lines.suffix(5)
        return tail.isEmpty ? "" : "; \(log.path) ends with:\n" + tail.joined(separator: "\n")
    }
}
