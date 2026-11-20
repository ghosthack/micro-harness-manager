import Foundation
import XCTest
@testable import MicrohmCore

final class ReconcilerTests: XCTestCase {

    private func entry(_ sessionName: String) -> SessionEntry {
        SessionEntry(sessionName, "/Users/x/Projects/foo", .claudeCode, nil, epoch)
    }

    func testManagedAndLiveIsReportedAsLiveManaged() {
        let alive = entry("mhm-foo")
        let result = Reconciler.reconcile([alive], ["mhm-foo"])

        XCTAssertEqual([alive], result.liveManaged)
        XCTAssertTrue(result.deadRegistered.isEmpty)
    }

    func testRegisteredButNotLiveIsDeadRegistered() {
        let dead = entry("mhm-gone")
        let result = Reconciler.reconcile([dead], [])

        XCTAssertTrue(result.liveManaged.isEmpty)
        XCTAssertEqual([dead], result.deadRegistered)
    }

    func testLiveSessionsWithNoRegistryEntryAreIgnored() {
        let result = Reconciler.reconcile([], ["mhm-orphan", "work"])

        XCTAssertTrue(result.liveManaged.isEmpty)
        XCTAssertTrue(result.deadRegistered.isEmpty)
    }

    func testMixedLiveAndDeadKeepRegistryOrder() {
        let alive = entry("mhm-alive")
        let dead = entry("mhm-dead")
        let alsoAlive = entry("mhm-also")
        let result = Reconciler.reconcile([alive, dead, alsoAlive], ["mhm-also", "mhm-alive", "unrelated"])

        XCTAssertEqual([alive, alsoAlive], result.liveManaged)
        XCTAssertEqual([dead], result.deadRegistered)
    }
}
