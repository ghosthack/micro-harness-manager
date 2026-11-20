import Foundation
import XCTest
@testable import MicrohmCore

/// The phone's close over the window's graceful closer, on a fake host.
final class PhoneCloserTests: XCTestCase {

    private static let SESSION = "mhm-proj"
    private var host: FakeSessionHost!
    private let events = SessionEvents()
    private let runEnded = SvcList<String>()

    override func setUp() {
        host = FakeSessionHost()
    }

    private func closer(_ registry: SessionRegistry) -> PhoneCloser {
        events.addSessionRunEndedListener { [runEnded] in runEnded.append($0) }
        return PhoneCloser(GracefulCloser(host, 0.001, 0.05, 0.05), registry, events)
    }

    private func registry() throws -> SessionRegistry {
        SessionRegistry.load(try makeTempDir(self).appendingPathComponent("sessions.json"))
    }

    func testClosesAnIdleAgentKeepsItsConversationAndTellsTheWindow() throws {
        let registry = try registry()
        let session = PhoneCloserTests.SESSION
        registry.put(SessionEntry.newlyCreated(session, "/proj", .claudeCode, nil))
        host.seedLiveSession(session)
        host.screen(session, "❯ ", "claude")
        host.onSendKeys = { [host] command in
            if command == session + ": /exit" {
                host!.screen(session, """
                    Resume this session with:
                    claude --resume fd626959-efe0-414b-a3f5-9261602748ed
                    sample@host proj %

                    """, "zsh")
            } else if command == session + ": exit" {
                host!.endSession(session)
            }
        }
        let closer = closer(registry)

        XCTAssertNil(closer.blocker(session, .claudeCode, .idle))
        let outcome = closer.close(session, .claudeCode, .idle)

        XCTAssertTrue(outcome.closed, outcome.message)
        XCTAssertEqual("fd626959-efe0-414b-a3f5-9261602748ed", registry.find(session)?.harnessSessionId)
        XCTAssertEqual([session], runEnded.all)
    }

    func testRefusesAWorkingAgentWithoutTypingAnything() throws {
        let registry = try registry()
        let session = PhoneCloserTests.SESSION
        host.seedLiveSession(session)
        host.screen(session, "✻ Thinking… (esc to interrupt)", "claude")
        let closer = closer(registry)

        XCTAssertEqual("It's still working. Close it once it's done.", closer.blocker(session, .claudeCode, .working))
        let outcome = closer.close(session, .claudeCode, .working)
        XCTAssertFalse(outcome.closed)
        XCTAssertEqual("It's still working. Close it once it's done.", outcome.message)
        XCTAssertTrue(host.sentCommands.isEmpty)
        XCTAssertTrue(runEnded.all.isEmpty)
    }

    func testNamesAProgramStillRunningInFront() throws {
        let registry = try registry()
        host.seedLiveSession(PhoneCloserTests.SESSION)
        host.screen(PhoneCloserTests.SESSION, "", "vim")
        XCTAssertEqual("'vim' is still running in it. Stop that first.",
                       closer(registry).blocker(PhoneCloserTests.SESSION, .shell, .idle))
    }
}

final class StyledScreenTests: XCTestCase {

    /// Slot i is 0x0000ii, so a colour names its slot; 0 is black, 15 white.
    private let screen = StyledScreen((0..<16).map { $0 == 15 ? 0xFFFFFF : $0 })

    func testRunsCarryColoursAndStylesAndInverseSwaps() {
        let out = screen.render("\u{1b}[1;31mred\u{1b}[0m plain \u{1b}[7minv\u{1b}[0m", 30, 2)
        XCTAssertEqual("#ffffff", out.path("fg").asText())
        XCTAssertEqual("#000000", out.path("bg").asText())
        let row = out.path("rows").path(0)
        XCTAssertEqual(3, row.elements.count, row.compact())
        XCTAssertEqual("red", row.path(0).path("t").asText())
        XCTAssertEqual("#000001", row.path(0).path("f").asText())
        XCTAssertEqual(StyledScreen.BOLD, row.path(0).path("s").asInt())
        XCTAssertEqual(" plain ", row.path(1).path("t").asText())
        XCTAssertFalse(row.path(1).has("f"), "default colours are left to the page")
        XCTAssertEqual("inv", row.path(2).path("t").asText())
        XCTAssertEqual("#000000", row.path(2).path("f").asText())
        XCTAssertEqual("#ffffff", row.path(2).path("b").asText())
    }

    func testKeepsBlockArtAndTrueColourAndDropsTrailingBlanks() {
        let row = screen.render("\u{1b}[38;2;215;119;87m▐▛███▜▌\u{1b}[0m   ", 20, 1).path("rows").path(0)
        XCTAssertEqual(1, row.elements.count, row.compact())
        XCTAssertEqual("▐▛███▜▌", row.path(0).path("t").asText())
        XCTAssertEqual("#d77757", row.path(0).path("f").asText())
    }

    func testABackgroundRunKeepsItsSpaces() {
        let row = screen.render("\u{1b}[44m  \u{1b}[0m", 10, 1).path("rows").path(0)
        XCTAssertEqual("  ", row.path(0).path("t").asText())
        XCTAssertEqual("#000004", row.path(0).path("b").asText())
    }

    func testUnderlinesCarryTheirKind() {
        let row = screen.render("\u{1b}[4ma\u{1b}[21mb\u{1b}[4:3mc\u{1b}[4:4md\u{1b}[4:5me", 10, 1).path("rows").path(0)
        XCTAssertEqual(StyledScreen.UNDERLINE, row.path(0).path("s").asInt())
        XCTAssertEqual(StyledScreen.UNDERLINE | StyledScreen.DOUBLE, row.path(1).path("s").asInt())
        XCTAssertEqual(StyledScreen.UNDERLINE | StyledScreen.CURLY, row.path(2).path("s").asInt())
        XCTAssertEqual(StyledScreen.UNDERLINE | StyledScreen.DOTTED, row.path(3).path("s").asInt())
        XCTAssertEqual(StyledScreen.UNDERLINE | StyledScreen.DASHED, row.path(4).path("s").asInt())
    }

    func testThePalettesMatchTheTerminalModule() {
        XCTAssertEqual(0xC23621, StyledScreen.palette(.macosTerminal)[1])
        XCTAssertEqual(0xC91B00, StyledScreen.palette(.iterm2)[1])
        XCTAssertEqual(0xCD0000, StyledScreen.palette(.xterm)[1])
        XCTAssertEqual(16, StyledScreen.palette(.xterm).count)
    }
}
