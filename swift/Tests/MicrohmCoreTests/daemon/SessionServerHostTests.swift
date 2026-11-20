import Darwin
import Foundation
import XCTest
@testable import MicrohmCore
@testable import MicrohmMux

/// End to end through the seam: a real `SessionServer` bound in-process on a temporary
/// home, with the real PTY-backed manager, so a genuine shell runs — driven through
/// `SessionServerHost` over a `SessionServerClient` with spawning disabled, so no test can
/// ever fork a daemon or touch the user's mux home. The shared server is kept alive by
/// option so the daemon's idle timer cannot race a test; the one test that checks the idle
/// exit starts its own server without it.
///
/// The sessions run a plain, non-login `/bin/sh` (the host's `shellCommand`) rather than
/// the user's `$SHELL -l`, so no developer dotfile can move the cwd or replace the
/// foreground process under the assertions.
///
/// Echo commands are typed as `echo hello-''e2e`: the shell's echo of the keystrokes then
/// never contains the word an assertion looks for, only the command's output does.
final class SessionServerHostTests: XCTestCase {

    private static let WAIT: TimeInterval = 15
    /// What the foreground probe reports for the idle `/bin/sh`: its basename.
    private static let SHELL = "sh"

    private var root: URL!
    private var home: URL!
    private var deadHome: URL!
    private var workdir: URL!
    private var server: SessionServer!
    private var client: SessionServerClient!
    private var host: SessionServerHost!
    private var servers: [SessionServer] = []
    private var connections: [SessionConnection] = []

    override func setUpWithError() throws {
        root = svcShortTempDir(self)
        home = try createDirectories(root.appendingPathComponent("home"))
        deadHome = try createDirectories(root.appendingPathComponent("dead"))
        workdir = try createDirectories(root.appendingPathComponent("work"))
        server = try start(ServeOptions.defaults(home).withKeepAlive(true))
        client = SessionServerClient(home: home, spawn: false)
        host = hermetic(SessionServerHost(client))
    }

    override func tearDown() {
        connections.forEach { $0.close() }
        servers.forEach { $0.close() } // kills every session, removes the socket, releases the lock
    }

    private func start(_ options: ServeOptions) throws -> SessionServer {
        let started = SessionServer(options: options, manager: SessionManagerImpl(historyLines: options.historyLines))
        servers.append(started)
        XCTAssertTrue(try started.start(), "bound on \(options.home.path)")
        return started
    }

    /// A plain `/bin/sh` for every session, whatever the settings say.
    private func hermetic(_ host: SessionServerHost) -> SessionServerHost {
        host.shellCommand = { ["/bin/sh"] }
        return host
    }

    private func attach(_ name: String, _ columns: Int, _ rows: Int) throws -> SessionConnection {
        let connection = try host.attach(name, columns, rows)
        connections.append(connection)
        return connection
    }

    private func awaitUntil(_ what: String, _ timeout: TimeInterval = SessionServerHostTests.WAIT,
                            file: StaticString = #filePath, line: UInt = #line, _ condition: () throws -> Bool) {
        svcAwait(timeout, what, file: file, line: line) { (try? condition()) ?? false }
    }

    // ---- "no server running", and never a spawn

    func testDeadHomeAnswersNoServerAndNeverSpawns() throws {
        let dead = hermetic(SessionServerHost(SessionServerClient(home: deadHome, spawn: false)))
        XCTAssertEqual([], try dead.listSessions())
        XCTAssertFalse(try dead.hasSession("mhm-ghost"))
        let screen = try dead.capture("mhm-ghost")
        XCTAssertTrue(screen.paneDead)
        XCTAssertEqual("", screen.text)
        XCTAssertNoThrow(try dead.killSession("mhm-ghost"))
        XCTAssertThrowsError(try dead.sendKeys("mhm-ghost", "echo x")) { XCTAssertTrue($0 is SessionHostException) }
        XCTAssertThrowsError(try dead.attach("mhm-ghost", 80, 24)) { XCTAssertTrue($0 is SessionHostException) }
        // With spawning disabled even newSession only reports the missing server...
        XCTAssertThrowsError(try dead.newSession("mhm-ghost", workdir, 80, 24)) { error in
            XCTAssertTrue((error as? SessionHostException)?.message.contains("does not spawn") ?? false, "\(error)")
        }
        // ...and nothing was forked: a spawn creates server.log before the daemon even binds.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: ServerHome.socket(deadHome).path))
        XCTAssertFalse(fm.fileExists(atPath: ServerHome.log(deadHome).path), "a spawn would have created server.log")
        XCTAssertFalse(fm.fileExists(atPath: ServerHome.lock(deadHome).path))
        XCTAssertTrue(server.isRunning, "the live server on the other home was never involved")
    }

