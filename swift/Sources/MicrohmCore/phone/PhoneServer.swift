import Foundation
import MicrohmShared

/// The phone page: a small web server for Safari (or any browser) on a phone on the same
/// network, or reaching it over a VPN. It serves the page's files and a JSON API over the
/// same session controller the MCP tools use.
///
/// Pages: `/` and the files beside it, from the module's `Resources/web` folder, or from a
/// folder on disk named by `MICROHM_WEB_DIR`, read on every request, so editing the page
/// needs no rebuild or restart.
///
/// API, all JSON, all behind the secret:
/// - `POST /api/login {"token"}` sets the cookie that carries the secret from then on;
/// - `GET /api/sessions`, `GET /api/harnesses`;
/// - `GET /api/screen?session=`, and `GET /api/stream?session=&cols=&rows=`, Server-Sent
///   Events with the screen each time it changes and `exited` when it ends. With `cols` and
///   `rows` the session runs at the phone's size while any phone watches it, and gets its
///   earlier size back when the last one leaves;
/// - `POST /api/send {session,text,enter}`, `POST /api/keys {session,keys}`,
///   `POST /api/spawn {harness,project,name,prompt}`, `POST /api/resume {session}`;
/// - `GET /api/close-check?session=` says whether a session can be closed now and why not;
///   `POST /api/close {session}` closes it politely or refuses (409);
/// - `POST /api/upload?name=` keeps the body as a file and answers its path, for a prompt
///   to name (a screenshot of the problem, say), in `?session=`'s project when it can;
/// - `GET /api/sessions` also lists the saved sessions that are not running, as `ended`, to
///   resume.
///
/// A home tool, not a public service: one shared secret, plain HTTP, every interface.
/// Requests from another site's page are refused (the `Origin` must match the `Host`), and
/// the cookie is `SameSite=Strict`.
public final class PhoneServer: @unchecked Sendable {

