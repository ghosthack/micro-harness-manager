import Darwin
import Foundation
import XCTest
@testable import MicrohmCore

/// `HttpServer` limits that no endpoint test reaches directly.
final class HttpServerTests: XCTestCase {

    private var server: HttpServer!

    override func setUpWithError() throws {
        server = HttpServer(port: 0, loopbackOnly: true, name: "http-test")
        try server.start { ex in
            guard let body = try ex.readBody(limit: 1024, drainLimit: 64 * 1024) else {
                try ex.send(413, "text/plain", Data("too large".utf8))
                return
            }
            try ex.send(200, "text/plain", Data("got \(body.count)".utf8))
        }
    }

    override func tearDown() {
        server.close()
    }

    /// A chunk that declares more than the limit is refused from its size line: the server
    /// drains at most the drain cap of it and answers, rather than reading (and holding)
    /// the whole declared chunk first.
    func testAnOversizedChunkIsRefusedWithoutReadingItWhole() throws {
        let socket = try SvcSocket(port: server.port)
        // declares 256 MiB, sends 256 KiB and then waits: only a bounded read can answer
        try socket.send(Array("POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n10000000\r\n".utf8))
        try socket.send([UInt8](repeating: 0x61, count: 256 * 1024))
        XCTAssertEqual(413, try socket.readHead().0)
    }

    func testChunksWithinTheLimitAreRead() throws {
        let socket = try SvcSocket(port: server.port)
        try socket.send(Array(("POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                               + "200\r\n" + String(repeating: "a", count: 512) + "\r\n"
                               + "200\r\n" + String(repeating: "b", count: 512) + "\r\n0\r\n\r\n").utf8))
        let (status, headers) = try socket.readHead()
        XCTAssertEqual(200, status)
        XCTAssertEqual("got 1024", socket.readBody(headers))
        // one byte more is over
        let again = try SvcSocket(port: server.port)
        try again.send(Array(("POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                              + "400\r\n" + String(repeating: "a", count: 1024) + "\r\n"
                              + "1\r\nb\r\n0\r\n\r\n").utf8))
        XCTAssertEqual(413, try again.readHead().0)
    }

    func testCloseStopsAcceptingAndEndsOpenConnections() throws {
        let idle = try SvcSocket(port: server.port)
        try idle.send(Array("POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nok".utf8))
        XCTAssertEqual(200, try idle.readHead().0)
        let port = server.port
        server.close()
        XCTAssertFalse(server.isRunning)
        XCTAssertThrowsError(try SvcSocket(port: port).readHead())
    }
}
