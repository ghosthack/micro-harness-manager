import XCTest
@testable import MicrohmCore

final class PhoneUploadsTests: XCTestCase {

    private var dir: URL!
    private let fixed = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mhm-uploads-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func uploads() -> PhoneUploads {
        var u = PhoneUploads(dir: dir)
        u.now = { [fixed] in fixed }
        return u
    }

    private func nameFor(_ name: String?, _ type: String?) -> String {
        uploads().fileName(name, type).replacingOccurrences(of: #"^\d{8}-\d{6}-[0-9a-f]{4}-"#, with: "",
                                                              options: .regularExpression)
    }

    func testNamesAreSafeInAPromptOrAShell() {
        XCTAssertEqual("Screen_Shot_2026-11-20_at_3.04_PM.png", nameFor("Screen Shot 2026-11-20 at 3.04 PM.png", nil))
        XCTAssertEqual("passwd", nameFor("../../etc/passwd", nil))
        XCTAssertEqual("evil.jpg", nameFor("C:\\dir\\evil.jpg", "image/jpeg"))
        XCTAssertEqual("x_y_rm_.txt", nameFor("x;y$(rm).txt", nil))
        XCTAssertEqual("upload.png", nameFor("", "image/png"))
        XCTAssertEqual("upload.jpg", nameFor(nil, "image/jpeg; q=1"))
        XCTAssertEqual("hidden", nameFor(".hidden", nil))
        XCTAssertEqual("IMG_0001.heic", nameFor("IMG_0001.HEIC", "image/heic"))
    }

    func testAnEmptyOrOversizedBodyIsNotKept() throws {
        XCTAssertThrowsError(try uploads().save(Data(), name: "a.png", contentType: nil))
        XCTAssertThrowsError(try uploads().save(Data(count: PhoneUploads.maxBytes + 1), name: "b.png", contentType: nil))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual([], files)
    }

    func testOldFilesAreRemovedAsNewOnesArrive() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.png")
        let recent = dir.appendingPathComponent("recent.png")
        try Data([1]).write(to: old)
        try Data([1]).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: fixed.addingTimeInterval(-PhoneUploads.keep - 3600)],
                                              ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: fixed.addingTimeInterval(-86400)],
                                              ofItemAtPath: recent.path)
        let saved = try uploads().save(Data([1]), name: "new.png", contentType: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }
}
