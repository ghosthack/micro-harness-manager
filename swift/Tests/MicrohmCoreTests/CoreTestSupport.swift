import Foundation
import XCTest
@testable import MicrohmCore

/// Test clock advanced explicitly by the test (Java's `testutil.MutableClock`).
final class MutableClock: MicrohmClock, @unchecked Sendable {
    private var now = IsoInstant.parse("2026-08-17T00:00:00Z")!

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    func instant() -> Date {
        now
    }
}

/// `Instant.EPOCH`.
let epoch = Date(timeIntervalSince1970: 0)

/// A fresh temporary directory (JUnit's `@TempDir`), removed when the test ends. Its path
/// is the real one (`/private/var/…`), as `toRealPath()` would give.
func makeTempDir(_ test: XCTestCase) throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("microhm-core-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let real = URL(fileURLWithPath: realPath(base.path), isDirectory: true)
    test.addTeardownBlock {
        try? FileManager.default.removeItem(at: real)
    }
    return real
}

func realPath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `Files.writeString`.
@discardableResult
func writeString(_ url: URL, _ text: String) throws -> URL {
    try Data(text.utf8).write(to: url)
    return url
}

/// `Files.writeString(…, APPEND)`.
func appendString(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

func readString(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

@discardableResult
func createDirectories(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `Files.setLastModifiedTime(path, FileTime.fromMillis(millis))`.
func setLastModified(_ url: URL, millis: Int64) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(millis) / 1000)],
                                          ofItemAtPath: url.path)
}
