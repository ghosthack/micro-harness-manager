import Foundation
import XCTest
@testable import MicrohmCore

/// The graceful-close decision tree, driven through `FakeStatusSessionHost` with scripted
/// pane reactions (`onSendKeys`). Timeouts are tiny real durations — the timeout fixtures
/// wait them out for real, which at 50ms is cheaper than injecting a clock into what is
/// otherwise a sleep-and-poll loop.
final class GracefulCloserTests: XCTestCase {

    private let SESSION = "mhm-proj"

    private var host: FakeStatusSessionHost!
    private var closer: GracefulCloser!

    override func setUp() {
        host = FakeStatusSessionHost()
        closer = GracefulCloser(host, 0.001, 0.050, 0.050)
    }

    private func close(_ plugin: HarnessPlugin, _ lastPolled: SessionState?) throws -> GracefulCloser.Result {
        try closer.close(SESSION, plugin, lastPolled)
    }

    func testIdleHarnessQuitsThenShellExitsThenSessionIsClosed() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "❯ ", "claude")
        host.onSendKeys = { [unowned self] command in
            if command == SESSION + ": /exit" {
                host.screen(SESSION, """
                    Resume this session with:
                    claude --resume fd626959-efe0-414b-a3f5-9261602748ed
                    sample@host proj %

                    """, "zsh") // harness hands back the shell
            } else if command == SESSION + ": exit" {
                host.endSession(SESSION)
            }
        }
        let result = try close(ClaudeCodePlugin(), .idle)
        XCTAssertEqual(GracefulCloser.Outcome.closed, result.outcome)
        XCTAssertEqual("fd626959-efe0-414b-a3f5-9261602748ed", result.harnessSessionId)
        XCTAssertEqual([SESSION + ": /exit", SESSION + ": exit"], host.sentCommands)
    }

    func testCodexExitReceiptSurvivesAShellExitTimeout() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "› Ask Codex to do anything", "codex")
        host.onSendKeys = { [unowned self] command in
            if command == SESSION + ": /quit" {
                host.screen(SESSION, """
                    To continue this session, run codex resume 0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f
                    sample@host proj %

                    """, "zsh")
            }
            // Deliberately ignore shell exit: metadata must not be tied to full closure.
        }

        let result = try close(CodexPlugin(), .idle)

        XCTAssertEqual(GracefulCloser.Outcome.exitTimeout, result.outcome)
        XCTAssertEqual("0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f", result.harnessSessionId)
    }

    func testCursorAgentQuitsAndReturnsItsResumeBreadcrumb() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "> ", "cursor-agent")
        host.onSendKeys = { [unowned self] command in
            if command == SESSION + ": /quit" {
                host.screen(SESSION, """
                    To resume this session: agent --resume=bc-abc123
                    sample@host proj %

                    """, "zsh")
            } else if command == SESSION + ": exit" {
                host.endSession(SESSION)
            }
        }

        let result = try close(CursorAgentPlugin(), .idle)

        XCTAssertEqual(GracefulCloser.Outcome.closed, result.outcome)
        XCTAssertEqual("bc-abc123", result.harnessSessionId)
        XCTAssertEqual([SESSION + ": /quit", SESSION + ": exit"], host.sentCommands)
    }

    /// The shell harness (and a harness that already died back to its shell) needs no
    /// quit stage — a bare prompt goes straight to `exit`.
    func testShellAtPromptSkipsTheQuitStage() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "sample@host proj %", "zsh")
        host.onSendKeys = { [unowned self] _ in host.endSession(SESSION) }
        let result = try close(ShellPlugin(), nil) // never-polled is fine at a prompt
        XCTAssertEqual(GracefulCloser.Outcome.closed, result.outcome)
        XCTAssertEqual([SESSION + ": exit"], host.sentCommands)
    }

    func testWorkingSessionIsRefusedUntouched() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "esc to interrupt", "claude")
        let result = try close(ClaudeCodePlugin(), .working)
        XCTAssertEqual(GracefulCloser.Outcome.busyState, result.outcome)
        XCTAssertTrue(host.sentCommands.isEmpty, "a refused close must send nothing")
    }

    func testWaitingForInputIsRefusedUntouched() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "Do you want to make this edit?", "claude")
        XCTAssertEqual(GracefulCloser.Outcome.busyState, try close(ClaudeCodePlugin(), .waitingForInput).outcome)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    func testPreflightReturnsKnownBusyStateWithoutSendingInput() throws {
        host.seedLiveSession(SESSION)

        let blocker = try XCTUnwrap(try closer.preflight(SESSION, ClaudeCodePlugin(), .working))

        XCTAssertEqual(GracefulCloser.Outcome.busyState, blocker.outcome)
        XCTAssertEqual("session is WORKING", blocker.detail)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    func testPreflightAllowsIdleHarnessWithoutSendingItsQuitCommand() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "❯ ", "claude")

        XCTAssertNil(try closer.preflight(SESSION, ClaudeCodePlugin(), .idle))
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    /// The caffeinate case: quiet enough to poll as IDLE forever, but killing it would
    /// kill work in flight — only the fresh foreground check can catch it.
    func testForegroundProgramIsRefusedByName() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "", "caffeinate")
        let result = try close(ShellPlugin(), .idle)
        XCTAssertEqual(GracefulCloser.Outcome.busyForeground, result.outcome)
        XCTAssertEqual("caffeinate", result.detail)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    func testPreflightReturnsForegroundBlockerWithoutSendingInput() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "", "caffeinate")

        let blocker = try XCTUnwrap(try closer.preflight(SESSION, ShellPlugin(), .idle))

        XCTAssertEqual(GracefulCloser.Outcome.busyForeground, blocker.outcome)
        XCTAssertEqual("caffeinate", blocker.detail)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    /// Never type quit text into a harness whose status has never been polled — the whole
    /// point of the busy checks is not to submit into a possibly-running turn.
    func testUnpolledHarnessIsRefused() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "❯ ", "claude")
        XCTAssertEqual(GracefulCloser.Outcome.busyState, try close(ClaudeCodePlugin(), nil).outcome)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    private final class MysteryHarness: HarnessPlugin, @unchecked Sendable {
        var type: HarnessType { .cursorAgent }
        func launchCommand() -> String { "mystery-harness" }
        func processName() -> String { "mystery-harness" }
    }

    /// A future plugin without grounded quit syntax must still be refused rather than
    /// having guessed text typed into its conversation.
    func testHarnessWithoutQuitSyntaxIsRefused() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "❯ ", "mystery-harness")
        let result = try close(MysteryHarness(), .idle)
        XCTAssertEqual(GracefulCloser.Outcome.noQuitSyntax, result.outcome)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    func testHarnessThatIgnoresItsQuitCommandTimesOutWithoutCleanup() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "❯ ", "claude") // never reacts to /exit
        let result = try close(ClaudeCodePlugin(), .idle)
        XCTAssertEqual(GracefulCloser.Outcome.quitTimeout, result.outcome)
        XCTAssertEqual([SESSION + ": /exit"], host.sentCommands)
        XCTAssertTrue(try host.hasSession(SESSION), "a timed-out close must leave the session alone")
    }

    func testShellThatIgnoresExitTimesOut() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "sample@host proj %", "zsh") // never reacts to exit
        XCTAssertEqual(GracefulCloser.Outcome.exitTimeout, try close(ShellPlugin(), .idle).outcome)
        XCTAssertTrue(try host.hasSession(SESSION))
    }

    func testAlreadyGoneSessionJustReportsGone() throws {
        // never seeded: capture reports a dead pane
        XCTAssertEqual(GracefulCloser.Outcome.alreadyGone, try close(ClaudeCodePlugin(), .idle).outcome)
        XCTAssertTrue(host.sentCommands.isEmpty)
    }

    /// A harness running as the session's root process takes the whole session with it on
    /// quit — the exit stage must notice the session is gone instead of sending `exit`
    /// into the void (the fake would throw; the daemon would error).
    func testSessionCollapsingWithTheHarnessSkipsTheExitStage() throws {
        host.seedLiveSession(SESSION)
        host.screen(SESSION, "❯ ", "claude")
        host.onSendKeys = { [unowned self] _ in host.endSession(SESSION) } // /exit ends everything
        let result = try close(ClaudeCodePlugin(), .idle)
        XCTAssertEqual(GracefulCloser.Outcome.closed, result.outcome)
        XCTAssertEqual([SESSION + ": /exit"], host.sentCommands)
    }
}
