import Darwin
import Foundation
import MicrohmShared

/// A small HTTP/1.1 server over BSD sockets, a thread per connection — the shape of the
/// JDK's `HttpServer` the Java app used for the MCP server and the phone page. It does
/// what those two need and no more: keep-alive, `Content-Length` and chunked request
/// bodies (with `Expect: 100-continue`), size limits on the head and the body, fixed-length
/// responses, and chunked streamed responses for Server-Sent Events.
///
/// `close()` stops accepting, shuts every open connection down (unblocking a stream's
/// write or a keep-alive read), and waits briefly for their threads to finish.
public final class HttpServer: @unchecked Sendable {

    /// Request line plus headers, at most.
    static let MAX_HEAD_BYTES = 64 * 1024
    static let MAX_HEADERS = 100
    /// How long a kept-alive connection may sit idle, and a read or write may stall.
    static let IDLE_TIMEOUT: TimeInterval = 60

    public typealias Handler = (HttpExchange) throws -> Void

    private let requestedPort: Int
    private let loopbackOnly: Bool
    private let name: String
    private let lock = NSCondition()
    private var listenFd: Int32 = -1
    private var boundPort = -1
    private var running = false
    private var connections: Set<Int32> = []
    private var activeThreads = 0

    /// - port: 0 picks a free one (see `port`)
    /// - loopbackOnly: bind 127.0.0.1 (the MCP server) rather than every interface (the
    ///   phone page: IPv4 and IPv6)
    public init(port: Int, loopbackOnly: Bool, name: String) {
        self.requestedPort = port
        self.loopbackOnly = loopbackOnly
        self.name = name
    }

    /// The bound port once started, else -1.
    public var port: Int {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Binds and starts accepting; throws when the port is taken.
    public func start(_ handler: @escaping Handler) throws {
        let (fd, port) = try bind()
        lock.lock()
        listenFd = fd
        boundPort = port
        running = true
        lock.unlock()
        let acceptor = Thread { [self] in acceptLoop(fd, handler) }
        acceptor.name = "\(name)-accept"
        acceptor.start()
    }

    /// Stops serving; idempotent. Open connections are shut down, and their threads given up
    /// to `wait` seconds to end.
    public func close(wait: TimeInterval = 1) {
        lock.lock()
        let fd = listenFd
        listenFd = -1
        running = false
        let open = connections
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for c in open {
            shutdown(c, SHUT_RDWR)
        }
        let deadline = Date().addingTimeInterval(wait)
        lock.lock()
        while activeThreads > 0 && Date() < deadline {
            _ = lock.wait(until: deadline)
        }
        lock.unlock()
    }

    private func bind() throws -> (Int32, Int) {
        func fail(_ what: String) -> Error {
            HttpError("\(what) port \(requestedPort): \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        if !loopbackOnly {
            // every interface, IPv4 and IPv6 alike
            let fd = socket(AF_INET6, SOCK_STREAM, 0)
            if fd >= 0 {
                var off: Int32 = 0
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = in_port_t(UInt16(requestedPort).bigEndian)
                addr.sin6_addr = in6addr_any
                let bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                if bound != 0 {
                    let error = fail("cannot bind")
                    Darwin.close(fd)
                    throw error
                }
                return try listenOn(fd)
            }
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("cannot open a socket for") }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(requestedPort).bigEndian)
        addr.sin_addr.s_addr = loopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let error = fail("cannot bind")
            Darwin.close(fd)
            throw error
        }
        return try listenOn(fd)
    }

