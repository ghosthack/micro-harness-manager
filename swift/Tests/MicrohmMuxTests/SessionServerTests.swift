import Darwin
import XCTest
@testable import MicrohmMux

/// The daemon over its socket, in-process, in a temporary home, with real sessions; the
/// client library and the raw wire (ports of the core of `SessionServerTest`,
/// `LiveSessionServerTest` and `CliTest`).
final class SessionServerTests: XCTestCase {

    private var temp: TempHome!
    private var server: SessionServer!
    private var client: SessionServerClient!

    override func setUpWithError() throws {
        temp = TempHome()
        server = try startServer()
        // spawn: false — a race can never fork a real daemon from these tests.
        client = SessionServerClient(home: temp.home, spawn: false)
    }

    override func tearDown() {
        server?.close()
        temp.remove()
    }

    private func startServer(_ options: ServeOptions? = nil) throws -> SessionServer {
        let options = options ?? ServeOptions.defaults(temp.home).withKeepAlive(true)
        let server = SessionServer(options: options, manager: SessionManagerImpl(historyLines: options.historyLines))
        XCTAssertTrue(try server.start())
        return server
    }

    private func newShell(_ name: String = "s") throws {
        try client.newSession(name, workdir: temp.workdir(), columns: 80, rows: 24, command: ["/bin/sh"],
                              env: ["PS1": "$ ", "ENV": ""])
    }

    private func awaitCapture(_ name: String, contains needle: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        try awaitCondition(10, "capture of \(name) to contain \(needle)", file: file, line: line) {
            try client.capture(name)?.text.contains(needle) == true
        }
    }

    func testHomeSocketLockAndLogAreOwnerOnly() throws {
        var st = stat()
        XCTAssertEqual(0, stat(temp.home.path, &st))
        XCTAssertEqual(0o700, st.st_mode & 0o777)
        XCTAssertEqual(0, stat(ServerHome.socket(temp.home).path, &st))
        XCTAssertEqual(0o600, st.st_mode & 0o777)
        XCTAssertEqual("\(getpid())\n", try String(contentsOf: ServerHome.lock(temp.home), encoding: .utf8))
    }

    func testPingListNewHasKill() throws {
        let info = try XCTUnwrap(try client.ping())
        XCTAssertEqual(1, info.protocol)
        XCTAssertEqual(Int64(getpid()), info.pid)
        XCTAssertEqual([], try client.list())

        let created = try client.newSession("s", workdir: temp.workdir(), columns: 100, rows: 30,
                                           command: ["/bin/sh"], labels: ["role": "test"], env: ["A": "b"])
        XCTAssertGreaterThan(created.pid, 0)
        XCTAssertEqual("unix", created.backend)
        XCTAssertTrue(created.envApplied)
        XCTAssertTrue(try client.has("s"))
        XCTAssertFalse(try client.has("nope"))
        let listed = try client.list()
        XCTAssertEqual(1, listed.count)
        XCTAssertEqual("s", listed[0].name)
        XCTAssertEqual(100, listed[0].columns)
        XCTAssertEqual(["role": "test"], listed[0].labels)
        XCTAssertEqual(temp.workdir().path, listed[0].workdir.path)
        XCTAssertTrue(listed[0].alive)
        XCTAssertLessThan(abs(listed[0].createdAt.timeIntervalSinceNow), 30)

        XCTAssertThrowsError(try client.newSession("s", workdir: temp.workdir(), columns: 80, rows: 24)) {
            XCTAssertTrue("\($0)".contains("already exists"), "\($0)")
        }
        try client.kill("s")
        try client.kill("s") // absent: not an error
        XCTAssertFalse(try client.has("s"))
    }

