import Darwin
import Foundation
import XCTest
@testable import MicrohmCore
import MicrohmShared

final class HostOwnerTests: XCTestCase {

    func testARecordRoundTripsThroughItsFile() throws {
        let dir = try makeTempDir(self)
        let registry = dir.appendingPathComponent("sessions.json")
        let record = HostOwner.Record(4242, 1_700_000_000_123)
        try HostOwner.write(registry, record)
        XCTAssertEqual(record, HostOwner.read(registry))
        XCTAssertEqual(dir.appendingPathComponent("mcp-host.pid").path, HostOwner.file(registry).path)
    }

    func testAGarbledOrMissingFileReadsAsNoHost() throws {
        let registry = try makeTempDir(self).appendingPathComponent("sessions.json")
        XCTAssertNil(HostOwner.read(registry))
        try writeString(HostOwner.file(registry), "not a record\n")
        XCTAssertNil(HostOwner.read(registry))
    }

    func testAPidOutsidePidTIsNoRecordAndStoppingIgnoresIt() throws {
        let registry = try makeTempDir(self).appendingPathComponent("sessions.json")
        for corrupt in ["99999999999 1700000000000", "4294967297 1", "-5 1", "0 1"] {
            try writeString(HostOwner.file(registry), corrupt + "\n")
            XCTAssertNil(HostOwner.read(registry), corrupt)
            XCTAssertTrue(HostOwner.stop(registry, 0.1), corrupt) // no trap: nothing to stop
        }
        XCTAssertFalse(HostOwner.live(HostOwner.Record(99_999_999_999, 1)))
        try writeString(HostOwner.file(registry), "\(Int32.max) 1\n")
        XCTAssertEqual(HostOwner.Record(Int64(Int32.max), 1), HostOwner.read(registry))
    }

    func testThisProcessIsLiveUnderItsOwnRecord() throws {
        let me = try XCTUnwrap(HostOwner.current())
        XCTAssertEqual(Int64(getpid()), me.pid)
        XCTAssertTrue(HostOwner.live(me))
    }

    func testAReusedPidWithAnotherStartTimeIsNotTheHost() throws {
        let me = try XCTUnwrap(HostOwner.current())
        XCTAssertFalse(HostOwner.live(HostOwner.Record(me.pid, me.startEpochMillis - 60_000)),
                       "a pid alone must never identify the host")
        XCTAssertFalse(HostOwner.live(HostOwner.Record(me.pid, me.startEpochMillis)) { _ in nil })
    }

    func testClearingLeavesANewerHostsRecordAlone() throws {
        let registry = try makeTempDir(self).appendingPathComponent("sessions.json")
        let older = HostOwner.Record(1, 1)
        let newer = HostOwner.Record(2, 2)
        try HostOwner.write(registry, newer)
        HostOwner.clear(registry, older)
        XCTAssertEqual(newer, HostOwner.read(registry))
        HostOwner.clear(registry, newer)
        XCTAssertNil(HostOwner.read(registry))
    }

    func testStoppingWithNoLiveHostClearsAStaleRecord() throws {
        let registry = try makeTempDir(self).appendingPathComponent("sessions.json")
        let me = try XCTUnwrap(HostOwner.current())
        try HostOwner.write(registry, HostOwner.Record(me.pid, me.startEpochMillis - 60_000))
        XCTAssertTrue(HostOwner.stop(registry, 1))
        XCTAssertNil(HostOwner.read(registry))
    }

    func testStoppingALiveHostEndsIt() throws {
        let registry = try makeTempDir(self).appendingPathComponent("sessions.json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        var start: Int64?
        svcAwait(5) {
            start = HostOwner.startMillis(Int64(child.processIdentifier))
            return start != nil
        }
        try HostOwner.write(registry, HostOwner.Record(Int64(child.processIdentifier), start!))
        XCTAssertTrue(HostOwner.stop(registry, 5))
        child.waitUntilExit()
        XCTAssertNil(HostOwner.read(registry))
    }
}

final class InstanceLockTests: XCTestCase {

    func testEachRegistryHasItsOwnLock() throws {
        let dir = try makeTempDir(self)
        let a = dir.appendingPathComponent("a").appendingPathComponent("sessions.json")
        let b = dir.appendingPathComponent("b").appendingPathComponent("sessions.json")
        defer { InstanceLock.release(a); InstanceLock.release(b) }
        XCTAssertEqual(.ACQUIRED, InstanceLock.tryAcquire(a))
        XCTAssertEqual(.ACQUIRED, InstanceLock.tryAcquire(a), "re-acquiring is idempotent")
        XCTAssertEqual(.ACQUIRED, InstanceLock.tryAcquire(b))
    }

