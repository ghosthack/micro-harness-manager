import Foundation
import XCTest
@testable import MicrohmCore

/// Muse's session layout, over a temporary sessions root shaped like the real one.
final class MuseSessionsTests: XCTestCase {

    func testAnOpenFileInADatedSessionDirectoryLeadsToItsSessionLog() throws {
        let root = try makeTempDir(self)
        let session = try createDirectories(root.appendingPathComponent("2026/11/08/01a1be9d-d2f1-7f23-9d66-e54fc58ac046"))
        let log = try writeString(session.appendingPathComponent("session.jsonl"), "{}\n")
        let lock = try writeString(session.appendingPathComponent(".session.lock"), "")
        let subagent = try createDirectories(session.appendingPathComponent("subagent/x")).appendingPathComponent("y.jsonl")

        XCTAssertEqual(log.path, MuseSessions.transcriptOf(root, lock)?.path, "the lock a running Muse holds")
        XCTAssertEqual(log.path, MuseSessions.transcriptOf(root, log)?.path)
        XCTAssertEqual(log.path, MuseSessions.transcriptOf(root, subagent)?.path, "a sub-agent's file: its session")
        XCTAssertEqual(log.path, MuseSessions.transcriptOf(root, root.appendingPathComponent("2026/11/../11/08/"
            + "01a1be9d-d2f1-7f23-9d66-e54fc58ac046/.session.lock"))?.path, "normalized")
    }

    func testFilesOutsideADatedSessionDirectoryLeadNowhere() throws {
        let root = try makeTempDir(self)
        let view = try createDirectories(root.appendingPathComponent(".msp-view-g6/01a1/x"))
        try writeString(view.deletingLastPathComponent().appendingPathComponent("session.jsonl"), "{}\n")
        let noLogYet = try createDirectories(root.appendingPathComponent("2026/11/09/01a2"))

        XCTAssertNil(MuseSessions.transcriptOf(root, view.appendingPathComponent("index-00000000.bin")))
        XCTAssertNil(MuseSessions.transcriptOf(root, root.appendingPathComponent("../session-index.db")))
        XCTAssertNil(MuseSessions.transcriptOf(root, noLogYet.appendingPathComponent(".session.lock")),
                     "no session.jsonl written yet")
        XCTAssertNil(MuseSessions.transcriptOf(root, root.appendingPathComponent("2026/11/09")))
        XCTAssertNil(MuseSessions.transcriptOf(root, URL(fileURLWithPath: "/elsewhere/2026/11/08/a/b")))
    }

    func testItsExecutablesAndRoot() {
        XCTAssertTrue(MuseSessions.isExecutable("muse"))
        XCTAssertTrue(MuseSessions.isExecutable("muse-bin-1.4.14-R7309.1"))
        XCTAssertFalse(MuseSessions.isExecutable("museum"))
        XCTAssertFalse(MuseSessions.isExecutable("bash"))
        XCTAssertTrue(MuseSessions.root().path.hasSuffix("/muse/sessions"))
    }
}