    func testNoServerErrorsKeepTheDaemonsMessageAndCause() {
        let dead = SessionServerHost(SessionServerClient(home: deadHome, spawn: false))
        XCTAssertThrowsError(try dead.attach("mhm-named", 80, 24)) { error in
            guard let e = error as? SessionHostException else { return XCTFail("\(error)") }
            XCTAssertTrue(e.message.contains("mhm-named"), e.message)
            guard let cause = e.cause as? SessionServerException else { return XCTFail("cause \(String(describing: e.cause))") }
            XCTAssertTrue(cause.isNoServer)
            XCTAssertEqual(cause.message, e.message)
        }
    }

    func testProtocolMismatchSurfacesTheDaemonsMessageVerbatimAndNeverSpawns() throws {
        let mismatch = try MismatchListener(ServerHome.socket(deadHome), protocol: 7, version: "9.9.9", pid: 777)
        defer { mismatch.close() }
        // Spawning enabled on purpose: a mismatch is a connected outcome, so even newSession
        // must report it rather than fork a competing daemon.
        let stale = hermetic(SessionServerHost(SessionServerClient(home: deadHome, spawn: true)))
        var listed = ""
        XCTAssertThrowsError(try stale.listSessions()) { listed = ($0 as? SessionHostException)?.message ?? "\($0)" }
        for part in ["9.9.9", "777", "protocol 7", String(MuxProtocol.VERSION)] {
            XCTAssertTrue(listed.contains(part), listed)
        }
        XCTAssertThrowsError(try stale.newSession("mhm-x", workdir, 80, 24)) {
            XCTAssertEqual(listed, ($0 as? SessionHostException)?.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ServerHome.log(deadHome).path), "no spawn happened")
    }

    // ---- live server

    func testCaptureMapsTheDaemonReplyOntoScreen() throws {
        XCTAssertTrue(try host.capture("mhm-missing").paneDead, "missing on a live server is a dead pane too")

        try host.newSession("mhm-cap", workdir, 80, 24)
        awaitUntil("the shell to be idle at its prompt") {
            SessionServerHostTests.SHELL == (try host.capture("mhm-cap").foregroundCommand)
        }
        let before = Date()
        let screen = try host.capture("mhm-cap")
        XCTAssertFalse(screen.paneDead)
        XCTAssertTrue(screen.text.hasSuffix("\n"), "visible screen, newline-joined, ending in a newline")
        XCTAssertTrue(screen.paneProcessId > 0, "the shell's pid")
        XCTAssertEqual(SessionServerHostTests.SHELL, screen.foregroundCommand)
        XCTAssertGreaterThanOrEqual(screen.capturedAt, before)
        XCTAssertLessThanOrEqual(screen.capturedAt, Date())

        try host.killSession("mhm-cap")
        awaitUntil("the killed session to capture as a dead pane") { try host.capture("mhm-cap").paneDead }
    }

    func testNewSessionWithAnEnvironmentReportsThatTheDaemonAppliedIt() throws {
        XCTAssertTrue(try host.newSession("mhm-env", workdir, 80, 24, env: ["MHM_TEST_VAR": "env-ok"]),
                      "this daemon acknowledges env")
        XCTAssertTrue(try host.newSession("mhm-noenv", workdir, 80, 24, env: [:]), "nothing asked, nothing lost")
        try host.sendKeys("mhm-env", "echo \"[$MHM_TEST_VAR]\"")
        awaitUntil("the variable to reach the shell") { try host.capture("mhm-env").text.contains("[env-ok]") }
    }