    private func listenOn(_ fd: Int32) throws -> (Int32, Int) {
        if listen(fd, 64) != 0 {
            let error = HttpError("cannot listen: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let family = storage.ss_family
        let port: UInt16 = withUnsafePointer(to: &storage) { p in
            if family == sa_family_t(AF_INET6) {
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        return (fd, Int(port))
    }

    private func acceptLoop(_ fd: Int32, _ handler: @escaping Handler) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED {
                    continue
                }
                if isRunning && errno == EMFILE {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                return
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: Int(HttpServer.IDLE_TIMEOUT), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            lock.lock()
            if !running {
                lock.unlock()
                Darwin.close(client)
                return
            }
            connections.insert(client)
            activeThreads += 1
            lock.unlock()
            let thread = Thread { [self] in
                serve(client, handler)
                lock.lock()
                connections.remove(client)
                activeThreads -= 1
                lock.broadcast()
                lock.unlock()
                Darwin.close(client)
            }
            thread.name = "\(name)-conn"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Requests on one connection, until it closes or must close.
    private func serve(_ fd: Int32, _ handler: Handler) {
        let connection = HttpConnection(fd)
        while isRunning {
            let exchange: HttpExchange
            do {
                guard let request = try connection.readRequest() else { return }
                exchange = HttpExchange(connection, request, server: self)
            } catch let e as HttpError {
                if let status = e.status {
                    try? connection.writeSimple(status, e.message)
                }
                return
            } catch {
                return
            }
            do {
                try handler(exchange)
                try exchange.finish()
            } catch {
                Log.debug("\(name): exchange failed: \(error)", tag: "http")
                if !exchange.responseStarted {
                    try? exchange.send(500, "text/plain", Data("internal error".utf8))
                }
                return
            }
            if !exchange.keepAlive {
                return
            }
        }
    }
}

/// An HTTP-level failure; `status` is what to answer with, if anything.
public struct HttpError: Error, CustomStringConvertible {
    public let message: String
    public let status: Int?

    init(_ message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// A request's head as parsed.
struct HttpRequest {
    let method: String
    let target: String
    let version: String
    let headers: [(String, String)]
}

/// The buffered byte stream of one connection.
final class HttpConnection {
    let fd: Int32
    private var buffer: [UInt8] = []
    private var start = 0

    init(_ fd: Int32) {
        self.fd = fd
    }

    private var available: Int { buffer.count - start }

    /// Reads more from the socket; false at EOF (or an error, a timeout included).
    private func fill() -> Bool {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                return true
            }
            if n < 0 && errno == EINTR {
                continue
            }
            return false
        }
    }

    /// The next request's head; nil when the peer closed (or idled out) between requests.
    func readRequest() throws -> HttpRequest? {
        // relative to `start`: `fill` may compact the buffer and move it
        var scanned = 0
        while true {
            if let end = headEnd(from: start + scanned) {
                let head = String(decoding: buffer[start..<end], as: UTF8.self)
                start = end + 4
                return try parse(head)
            }
            if available > HttpServer.MAX_HEAD_BYTES {
                throw HttpError("request head too large", status: 431)
            }
            scanned = Swift.max(0, available - 3)
            if !fill() {
                if available > 0 {
                    throw HttpError("connection closed mid-request")
                }
                return nil
            }
        }
    }

    private func headEnd(from: Int) -> Int? {
        var i = max(from, start)
        while i + 3 < buffer.count {
            if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
                return i
            }
            i += 1
        }
        return nil
    }

    private func parse(_ head: String) throws -> HttpRequest {
        var lines = head.components(separatedBy: "\r\n")
        // tolerate leading blank lines (RFC 9112 §2.2)
        while lines.first == "" { lines.removeFirst() }
        guard let requestLine = lines.first else { throw HttpError("empty request", status: 400) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw HttpError("bad request line", status: 400)
        }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HttpError("bad header", status: 400) }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            if headers.count > HttpServer.MAX_HEADERS {
                throw HttpError("too many headers", status: 431)
            }
        }
        return HttpRequest(method: String(parts[0]), target: String(parts[1]), version: String(parts[2]),
                           headers: headers)
    }

    /// Up to `count` bytes (fewer only at EOF).
    func read(_ count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(count, 1 << 20))
        while out.count < count {
            if available == 0 && !fill() {
                break
            }
            let n = min(count - out.count, available)
            out.append(contentsOf: buffer[start..<(start + n)])
            start += n
        }
        return out
    }

    /// One CRLF-terminated line (without it); nil at EOF or past `max` bytes.
    func readLine(max: Int = 8192) -> String? {
        var scanned = 0 // relative to `start`, which `fill` may move
        while true {
            while start + scanned + 1 < buffer.count {
                if buffer[start + scanned] == 13 && buffer[start + scanned + 1] == 10 {
                    let line = String(decoding: buffer[start..<(start + scanned)], as: UTF8.self)
                    start += scanned + 2
                    return line
                }
                scanned += 1
            }
            if available > max || !fill() {
                return nil
            }
        }
    }

    func write(_ bytes: [UInt8]) throws {
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                throw HttpError("write failed: \(String(cString: strerror(errno)))")
            }
            written += n
        }
    }

    /// A bare response for a request that could not even be parsed.
    func writeSimple(_ status: Int, _ message: String) throws {
        let body = Array(message.utf8)
        try write(Array(("HTTP/1.1 \(status) \(HttpExchange.reason(status))\r\nContent-Type: text/plain\r\n"
                         + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8) + body)
    }
}

/// One request and its response. The handler reads the body at most once
/// (`readBody`), then either `send`s a whole response or `startStream`s a chunked one and
/// `write`s to it. A body the handler did not read is drained (or the connection closed)
/// before the next request.
public final class HttpExchange: @unchecked Sendable {

