import Foundation
import XCTest
@testable import MicrohmCore
import MicrohmShared

/// The launch sequence against a fake host: naming, the typed command (with and without
/// MCP injection), labels and the registry row — for both a fresh create and a resume.
final class SessionLauncherTests: XCTestCase {

    private static let URL_BASE = "http://127.0.0.1:7392/mcp/"
    private static let TOKEN = "secret-token"

    private var dir: URL!
    private var host: FakeSessionHost!
    private var registry: SessionRegistry!
    private var project: URL!
    private var mcpUrl: String?
    private var mcpDir: URL!
    private var claudeProjects: URL!
    private let labelCalls = SvcList<(String, [String: String])>()
    /// Every env-carrying start, as `session env`.
    private let envStarts = SvcList<String>()
    /// What the fake daemon acknowledges: false plays one that predates `env`.
    private var envAcknowledged = true
    private var savedHome: URL?

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
        host = FakeSessionHost()
        registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        project = try createDirectories(dir.appendingPathComponent("proj"))
        mcpUrl = SessionLauncherTests.URL_BASE
        mcpDir = dir.appendingPathComponent("mcp")
        claudeProjects = dir.appendingPathComponent("claude-projects")
        ClaudeProjects.rootOverride = claudeProjects
        savedHome = MicrohmPaths.homeOverride
        MicrohmPaths.homeOverride = try createDirectories(dir.appendingPathComponent("home"))
    }

    override func tearDown() {
        ClaudeProjects.rootOverride = nil
        MicrohmPaths.homeOverride = savedHome
    }

    private func launcher(_ host: SessionHost? = nil) -> SessionLauncher {
        let host = host ?? self.host!
        let launcher = SessionLauncher(registry, host, { [unowned self] session in
            mcpUrl.map { McpLink(url: $0 + session, token: SessionLauncherTests.TOKEN) }
        }, mcpDir, { [labelCalls] session, labels in labelCalls.append((session, labels)) },
        { [unowned self] session, workdir, columns, rows, env in
            envStarts.append(session + " " + SessionLauncherTests.describe(env))
            try host.newSession(session, workdir, columns, rows)
            return envAcknowledged
        })
        launcher.directLaunch = { false }
        return launcher
    }

    static func describe(_ map: [String: String]) -> String {
        "{" + map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
    }

    private var sent: [String] { host.sentCommands }

    func testCreateInjectsTheMcpServerLabelsAndRegistersTheDisplayName() throws {
        let name = try launcher().create(project, .claudeCode, nil, "reviewer", ["spawnedBy": "mhm-boss"])

        XCTAssertEqual("mhm-proj", name)
        XCTAssertEqual(["mhm-proj \(project.path) 120x32"], host.newSessionCalls)
        XCTAssertTrue(envStarts.all.isEmpty, "claude reads its token from the config file, not the environment")
        let config = mcpDir.appendingPathComponent("mhm-proj.json")
        let id = try XCTUnwrap(registry.find("mhm-proj")?.harnessSessionId)
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression), id)
        XCTAssertEqual(["mhm-proj: claude --mcp-config " + HarnessPlugins.shellArgument(config.path) + " --session-id " + id],
                       sent)
        XCTAssertEqual("{\"mcpServers\":{\"micro-harness-manager\":{\"type\":\"http\",\"url\":\""
                       + SessionLauncherTests.URL_BASE + "mhm-proj\",\"headers\":{\"Authorization\":\"Bearer "
                       + SessionLauncherTests.TOKEN + "\"}}}}\n", try readString(config))
        XCTAssertEqual(1, labelCalls.count)
        XCTAssertEqual("mhm-proj", labelCalls.all[0].0)
        XCTAssertEqual(["spawnedBy": "mhm-boss", "harness": "claude-code", "project": project.path, "display": "reviewer"],
                       labelCalls.all[0].1)
        let entry = try XCTUnwrap(registry.find("mhm-proj"))
        XCTAssertEqual("reviewer", entry.displayName)
        XCTAssertEqual(.claudeCode, entry.harnessType)
    }

    func testOnlyAHarnessThatReadsTheTokenFromTheEnvironmentGetsIt() throws {
        let launcher = launcher()
        try launcher.create(project, .codex, nil, nil)
        try launcher.create(project, .shell, nil, nil)
        try launcher.create(project, .opencode, nil, nil)
        XCTAssertEqual(["mhm-proj {MHM_MCP_TOKEN=\(SessionLauncherTests.TOKEN)}"], envStarts.all, "codex only")
        XCTAssertEqual(3, host.newSessionCalls.count)
    }

    func testADaemonThatDropsTheEnvironmentGetsCodexLaunchedWithoutMcp() throws {
        envAcknowledged = false
        let launcher = launcher()
        try launcher.create(project, .codex, nil, nil)
        XCTAssertEqual(["mhm-proj {MHM_MCP_TOKEN=\(SessionLauncherTests.TOKEN)}"], envStarts.all)
        XCTAssertEqual(["mhm-proj: codex"], sent, "no MCP flags its harness could not use")
        XCTAssertNotNil(registry.find("mhm-proj"))

        // a harness that reads a config file is unaffected
        try launcher.create(project, .claudeCode, nil, nil)
        XCTAssertTrue(sent.last!.hasPrefix("mhm-proj-2: claude --mcp-config "), sent.last!)

        // and a resume on the same old daemon likewise drops MCP
        let dead = try XCTUnwrap(registry.find("mhm-proj"))
        try host.killSession("mhm-proj")
        try launcher.resume(dead, {})
        XCTAssertEqual("mhm-proj: codex", sent.last)
    }

    func testCreateWithoutARunningMcpServiceTypesThePlainCommand() throws {
        mcpUrl = nil
        try launcher().create(project, .codex, nil, nil)
        XCTAssertEqual(["mhm-proj: codex"], sent)
        XCTAssertTrue(envStarts.all.isEmpty, "no MCP, no token in the environment")
        XCTAssertEqual(["mhm-proj \(project.path) 120x32"], host.newSessionCalls)
        XCTAssertNil(registry.find("mhm-proj")?.displayName)
    }

    func testABlankDisplayNameIsNoOverride() throws {
        try launcher().create(project, .shell, nil, "  ")
        XCTAssertNil(registry.find("mhm-proj")?.displayName)
    }

    func testShellHarnessTypesNothing() throws {
        try launcher().create(project, .shell, nil, nil)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNotNil(registry.find("mhm-proj"))
    }

    func testNamesStayUniqueAcrossTheDaemonAndTheRegistry() throws {
        host.seedLiveSession("mhm-proj")
        let launcher = launcher()
        XCTAssertEqual("mhm-proj-2", try launcher.create(project, .shell, nil, nil))
        XCTAssertEqual("mhm-proj-3", try launcher.create(project, .shell, nil, nil))
    }

    func testAResumeIdWithoutSyntaxWarnsThenLaunchesFresh() throws {
        var warned = 0
        // the shell harness is the one without resume syntax; its fresh launch is "nothing"
        try launcher().create(project, .shell, "x", nil, [:], onNoResumeSyntax: { warned += 1 })
        XCTAssertEqual(1, warned)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(["mhm-proj \(project.path) 120x32"], host.newSessionCalls)
    }

    func testAFailingLabellerNeverFailsTheLaunch() throws {
        let launcher = SessionLauncher.withoutMcp(registry, host) { _, _ in
            throw SessionHostException("daemon too old")
        }
        launcher.directLaunch = { false }
        XCTAssertEqual("mhm-proj", try launcher.create(project, .codex, nil, nil))
        XCTAssertEqual(["mhm-proj: codex"], sent)
    }

    func testAFailedCreatePropagatesAndRegistersNothing() {
        host.onSendKeys = { _ in throw SessionHostException("boom") }
        XCTAssertThrowsError(try launcher().create(project, .codex, nil, nil)) { error in
            XCTAssertTrue(error is SessionHostException)
        }
        XCTAssertNil(registry.find("mhm-proj"))
    }

    func testResumeInjectsAheadOfTheResumeSubcommandAndKeepsTheRow() throws {
        let dead = SessionEntry("mhm-proj", project.path, .codex, "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
                                Date(timeIntervalSince1970: 0), "named")
        registry.put(dead)
        try launcher().resume(dead) { XCTFail("codex has resume syntax") }
        XCTAssertEqual(["mhm-proj: codex -c 'mcp_servers.micro-harness-manager.url=\"" + SessionLauncherTests.URL_BASE
                        + "mhm-proj\"' -c 'mcp_servers.micro-harness-manager.bearer_token_env_var=\"MHM_MCP_TOKEN\"'"
                        + " resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"], sent)
        XCTAssertEqual(["mhm-proj {MHM_MCP_TOKEN=\(SessionLauncherTests.TOKEN)}"], envStarts.all)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mcpDir.path), "codex needs no config file")
        XCTAssertEqual(["harness": "codex", "project": project.path, "display": "named"], labelCalls.all.first?.1)
        XCTAssertEqual(dead, registry.find("mhm-proj"))
    }

    func testTheConfigFileIsOwnerOnlyRewrittenOnResumeAndDiscardedOnRequest() throws {
        let launcher = launcher()
        try launcher.create(project, .claudeCode, nil, nil)
        let config = mcpDir.appendingPathComponent("mhm-proj.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        let dirMode = try FileManager.default.attributesOfItem(atPath: mcpDir.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        XCTAssertEqual(0o700, dirMode)
        XCTAssertEqual(0o600, fileMode)
        XCTAssertEqual(["mhm-proj.json"], try FileManager.default.contentsOfDirectory(atPath: mcpDir.path),
                       "no temp file left behind")

        // a resume after a token change overwrites the file with the current token
        mcpUrl = "http://127.0.0.1:9/mcp/"
        try host.killSession("mhm-proj")
        try launcher.resume(try XCTUnwrap(registry.find("mhm-proj")), {})
        let rewritten = try readString(config)
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:9/mcp/mhm-proj"), rewritten)

        // resumed while the service is off: the stale token's file goes
        mcpUrl = nil
        try host.killSession("mhm-proj")
        try launcher.resume(try XCTUnwrap(registry.find("mhm-proj")), {})
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual("mhm-proj: claude --session-id " + (registry.find("mhm-proj")?.harnessSessionId ?? "?"), sent.last,
                       "no MCP flag; still no message, so a fresh start under its id")

        try writeString(config, "x")
        launcher.discardMcpConfig("mhm-proj")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        launcher.discardMcpConfig("mhm-proj") // already gone: no complaint
    }

    func testAnUnwritableConfigDirLaunchesWithoutMcp() throws {
        try writeString(dir.appendingPathComponent("blocker"), "not a directory")
        mcpDir = dir.appendingPathComponent("blocker").appendingPathComponent("mcp")
        try launcher().create(project, .claudeCode, nil, nil)
        XCTAssertEqual(["mhm-proj: claude --session-id " + (registry.find("mhm-proj")?.harnessSessionId ?? "?")], sent)
    }

    func testSessionNamesBecomeFileSafeConfigNames() {
        XCTAssertEqual(mcpDir.appendingPathComponent("a_b_.._c.json"), launcher().mcpConfigFile("a/b/../c"))
    }

    func testANameThatKeepsGettingTakenGivesUpAfterBoundedRetries() {
        var probes = 0
        // every candidate is registered by "someone else" right after it probes free
        host.onHasSession = { [registry, project] session in
            probes += 1
            registry!.put(SessionEntry.newlyCreated(session, project!.path, .shell, nil))
        }
        XCTAssertThrowsError(try launcher().create(project, .shell, nil, nil))
        XCTAssertTrue(probes <= 2 * SessionLauncher.MAX_NAME_ATTEMPTS, "bounded: \(probes)")
        XCTAssertTrue(host.newSessionCalls.isEmpty)
    }

    func testASlowHostProbeNeitherBlocksOtherLaunchesNorLetsThemShareAName() throws {
        let probing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probes = Atomic(wrappedValue: 0)
        // the first probe of mhm-proj answers "free" and then stalls, like a slow daemon round trip
        host.onHasSession = { session in
            if session == "mhm-proj" {
                let n = probes.wrappedValue
                probes.wrappedValue = n + 1
                if n == 0 {
                    probing.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
            }
        }
        let launcher = launcher()
        let project = self.project!
        let slow = SvcList<Result<String, Error>>()
        Thread.detachNewThread {
            slow.append(Result { try launcher.create(project, .shell, nil, nil) })
        }
        XCTAssertEqual(.success, probing.wait(timeout: .now() + 10))
        // the stalled probe holds no lock: a second launch in the same folder completes
        XCTAssertEqual("mhm-proj", try launcher.create(project, .shell, nil, nil))
        release.signal()
        // the slow launch's "free" answer went stale meanwhile; it re-derives
        svcAwait(10) { slow.count == 1 }
        XCTAssertEqual("mhm-proj-2", try slow.all.first?.get())
    }

    func testAFreshLocalClaudeIsGivenItsSessionIdSoTheRowKnowsItFromTheStart() throws {
        mcpUrl = nil
        try launcher().create(project, .claudeCode, nil, nil)
        let id = try XCTUnwrap(registry.find("mhm-proj")?.harnessSessionId)
        XCTAssertEqual(["mhm-proj: claude --session-id " + id], sent)

        // a harness that can't be told its id launches as before, with no id on the row
        try launcher().create(project, .codex, nil, nil)
        XCTAssertEqual("mhm-proj-2: codex", sent.last)
        XCTAssertNil(registry.find("mhm-proj-2")?.harnessSessionId)
    }

    func testAResumeWhoseConversationNeverGotAMessageStartsFreshUnderTheSameId() throws {
        mcpUrl = nil
        let dead = SessionEntry.newlyCreated("mhm-proj", project.path, .claudeCode, "1111-2222")
        registry.put(dead)
        try launcher().resume(dead, {})
        XCTAssertEqual("mhm-proj: claude --session-id 1111-2222", sent.last,
                       "no transcript yet: --resume would fail with \"No conversation found\"")

        let encoded = String(project.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let claudeDir = try createDirectories(claudeProjects.appendingPathComponent(encoded))
        try writeString(claudeDir.appendingPathComponent("1111-2222.jsonl"), "{}\n")
        try host.killSession("mhm-proj")
        try launcher().resume(dead, {})
        XCTAssertEqual("mhm-proj: claude --resume 1111-2222", sent.last)
    }

    // ---- one-step launches (the shell runs the agent itself)

    func testADirectLaunchStartsTheAgentAsTheShellsOwnCommand() throws {
        let direct = FakeDirectSessionHost()
        host = direct
        let launcher = launcher(direct)
        launcher.directLaunch = { true }
        launcher.sessionShell = { "bash" }
        launcher.shells = SessionShell(windows: false, env: ["PATH": "/bin"], executable: { $0 == "/bin/bash" })
        try launcher.create(project, .codex, nil, nil)
        XCTAssertTrue(direct.sentCommands.isEmpty, "nothing is typed")
        XCTAssertEqual(1, direct.directStarts.count)
        let start = direct.directStarts[0]
        XCTAssertTrue(start.hasPrefix("mhm-proj [\"/bin/bash\", \"-l\", \"-i\", \"-c\", \"codex -c "), start)
        XCTAssertTrue(start.contains("; exec \\'/bin/bash\\' -l\"]") || start.contains("; exec '/bin/bash' -l\"]"), start)
        XCTAssertTrue(start.contains("MHM_MCP_TOKEN"), "codex gets its token in the environment: \(start)")
        XCTAssertNotNil(registry.find("mhm-proj"))

        // a shell that cannot do it falls back to typing the command
        launcher.sessionShell = { "/usr/bin/xonsh" }
        launcher.shells = SessionShell(windows: false, env: [:], executable: { _ in true })
        try launcher.create(project, .shell, nil, nil)
        XCTAssertEqual(1, direct.directStarts.count, "a plain shell has nothing to start")
    }
}
