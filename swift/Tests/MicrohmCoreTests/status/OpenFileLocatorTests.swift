import Foundation
import XCTest
@testable import MicrohmCore

final class OpenFileLocatorTests: XCTestCase {

    private typealias HarnessProcess = OpenFileLocator.HarnessProcess

    private let ROLLOUT = URL(fileURLWithPath: "/codex/sessions/rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl")

    /// Mutable state the injected closures share (Java's atomics).
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testLsofRunsOnceForTheSameHarnessProcessAcrossTicks() {
        let lsofCalls = Box(0)
        let clock = Box<UInt64>(0)
        let rollout = ROLLOUT
        let locator = OpenFileLocator({ _ in [HarnessProcess(100, 1)] },
                                      { _ in lsofCalls.value += 1; return rollout },
                                      { _ in true }, { clock.value })

        for _ in 0..<20 {
            XCTAssertEqual(ROLLOUT, locator.apply(42))
            clock.value += 4_000_000_000
        }
        XCTAssertEqual(1, lsofCalls.value)
    }

    func testANewHarnessProcessIsLookedUpAgain() {
        let lsofCalls = Box(0)
        let current = Box(HarnessProcess(100, 1))
        let rollout = ROLLOUT
        let locator = OpenFileLocator({ _ in [current.value] },
                                      { _ in lsofCalls.value += 1; return rollout },
                                      { _ in true }, { 0 })

        _ = locator.apply(42)
        _ = locator.apply(42)
        current.value = HarnessProcess(101, 2)
        _ = locator.apply(42)
        _ = locator.apply(42)
        // The same pid reused by a later process is a different process.
        current.value = HarnessProcess(100, 3)
        _ = locator.apply(42)
        XCTAssertEqual(3, lsofCalls.value)
    }

    func testAMissIsRetriedOnlyAfterBackOff() {
        let lsofCalls = Box(0)
        let clock = Box<UInt64>(0)
        let rollout = ROLLOUT
        let locator = OpenFileLocator({ _ in [HarnessProcess(100, 1)] },
                                      { _ in lsofCalls.value += 1; return lsofCalls.value < 2 ? nil : rollout },
                                      { _ in true }, { clock.value })

        XCTAssertNil(locator.apply(42))
        clock.value += OpenFileLocator.missRetryNanos - 1
        XCTAssertNil(locator.apply(42))
        XCTAssertEqual(1, lsofCalls.value)
        clock.value += 1
        XCTAssertEqual(ROLLOUT, locator.apply(42))
        XCTAssertEqual(2, lsofCalls.value)
    }

    func testAHitIsRecheckedAfterTheRefreshInterval() {
        let lsofCalls = Box(0)
        let clock = Box<UInt64>(0)
        let rollout = ROLLOUT
        let locator = OpenFileLocator({ _ in [HarnessProcess(100, 1)] },
                                      { _ in lsofCalls.value += 1; return rollout },
                                      { _ in true }, { clock.value })

        _ = locator.apply(42)
        clock.value += OpenFileLocator.hitRefreshNanos
        _ = locator.apply(42)
        XCTAssertEqual(2, lsofCalls.value)
    }

    func testExitedProcessesAreForgotten() {
        let clock = Box<UInt64>(0)
        let alive = Box<Set<Int64>>([100, 101])
        let rollout = ROLLOUT
        let locator = OpenFileLocator({ pane in [HarnessProcess(pane, 1)] },
                                      { _ in rollout },
                                      { alive.value.contains($0.pid) }, { clock.value })

        _ = locator.apply(100)
        _ = locator.apply(101)
        XCTAssertEqual(2, locator.cachedProcessCount())
        alive.value.remove(100)
        clock.value += OpenFileLocator.pruneIntervalNanos
        _ = locator.apply(101)
        XCTAssertEqual(1, locator.cachedProcessCount())
    }

    /// The real thing: this test process holds a file open, and lsof over its own pid
    /// finds it and maps it to the transcript beside it.
    func testOverLsofFindsTheFileTheHarnessProcessHoldsOpen() throws {
        try XCTSkipUnless(["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }, "lsof installed")
        let dir = try makeTempDir(self)
        let session = try createDirectories(dir.appendingPathComponent("s1"))
        let transcript = try writeString(session.appendingPathComponent("log.jsonl"), "{}\n")
        let lock = try writeString(session.appendingPathComponent(".lock"), "")
        let me = Int64(getpid())
        let myName = try XCTUnwrap(OpenFileLocator.executablePath(me).map { ($0 as NSString).lastPathComponent })
        let held = try FileHandle(forUpdating: lock)
        defer { try? held.close() }

        let locator = OpenFileLocator.overLsof({ $0 == myName }, { open in
            open.lastPathComponent == ".lock" && PathCompat.startsWith(open, session)
                ? open.deletingLastPathComponent().appendingPathComponent("log.jsonl") : nil
        })
        XCTAssertEqual(transcript.path, locator.apply(me)?.path)
        let nobody = OpenFileLocator.overLsof({ $0 == "no-such-harness" }, { $0 })
        XCTAssertNil(nobody.apply(me), "no harness process under the pane")
        XCTAssertEqual([], OpenFileLocator.processes(-1) { _ in true })
    }
}
