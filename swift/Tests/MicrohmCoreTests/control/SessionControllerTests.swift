import XCTest
@testable import MicrohmCore
import MicrohmMux

/// The MCP session controller against an in-memory daemon (Java's `SessionControllerTest`):
/// tool calls run inline, the monitor is driven with `tick()` and a mutable clock, and
/// deliveries run on the ticking thread.
final class SessionControllerTests: XCTestCase {

    private static let NOTICE_TAIL = ". Use the read tool to see it."
    /// Claude Code idle at its prompt.
    private static let CLAUDE_IDLE = "Done.\n❯ \n? for shortcuts\n"
    /// Claude Code asking for a permission.
    private static let CLAUDE_APPROVAL = "Bash: rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n"
        + "  2. No, and tell Claude what to do differently (esc)\n"

    private var dir: URL!
    private var daemon: FakeDaemon!
    private var registry: SessionRegistry!
    private var clock: MutableClock!
    private var spawner: FakeSpawner!
    private let sleepsLock = NSLock()
    private var recordedSleeps: [TimeInterval] = []
    private var controller: SessionController!
    /// The user's session-logs setting; on, as the log tests need, unless a test turns it off.
    private var sessionLogs = true

    private var sleeps: [TimeInterval] {
        sleepsLock.lock(); defer { sleepsLock.unlock() }
        return recordedSleeps
    }

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
        daemon = FakeDaemon()
        registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        clock = MutableClock()
        spawner = FakeSpawner(daemon)
        controller = makeController(SessionController.Timings.DEFAULT)
    }

    override func tearDown() {
        controller?.serverStopped()
    }

    private func makeController(_ timings: SessionController.Timings,
                                _ deliveries: @escaping SessionController.Executor = { $0() }) -> SessionController {
        SessionController(daemon, registry, spawner, clock, { harness, project, id, _ in
            switch harness {
            case .codex: return URL(fileURLWithPath: "/codex/rollout-x.jsonl")
            case .claudeCode:
                return URL(fileURLWithPath: "/claude" + project.path).appendingPathComponent((id ?? "newest") + ".jsonl")
            case .muse: return URL(fileURLWithPath: "/muse/sessions/2026/11/08/m1/session.jsonl")
            default: return nil
            }
        }, { [weak self] seconds in
            guard let self else { return }
            sleepsLock.lock()
            recordedSleeps.append(seconds)
            sleepsLock.unlock()
        }, deliveries, timings, { [weak self] in self?.sessionLogs ?? false })
    }

    private static func fastTimings() -> SessionController.Timings {
        SessionController.Timings(tick: 0.01, enterDelay: 0, shortQuiescence: 5, longQuiescence: 20, notifyTtl: 30 * 60,
                                  promptTimeout: 120, keysQuietMs: 300, keysTimeoutMs: 3000, watchQuietMs: 500,
                                  watchBackoffMin: 0.005, watchBackoffMax: 0.02)
    }

    // MARK: - helpers

    private func call(_ caller: String?, _ tool: String, _ json: String) -> ToolResult {
        controller.call(caller, tool, try! CoreJSON.parse(json))
    }

    @discardableResult
    private func ok(_ caller: String?, _ tool: String, _ json: String,
                    file: StaticString = #filePath, line: UInt = #line) -> String {
        let result = call(caller, tool, json)
        XCTAssertFalse(result.isError, "expected success, got: " + result.text, file: file, line: line)
        return result.text
    }

    private func error(_ caller: String?, _ tool: String, _ json: String,
                       file: StaticString = #filePath, line: UInt = #line) -> String {
        let result = call(caller, tool, json)
        XCTAssertTrue(result.isError, "expected an error, got: " + result.text, file: file, line: line)
        return result.text
    }

    @discardableResult
    private func shell(_ name: String) -> FakeDaemon.FakeSession {
        let s = daemon.add(name)
        s.labels["harness"] = "shell"
        return s
    }

    /// A claude-code session showing `screen`, claude in the foreground.
    @discardableResult
    private func agent(_ name: String, _ screen: String) -> FakeDaemon.FakeSession {
        let s = daemon.add(name)
        s.labels["harness"] = "claude-code"
        s.foreground = "claude"
        return s.show(screen)
    }

    /// Lets `seconds` pass, one monitor tick a second.
    private func ticks(_ seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(1)
            try? controller.tick()
        }
    }

    private func tick() {
        XCTAssertNoThrow(try controller.tick())
    }

    private func register(_ name: String, _ harness: HarnessType, _ display: String?) {
        let entry = SessionEntry.newlyCreated(name, "/proj/" + name, harness, nil)
        registry.put(display != nil ? entry.withDisplayName(display) : entry)
    }

    private func lines(_ from: Int, _ to: Int) -> String {
        (from...to).map { "line \($0)\n" }.joined()
    }

    private func inputsTo(_ session: String) -> [FakeDaemon.Input] {
        daemon.inputs.filter { $0.session == session }
    }

    private func contents(_ url: URL) -> String {
        (try? readString(url)) ?? ""
    }

    private func textLines(_ s: String) -> [String] {
        JavaText.lines(s)
    }

    /// Whole seconds of the clock, as the log markers print them.
    private func stamp() -> String {
        IsoInstant.format(Date(timeIntervalSince1970: clock.instant().timeIntervalSince1970.rounded(.down)))
    }

    private func awaitTrue(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in time", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // MARK: - tools/list

    func testOffersTheSevenToolsWithDescribedSchemas() {
        XCTAssertEqual(["list", "read", "send", "keys", "notify", "spawn", "kill"], controller.tools().map(\.name))
        for def in controller.tools() {
            XCTAssertEqual("object", def.inputSchema.path("type").asText())
            for p in def.inputSchema.path("properties").elements {
                XCTAssertFalse(JavaText.isBlank(p.path("description").asText()), def.name)
            }
        }
        XCTAssertTrue(controller.tools()[0].description.contains("claude-code, codex, muse, grok"))
        XCTAssertTrue(controller.tools()[1].description.contains("earlier output is in the transcript"))
        let keys = controller.tools()[3]
        XCTAssertTrue(keys.description.contains("C-c"))
        XCTAssertTrue(keys.description.contains("PageDown"))
        let harnesses = controller.tools()[5].inputSchema.path("properties").path("harness").path("enum")
        XCTAssertEqual(HarnessType.allCases.count, harnesses.elements.count)
    }

    // MARK: - phone page

    func testSummariesAndScreenGiveThePhonePageData() throws {
        agent("mhm-a", Self.CLAUDE_APPROVAL)
        register("mhm-a", .claudeCode, "Alpha")
        shell("mhm-b").show("$ ls\n")
        _ = try controller.summaries() // first look: just changed, so working
        clock.advance(30)

        let summaries = try controller.summaries()
        XCTAssertEqual(["mhm-a", "mhm-b"], summaries.map(\.name))
        XCTAssertEqual("Alpha", summaries[0].display)
        XCTAssertEqual("claude-code", summaries[0].harness)
        XCTAssertEqual("WAITING_FOR_INPUT", summaries[0].state)
        XCTAssertEqual("/proj/mhm-a", summaries[0].project)

        let view = try XCTUnwrap(try controller.screen("Alpha"))
        XCTAssertEqual("mhm-a", view.name)
        XCTAssertEqual("WAITING_FOR_INPUT", view.state)
        XCTAssertTrue(view.text.contains("Do you want to proceed?"), view.text)
        XCTAssertFalse(view.text.contains("▶"), "plain text, no markers: " + view.text)
        XCTAssertThrowsError(try controller.screen("nope"))
    }

    func testEndedListsSavedSessionsTheDaemonIsNotRunningNewestFirst() throws {
        registry.put(SessionEntry("mhm-old", "/p/old", .claudeCode, "abc", IsoInstant.parse("2026-11-01T00:00:00Z")!, nil))
        registry.put(SessionEntry("mhm-new", "/p/new", .codex, nil, IsoInstant.parse("2026-11-10T00:00:00Z")!, nil))
        register("mhm-live", .shell, nil)
        shell("mhm-live").show("$ ")

        // a session whose program ended but the daemon still lists counts as ended
        register("mhm-gone", .shell, nil)
        shell("mhm-gone").show("$ exit").alive = false
        XCTAssertEqual(["mhm-live"], try controller.summaries().map(\.name))

        let ended = try controller.ended()
        XCTAssertEqual(["mhm-gone", "mhm-new", "mhm-old"], ended.map(\.name)) // newest first: mhm-gone was just made
        XCTAssertFalse(ended[1].conversation)
        XCTAssertTrue(ended[2].conversation)
        XCTAssertEqual("/p/old", ended[2].project)
    }

    func testResumeStartsAnEndedSessionByNameOrSidebarName() throws {
        registry.put(SessionEntry.newlyCreated("mhm-a", "/p/a", .claudeCode, "abc").withDisplayName("Alpha"))
        XCTAssertEqual("mhm-a", try controller.resume("alpha"))
        XCTAssertEqual(["mhm-a"], spawner.resumed)
        XCTAssertThrowsError(try controller.resume("mhm-a")) { XCTAssertEqual("mhm-a is already running", "\($0)") }
        XCTAssertThrowsError(try controller.resume("nope")) {
            XCTAssertTrue("\($0)".contains("no saved session named nope"))
        }
    }

    func testSummariesOfNoDaemonAreEmpty() throws {
        daemon.down = true
        XCTAssertEqual([], try controller.summaries())
        // and a session asked for by name has ended, rather than "the daemon is not answering"
        XCTAssertNil(try controller.screen("mhm-gone"))
    }

    func testUnknownToolIsAnError() {
        XCTAssertTrue(error(nil, "explode", "{}").contains("unknown tool"))
    }

    // MARK: - resolution

    func testResolvesByNameRegistryDisplayNameAndDisplayLabel() {
        shell("mhm-a").show("alpha")
        daemon.add("mhm-b").show("beta")
        register("mhm-b", .shell, "Backend")
        shell("mhm-c").show("gamma").labels["display"] = "Docs"

        XCTAssertTrue(ok(nil, "read", "{\"session\":\"mhm-a\"}").hasPrefix("mhm-a · shell"))
        XCTAssertTrue(ok(nil, "read", "{\"session\":\"backend\"}").hasPrefix("mhm-b · shell"))
        XCTAssertTrue(ok(nil, "read", "{\"session\":\"DOCS\"}").hasPrefix("mhm-c · shell"))
        XCTAssertTrue(error(nil, "read", "{\"session\":\"nope\"}").contains("no such session: nope"))
    }

    func testARegisteredSessionThatIsNotRunningIsReportedAsSuch() {
        registry.put(SessionEntry.newlyCreated("mhm-t", "/p", .codex, nil).withDisplayName("Gone"))
        XCTAssertTrue(error(nil, "read", "{\"session\":\"mhm-t\"}").contains("mhm-t is not running"))
        XCTAssertTrue(error(nil, "send", "{\"session\":\"gone\",\"text\":\"hi\"}").contains("mhm-t is not running"))
    }

    func testAmbiguousDisplayNameIsAnError() {
        shell("mhm-a").labels["display"] = "Twin"
        shell("mhm-b").labels["display"] = "twin"
        XCTAssertTrue(error(nil, "read", "{\"session\":\"Twin\"}").contains("ambiguous"))
    }

    // MARK: - list

    func testListsOneLinePerSessionWithStateProjectTranscriptAndTheCallersMark() {
        daemon.quietProbe = true // both long idle: primed straight to a quiescent state
        daemon.add("mhm-api").show("› ready").foreground = "codex"
        register("mhm-api", .codex, "API")
        shell("mhm-sh").show("$ ").workdir = URL(fileURLWithPath: "/tmp/sh")

        let rows = ok("mhm-sh", "list", "{}").components(separatedBy: "\n")
        XCTAssertEqual(2, rows.count)
        XCTAssertTrue(rows[0].hasPrefix("mhm-api · API · codex · "), rows[0])
        XCTAssertTrue(rows[0].hasSuffix(" · /proj/mhm-api · transcript: /codex/rollout-x.jsonl · log: -"),
                      "the caller's folder doesn't exist: " + rows[0])
        XCTAssertEqual("mhm-sh · - · shell · IDLE · /tmp/sh · transcript: - · log: - (you)", rows[1])
    }

    func testAClaudeTranscriptIsNeverGuessedWhenAnotherClaudeSessionSharesTheProject() {
        daemon.quietProbe = true
        for name in ["mhm-one", "mhm-two", "mhm-solo"] {
            daemon.add(name).show("> ").foreground = "claude"
        }
        registry.put(SessionEntry.newlyCreated("mhm-one", "/shared", .claudeCode, "id-1"))
        registry.put(SessionEntry.newlyCreated("mhm-two", "/shared", .claudeCode, nil))
        registry.put(SessionEntry.newlyCreated("mhm-solo", "/alone", .claudeCode, nil))

        let rows = ok(nil, "list", "{}").components(separatedBy: "\n")
        XCTAssertTrue(rows[0].hasSuffix("transcript: /claude/shared/id-1.jsonl · log: -"), "its own file: " + rows[0])
        XCTAssertTrue(rows[1].contains("transcript: /claude/shared/ (id unknown"), "the folder, not a guess: " + rows[1])
        XCTAssertTrue(rows[2].hasSuffix("transcript: /claude/alone/newest.jsonl · log: -"), "alone in its project: " + rows[2])
    }

    func testListWithoutSessionsSaysSo() {
        XCTAssertTrue(ok(nil, "list", "{}").hasPrefix("no sessions"))
    }

    // MARK: - read

    func testReadIsWholeThenUnchangedThenIncrementalThenFullOnRequest() {
        let s = shell("mhm-a").show(lines(1, 10) + "$ ▮\n\n\n")
        let first = ok("mhm-me", "read", "{\"session\":\"mhm-a\"}")
        let firstLines = first.components(separatedBy: "\n")
        XCTAssertTrue(firstLines[0].hasPrefix("mhm-a · shell · WORKING ("), firstLines[0])
        XCTAssertEqual(12, firstLines.count, "header + 11 lines, trailing blanks trimmed")

        let again = ok("mhm-me", "read", "{\"session\":\"mhm-a\"}")
        XCTAssertTrue(again.hasSuffix(" · unchanged"), again)
        XCTAssertEqual(1, again.components(separatedBy: "\n").count)

        // scrolled by three lines: only the new ones and the prompt come back
        s.show(lines(4, 13) + "$ ▮\n")
        let rows = textLines(ok("mhm-me", "read", "{\"session\":\"mhm-a\"}"))
        XCTAssertTrue(rows[1].hasPrefix("… (7 lines above already seen"), rows[1])
        XCTAssertEqual(["line 11", "line 12", "line 13", "$ ▮"], Array(rows[2...]))

        let full = ok("mhm-me", "read", "{\"session\":\"mhm-a\",\"full\":true}")
        XCTAssertEqual(12, full.components(separatedBy: "\n").count)
        XCTAssertTrue(full.contains("line 4\n"))

        // seen-tracking is per caller: another reader starts with the whole screen
        XCTAssertEqual(12, ok("mhm-other", "read", "{\"session\":\"mhm-a\"}").components(separatedBy: "\n").count)
    }

    func testWholeScreenReadsEndWithWhereTheTranscriptIs() {
        let s = daemon.add("mhm-m")
        s.labels["harness"] = "muse"
        s.show(lines(1, 5))
        let note = "… (earlier output is in the transcript, /muse/sessions/2026/11/08/m1/session.jsonl: grep or tail it)"
        let first = ok("mhm-me", "read", "{\"session\":\"mhm-m\"}")
        XCTAssertTrue(first.hasSuffix("\nline 5\n" + note), first)
        XCTAssertTrue(ok("mhm-me", "read", "{\"session\":\"mhm-m\"}").hasSuffix(" · unchanged"), "no note")
        s.show(lines(3, 8))
        XCTAssertFalse(ok("mhm-me", "read", "{\"session\":\"mhm-m\"}").contains("transcript"),
                       "an incremental read has no note")
        XCTAssertTrue(ok("mhm-me", "read", "{\"session\":\"mhm-m\",\"full\":true}").hasSuffix(note))

        shell("mhm-sh").show(lines(1, 3))
        XCTAssertFalse(ok(nil, "read", "{\"session\":\"mhm-sh\"}").contains("transcript"), "no transcript, no note")
    }

    // MARK: - screen logs

    /// A shell session working in a fresh folder of `dir`: the caller whose logs go there.
    private func callerIn(_ name: String) throws -> URL {
        let project = try createDirectories(dir.appendingPathComponent("project-" + name))
        shell(name).show("$ ").workdir = project
        return project
    }

    private func logFile(_ project: URL, _ session: String) -> URL {
        project.appendingPathComponent(".microhm-sessions").appendingPathComponent(session + ".log")
    }

    func testTheCallersProjectGetsAPlainLogOfEachSessionsScrollbackEachLineOnce() throws {
        let project = try callerIn("mhm-me")
        let s = daemon.add("mhm-m")
        s.labels["harness"] = "muse"
        s.show(lines(10, 12))
        s.history = ["line 1", "line 2"]

        let log = logFile(project, "mhm-m")
        let before = ok("mhm-me", "list", "{}")
        XCTAssertTrue(textLines(before).allSatisfy { $0.contains(" · log: -") }, "no log before a read: " + before)
        tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".microhm-sessions").path),
                       "listing copies nothing into the project")
        ok("mhm-me", "read", "{\"session\":\"mhm-m\"}")
        let list = ok("mhm-me", "list", "{}")
        XCTAssertTrue(list.contains("mhm-m · - · muse · ") && list.contains(" · log: " + log.path), list)
        XCTAssertTrue(list.contains(project.path + " · transcript: - · log: - (you)"), "none of your own session: " + list)
        XCTAssertEqual("line 1\nline 2\n", contents(log), "the scrollback the session holds, at once")
        XCTAssertEqual("*\n", contents(project.appendingPathComponent(".microhm-sessions/.gitignore")),
                       "kept out of git")

        s.history = ["line 1", "line 2", "line 3", "line 4"]
        tick()
        tick()
        XCTAssertEqual("line 1\nline 2\nline 3\nline 4\n", contents(log), "kept up on the monitor's tick, each line once")

        s.historyDropped = 10 // 10 more scrolled off; only the last 4 are still held
        s.history = ["line 11", "line 12", "line 13", "line 14"]
        tick()
        XCTAssertTrue(contents(log).hasSuffix("line 4\n--- microhm · " + stamp()
            + " · 6 lines scrolled past before they could be copied ---\nline 11\nline 12\nline 13\nline 14\n"),
                      contents(log))

        let full = ok("mhm-me", "read", "{\"session\":\"mhm-m\",\"full\":true}")
        XCTAssertTrue(full.hasSuffix("… (earlier output is in the transcript, /muse/sessions/2026/11/08/m1/session.jsonl"
            + ", and in the screen log, " + log.path + ": grep or tail them)"), full)

        // a new session under the same name counts its scrollback afresh
        s.processId = 5151
        s.historyDropped = 0
        s.history = ["fresh 1"]
        tick()
        XCTAssertTrue(contents(log).hasSuffix("line 14\n--- microhm · " + stamp()
            + " · a new session (pid 5151) ---\nfresh 1\n"), contents(log))

        // the session ends: its last lines, then no more
        s.history = ["fresh 1", "bye"]
        s.alive = false
        tick()
        s.history = ["fresh 1", "bye", "never"]
        tick()
        XCTAssertTrue(contents(log).hasSuffix("fresh 1\nbye\n"), contents(log))
    }

    func testAFullScreenProgramsLogGetsEachNewLineOfItsScreenOnceWithoutItsChrome() throws {
        let project = try callerIn("mhm-me")
        let s = daemon.add("mhm-g")
        s.labels["harness"] = "grok"
        s.alternateScreen = true
        s.show("Grok\n   ⠙ Responding… 1.0s        1s ⇣1.0k [stop]\n\n")
        let log = logFile(project, "mhm-g")
        ok("mhm-me", "read", "{\"session\":\"mhm-g\"}")
        let stamp = stamp()
        s.show("Grok\nThe answer\n   ⠴ Responding… 2.0s        2s ⇣1.0k [stop]\n")
        tick()
        s.show("Grok\nThe answer\nis 42.\n\n")
        tick()
        tick()
        XCTAssertEqual("--- microhm · " + stamp + " · screen ---\nGrok\nThe answer\nis 42.\n", contents(log),
                       "each line once, no status row")
    }

    func testADaemonWithoutScrollbackReadsKeepsNoLog() throws {
        let project = try callerIn("mhm-me")
        daemon.noHistory = true
        shell("mhm-sh").show("$ make\nok\n")
        XCTAssertTrue(ok("mhm-me", "list", "{}").contains("mhm-sh · - · shell · "), "list still works")
        XCTAssertFalse(ok("mhm-me", "read", "{\"session\":\"mhm-sh\",\"full\":true}").contains("screen log"),
                       "read still works, and names no log")
        XCTAssertTrue(textLines(ok("mhm-me", "list", "{}")).first { $0.hasPrefix("mhm-sh") }!.hasSuffix(" · log: -"))
        tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile(project, "mhm-sh").path))
    }

    func testNoLogIsKeptWhileSessionLogsAreOffAndThoseBeingKeptStopWhenTheyAreTurnedOff() throws {
        let project = try callerIn("mhm-me")
        let s = shell("mhm-sh").show("$ ")
        s.history = ["one"]
        sessionLogs = false
        XCTAssertFalse(ok("mhm-me", "read", "{\"session\":\"mhm-sh\",\"full\":true}").contains("screen log"))
        tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".microhm-sessions").path),
                       "off: nothing is copied")
        XCTAssertTrue(textLines(ok("mhm-me", "list", "{}")).allSatisfy { $0.contains(" · log: -") })

        sessionLogs = true
        ok("mhm-me", "read", "{\"session\":\"mhm-sh\"}")
        let log = logFile(project, "mhm-sh")
        XCTAssertEqual("one\n", contents(log))

        sessionLogs = false
        s.history = ["one", "two"]
        tick()
        XCTAssertEqual("one\n", contents(log), "turned off: no longer kept, and what was written stays")
        XCTAssertTrue(textLines(ok("mhm-me", "list", "{}")).allSatisfy { $0.contains(" · log: -") })
    }

    func testLogsOfACallerThatEndedStop() throws {
        let project = try callerIn("mhm-me")
        let s = shell("mhm-sh").show("$ ")
        s.history = ["one"]
        ok("mhm-me", "read", "{\"session\":\"mhm-sh\"}")
        let log = logFile(project, "mhm-sh")
        XCTAssertEqual("one\n", contents(log))
        daemon.remove("mhm-me")
        s.history = ["one", "two"]
        tick()
        XCTAssertEqual("one\n", contents(log), "its caller is gone: no longer kept")
    }

    func testChromeOnlyChangesReadAsOnlyStatusLinesChangedWithJustThoseLines() {
        let s = agent("mhm-c", "Answer: 42\n❯ \n? for shortcuts\n")
        ok(nil, "read", "{\"session\":\"mhm-c\"}")
        s.show("Answer: 42\n❯ typing▮\n? for shortcuts    auto mode on\n")
        let read = ok(nil, "read", "{\"session\":\"mhm-c\"}")
        let rows = textLines(read)
        XCTAssertTrue(rows[0].hasSuffix(" · only status lines changed"), read)
        XCTAssertEqual(["❯ typing▮", "? for shortcuts    auto mode on"], Array(rows[1...]))
    }

    func testSameTextWithMovedMarkersOrSameOutputCountIsUnchanged() {
        let s = shell("mhm-a").show("$ ls\n▶ a\nb\n$ ▮\n")
        ok(nil, "read", "{\"session\":\"mhm-a\"}")
        s.show("$ ls\na\n▶ b\n$▮ \n") // only the highlight and the cursor moved
        XCTAssertTrue(ok(nil, "read", "{\"session\":\"mhm-a\"}").hasSuffix(" · unchanged"))
        s.text = "$ ls\na\nb\n$ x▮\n" // no output counted (a repaint the daemon did not count)
        XCTAssertTrue(ok(nil, "read", "{\"session\":\"mhm-a\"}").hasSuffix(" · unchanged"))
    }

    func testRedrawnScreenComesBackWhole() {
        let s = shell("mhm-a").show(lines(1, 10))
        ok(nil, "read", "{\"session\":\"mhm-a\"}")
        s.show(lines(50, 59))
        XCTAssertEqual(11, ok(nil, "read", "{\"session\":\"mhm-a\"}").components(separatedBy: "\n").count)
    }

    func testLongScreensAreCappedKeepingTheTail() {
        let wide = String(repeating: "x", count: 200)
        shell("mhm-a").show((0..<60).map { "\($0) \(wide)\n" }.joined())
        let read = ok(nil, "read", "{\"session\":\"mhm-a\"}")
        let body = String(read[read.index(after: read.firstIndex(of: "\n")!)...])
        XCTAssertLessThanOrEqual(body.utf16.count, SessionController.MAX_BODY_CHARS)
        XCTAssertTrue(body.hasPrefix("… ("))
        XCTAssertTrue(body.contains("earlier lines omitted"))
        XCTAssertTrue(body.hasSuffix("59 " + wide))
    }

    // MARK: - send / keys

    func testSendPastesThenPressesEnterAfterTheDelay() {
        shell("mhm-a").show("$ ")
        XCTAssertEqual("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"echo hi\\nworld\"}"))
        XCTAssertEqual([FakeDaemon.Input("mhm-a", "echo hi\nworld", true, nil),
                        FakeDaemon.Input("mhm-a", nil, false, ["Enter"])], inputsTo("mhm-a"))
        XCTAssertEqual([0.4], sleeps)

        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"draft\",\"enter\":false}")
        XCTAssertEqual(FakeDaemon.Input("mhm-a", "draft", true, nil), inputsTo("mhm-a").last)
    }

    func testSendAndKillRefuseTheCallersOwnSession() {
        shell("mhm-me").show("$ ")
        XCTAssertTrue(error("mhm-me", "send", "{\"session\":\"mhm-me\",\"text\":\"x\"}").contains("your own session"))
        XCTAssertTrue(error("mhm-me", "kill", "{\"session\":\"mhm-me\"}").contains("your own session"))
        XCTAssertTrue(daemon.inputs.isEmpty)
        XCTAssertTrue(spawner.killed.isEmpty)
    }

    func testKeysPressesWaitsForQuietSinceTheInputAndReturnsTheWholeScreen() {
        let s = shell("mhm-a").show("Pick one\n▶ 1. Yes\n  2. No\n")
        let before = s.outputBytes
        ok("mhm-me", "read", "{\"session\":\"mhm-a\"}")
        let screen = ok("mhm-me", "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Down\",\"Enter\"]}")
        XCTAssertEqual([FakeDaemon.Input("mhm-a", nil, false, ["Down", "Enter"])], inputsTo("mhm-a"))
        XCTAssertEqual([FakeDaemon.Wait("mhm-a", before, 300, 3000)], daemon.waits)
        XCTAssertTrue(screen.contains("▶ 1. Yes"), "whole screen even though nothing changed: " + screen)
        // and it counts as seen
        XCTAssertTrue(ok("mhm-me", "read", "{\"session\":\"mhm-a\"}").hasSuffix("unchanged"))
    }

    func testKeysReportsBadKeyNames() {
        shell("mhm-a").show("$ ")
        XCTAssertTrue(error(nil, "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Bogus\"]}").contains("unknown key: Bogus"))
        XCTAssertTrue(error(nil, "keys", "{\"session\":\"mhm-a\",\"keys\":[]}").contains("keys is required"))
    }

    // MARK: - notify

    func testNotifyNeedsACaller() {
        shell("mhm-a").show("$ ")
        XCTAssertTrue(error(nil, "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}").contains("only works from a session"))
    }

    func testFinishedOnASessionThatIsNotWorkingRegistersNothing() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("$ ")
        XCTAssertEqual("mhm-a is already IDLE (not working); nothing registered",
                       ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}"))
        XCTAssertFalse(controller.hasPending())
    }

    func testFinishedIsHeldWhileTheCallerWorksThenTypedIntoIt() {
        let me = agent("mhm-me", "thinking 0")
        let target = shell("mhm-a").show("building 0")
        XCTAssertEqual("will notify mhm-me when mhm-a finished",
                       ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}"))

        // the target goes quiet and turns IDLE while the caller is still busy
        for i in 1...7 {
            clock.advance(1)
            me.show("thinking \(i)")
            tick()
        }
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "held while the caller works")
        XCTAssertTrue(controller.hasPending())

        // the caller ends its turn: once it is quiet at its prompt the notice is typed in
        me.show(Self.CLAUDE_IDLE)
        ticks(7)
        XCTAssertEqual([FakeDaemon.Input("mhm-me", "[micro-harness-manager] mhm-a finished (IDLE)" + Self.NOTICE_TAIL, true, nil),
                        FakeDaemon.Input("mhm-me", nil, false, ["Enter"])], inputsTo("mhm-me"))
        XCTAssertTrue(inputsTo("mhm-a").isEmpty, "nothing is ever typed into the target")
        XCTAssertFalse(controller.hasPending(), "one-shot")
        XCTAssertEqual("building 0", target.text)
    }

    func testExitedAndAnyChangeFire() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("$ ")
        let b = shell("mhm-b").show("$ ")
        XCTAssertEqual("will notify mhm-me when mhm-a exited",
                       ok("mhm-me", "notify", "{\"sessions\":[\"mhm-a\"],\"on\":\"exited\"}"))
        ok("mhm-me", "notify", "{\"session\":\"mhm-b\",\"on\":\"any-change\"}")

        tick()
        XCTAssertTrue(inputsTo("mhm-me").isEmpty)

        try? daemon.kill("mhm-a")
        b.show("$ make\nok")
        tick()
        XCTAssertEqual("[micro-harness-manager] mhm-a exited (EXITED)" + Self.NOTICE_TAIL + "\n"
                       + "[micro-harness-manager] mhm-b changed (WORKING)" + Self.NOTICE_TAIL,
                       inputsTo("mhm-me").first?.text, "fired notices for one caller go in one paste")
        XCTAssertFalse(controller.hasPending())
    }

    func testUndeliverableNotificationsAreDroppedAfterThirtyMinutes() {
        let me = agent("mhm-me", "busy 0")
        shell("mhm-a").show("$ ")
        daemon.quietProbe = false
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        try? daemon.kill("mhm-a")
        for i in 1...32 {
            clock.advance(60)
            me.show("busy \(i)")
            tick()
        }
        XCTAssertTrue(inputsTo("mhm-me").isEmpty)
        XCTAssertFalse(controller.hasPending())
    }

    func testNotificationsForAGoneCallerAreDropped() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}")
        try? daemon.kill("mhm-me")
        tick()
        XCTAssertFalse(controller.hasPending())
    }

    // MARK: - spawn / kill

    func testSpawnLaunchesThroughTheSpawnerAndTypesThePromptOnceReady() {
        shell("mhm-me").show("$ ")
        let reply = ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\","
                       + "\"name\":\"Helper\",\"prompt\":\"ls -la\"}")
        XCTAssertEqual("mhm-new-1 started (shell in \(dir.path)); the prompt will be typed in once it is ready at its prompt",
                       reply)
        let request = spawner.requests[0]
        XCTAssertEqual(.shell, request.harness)
        XCTAssertEqual(dir.path, request.project.path)
        XCTAssertEqual("Helper", request.displayName)
        XCTAssertEqual("mhm-me", request.labels[SessionController.LABEL_SPAWNED_BY])

        tick() // first look: output still changing
        XCTAssertTrue(inputsTo("mhm-new-1").isEmpty)
        clock.advance(6)
        tick()
        XCTAssertEqual([FakeDaemon.Input("mhm-new-1", "ls -la", true, nil),
                        FakeDaemon.Input("mhm-new-1", nil, false, ["Enter"])], inputsTo("mhm-new-1"))
        XCTAssertFalse(controller.hasPending())
    }

    func testASpawnThatNeverGetsReadyTellsTheRequesterInsteadOfTyping() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        spawner.harnessLabel = "claude-code" // its shell stays in front: claude never started
        ok("mhm-me", "spawn", "{\"harness\":\"claude-code\",\"project\":\"~\",\"prompt\":\"hi\"}")
        for _ in 0..<13 {
            clock.advance(10)
            tick()
        }
        XCTAssertTrue(inputsTo("mhm-new-1").isEmpty)
        XCTAssertTrue(inputsTo("mhm-me").first?.text?
            .hasPrefix("[micro-harness-manager] mhm-new-1 did not reach its prompt within 120 s") ?? false,
                      "\(inputsTo("mhm-me"))")
    }

    func testSpawnValidatesHarnessAndProject() {
        XCTAssertTrue(error(nil, "spawn", "{\"harness\":\"emacs\",\"project\":\"/\"}").contains("unknown harness"))
        XCTAssertTrue(error(nil, "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)/missing\"}")
            .contains("not an existing directory"))
        XCTAssertTrue(error(nil, "spawn", "{\"harness\":\"shell\",\"project\":\"rel/path\"}").contains("absolute"))
        XCTAssertTrue(spawner.requests.isEmpty)
    }

    func testKillEndsAnotherSession() {
        shell("mhm-a").show("$ ")
        XCTAssertEqual("killed mhm-a", ok("mhm-me", "kill", "{\"session\":\"mhm-a\"}"))
        XCTAssertEqual(["mhm-a"], spawner.killed)
    }

    // MARK: - old daemon

    func testAnOldDaemonIsReadAsPlainTextAndAnUnknownCounterNeverMeansUnchanged() {
        daemon.old = true
        let s = shell("mhm-a").show("line 1\n▶ choice\n$ ▮\n")
        let first = ok(nil, "read", "{\"session\":\"mhm-a\"}")
        XCTAssertTrue(textLines(first)[0].hasSuffix(" " + SessionController.OLD_DAEMON_NOTE), first)
        XCTAssertFalse(first.contains("▮"), first)
        XCTAssertFalse(first.contains("▶"), first)
        let refused = daemon.unsupportedCalls // annotated capture and the quiet probe, once each
        XCTAssertEqual(2, refused)

        s.show("line 1\nchoice\n$ ls▮\n") // the old daemon reports outputBytes -1 both times
        let second = ok(nil, "read", "{\"session\":\"mhm-a\"}")
        XCTAssertFalse(second.hasSuffix("unchanged"), second)
        XCTAssertTrue(second.hasSuffix("$ ls"), second)
        XCTAssertTrue(ok(nil, "read", "{\"session\":\"mhm-a\"}").hasSuffix(" · unchanged"), "same text")
        XCTAssertEqual(refused, daemon.unsupportedCalls, "remembered: never asked again")
    }

    func testSendOnAnOldDaemonFallsBackToSendKeysAndRefusesMultiLineText() {
        daemon.old = true
        shell("mhm-a").show("$ ")
        XCTAssertEqual("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"echo hi\"}"))
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"draft\",\"enter\":false}")
        XCTAssertEqual([FakeDaemon.SendKeys("mhm-a", "echo hi", true), FakeDaemon.SendKeys("mhm-a", "draft", false)],
                       daemon.sentKeys)
        XCTAssertTrue(sleeps.isEmpty, "the server pauses before Enter itself")

        let refused = error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\\ntwo\"}")
        XCTAssertTrue(refused.contains("predates pasting") && refused.contains("one line at a time"), refused)
        XCTAssertTrue(refused.contains("(pid 100)"), refused)
        XCTAssertEqual(2, daemon.sentKeys.count, "nothing typed")
        XCTAssertTrue(daemon.inputs.isEmpty)
    }

    func testKeysOnAnOldDaemonExplainsWhyAndWhenItGoesAway() {
        daemon.old = true
        daemon.pid = 91806
        shell("mhm-a").show("$ ")
        let expected = "keys needs a newer daemon; the running one (pid 91806) predates it. It is replaced "
            + "automatically once every session has ended and a new one starts."
        XCTAssertEqual(expected, error(nil, "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Enter\"]}"))
        XCTAssertEqual(expected, error(nil, "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Enter\"]}"))
        XCTAssertTrue(daemon.sentKeys.isEmpty)
    }

    func testANewDaemonIsUsedFullyOnceThePidChanges() {
        daemon.old = true
        shell("mhm-a").show("$ ")
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"x\"}")
        XCTAssertEqual(1, daemon.sentKeys.count)

        daemon.old = false
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"x\"}")
        XCTAssertEqual(2, daemon.sentKeys.count, "same pid: still taken for the old daemon")

        daemon.pid = 200
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"x\"}")
        XCTAssertEqual(2, daemon.sentKeys.count)
        XCTAssertEqual([FakeDaemon.Input("mhm-a", "x", true, nil), FakeDaemon.Input("mhm-a", nil, false, ["Enter"])],
                       inputsTo("mhm-a"))
        XCTAssertFalse(ok(nil, "read", "{\"session\":\"mhm-a\"}").contains(SessionController.OLD_DAEMON_NOTE))
    }

    func testAnOldDaemonGetsSpawnPromptsAndNotificationsThroughSendKeys() {
        daemon.old = true // no labels either: the registry names the caller's harness
        agent("mhm-me", Self.CLAUDE_IDLE)
        register("mhm-me", .claudeCode, nil)
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"make\"}")
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"one\\ntwo\"}")
        ticks(14) // no quiet probe on an old daemon: the caller needs its own 5 s look
        XCTAssertEqual([FakeDaemon.SendKeys("mhm-new-1", "make", true)],
                       daemon.sentKeys.filter { $0.session == "mhm-new-1" })
        XCTAssertFalse(daemon.sentKeys.contains { $0.session == "mhm-new-2" })
        let toMe = daemon.sentKeys.filter { $0.session == "mhm-me" }
        XCTAssertEqual(1, toMe.count, "the multi-line prompt is refused and its requester told: \(toMe)")
        XCTAssertTrue(toMe.first?.text.hasPrefix("[micro-harness-manager] mhm-new-2 could not be given its prompt: "
            + "the running daemon") ?? false, "\(toMe)")
        XCTAssertTrue(toMe.first?.enter ?? false)
        XCTAssertFalse(controller.hasPending())
        XCTAssertTrue(daemon.inputs.isEmpty)
    }

    func testTheMonitorStopsAskingAnOldDaemonForAWatchAndResumesWithANewOne() throws {
        daemon.old = true
        controller = makeController(Self.fastTimings())
        let service = McpService(controller, "test")
        try service.start(0, "token")
        defer { service.stop() }
        awaitTrue { daemon.pings >= 5 } // ticking along, checking the daemon
        XCTAssertEqual(1, daemon.watchAttempts, "asked once per daemon")
        XCTAssertTrue(daemon.watches.isEmpty)

        daemon.old = false
        daemon.pid = 200
        awaitTrue { !daemon.watches.isEmpty }
    }

    // MARK: - delivery safety

    func testNotifyRefusesAPlainShellCaller() {
        shell("mhm-me").show("$ ")
        shell("mhm-a").show("building")
        let refused = error("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        XCTAssertTrue(refused.contains("plain shell session") && refused.contains("run as a command"), refused)
        XCTAssertFalse(controller.hasPending())
    }

    func testANotificationIsHeldWhileTheCallerWaitsForAnAnswerOrSitsAtAShell() {
        let me = agent("mhm-me", Self.CLAUDE_APPROVAL)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        try? daemon.kill("mhm-a")
        ticks(10)
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "never typed (and Enter pressed) into a permission dialog")

        me.foreground = "zsh" // claude exited: a shell prompt would run the line
        me.show("$ ")
        ticks(10)
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "never typed into a bare shell")

        me.foreground = "claude"
        me.show(Self.CLAUDE_IDLE)
        ticks(7)
        XCTAssertEqual("[micro-harness-manager] mhm-a exited (EXITED)" + Self.NOTICE_TAIL, inputsTo("mhm-me").first?.text)
    }

    func testFinishedAfterASpawnPromptWaitsUntilThePromptWasTypedAndWorkedOn() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"make\"}")
        XCTAssertEqual("will notify mhm-me when mhm-new-1 finished",
                       ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}"),
                       "a session about to be given its prompt counts as working")
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"needs-input\"}")

        ticks(7) // the shell settles at its prompt: the prompt goes in
        XCTAssertEqual(2, inputsTo("mhm-new-1").count)
        ticks(10) // typed, but nothing started yet
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "not finished before it even started")

        daemon.session("mhm-new-1")!.show("$ make\nbuilding…").foreground = "make"
        ticks(1)
        XCTAssertTrue(inputsTo("mhm-me").isEmpty)
        daemon.session("mhm-new-1")!.show("$ make\nbuilt\n$ ").foreground = "zsh"
        ticks(14) // the caller is first looked at once there is something to deliver
        XCTAssertEqual("[micro-harness-manager] mhm-new-1 finished (IDLE)" + Self.NOTICE_TAIL, inputsTo("mhm-me").first?.text)
        XCTAssertTrue(controller.hasPending(), "needs-input is still armed")
    }

    func testATransientCaptureErrorIsNotTakenForAnExit() {
        daemon.quietProbe = true // the caller is long idle
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"ls\"}")
        daemon.captureFailures["mhm-a"] = 3
        daemon.captureFailures["mhm-new-1"] = 3
        ticks(3)
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "no spurious 'exited', no 'exited before its prompt'")
        ticks(7)
        XCTAssertEqual(2, inputsTo("mhm-new-1").count, "the prompt still goes in")
        XCTAssertTrue(inputsTo("mhm-me").isEmpty)

        try? daemon.kill("mhm-a")
        daemon.captureFailures["mhm-me"] = 2
        ticks(2)
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "held, not dropped, while the caller cannot be captured")
        ticks(1)
        XCTAssertEqual("[micro-harness-manager] mhm-a exited (EXITED)" + Self.NOTICE_TAIL, inputsTo("mhm-me").first?.text)
    }

    func testNotifyRegistersNothingWhenAnySessionIsBadAndRepeatingIsIdempotent() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        XCTAssertTrue(error("mhm-me", "notify", "{\"sessions\":[\"mhm-a\",\"mhm-typo\"],\"on\":\"exited\"}")
            .contains("no such session: mhm-typo"))
        XCTAssertTrue(error("mhm-me", "notify", "{\"sessions\":[\"mhm-a\",\"mhm-me\"],\"on\":\"exited\"}")
            .contains("not your own"))
        XCTAssertFalse(controller.hasPending(), "nothing registered by the failed calls")

        XCTAssertEqual("will notify mhm-me when mhm-a exited",
                       ok("mhm-me", "notify", "{\"sessions\":[\"mhm-a\",\"mhm-a\"],\"on\":\"exited\"}"))
        XCTAssertEqual("already registered: will notify mhm-me when mhm-a exited",
                       ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}"))
        try? daemon.kill("mhm-a")
        ticks(7)
        XCTAssertEqual("[micro-harness-manager] mhm-a exited (EXITED)" + Self.NOTICE_TAIL, inputsTo("mhm-me").first?.text,
                       "one notice, not two")
    }

    func testAFailedEnterIsRetriedAloneWithoutPastingAgain() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        try? daemon.kill("mhm-a")
        let enterFailures = Counter(1)
        daemon.failInput = { $0.keys != nil && enterFailures.takeOne() }
        ticks(7)
        XCTAssertEqual([FakeDaemon.Input("mhm-me", "[micro-harness-manager] mhm-a exited (EXITED)" + Self.NOTICE_TAIL, true, nil),
                        FakeDaemon.Input("mhm-me", nil, false, ["Enter"])], inputsTo("mhm-me"), "pasted once, Enter retried")
        XCTAssertFalse(controller.hasPending())
    }

    func testASpawnPromptsFailedEnterIsRetriedAlone() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        let enterFailures = Counter(1)
        daemon.failInput = { $0.keys != nil && enterFailures.takeOne() }
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"ls\"}")
        ticks(15)
        XCTAssertEqual([FakeDaemon.Input("mhm-new-1", "ls", true, nil), FakeDaemon.Input("mhm-new-1", nil, false, ["Enter"])],
                       inputsTo("mhm-new-1"))
        XCTAssertFalse(controller.hasPending())
    }

    func testADeliveryInFlightIsNotStartedTwice() {
        let queued = Queue()
        controller = makeController(SessionController.Timings.DEFAULT) { queued.add($0) }
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"ls\"}")
        try? daemon.kill("mhm-a")
        ticks(10)
        let tasks = queued.all
        XCTAssertEqual(2, tasks.count, "one notification delivery and one prompt delivery: \(tasks.count)")
        tasks.forEach { $0() }
        XCTAssertEqual(2, inputsTo("mhm-me").count)
        XCTAssertEqual(2, inputsTo("mhm-new-1").count)
        XCTAssertFalse(controller.hasPending())
    }

    func testSpawnRefusesADisplayNameAlreadyInUse() {
        shell("mhm-a").labels["display"] = "Helper"
        daemon.add("mhm-b").show("x")
        register("mhm-b", .shell, "Backend")
        XCTAssertEqual("name already in use by mhm-a; choose another",
                       error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"helper\"}"))
        XCTAssertEqual("name already in use by mhm-b; choose another",
                       error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"Backend\"}"))
        XCTAssertTrue(spawner.requests.isEmpty)
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"Fresh\"}")
    }

    func testANamedSpawnStartsTheFirstSessionWhenNoDaemonIsRunningYet() {
        daemon.down = true
        daemon.pid = -1
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"First\"}")
        XCTAssertEqual(1, spawner.requests.count, "the spawner is what starts the daemon")
    }

    func testAnyChangeIgnoresTheComposerButReadShowsIt() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        let c = agent("mhm-c", "Answer: 42\n❯ \n? for shortcuts\n")
        ok("mhm-me", "notify", "{\"session\":\"mhm-c\",\"on\":\"any-change\"}")
        c.show("Answer: 42\n❯ half-typed\n? for shortcuts\n")
        ticks(7)
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "composer-only changes do not fire any-change")
        XCTAssertTrue(controller.hasPending())
    }

    // MARK: - unreachable daemon

    func testAnUnreachableDaemonIsNeitherAnExitNorAMissedPrompt() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"ls\"}")

        daemon.down = true // list comes back empty, ping fails
        for _ in 0..<5 {
            clock.advance(60) // past the prompt deadline even
            tick()
        }
        daemon.down = false
        XCTAssertTrue(inputsTo("mhm-me").isEmpty, "no 'exited', no 'did not reach its prompt'")
        XCTAssertTrue(controller.hasPending())
        daemon.down = true
        let whileDown = error("mhm-me", "read", "{\"session\":\"mhm-a\"}")
        daemon.down = false
        XCTAssertEqual(String(SessionController.DAEMON_UNREACHABLE.prefix(20)), String(whileDown.prefix(20)))

        // the daemon dies between the list and the captures: still unknown, not gone
        daemon.afterList = { [unowned daemon = daemon!] in daemon.down = true }
        tick()
        daemon.afterList = {}
        daemon.down = false
        XCTAssertTrue(inputsTo("mhm-me").isEmpty)

        // once it answers again, a real exit still fires
        try? daemon.kill("mhm-a")
        ticks(7)
        XCTAssertTrue(inputsTo("mhm-me").first?.text?.hasPrefix("[micro-harness-manager] mhm-a exited (EXITED)") ?? false,
                      "\(inputsTo("mhm-me"))")
    }

    // MARK: - spawn prompt and notify

    /// Spawns a claude-code session with `prompt` and has it reach its idle prompt.
    @discardableResult
    private func spawnClaudeWithPrompt(_ prompt: String) -> FakeDaemon.FakeSession {
        spawner.harnessLabel = "claude-code"
        ok("mhm-me", "spawn", "{\"harness\":\"claude-code\",\"project\":\"\(dir.path)\",\"prompt\":"
           + CoreJSON.string(prompt).compact() + "}")
        let s = daemon.session("mhm-new-1")!
        s.foreground = "claude"
        s.show(Self.CLAUDE_IDLE)
        return s
    }

    func testFinishedAndNeedsInputAfterASpawnPromptFireWhenTheSessionAsksAQuestion() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        let s = spawnClaudeWithPrompt("do it")
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}")
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"needs-input\"}")
        ticks(7)
        XCTAssertEqual(2, inputsTo("mhm-new-1").count, "the prompt went in")

        daemon.quietProbe = false
        s.show(Self.CLAUDE_APPROVAL)
        ticks(30)
        let delivered = inputsTo("mhm-me").first?.text ?? ""
        XCTAssertTrue(delivered.contains("mhm-new-1 finished (WAITING_FOR_INPUT)"), delivered)
        XCTAssertTrue(delivered.contains("mhm-new-1 needs input (WAITING_FOR_INPUT)"), delivered)
        XCTAssertFalse(controller.hasPending())
    }

    func testFinishedAfterASpawnPromptFiresWhenTheHarnessFallsBackToAShell() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        let s = spawnClaudeWithPrompt("do it")
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}")
        ticks(7)
        XCTAssertEqual(2, inputsTo("mhm-new-1").count)

        s.foreground = "zsh" // claude quit straight away
        s.text = "$ "
        ticks(10)
        XCTAssertTrue(inputsTo("mhm-me").first?.text?.hasPrefix("[micro-harness-manager] mhm-new-1 finished (") ?? false,
                      "\(inputsTo("mhm-me"))")
        XCTAssertFalse(controller.hasPending())
    }

    func testARegistrationWaitingForASpawnPromptIsDroppedAfterThirtyMinutes() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        spawnClaudeWithPrompt("do it")
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}")
        ticks(7)
        XCTAssertEqual(2, inputsTo("mhm-new-1").count)
        // it never reacts: idle at its prompt, screen unchanged
        for _ in 0..<29 {
            clock.advance(60)
            tick()
        }
        XCTAssertTrue(controller.hasPending(), "still armed before the TTL")
        clock.advance(120)
        tick()
        XCTAssertFalse(controller.hasPending())
        XCTAssertTrue(inputsTo("mhm-me").isEmpty)
    }

    func testSpawnStripsTheDisplayNameAndChecksItStripped() {
        shell("mhm-a").labels["display"] = "Helper"
        XCTAssertEqual("name already in use by mhm-a; choose another",
                       error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"  helper \"}"))
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"  Fresh  \"}")
        XCTAssertEqual("Fresh", spawner.requests.first?.displayName)
    }

    func testConcurrentSpawnsCannotTakeTheSameDisplayName() {
        let inSpawn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        spawner.onSpawn = {
            inSpawn.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        let done = DispatchSemaphore(value: 0)
        let firstResult = Box<ToolResult>()
        let json = "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"Twin\"}"
        let controller = self.controller!
        Thread.detachNewThread {
            firstResult.value = controller.call("mhm-me", "spawn", try! CoreJSON.parse(json))
            done.signal()
        }
        XCTAssertEqual(.success, inSpawn.wait(timeout: .now() + 10))
        spawner.onSpawn = {}
        let refused = error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\" twin\"}")
        XCTAssertTrue(refused.contains("already in use"), refused)
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"Other\"}")
        release.signal()
        XCTAssertEqual(.success, done.wait(timeout: .now() + 10))
        XCTAssertEqual(false, firstResult.value?.isError)
        XCTAssertEqual(2, spawner.requests.count)
        // released once created: the name is now taken by the live session's label
        let names = spawner.requests.indices.map { "mhm-new-\($0 + 1)" }
        let first = spawner.requests.firstIndex { $0.displayName == "Twin" }!
        daemon.session(names[first])!.labels["display"] = "Twin"
        daemon.session(names[1 - first])!.labels["display"] = "Other"
        let taken = error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"twin\"}")
        XCTAssertTrue(taken.hasPrefix("name already in use by mhm-"), taken)
    }

    func testAFailedSpawnReleasesItsDisplayName() {
        spawner.onSpawn = { throw FakeError("boom") }
        XCTAssertTrue(error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"X\"}")
            .contains("boom"))
        spawner.onSpawn = {}
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"name\":\"X\"}")
    }

    // MARK: - an owed Enter

    func testAPastedSpawnPromptsEnterIsRetriedPastTheDeadlineAndWhateverTheSessionLooksLike() {
        agent("mhm-me", Self.CLAUDE_IDLE)
        let enterFailures = Counter(3)
        daemon.failInput = { $0.session == "mhm-new-1" && $0.keys != nil && enterFailures.takeOne() }
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"ls\"}")
        ticks(7)
        XCTAssertEqual([FakeDaemon.Input("mhm-new-1", "ls", true, nil)], inputsTo("mhm-new-1"))
        // now busy (not ready), and the 120 s deadline passes: the Enter is still owed
        daemon.session("mhm-new-1")!.show("busy").foreground = "make"
        clock.advance(200)
        tick()
        tick()
        tick()
        XCTAssertEqual([FakeDaemon.Input("mhm-new-1", "ls", true, nil), FakeDaemon.Input("mhm-new-1", nil, false, ["Enter"])],
                       inputsTo("mhm-new-1"))
        XCTAssertFalse(controller.hasPending(), "no 'not sent' notice either")
    }

    func testAnEnterThatKeepsFailingIsReportedAsPastedButNotSubmitted() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        daemon.failInput = { $0.session == "mhm-new-1" && $0.keys != nil }
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"ls\"}")
        ticks(7 + SessionController.MAX_ENTER_ATTEMPTS + 7)
        XCTAssertEqual([FakeDaemon.Input("mhm-new-1", "ls", true, nil)], inputsTo("mhm-new-1"))
        let notice = inputsTo("mhm-me").first?.text ?? ""
        XCTAssertTrue(notice.hasPrefix("[micro-harness-manager] mhm-new-1 had its prompt pasted but not submitted"), notice)
    }

    func testAPastedNotificationsEnterGoesInEvenOnceTheCallerIsBusyAndPastTheTtl() {
        let me = agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        try? daemon.kill("mhm-a")
        let enterFails = Box<Bool>()
        enterFails.value = true
        daemon.failInput = { $0.keys != nil && enterFails.value == true }
        ticks(7)
        XCTAssertEqual(1, inputsTo("mhm-me").count, "pasted, Enter failed")

        me.show(Self.CLAUDE_APPROVAL) // the caller is now asking something
        clock.advance(40 * 60)
        enterFails.value = false
        tick()
        XCTAssertEqual(FakeDaemon.Input("mhm-me", nil, false, ["Enter"]), inputsTo("mhm-me").last)
        XCTAssertFalse(controller.hasPending())
    }

    func testANotificationWhoseEnterKeepsFailingIsDroppedEventually() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        shell("mhm-a").show("building")
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}")
        try? daemon.kill("mhm-a")
        daemon.failInput = { $0.keys != nil }
        ticks(SessionController.MAX_ENTER_ATTEMPTS + 2)
        XCTAssertFalse(controller.hasPending())
        XCTAssertEqual(1, inputsTo("mhm-me").count, "pasted once, never pasted again")
    }

    // MARK: - multi-line pastes

    func testMultiLineSendNeedsBracketedPasteAndSaysSoWhenTheSessionLacksIt() {
        let s = shell("mhm-a").show("$ ")
        s.bracketedPaste = false
        XCTAssertEqual(SessionController.MULTI_LINE_REFUSED,
                       error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\\ntwo\"}"))
        XCTAssertTrue(inputsTo("mhm-a").isEmpty, "nothing written, Enter not pressed")
        XCTAssertEqual(1, daemon.bracketedRequired.count)

        XCTAssertEqual("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\"}"))
        XCTAssertEqual(1, daemon.bracketedRequired.count, "a single line needs no bracketed paste")
        XCTAssertEqual(2, inputsTo("mhm-a").count)

        s.bracketedPaste = true
        XCTAssertEqual("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\\ntwo\"}"))
        XCTAssertEqual(FakeDaemon.Input("mhm-a", "one\ntwo", true, nil), inputsTo("mhm-a")[2])
    }

    func testControlCharactersOnOneLineAlsoNeedBracketedPaste() {
        let s = shell("mhm-a").show("$ ")
        s.bracketedPaste = false
        XCTAssertEqual(SessionController.MULTI_LINE_REFUSED,
                       error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"see \\u001b[31merror\"}"))
        XCTAssertEqual(SessionController.MULTI_LINE_REFUSED,
                       error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"stop\\u0003\"}"))
        XCTAssertTrue(inputsTo("mhm-a").isEmpty, "nothing written")
        XCTAssertEqual("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"a\\tb\"}"))
        XCTAssertEqual(2, daemon.bracketedRequired.count, "a tab is text, not a key")
    }

    func testAMultiLineSpawnPromptTheHarnessCannotTakeIsNotTypedAndTheRequesterIsTold() {
        daemon.quietProbe = true
        agent("mhm-me", Self.CLAUDE_IDLE)
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"\(dir.path)\",\"prompt\":\"one\\ntwo\"}")
        daemon.session("mhm-new-1")!.bracketedPaste = false
        ticks(14)
        XCTAssertTrue(inputsTo("mhm-new-1").isEmpty)
        let notice = inputsTo("mhm-me").first?.text ?? ""
        XCTAssertTrue(notice.hasPrefix("[micro-harness-manager] mhm-new-1 could not be given its prompt: "
            + SessionController.MULTI_LINE_REFUSED), notice)
        XCTAssertFalse(controller.hasPending())
    }

    // MARK: - monitor

    func testMonitorReconnectsTheWatchWithBackoffAndStopsWithTheMcpService() throws {
        daemon.watchFailures = 2
        controller = makeController(Self.fastTimings())
        let service = McpService(controller, "test")
        try service.start(0, "token")
        XCTAssertTrue(controller.monitorRunning())
        awaitTrue { !daemon.watches.isEmpty }
        XCTAssertEqual(3, daemon.watchAttempts)

        // the daemon restarts: the stream ends and is opened again
        daemon.watches[0].close()
        awaitTrue { daemon.watches.count == 2 }
        service.stop()
        XCTAssertFalse(controller.monitorRunning())
        XCTAssertFalse(daemon.watches.last!.isOpen, "stopping closes the stream")
    }

    // MARK: - fakes

    final class FakeSpawner: SessionSpawner, @unchecked Sendable {
        private let daemon: FakeDaemon
        private let lock = NSLock()
        private var _requests: [SpawnRequest] = []
        private var _killed: [String] = []
        private var _resumed: [String] = []
        var harnessLabel: String?
        /// Runs at the start of every spawn, e.g. to hold one in flight.
        @Atomic var onSpawn: () throws -> Void = {}

        init(_ daemon: FakeDaemon) {
            self.daemon = daemon
        }

        var requests: [SpawnRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        var killed: [String] { lock.lock(); defer { lock.unlock() }; return _killed }
        var resumed: [String] { lock.lock(); defer { lock.unlock() }; return _resumed }

        func resume(_ entry: SessionEntry) throws {
            lock.lock()
            _resumed.append(entry.sessionName)
            lock.unlock()
            daemon.add(entry.sessionName).show("$ ")
        }

        func spawn(_ request: SpawnRequest) throws -> String {
            try onSpawn()
            lock.lock()
            _requests.append(request)
            let name = "mhm-new-\(_requests.count)"
            lock.unlock()
            let s = daemon.add(name)
            s.labels["harness"] = harnessLabel ?? request.harness.id
            s.show("$ ")
            return name
        }

        func kill(_ session: String) throws {
            lock.lock()
            _killed.append(session)
            lock.unlock()
            try daemon.kill(session)
        }
    }
}

/// `AtomicInteger.getAndDecrement() > 0`.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }

    func takeOne() -> Bool {
        lock.lock(); defer { lock.unlock() }
        value -= 1
        return value >= 0
    }
}

/// A value shared with another thread.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Deliveries held for the test to run.
final class Queue: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [() -> Void] = []
    func add(_ task: @escaping () -> Void) {
        lock.lock(); tasks.append(task); lock.unlock()
    }
    var all: [() -> Void] { lock.lock(); defer { lock.unlock() }; return tasks }
}
