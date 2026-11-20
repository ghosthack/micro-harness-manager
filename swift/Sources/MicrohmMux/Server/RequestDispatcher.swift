import Foundation
import MicrohmVT

/// The request/response operations that do not change the connection's mode. A missing
/// session is always the error `no such session: <name>` so the client can map it onto the
/// app's "no such session" semantics.
final class RequestDispatcher: @unchecked Sendable {

    static let NO_SUCH_SESSION_PREFIX = "no such session: "

    let manager: SessionManager
    private unowned let server: SessionServer

    init(manager: SessionManager, server: SessionServer) {
        self.manager = manager
        self.server = server
    }

    /// Nil when `op` is unknown here (attach, watch and shutdown belong to the connection).
    func handle(_ op: String, _ request: JSONObject) -> JSONObject? {
        switch op {
        case MuxProtocol.OP_PING:
            return server.identity(Json.ok())
        case MuxProtocol.OP_LIST:
            return Json.ok().with(MuxProtocol.F_SESSIONS, JsonEncoding.infos(manager.sessions()))
        case MuxProtocol.OP_HAS:
            let name = RequestDispatcher.name(request)
            return Json.ok().with(MuxProtocol.F_PRESENT, manager.find(name) != nil)
        case MuxProtocol.OP_NEW:
            return create(request)
        case MuxProtocol.OP_KILL:
            manager.kill(RequestDispatcher.name(request))
            return Json.ok()
        case MuxProtocol.OP_SEND_KEYS:
            return withSession(request) { session in
                let text = JsonEncoding.textField(request, MuxProtocol.F_TEXT)
                let enter = request[MuxProtocol.F_ENTER]
                try session.sendKeys(text ?? "", enter: enter == nil || enter!.asBoolean(true))
                return Json.ok()
            }
        case MuxProtocol.OP_CAPTURE:
            return capture(request)
        case MuxProtocol.OP_LABEL:
            return label(request)
        case MuxProtocol.OP_INPUT:
            return input(request)
        case MuxProtocol.OP_WAIT:
            return awaitQuiet(request)
        case MuxProtocol.OP_CURRENT_PATH:
            return withSession(request) { session in
                Json.ok().with(MuxProtocol.F_PATH, session.currentPath().path)
            }
        default:
            return nil
        }
    }

    func find(_ request: JSONObject) -> Session? {
        let name = RequestDispatcher.name(request)
        return name.isEmpty ? nil : manager.find(name)
    }

    static func noSuchSession(_ name: String) -> JSONObject {
        Json.error(NO_SUCH_SESSION_PREFIX + name)
    }

    /// Bounds for a requested terminal size; the emulator clamps tiny sizes upward itself,
    /// but a zero or absurd size must never reach the PTY spawn.
    static let MAX_COLUMNS = 4000
    static let MAX_ROWS = 2000

    /// The error text for an unusable size, or nil when it is acceptable.
    static func invalidSize(_ columns: Int, _ rows: Int) -> String? {
        if columns < 1 || columns > MAX_COLUMNS || rows < 1 || rows > MAX_ROWS {
            return "invalid size \(columns)x\(rows) (1..\(MAX_COLUMNS) columns, 1..\(MAX_ROWS) rows)"
        }
        return nil
    }

