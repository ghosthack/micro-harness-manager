import XCTest
@testable import MicrohmCore

/// A minimal in-memory `SessionHost` for the spawner tests (the slice of Java's
/// `host.FakeSessionHost` they use).
final class SpawnerTestHost: SessionHost, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [String] = []
    private(set) var newSessionCalls: [String] = []
    private(set) var killedSessions: [String] = []
    private(set) var sentKeys: [String] = []

    func hasSession(_ session: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live.contains(session)
    }

    func sendKeys(_ session: String, _ command: String) throws {
        lock.lock(); defer { lock.unlock() }
        sentKeys.append(session + ": " + command)
    }

    func capture(_ session: String) throws -> Screen {
        Screen("", !(try hasSession(session)), Date())
    }

    func listSessions() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    func newSession(_ session: String, _ workdir: URL, _ columns: Int, _ rows: Int) throws {
        lock.lock(); defer { lock.unlock() }
        live.append(session)
        newSessionCalls.append("\(session) \(workdir.path) \(columns)x\(rows)")
    }

    func killSession(_ session: String) throws {
        lock.lock(); defer { lock.unlock() }
        live.removeAll { $0 == session }
        killedSessions.append(session)
    }

    func attach(_ session: String, _ columns: Int, _ rows: Int) throws -> SessionConnection {
        throw SessionHostException("no attach in this fake")
    }
}

/// The production spawner over a real launcher with a fake host.
final class LauncherSpawnerTests: XCTestCase {

    private func launcherWithoutMcp(_ registry: SessionRegistry, _ host: SessionHost) -> SessionLauncher {
        let launcher = SessionLauncher.withoutMcp(registry, host, SessionLabellers.none)
        launcher.directLaunch = { false } // typed launches, whatever the user's settings say
        return launcher
    }

    func testSpawnsRegistersAndAnnouncesThenKillsAndAnnounces() throws {
        let dir = try makeTempDir(self)
        let host = SpawnerTestHost()
        let registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        let launcher = launcherWithoutMcp(registry, host)
        let events = SessionEvents()
        var changed: [String?] = []
        var killed: [String] = []
        events.addSessionsChangedListener { changed.append($0) }
        events.addSessionKilledListener { killed.append($0) }
        let project = try createDirectories(dir.appendingPathComponent("api"))

        let spawner = LauncherSpawner(launcher, host, events)
        let name = try spawner.spawn(SpawnRequest(.codex, project, "API", ["spawned-by": "mhm-boss"]))

        XCTAssertEqual("mhm-api", name)
        XCTAssertEqual(["mhm-api \(project.path) 120x32"], host.newSessionCalls)
        XCTAssertEqual("API", registry.find("mhm-api")?.displayName)
        XCTAssertEqual(["mhm-api"], changed)

        try spawner.kill("mhm-api")
        XCTAssertEqual(["mhm-api"], host.killedSessions)
        XCTAssertEqual(["mhm-api"], killed)
        XCTAssertEqual(2, changed.count)
    }

    func testResumeTellsTheWindowFirstThenStartsTheSessionAgain() throws {
        let dir = try makeTempDir(self)
        let host = SpawnerTestHost()
        let registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        let launcher = launcherWithoutMcp(registry, host)
        let events = SessionEvents()
        var order: [String] = []
        events.addSessionRunEndedListener { order.append("run ended \($0) after \(host.newSessionCalls.count)") }
        events.addSessionsChangedListener { order.append("changed \($0 ?? "null")") }
        let project = try createDirectories(dir.appendingPathComponent("api"))
        let entry = SessionEntry.newlyCreated("mhm-api", project.path, .shell, nil)
        registry.put(entry)

        try LauncherSpawner(launcher, host, events).resume(entry)

        XCTAssertEqual(["mhm-api \(project.path) 120x32"], host.newSessionCalls)
        XCTAssertEqual(["run ended mhm-api after 0", "changed null", "changed mhm-api"], order)
    }

    func testKillDeletesTheSessionsMcpConfigFile() throws {
        let dir = try makeTempDir(self)
        let host = SpawnerTestHost()
        let registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        let mcpDir = dir.appendingPathComponent("mcp")
        let launcher = SessionLauncher(registry, host, { McpLink(url: "http://127.0.0.1:1/mcp/" + $0, token: "tok") },
                                       mcpDir, SessionLabellers.none, { session, workdir, columns, rows, _ in
                                           try host.newSession(session, workdir, columns, rows)
                                           return true
                                       })
        launcher.directLaunch = { false }
        let spawner = LauncherSpawner(launcher, host, SessionEvents())
        let name = try spawner.spawn(SpawnRequest(.claudeCode, try createDirectories(dir.appendingPathComponent("api")),
                                                  nil, [:]))
        let config = mcpDir.appendingPathComponent(name + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))

        try spawner.kill(name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
    }
}
