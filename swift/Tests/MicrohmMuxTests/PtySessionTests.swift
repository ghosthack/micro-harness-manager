import Darwin
import XCTest
@testable import MicrohmMux
import MicrohmVT

/// Real shells in real PTYs (ports of `PtySessionTest` and `SessionManagerImplTest`).
final class PtySessionTests: XCTestCase {

    private var temp: TempHome!
    private var manager: SessionManagerImpl!

    override func setUp() {
        temp = TempHome()
        manager = SessionManagerImpl(historyLines: 100, idleDelay: 3600)
    }

    override func tearDown() {
        manager.close()
        temp.remove()
    }

    /// A plain `/bin/sh` session with a fixed prompt, so output is predictable.
    private func shell(_ name: String = "t", columns: Int = 80, rows: Int = 24,
                       environment: [String: String] = [:]) throws -> Session {
        var env = environment
        env["PS1"] = "$ "
        env["ENV"] = ""
        return try manager.create(name: name, workdir: temp.workdir(), columns: columns, rows: rows,
                                  command: ["/bin/sh"], labels: [:], environment: env)
    }

    private func awaitScreen(_ session: Session, contains needle: String, _ timeout: TimeInterval = 10,
                             file: StaticString = #filePath, line: UInt = #line) {
        awaitCondition(timeout, "screen to contain \(needle): \(session.capture().text)", file: file, line: line) {
            session.capture().text.contains(needle)
        }
    }

    func testEndToEnd() throws {
        let session = try shell()
        let clientA = RecordingClient()
        session.attach(clientA, columns: 80, rows: 24)
        XCTAssertTrue(session.isAlive())
        let info = session.info()
        XCTAssertEqual("t", info.name)
        XCTAssertEqual("unix", info.backend)
        XCTAssertEqual(1, info.clients)
        XCTAssertGreaterThan(info.pid, 0)

        try session.sendKeys("echo hel''lo", enter: true)
        awaitScreen(session, contains: "hello")
        let capture = session.capture()
        XCTAssertTrue(capture.alive)
        XCTAssertEqual(info.pid, capture.processId)
        XCTAssertEqual("sh", capture.foregroundCommand, "idle at the prompt: the shell is the foreground")
        XCTAssertEqual(80, capture.columns)
        awaitCondition(5, "client A to see hello") { clientA.text.contains("hello") }

        // A second client's first bytes are a snapshot that redraws "hello".
        let clientB = RecordingClient()
        session.attach(clientB, columns: 80, rows: 24)
        XCTAssertEqual(1, clientB.snapshots)
        XCTAssertTrue(clientB.text.hasPrefix("\u{1b}[?1049l"), "redraw reset prefix")
        let replica = HeadlessTerminal(80, 24, 100) { _ in }
        replica.apply(VtTokenizer().feed(Array(clientB.text.utf8)).tokens)
        XCTAssertEqual(session.capture().text, replica.screenText(), "the replica matches capture exactly")
        XCTAssertEqual(2, session.clients().count)

        // Resize from B: A gets the in-band announcement, B does not.
        let bBefore = clientB.text.count
        session.resize(columns: 100, rows: 30, except: clientB)
        awaitCondition(5, "A to get the size announcement") { clientA.text.contains("\u{1b}[8;30;100t") }
        XCTAssertFalse(String(clientB.text.dropFirst(bBefore)).contains("[8;30;100t"))
        XCTAssertEqual(100, session.capture().columns)
        XCTAssertEqual(30, session.info().rows)

        // current-path: no OSC hint from a stock sh, so the kernel's answer for the shell.
        XCTAssertEqual(temp.workdir().path, session.currentPath().resolvingSymlinksInPath().path)
        try session.sendKeys("mkdir -p sub && cd sub", enter: true)
        awaitCondition(5, "current-path to follow cd") {
            session.currentPath().resolvingSymlinksInPath().path == temp.workdir().appendingPathComponent("sub").path
        }

        // kill: a foreground sleep (a descendant of the shell) goes with the shell.
        try session.sendKeys("sleep 100", enter: true)
        awaitCondition(10, "sleep to become the foreground") { session.capture().foregroundCommand == "sleep" }
        let descendants = ProcessTable.descendants(of: Int32(info.pid)).map(\.pid)
        XCTAssertFalse(descendants.isEmpty)
        manager.kill("t")
        XCTAssertFalse(session.isAlive())
        awaitCondition(5, "onExit on the clients") { clientA.exitCode != nil && clientB.exitCode != nil }
        XCTAssertEqual(0, session.clients().count)
        awaitCondition(5, "descendants to be gone") { !descendants.contains(where: ProcessTable.isAlive) }
        XCTAssertNil(manager.find("t"))

        // A late attach still gets the last screen and then the end.
        let late = RecordingClient()
        session.attach(late, columns: 80, rows: 24)
        XCTAssertNotNil(late.exitCode)
        XCTAssertFalse(late.text.isEmpty)
    }

