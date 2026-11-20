import Darwin
import Foundation
import XCTest
@testable import MicrohmShared

/// The logger must never take the process down: a write that fails (a full disk, an I/O
/// error, a log that is a pipe nobody reads any more) is dropped.
final class LogTests: XCTestCase {

    func testAFailingWriteIsDroppedAndTheLogCarriesOn() throws {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(0, pipe(&ends))
        let log = Log()
        log.open(URL(fileURLWithPath: "/dev/fd/\(ends[1])"))
        Darwin.close(ends[1])
        log.write("INFO", "while someone reads", "test")
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(ends[0], &buffer, buffer.count)
        XCTAssertTrue(String(decoding: buffer[0..<max(0, n)], as: UTF8.self).contains("[test] while someone reads"))
        Darwin.close(ends[0]) // the reader goes: every further write is EPIPE
        for i in 0..<3 {
            log.write("INFO", "into a broken pipe \(i)", "test")
        }

        // still usable once pointed at a file
        let file = try makeTempDir(self).appendingPathComponent("app.log")
        log.open(file)
        log.write("WARN", "after the failures", "test")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("WARN [test] after the failures"), text)
        var st = stat()
        XCTAssertEqual(0, stat(file.path, &st))
        XCTAssertEqual(0o600, st.st_mode & 0o777)
    }
}