    func testCaptureInputLabelWaitAndPath() throws {
        try newShell()
        try awaitCapture("s", contains: "$")
        try client.sendKeys("s", text: "echo hel''lo", enter: true)
        try awaitCapture("s", contains: "hello")
        let capture = try XCTUnwrap(try client.capture("s"))
        XCTAssertTrue(capture.alive)
        XCTAssertEqual("sh", capture.foregroundCommand)
        XCTAssertGreaterThan(capture.outputBytes, 0)
        XCTAssertNil(capture.history)
        XCTAssertNotNil(try client.capture("s", format: .TEXT, historyLines: 10)?.history)
        XCTAssertTrue(try client.capture("s", format: .ANSI)?.text.contains("\u{1b}[") == true)
        XCTAssertNil(try client.capture("missing"))

        try client.input("s", text: "echo typed", paste: false, keys: ["Enter"])
        try awaitCapture("s", contains: "typed")
        XCTAssertThrowsError(try client.input("s", text: nil, paste: false, keys: ["Bogus"])) {
            XCTAssertEqual("unknown key: Bogus", "\($0)")
        }
        XCTAssertThrowsError(try client.input("s", text: "x", paste: true, requireBracketedPaste: true, keys: nil)) {
            XCTAssertEqual(MuxProtocol.ERROR_BRACKETED_PASTE_DISABLED, "\($0)")
        }

        XCTAssertEqual(["a": "1", "b": "2"], try client.label("s", changes: ["a": "1", "b": "2"]))
        XCTAssertEqual(["b": "2"], try client.label("s", changes: ["a": nil]))

        let quiet = try client.awaitQuiet("s", sinceBytes: -1, quietMs: 100, timeoutMs: 3000)
        XCTAssertTrue(quiet.quiet)
        XCTAssertTrue(quiet.alive)
        XCTAssertEqual(temp.workdir().path, try client.currentPath("s").resolvingSymlinksInPath().path)

        XCTAssertThrowsError(try client.sendKeys("missing", text: "x", enter: false)) {
            XCTAssertEqual("no such session: missing", "\($0)")
        }
    }

    func testAttachRedrawsThenStreamsAndEndsWithTheExitCode() throws {
        try newShell()
        try client.sendKeys("s", text: "echo before-attach", enter: true)
        try awaitCapture("s", contains: "before-attach")
        let attached = try client.attach("s", columns: 80, rows: 24)
        var seen = [UInt8]()
        func readUntil(_ needle: String) throws {
            let deadline = Date(timeIntervalSinceNow: 10)
            while !String(decoding: seen, as: UTF8.self).contains(needle) && Date() < deadline {
                guard let chunk = try attached.read() else { break }
                seen += chunk
            }
        }
        try readUntil("before-attach")
        XCTAssertTrue(String(decoding: seen, as: UTF8.self).hasPrefix("\u{1b}[?1049l"), "the redraw comes first")
        XCTAssertEqual(1, try client.list().first?.clients)
        try attached.write(Array("echo via-attach\r".utf8))
        try readUntil("via-attach\r\n")
        try attached.resize(columns: 120, rows: 40)
        try awaitCondition(5, "the resize to apply") { try client.list().first?.columns == 120 }
        try attached.write(Array("exit 7\r".utf8))
        XCTAssertEqual(7, attached.waitFor())
        XCTAssertEqual(7, attached.exitCode)
        XCTAssertFalse(attached.isConnected)
        // What was buffered stays readable, then the stream ends.
        while try attached.read() != nil {}
    }

    func testDetachLeavesTheSessionRunning() throws {
        try newShell()
        let attached = try client.attach("s", columns: 80, rows: 24)
        _ = try attached.read()
        attached.close()
        XCTAssertEqual(-1, attached.waitFor())
        XCTAssertNil(attached.exitCode)
        try awaitCondition(5, "the client to be gone") { try client.list().first?.clients == 0 }
        XCTAssertTrue(try client.has("s"))
        XCTAssertThrowsError(try client.attach("missing", columns: 80, rows: 24)) {
            XCTAssertEqual("no such session: missing", "\($0)")
        }
        XCTAssertThrowsError(try client.attach("s", columns: 0, rows: 24))
    }