    func testEmulatorRepliesGoToThePtyAndAreStrippedFromClients() throws {
        let session = try shell()
        let client = RecordingClient()
        session.attach(client, columns: 80, rows: 24)
        // The cursor position report is answered by the daemon's emulator: `read` gets it.
        try session.sendKeys(#"printf '\033[6n'; IFS= read -r -d R reply; echo "got[${reply#?}]""#, enter: true)
        awaitScreen(session, contains: "got[[")
        XCTAssertFalse(client.text.contains("\u{1b}[6n"), "the query is answered by the server, not forwarded")
    }

    func testOutputBytesAndAwaitQuiet() throws {
        let session = try shell()
        awaitScreen(session, contains: "$")
        let before = session.outputBytes()
        let start = Date()
        try session.write(Array("sleep 0.3; echo done-waiting\r".utf8))
        let result = session.awaitQuiet(sinceBytes: before, quietMs: 500, timeoutMs: 5000)
        XCTAssertTrue(result.quiet)
        XCTAssertTrue(result.alive)
        XCTAssertGreaterThan(result.outputBytes, before)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(session.capture().text.contains("done-waiting"))
        XCTAssertEqual(session.outputBytes(), session.info().outputBytes)

        let mark = session.outputBytes()
        try session.write(Array("while :; do echo busy; done\r".utf8))
        let busy = session.awaitQuiet(sinceBytes: mark, quietMs: 300, timeoutMs: 1500)
        XCTAssertFalse(busy.quiet, "output never stopped: the timeout answers")
        try session.write([0x03])
        try session.write(Array("exit 4\r".utf8))
        let gone = session.awaitQuiet(sinceBytes: -1, quietMs: 60_000, timeoutMs: 10_000)
        XCTAssertTrue(gone.quiet)
        XCTAssertFalse(gone.alive)
    }

    func testPasteIsBracketedOnlyWhenTheProgramAskedForIt() throws {
        let session = try shell()
        awaitScreen(session, contains: "$")
        XCTAssertFalse(try session.pasteIfBracketed("nope"))
        try session.sendKeys(#"printf '\033[?2004h'; od -c"#, enter: true)
        awaitCondition(5, "bracketed paste mode") { (try? session.pasteIfBracketed("")) == true }
        try session.paste("ab\u{1b}[201~c")
        try session.write([0x0D, 0x04])
        awaitScreen(session, contains: "[   2   0   0   ~   a   b   [   2   0   1   ~   c")
    }

    func testInputKeysFollowTheCursorKeyModeAndUnknownKeysWriteNothing() throws {
        let session = try shell()
        awaitScreen(session, contains: "$")
        try session.sendKeys(#"printf '\033[?1h'; od -c"#, enter: true)
        Thread.sleep(forTimeInterval: 0.3)
        try session.input(["Up", "Enter"])
        try session.write([0x04])
        awaitScreen(session, contains: "033   O   A")
        XCTAssertThrowsError(try session.input(["NoSuchKey"]))
    }

    func testWatcherSeesOutputQuietTitleBellAndExit() throws {
        let session = try shell()
        awaitScreen(session, contains: "$")
        let watcher = RecordingWatcher(quietMs: 150)
        session.addWatcher(watcher)
        try session.write(Array(#"printf '\033]0;new-title\007'; printf '\007'"# .utf8) + [0x0D])
        awaitCondition(5, "output, title, bell, quiet: \(watcher.types)") {
            let t = watcher.types
            return t.contains("output") && t.contains("title") && t.contains("bell") && t.contains("quiet")
        }
        XCTAssertEqual("new-title", watcher.events.first { $0.type == "title" }?.title)
        XCTAssertEqual("output", watcher.types.first)
        try session.write(Array("exit 5\r".utf8))
        awaitCondition(5, "exit event") { watcher.types.contains("exit") }
        XCTAssertEqual(5, watcher.events.last?.exitCode)
        XCTAssertEqual("exit", watcher.types.last)

        // A watcher added after the exit still hears it, at once.
        let late = RecordingWatcher()
        session.addWatcher(late)
        XCTAssertEqual(["exit"], late.types)
    }

    func testCaptureFormatsAndHistory() throws {
        let session = try shell(rows: 5)
        awaitScreen(session, contains: "$")
        try session.write(Array("i=0; while [ $i -lt 20 ]; do echo line$i; i=$((i+1)); done\r".utf8))
        awaitScreen(session, contains: "line19")
        let withHistory = session.capture(.TEXT, historyLines: 50)
        let history = try XCTUnwrap(withHistory.history)
        XCTAssertTrue(history.text.contains("line0\n"), history.text)
        XCTAssertGreaterThan(history.added, 10)
        XCTAssertNil(session.capture(.TEXT, historyLines: 0).history)
        let since = session.captureSince(.TEXT, since: history.added)
        XCTAssertEqual("", since.history?.text)
        XCTAssertTrue(session.capture(.ANSI).text.contains("\u{1b}["))
        XCTAssertTrue(session.capture(.ANNOTATED).text.contains(HeadlessTerminal.CURSOR_MARKER))
    }

    func testLabelsMergeAndAreGivenAtCreation() throws {
        let session = try manager.create(name: "l", workdir: temp.workdir(), columns: 80, rows: 24, command: ["/bin/cat"],
                                         labels: ["a": "1"], environment: [:])
        XCTAssertEqual(["a": "1"], session.labels())
        session.label(["b": "2", "a": nil])
        XCTAssertEqual(["b": "2"], session.labels())
        XCTAssertEqual(["b": "2"], session.info().labels)
    }

    func testEnvironmentReachesTheShell() throws {
        let session = try shell(environment: ["MICROHM_TEST_VAR": "hello env", "TERM": "dumb"])
        try session.sendKeys("echo \"[$MICROHM_TEST_VAR|$TERM|$MICROHM_SESSION]\"", enter: true)
        awaitScreen(session, contains: "[hello env|xterm-256color|t]")
    }

    func testInputForAProgramThatDoesNotReadIsBoundedAndRefused() throws {
        let session = try manager.create(name: "stuck", workdir: temp.workdir(), columns: 80, rows: 24,
                                         command: ["/bin/sleep", "30"], labels: [:], environment: [:])
        let chunk = [UInt8](repeating: 0x61, count: 1024 * 1024)
        var refused = false
        for _ in 0..<16 {
            do {
                try session.write(chunk)
            } catch is InputRejectedError {
                refused = true
                break
            }
        }
        XCTAssertTrue(refused, "the pending input is bounded")
    }

    // MARK: manager

    func testNamesAreUniqueAndBadWorkdirsOrCommandsFail() throws {
        _ = try shell("dup")
        XCTAssertThrowsError(try shell("dup")) { XCTAssertTrue("\($0)".contains("already exists"), "\($0)") }
        XCTAssertThrowsError(try manager.create(name: "x", workdir: temp.root.appendingPathComponent("missing"),
                                                columns: 80, rows: 24, command: nil))
        XCTAssertThrowsError(try manager.create(name: "y", workdir: temp.workdir(), columns: 80, rows: 24,
                                                command: ["/nonexistent/program"]))
        XCTAssertNil(manager.find("y"))
    }

    func testCreatedListenersAndCreationOrder() throws {
        var created: [String] = []
        let listener = CreatedListener { created.append($0.name) }
        manager.addCreatedListener(listener)
        _ = try shell("one")
        _ = try shell("two")
        manager.removeCreatedListener(listener)
        _ = try shell("three")
        XCTAssertEqual(["one", "two"], created)
        XCTAssertEqual(["one", "two", "three"], manager.sessions().map(\.name))
    }

    func testIdleTimerFiresWhenTheLastSessionEndsAndCloseRefusesNewOnes() throws {
        let quick = SessionManagerImpl(historyLines: 0, idleDelay: 0.2)
        let fired = expectation(description: "idle")
        fired.assertForOverFulfill = false
        var armed = false
        quick.setListener { if armed { fired.fulfill() } }
        let session = try quick.create(name: "q", workdir: temp.workdir(), columns: 80, rows: 24,
                                       command: ["/bin/sh", "-c", "exit 0"])
        armed = true
        wait(for: [fired], timeout: 5)
        XCTAssertNil(quick.find("q"))
        XCTAssertFalse(session.isAlive())
        XCTAssertTrue(quick.closeIfIdle())
        XCTAssertThrowsError(try quick.create(name: "r", workdir: temp.workdir(), columns: 80, rows: 24, command: nil)) {
            XCTAssertEqual(SessionManagerConstants.CLOSED, "\($0)")
        }
    }

    func testKillGivesASighupIgnoringDescendantTheGraceThenSigkill() throws {
        let session = try shell()
        awaitScreen(session, contains: "$")
        try session.write(Array("(trap '' HUP; exec sleep 100) & echo bg-started\r".utf8))
        awaitScreen(session, contains: "bg-started")
        let descendants = ProcessTable.descendants(of: Int32(session.info().pid)).map(\.pid)
        XCTAssertFalse(descendants.isEmpty)
        let start = Date()
        manager.kill("t")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.5, "the grace ran")
        awaitCondition(5, "the HUP-ignoring sleep to be killed") { !descendants.contains(where: ProcessTable.isAlive) }
    }
}
