import Foundation
import XCTest
@testable import MicrohmCore

final class CodexSessionNameResolverTests: XCTestCase {

    private let id = "01a0299e-d978-7651-871e-e746fedd1186"

    func testResolvesLatestSavedNameForActiveRollout() throws {
        let codexHome = try makeTempDir(self)
        let rollout = codexHome.appendingPathComponent("sessions/2026/08/22/rollout-2026-08-22T00-00-00-" + id + ".jsonl")
        try createDirectories(rollout.deletingLastPathComponent())
        try writeString(rollout, "")
        try writeString(codexHome.appendingPathComponent("session_index.jsonl"), """
            {"id":"\(id)","thread_name":"old name","updated_at":"2026-08-22T00:00:00Z"}
            {not-yet-complete
            {"id":"\(id)","thread_name":"new name","updated_at":"2026-08-22T00:01:00Z"}

            """)

        let resolver = CodexSessionNameResolver(codexHome, { _ in rollout })

        XCTAssertEqual("new name", resolver.resolve(42))
    }

    func testMissingRenameFallsBackCleanly() throws {
        let codexHome = try makeTempDir(self)
        let rollout = try writeString(codexHome.appendingPathComponent("rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl"), "")
        try writeString(codexHome.appendingPathComponent("session_index.jsonl"), """
            {"id":"someone-else","thread_name":"not this chat"}

            """)

        let resolver = CodexSessionNameResolver(codexHome, { _ in rollout })

        XCTAssertNil(resolver.resolve(42))
        XCTAssertNil(resolver.resolve(-1))
    }

    func testUnnamedExistingChatUsesFirstRealUserPromptAsPreview() throws {
        let codexHome = try makeTempDir(self)
        let rollout = try writeString(codexHome.appendingPathComponent("rollout-" + id + ".jsonl"),
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                + "\"content\":[{\"type\":\"input_text\",\"text\":"
                + "\"<environment_context>generated metadata</environment_context>\"}]}}\n"
                + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                + "\"content\":[{\"type\":\"input_text\",\"text\":"
                + "\"Fix the sidebar\\nname inheritance\"}]}}\n")
        try writeString(codexHome.appendingPathComponent("session_index.jsonl"), "")
        let resolver = CodexSessionNameResolver(codexHome, { _ in rollout })

        XCTAssertEqual("Fix the sidebar name inheritance", resolver.resolve(42))
    }

    func testTranscriptIsTheOpenRolloutAndEmptyWithoutAPane() throws {
        let codexHome = try makeTempDir(self)
        let rollout = codexHome.appendingPathComponent("sessions/../rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl")
        let resolver = CodexSessionNameResolver(codexHome, { pid in pid == 42 ? rollout : nil })

        XCTAssertEqual(codexHome.appendingPathComponent("rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl").path,
                       resolver.transcript(42)?.path)
        XCTAssertNil(resolver.transcript(7))
        XCTAssertNil(resolver.transcript(0))
    }

    func testIndexIsParsedOnlyWhenItChangesAndAppendsAreFolded() throws {
        let codexHome = try makeTempDir(self)
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        try writeString(index, "{\"id\":\"\(id)\",\"thread_name\":\"first\"}\n")
        try setLastModified(index, millis: 1_000_000)
        let sessionIndex = CodexSessionIndex(index)

        for _ in 0..<5 {
            XCTAssertEqual("first", sessionIndex.name(id))
        }
        XCTAssertEqual(1, sessionIndex.parseCount())

        // A half-written append is ignored if it does not parse, and completed later.
        try appendString(index, "{\"id\":\"other\",\"thread_name\":\"x\"}\n{\"id\":\"\(id)\",\"thr")
        try setLastModified(index, millis: 2_000_000)
        XCTAssertEqual("first", sessionIndex.name(id))
        XCTAssertEqual("x", sessionIndex.name("other"))
        XCTAssertEqual(2, sessionIndex.parseCount())
        try appendString(index, "ead_name\":\"second\"}")
        try setLastModified(index, millis: 3_000_000)
        XCTAssertEqual("second", sessionIndex.name(id))
        try appendString(index, "\n")
        try setLastModified(index, millis: 3_500_000)
        XCTAssertEqual("second", sessionIndex.name(id))
        XCTAssertEqual("x", sessionIndex.name("other"))
        XCTAssertEqual(4, sessionIndex.parseCount())

        // A rewritten, shorter file is parsed afresh.
        try writeString(index, "{\"id\":\"\(id)\",\"thread_name\":\"third\"}\n")
        try setLastModified(index, millis: 4_000_000)
        XCTAssertEqual("third", sessionIndex.name(id))
        XCTAssertNil(sessionIndex.name("other"))

        try FileManager.default.removeItem(at: index)
        XCTAssertNil(sessionIndex.name(id))
    }

    func testResolverPicksUpARenameAppendedLater() throws {
        let codexHome = try makeTempDir(self)
        let rollout = try writeString(codexHome.appendingPathComponent("rollout-" + id + ".jsonl"), "")
        let index = try writeString(codexHome.appendingPathComponent("session_index.jsonl"), "")
        let resolver = CodexSessionNameResolver(codexHome, { _ in rollout })

        XCTAssertNil(resolver.resolve(42))
        try writeString(index, "{\"id\":\"\(id)\",\"thread_name\":\"named\"}\n")
        XCTAssertEqual("named", resolver.resolve(42))
    }

    func testEmptyPreviewIsRetriedOnceTheRolloutGrows() throws {
        let codexHome = try makeTempDir(self)
        let rollout = try writeString(codexHome.appendingPathComponent("rollout-" + id + ".jsonl"), "")
        let resolver = CodexSessionNameResolver(codexHome, { _ in rollout })

        XCTAssertNil(resolver.resolve(42))
        try writeString(rollout,
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                + "\"content\":[{\"type\":\"input_text\",\"text\":\"Hello there\"}]}}\n")
        XCTAssertEqual("Hello there", resolver.resolve(42))
    }

    func testPreviewCacheIsBounded() throws {
        let codexHome = try makeTempDir(self)
        final class Current: @unchecked Sendable { var rollout: URL? }
        let current = Current()
        let resolver = CodexSessionNameResolver(codexHome, { _ in current.rollout })
        for i in 0..<(CodexSessionNameResolver.previewCacheLimit + 50) {
            let rollout = codexHome.appendingPathComponent(String(format: "rollout-01a0299e-d978-7651-871e-%012d.jsonl", i))
            try writeString(rollout, "")
            current.rollout = rollout
            _ = resolver.resolve(42)
        }
        XCTAssertEqual(CodexSessionNameResolver.previewCacheLimit, resolver.previewCacheSize())
    }
}
