import CommonCrypto
import Foundation
import MicrohmShared

/// A minimal MCP server over "Streamable HTTP": JSON-RPC 2.0 on `POST /mcp`, every answer a
/// plain `application/json` body (no SSE stream — `GET` is 405, which the spec allows).
/// Serves the tools of one `McpToolset`.
///
/// The URL path carries the caller's identity: `http://127.0.0.1:<port>/mcp/<caller>` (see
/// `callerUrl`); `/mcp` without a path segment is an anonymous caller. The shared secret
/// goes in an `Authorization: Bearer <token>` header — how the app's own launched agents
/// send it — or, for manual clients whose config is a single URL string, in the query:
/// `?token=<token>` (see `urlFor`).
///
/// Security: binds the loopback interface only; rejects requests carrying an `Origin`
/// header that is not localhost (403 — DNS-rebinding guard) and requests without the token
/// (401, constant-time compare); bodies over 1 MiB get 413. Toolset errors become `isError`
/// tool results, never HTTP failures.
///
/// Requests are served on a thread per connection; a slow tool call does not hold up others.
public final class McpServer: @unchecked Sendable {

    /// Newest first; the first one is answered when the client asks for anything else.
    static let PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let SERVER_NAME = "micro-harness-manager"
    static let MAX_BODY_BYTES = 1 << 20
    /// How much of an oversized body is read and discarded so the 413 reaches the client.
    private static let MAX_DRAIN_BYTES: Int64 = 16 << 20
    static let CONTEXT = "/mcp"

    static let PARSE_ERROR = -32700
    static let INVALID_REQUEST = -32600
    static let METHOD_NOT_FOUND = -32601
    static let INVALID_PARAMS = -32602

    static let INSTRUCTIONS = """
        micro-harness-manager lets you see and drive the other terminal sessions it hosts \
        (coding agents and shells running side by side with you).
        - Start with `list` to see the sessions, their harness, state, transcript path and log path.
        - `read` is incremental and cheap: it returns only what changed since your last read \
        of that session (or "unchanged"); pass full=true for the whole screen.
        - Answer prompts and menus with `keys`, one step at a time, and read the screen it \
        returns before the next step.
        - To wait for another session, use `notify` instead of polling with `read`: you get a \
        line typed into your session when the event happens.
        - The screen is only the visible terminal; a session's history lives in its transcript \
        file (claude-code, codex, muse and grok have one) and in a plain-text screen log kept \
        in your own project's .microhm-sessions/ folder (any harness, from your first `read` \
        of the session on, when the user has turned session logs on): `list` and whole-screen reads give both paths — tail or grep \
        them with your file tools rather than loading them whole.
        """

    private static let LOCAL_HOSTS: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    private let requestedPort: Int
    private let token: [UInt8]
    private let tokenText: String
    private let toolset: McpToolset
    private let serverVersion: String
    private let lock = NSLock()
    private var server: HttpServer?

    /// - port: TCP port on 127.0.0.1; 0 picks a free one (see `port`)
    /// - token: the shared secret every request must present
    /// - serverVersion: reported as `serverInfo.version`
    public init(_ port: Int, _ token: String, _ tools: McpToolset, _ serverVersion: String) throws {
        if port < 0 || port > 65535 {
            throw HttpError("port out of range: \(port)")
        }
        if token.isEmpty {
            throw HttpError("empty token")
        }
        self.requestedPort = port
        self.tokenText = token
        self.token = Array(token.utf8)
        self.toolset = tools
        self.serverVersion = serverVersion
    }