    func testADirectStartRunsTheGivenCommand() throws {
        XCTAssertTrue(try host.newSession("mhm-direct", workdir, 80, 24,
                                          command: ["/bin/sh", "-c", "echo direct-''$MHM_D; exec /bin/sh"],
                                          env: ["MHM_D": "ok"]))
        awaitUntil("the command's output") { try host.capture("mhm-direct").text.contains("direct-ok") }
    }

    func testLabelsReachTheDaemon() throws {
        try host.newSession("mhm-lab", workdir, 80, 24)
        try host.label("mhm-lab", ["harness": "codex", "display": "x"])
        let info = try XCTUnwrap(try client.list().first { $0.name == "mhm-lab" })
        XCTAssertEqual("codex", info.labels["harness"])
        XCTAssertEqual("x", info.labels["display"])
    }

    func testNewSendKeysCaptureAttachInputOutputDetachKill() throws {
        let name = "mhm-e2e"
        try host.newSession(name, workdir, 100, 30)
        XCTAssertTrue(try host.hasSession(name))
        XCTAssertEqual([name], try host.listSessions())
        XCTAssertThrowsError(try host.newSession(name, workdir, 100, 30)) { error in
            guard let e = error as? SessionHostException else { return XCTFail("\(error)") }
            XCTAssertTrue(e.message.contains("already exists"), e.message)
            XCTAssertTrue(e.cause is SessionServerException)
        }

        // send-keys → capture: the command's output (not its keystroke echo) is on the screen
        // and the shell is back at its prompt as the foreground process.
        try host.sendKeys(name, "echo hello-''e2e")
        awaitUntil("capture to show the echo with the shell idle") {
            let s = try host.capture(name)
            return s.text.contains("hello-e2e") && s.foregroundCommand == SessionServerHostTests.SHELL
        }
        let screen = try host.capture(name)
        XCTAssertFalse(screen.paneDead)
        XCTAssertTrue(screen.paneProcessId > 0, "the shell's pid")
        XCTAssertEqual(realPath(workdir.path), realPath(try client.currentPath(name).path))

        // attach (pull): the redraw carries the earlier output, typed input reaches the
        // shell, and its output comes back on the same stream
        let connection = try attach(name, 120, 32)
        XCTAssertEqual(name, connection.name)
        XCTAssertTrue(connection.isAlive)
        let reader = PullReader(connection)
        awaitUntil("the redraw to contain the earlier output") { reader.text.contains("hello-e2e") }
        let mark = reader.length
        try connection.write(Array("echo bye-''e2e\r".utf8))
        awaitUntil("live output after typed input") { reader.text(after: mark).contains("bye-e2e") }
        connection.resize(100, 30)
        XCTAssertTrue(connection.isAlive)

        // detach: the connection ends, the session does not
        connection.close()
        XCTAssertFalse(connection.isAlive)
        XCTAssertEqual(0, connection.waitFor(), "a detach has no exit status")
        reader.join()
        XCTAssertTrue(try host.hasSession(name), "detach never kills the session")
        awaitUntil("the daemon to drop the detached client") { try client.list().first?.clients == 0 }

        // kill: gone from has/list, a dead pane on capture, and killing again is not an error
        try host.killSession(name)
        awaitUntil("the session to be gone") { !(try host.hasSession(name)) }
        XCTAssertEqual([], try host.listSessions())
        XCTAssertTrue(try host.capture(name).paneDead)
        XCTAssertNoThrow(try host.killSession(name))
    }

    /// The push side of the connection, as the app's terminal transport uses it: `start()`
    /// delivers the redraw and live output to `onBytes`, `send` types, and the end of the
    /// session calls `onEnd` once.
    func testTheConnectionIsAPushTransportToo() throws {
        let name = "mhm-push"
        try host.newSession(name, workdir, 80, 24)
        try host.sendKeys(name, "echo before-''push")
        awaitUntil("the echo") { try host.capture(name).text.contains("before-push") }

        let connection = try host.attachConnection(name, 80, 24)
        connections.append(connection)
        let received = SvcList<Data>()
        let ends = SvcList<Int>()
        connection.onBytes = { received.append($0) }
        connection.onEnd = { ends.append(1) }
        connection.start()
        connection.start() // idempotent
        let text = { String(decoding: received.all.reduce(Data(), +), as: UTF8.self) }
        awaitUntil("the redraw") { text().contains("before-push") }
        connection.send(Data("echo after-''push\r".utf8))
        awaitUntil("live output") { text().contains("after-push") }
        connection.resize(cols: 90, rows: 25)
        awaitUntil("the resize to reach the session") { try client.list().first?.columns == 90 }

        // the session's program ends: the stream ends, onEnd once
        connection.send(Data("exit\r".utf8))
        awaitUntil("onEnd") { ends.count == 1 }
        XCTAssertFalse(connection.isAlive)
        connection.close()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(1, ends.count)
    }

