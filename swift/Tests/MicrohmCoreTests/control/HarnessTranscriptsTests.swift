import XCTest
@testable import MicrohmCore

/// Transcript lookup over a temporary Claude projects directory and a fake Codex locator.
final class HarnessTranscriptsTests: XCTestCase {

    func testClaudeUsesTheSessionsOwnFileElseTheNewestInTheProjectDirectory() throws {
        let dir = try makeTempDir(self)
        let projects = dir.appendingPathComponent("projects")
        let project = URL(fileURLWithPath: "/Users/me/src/my_app.v2")
        // Claude's folder name: every non-alphanumeric character of the absolute path a dash
        let claudeDir = try createDirectories(projects.appendingPathComponent("-Users-me-src-my-app-v2"))
        let older = try writeString(claudeDir.appendingPathComponent("aaaa-1.jsonl"), "{}")
        let newer = try writeString(claudeDir.appendingPathComponent("bbbb-2.jsonl"), "{}")
        try setLastModified(older, millis: 1_000)
        try setLastModified(newer, millis: 2_000)
        let transcripts = HarnessTranscripts(projects, CodexSessionNameResolver(dir) { _ in nil })

        XCTAssertEqual(newer.path, transcripts.transcript(.claudeCode, project, nil, -1)?.path)
        XCTAssertEqual(older.path, transcripts.transcript(.claudeCode, project, "aaaa-1", -1)?.path)
        XCTAssertNil(transcripts.transcript(.claudeCode, project, "cccc-3", -1),
                     "a known id whose conversation has no message yet is not given another session's file")
        XCTAssertNil(transcripts.transcript(.claudeCode, URL(fileURLWithPath: "/elsewhere"), nil, -1))
        XCTAssertNil(transcripts.transcript(.grok, project, nil, 7))
    }

    func testMuseAndGrokAskTheirLocatorsWithThePanesPid() throws {
        let dir = try makeTempDir(self)
        let muse = dir.appendingPathComponent("muse/sessions/2026/11/08/01a1/session.jsonl")
        let grok = dir.appendingPathComponent("grok/sessions/%2Fp/01b2/chat_history.jsonl")
        let transcripts = HarnessTranscripts(dir.appendingPathComponent("projects"),
                                             CodexSessionNameResolver(dir) { _ in nil },
                                             { $0 == 42 ? muse : nil }, { $0 == 43 ? grok : nil })
        let p = URL(fileURLWithPath: "/p")
        XCTAssertEqual(muse, transcripts.transcript(.muse, p, nil, 42))
        XCTAssertNil(transcripts.transcript(.muse, p, nil, 43))
        XCTAssertEqual(grok, transcripts.transcript(.grok, p, nil, 43))
        XCTAssertNil(transcripts.transcript(.grok, p, nil, -1), "no pane pid, no lookup")
    }

    func testCodexAsksTheResolverForThePanesOpenRollout() throws {
        let dir = try makeTempDir(self)
        let rollout = dir.appendingPathComponent(
            "sessions/rollout-2026-01-01T00-00-00-0199a0b1-0000-7000-8000-000000000001.jsonl")
        let transcripts = HarnessTranscripts(dir.appendingPathComponent("projects"),
                                             CodexSessionNameResolver(dir) { $0 == 42 ? rollout : nil })
        let p = URL(fileURLWithPath: "/p")
        XCTAssertEqual(rollout.path, transcripts.transcript(.codex, p, nil, 42)?.path)
        XCTAssertNil(transcripts.transcript(.codex, p, nil, 43))
    }
}
