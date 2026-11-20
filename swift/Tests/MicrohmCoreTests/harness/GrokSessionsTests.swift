import Foundation
import XCTest
@testable import MicrohmCore

/// Grok's registry and session layout, over a temporary home shaped like the real one.
final class GrokSessionsTests: XCTestCase {

    private var home: URL!

    /// 2026-11-09T04:57:44.123926Z in microseconds, as Grok writes pid_start.
    private let START_MICROS: Int64 = 1794200264123926
    private var START_MILLIS: Int64 { START_MICROS / 1000 }

    override func setUpWithError() throws {
        home = try makeTempDir(self)
    }

    private func registry(_ json: String) throws {
        try writeString(home.appendingPathComponent("active_sessions.json"), json)
    }

    private func session(_ cwdFolder: String, _ id: String) throws -> URL {
        let dir = try createDirectories(home.appendingPathComponent("sessions").appendingPathComponent(cwdFolder)
            .appendingPathComponent(id))
        return try writeString(dir.appendingPathComponent("chat_history.jsonl"), "{\"type\":\"system\"}\n")
    }

    func testTheProcessesRegistrationLeadsToItsChatHistory() throws {
        let empty = try session("%2FUsers%2Fme%2FProjects%2Fempty", "01a1beab-6014-7290-ade0-ed6d3190fcb4")
        let spec = try session("%2FUsers%2Fme%2FProjects%2Favc-spec", "01a1bec2-fed8-7691-b2cf-3efa30eb7a30")
        try registry("""
            [
              {"session_id": "01a1beab-6014-7290-ade0-ed6d3190fcb4", "pid": 2918,
               "pid_start": \(START_MICROS), "cwd": "/Users/me/Projects/empty", "opened_at": "2026-11-09T04:57:45Z"},
              {"session_id": "01a1bec2-fed8-7691-b2cf-3efa30eb7a30", "pid": 42411,
               "pid_start": \(START_MICROS + 1_500_000_000), "cwd": "/Users/me/Projects/avc-spec", "opened_at": "2026-11-09T05:23:32Z"}
            ]
            """)

        XCTAssertEqual(empty, GrokSessions.transcript(home, 2918, START_MILLIS))
        XCTAssertEqual(empty, GrokSessions.transcript(home, 2918, START_MILLIS + 1500),
                       "start times a little apart are the same process")
        XCTAssertEqual(spec, GrokSessions.transcript(home, 42411, START_MILLIS + 1_500_000))
        XCTAssertEqual(empty, GrokSessions.transcript(home, 2918, 0), "start time unknown: by pid")
        XCTAssertNil(GrokSessions.transcript(home, 2918, START_MILLIS + 60_000),
                     "the same pid started later is another process")
        XCTAssertNil(GrokSessions.transcript(home, 7, START_MILLIS), "not registered")
    }

    func testNothingWithoutARegistryAChatHistoryOrASaneId() throws {
        XCTAssertNil(GrokSessions.transcript(home, 2918, START_MILLIS), "no registry")
        try registry("not json")
        XCTAssertNil(GrokSessions.transcript(home, 2918, START_MILLIS))
        try registry("{\"pid\": 2918}")
        XCTAssertNil(GrokSessions.transcript(home, 2918, START_MILLIS), "not an array")
        try registry("[{\"session_id\": \"01a1\", \"pid\": 2918}]")
        XCTAssertNil(GrokSessions.transcript(home, 2918, START_MILLIS), "no chat history yet")
        _ = try session("x", "01a1")
        XCTAssertNotNil(GrokSessions.transcript(home, 2918, START_MILLIS))
        try registry("[{\"session_id\": \"../x/01a1\", \"pid\": 2918}]")
        XCTAssertNil(GrokSessions.transcript(home, 2918, START_MILLIS), "no path tricks")
    }

    func testItsExecutables() {
        XCTAssertTrue(GrokSessions.isExecutable("grok"))
        XCTAssertTrue(GrokSessions.isExecutable("grok-1.0.77-macos-aarch64"))
        XCTAssertFalse(GrokSessions.isExecutable("grokker"))
        XCTAssertFalse(GrokSessions.isExecutable("zsh"))
    }
}