    func testWaitingForAHeldLockGivesUpAfterTheTimeout() throws {
        let registry = try makeTempDir(self).appendingPathComponent("c").appendingPathComponent("sessions.json")
        try createDirectories(registry.deletingLastPathComponent())
        defer { InstanceLock.release(registry) }
        // another holder (here: another open file description in this process)
        let other = open(InstanceLock.lockFile(registry).path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(0, flock(other, LOCK_EX | LOCK_NB))
        let t0 = Date()
        XCTAssertEqual(.HELD, InstanceLock.acquire(registry, 0.3))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.3)
        close(other)
        XCTAssertEqual(.ACQUIRED, InstanceLock.tryAcquire(registry))
    }

    func testAnUnwritablePlaceIsUnavailable() throws {
        let blocker = try makeTempDir(self).appendingPathComponent("file")
        try writeString(blocker, "x")
        XCTAssertEqual(.UNAVAILABLE, InstanceLock.tryAcquire(blocker.appendingPathComponent("sessions.json")))
    }
}

final class HostLauncherTests: XCTestCase {

    func testTheHostCommandPassesTheModeAndTheStateLocations() {
        let registry = URL(fileURLWithPath: "/home/u/.micro-harness-manager-swift/sessions.json")
        let muxHome = URL(fileURLWithPath: "/home/u/.micro-harness-manager-swift/mux")
        XCTAssertEqual(["/Applications/Microhm.app/Contents/MacOS/microhm-host", McpHost.FLAG,
                        "--registry=" + registry.path, "--mux-home=" + muxHome.path],
                       HostLauncher.command(["/Applications/Microhm.app/Contents/MacOS/microhm-host"], registry, muxHome,
                                            McpHost.FLAG))
    }

    func testOpeningPassesTheStateButNoMode() {
        let registry = URL(fileURLWithPath: "/tmp/r/sessions.json")
        let muxHome = URL(fileURLWithPath: "/tmp/m")
        XCTAssertEqual(["/opt/mhm/bin/mhm", "--registry=/tmp/r/sessions.json", "--mux-home=/tmp/m"],
                       HostLauncher.command(["/opt/mhm/bin/mhm"], registry, muxHome))
    }

    func testNothingToHostLaunchesNothing() throws {
        let saved = MicrohmPaths.homeOverride
        defer { MicrohmPaths.homeOverride = saved }
        MicrohmPaths.homeOverride = try makeTempDir(self) // fresh settings: MCP and phone off
        let registry = SessionRegistry.load(MicrohmPaths.registryFile)
        XCTAssertFalse(HostLauncher.launchIfNeeded(registry, FakeSessionHost()))
    }

    func testLiveRegisteredCountsOnlyRegisteredSessionsTheDaemonRuns() throws {
        let registry = SessionRegistry.load(try makeTempDir(self).appendingPathComponent("sessions.json"))
        registry.put(SessionEntry.newlyCreated("mhm-a", "/p", .shell, nil))
        registry.put(SessionEntry.newlyCreated("mhm-b", "/p", .shell, nil))
        let host = FakeSessionHost()
        host.seedLiveSession("mhm-a")
        host.seedLiveSession("mhm-other")
        XCTAssertEqual(1, McpHost.liveRegistered(registry, host))
        host.failListing(SessionHostException("down"))
        XCTAssertEqual(0, McpHost.liveRegistered(registry, host), "a daemon that does not answer counts as none")
    }

    func testStateOptionsPointEveryPathAtTheGivenState() throws {
        let saved = MicrohmPaths.homeOverride
        let savedMux = ProcessInfo.processInfo.environment["MICROHM_MUX_HOME"]
        defer {
            MicrohmPaths.homeOverride = saved
            if let savedMux { setenv("MICROHM_MUX_HOME", savedMux, 1) } else { unsetenv("MICROHM_MUX_HOME") }
        }
        let dir = try makeTempDir(self)
        McpHost.applyStateOptions(["--registry=" + dir.appendingPathComponent("sessions.json").path,
                                   "--mux-home=" + dir.appendingPathComponent("m").path])
        XCTAssertEqual(dir.appendingPathComponent("sessions.json").path, RegistryPaths.resolve().path)
        XCTAssertEqual(dir.appendingPathComponent("m").path, MicrohmPaths.muxHome.path)
    }
}

final class PerfStatsTests: XCTestCase {

    func testTheSnapshotHasCpuMemoryAndThreads() {
        let rows = PerfStats.snapshot()
        let labels = rows.map(\.label)
        for label in ["Startup", "CPU time", "Memory in use", "Threads"] {
            XCTAssertTrue(labels.contains(label), "\(labels)")
        }
        XCTAssertGreaterThan(Int(rows.first { $0.label == "Threads" }?.value ?? "0") ?? 0, 0)
        XCTAssertTrue(PerfStats.asText(rows).hasPrefix("Startup: "))
        XCTAssertEqual("1 h 2 min", PerfStats.duration(3_725_000))
        XCTAssertEqual("0.25 s", PerfStats.seconds(250))
    }
}