    static let COOKIE = "mhm_phone"
    static let WEB_DIR_ENV = "MICROHM_WEB_DIR"
    static let MAX_BODY = 64 * 1024
    private static let TOOLS: Set<String> = ["send", "keys", "spawn"]
    static let MIN_COLUMNS = 20
    static let MAX_COLUMNS = 400
    static let MIN_ROWS = 5
    static let MAX_ROWS = 200
    /// How often an idle stream writes a comment line: a phone that has gone is noticed on a
    /// write, and its session's size given back.
    static let KEEPALIVE: TimeInterval = 5
    /// Scrollback a stream starts with, at most: enough to read back, light enough for a phone.
    static let MAX_HISTORY_LINES = 2000
    /// The size of each piece the first scrollback is sent in, so the page can show progress.
    static let HISTORY_CHUNK = 64 * 1024
    /// How long a session keeps the phone's size after the last phone leaves. A resize makes
    /// an agent like Claude Code redraw its whole conversation, which takes seconds on a long
    /// one and adds a copy to its scrollback; going back to the list and into the session
    /// again within this time costs no resize at all.
    static let GIVE_BACK_AFTER: TimeInterval = 60
    private static let TYPES: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "webmanifest": "application/manifest+json",
        "svg": "image/svg+xml",
        "png": "image/png",
    ]

    private let requestedPort: Int
    private let token: [UInt8]
    private let backend: PhoneBackend
    private let webDir: URL?
    private let poll: TimeInterval
    private let keepalive: TimeInterval
    private let giveBackAfter: TimeInterval
    private let giveBacks = DispatchQueue(label: "mhm-phone-size")

    /// Where files sent from the page are kept; `MicrohmPaths.uploadsDir` unless a test says.
    var uploadDir: URL?

    /// Sessions held at a phone's size, by session name; guarded by `holdsLock`.
    private var holds: [String: Hold] = [:]
    private let holdsLock = NSRecursiveLock()

    /// A session some phones are watching: its size before the first one came, how many
    /// watch, the size the last one asked for, and the size-back waiting to run once the
    /// last one has left.
    private final class Hold {
        let columns: Int
        let rows: Int
        var viewers = 0
        var phoneColumns = 0
        var phoneRows = 0
        var giveBack: DispatchWorkItem?

        init(_ columns: Int, _ rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// Draws screens in colour for streams that ask (`styled=1`); nil: plain text only.
    @Atomic private var colours: StyledScreen?

    /// Wakes sleeping streams when the server closes.
    private let state = NSCondition()
    private var running = false
    private var server: HttpServer?

    /// - port: TCP port on every interface; 0 picks a free one (tests)
    /// - token: the secret every API request must carry
    /// - webDir: where the page's files are read from, or nil for the bundled ones
    /// - poll: how often a stream looks at its session's screen
    public convenience init(_ port: Int, _ token: String, _ backend: PhoneBackend, _ webDir: URL?,
                            _ poll: TimeInterval) throws {
        try self.init(port, token, backend, webDir, poll, PhoneServer.KEEPALIVE, PhoneServer.GIVE_BACK_AFTER)
    }

    init(_ port: Int, _ token: String, _ backend: PhoneBackend, _ webDir: URL?, _ poll: TimeInterval,
         _ keepalive: TimeInterval, _ giveBackAfter: TimeInterval) throws {
        if token.isEmpty {
            throw HttpError("empty token")
        }
        self.requestedPort = port
        self.token = Array(token.utf8)
        self.backend = backend
        self.webDir = webDir
        self.poll = poll
        self.keepalive = keepalive
        self.giveBackAfter = giveBackAfter
    }

    /// The folder `MICROHM_WEB_DIR` names, if any.
    public static func webDirOverride() -> URL? {
        guard let dir = ProcessInfo.processInfo.environment[WEB_DIR_ENV], !JavaText.isBlank(dir) else {
            return nil
        }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    public func start() throws {
        state.lock()
        if server != nil {
            state.unlock()
            throw HttpError("already started")
        }
        state.unlock()
        let s = HttpServer(port: requestedPort, loopbackOnly: false, name: "mhm-phone")
        state.lock()
        running = true
        state.unlock()
        do {
            try s.start { [weak self] exchange in
                try self?.route(exchange)
            }
        } catch {
            state.lock()
            running = false
            state.unlock()
            throw error
        }
        state.lock()
        server = s
        state.unlock()
    }

    /// Lets streams that ask for it (`styled=1`) get the screen with its colours.
    public func useColours(_ colours: StyledScreen?) {
        self.colours = colours
    }

    /// The bound port, or -1 while stopped.
    public var port: Int {
        state.lock(); defer { state.unlock() }
        return server?.port ?? -1
    }

    private var isRunning: Bool {
        state.lock(); defer { state.unlock() }
        return running
    }

    /// Stops serving. Sessions still at a phone's size get their own back now: the streams
    /// end (giving back at once, as the server is no longer running), then every size-back
    /// still waiting runs.
    public func close() {
        state.lock()
        running = false
        state.broadcast()
        let s = server
        server = nil
        state.unlock()
        s?.close(wait: 1)
        holdsLock.lock()
        let waiting = holds.filter { $0.value.viewers == 0 }.map(\.key)
        holdsLock.unlock()
        waiting.forEach(giveBack)
    }

    // MARK: - dispatch

    private func route(_ ex: HttpExchange) throws {
        do {
            let path = ex.path
            let method = ex.method
            if !path.hasPrefix("/api/") {
                if method != "GET" && method != "HEAD" {
                    try send(ex, 405, "text/plain", "method not allowed")
                    return
                }
                try serveFile(ex, path)
                return
            }
            if method == "POST" && !PhoneServer.sameOrigin(ex) {
                try sendError(ex, 403, "request from another site refused")
                return
            }
            if path == "/api/login" && method == "POST" {
                try login(ex)
                return
            }
            if !authorized(ex) {
                try sendError(ex, 401, "open the phone link from Microhm's Settings on this phone")
                return
            }
            switch method + " " + path {
            case "GET /api/sessions": try sendJson(ex, 200, try sessions())
            case "GET /api/harnesses": try sendJson(ex, 200, harnesses())
            case "GET /api/screen": try screen(ex)
            case "GET /api/stream": try stream(ex)
            case "POST /api/send", "POST /api/keys", "POST /api/spawn": try tool(ex, String(path.dropFirst(5)))
            case "POST /api/resume": try resume(ex)
            case "GET /api/close-check": try closeCheck(ex)
            case "POST /api/close": try close(ex)
            case "POST /api/upload": try upload(ex)
            default: try sendError(ex, 404, "no such endpoint")
            }
        } catch let e as HttpError where ex.responseStarted {
            throw e // the client went away mid-stream
        } catch {
            Log.debug("phone request failed: \(error)", tag: "phone")
            if !ex.responseStarted {
                try sendError(ex, 500, errorMessage(error))
            }
            // headers already sent (a stream): nothing more to say
        }
    }

    // MARK: - auth

    private func login(_ ex: HttpExchange) throws {
        let body = try readJson(ex)
        let given = body?.path("token").asText("") ?? ""
        if !matches(given) {
            // a guess costs a second
            Thread.sleep(forTimeInterval: 1)
            try sendError(ex, 401, "that link's secret is not the current one")
            return
        }
        ex.addHeader("Set-Cookie", PhoneServer.COOKIE + "=" + given
                     + "; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000")
        try sendJson(ex, 200, .obj([("ok", .bool(true))]))
    }

    private func authorized(_ ex: HttpExchange) -> Bool {
        if let auth = ex.header("Authorization"), auth.count >= 7, auth.prefix(7).lowercased() == "bearer ",
           matches(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)) {
            return true
        }
        for header in ex.headers("Cookie") {
            for part in header.split(separator: ";") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix(PhoneServer.COOKIE + "="), matches(String(p.dropFirst(PhoneServer.COOKIE.count + 1))) {
                    return true
                }
            }
        }
        return false
    }

    private func matches(_ given: String) -> Bool {
        constantTimeEquals(token, Array(given.utf8))
    }

    /// A POST without an Origin (not from a browser page) or from a page on this server.
    static func sameOrigin(_ ex: HttpExchange) -> Bool {
        guard let origin = ex.header("Origin") else {
            return true
        }
        guard let host = ex.header("Host"), let authority = authority(origin) else {
            return false
        }
        return authority.caseInsensitiveCompare(host) == .orderedSame
    }

    /// `URI.getRawAuthority()`: what follows `scheme://` up to the path.
    static func authority(_ uri: String) -> String? {
        guard let scheme = uri.range(of: "://") else { return nil }
        let rest = uri[scheme.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = String(rest[..<end])
        return authority.isEmpty || authority.contains(" ") ? nil : authority
    }

    // MARK: - API

    static func json(_ s: SessionController.SessionSummary) -> CoreJSON {
        .obj([("name", .string(s.name)), ("display", s.display.map(CoreJSON.string) ?? .null),
              ("harness", .string(s.harness)), ("state", .string(s.state)), ("project", .string(s.project))])
    }

    static func json(_ v: SessionController.ScreenView) -> CoreJSON {
        .obj([("name", .string(v.name)), ("display", v.display.map(CoreJSON.string) ?? .null),
              ("harness", .string(v.harness)), ("state", .string(v.state)), ("reason", .string(v.reason)),
              ("title", .string(v.title)), ("text", .string(v.text)), ("columns", .int(Int64(v.columns))),
              ("rows", .int(Int64(v.rows))), ("outputBytes", .int(v.outputBytes)), ("alive", .bool(v.alive))])
    }

    private func sessions() throws -> CoreJSON {
        let running = try backend.sessions().map(PhoneServer.json)
        let ended = try backend.ended().map { e -> CoreJSON in
            .obj([("name", .string(e.name)), ("display", e.display.map(CoreJSON.string) ?? .null),
                  ("harness", .string(e.harness)), ("project", .string(e.project)),
                  ("conversation", .bool(e.conversation)),
                  ("created", e.created.map { .string(IsoInstant.format($0)) } ?? .null)])
        }
        return .obj([("sessions", .array(running)), ("ended", .array(ended))])
    }

    /// Whether the session can be closed now: `closable`, or the `reason` not.
    private func closeCheck(_ ex: HttpExchange) throws {
        guard let session = query(ex, "session") else {
            try sendError(ex, 400, "session is required")
            return
        }
        let blocker: String?
        do {
            blocker = try backend.closeBlocker(session)
        } catch {
            try sendError(ex, 404, errorMessage(error))
            return
        }
        var out = CoreJSON.obj([("ok", .bool(true)), ("closable", .bool(blocker == nil))])
        if let blocker {
            out.set("reason", .string(blocker))
        }
        try sendJson(ex, 200, out)
    }

    private func close(_ ex: HttpExchange) throws {
        let args = try readJson(ex)
        let session = args?.path("session").asText("") ?? ""
        if JavaText.isBlank(session) {
            try sendError(ex, 400, "session is required")
            return
        }
        do {
            let outcome = try backend.close(session)
            try sendJson(ex, outcome.closed ? 200 : 409, .obj([
                ("ok", .bool(outcome.closed)), ("closed", .bool(outcome.closed)),
                ("error", outcome.closed ? .null : .string(outcome.message)),
            ]))
        } catch {
            try sendError(ex, 404, errorMessage(error))
        }
    }

    private func resume(_ ex: HttpExchange) throws {
        let args = try readJson(ex)
        let session = args?.path("session").asText("") ?? ""
        if JavaText.isBlank(session) {
            try sendError(ex, 400, "session is required")
            return
        }
        do {
            let name = try backend.resume(session)
            try sendJson(ex, 200, .obj([("ok", .bool(true)), ("name", .string(name))]))
        } catch {
            try sendError(ex, 400, errorMessage(error))
        }
    }

    private func harnesses() -> CoreJSON {
        .obj([("harnesses", .array(HarnessType.allCases.map { .string($0.id) }))])
    }

    private func screen(_ ex: HttpExchange) throws {
        guard let session = query(ex, "session") else {
            try sendError(ex, 400, "session is required")
            return
        }
        let view: SessionController.ScreenView?
        do {
            view = try backend.screen(session)
        } catch {
            try sendError(ex, 404, errorMessage(error))
            return
        }
        guard let view else {
            try sendError(ex, 410, session + " has exited")
            return
        }
        try sendJson(ex, 200, PhoneServer.json(view))
    }

    /// Server-Sent Events: the screen now, then again each time it changes; a comment line
    /// every few seconds keeps proxies and Safari from timing out; `exited` ends it.
    private func stream(_ ex: HttpExchange) throws {
        guard let session = query(ex, "session") else {
            try sendError(ex, 400, "session is required")
            return
        }
        ex.setHeader("Content-Type", "text/event-stream; charset=utf-8")
        ex.setHeader("Cache-Control", "no-cache")
        try ex.startStream(200)
        let held = hold(session, intQuery(ex, "cols"), intQuery(ex, "rows"))
        let styled = query(ex, "styled") == "1"
        defer {
            if let held {
                release(held)
            }
        }
        try streamScreens(ex, session, styled)
    }

    /// The stream's loop. The screen goes first, so a phone sees something at once; the
    /// scrollback follows, the first time in pieces of `HISTORY_CHUNK` bytes that each say
    /// how much of the total has been sent (`loaded`, `total`, `done`), so the page can show
    /// its progress; afterwards only new lines.
    private func streamScreens(_ out: HttpExchange, _ session: String, _ styled: Bool) throws {
        var last: String?
        var lastWrite = Date()
        var historyAdded: Int64 = -1 // nothing sent yet: the first history is everything held
        while isRunning {
            var wrote = false
            do {
                // gone, or its program ended while the daemon still lists it
                guard let view = try backend.screen(session), view.alive else {
                    try write(out, "event: exited\ndata: {}\n\n")
                    return
                }
                var screen = PhoneServer.json(view)
                if styled, let drawer = colours, let a = try backend.ansi(session) {
                    // the same screen with its colours: rows of styled runs (see StyledScreen)
                    screen.set("styled", drawer.render(a.text, a.columns, a.rows))
                }
                let data = screen.compact()
                if data != last {
                    try write(out, "data: " + data + "\n\n") // throws once the phone has gone
                    wrote = true
                }
                last = data
                if let history = try backend.history(session, max(0, historyAdded)),
                   historyAdded < 0 || history.added != historyAdded {
                    let text = historyAdded < 0 ? PhoneServer.lastLines(history.text, PhoneServer.MAX_HISTORY_LINES)
                        : history.text
                    // a count that went down: the session's history was cleared, start over
                    let reset = historyAdded < 0 || history.added < historyAdded
                    try writeHistory(out, text, reset)
                    wrote = true
                    historyAdded = history.added
                }
            } catch let e as HttpError {
                throw e
            } catch {
                try write(out, "event: problem\ndata: " + CoreJSON.obj([("error", .string(errorMessage(error)))]).compact()
                          + "\n\n")
                wrote = true
                last = nil
            }
            if !wrote && Date().timeIntervalSince(lastWrite) > keepalive {
                try write(out, ": ping\n\n")
                wrote = true
            }
            if wrote {
                lastWrite = Date()
            }
            if !sleepQuietly(poll) {
                return
            }
        }
    }

    /// `text` as history events of at most `HISTORY_CHUNK` bytes, cut at line ends, each
    /// with how many bytes have been sent so far of how many.
    private func writeHistory(_ out: HttpExchange, _ text: String, _ reset: Bool) throws {
        let chunks = PhoneServer.chunkLines(text, PhoneServer.HISTORY_CHUNK)
        let total = Int64(text.utf8.count)
        var loaded: Int64 = 0
        for (i, chunk) in chunks.enumerated() {
            loaded += Int64(chunk.utf8.count + (i < chunks.count - 1 ? 1 : 0))
            try write(out, "event: history\ndata: " + CoreJSON.obj([
                ("text", .string(chunk)), ("reset", .bool(reset && i == 0)), ("loaded", .int(loaded)),
                ("total", .int(total)), ("done", .bool(i == chunks.count - 1)),
            ]).compact() + "\n\n")
        }
    }

    /// `text` cut at line ends into pieces of at most about `maxBytes` each (a longer line
    /// is one piece); joined with line breaks they make `text` again.
    static func chunkLines(_ text: String, _ maxBytes: Int) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var bytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let size = line.utf8.count + 1
            if bytes > 0 && bytes + size > maxBytes {
                chunks.append(chunk)
                chunk = ""
                bytes = 0
            }
            if bytes > 0 {
                chunk += "\n"
            }
            chunk += line
            bytes += size
        }
        chunks.append(chunk)
        return chunks
    }

    /// Runs `session` at the phone's size while this stream lasts; the session's name, to
    /// `release` afterwards, or nil when no (valid) size was asked for or the session cannot
    /// be resized.
    private func hold(_ session: String, _ columns: Int?, _ rows: Int?) -> String? {
        guard let columns, let rows, columns >= PhoneServer.MIN_COLUMNS, columns <= PhoneServer.MAX_COLUMNS,
              rows >= PhoneServer.MIN_ROWS, rows <= PhoneServer.MAX_ROWS else {
            return nil
        }
        let view: SessionController.ScreenView
        do {
            guard let found = try backend.screen(session) else { return nil }
            view = found
        } catch {
            Log.debug("could not size \(session) for the phone: \(error)", tag: "phone")
            return nil
        }
        let name = view.name
        // The bookkeeping under the lock, the daemon I/O (the resize) outside it.
        holdsLock.lock()
        let hold = holds[name] ?? Hold(view.columns, view.rows)
        holds[name] = hold
        if let pending = hold.giveBack {
            pending.cancel() // back within the grace time: keep the size
            hold.giveBack = nil
        }
        let previousColumns = hold.phoneColumns
        let previousRows = hold.phoneRows
        hold.viewers += 1
        hold.phoneColumns = columns
        hold.phoneRows = rows
        holdsLock.unlock()
        if view.columns != columns || view.rows != rows {
            do {
                try backend.resize(name, columns, rows)
            } catch {
                // The stream will not release what it never got: take this viewer back
                // out, or the session stays held (at the phone's size) for ever.
                Log.debug("could not size \(session) for the phone: \(error)", tag: "phone")
                holdsLock.lock()
                if hold.phoneColumns == columns && hold.phoneRows == rows {
                    hold.phoneColumns = previousColumns
                    hold.phoneRows = previousRows
                }
                holdsLock.unlock()
                release(name)
                return nil
            }
        }
        return name
    }

    /// One phone stopped watching `name`. When it was the last, the session gets its size
    /// back after `giveBackAfter` (at once when the server is closing), unless a phone comes
    /// back first.
    private func release(_ name: String) {
        holdsLock.lock()
        guard let hold = holds[name] else {
            holdsLock.unlock()
            return
        }
        hold.viewers -= 1
        if hold.viewers > 0 {
            holdsLock.unlock()
            return
        }
        if !isRunning || giveBackAfter == 0 {
            holdsLock.unlock()
            giveBack(name) // daemon I/O: not under the lock
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.giveBack(name) }
        hold.giveBack = item
        holdsLock.unlock()
        giveBacks.asyncAfter(deadline: .now() + giveBackAfter, execute: item)
    }

    /// Gives `name` its size from before the phones came, unless something else (the app's
    /// window) has resized it since, or a phone is watching it again.
    private func giveBack(_ name: String) {
        // The bookkeeping under the lock; the screen and resize calls go to the daemon and
        // may block, so they run after it is released.
        holdsLock.lock()
        guard let hold = holds[name], hold.viewers <= 0 else {
            holdsLock.unlock()
            return
        }
        hold.giveBack?.cancel()
        holds.removeValue(forKey: name)
        holdsLock.unlock()
        do {
            if let view = try backend.screen(name), view.columns == hold.phoneColumns, view.rows == hold.phoneRows {
                try backend.resize(name, hold.columns, hold.rows)
            }
        } catch {
            Log.debug("could not give \(name) its size back: \(error)", tag: "phone")
        }
    }

    private func tool(_ ex: HttpExchange, _ tool: String) throws {
        if !PhoneServer.TOOLS.contains(tool) {
            try sendError(ex, 404, "no such endpoint")
            return
        }
        guard let args = try readJson(ex), args.isObject else {
            try sendError(ex, 400, "expected a JSON object")
            return
        }
        let result = backend.call(tool, args)
        try sendJson(ex, result.isError ? 400 : 200, .obj([("ok", .bool(!result.isError)), ("text", .string(result.text))]))
    }

    // MARK: - files

    private func serveFile(_ ex: HttpExchange, _ path: String) throws {
        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard PhoneServer.isFileName(name), let bytes = readPageFile(name) else {
            try send(ex, 404, "text/plain", "not found")
            return
        }
        let ext = name.split(separator: ".").last.map(String.init) ?? ""
        ex.setHeader("Cache-Control", "no-cache")
        try ex.send(200, PhoneServer.TYPES[ext] ?? "application/octet-stream", bytes)
    }

    /// `[A-Za-z0-9][A-Za-z0-9._-]*`.
    static func isFileName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isAlnum(first) else { return false }
        return name.unicodeScalars.allSatisfy { isAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
    }

    private func readPageFile(_ name: String) -> Data? {
        let dir = webDir ?? PhoneServer.bundledWebDir()
        guard let dir else { return nil }
        let file = dir.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return try? Data(contentsOf: file)
    }

    /// The page as built into this module (`Resources/web`).
    static func bundledWebDir() -> URL? {
        Bundle.module.url(forResource: "web", withExtension: nil)
    }

    /// Keeps the request body as a file and answers its absolute path, for the page to put
    /// in the message. `?session=` puts it in that session's project (`.microhm/uploads`);
    /// `?name=` is the file's own name, kept for its extension and as a hint.
    private func upload(_ ex: HttpExchange) throws {
        guard let body = try ex.readBody(limit: PhoneUploads.maxBytes) else {
            try sendError(ex, 413, PhoneUploads.tooLargeMessage)
            return
        }
        let uploads = uploadsFor(query(ex, "session"))
        let saved: URL
        do {
            saved = try uploads.save(body, name: query(ex, "name"), contentType: ex.header("Content-Type"))
        } catch {
            try sendError(ex, 400, "could not keep that file: \(error.localizedDescription)")
            return
        }
        Log.info("kept a file from the phone page at \(saved.path)", tag: "phone")
        try sendJson(ex, 200, .obj([("ok", .bool(true)), ("path", .string(saved.path))]))
    }

    /// The session's project's uploads, else the folder in Microhm's home.
    private func uploadsFor(_ session: String?) -> PhoneUploads {
        if let session, let summary = (try? backend.sessions())?.first(where: { $0.name == session }),
           PhoneUploads.usableProject(summary.project) {
            return PhoneUploads.inProject(URL(fileURLWithPath: summary.project, isDirectory: true))
        }
        return PhoneUploads(dir: uploadDir ?? MicrohmPaths.uploadsDir)
    }

    // MARK: - helpers

    private func readJson(_ ex: HttpExchange) throws -> CoreJSON? {
        guard let body = try ex.readBody(limit: PhoneServer.MAX_BODY, drainLimit: 1 << 20) else {
            return nil
        }
        return try? CoreJSON.parse(body)
    }

    /// The value of `key` in the query, decoded; nil when absent or blank.
    private func query(_ ex: HttpExchange, _ key: String) -> String? {
        guard let value = UrlCoding.query(ex.rawQuery, key), !JavaText.isBlank(value) else {
            return nil
        }
        return value
    }

    /// The last `max` lines of `text`.
    static func lastLines(_ text: String, _ max: Int) -> String {
        let units = Array(text.utf16)
        var at = units.count
        var n = 0
        while n < max && at > 0 {
            var i = at - 1
            while i >= 0 && units[i] != 0x0A { i -= 1 }
            if i < 0 {
                return text
            }
            at = i
            n += 1
        }
        return at <= 0 ? text : String(decoding: units[(at + 1)...], as: UTF16.self)
    }

    private func intQuery(_ ex: HttpExchange, _ key: String) -> Int? {
        query(ex, key).flatMap { Int(JavaText.trim($0)) }
    }

    private func sendJson(_ ex: HttpExchange, _ status: Int, _ body: CoreJSON) throws {
        try ex.send(status, "application/json", Data(body.compact().utf8))
    }

    private func sendError(_ ex: HttpExchange, _ status: Int, _ message: String) throws {
        try sendJson(ex, status, .obj([("ok", .bool(false)), ("error", .string(message))]))
    }

    private func send(_ ex: HttpExchange, _ status: Int, _ type: String, _ body: String) throws {
        try ex.send(status, type, Data(body.utf8))
    }

    private func write(_ out: HttpExchange, _ text: String) throws {
        try out.write(Data(text.utf8))
    }

    /// False when the server is closing.
    private func sleepQuietly(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        state.lock(); defer { state.unlock() }
        while running && Date() < deadline {
            _ = state.wait(until: deadline)
        }
        return running
    }
}

