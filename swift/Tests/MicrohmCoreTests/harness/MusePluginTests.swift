import Foundation
import XCTest
@testable import MicrohmCore





final class MusePluginTests: XCTestCase {
    private let plugin = MusePlugin()
    private let ID = "01a138c8-10c5-7d81-93a7-f964e2854b9e"

    private func screen(_ text: String) -> Screen {
        Screen(text, false, epoch, "muse-bin-1.4.7-")
    }

    func testBootstrapKeepsMuseDefaultsAndRecognizesTheNativeLauncher() {
        XCTAssertEqual("muse", plugin.launchCommand())
        XCTAssertEqual(Optional("muse resume " + ID), plugin.resumeCommand(ID))
        XCTAssertEqual(Optional("muse resume 'a session name'"), plugin.resumeCommand("a session name"))
        XCTAssertEqual(Optional("/quit"), plugin.quitCommand())
        XCTAssertTrue(plugin.ownsProcess("muse-bin-1.4.7-"))
        XCTAssertTrue(plugin.ownsProcess("muse-bin-1.4.7-R6101.1"))
        XCTAssertTrue(plugin.ownsProcess("muse"))
        XCTAssertFalse(plugin.ownsProcess("zsh"))
        XCTAssertFalse(plugin.ownsProcess("node"))
    }

    func testExtractsOnlyTheGroundedExitReceipt() {
        XCTAssertEqual(Optional(ID), plugin.harnessSessionIdFromExit(screen(
                "◆ echo: Harness Manager echo test\n\nTo continue this session, run muse resume " + ID + "\nsample@macbookpro empty %")))
        XCTAssertNil( plugin.harnessSessionIdFromExit(screen(
                "◆ To continue this session, run muse resume " + ID)))
        XCTAssertNil( plugin.harnessSessionIdFromExit(screen("Muse Code 1.4.7")))
    }

    func testTrustAndLoginWaitForTheUser() {
        XCTAssertEqual(SessionState.waitingForInput, plugin.classifyQuiescent(screen("""
            Do you trust this workspace?
            Workspace: /Users/sample/Projects/muse-untrusted.demo01
            ⟩ 1  Trust and continue
              2  Quit
            Use Up/Down or 1/2, then Enter. Esc quits.

            """), 5)!.state)
        XCTAssertEqual(SessionState.waitingForInput, plugin.classifyQuiescent(screen("""
            Muse Code 1.4.7
            Log in with browser · Enter to choose
            Set an API key
            ↓↑ to select · Esc to quit

            """), 5)!.state)
    }

    func testRecognizesRunningAndCompletedEchoTurns() {
        let chrome = "\n── Voice input (alt(option)+v to start) ─────────\n❯\n────────────────\n  echo · ~/Projects/empty · Auto-review\n"
        XCTAssertEqual(SessionState.working, plugin.classifyQuiescent(screen(
                "❯ Harness Manager echo test\n◇ Thinking\n" + chrome), 5)!.state)
        XCTAssertEqual(SessionState.idle, plugin.classifyQuiescent(screen(
                "❯ Harness Manager echo test\n◆ echo: Harness Manager echo test\n" + chrome), 5)!.state)
        XCTAssertEqual(SessionState.waitingForInput, plugin.classifyQuiescent(screen(
                "◆ Which folder should I use?\n" + chrome), 5)!.state)
    }

    func testMasksComposerChromeWithoutDroppingTheConversation() {
        XCTAssertEqual("❯ test\n◆ echo: test", plugin.maskChrome("""
            ❯ test
            ◆ echo: test

            ── Voice input (alt(option)+v to start) ─────────
            ❯ ▮
            ────────────────
              echo · ~/Projects/empty · Auto-review

            """))
    }
}

