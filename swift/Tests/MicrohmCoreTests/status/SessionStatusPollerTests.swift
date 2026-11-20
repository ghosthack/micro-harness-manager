import Foundation
import XCTest
@testable import MicrohmCore

/// Exercises the poll -> publish wiring against `FakeStatusSessionHost`, with both the
/// "background" and "result" executors running same-thread so results are visible
/// immediately (no main-thread hop involved — that part is production-only wiring).
final class SessionStatusPollerTests: XCTestCase {

    private let SHORT: TimeInterval = 5
    private let LONG: TimeInterval = 20

    private let sameThread: SessionStatusPoller.Executor = { $0() }

    private func entry(_ sessionName: String, _ type: HarnessType) -> SessionEntry {
        SessionEntry(sessionName, "/Users/x/Projects/foo", type, nil, epoch)
    }

    /// Never consulted for non-Codex sessions; for Codex ones it finds no rollout.
    private func noCodex() -> CodexSessionNameResolver {
        CodexSessionNameResolver(URL(fileURLWithPath: "/nonexistent-codex-home"), { _ in nil })
    }

    private func poller(_ host: StatusSessionHost, _ background: @escaping SessionStatusPoller.Executor,
                        _ dispatcher: @escaping SessionStatusPoller.Executor, _ clock: MicrohmClock) -> SessionStatusPoller {
        SessionStatusPoller(host, background, dispatcher, clock, SHORT, LONG, noCodex())
    }

    func testFirstSnapshotsRemainPendingInsteadOfPresentingUnknownAsWorking() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.seedLiveSession("mhm-b")
        host.screen("mhm-a", "working output")
        host.screen("mhm-b", "more output")

        let poller = poller(host, sameThread, sameThread, MutableClock())
        var results: [String: SessionStatusPoller.PollResult] = [:]
        poller.pollAll([entry("mhm-a", .claudeCode), entry("mhm-b", .cursorAgent)]) { results[$0] = $1 }

