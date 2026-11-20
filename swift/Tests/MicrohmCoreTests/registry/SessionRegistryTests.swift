import Foundation
import XCTest
@testable import MicrohmCore

final class SessionRegistryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
    }

    func testMissingFileLoadsEmpty() {
        let registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        XCTAssertTrue(registry.sessions().isEmpty)
    }

    func testRoundTripsThroughDisk() {
        let file = dir.appendingPathComponent("sessions.json")
        let claude = SessionEntry("mhm-foo", "/Users/x/Projects/foo", .claudeCode, "abc-123",
                                  IsoInstant.parse("2026-08-01T00:00:00Z")!)
        let cursor = SessionEntry("mhm-bar", "/Users/x/Projects/bar", .cursorAgent, nil,
                                  IsoInstant.parse("2026-08-02T00:00:00Z")!)

        let written = SessionRegistry.load(file)
        written.put(claude)
        written.put(cursor)

        let reloaded = SessionRegistry.load(file)
        let sessions = reloaded.sessions()
        XCTAssertEqual(2, sessions.count)
        XCTAssertEqual(claude, reloaded.find("mhm-foo"))
        XCTAssertEqual(cursor, reloaded.find("mhm-bar"))
        XCTAssertNil(reloaded.find("mhm-bar")!.harnessSessionIdOpt)
    }

    /// The file keeps the Java app's Jackson layout, field for field.
    func testWritesTheJacksonLayout() throws {
        let file = dir.appendingPathComponent("sessions.json")
        let registry = SessionRegistry.load(file)
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, IsoInstant.parse("2026-08-01T00:00:00.123Z")!))
        XCTAssertEqual("""
            {
              "sessions" : [ {
                "sessionName" : "mhm-foo",
                "projectPath" : "/a",
                "harnessType" : "claude-code",
                "harnessSessionId" : null,
                "createdAt" : "2026-08-01T00:00:00.123Z",
                "displayName" : null
              } ]
            }
            """, try readString(file))
        registry.remove("mhm-foo")
        XCTAssertEqual("{\n  \"sessions\" : [ ]\n}", try readString(file))
    }

    func testNewlyCreatedEntriesRoundTripExactly() {
        let file = dir.appendingPathComponent("sessions.json")
        let entry = SessionEntry.newlyCreated("mhm-now", "/a", .codex, nil)
        SessionRegistry.load(file).put(entry)
        XCTAssertEqual(entry, SessionRegistry.load(file).find("mhm-now"))
    }

    func testRenamedDisplayNameRoundTripsAndCanBeCleared() {
        let file = dir.appendingPathComponent("sessions.json")
        let registry = SessionRegistry.load(file)
        let entry = SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch)

        registry.put(entry.withDisplayName("  My useful name  "))
        XCTAssertEqual("My useful name", SessionRegistry.load(file).find("mhm-foo")!.displayName)

        registry.put(registry.find("mhm-foo")!.withDisplayName("  "))
        XCTAssertNil(SessionRegistry.load(file).find("mhm-foo")!.displayName)
    }

    func testPutOverwritesExistingEntryForSameSession() {
        let registry = SessionRegistry.load(dir.appendingPathComponent("sessions.json"))
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch))
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, "resumed-id", epoch))

        XCTAssertEqual(1, registry.sessions().count)
        XCTAssertEqual("resumed-id", registry.find("mhm-foo")!.harnessSessionId)
    }

    func testRecoveredHarnessSessionIdPersistsWithoutClobberingOtherMetadata() {
        let file = dir.appendingPathComponent("sessions.json")
        let registry = SessionRegistry.load(file)
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch, "My session"))

        registry.recordHarnessSessionId("mhm-foo", "  fd626959-efe0-414b-a3f5-9261602748ed  ")

        let saved = SessionRegistry.load(file).find("mhm-foo")!
        XCTAssertEqual("fd626959-efe0-414b-a3f5-9261602748ed", saved.harnessSessionId)
        XCTAssertEqual("My session", saved.displayName)
    }

    func testRemoveDropsTheEntryAndPersists() {
        let file = dir.appendingPathComponent("sessions.json")
        let registry = SessionRegistry.load(file)
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch))
        registry.remove("mhm-foo")

        XCTAssertTrue(registry.sessions().isEmpty)
        XCTAssertTrue(SessionRegistry.load(file).sessions().isEmpty)
    }

    func testCorruptFileIsToleratedAsEmpty() throws {
        let file = dir.appendingPathComponent("sessions.json")
        try writeString(file, "{ this is not valid json ][")

        let registry = SessionRegistry.load(file)
        XCTAssertTrue(registry.sessions().isEmpty)

        // and it's still usable — a subsequent mutation overwrites the garbage cleanly
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch))
        XCTAssertEqual(1, SessionRegistry.load(file).sessions().count)
    }

    func testCorruptFileIsBackedUpBeforeItCanBeOverwritten() throws {
        let file = dir.appendingPathComponent("sessions.json")
        let garbage = "{ this is not valid json ]["
        try writeString(file, garbage)

        _ = SessionRegistry.load(file)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backup = try XCTUnwrap(siblings.first { $0.hasPrefix("sessions.json.corrupt-") })
        XCTAssertEqual(garbage, try readString(dir.appendingPathComponent(backup)))
    }

    func testUnreadableFileThatCannotBeBackedUpIsNeverOverwritten() throws {
        let file = dir.appendingPathComponent("sessions.json")
        let original = "{\"sessions\": [{\"sessionName\": \"mhm-keep\"}]}"
        try writeString(file, original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path),
                      "permissions aren't enforced (running as root?)")

        let registry = SessionRegistry.load(file)
        XCTAssertTrue(registry.sessions().isEmpty)
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch))
        XCTAssertEqual(1, registry.sessions().count, "the run still works in memory")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(original, try readString(file))
    }

    func testMissingOrNullSessionsListLoadsEmpty() throws {
        let emptyObject = dir.appendingPathComponent("empty-object.json")
        try writeString(emptyObject, "{}")
        XCTAssertTrue(SessionRegistry.load(emptyObject).sessions().isEmpty)

        let nullSessions = dir.appendingPathComponent("null-sessions.json")
        try writeString(nullSessions, "{\"sessions\": null}")
        XCTAssertTrue(SessionRegistry.load(nullSessions).sessions().isEmpty)
    }

    func testNullEntryIsSkipped() throws {
        let file = dir.appendingPathComponent("sessions.json")
        try writeString(file, "{\"sessions\": [null]}")

        let registry = SessionRegistry.load(file)
        XCTAssertTrue(registry.sessions().isEmpty)

        // and it's still usable afterwards
        registry.put(SessionEntry("mhm-foo", "/a", .claudeCode, nil, epoch))
        XCTAssertEqual(1, SessionRegistry.load(file).sessions().count)
    }

    func testUnknownHarnessTypeEntryIsPreservedAcrossMutations() throws {
        let file = dir.appendingPathComponent("sessions.json")
        try writeString(file, """
            {"sessions": [
              {"sessionName": "mhm-foo", "projectPath": "/a", "harnessType": "claude-code",
               "harnessSessionId": "resume-foo", "createdAt": "2026-08-01T00:00:00Z"},
              {"sessionName": "mhm-future", "projectPath": "/b", "harnessType": "gemini-cli",
               "harnessSessionId": "resume-future", "createdAt": "2026-08-02T00:00:00Z"},
              {"sessionName": "mhm-bar", "projectPath": "/c", "harnessType": "cursor-agent",
               "harnessSessionId": null, "createdAt": "2026-08-03T00:00:00Z"}
            ]}

            """)

        let registry = SessionRegistry.load(file)
        XCTAssertEqual(2, registry.sessions().count)
        XCTAssertEqual("resume-foo", registry.find("mhm-foo")!.harnessSessionId)
        XCTAssertNotNil(registry.find("mhm-bar"))

        // a routine mutation must not destroy the entry this build can't read
        registry.put(SessionEntry("mhm-new", "/d", .claudeCode, nil, epoch))

        let saved = try readString(file)
        XCTAssertTrue(saved.contains("gemini-cli"))
        XCTAssertTrue(saved.contains("resume-future"))
        XCTAssertEqual(3, SessionRegistry.load(file).sessions().count)
    }

    func testPutUnderAPreservedUnknownEntrysKeySupersedesIt() throws {
        let file = dir.appendingPathComponent("sessions.json")
        try writeString(file, """
            {"sessions": [
              {"sessionName": "mhm-x", "projectPath": "/old", "harnessType": "gemini-cli",
               "harnessSessionId": "stale-id", "createdAt": "2026-08-01T00:00:00Z"}
            ]}

            """)

        let registry = SessionRegistry.load(file)
        XCTAssertTrue(registry.sessions().isEmpty) // unknown type — preserved, not bound

        // the user re-creates the session under this build's harness types: their
        // explicit action wins — the file must not carry two entries for mhm-x
        registry.put(SessionEntry("mhm-x", "/new", .claudeCode, "fresh-id", epoch))

        let saved = try readString(file)
        XCTAssertFalse(saved.contains("gemini-cli"))
        XCTAssertFalse(saved.contains("stale-id"))
        XCTAssertEqual(1, SessionRegistry.load(file).sessions().count)
        XCTAssertEqual("fresh-id", SessionRegistry.load(file).find("mhm-x")!.harnessSessionId)
    }

    func testNewerBuildFieldsOnABindableEntrySurviveASave() throws {
        let file = dir.appendingPathComponent("sessions.json")
        try writeString(file, """
            {"sessions": [
              {"sessionName": "mhm-foo", "projectPath": "/a", "harnessType": "claude-code",
               "harnessSessionId": "resume-foo", "createdAt": "2026-08-01T00:00:00Z",
               "newerBuildField": "must-survive"}
            ]}

            """)

        let registry = SessionRegistry.load(file)
        XCTAssertEqual(1, registry.sessions().count) // binds fine — the extra field is just dropped in memory

        // an unrelated mutation rewrites the file; the field this build doesn't know must ride along
        registry.put(SessionEntry("mhm-new", "/d", .claudeCode, nil, epoch))

        let saved = try readString(file)
        XCTAssertTrue(saved.contains("must-survive"))
        XCTAssertEqual("resume-foo", SessionRegistry.load(file).find("mhm-foo")!.harnessSessionId)
    }
}
