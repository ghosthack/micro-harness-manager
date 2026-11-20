import XCTest
@testable import MicrohmCore
import MicrohmMux

/// The log files themselves: rolling into compressed parts, and progress kept across a restart.
final class SessionLogsTests: XCTestCase {

    private var project: URL!
    private let now = IsoInstant.parse("2026-11-09T06:00:00Z")!
    private let same: (String) -> String = { $0 }

    override func setUpWithError() throws {
        project = try makeTempDir(self)
    }

    /// A capture whose scrollback has `added` lines in all, ending with `text`.
    private func scrolled(_ text: String, _ added: Int64) -> SessionCapture {
        let held = text.filter { $0 == "\n" }.count
        return SessionCapture(text: "$ \n", alive: true, foregroundCommand: "zsh", processId: 77, title: "",
                              columns: 80, rows: 24, outputBytes: 0, cursorVisible: true)
            .withHistory(CaptureHistory(text: text, held: held, added: added, alternateScreen: false))
    }

    private func numbered(_ from: Int, _ to: Int) -> String {
        (from...to).map { "row \($0)\n" }.joined()
    }

    private func gunzip(_ part: URL) throws -> String {
        String(decoding: try Gzip.decompress(Data(contentsOf: part)), as: UTF8.self)
    }

    private var folder: URL { project.appendingPathComponent(SessionLogs.FOLDER) }

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    func testTheLiveFileRollsIntoNumberedCompressedPartsAndNothingIsLost() throws {
        let log = try SessionLogs().open(project, "mhm-x")
        XCTAssertEqual(folder.appendingPathComponent("mhm-x.log").path, log.file.path)

        try log.record(scrolled(numbered(1, 1500), 1500), same, now)
        for from in stride(from: 1501, through: 9001, by: 1500) {
            try log.record(scrolled(numbered(from, from + 1499), log.since() + 1500), same, now)
        }
        XCTAssertEqual(10_500, log.since())
        let first = folder.appendingPathComponent("mhm-x.0001.log.gz")
        XCTAssertTrue(exists(first))
        XCTAssertFalse(exists(folder.appendingPathComponent("mhm-x.0002.log.gz")))
        XCTAssertEqual(numbered(1, 7500), try gunzip(first), "rolled before it would pass 8000 lines")
        XCTAssertEqual(numbered(7501, 10_500), try readString(log.file))

        // a restarted app picks up where the log left off, parts and all
        let again = try SessionLogs().open(project, "mhm-x")
        XCTAssertEqual(10_500, again.since())
        XCTAssertEqual(77, again.pid)
        try again.record(scrolled(numbered(10_501, 16_000), 16_000), same, now)
        XCTAssertEqual(numbered(7501, 10_500), try gunzip(folder.appendingPathComponent("mhm-x.0002.log.gz")),
                       "it knew how full the live file was")
        XCTAssertEqual(numbered(10_501, 16_000), try readString(again.file))
    }

    /// A full-screen capture showing `screen`, with no scrollback.
    private func fullScreen(_ screen: String) -> SessionCapture {
        SessionCapture(text: screen, alive: true, foregroundCommand: "grok", processId: 77, title: "",
                       columns: 80, rows: 24, outputBytes: 0, cursorVisible: true)
            .withHistory(CaptureHistory(text: "", held: 0, added: 0, alternateScreen: true))
    }

    func testAFullScreenProgramsLinesAreWrittenAsTheyAppearEachOnceAndWithoutItsChrome() throws {
        let log = try SessionLogs().open(project, "mhm-g")
        let chrome: (String) -> String = { screen in
            JavaText.lines(screen).filter { !$0.hasPrefix("status") }.map { $0 + "\n" }.joined()
        }
        try log.record(fullScreen("Grok\nstatus 1s\n"), chrome, now)
        try log.record(fullScreen("Grok\n1. one\nstatus 2s\n"), chrome, now.addingTimeInterval(1))
        try log.record(fullScreen("Grok\n1. one\n2. two\nstatus 3s\n"), chrome, now.addingTimeInterval(2))
        try log.record(fullScreen("Grok\n2. two\n3. thr\nstatus 4s\n"), chrome, now.addingTimeInterval(3))
        XCTAssertEqual("--- microhm · 2026-11-09T06:00:01Z · screen ---\nGrok\n1. one\n2. two\n",
                       try readString(log.file), "the bottom row waits: it may be still being drawn")
        try log.record(fullScreen("Grok\n2. two\n3. three\nstatus 5s\n"), chrome, now.addingTimeInterval(4))
        try log.record(fullScreen("Grok\n2. two\n3. three\nstatus 6s\n"), chrome, now.addingTimeInterval(5))
        let expected = "--- microhm · 2026-11-09T06:00:01Z · screen ---\nGrok\n1. one\n2. two\n3. three\n"
        XCTAssertEqual(expected, try readString(log.file), "until it holds")

        // a restarted app remembers what it wrote lately
        let again = try SessionLogs().open(project, "mhm-g")
        try again.record(fullScreen("Grok\n3. three\n4. four\n"), chrome, now.addingTimeInterval(9))
        try again.record(fullScreen("Grok\n3. three\n4. four\n"), chrome, now.addingTimeInterval(9))
        XCTAssertEqual(expected + "--- microhm · 2026-11-09T06:00:09Z · screen ---\n4. four\n", try readString(log.file))
    }