/// The app's handle on its one `PhoneServer`, the way `McpService` is for the MCP server:
/// started at launch when `phone.server` is on, restarted when Settings changes it, stopped
/// on shutdown. A port that is taken is logged and rethrown for the caller to report; it
/// never takes the app down.
public final class PhoneService: @unchecked Sendable {

    static let POLL: TimeInterval = 0.3

    /// The 16 ANSI colours streams draw with: the palette chosen in Settings → Terminal. The
    /// app may point this at `MicrohmTerminal.AnsiPalettes`; the default reads the setting.
    nonisolated(unsafe) public static var palette: () -> [Int] = { StyledScreen.palette(AppSettings.terminalPalette()) }

    private let backend: PhoneBackend
    private let lock = NSRecursiveLock()
    private var server: PhoneServer?
    private var token: String?

    public init(_ backend: PhoneBackend) {
        self.backend = backend
    }

    /// Serves on `port` with `token`; already doing so is a no-op.
    public func start(_ port: Int, _ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let server, server.port == port, token == self.token {
            return
        }
        stop()
        let candidate = try PhoneServer(port, token, backend, PhoneServer.webDirOverride(), PhoneService.POLL)
        // colours as the window draws them: the ANSI palette chosen in Settings → Terminal
        candidate.useColours(StyledScreen(PhoneService.palette()))
        do {
            try candidate.start()
        } catch {
            candidate.close()
            Log.warn("phone page could not start on port \(port): \(error)", tag: "phone")
            throw error
        }
        server = candidate
        self.token = token
        Log.info("phone page at \(PhoneService.link(candidate.port, nil))"
                 + (PhoneServer.webDirOverride().map { " (page files from \($0.path))" } ?? ""), tag: "phone")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let server {
            server.close()
            self.server = nil
            token = nil
            Log.info("phone page stopped", tag: "phone")
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

    /// The link to open on a phone: this machine's local network address, and the secret
    /// after `#`, which the browser never sends to a server; the page trades it for a
    /// cookie and then drops it from the address bar. `token` nil leaves it out.
    public static func link(_ port: Int, _ token: String?) -> String {
        "http://" + lanAddress() + ":\(port)/" + (token.map { "#k=" + $0 } ?? "")
    }

    /// The first private IPv4 address of an interface that is up, else the host name.
    static func lanAddress() -> String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "localhost" }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let a = address >> 24
            let b = (address >> 16) & 0xff
            let siteLocal = a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)
            if siteLocal {
                return "\(a).\(b).\((address >> 8) & 0xff).\(address & 0xff)"
            }
        }
        return ProcessInfo.processInfo.hostName
    }
}