    /// Binds 127.0.0.1 and starts serving. Throws if the port is taken or already started.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        if server != nil {
            throw HttpError("already started")
        }
        let s = HttpServer(port: requestedPort, loopbackOnly: true, name: "mhm-mcp")
        try s.start { [weak self] exchange in
            guard let self else { return }
            try self.serve(exchange)
        }
        server = s
    }

    /// The bound port once started (the real one when constructed with 0), else the
    /// requested port.
    public var port: Int {
        lock.lock(); defer { lock.unlock() }
        return server?.port ?? requestedPort
    }

    /// The token-free URL for session `caller` — the token then goes in a bearer header;
    /// nil caller gives the anonymous URL.
    public func callerUrl(_ caller: String?) -> String {
        let path = caller.map { McpServer.CONTEXT + "/" + UrlCoding.encode($0) } ?? McpServer.CONTEXT
        return "http://127.0.0.1:\(port)" + path
    }

    /// `callerUrl` with the token in the query, for a manual client whose MCP config is a
    /// single URL string.
    public func urlFor(_ caller: String?) -> String {
        callerUrl(caller) + "?token=" + UrlCoding.encode(tokenText)
    }

    /// Stops immediately; idempotent. In-flight exchanges are abandoned.
    public func close() {
        lock.lock()
        let s = server
        server = nil
        lock.unlock()
        s?.close(wait: 0.2)
    }

    // MARK: - HTTP

    private func serve(_ exchange: HttpExchange) throws {
        guard let path = McpServer.parsePath(exchange.rawPath) else {
            try sendStatus(exchange, 404, "not found")
            return
        }
        if let origin = exchange.header("Origin"), !McpServer.isLocalOrigin(origin) {
            try sendStatus(exchange, 403, "forbidden origin")
            return
        }
        if !authorized(path.caller, exchange.rawQuery, exchange.header("Authorization")) {
            try sendStatus(exchange, 401, "missing or invalid token")
            return
        }
        if exchange.method != "POST" {
            exchange.setHeader("Allow", "POST")
            try sendStatus(exchange, 405, "method not allowed (POST JSON-RPC; no SSE stream offered)")
            return
        }
        guard let body = try exchange.readBody(limit: McpServer.MAX_BODY_BYTES, drainLimit: McpServer.MAX_DRAIN_BYTES) else {
            try sendStatus(exchange, 413, "request body over \(McpServer.MAX_BODY_BYTES) bytes")
            return
        }
        let result = dispatch(body, path.caller)
        guard let response = result.response else {
            try exchange.send(202, nil, nil)
            return
        }
        if result.initialized {
            exchange.setHeader("Mcp-Session-Id", UUID().uuidString.lowercased())
        }
        try McpServer.sendJson(exchange, 200, response)
    }

    /// The decoded caller (nil: anonymous).
    struct CallerPath: Equatable {
        let caller: String?
    }

    /// The caller of `rawPath`; nil when the path is not under `/mcp`.
    static func parsePath(_ rawPath: String?) -> CallerPath? {
        guard let rawPath else { return nil }
        if rawPath == CONTEXT || rawPath == CONTEXT + "/" {
            return CallerPath(caller: nil)
        }
        if !rawPath.hasPrefix(CONTEXT + "/") {
            return nil // e.g. "/mcpx"
        }
        var segment = String(rawPath.dropFirst(CONTEXT.count + 1))
        if segment.hasSuffix("/") {
            segment.removeLast()
        }
        if segment.isEmpty || segment.contains("/") {
            return nil
        }
        // Path semantics: '+' is literal, only %XX escapes are decoded.
        guard let caller = UrlCoding.formDecode(segment.replacingOccurrences(of: "+", with: "%2B")) else {
            return nil
        }
        return CallerPath(caller: caller.isEmpty ? nil : caller)
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URLComponents(string: origin.trimmingCharacters(in: .whitespaces))?.host else {
            return false
        }
        let h = host.lowercased()
        return LOCAL_HOSTS.contains(h) || LOCAL_HOSTS.contains("[" + h + "]")
    }

    private func authorized(_ caller: String?, _ rawQuery: String?, _ authorization: String?) -> Bool {
        if let authorization {
            let a = authorization.trimmingCharacters(in: .whitespaces)
            if a.count >= 7, a.prefix(7).lowercased() == "bearer ",
               matches(caller, String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces)) {
                return true
            }
        }
        if let rawQuery {
            for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
                guard let eq = pair.firstIndex(of: "="), eq > pair.startIndex, pair[..<eq] == "token" else { continue }
                guard let value = UrlCoding.formDecode(String(pair[pair.index(after: eq)...])) else { continue }
                if matches(caller, value) {
                    return true
                }
            }
        }
        return false
    }

    /// The server's own token opens every path (it is the user's key, for manual clients);
    /// a session's token opens only that session's path, so an agent cannot call as another
    /// session. Both comparisons always run, in constant time.
    private func matches(_ caller: String?, _ candidate: String) -> Bool {
        let given = Array(candidate.utf8)
        let owner = constantTimeEquals(token, given)
        let session = caller.map { constantTimeEquals(Array(sessionToken($0).utf8), given) } ?? false
        return owner || session
    }

    /// The token a launched session is given: derived from the server's token and the
    /// session's name (HMAC-SHA256, base64url without padding), so it authenticates
    /// `/mcp/<caller>` and no other caller's path, and reveals nothing about the server's
    /// token.
    public func sessionToken(_ caller: String) -> String {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let message = Array(caller.utf8)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), token, token.count, message, message.count, &mac)
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sendStatus(_ exchange: HttpExchange, _ status: Int, _ message: String) throws {
        try McpServer.sendJson(exchange, status, McpServer.errorResponse(.null, -32000, message))
    }

    private static func sendJson(_ exchange: HttpExchange, _ status: Int, _ body: CoreJSON) throws {
        try exchange.send(status, "application/json", Data(body.compact().utf8))
    }

    // MARK: - JSON-RPC

    /// A POST's answer: nil response means 202 with no body.
    private struct Exchange {
        let response: CoreJSON?
        let initialized: Bool
    }

    private func dispatch(_ body: Data, _ caller: String?) -> Exchange {
        if body.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            return Exchange(response: McpServer.errorResponse(.null, McpServer.PARSE_ERROR, "parse error: empty body"),
                            initialized: false)
        }
        guard let message = try? CoreJSON.parse(body) else {
            return Exchange(response: McpServer.errorResponse(.null, McpServer.PARSE_ERROR, "parse error"),
                            initialized: false)
        }
        var initialized = false
        if case .array(let items) = message {
            if items.isEmpty {
                return Exchange(response: McpServer.errorResponse(.null, McpServer.INVALID_REQUEST, "empty batch"),
                                initialized: false)
            }
            let responses = items.compactMap { process($0, caller, &initialized) }
            return Exchange(response: responses.isEmpty ? nil : .array(responses), initialized: initialized)
        }
        return Exchange(response: process(message, caller, &initialized), initialized: initialized)
    }

    /// One message's response, or nil for notifications and client responses.
    private func process(_ message: CoreJSON, _ caller: String?, _ initialized: inout Bool) -> CoreJSON? {
        guard message.isObject else {
            return McpServer.errorResponse(.null, McpServer.INVALID_REQUEST, "invalid request")
        }
        let method = message.get("method")
        let id = message.get("id")
        if method == nil && (message.has("result") || message.has("error")) {
            return nil // a response to a server request; we never send any, ignore
        }
        let validId = id == nil || id!.isTextual || id!.isNumber || id!.isNull
        let replyId: CoreJSON = id != nil && validId ? id! : .null
        guard let method, method.isTextual, message.path("jsonrpc").asText(nil) == "2.0", validId else {
            return McpServer.errorResponse(replyId, McpServer.INVALID_REQUEST, "invalid request")
        }
        guard let id else {
            return nil // notification (e.g. notifications/initialized): nothing to answer
        }
        let params = message.get("params")
        switch method.asText() {
        case "initialize":
            initialized = true
            return McpServer.resultResponse(id, initialize(params))
        case "ping":
            return McpServer.resultResponse(id, .object([]))
        case "tools/list":
            return McpServer.resultResponse(id, toolsList())
        case "tools/call":
            guard let params, params.path("name").isTextual else {
                return McpServer.errorResponse(id, McpServer.INVALID_PARAMS, "tools/call needs a string 'name'")
            }
            return McpServer.resultResponse(id, toolsCall(caller, params.path("name").asText(), params.get("arguments")))
        default:
            return McpServer.errorResponse(id, McpServer.METHOD_NOT_FOUND, "method not found: " + method.asText())
        }
    }

    private func initialize(_ params: CoreJSON?) -> CoreJSON {
        let requested = params?.path("protocolVersion").asText(nil)
        let version = requested.flatMap { McpServer.PROTOCOL_VERSIONS.contains($0) ? $0 : nil }
            ?? McpServer.PROTOCOL_VERSIONS[0]
        return .obj([
            ("protocolVersion", .string(version)),
            ("capabilities", .obj([("tools", .obj([("listChanged", .bool(false))]))])),
            ("serverInfo", .obj([("name", .string(McpServer.SERVER_NAME)), ("version", .string(serverVersion))])),
            ("instructions", .string(McpServer.INSTRUCTIONS)),
        ])
    }

    private func toolsList() -> CoreJSON {
        .obj([("tools", .array(toolset.tools().map { def in
            .obj([("name", .string(def.name)), ("description", .string(def.description)),
                  ("inputSchema", def.inputSchema)])
        }))])
    }

    private func toolsCall(_ caller: String?, _ name: String, _ arguments: CoreJSON?) -> CoreJSON {
        let outcome: ToolResult
        if !toolset.tools().contains(where: { $0.name == name }) {
            outcome = ToolResult.error("unknown tool: " + name)
        } else {
            let args = arguments == nil || arguments!.isNull ? CoreJSON.object([]) : arguments!
            do {
                outcome = try toolset.call(caller, name, args)
            } catch {
                Log.debug("MCP tool \(name) failed: \(error)", tag: "mcp")
                let message = errorMessage(error)
                outcome = ToolResult.error(JavaText.isBlank(message) ? String(describing: error) : message)
            }
        }
        return .obj([
            ("content", .array([.obj([("type", .string("text")), ("text", .string(outcome.text))])])),
            ("isError", .bool(outcome.isError)),
        ])
    }

    private static func resultResponse(_ id: CoreJSON, _ result: CoreJSON) -> CoreJSON {
        .obj([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
    }

    private static func errorResponse(_ id: CoreJSON, _ code: Int, _ message: String) -> CoreJSON {
        .obj([("jsonrpc", .string("2.0")), ("id", id),
              ("error", .obj([("code", .int(Int64(code))), ("message", .string(message))]))])
    }
}

/// The app's handle on its one `McpServer`: started at launch when the `mcp.server`
/// setting is on, restarted from Settings when the port changes, stopped on Settings-off
/// and on shutdown. Thread-safe — the UI starts and stops it while session launches on
/// background threads ask `linkFor` which URL and token to give a launched agent.
///
/// The toolset is fixed for the service's lifetime; only the listening socket comes and
/// goes, and the toolset is told about each (`serverStarted`, `serverStopped`) so its
/// background work runs only while it serves. A bind failure (the port is taken) leaves the
/// service stopped, is logged, and is rethrown for the caller to report — it never takes
/// the app down.
public final class McpService: @unchecked Sendable {

    /// A toolset with no tools, for windows and tests that host no controller.
    public static let NO_TOOLS: McpToolset = NoTools()

    private final class NoTools: McpToolset {
        func tools() -> [ToolDef] { [] }
        func call(_ caller: String?, _ tool: String, _ arguments: CoreJSON) throws -> ToolResult {
            ToolResult.error("unknown tool: " + tool)
        }
    }

    private let toolset: McpToolset
    private let serverVersion: String
    private let lock = NSRecursiveLock()
    private var server: McpServer?
    private var token: String?

    public init(_ tools: McpToolset, _ serverVersion: String = McpService.defaultVersion()) {
        self.toolset = tools
        self.serverVersion = serverVersion
    }

    /// Serves on 127.0.0.1:`port` (0 = any free port, for tests) with `token`. Already
    /// running with the same port and token is a no-op; with a different one the old socket
    /// is closed first, so a failed restart leaves the service stopped rather than on the
    /// stale port. Throws when the port cannot be bound; the service is then stopped.
    public func start(_ port: Int, _ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let server, port != 0, server.port == port, token == self.token {
            return
        }
        stop()
        let candidate = try McpServer(port, token, toolset, serverVersion)
        do {
            try candidate.start()
        } catch {
            candidate.close()
            Log.warn("MCP server could not start on 127.0.0.1:\(port): \(error)", tag: "mcp")
            throw error
        }
        server = candidate
        self.token = token
        Log.info("MCP server listening on 127.0.0.1:\(candidate.port)", tag: "mcp")
        toolset.serverStarted()
    }

    /// Closes the socket; idempotent. In-flight calls are abandoned.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let server {
            server.close()
            Log.info("MCP server stopped", tag: "mcp")
            self.server = nil
            token = nil
            toolset.serverStopped()
        }
    }

    public func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return server != nil
    }

    /// The bound port, or -1 while stopped.
    public func port() -> Int {
        lock.lock(); defer { lock.unlock() }
        return server?.port ?? -1
    }

    /// The URL an agent running in `session` reaches the server at — the session name rides
    /// in the path as the caller identity, the token in the query — or nil while stopped.
    /// For manual clients; launched agents get `linkFor`.
    public func urlFor(_ session: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        return server?.urlFor(session)
    }

    /// The token-free URL for `session` and that session's own token (valid for its path
    /// only) to send as a bearer header, read together so a concurrent restart can never
    /// pair one server's URL with another's token — or nil while stopped, which callers read
    /// as "launch without MCP".
    public func linkFor(_ session: String) -> McpLink? {
        lock.lock(); defer { lock.unlock() }
        guard let server else { return nil }
        return McpLink(url: server.callerUrl(session), token: server.sessionToken(session))
    }

    public static func defaultVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
