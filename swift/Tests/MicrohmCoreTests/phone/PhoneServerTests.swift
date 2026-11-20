import Foundation
import XCTest
@testable import MicrohmCore

/// One session, "hm-a", whose screen text the test sets; nil text means it exited.
private final class FakeBackend: PhoneBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String? = "hello"
    var text: String? {
        get { lock.lock(); defer { lock.unlock() }; return _text }
        set { lock.lock(); _text = newValue; lock.unlock() }
    }
    let calls = SvcList<String>()
    @Atomic var alive = true
    @Atomic var columns = 120
    @Atomic var rows = 40
    let resizes = SvcList<String>()
    /// The scrollback, one entry per line ever added.
    private var _history: [String] = []
    @Atomic var failSessions = false
    @Atomic var project = "/p/a"
    let closed = SvcList<String>()
    let resumed = SvcList<String>()

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func addHistory(_ lines: [String]) {
        lock.lock(); _history += lines; lock.unlock()
    }

    var historyLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _history
    }

    func history(_ session: String, _ since: Int64) throws -> SessionController.HistoryView? {
        let all = historyLines
        let from = Int(min(since, Int64(all.count)))
        return SessionController.HistoryView(all[from...].joined(separator: "\n"), Int64(all.count), false)
    }

    @Atomic var failResize = false

    func resize(_ session: String, _ c: Int, _ r: Int) throws {
        if failResize {
            throw Failure(description: "daemon down")
        }
        resizes.append("\(session) \(c)x\(r)")
        columns = c
        rows = r
    }

    func closeBlocker(_ session: String) throws -> String? {
        session == "busy" ? "It's still working." : nil
    }

    func close(_ session: String) throws -> PhoneCloser.Outcome {
        if session == "busy" {
            return PhoneCloser.Outcome(false, "It's still working.")
        }
        closed.append(session)
        return PhoneCloser.Outcome(true, "Closed")
    }

    func ended() throws -> [SessionController.EndedSession] {
        [SessionController.EndedSession(name: "hm-b", display: "beta", harness: "codex", project: "/p/b",
                                        conversation: true, created: IsoInstant.parse("2026-11-01T00:00:00Z"))]
    }

    func resume(_ session: String) throws -> String {
        if session != "hm-b" {
            throw Failure(description: "no saved session named " + session)
        }
        resumed.append(session)
        return "hm-b"
    }

    func sessions() throws -> [SessionController.SessionSummary] {
        if failSessions {
            throw Failure(description: "daemon down")
        }
        return [SessionController.SessionSummary("hm-a", "alpha", "claude-code", "WAITING_FOR_INPUT", project)]
    }

    func screen(_ session: String) throws -> SessionController.ScreenView? {
        if session != "hm-a" && session != "alpha" {
            throw Failure(description: "no session named " + session)
        }
        guard let t = text else { return nil }
        return SessionController.ScreenView("hm-a", "alpha", "claude-code", "WAITING_FOR_INPUT", "menu", "title", t,
                                            columns, rows, Int64(t.utf16.count), alive)
    }

    func call(_ tool: String, _ arguments: CoreJSON) -> ToolResult {
        calls.append(tool + " " + arguments.compact())
        return arguments.path("session").asText() == "hm-a" ? .ok("done") : .error("no such session")
    }
}

final class PhoneServerTests: XCTestCase {

    private static let TOKEN = "phone-secret_123"
    private static let COOKIE = PhoneServer.COOKIE + "=" + TOKEN

    private var web: URL!
    private var backend: FakeBackend!
    private var server: PhoneServer!
    private var streams: [SvcSocket] = []

    override func setUpWithError() throws {
        web = try makeTempDir(self)
        try writeString(web.appendingPathComponent("index.html"), "<p>page v1</p>")
        backend = FakeBackend()
        server = try PhoneServer(0, PhoneServerTests.TOKEN, backend, web, 0.02, 0.05, 0.3)
        try server.start()
    }

    override func tearDown() {
        streams.forEach { $0.close() }
        server.close()
    }

    private func get(_ path: String, _ cookie: String? = nil) throws -> SvcResponse {
        try SvcHttp.request(server.port, "GET", path, headers: cookie.map { [("Cookie", $0)] } ?? [])
    }

    private func post(_ path: String, _ json: String, _ cookie: String?, _ origin: String?) throws -> SvcResponse {
        var headers = [("Content-Type", "application/json")]
        if let cookie { headers.append(("Cookie", cookie)) }
        if let origin { headers.append(("Origin", origin)) }
        return try SvcHttp.request(server.port, "POST", path, headers: headers, body: json)
    }

