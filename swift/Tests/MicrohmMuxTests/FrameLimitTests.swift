import Darwin
import XCTest
@testable import MicrohmMux

/// Payloads past `Frame.MAX_PAYLOAD`: an attach snapshot, a capture reply and a paste that
/// large must be chunked or refused, never trap the daemon or the client; and a request
/// whose reply never comes times out instead of blocking for ever.
final class FrameLimitTests: XCTestCase {

    private var temp: TempHome!
    private var server: SessionServer!
    private var client: SessionServerClient!

    override func setUpWithError() throws {
        temp = TempHome()
        let options = ServeOptions.defaults(temp.home).withKeepAlive(true)
        server = SessionServer(options: options, manager: SessionManagerImpl(historyLines: options.historyLines))
        XCTAssertTrue(try server.start())
        client = SessionServerClient(home: temp.home, spawn: false)
    }

    override func tearDown() {
        server?.close()
        temp.remove()
    }

    func testAFrameOverTheLimitThrowsInsteadOfTrapping() {
        XCTAssertThrowsError(try Frame(.DATA_OUT, [UInt8](repeating: 0x41, count: Frame.MAX_PAYLOAD + 1)))
        XCTAssertNoThrow(try Frame(.DATA_OUT, [UInt8](repeating: 0x41, count: Frame.MAX_PAYLOAD)))
    }

    /// Plain history lines, then a screen whose every cell has its own truecolor fg and bg:
    /// both the attach redraw and an ANSI capture with history come to well over 16 MB.
    private func startColourfulSession(_ name: String, columns: Int, rows: Int) throws {
        let historyLine = [UInt8](repeating: 0x68, count: columns) + [13, 10]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(40 << 20)
        for _ in 0..<ServeOptions.DEFAULT_HISTORY_LINES {
            bytes += historyLine
        }
        for y in 0..<rows {
            for x in 0..<columns {
                let r = (x * 7 + y) % 256, g = (x * 13 + y * 3) % 256, b = (x * 29 + y * 5) % 256
                bytes += Array("\u{1b}[38;2;\(r);\(g);\(b);48;2;\(255 - r);\(255 - g);\(255 - b)m".utf8)
                bytes.append(UInt8(65 + x % 26))
            }
            if y < rows - 1 {
                bytes += [27, 91, 48, 109, 13, 10] // ESC [ 0 m CR LF
            }
        }
        let file = temp.root.appendingPathComponent("colours")
        try Data(bytes).write(to: file)
        try client.newSession(name, workdir: temp.workdir(), columns: columns, rows: rows,
                              command: ["/bin/sh", "-c", "cat '\(file.path)'; exec sleep 600"])
        try awaitCondition(120, "the session to take in all its output") {
            (try client.capture(name)?.outputBytes ?? 0) >= Int64(bytes.count)
        }
    }

    func testAnOversizedAttachRedrawIsChunkedAndAnOversizedCaptureIsAnError() throws {
        try startColourfulSession("big", columns: 2000, rows: 200)

        // The redraw goes out as several frames, none over the limit; the daemon lives on.
        let raw = try RawConnection(temp.home)
        defer { raw.close() }
        let ok = try XCTUnwrap(try raw.request(MuxProtocol.OP_ATTACH,
                                               Json.object().with(MuxProtocol.F_NAME, "big")
                                                   .with(MuxProtocol.F_COLUMNS, 2000).with(MuxProtocol.F_ROWS, 200)))
        XCTAssertEqual(.bool(true), ok[MuxProtocol.F_OK])
        var total = 0
        var frames = 0
        while total <= Frame.MAX_PAYLOAD {
            let frame = try XCTUnwrap(try raw.codec.read(), "the redraw ended after \(total) bytes")
            XCTAssertEqual(.DATA_OUT, frame.type)
            XCTAssertLessThanOrEqual(frame.payload.count, Frame.MAX_PAYLOAD)
            total += frame.payload.count
            frames += 1
        }
        XCTAssertGreaterThan(frames, 1)
        XCTAssertNotNil(try client.ping())

        // A capture reply too large for a frame is an error reply, not a dead daemon.
        XCTAssertThrowsError(try client.capture("big", format: .ANSI, historyLines: 2000)) {
            XCTAssertTrue("\($0)".contains("too large"), "\($0)")
        }
        XCTAssertNotNil(try client.capture("big"))
        XCTAssertNotNil(try client.ping())
    }

    func testAPasteOverAFrameIsSentInPieces() throws {
        try client.newSession("p", workdir: temp.workdir(), columns: 80, rows: 24,
                              command: ["/bin/sh", "-c", "exec sleep 600"])
        let attached = try client.attach("p", columns: 80, rows: 24)
        defer { attached.close() }
        try attached.write([UInt8](repeating: 0x61, count: Frame.MAX_PAYLOAD + 4096))
        XCTAssertTrue(attached.isConnected)
        try attached.resize(columns: 81, rows: 24) // the connection still takes frames
        try awaitCondition(10, "the resize to arrive") { try client.list().first?.columns == 81 }
        XCTAssertNotNil(try client.ping())
    }

    func testARequestWhoseReplyNeverComesTimesOut() throws {
        // A "server" that accepts and never answers (a wedged or stopped daemon).
        let home = temp.root.appendingPathComponent("wedged", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let listener = try UnixListener(bind: ServerHome.socket(home).path)
        defer { listener.close() }
        let accepted = NSLock()
        var held: [UnixSocket] = []
        let acceptor = Thread {
            while let socket = try? listener.accept() {
                accepted.lock(); held.append(socket); accepted.unlock()
            }
        }
        acceptor.start()
        defer { accepted.lock(); held.forEach { $0.close() }; accepted.unlock() }

        let wedged = SessionServerClient(home: home, spawn: false)
        wedged.requestTimeout = 0.5
        let started = Date()
        XCTAssertThrowsError(try wedged.list()) {
            XCTAssertTrue("\($0)".contains("timed out"), "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
