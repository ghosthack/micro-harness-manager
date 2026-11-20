import Darwin
import XCTest
@testable import MicrohmMux

/// The client starting a real daemon — the built `microhm-mux serve --daemon` — in a
/// temporary home (ports of `ServerLauncherTest` and `SessionServerClientSpawnTest`).
final class DaemonSpawnTests: XCTestCase {

    private var temp: TempHome!

    override func setUp() {
        temp = TempHome()
    }

    override func tearDown() {
        try? SessionServerClient(home: temp.home, spawn: false).shutdown()
        temp.remove()
    }

    func testResolutionOrder() {
        let explicit = URL(fileURLWithPath: "/opt/a/microhm-mux")
        let sibling = URL(fileURLWithPath: "/Applications/Microhm.app/Contents/MacOS/microhm-mux")
        XCTAssertEqual(["/opt/a/microhm-mux", "serve", "--daemon"],
                       ServerLauncher.resolveCommand(explicit: explicit, launcherEnv: "/env/x", sibling: sibling))
        XCTAssertEqual(["/env/x", "serve", "--daemon"],
                       ServerLauncher.resolveCommand(explicit: nil, launcherEnv: "/env/x", sibling: sibling))
        XCTAssertEqual([sibling.path, "serve", "--daemon"],
                       ServerLauncher.resolveCommand(explicit: nil, launcherEnv: " ", sibling: sibling))
        XCTAssertNil(ServerLauncher.resolveCommand(explicit: nil, launcherEnv: nil, sibling: nil))
    }

    func testNewSessionSpawnsADetachedDaemonThatOutlivesTheClient() throws {
        let launcher = try XCTUnwrap(builtMicrohmMux(), "microhm-mux is built next to the tests")
        let client = SessionServerClient(home: temp.home, spawn: true, launcher: launcher)
        XCTAssertNil(try client.ping())
        try client.newSession("spawned", workdir: temp.workdir(), columns: 80, rows: 24, command: ["/bin/sh"])
        let info = try XCTUnwrap(try client.ping())
        XCTAssertNotEqual(Int64(getpid()), info.pid, "a separate process")
        let daemon = try XCTUnwrap(ProcessTable.entry(of: Int32(info.pid)))
        XCTAssertEqual(daemon.pid, daemon.pgid, "its own process group (a session leader)")
        XCTAssertEqual(["spawned"], try client.list().map(\.name))
        var st = stat()
        XCTAssertEqual(0, stat(ServerHome.log(temp.home).path, &st))
        XCTAssertEqual(0o600, st.st_mode & 0o777)

        // A second client (another app instance) joins the same daemon without spawning.
        let other = SessionServerClient(home: temp.home, spawn: true, launcher: URL(fileURLWithPath: "/nonexistent"))
        try other.newSession("second", workdir: temp.workdir(), columns: 80, rows: 24, command: ["/bin/sh"])
        XCTAssertEqual(info.pid, try other.ping()?.pid)

        try client.shutdown()
        XCTAssertNil(try client.ping())
        awaitCondition(5, "the daemon process to end") { !ProcessTable.isAlive(Int32(info.pid)) }
    }

    func testAFailingDaemonIsReportedWithItsLogInsteadOfWaitingOutTheDeadline() throws {
        let launcher = try XCTUnwrap(builtMicrohmMux())
        // A home whose socket path is over the 104-byte limit: the daemon cannot bind.
        let deep = temp.root.appendingPathComponent(String(repeating: "d", count: 100), isDirectory: true)
        let client = SessionServerClient(home: deep, spawn: true, launcher: launcher)
        let start = Date()
        XCTAssertThrowsError(try client.newSession("x", workdir: temp.workdir(), columns: 80, rows: 24)) { error in
            XCTAssertTrue("\(error)".contains("exited with status 1"), "\(error)")
            XCTAssertTrue("\(error)".contains("over the OS limit"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), SessionServerClient.CONNECT_TIMEOUT_SECONDS)
    }

    func testNothingToLaunchIsAClearError() {
        let client = SessionServerClient(home: temp.home, spawn: true, spawner: { _ in
            throw SessionServerException("cannot start the session daemon: no launcher")
        })
        XCTAssertThrowsError(try client.newSession("x", workdir: temp.workdir(), columns: 80, rows: 24)) {
            XCTAssertEqual("cannot start the session daemon: no launcher", "\($0)")
        }
    }
}