    public let method: String
    /// The request target's path, still percent-encoded.
    public let rawPath: String
    /// The query after `?`, still percent-encoded; nil when there is none.
    public let rawQuery: String?
    public let requestHeaders: [(String, String)]
    /// Headers to send with the response (`Content-Type` and `Content-Length` are added by
    /// `send`).
    public var responseHeaders: [(String, String)] = []

    private let connection: HttpConnection
    private weak var server: HttpServer?
    private let version: String
    private var bodyRead = false
    private var bodyComplete = true
    private var continueOwed = false
    private(set) var responseStarted = false
    private var streaming = false
    private(set) var keepAlive: Bool
    private var contentLength: Int64?
    private let chunkedRequest: Bool

    init(_ connection: HttpConnection, _ request: HttpRequest, server: HttpServer) {
        self.connection = connection
        self.server = server
        self.method = request.method
        self.version = request.version
        self.requestHeaders = request.headers
        let target = request.target
        if let q = target.firstIndex(of: "?") {
            rawPath = String(target[..<q])
            rawQuery = String(target[target.index(after: q)...])
        } else {
            rawPath = target
            rawQuery = nil
        }
        let connectionHeader = request.headers.first { $0.0.caseInsensitiveCompare("Connection") == .orderedSame }?.1
            .lowercased() ?? ""
        keepAlive = request.version == "HTTP/1.1" ? !connectionHeader.contains("close") : connectionHeader.contains("keep-alive")
        let transfer = request.headers.first { $0.0.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }?.1
        chunkedRequest = transfer?.lowercased().contains("chunked") ?? false
        if !chunkedRequest, let length = request.headers.first(where: {
            $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame
        })?.1 {
            contentLength = Int64(length.trimmingCharacters(in: .whitespaces))
            if contentLength == nil || contentLength! < 0 {
                keepAlive = false
                contentLength = 0
            }
        }
        bodyComplete = !chunkedRequest && (contentLength ?? 0) == 0
        continueOwed = !bodyComplete && (header("Expect")?.lowercased() == "100-continue")
    }

    /// The decoded path (`%XX` escapes resolved; `+` kept).
    public var path: String {
        rawPath.removingPercentEncoding ?? rawPath
    }

