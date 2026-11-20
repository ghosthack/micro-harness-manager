import Darwin
import Foundation

/// An I/O failure in the mux layer (Java: `IOException`). `isEOF` marks the end of the
/// stream in the middle of something (Java: `EOFException`).
public struct MuxIOError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public let isEOF: Bool
    public init(_ message: String, isEOF: Bool = false) {
        self.message = message
        self.isEOF = isEOF
    }
    public var description: String { message }
    public var errorDescription: String? { message }
}

func errnoText(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
}

/// The OS limit on a Unix-domain socket path, NUL excluded (104-byte `sun_path` on macOS).
let maxSocketPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    if bytes.count > maxSocketPathBytes {
        throw MuxIOError("Unix domain path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

/// One connected Unix-domain stream socket. Closed exactly once and never used after (a
/// reused descriptor number could otherwise receive a late write): every operation
/// registers itself as in flight, and `close` shuts the socket down — which wakes a reader
/// or writer blocked in it — and releases the descriptor once nothing is in flight. Safe to
/// close from any thread (Java's `SocketChannel.close` semantics).
public final class UnixSocket: @unchecked Sendable {

    private let fd: Int32
    private let lock = NSLock()
    private var inFlight = 0
    private var closing = false
    private var released = false

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Connects to the socket file at `path`; throws when it is missing or refuses.
    public static func connect(_ path: String) throws -> UnixSocket {
        var address = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw MuxIOError("socket: \(errnoText())") }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            throw MuxIOError("connect \(path): \(errnoText(e))")
        }
        return UnixSocket(fd: fd)
    }

    private func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closing { return false }
        inFlight += 1
        return true
    }

    private func exit() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        if inFlight == 0 && closing { release() }
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closing
    }

    /// Up to `count` bytes; 0 at end of stream (or once closed).
    func read(_ buffer: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        if !enter() { return 0 }
        defer { exit() }
        while true {
            let n = Darwin.read(fd, buffer, count)
            if n >= 0 { return n }
            let e = errno
            if e == EINTR { continue }
            if e == ECONNRESET || e == ENOTCONN || e == EBADF { return 0 }
            throw MuxIOError("read: \(errnoText(e))")
        }
    }

    /// Writes every byte or throws (the peer went away, or this socket closed).
    func write(_ bytes: UnsafeRawBufferPointer) throws {
        if bytes.count == 0 { return }
        if !enter() { throw MuxIOError("Socket closed") }
        defer { exit() }
        var written = 0
        while written < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw MuxIOError(e == EPIPE ? "Broken pipe" : "write: \(errnoText(e))")
            }
            written += n
        }
    }

    /// Idempotent; wakes any thread blocked in a read or write on this socket.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if closing { return }
        closing = true
        _ = shutdown(fd, SHUT_RDWR)
        if inFlight == 0 { release() }
    }

    private func release() {
        if released { return }
        released = true
        Darwin.close(fd)
    }
}

/// A listening Unix-domain socket. `accept` waits in `poll` on the listener and a wake
/// pipe, so `close` from another thread ends it promptly (macOS does not wake a blocked
/// `accept` on close or shutdown).
final class UnixListener: @unchecked Sendable {

    private let fd: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var closed = false
    private var inFlight = 0
    private var released = false

    /// Binds and listens at `path`; the file is created with the umask's permissions.
    init(bind path: String) throws {
        var address = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw MuxIOError("socket: \(errnoText())") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            throw MuxIOError("bind \(path): \(errnoText(e))")
        }
        if listen(fd, 128) != 0 {
            let e = errno
            Darwin.close(fd)
            throw MuxIOError("listen \(path): \(errnoText(e))")
        }
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        }
        self.fd = fd
        wakeRead = fds[0]
        wakeWrite = fds[1]
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    /// The next connection; nil once the listener is closed.
    func accept() throws -> UnixSocket? {
        lock.lock()
        if closed { lock.unlock(); return nil }
        inFlight += 1
        lock.unlock()
        defer {
            lock.lock()
            inFlight -= 1
            if inFlight == 0 && closed { release() }
            lock.unlock()
        }
        var pollfds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while true {
            pollfds[0].revents = 0
            pollfds[1].revents = 0
            let ready = poll(&pollfds, wakeRead >= 0 ? 2 : 1, wakeRead >= 0 ? -1 : 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw MuxIOError("poll: \(errnoText())")
            }
            if !isOpen || (wakeRead >= 0 && pollfds[1].revents != 0) { return nil }
            if ready == 0 { continue }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                let e = errno
                if e == EINTR || e == ECONNABORTED || e == EAGAIN { continue }
                throw MuxIOError("accept: \(errnoText(e))")
            }
            return UnixSocket(fd: client)
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        closed = true
        if inFlight == 0 {
            release()
        } else if wakeWrite >= 0 {
            var one: UInt8 = 1
            _ = Darwin.write(wakeWrite, &one, 1)
        }
    }

    private func release() {
        if released { return }
        released = true
        Darwin.close(fd)
        if wakeRead >= 0 {
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
        }
    }
}