    func testWatchStreamsEventsOfEverySessionIncludingLaterOnes() throws {
        let lock = NSLock()
        var events: [SessionEvent] = []
        let watch = try client.watch(names: nil, quietMs: 150) { event in
            lock.lock(); events.append(event); lock.unlock()
        }
        defer { watch.close() }
        func snapshot() -> [SessionEvent] { lock.lock(); defer { lock.unlock() }; return events }
        try newShell("later")
        try client.sendKeys("later", text: #"printf '\033]2;watched\007'; exit 3"#, enter: true)
        awaitCondition(10, "exit event: \(snapshot())") { snapshot().contains { $0.type == "exit" } }
        let mine = snapshot().filter { $0.name == "later" }
        XCTAssertEqual("output", mine.first?.type)
        XCTAssertEqual("watched", mine.first { $0.type == "title" }?.title)
        XCTAssertEqual(3, mine.last?.exitCode)
        XCTAssertTrue(watch.isOpen)
        XCTAssertNil(watch.error)
        XCTAssertThrowsError(try client.watch(names: ["missing"], quietMs: 100) { _ in })
    }

    // MARK: the wire

    func testProtocolMismatchIsAnsweredWithTheServersIdentityAndCloses() throws {
        let raw = try RawConnection(temp.home)
        try raw.send(Json.object().with("op", "ping").with("protocol", 99))
        let reply = try XCTUnwrap(try raw.reply())
        XCTAssertEqual(#"{"ok":false,"error":"protocol mismatch","protocol":1,"version":""# + server.version + #"","pid":\#(getpid())}"#,
                       JSON.object(reply).description)
        XCTAssertNil(try raw.reply(), "the server closes after a mismatch")
    }

    func testBadRequestsAreAnsweredNotDropped() throws {
        let raw = try RawConnection(temp.home)
        XCTAssertEqual(#"{"ok":false,"error":"unknown op: frobnicate"}"#,
                       JSON.object(try XCTUnwrap(try raw.request("frobnicate"))).description)
        XCTAssertEqual(#"{"ok":false,"error":"no such session: x"}"#,
                       JSON.object(try XCTUnwrap(try raw.request("capture", Json.object().with("name", "x")))).description)
        XCTAssertEqual("invalid size 0x24 (1..4000 columns, 1..2000 rows)",
                       try raw.request("new", Json.object().with("name", "x").with("workdir", "/tmp").with("columns", 0))?["error"]?.stringValue)
        XCTAssertEqual("workdir is required", try raw.request("new", Json.object().with("name", "x"))?["error"]?.stringValue)
        XCTAssertEqual("command must be an array of strings",
                       try raw.request("new", Json.object().with("name", "x").with("workdir", "/tmp")
                                        .with("command", "sh"))?["error"]?.stringValue)
        XCTAssertEqual("invalid environment variable name: 'A=B'",
                       try raw.request("new", Json.object().with("name", "x").with("workdir", "/tmp")
                                        .with("env", .object(Json.object().with("A=B", "1"))))?["error"]?.stringValue)
        XCTAssertEqual(#"{"ok":true,"present":false}"#,
                       JSON.object(try XCTUnwrap(try raw.request("has", Json.object().with("name", "x")))).description)
        try raw.sendRaw(.REQUEST, Array("not json".utf8))
        XCTAssertTrue(try raw.reply()?["error"]?.stringValue?.hasPrefix("malformed request") == true)
        XCTAssertNil(try raw.reply())
    }

    func testAnUnknownOpReadsAsUnsupportedToTheClient() throws {
        let raw = try RawConnection(temp.home)
        XCTAssertEqual("unknown op: watch-v2", try raw.request("watch-v2")?["error"]?.stringValue)
        // The client maps that answer onto "the daemon predates it".
        XCTAssertTrue(SessionServerException.unsupported("x").isUnsupported)
    }

    func testShutdownIsHonouredWhateverTheProtocol() throws {
        try newShell()
        let raw = try RawConnection(temp.home)
        try raw.send(Json.object().with("op", "shutdown").with("protocol", 42))
        XCTAssertEqual(#"{"ok":true}"#, JSON.object(try XCTUnwrap(try raw.reply())).description)
        XCTAssertNil(try raw.reply(), "the socket closes once the server is down")
        XCTAssertTrue(server.awaitExit(within: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ServerHome.socket(temp.home).path))
        XCTAssertNil(try client.ping(), "no server: ping is nil, not an error")
        XCTAssertEqual([], try client.list())
        XCTAssertFalse(try client.has("s"))
        try client.kill("s")
        try client.shutdown()
        XCTAssertThrowsError(try client.sendKeys("s", text: "x", enter: false)) {
            XCTAssertTrue(($0 as? SessionServerException)?.isNoServer == true)
        }
        XCTAssertThrowsError(try client.newSession("t", workdir: temp.workdir(), columns: 80, rows: 24)) {
            XCTAssertTrue(($0 as? SessionServerException)?.isNoServer == true, "spawn: false never starts one")
        }
    }

    func testASecondServerOnTheSameHomeStandsDownAndAStaleSocketIsReplaced() throws {
        let second = SessionServer(options: ServeOptions.defaults(temp.home), manager: SessionManagerImpl(historyLines: 0))
        XCTAssertFalse(try second.start(), "the lock is held")
        XCTAssertNotNil(try client.ping(), "the first one is untouched")
        server.close()
        // A stale socket file (nobody listening) is removed by the next server.
        XCTAssertEqual(0, Darwin.close(Darwin.open(ServerHome.socket(temp.home).path, O_CREAT | O_WRONLY, 0o600)))
        server = try startServer()
        XCTAssertNotNil(try client.ping())
    }

    func testTheIdleServerExitsOnItsOwn() throws {
        server.close()
        server = SessionServer(options: ServeOptions.defaults(temp.home),
                               manager: SessionManagerImpl(historyLines: 0, idleDelay: 0.3))
        XCTAssertTrue(try server.start())
        XCTAssertTrue(server.awaitExit(within: 10), "no session ever came: the server exits")
        XCTAssertNil(try client.ping())
    }

    func testTheCliAgainstARunningServer() throws {
        func cli(_ args: String...) -> (Int32, String, String) {
            let out = BufferOutput()
            let err = BufferOutput()
            let code = Cli(stdin: BufferInput(), out: out, err: err).run(args + ["--home", temp.home.path])
            return (code, out.text, err.text)
        }
        XCTAssertEqual(0, cli("list").0)
        XCTAssertEqual("", cli("list").1)
        XCTAssertEqual("false\n", cli("has", "s").1)
        XCTAssertEqual(0, cli("new", "s", "--dir", temp.workdir().path, "--size", "90x20").0)
        XCTAssertTrue(cli("list").1.hasPrefix("s: 90x20 pid "))
        XCTAssertTrue(cli("list", "--json").1.hasPrefix(#"[{"name":"s","workdir":""#))
        XCTAssertEqual(0, cli("send-keys", "s", "echo", "from-cli").0)
        try awaitCapture("s", contains: "from-cli")
        XCTAssertTrue(cli("capture", "s").1.contains("from-cli"))
        XCTAssertTrue(cli("capture", "s", "--json").1.hasPrefix(#"{"text":""#))
        XCTAssertEqual("k=v\n", cli("label", "s", "k=v").1)
        XCTAssertTrue(cli("wait", "s", "--quiet", "50").1.hasPrefix(#"{"quiet":true,"outputBytes":"#))
        let missing = cli("capture", "nope")
        XCTAssertEqual(1, missing.0)
        XCTAssertEqual("error: no such session: nope\n", missing.2)
        let usage = cli("bogus")
        XCTAssertEqual(1, usage.0)
        XCTAssertTrue(usage.2.hasPrefix("error: unknown command 'bogus'\nusage: microhm-mux"))
        XCTAssertEqual(1, cli("capture", "s", "--format", "pdf").0)
        XCTAssertEqual(0, cli("kill", "s").0)
        XCTAssertTrue(cli("version").1.contains("server running: \(server.version) (protocol 1, pid \(getpid()))"))
        XCTAssertEqual(0, cli("shutdown").0)
        XCTAssertTrue(server.awaitExit(within: 5))
        XCTAssertEqual("false\n", cli("has", "s").1)
        let dead = cli("send-keys", "s", "x")
        XCTAssertEqual(1, dead.0)
        XCTAssertEqual("error: no such session: s (no session server is running)\n", dead.2)
    }
}
