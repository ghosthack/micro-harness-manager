import XCTest
@testable import MicrohmMux

/// Pure logic of the session layer: the foreground rules, the shell command, probes'
/// parsers (ports of `ForegroundProbeTest`, `ShellCommandTest`, `CwdProbeTest`), and the
/// CLI's pure parts (`SizeAnnouncementFilterTest`, `Args`).
final class SessionUnitTests: XCTestCase {

    private typealias Foreground = ForegroundProbe.Foreground

    private struct Node: ForegroundProbe.ProcessNode {
        let pid: Int64
        let command: String
        var isAlive = true
        var startTime: TimeInterval = 0
        var kids: [Node] = []
        var children: [ForegroundProbe.ProcessNode] { kids }
    }

    func testShellAloneReportsTheShell() {
        XCTAssertEqual(Foreground(pid: 1, command: "zsh"), ForegroundProbe.walk(Node(pid: 1, command: "/bin/zsh")))
    }

    func testHarnessIsReportedNotItsToolOrMcpChildren() {
        let harness = Node(pid: 2, command: "/usr/local/bin/node", startTime: 1,
                           kids: [Node(pid: 3, command: "/usr/bin/git", startTime: 5),
                                  Node(pid: 4, command: "/usr/local/bin/mcp-server", startTime: 6)])
        XCTAssertEqual(Foreground(pid: 2, command: "node"),
                       ForegroundProbe.walk(Node(pid: 1, command: "-zsh", kids: [harness])))
    }

    func testNewestLiveChildWinsAndUnreadableNamesAreSkipped() {
        let old = Node(pid: 2, command: "vim", startTime: 1)
        let new = Node(pid: 3, command: "less", startTime: 2)
        let dead = Node(pid: 4, command: "top", isAlive: false, startTime: 3)
        XCTAssertEqual(Foreground(pid: 3, command: "less"),
                       ForegroundProbe.walk(Node(pid: 1, command: "bash", kids: [old, new, dead])))
        let unreadable = Node(pid: 5, command: "", kids: [Node(pid: 6, command: "python3")])
        XCTAssertEqual(Foreground(pid: 6, command: "python3"),
                       ForegroundProbe.walk(Node(pid: 1, command: "bash", kids: [unreadable])))
        XCTAssertEqual(Foreground(pid: 1, command: "bash"),
                       ForegroundProbe.walk(Node(pid: 1, command: "bash", kids: [Node(pid: 7, command: "")])))
    }

    func testNormalizesNames() {
        XCTAssertEqual("zsh", ForegroundProbe.normalize("-zsh"))
        XCTAssertEqual("node", ForegroundProbe.normalize("/usr/local/bin/Node"))
        XCTAssertEqual("node", ForegroundProbe.normalize("C:\\nodejs\\Node.EXE"))
        XCTAssertEqual("python", ForegroundProbe.normalize("/opt/homebrew/bin/Python"))
        XCTAssertEqual("", ForegroundProbe.normalize(nil))
        XCTAssertEqual("", ForegroundProbe.normalize("  "))
    }

    func testPsRuleFindsTheForegroundGroupLeader() {
        let ps = """
              501   501   777 -zsh
              777   777   777 /usr/local/bin/node
              778   777   777 /usr/bin/git

            """
        XCTAssertEqual(Foreground(pid: 777, command: "node"), ForegroundProbe.parsePs(ps, 501))
    }

    func testPsRuleFallsBackToTheShellWhenTheLeaderIsGoneOrNoTty() {
        XCTAssertEqual(Foreground(pid: 501, command: "bash"),
                       ForegroundProbe.parsePs("  501   501   900 /bin/bash\n  902   900   900 /usr/bin/sort\n", 501))
        XCTAssertEqual(Foreground(pid: 501, command: "bash"),
                       ForegroundProbe.parsePs("  501   501     0 /bin/bash\n  502   501     0 /usr/bin/sleep\n", 501))
        XCTAssertEqual(Foreground(pid: 501, command: "bash"), ForegroundProbe.parsePs("  501   501   501 -bash\n", 501))
    }

    func testPsRuleKeepsSpacesInCommandPathsAndNeedsTheShellRow() {
        let ps = "  501   501   600 -zsh\n  600   600   600 /Applications/Foo Bar.app/Contents/MacOS/Foo Bar\n"
        XCTAssertEqual("foo bar", ForegroundProbe.parsePs(ps, 501)?.command)
        XCTAssertNil(ForegroundProbe.parsePs("  9   9   9 sh\n", 501))
        XCTAssertNil(ForegroundProbe.parsePs("", 501))
        XCTAssertNil(ForegroundProbe.parsePs("ps: 501: no such process\n", 501))
    }