    /// The first value of `name` (case-insensitive), or nil.
    public func header(_ name: String) -> String? {
        requestHeaders.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// Every value of `name`.
    public func headers(_ name: String) -> [String] {
        requestHeaders.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }

    /// The declared body length; nil for a chunked body or none.
    public var declaredLength: Int64? { contentLength }

    /// The body, or nil when it is over `limit` bytes. What the client is still sending of
    /// an oversized body is read and discarded, up to `drainLimit` bytes, so the error
    /// response reaches it (closing on unread bytes resets the connection, and the client
    /// never sees the status); past that the connection is closed after the response.
    public func readBody(limit: Int, drainLimit: Int64 = 16 << 20) throws -> Data? {
        if bodyRead {
            return Data()
        }
        bodyRead = true
        if bodyComplete {
            return Data()
        }
        if let length = contentLength, length > Int64(limit) {
            if continueOwed {
                // never invited: the client sends nothing more, and the connection ends
                continueOwed = false
                keepAlive = false
                return nil
            }
            drain(length, drainLimit)
            return nil
        }
        try sendContinueIfOwed()
        if let length = contentLength {
            let bytes = connection.read(Int(length))
            bodyComplete = true
            if bytes.count < Int(length) {
                keepAlive = false
                throw HttpError("connection closed mid-body")
            }
            return Data(bytes)
        }
        // chunked
        var body: [UInt8] = []
        var over = false
        var drained: Int64 = 0
        while true {
            guard let sizeLine = connection.readLine() else {
                keepAlive = false
                throw HttpError("bad chunked body")
            }
            let hex = sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(hex, radix: 16), size >= 0 else {
                keepAlive = false
                throw HttpError("bad chunk size")
            }
            if size == 0 {
                // trailers
                while let line = connection.readLine(), !line.isEmpty {}
                break
            }
            let chunk = connection.read(size)
            _ = connection.readLine()
            if chunk.count < size {
                keepAlive = false
                throw HttpError("connection closed mid-body")
            }
            if over || body.count + size > limit {
                over = true
                drained += Int64(size)
                body.removeAll()
                if drained > drainLimit {
                    keepAlive = false
                    return nil
                }
            } else {
                body.append(contentsOf: chunk)
            }
        }
        bodyComplete = true
        return over ? nil : Data(body)
    }

    private func drain(_ length: Int64, _ drainLimit: Int64) {
        var left = length
        while left > 0 && length - left < drainLimit {
            let got = connection.read(Int(min(left, 64 * 1024)))
            if got.isEmpty { break }
            left -= Int64(got.count)
        }
        if left > 0 {
            keepAlive = false
        } else {
            bodyComplete = true
        }
    }

    private func sendContinueIfOwed() throws {
        if continueOwed {
            continueOwed = false
            try connection.write(Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
    }

    public func setHeader(_ name: String, _ value: String) {
        responseHeaders.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
        responseHeaders.append((name, value))
    }

    public func addHeader(_ name: String, _ value: String) {
        responseHeaders.append((name, value))
    }

    /// A whole response; `body` nil sends none (`Content-Length: 0`). A HEAD request gets
    /// the headers only.
    public func send(_ status: Int, _ contentType: String?, _ body: Data?) throws {
        guard !responseStarted else { throw HttpError("response already sent") }
        responseStarted = true
        prepareForResponse()
        if let contentType {
            setHeader("Content-Type", contentType)
        }
        let bytes = body ?? Data()
        setHeader("Content-Length", String(bytes.count))
        var out = Array(head(status).utf8)
        if method != "HEAD" {
            out.append(contentsOf: bytes)
        }
        try connection.write(out)
    }

    /// Starts a chunked response (a stream, e.g. Server-Sent Events); `write` sends each
    /// piece at once.
    public func startStream(_ status: Int) throws {
        guard !responseStarted else { throw HttpError("response already sent") }
        responseStarted = true
        streaming = true
        prepareForResponse()
        setHeader("Transfer-Encoding", "chunked")
        try connection.write(Array(head(status).utf8))
    }

    /// One piece of a stream; throws once the client has gone.
    public func write(_ data: Data) throws {
        guard streaming else { throw HttpError("not streaming") }
        if data.isEmpty { return }
        var out = Array(String(data.count, radix: 16).utf8) + [13, 10]
        out.append(contentsOf: data)
        out.append(contentsOf: [13, 10])
        try connection.write(out)
    }

    /// Ends the response after the handler: the stream's last chunk, or an error status
    /// when the handler sent nothing.
    func finish() throws {
        if !responseStarted {
            try send(500, "text/plain", Data("no response".utf8))
        }
        if streaming {
            streaming = false
            try connection.write(Array("0\r\n\r\n".utf8))
        }
        if !bodyComplete && keepAlive {
            // unread body: drain it so the next request starts at its head
            if chunkedRequest || continueOwed {
                keepAlive = false
            } else if let length = contentLength {
                drain(length, 1 << 20)
            }
        }
    }

    /// Before the head goes out: a body the client was told to hold back is never coming.
    private func prepareForResponse() {
        if continueOwed {
            keepAlive = false
        }
        if !(server?.isRunning ?? false) {
            keepAlive = false
        }
        if !keepAlive {
            setHeader("Connection", "close")
        }
    }

    private func head(_ status: Int) -> String {
        var head = "HTTP/1.1 \(status) \(HttpExchange.reason(status))\r\n"
        head += "Date: \(HttpExchange.httpDate())\r\n"
        for (name, value) in responseHeaders {
            head += "\(name): \(value)\r\n"
        }
        return head + "\r\n"
    }

    private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// Query-string and URL helpers in Java's `URLDecoder`/`URLEncoder` semantics.
enum UrlCoding {

    /// `URLDecoder.decode`: `+` is a space, `%XX` an escaped UTF-8 byte; nil when an escape
    /// is malformed.
    static func formDecode(_ s: String) -> String? {
        var bytes: [UInt8] = []
        var units = Array(s.utf8)[...]
        while let b = units.first {
            units = units.dropFirst()
            if b == UInt8(ascii: "+") {
                bytes.append(0x20)
            } else if b == UInt8(ascii: "%") {
                guard units.count >= 2,
                      let v = UInt8(String(decoding: units.prefix(2), as: UTF8.self), radix: 16) else { return nil }
                bytes.append(v)
                units = units.dropFirst(2)
            } else {
                bytes.append(b)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `URLEncoder.encode(s, UTF_8).replace("+", "%20")`.
    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"),
                 UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// The first value of `key` in `rawQuery`, decoded.
    static func query(_ rawQuery: String?, _ key: String) -> String? {
        guard let rawQuery else { return nil }
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            guard let eq = pair.firstIndex(of: "="), eq > pair.startIndex else { continue }
            if pair[..<eq] == key {
                return formDecode(String(pair[pair.index(after: eq)...]))
            }
        }
        return nil
    }
}

/// Constant-time comparison (`MessageDigest.isEqual`).
func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a.count != b.count {
        return false
    }
    var diff: UInt8 = 0
    for i in 0..<a.count {
        diff |= a[i] ^ b[i]
    }
    return diff == 0
}
