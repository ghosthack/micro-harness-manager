import Foundation
import XCTest
@testable import MicrohmCore

final class SessionShellTests: XCTestCase {

    /// A Unix machine with zsh and bash in /bin and fish from Homebrew (not on PATH).
    private func unix() -> SessionShell {
        let installed: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", "/usr/bin/xonsh"]
        return SessionShell(windows: false, env: ["PATH": "/usr/bin:/bin"], executable: { installed.contains($0) },
                            defaultProgram: { "/bin/zsh" })
    }

    func testTheDefaultLeavesTheChoiceToTheDaemon() {
        XCTAssertNil(unix().command(""))
        XCTAssertNil(unix().command(nil))
    }

    func testNamesResolveToLoginShellsWherePathOrTheUsualPlacesHaveThem() {
        XCTAssertEqual(["/bin/bash", "-l"], unix().command("bash"))
        XCTAssertEqual(["/opt/homebrew/bin/fish", "-l"], unix().command("fish"),
                       "an app started from the Dock has a short PATH; Homebrew's directory is searched too")
        XCTAssertEqual(["/usr/bin/xonsh", "-l"], unix().command("/usr/bin/xonsh"))
    }

    func testAShellThatIsNotThereFallsBackToTheDefaultRatherThanFailingToStart() {
        XCTAssertNil(unix().command("tcsh"))
        XCTAssertNil(unix().command("/nope/zsh"))
        XCTAssertTrue(unix().describe("tcsh").hasSuffix("(not found; your default is used)"))
    }

    func testOnlyInstalledShellsAreOffered() {
        XCTAssertEqual(["zsh", "bash", "fish", "sh"], unix().installedNames())
    }

    func testOneStepRunsTheAgentInsideTheShellThenLeavesALoginShell() {
        XCTAssertEqual(["/bin/bash", "-l", "-i", "-c", "claude --resume x; exec '/bin/bash' -l"],
                       unix().oneStep("bash", "claude --resume x"))
        XCTAssertEqual(["/opt/homebrew/bin/fish", "-l", "-i", "-c", "codex; exec '/opt/homebrew/bin/fish' -l"],
                       unix().oneStep("fish", "codex"))
        XCTAssertEqual(["/bin/zsh", "-l", "-i", "-c", "codex; exec '/bin/zsh' -l"], unix().oneStep("", "codex"),
                       "the default shell, when it can")
    }

    func testShellsThatCannotDoItKeepTypingTheCommand() {
        XCTAssertNil(unix().oneStep("/usr/bin/xonsh", "claude"), "unknown -c/exec semantics")
        XCTAssertNil(unix().oneStep("bash", "  "), "a plain shell session has nothing to run")
        let windows = SessionShell(windows: true, env: ["Path": "C:\\Windows\\System32"], executable: { _ in true })
        XCTAssertNil(windows.oneStep("pwsh", "claude"))
    }

    func testWellKnownShellsReadAsTheirNameAndOthersAsTheirPath() {
        XCTAssertEqual("zsh", unix().displayName("/bin/zsh"))
        XCTAssertEqual("fish", unix().displayName("/opt/homebrew/bin/fish"))
        XCTAssertEqual("/usr/bin/xonsh", unix().displayName("/usr/bin/xonsh"))
        XCTAssertEqual("zsh (your default)", unix().describe(""))
    }

    func testQuotingSurvivesQuotesInThePath() {
        XCTAssertEqual("'/Users/o'\\''brien/bin/zsh'", SessionShell.quote("/Users/o'brien/bin/zsh"))
    }

    func testWindowsShellsGetFriendlyNamesAndNoLoginFlag() {
        let windows = SessionShell(windows: true, env: ["Path": "C:\\Program Files\\PowerShell\\7"],
                                   executable: { $0.hasSuffix("pwsh.exe") })
        XCTAssertEqual("PowerShell 7", windows.displayName("pwsh"))
        XCTAssertEqual("Command Prompt", windows.displayName("C:\\Windows\\System32\\cmd.exe"))
        XCTAssertEqual(1, windows.command("pwsh")?.count)
        XCTAssertTrue(windows.command("pwsh")?.first?.hasSuffix("pwsh.exe") ?? false)
    }
}

final class SessionEventsTests: XCTestCase {

    func testKillFiresKilledListenersThenAChangeAndRemovingAListenerStopsIt() {
        let events = SessionEvents()
        var seen: [String] = []
        let changed = events.addSessionsChangedListener { seen.append("changed \($0 ?? "null")") }
        events.addSessionKilledListener { seen.append("killed " + $0) }

        events.fireSessionsChanged("mhm-new")
        events.fireSessionKilled("mhm-old")
        events.removeSessionsChangedListener(changed)
        events.fireSessionsChanged(nil)

        XCTAssertEqual(["changed mhm-new", "killed mhm-old", "changed null"], seen)
    }

    func testRunEndedListenersRunFirstThenAChange() {
        let events = SessionEvents()
        var seen: [String] = []
        events.addSessionsChangedListener { seen.append("changed \($0 ?? "null")") }
        let token = events.addSessionRunEndedListener { seen.append("ended " + $0) }
        events.fireSessionRunEnded("mhm-a")
        events.removeSessionRunEndedListener(token)
        events.fireSessionRunEnded("mhm-b")
        XCTAssertEqual(["ended mhm-a", "changed null", "changed null"], seen)
    }

    func testAListenerMayRemoveItselfWhileFiring() {
        let events = SessionEvents()
        var token: SessionEvents.Token?
        var calls = 0
        token = events.addSessionKilledListener { _ in
            calls += 1
            events.removeSessionKilledListener(token!)
        }
        events.fireSessionKilled("x")
        events.fireSessionKilled("y")
        XCTAssertEqual(1, calls)
    }
}