    func testMemoReusesAQuietUnchangedForegroundOnly() {
        var now: UInt64 = 0
        var group: Int64 = 501
        var probes = 0
        let memo = ForegroundProbe.Memo(enabled: true, foregroundGroup: { group }, probe: { pid in
            defer { probes += 1 }
            return Foreground(pid: pid, command: "zsh\(probes)")
        }, clock: { now })
        let s: UInt64 = 1_000_000_000
        XCTAssertEqual("zsh0", memo.probe(501, 10).command)
        now = 5 * s
        XCTAssertEqual("zsh0", memo.probe(501, 10).command, "quiet and same group: reused")
        XCTAssertEqual("zsh1", memo.probe(501, 11).command, "output since: re-probed")
        now += s / 2
        XCTAssertEqual("zsh1", memo.probe(501, 12).command, "younger than FRESH: reused despite output")
        group = 777
        XCTAssertEqual("zsh2", memo.probe(501, 12).command, "new foreground group: re-probed")
        now += 31 * s
        XCTAssertEqual("zsh3", memo.probe(501, 12).command, "older than IDLE: re-probed")
        group = -1
        XCTAssertEqual("zsh4", memo.probe(501, 12).command, "unknown group: never cached")
        XCTAssertEqual("zsh5", memo.probe(501, 12).command)

        let off = ForegroundProbe.Memo(enabled: false, foregroundGroup: { 501 }, probe: { pid in
            defer { probes += 1 }
            return Foreground(pid: pid, command: "p\(probes)")
        }, clock: { 0 })
        XCTAssertEqual("p6", off.probe(501, 0).command)
        XCTAssertEqual("p7", off.probe(501, 0).command)
    }

    func testShellCommandUsesTheLoginShellAndTheSessionEnvironment() {
        XCTAssertEqual(["/bin/zsh", "-l"], ShellCommand.build("s", nil, ["SHELL": "/bin/zsh"]).command)
        XCTAssertEqual(["/bin/sh", "-l"], ShellCommand.build("s", nil, ["SHELL": " "]).command)
        XCTAssertEqual(["/bin/sh", "-l"], ShellCommand.build("s", [], [:]).command)
        XCTAssertEqual(["/usr/bin/top", "-l", "1"], ShellCommand.build("s", ["/usr/bin/top", "-l", "1"], [:]).command)

        let env = ShellCommand.build("mhm-foo", nil, ["HOME": "/Users/x", "PATH": "/usr/bin"]).environment
        XCTAssertEqual("/Users/x", env["HOME"])
        XCTAssertEqual("xterm-256color", env["TERM"])
        XCTAssertEqual("truecolor", env["COLORTERM"])
        XCTAssertEqual("en_US.UTF-8", env["LANG"])
        XCTAssertEqual("mhm-foo", env["MICROHM_SESSION"])

        let kept = ShellCommand.build("s", nil, ["LANG": "de_DE.UTF-8", "TERM": "dumb"],
                                      ["TERM": "vt100", "MICROHM_SESSION": "x", "COLORTERM": "no", "EXTRA": "1"]).environment
        XCTAssertEqual("de_DE.UTF-8", kept["LANG"], "LANG is only defaulted")
        XCTAssertEqual("xterm-256color", kept["TERM"], "TERM is always ours")
        XCTAssertEqual("s", kept["MICROHM_SESSION"], "the session name is always ours")
        XCTAssertEqual("no", kept["COLORTERM"], "the caller may override COLORTERM")
        XCTAssertEqual("1", kept["EXTRA"])
    }

    func testALaunchingAgentsProcessMarkersAreNotInherited() {
        var inherited = ["PATH": "/usr/bin", "CLAUDE_CODE_USE_BEDROCK": "1"]
        for marker in ShellCommand.AGENT_PROCESS_MARKERS { inherited[marker] = "x" }
        let env = ShellCommand.build("s", nil, inherited).environment
        XCTAssertEqual("/usr/bin", env["PATH"])
        XCTAssertEqual("1", env["CLAUDE_CODE_USE_BEDROCK"], "a user's setting passes through")
        for marker in ShellCommand.AGENT_PROCESS_MARKERS {
            XCTAssertNil(env[marker], marker)
        }
    }

    func testCwdProbeParsesLsofAndAsksTheKernel() {
        XCTAssertEqual("/Users/x/My Dir", CwdProbe.parseLsof("p123\nfcwd\nn/Users/x/My Dir\n")?.path)
        XCTAssertNil(CwdProbe.parseLsof("p123\nftxt\nn/bin/zsh\n"))
        XCTAssertNil(CwdProbe.parseLsof(""))
        let mine = CwdProbe.cwdOf(Int64(getpid()))
        XCTAssertEqual(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path,
                       mine?.resolvingSymlinksInPath().path)
    }

    func testPasteSafeStripsEveryEscAndC1Csi() {
        XCTAssertEqual("[201~x[200~", PtySession.pasteSafe("\u{1b}[201~x\u{9b}\u{1b}[200~"))
        XCTAssertEqual("[201[201~~", PtySession.pasteSafe("\u{1b}[201\u{1b}[201~~"))
        XCTAssertEqual("plain ✓", PtySession.pasteSafe("plain ✓"))
    }