    /// `git clean -fdx` in the project takes the folder with it: the log starts again there,
    /// without losing the lines it could not write meanwhile.
    func testADeletedFolderIsMadeAgainAndTheLogGoesOn() throws {
        let log = try SessionLogs().open(project, "mhm-x")
        try log.record(scrolled(numbered(1, 3), 3), same, now)
        try FileManager.default.removeItem(at: folder)
        try log.record(scrolled(numbered(4, 5), 5), same, now)
        XCTAssertEqual(numbered(4, 5), try readString(log.file))
        XCTAssertEqual("*\n", try readString(folder.appendingPathComponent(".gitignore")))
        XCTAssertEqual(5, try SessionLogs().open(project, "mhm-x").since())
    }

    func testAFailedWriteLeavesTheLinesToBeWrittenNextTime() throws {
        let log = try SessionLogs().open(project, "mhm-x")
        try log.record(scrolled(numbered(1, 3), 3), same, now)
        try FileManager.default.removeItem(at: folder)
        try writeString(folder, "in the way") // a file where the folder was: nothing can be written
        XCTAssertThrowsError(try log.record(scrolled(numbered(4, 5), 5), same, now))
        XCTAssertEqual(3, log.since(), "not counted as written")
        try FileManager.default.removeItem(at: folder)
        try log.record(scrolled(numbered(4, 5), 5), same, now)
        XCTAssertEqual(numbered(4, 5), try readString(log.file))
    }

    /// A project is not trusted: a planted link must not send sessions' output elsewhere.
    func testLinksPlantedInTheProjectAreNotWrittenThrough() throws {
        let elsewhere = try makeTempDir(self)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try SessionLogs().open(project, "mhm-x"))
        XCTAssertEqual(0, try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).count)

        try FileManager.default.removeItem(at: folder)
        try createDirectories(folder)
        let victim = try writeString(elsewhere.appendingPathComponent("victim"), "mine\n")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("mhm-x.log"),
                                                   withDestinationURL: victim)
        let log = try SessionLogs().open(project, "mhm-x")
        XCTAssertThrowsError(try log.record(scrolled(numbered(1, 2), 2), same, now))
        XCTAssertEqual("mine\n", try readString(victim))
    }

    func testAnIdleSessionDoesNotRewriteItsState() throws {
        let log = try SessionLogs().open(project, "mhm-x")
        try log.record(scrolled(numbered(1, 3), 3), same, now)
        let state = folder.appendingPathComponent(".mhm-x.state")
        try setLastModified(state, millis: 1000)
        try log.record(scrolled("", 3), same, now.addingTimeInterval(1))
        let modified = try FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate] as! Date
        XCTAssertEqual(1000, Int64((modified.timeIntervalSince1970 * 1000).rounded()))
    }

    private func permissions(_ url: URL) -> mode_t {
        var st = stat()
        lstat(url.path, &st)
        return st.st_mode & 0o777
    }

    func testTheFolderAndTheFilesMadeInItAreTheOwnersAlone() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755]) // left open by an earlier version
        chmod(folder.path, 0o755)

        let log = try SessionLogs().open(project, "mhm-p")
        XCTAssertEqual(0o700, permissions(folder), "an existing folder is closed too")
        try log.record(scrolled(numbered(1, 5000), 5000), same, now)
        try log.record(scrolled(numbered(5001, 10_000), 10_000), same, now)
        for name in ["mhm-p.log", ".mhm-p.state", ".gitignore", "mhm-p.0001.log.gz"] {
            XCTAssertEqual(0o600, permissions(folder.appendingPathComponent(name)), name)
        }

        // made again after something deleted it: closed again
        try FileManager.default.removeItem(at: folder)
        try log.record(scrolled(numbered(10_001, 10_002), 10_002), same, now)
        XCTAssertEqual(0o700, permissions(folder))
        XCTAssertEqual(0o600, permissions(log.file))
    }

    func testNamesAreKeptToSafeCharacters() {
        XCTAssertEqual(folder.appendingPathComponent("a_b_c.log").path, SessionLogs.file(project, "a/b c").path)
    }
}