    func testClosingAPushTransportEndsItOnceAndLeavesTheSession() throws {
        let name = "mhm-push-close"
        try host.newSession(name, workdir, 80, 24)
        let connection = try host.attachConnection(name, 80, 24)
        let ends = SvcList<Int>()
        connection.onEnd = { ends.append(1) }
        connection.start()
        connection.close()
        awaitUntil("onEnd") { ends.count == 1 }
        XCTAssertTrue(try host.hasSession(name))
    }

    func testServerExitsAfterTheLastKillWhenNotKeptAlive() throws {
        let exitingHome = try createDirectories(root.appendingPathComponent("exit"))
        let exiting = try start(ServeOptions.defaults(exitingHome)) // no keep-alive: the daemon's normal mode
        let exitingHost = hermetic(SessionServerHost(SessionServerClient(home: exitingHome, spawn: false)))
        try exitingHost.newSession("mhm-last", workdir, 80, 24) // cancels the boot idle timer
        XCTAssertTrue(try exitingHost.hasSession("mhm-last"))

        try exitingHost.killSession("mhm-last")
        // The idle timer re-arms when the count drops to zero and fires shortly after.
        XCTAssertTrue(exiting.awaitExit(within: SessionServerHostTests.WAIT), "the server exits after its last session ends")
        XCTAssertFalse(exiting.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ServerHome.socket(exitingHome).path),
                       "the socket file goes with it")
        // A host over the now-dead home is back to the no-server semantics.
        XCTAssertEqual([], try exitingHost.listSessions())
        XCTAssertFalse(try exitingHost.hasSession("mhm-last"))
        XCTAssertTrue(try exitingHost.capture("mhm-last").paneDead)
    }

    func testTheHostIsAStatusSessionHostForThePollerAndCloser() throws {
        let status: StatusSessionHost = host
        XCTAssertFalse(try status.hasSession("nope"))
    }
}

/// Reads a pull-style connection on its own thread until it ends.
private final class PullReader: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private let done = DispatchSemaphore(value: 0)

    init(_ connection: SessionConnection) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = (try? buffer.withUnsafeMutableBytes { try connection.read(into: $0) }) ?? -1
                if n < 0 { break }
                lock.lock(); bytes += buffer[0..<n]; lock.unlock()
            }
            done.signal()
        }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var length: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes.count
    }

    func text(after mark: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes[min(mark, bytes.count)...], as: UTF8.self)
    }

    func join() {
        XCTAssertEqual(.success, done.wait(timeout: .now() + 10), "the reader ends with the connection")
    }
}

/// A socket that answers every request the way a daemon of another protocol does.
private final class MismatchListener: @unchecked Sendable {
    private let listener: UnixListener

    init(_ socket: URL, protocol version: Int, version text: String, pid: Int64) throws {
        listener = try UnixListener(bind: socket.path)
        let listener = self.listener
        Thread.detachNewThread {
            while let connection = try? listener.accept() {
                let codec = FrameCodec(connection)
                if (try? codec.read()) != nil {
                    let reply = Json.object().with(MuxProtocol.F_OK, false)
                        .with(MuxProtocol.F_ERROR, MuxProtocol.ERROR_PROTOCOL_MISMATCH)
                        .with(MuxProtocol.F_PROTOCOL, version).with(MuxProtocol.F_VERSION, text)
                        .with(MuxProtocol.F_PID, pid)
                    try? codec.write(Frame.json(.RESPONSE, reply))
                }
                connection.close()
            }
        }
    }

    func close() {
        listener.close()
    }
}