    func testAnUploadIsKeptAndItsPathAnswered() throws {
        let uploads = web.appendingPathComponent("uploads")
        server.uploadDir = uploads
        let locked = try SvcHttp.request(server.port, "POST", "/api/upload?name=a.png", body: "x")
        XCTAssertEqual(401, locked.status)
        let r = try SvcHttp.request(server.port, "POST", "/api/upload?name=My%20Screen%20Shot.PNG",
                                    headers: [("Cookie", PhoneServerTests.COOKIE), ("Content-Type", "image/png")],
                                    body: "fake png bytes")
        XCTAssertEqual(200, r.status, r.body)
        let path = try XCTUnwrap(CoreJSON.parse(Data(r.body.utf8)).path("path").asText(nil))
        let saved = URL(fileURLWithPath: path)
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertEqual(uploads.standardizedFileURL.resolvingSymlinksInPath().path,
                       saved.deletingLastPathComponent().resolvingSymlinksInPath().path)
        XCTAssertNotNil(saved.lastPathComponent.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}-My_Screen_Shot\.png$"#,
                                                      options: .regularExpression), saved.lastPathComponent)
        XCTAssertEqual("fake png bytes", try String(contentsOf: saved, encoding: .utf8))
    }

    func testAnUploadForASessionGoesIntoItsProjectKeptOutOfGit() throws {
        let project = web.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        backend.project = project.path
        server.uploadDir = web.appendingPathComponent("elsewhere")
        let r = try SvcHttp.request(server.port, "POST", "/api/upload?session=hm-a&name=shot.png",
                                    headers: [("Cookie", PhoneServerTests.COOKIE)], body: "xy")
        XCTAssertEqual(200, r.status, r.body)
        let path = try XCTUnwrap(CoreJSON.parse(Data(r.body.utf8)).path("path").asText(nil))
        XCTAssertEqual(project.appendingPathComponent(".microhm/uploads").resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path)
        let ignore = try String(contentsOf: project.appendingPathComponent(".microhm/.gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.split(separator: "\n").contains("*"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: web.appendingPathComponent("elsewhere").path))

        // a session whose folder is gone: the folder in Microhm's home
        backend.project = web.appendingPathComponent("gone").path
        let fallback = try SvcHttp.request(server.port, "POST", "/api/upload?session=hm-a&name=b.png",
                                           headers: [("Cookie", PhoneServerTests.COOKIE)], body: "x")
        XCTAssertEqual(200, fallback.status, fallback.body)
        XCTAssertTrue(fallback.body.contains("elsewhere"), fallback.body)
    }

    private func stream(_ path: String) throws -> SvcSocket {
        let (socket, status, headers) = try SvcHttp.stream(server.port, path, headers: [("Cookie", PhoneServerTests.COOKIE)])
        XCTAssertEqual(200, status)
        XCTAssertTrue(headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("text/event-stream") })
        streams.append(socket)
        return socket
    }

    /// The data of the next event named `name`.
    private func nextEvent(_ reader: SvcSocket, _ name: String) throws -> CoreJSON {
        var named = false
        while let line = reader.bodyLine() {
            if line == "event: " + name {
                named = true
            } else if line.isEmpty {
                named = false
            } else if named && line.hasPrefix("data: ") {
                return try CoreJSON.parse(String(line.dropFirst(6)))
            }
        }
        throw SvcConnectError()
    }

    /// The data of the next screen: an event without a name.
    private func nextData(_ reader: SvcSocket) throws -> CoreJSON {
        var named = false
        while let line = reader.bodyLine() {
            if line.hasPrefix("event: ") {
                named = true
            } else if line.isEmpty {
                named = false
            } else if !named && line.hasPrefix("data: ") {
                return try CoreJSON.parse(String(line.dropFirst(6)))
            }
        }
        throw SvcConnectError()
    }

    private func skipToExited(_ reader: SvcSocket) -> String? {
        while let line = reader.bodyLine() {
            if line == "event: exited" { return line }
        }
        return nil
    }

    func testServesThePageFromDiskOnEveryRequest() throws {
        XCTAssertEqual("<p>page v1</p>", try get("/").body)
        try writeString(web.appendingPathComponent("index.html"), "<p>page v2</p>")
        let again = try get("/")
        XCTAssertEqual("<p>page v2</p>", again.body)
        XCTAssertTrue(again.header("Content-Type")?.hasPrefix("text/html") ?? false)
        XCTAssertEqual(404, try get("/missing.js").status)
        XCTAssertEqual(404, try get("/..%2Fsecret").status)
    }

    func testServesThePageFromTheModuleWithoutAnOverride() throws {
        server.close()
        server = try PhoneServer(0, PhoneServerTests.TOKEN, backend, nil, 0.02)
        try server.start()
        let page = try get("/")
        XCTAssertEqual(200, page.status)
        XCTAssertTrue(page.body.contains("app.js"))
        XCTAssertEqual(200, try get("/app.js").status)
        XCTAssertTrue(try get("/app.js").header("Content-Type")?.hasPrefix("text/javascript") ?? false)
    }

    func testTheApiNeedsTheSecret() throws {
        XCTAssertEqual(401, try get("/api/sessions").status)
        XCTAssertEqual(401, try get("/api/sessions", PhoneServer.COOKIE + "=wrong").status)
        let ok = try get("/api/sessions", PhoneServerTests.COOKIE)
        XCTAssertEqual(200, ok.status)
        let first = ok.json.path("sessions").path(0)
        XCTAssertEqual("hm-a", first.path("name").asText())
        XCTAssertEqual("WAITING_FOR_INPUT", first.path("state").asText())
        let bearer = try SvcHttp.request(server.port, "GET", "/api/sessions",
                                         headers: [("Authorization", "Bearer " + PhoneServerTests.TOKEN)])
        XCTAssertEqual(200, bearer.status)
    }

    func testLoginTradesTheSecretForACookie() throws {
        XCTAssertEqual(401, try post("/api/login", "{\"token\":\"nope\"}", nil, nil).status)
        let ok = try post("/api/login", "{\"token\":\"" + PhoneServerTests.TOKEN + "\"}", nil, nil)
        XCTAssertEqual(200, ok.status)
        let cookie = try XCTUnwrap(ok.header("Set-Cookie"))
        XCTAssertTrue(cookie.hasPrefix(PhoneServerTests.COOKIE + ";"), cookie)
        XCTAssertTrue(cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict"), cookie)
    }

    func testRefusesPostsFromAnotherSite() throws {
        let body = "{\"session\":\"hm-a\",\"text\":\"hi\"}"
        XCTAssertEqual(403, try post("/api/send", body, PhoneServerTests.COOKIE, "http://evil.example").status)
        XCTAssertEqual(200, try post("/api/send", body, PhoneServerTests.COOKIE, "http://localhost:\(server.port)").status)
    }

    func testSendKeysAndSpawnGoToTheBackend() throws {
        let sent = try post("/api/send", "{\"session\":\"hm-a\",\"text\":\"hi\",\"enter\":true}", PhoneServerTests.COOKIE, nil)
        XCTAssertEqual(200, sent.status)
        XCTAssertEqual("done", sent.json.path("text").asText())
        let failed = try post("/api/keys", "{\"session\":\"hm-x\",\"keys\":[\"Esc\"]}", PhoneServerTests.COOKIE, nil)
        XCTAssertEqual(400, failed.status)
        XCTAssertEqual("no such session", failed.json.path("text").asText())
        _ = try post("/api/spawn", "{\"harness\":\"shell\",\"project\":\"/p\"}", PhoneServerTests.COOKIE, nil)
        let calls = backend.calls.all
        XCTAssertEqual(3, calls.count)
        XCTAssertTrue(calls[0].hasPrefix("send "))
        XCTAssertTrue(calls[1].hasPrefix("keys "))
        XCTAssertTrue(calls[2].hasPrefix("spawn "))
        XCTAssertEqual(404, try post("/api/kill", "{\"session\":\"hm-a\"}", PhoneServerTests.COOKIE, nil).status)
    }

    func testScreenAnswersForAKnownSessionOnly() throws {
        let screen = try get("/api/screen?session=alpha", PhoneServerTests.COOKIE)
        XCTAssertEqual(200, screen.status)
        XCTAssertEqual("hello", screen.json.path("text").asText())
        XCTAssertEqual(404, try get("/api/screen?session=zzz", PhoneServerTests.COOKIE).status)
        backend.text = nil
        XCTAssertEqual(410, try get("/api/screen?session=hm-a", PhoneServerTests.COOKIE).status)
    }

    func testTheScreenJsonHasTheJavaFieldsInOrder() throws {
        let body = try get("/api/screen?session=hm-a", PhoneServerTests.COOKIE).body
        XCTAssertEqual("{\"name\":\"hm-a\",\"display\":\"alpha\",\"harness\":\"claude-code\",\"state\":\"WAITING_FOR_INPUT\","
                       + "\"reason\":\"menu\",\"title\":\"title\",\"text\":\"hello\",\"columns\":120,\"rows\":40,"
                       + "\"outputBytes\":5,\"alive\":true}", body)
    }

    func testStreamSendsEachChangeThenExited() throws {
        let reader = try stream("/api/stream?session=hm-a")
        XCTAssertEqual("hello", try nextData(reader).path("text").asText())
        backend.text = "hello again"
        XCTAssertEqual("hello again", try nextData(reader).path("text").asText())
        backend.text = nil
        XCTAssertEqual("event: exited", skipToExited(reader))
    }

    func testAWatchingPhoneSetsTheSizeAndTheLastOneToLeaveGivesItBack() throws {
        let a = try stream("/api/stream?session=alpha&cols=45&rows=30")
        XCTAssertEqual(45, try nextData(a).path("columns").asInt())
        XCTAssertEqual(["hm-a 45x30"], backend.resizes.all)

        let b = try stream("/api/stream?session=hm-a&cols=50&rows=28")
        XCTAssertEqual(50, try nextData(b).path("columns").asInt())
        b.close() // the second phone leaves: the first still watches, nothing is given back
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(["hm-a 45x30", "hm-a 50x28"], backend.resizes.all)

        a.close() // the last phone leaves: its size is given back after the grace time
        svcAwait(5) { backend.resizes.count >= 3 }
        XCTAssertEqual(["hm-a 45x30", "hm-a 50x28", "hm-a 120x40"], backend.resizes.all)
    }

    func testAPhoneWhoseResizeFailedDoesNotKeepTheSessionHeld() throws {
        backend.failResize = true
        let failed = try stream("/api/stream?session=hm-a&cols=45&rows=30")
        _ = try nextData(failed)
        backend.failResize = false
        XCTAssertTrue(backend.resizes.all.isEmpty)

        let watching = try stream("/api/stream?session=hm-a&cols=50&rows=28")
        _ = try nextData(watching)
        XCTAssertEqual(["hm-a 50x28"], backend.resizes.all)
        failed.close()
        watching.close() // the last real viewer leaves: the size comes back
        svcAwait(5) { backend.resizes.count >= 2 }
        XCTAssertEqual(["hm-a 50x28", "hm-a 120x40"], backend.resizes.all)
    }

    func testComingBackWithinTheGraceTimeCostsNoResize() throws {
        let path = "/api/stream?session=hm-a&cols=45&rows=30"
        let first = try stream(path)
        _ = try nextData(first)
        first.close()
        Thread.sleep(forTimeInterval: 0.12) // noticed as gone (keepalive 50 ms), well inside the 300 ms grace

        let again = try stream(path)
        _ = try nextData(again)
        Thread.sleep(forTimeInterval: 0.5) // past the first grace time: the cancelled size-back must not run
        XCTAssertEqual(["hm-a 45x30"], backend.resizes.all)
        again.close()
    }

    func testClosingTheServerGivesSizesBackAtOnce() throws {
        server.close()
        server = try PhoneServer(0, PhoneServerTests.TOKEN, backend, web, 0.02, 0.05, 600)
        try server.start()
        let watching = try stream("/api/stream?session=hm-a&cols=45&rows=30")
        _ = try nextData(watching)
        server.close()
        XCTAssertEqual(["hm-a 45x30", "hm-a 120x40"], backend.resizes.all)
    }

    func testAStreamWithoutAValidSizeLeavesTheSizeAlone() throws {
        let response = try stream("/api/stream?session=hm-a&cols=3&rows=30")
        _ = try nextData(response)
        response.close()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(backend.resizes.all.isEmpty, "\(backend.resizes.all)")
    }

    func testStreamSendsTheScrollbackThenEachNewLine() throws {
        backend.addHistory(["one", "two"])
        let reader = try stream("/api/stream?session=hm-a")
        let first = try nextEvent(reader, "history")
        XCTAssertEqual("one\ntwo", first.path("text").asText())
        XCTAssertTrue(first.path("reset").asBoolean())
        backend.addHistory(["three"])
        let next = try nextEvent(reader, "history")
        XCTAssertEqual("three", next.path("text").asText())
        XCTAssertFalse(next.path("reset").asBoolean())
    }

    func testAFailingRequestStillGetsItsErrorMessage() throws {
        backend.failSessions = true
        let failed = try get("/api/sessions", PhoneServerTests.COOKIE)
        XCTAssertEqual(500, failed.status)
        XCTAssertEqual("daemon down", failed.json.path("error").asText())
    }

    func testListsEndedSessionsAndResumesOne() throws {
        let ended = try get("/api/sessions", PhoneServerTests.COOKIE).json.path("ended").path(0)
        XCTAssertEqual("hm-b", ended.path("name").asText())
        XCTAssertTrue(ended.path("conversation").asBoolean())
        XCTAssertEqual("2026-11-01T00:00:00Z", ended.path("created").asText())

        let ok = try post("/api/resume", "{\"session\":\"hm-b\"}", PhoneServerTests.COOKIE, nil)
        XCTAssertEqual(200, ok.status)
        XCTAssertEqual("hm-b", ok.json.path("name").asText())
        XCTAssertEqual(["hm-b"], backend.resumed.all)

        let missing = try post("/api/resume", "{\"session\":\"zz\"}", PhoneServerTests.COOKIE, nil)
        XCTAssertEqual(400, missing.status)
        XCTAssertEqual("no saved session named zz", missing.json.path("error").asText())
        XCTAssertEqual(401, try post("/api/resume", "{\"session\":\"hm-b\"}", nil, nil).status)
    }

    func testCloseChecksFirstAndRefusesABusySession() throws {
        let ok = try get("/api/close-check?session=hm-a", PhoneServerTests.COOKIE).json
        XCTAssertTrue(ok.path("closable").asBoolean())
        let busy = try get("/api/close-check?session=busy", PhoneServerTests.COOKIE).json
        XCTAssertFalse(busy.path("closable").asBoolean())
        XCTAssertEqual("It's still working.", busy.path("reason").asText())

        XCTAssertEqual(200, try post("/api/close", "{\"session\":\"hm-a\"}", PhoneServerTests.COOKIE, nil).status)
        XCTAssertEqual(["hm-a"], backend.closed.all)
        let refused = try post("/api/close", "{\"session\":\"busy\"}", PhoneServerTests.COOKIE, nil)
        XCTAssertEqual(409, refused.status)
        XCTAssertEqual("It's still working.", refused.json.path("error").asText())
        XCTAssertEqual(403, try post("/api/close", "{\"session\":\"hm-a\"}", PhoneServerTests.COOKIE,
                                     "http://evil.example").status)
    }

    func testASessionWhoseProgramEndedEndsTheStream() throws {
        let reader = try stream("/api/stream?session=hm-a")
        _ = try nextData(reader)
        backend.alive = false // still listed by the daemon, but its program is gone
        XCTAssertEqual("event: exited", skipToExited(reader))
    }

    func testTheFirstScrollbackComesAfterTheScreenInPiecesThatCountUp() throws {
        let line = String(repeating: "x", count: 1000)
        backend.addHistory((0..<150).map { "\($0)" + line }) // about 150 KB: three pieces
        let reader = try stream("/api/stream?session=hm-a")
        var first: String?
        repeat {
            first = reader.bodyLine()
        } while first?.isEmpty == true
        XCTAssertTrue(first?.hasPrefix("data: ") ?? false, "the screen comes first: \(first ?? "nil")")
        var joined = ""
        var lastLoaded: Int64 = 0
        var pieces = 0
        var piece: CoreJSON
        repeat {
            piece = try nextEvent(reader, "history")
            XCTAssertEqual(pieces == 0, piece.path("reset").asBoolean())
            XCTAssertTrue(piece.path("loaded").asLong() > lastLoaded)
            lastLoaded = piece.path("loaded").asLong()
            if pieces > 0 { joined += "\n" }
            pieces += 1
            joined += piece.path("text").asText()
        } while !piece.path("done").asBoolean()
        XCTAssertEqual(3, pieces)
        XCTAssertEqual(backend.historyLines.joined(separator: "\n"), joined)
        XCTAssertEqual(piece.path("total").asLong(), lastLoaded)
    }

    func testChunkLinesCutsAtLineEndsAndJoinsBack() {
        XCTAssertEqual(["aa\nbb", "cc"], PhoneServer.chunkLines("aa\nbb\ncc", 6))
        XCTAssertEqual(["toolongline", "x"], PhoneServer.chunkLines("toolongline\nx", 4))
        XCTAssertEqual([""], PhoneServer.chunkLines("", 10))
    }

    func testLastLinesKeepsTheNewest() {
        XCTAssertEqual("2\n3", PhoneServer.lastLines("1\n2\n3", 2))
        XCTAssertEqual("1\n2\n3", PhoneServer.lastLines("1\n2\n3", 5))
        XCTAssertEqual("", PhoneServer.lastLines("", 5))
    }

    func testAuthorityOfAnOrigin() {
        XCTAssertEqual("localhost:7403", PhoneServer.authority("http://localhost:7403"))
        XCTAssertEqual("192.168.1.2:7403", PhoneServer.authority("http://192.168.1.2:7403/"))
        XCTAssertNil(PhoneServer.authority("null"))
    }
}