        XCTAssertEqual(2, results.count)
        XCTAssertNotNil(results["mhm-a"])
        XCTAssertNotNil(results["mhm-b"])
        XCTAssertEqual(SessionState.working, results["mhm-a"]!.classification.state)
        XCTAssertFalse(results["mhm-a"]!.stateConfirmed)
        XCTAssertFalse(results["mhm-b"]!.stateConfirmed)
    }

    func testQuiescenceAccumulatesAcrossPolls() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "checked off item 3\n❯ ")
        let clock = MutableClock()

        let poller = poller(host, sameThread, sameThread, clock)
        var results: [String: SessionStatusPoller.PollResult] = [:]
        let sessions = [entry("mhm-a", .cursorAgent)]

        poller.pollAll(sessions) { results[$0] = $1 }
        XCTAssertFalse(results["mhm-a"]!.stateConfirmed)

        clock.advance(3)
        poller.pollAll(sessions) { results[$0] = $1 }
        XCTAssertFalse(results["mhm-a"]!.stateConfirmed)
        XCTAssertEqual(Confidence.medium, results["mhm-a"]!.classification.confidence)

        clock.advance(3)
        poller.pollAll(sessions) { results[$0] = $1 }
        XCTAssertTrue(results["mhm-a"]!.stateConfirmed)
        XCTAssertEqual(SessionState.idle, results["mhm-a"]!.classification.state)
    }

    func testDetectorStateIsIndependentPerSession() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.seedLiveSession("mhm-b")
        host.screen("mhm-a", "same text")
        host.screen("mhm-b", "same text")
        let clock = MutableClock()

        let poller = poller(host, sameThread, sameThread, clock)
        var results: [String: Classification] = [:]
        let sessions = [entry("mhm-a", .claudeCode), entry("mhm-b", .claudeCode)]

        poller.pollAll(sessions) { results[$0] = $1.classification }
        clock.advance(6)
        // mhm-b's text changes, mhm-a's doesn't — they must classify independently
        host.screen("mhm-b", "different text now")
        poller.pollAll(sessions) { results[$0] = $1.classification }

        XCTAssertEqual(SessionState.idle, results["mhm-a"]!.state)
        XCTAssertEqual(SessionState.working, results["mhm-b"]!.state)
    }

    private final class FlakyHost: StatusSessionHost {
        struct Simulated: Error {}
        func hasSession(_ session: String) throws -> Bool { true }
        func sendKeys(_ session: String, _ command: String) throws {}
        func capture(_ session: String) throws -> Screen {
            if session == "mhm-bad" {
                throw Simulated() // simulated daemon failure
            }
            return Screen("output", false, epoch, "")
        }
    }

    func testAFailingSessionDoesNotBlockOthersOrPublishAResultForItself() {
        let poller = poller(FlakyHost(), sameThread, sameThread, MutableClock())
        var results: [String: Classification] = [:]
        poller.pollAll([entry("mhm-good", .claudeCode), entry("mhm-bad", .claudeCode)]) {
            results[$0] = $1.classification
        }

        XCTAssertEqual(1, results.count)
        XCTAssertNotNil(results["mhm-good"])
    }

    func testForgetDropsDetectorSoANewLifecycleStartsFresh() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "same text")
        let clock = MutableClock()

        let poller = poller(host, sameThread, sameThread, clock)
        var results: [String: Classification] = [:]
        let sessions = [entry("mhm-a", .claudeCode)]

        poller.pollAll(sessions) { results[$0] = $1.classification }
        clock.advance(6)
        poller.pollAll(sessions) { results[$0] = $1.classification }
        XCTAssertEqual(SessionState.idle, results["mhm-a"]!.state)

        poller.forget("mhm-a")
        var freshResults: [String: SessionStatusPoller.PollResult] = [:]
        poller.pollAll(sessions) { freshResults[$0] = $1 }
        // A fresh detector has no comparison baseline, so its provisional WORKING
        // classification must not be presented as a confirmed green state.
        XCTAssertFalse(freshResults["mhm-a"]!.stateConfirmed)
    }

    /// Background "executor" that queues tasks for the test to run by hand, so overlap and
    /// forget/poll interleavings can be exercised deterministically.
    private final class ManualExecutor {
        var queued: [() -> Void] = []

        lazy var execute: SessionStatusPoller.Executor = { [unowned self] task in queued.append(task) }

        func runAll() {
            while !queued.isEmpty {
                queued.removeFirst()()
            }
        }
    }

    func testPollsSerializePerSessionInsteadOfStacking() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "output")
        let background = ManualExecutor()

        let poller = poller(host, background.execute, sameThread, MutableClock())
        var results: [String: Classification] = [:]
        let sessions = [entry("mhm-a", .claudeCode)]

        // three ticks land while the first capture is still "in flight" (unrun)
        poller.pollAll(sessions) { results[$0] = $1.classification }
        poller.pollAll(sessions) { results[$0] = $1.classification }
        poller.pollAll(sessions) { results[$0] = $1.classification }
        XCTAssertEqual(1, background.queued.count) // ticks 2 and 3 skipped, not stacked

        background.runAll()
        XCTAssertEqual(1, results.count)

        // with the first task done, the next tick polls again
        poller.pollAll(sessions) { results[$0] = $1.classification }
        XCTAssertEqual(1, background.queued.count)
    }

    func testForgetDuringAnInFlightPollDropsTheResultAndTheStaleDetector() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "old lifecycle output")
        let background = ManualExecutor()

        let poller = poller(host, background.execute, sameThread, MutableClock())
        var results: [String: Classification] = [:]

        poller.pollAll([entry("mhm-a", .claudeCode)]) { results[$0] = $1.classification }
        poller.forget("mhm-a") // lifecycle ends while the capture task is still queued
        background.runAll()

        XCTAssertTrue(results.isEmpty, "a poll of the ended lifecycle must not publish")
        XCTAssertFalse(poller.hasDetector("mhm-a"), "the ended lifecycle's detector must not be resurrected")
    }

    func testForgetWhileTheResultSitsInTheDispatchQueueDropsIt() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "old lifecycle output")
        let background = ManualExecutor()
        let dispatcher = ManualExecutor()

        let poller = poller(host, background.execute, dispatcher.execute, MutableClock())
        var results: [String: Classification] = [:]

        poller.pollAll([entry("mhm-a", .claudeCode)]) { results[$0] = $1.classification }
        background.runAll() // capture+classify done; the result now sits in the dispatch queue
        poller.forget("mhm-a") // production equivalent: forget() on the main thread before the result task runs
        dispatcher.runAll()

        XCTAssertTrue(results.isEmpty, "a result dispatched after forget() must not be published")
    }

    /// Fires `forget()` from inside `StateDetector.classify` (which reads the injected
    /// clock) — i.e. after the capture-time generation check passed and after the detector
    /// was re-inserted, the exact window the conditional self-eviction exists for.
    private final class HookClock: MicrohmClock {
        private let now = IsoInstant.parse("2026-08-17T00:00:00Z")!
        weak var poller: SessionStatusPoller?
        var fired = false

        func instant() -> Date {
            if !fired, let poller {
                fired = true
                poller.forget("mhm-a")
            }
            return now
        }
    }

    func testForgetBetweenCaptureAndPublishEvictsTheResurrectedDetector() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "old lifecycle output")
        let hookClock = HookClock()

        let poller = poller(host, sameThread, sameThread, hookClock)
        hookClock.poller = poller
        var results: [String: Classification] = [:]
        poller.pollAll([entry("mhm-a", .claudeCode)]) { results[$0] = $1.classification }

        XCTAssertTrue(hookClock.fired, "the hook must actually have run inside classify")
        XCTAssertTrue(results.isEmpty, "a classification of the ended lifecycle must not be published")
        XCTAssertFalse(poller.hasDetector("mhm-a"), "the detector re-inserted mid-poll must be evicted, not resurrected")
    }

    func testPublishesThePaneTitleAlongsideTheClassification() {
        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "output")
        host.paneTitle("mhm-a", "✳ refactor the poller")

        let poller = poller(host, sameThread, sameThread, MutableClock())
        var results: [String: SessionStatusPoller.PollResult] = [:]
        poller.pollAll([entry("mhm-a", .claudeCode)]) { results[$0] = $1 }

        XCTAssertEqual("✳ refactor the poller", results["mhm-a"]!.paneTitle)
        XCTAssertEqual(SessionState.working, results["mhm-a"]!.classification.state)
        XCTAssertFalse(results["mhm-a"]!.stateConfirmed)
    }

    func testCodexSavedRenameOverridesItsGenericOscTitle() throws {
        let codexHome = try makeTempDir(self)
        let id = "01a0299e-d978-7651-871e-e746fedd1186"
        let rollout = try writeString(codexHome.appendingPathComponent("rollout-" + id + ".jsonl"), "")
        try writeString(codexHome.appendingPathComponent("session_index.jsonl"),
                        "{\"id\":\"" + id + "\",\"thread_name\":\"saved Codex name\"}\n")

        let host = FakeStatusSessionHost()
        host.seedLiveSession("mhm-a")
        host.screen("mhm-a", "output")
        host.paneProcessId("mhm-a", 42)
        host.paneTitle("mhm-a", "⠼ project-directory")
        let resolver = CodexSessionNameResolver(codexHome, { _ in rollout })
        let poller = SessionStatusPoller(host, sameThread, sameThread, MutableClock(), SHORT, LONG, resolver)
        var results: [String: SessionStatusPoller.PollResult] = [:]

        poller.pollAll([entry("mhm-a", .codex)]) { results[$0] = $1 }

        XCTAssertEqual("saved Codex name", results["mhm-a"]!.paneTitle)
    }
}
