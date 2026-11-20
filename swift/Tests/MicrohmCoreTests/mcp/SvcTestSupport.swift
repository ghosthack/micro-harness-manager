import Darwin
import Foundation
import XCTest
@testable import MicrohmCore

/// A response as a raw HTTP/1.1 client read it.
struct SvcResponse {
    let status: Int
    let headers: [(String, String)]
    let body: String

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func headers(_ name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }

    var json: CoreJSON {
        (try? CoreJSON.parse(body)) ?? .missing
    }
}

struct SvcConnectError: Error {}

/// A blocking socket to 127.0.0.1 that reads lines and de-chunks a streamed body: what the
/// Java tests did with `HttpClient`, without anything rewriting headers (URLSession would
/// set its own `Origin`/`Connection`/cookies).
final class SvcSocket {
    let fd: Int32
    private var buffer: [UInt8] = []
    /// Bytes left in the current chunk of a chunked body; nil while not chunked.
    private var chunkLeft: Int?
    private var chunked = false
    private var bodyEnded = false

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            Darwin.close(fd)
            throw SvcConnectError()
        }
    }

    deinit {
        Darwin.close(fd)
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
    }

    func send(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { throw SvcConnectError() }
            off += n
        }
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n <= 0 { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    /// A raw CRLF/LF line; nil at EOF.
    private func rawLine() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 10) {
                var line = Array(buffer[0..<i])
                buffer.removeFirst(i + 1)
                if line.last == 13 { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            if !fill() { return nil }
        }
    }

    private func rawRead(_ n: Int) -> [UInt8] {
        while buffer.count < n {
            if !fill() { break }
        }
        let k = min(n, buffer.count)
        let out = Array(buffer[0..<k])
        buffer.removeFirst(k)
        return out
    }

    /// Status line and headers.
    func readHead() throws -> (Int, [(String, String)]) {
        guard let statusLine = rawLine() else { throw SvcConnectError() }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw SvcConnectError() }
        var headers: [(String, String)] = []
        while let line = rawLine(), !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        if status == 100 {
            return try readHead()
        }
        chunked = headers.contains { $0.0.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame && $0.1.contains("chunked") }
        return (status, headers)
    }

    /// The next body bytes of a chunked body (empty at its end).
    private func bodyBytes() -> [UInt8] {
        if bodyEnded { return [] }
        if chunkLeft == nil || chunkLeft == 0 {
            if chunkLeft == 0 { _ = rawLine() } // CRLF after a chunk
            guard let sizeLine = rawLine(), let size = Int(sizeLine.split(separator: ";").first.map(String.init) ?? "", radix: 16) else {
                bodyEnded = true
                return []
            }
            if size == 0 {
                bodyEnded = true
                return []
            }
            chunkLeft = size
        }
        let got = rawRead(chunkLeft!)
        chunkLeft! -= got.count
        if got.isEmpty { bodyEnded = true }
        return got
    }

    private var bodyBuffer: [UInt8] = []

    /// One line of a chunked body (an SSE stream); nil once it ended.
    func bodyLine() -> String? {
        while true {
            if let i = bodyBuffer.firstIndex(of: 10) {
                let line = Array(bodyBuffer[0..<i])
                bodyBuffer.removeFirst(i + 1)
                return String(decoding: line, as: UTF8.self)
            }
            let more = bodyBytes()
            if more.isEmpty { return nil }
            bodyBuffer.append(contentsOf: more)
        }
    }

    /// The whole body (after `readHead`), by length, chunks or EOF.
    func readBody(_ headers: [(String, String)], head: Bool = false) -> String {
        if head { return "" }
        if chunked {
            var all: [UInt8] = []
            while true {
                let b = bodyBytes()
                if b.isEmpty { break }
                all += b
            }
            return String(decoding: all, as: UTF8.self)
        }
        if let length = headers.first(where: { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }).flatMap({ Int($0.1) }) {
            return String(decoding: rawRead(length), as: UTF8.self)
        }
        var all = buffer
        buffer = []
        while fill() { all += buffer; buffer = [] }
        return String(decoding: all, as: UTF8.self)
    }

    static func requestBytes(_ method: String, _ target: String, _ headers: [(String, String)], _ body: String?,
                             port: Int) -> [UInt8] {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: localhost:\(port)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        let bodyBytes = Array((body ?? "").utf8)
        if body != nil { head += "Content-Length: \(bodyBytes.count)\r\n" }
        head += "\r\n"
        return Array(head.utf8) + bodyBytes
    }
}

enum SvcHttp {

    /// One request on its own connection.
    static func request(_ port: Int, _ method: String, _ target: String, headers: [(String, String)] = [],
                        body: String? = nil) throws -> SvcResponse {
        let socket = try SvcSocket(port: port)
        try socket.send(SvcSocket.requestBytes(method, target, headers + [("Connection", "close")], body, port: port))
        let (status, responseHeaders) = try socket.readHead()
        return SvcResponse(status: status, headers: responseHeaders, body: socket.readBody(responseHeaders, head: method == "HEAD"))
    }

    /// `url` split into port and target (`http://127.0.0.1:P/…`).
    static func split(_ url: String) -> (Int, String) {
        let rest = url.dropFirst("http://".count)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let hostPort = rest[..<slash]
        let port = Int(hostPort.split(separator: ":").last ?? "0") ?? 0
        let target = slash == rest.endIndex ? "/" : String(rest[slash...])
        return (port, target)
    }

    static func post(_ url: String, _ body: String, _ headers: [(String, String)] = []) throws -> SvcResponse {
        let (port, target) = split(url)
        return try request(port, "POST", target, headers: [("Content-Type", "application/json"),
                                                            ("Accept", "application/json, text/event-stream")] + headers,
                           body: body)
    }

    /// A streamed GET: the open socket after its head.
    static func stream(_ port: Int, _ target: String, headers: [(String, String)]) throws -> (SvcSocket, Int, [(String, String)]) {
        let socket = try SvcSocket(port: port)
        try socket.send(SvcSocket.requestBytes("GET", target, headers, nil, port: port))
        let (status, h) = try socket.readHead()
        return (socket, status, h)
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func svcAwait(_ timeout: TimeInterval = 15, _ what: String = "condition", file: StaticString = #filePath,
              line: UInt = #line, _ condition: () throws -> Bool) rethrows {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if try condition() { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
    if try condition() { return }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

/// A short private directory under /tmp (Unix socket paths have a 104-byte ceiling),
/// removed when the test ends.
func svcShortTempDir(_ test: XCTestCase) -> URL {
    var template = Array("/tmp/mhm-svc-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    precondition(made != nil, "mkdtemp failed")
    let url = URL(fileURLWithPath: String(cString: template), isDirectory: true).resolvingSymlinksInPath()
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// A thread-safe list for callbacks from other threads.
final class SvcList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
    }

    var all: [T] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    var count: Int { all.count }
}

/// `JsonNode.at(pointer)`.
extension CoreJSON {
    func svcAt(_ pointer: String) -> CoreJSON {
        var node = self
        for part in pointer.split(separator: "/") {
            if let index = Int(part), node.isArray {
                node = node.path(index)
            } else {
                node = node.path(String(part))
            }
        }
        return node
    }
}