    // MARK: CLI pieces

    private let ESC = "\u{1b}"

    private func filterPass(_ filter: SizeAnnouncementFilter, _ text: String) -> String {
        String(decoding: filter.filter(Array(text.utf8)), as: UTF8.self)
    }

    func testSizeAnnouncementIsReplacedByANoticeAndEverythingElsePasses() {
        var notices: [String] = []
        let filter = SizeAnnouncementFilter { notices.append("\($0)x\($1)") }
        XCTAssertEqual("beforeafter\(ESC)[31mred\(ESC)[0m",
                       filterPass(filter, "before\(ESC)[8;40;120tafter\(ESC)[31mred\(ESC)[0m"))
        XCTAssertEqual(["120x40"], notices)
    }

    func testSizeAnnouncementSplitAcrossReadsIsStillRecognised() {
        var notices: [String] = []
        let filter = SizeAnnouncementFilter { notices.append("\($0)x\($1)") }
        let out = filterPass(filter, "x\(ESC)[8;") + filterPass(filter, "2") + filterPass(filter, "4;80")
            + filterPass(filter, "ty")
        XCTAssertEqual("xy", out)
        XCTAssertEqual(["80x24"], notices)
    }

    func testSizeAnnouncementLookalikesAreReleasedIntact() {
        var notices: [String] = []
        let filter = SizeAnnouncementFilter { notices.append("\($0)x\($1)") }
        let other = "\(ESC)[8;24;80z\(ESC)[8t\(ESC)[9;1;1t\(ESC)\(ESC)[8;1;1t"
        XCTAssertEqual("\(ESC)[8;24;80z\(ESC)[8t\(ESC)[9;1;1t\(ESC)", filterPass(filter, other))
        XCTAssertEqual(["1x1"], notices, "the ESC ESC case: the second ESC opens a real announcement")
    }

    func testSizeAnnouncementTrailingPartialIsHeldThenFlushed() {
        var notices: [String] = []
        let filter = SizeAnnouncementFilter { notices.append("\($0)x\($1)") }
        XCTAssertEqual("abc", filterPass(filter, "abc\(ESC)[8;1"))
        XCTAssertEqual("\(ESC)[8;1", String(decoding: filter.flush(), as: UTF8.self))
        XCTAssertEqual([], notices)
    }

    func testArgsGrammar() throws {
        let args = try Args.parse(["new", "--dir=/tmp", "--size", "120x40", "--json", "--", "x"],
                                  ["--dir", "--size"], ["--json"])
        XCTAssertEqual(["new", "--", "x"], args.positionals)
        XCTAssertEqual("/tmp", args.value("--dir"))
        XCTAssertTrue(args.flag("--json"))
        XCTAssertTrue(try Args.size("120x40") == (120, 40))
        XCTAssertThrowsError(try Args.parse(["--bogus"], [], []))
        XCTAssertThrowsError(try Args.parse(["--json=1"], [], ["--json"]))
        XCTAssertThrowsError(try Args.parse(["--dir"], ["--dir"], []))
        XCTAssertThrowsError(try Args.size("0x10"))
        XCTAssertThrowsError(try Args.size("wide"))
        XCTAssertThrowsError(try Args.parse(["--quiet", "soon"], ["--quiet"], []).longValue("--quiet", 0))
        let labels = try Cli.parseLabels(["a=1", "b=", "c=x=y"])
        XCTAssertEqual(.some("1"), labels["a"])
        XCTAssertEqual(.some(nil), labels["b"])
        XCTAssertEqual(.some("x=y"), labels["c"])
        XCTAssertThrowsError(try Cli.parseLabels(["=v"]))
    }

    func testInboundPipeHandsOverBufferedBytesThenTheFailureThenTheEnd() throws {
        let pipe = InboundPipe(capacity: 8)
        XCTAssertTrue(pipe.append([1, 2, 3]))
        XCTAssertTrue(pipe.append([4, 5]))
        pipe.fail("dropped")
        var buffer = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(4, try buffer.withUnsafeMutableBytes { try pipe.read($0) })
        XCTAssertEqual([1, 2, 3, 4], buffer)
        XCTAssertEqual(1, try buffer.withUnsafeMutableBytes { try pipe.read($0) })
        XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try pipe.read($0) })
        XCTAssertEqual(-1, try buffer.withUnsafeMutableBytes { try pipe.read($0) })
        XCTAssertFalse(pipe.append([9]), "an ended pipe takes nothing")
    }

    func testInboundPipeCloseWakesABlockedReader() throws {
        let pipe = InboundPipe(capacity: 8)
        let done = expectation(description: "reader returned")
        Thread {
            var buffer = [UInt8](repeating: 0, count: 4)
            let n = try? buffer.withUnsafeMutableBytes { try pipe.read($0) }
            XCTAssertEqual(-1, n)
            done.fulfill()
        }.start()
        Thread.sleep(forTimeInterval: 0.1)
        pipe.close()
        wait(for: [done], timeout: 5)
    }
}