    private func create(_ request: JSONObject) -> JSONObject {
        let name = RequestDispatcher.name(request)
        if name.isEmpty {
            return Json.error("session name is required")
        }
        let columns = JsonEncoding.intField(request, MuxProtocol.F_COLUMNS, 80)
        let rows = JsonEncoding.intField(request, MuxProtocol.F_ROWS, 24)
        if let badSize = RequestDispatcher.invalidSize(columns, rows) {
            return Json.error(badSize)
        }
        guard let workdir = JsonEncoding.textField(request, MuxProtocol.F_WORKDIR),
              !workdir.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Json.error("workdir is required")
        }
        let labels: [String: String?]
        let env: [String: String]
        do {
            labels = try RequestDispatcher.labels(request[MuxProtocol.F_LABELS], allowNull: false)
            env = try RequestDispatcher.environment(request[MuxProtocol.F_ENV])
        } catch {
            return Json.error("\(error)")
        }
        var command: [String] = []
        if let commandNode = request[MuxProtocol.F_COMMAND], !commandNode.isNull {
            // Anything else would silently start a login shell in place of what was asked.
            guard case .array(let array) = commandNode else {
                return Json.error("command must be an array of strings")
            }
            for arg in array {
                guard case .string(let s) = arg else { return Json.error("command must be an array of strings") }
                command.append(s)
            }
        }
        do {
            let session = try manager.create(name: name, workdir: URL(fileURLWithPath: workdir), columns: columns,
                                             rows: rows, command: command, labels: labels.compactMapValues { $0 },
                                             environment: env)
            let info = session.info()
            var reply = Json.ok().with(MuxProtocol.F_PID, info.pid).with(MuxProtocol.F_BACKEND, info.backend)
            if !env.isEmpty {
                // The ack: a daemon that predates env ignores the field and omits this, which
                // is how a client tells "applied" from "silently dropped".
                reply[MuxProtocol.F_ENV] = .bool(true)
            }
            return reply
        } catch {
            return Json.error("\(error)")
        }
    }

    private func capture(_ request: JSONObject) -> JSONObject {
        let formatName = JsonEncoding.textField(request, MuxProtocol.F_FORMAT)
        let format = formatName == nil ? CaptureFormat.TEXT : CaptureFormat.fromWireName(formatName)
        guard let format else {
            return Json.error("unknown capture format: \(formatName ?? "") (text, annotated or ansi)")
        }
        let history = max(0, JsonEncoding.intField(request, MuxProtocol.F_HISTORY, 0))
        let since = JsonEncoding.longField(request, MuxProtocol.F_HISTORY_SINCE, -1)
        return withSession(request) { session in
            JsonEncoding.capture(since >= 0 ? session.captureSince(format, since: since)
                                            : session.capture(format, historyLines: history), format)
        }
    }

    private func label(_ request: JSONObject) -> JSONObject {
        let changes: [String: String?]
        do {
            changes = try RequestDispatcher.labels(request[MuxProtocol.F_LABELS], allowNull: true)
        } catch {
            return Json.error("\(error)")
        }
        return withSession(request) { session in
            session.label(changes)
            return Json.ok().with(MuxProtocol.F_LABELS, .object(JsonEncoding.labels(session.labels())))
        }
    }

    /// Validates everything (key names included) before writing anything, so a bad key
    /// never leaves half an input in the PTY.
    private func input(_ request: JSONObject) -> JSONObject {
        let textNode = request[MuxProtocol.F_TEXT]
        if let textNode, !textNode.isNull, !textNode.isTextual {
            return Json.error("text must be a string")
        }
        let text = textNode?.stringValue
        var keys: [String] = []
        if let keysNode = request[MuxProtocol.F_KEYS], !keysNode.isNull {
            guard case .array(let array) = keysNode else { return Json.error("keys must be an array of key names") }
            for key in array {
                guard case .string(let s) = key else { return Json.error("keys must be an array of key names") }
                keys.append(s)
            }
        }
        if text == nil && keys.isEmpty {
            return Json.error("input needs text or keys")
        }
        do {
            _ = try KeyNames.encode(keys, false)
        } catch {
            return Json.error("\(error)")
        }
        let paste = JsonEncoding.booleanField(request, MuxProtocol.F_PASTE, false)
        let requireBracketed = JsonEncoding.booleanField(request, MuxProtocol.F_REQUIRE_BRACKETED_PASTE, false)
        return withSession(request) { session in
            if let text {
                if paste && requireBracketed {
                    // Checked and written in one step by the session; refused = nothing
                    // written, keys included.
                    if try !session.pasteIfBracketed(text) {
                        return Json.error(MuxProtocol.ERROR_BRACKETED_PASTE_DISABLED)
                    }
                } else if paste {
                    try session.paste(text)
                } else {
                    try session.write(Array(text.utf8))
                }
            }
            if !keys.isEmpty {
                try session.input(keys)
            }
            return Json.ok()
        }
    }

    /// Inline on the connection's thread: only this connection waits.
    private func awaitQuiet(_ request: JSONObject) -> JSONObject {
        let sinceBytes = JsonEncoding.longField(request, MuxProtocol.F_SINCE_BYTES, -1)
        let quietMs = RequestDispatcher.clampMs(JsonEncoding.longField(request, MuxProtocol.F_QUIET_MS,
                                                                       MuxProtocol.WAIT_DEFAULT_QUIET_MS))
        let timeoutMs = RequestDispatcher.clampMs(JsonEncoding.longField(request, MuxProtocol.F_TIMEOUT_MS,
                                                                         MuxProtocol.WAIT_DEFAULT_TIMEOUT_MS))
        return withSession(request) { session in
            let result = session.awaitQuiet(sinceBytes: sinceBytes, quietMs: quietMs, timeoutMs: timeoutMs)
            return Json.ok()
                .with(MuxProtocol.F_QUIET, result.quiet)
                .with(MuxProtocol.F_OUTPUT_BYTES, result.outputBytes)
                .with(MuxProtocol.F_ALIVE, result.alive)
        }
    }

    /// A duration request field clamped to 0..WAIT_MAX_MS.
    static func clampMs(_ ms: Int64) -> Int64 {
        max(0, min(MuxProtocol.WAIT_MAX_MS, ms))
    }

    /// A `labels` object as a map. With `allowNull` a JSON null value is kept as a nil
    /// (remove) entry; without, it is an error. Absent/null object = empty.
    static func labels(_ node: JSON?, allowNull: Bool) throws -> [String: String?] {
        var labels: [String: String?] = [:]
        guard let node, !node.isNull else { return labels }
        guard case .object(let object) = node else { throw MuxError("labels must be an object of strings") }
        for (key, value) in object.fields {
            if case .string(let s) = value {
                labels[key] = .some(s)
            } else if value.isNull && allowNull {
                labels[key] = .some(nil)
            } else {
                throw MuxError("label \(key) must be a string" + (allowNull ? " or null" : ""))
            }
        }
        return labels
    }

    /// An `env` object as a map: string values only, names non-empty and free of `=` and
    /// NUL, values free of NUL (neither can reach a process environment). Absent/null
    /// object = empty.
    static func environment(_ node: JSON?) throws -> [String: String] {
        var env: [String: String] = [:]
        guard let node, !node.isNull else { return env }
        guard case .object(let object) = node else { throw MuxError("env must be an object of strings") }
        for (key, value) in object.fields {
            if key.isEmpty || key.contains("=") || key.contains("\0") {
                throw MuxError("invalid environment variable name: '\(key)'")
            }
            guard case .string(let s) = value else { throw MuxError("env \(key) must be a string") }
            if s.contains("\0") {
                throw MuxError("env \(key) must not contain NUL")
            }
            env[key] = s
        }
        return env
    }

    private func withSession(_ request: JSONObject, _ body: (Session) throws -> JSONObject) -> JSONObject {
        let name = RequestDispatcher.name(request)
        guard !name.isEmpty, let session = manager.find(name) else {
            return RequestDispatcher.noSuchSession(name)
        }
        do {
            return try body(session)
        } catch {
            return Json.error("\(error)") // the sender's to act on, not an internal error
        }
    }

    private static func name(_ request: JSONObject) -> String {
        JsonEncoding.textField(request, MuxProtocol.F_NAME) ?? ""
    }
}
