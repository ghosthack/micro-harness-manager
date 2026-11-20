import Darwin
import Foundation

/// A failure of the PTY layer (Java: `IOException`). The message is meant for the user.
public struct PtyError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// `strerror(errno)`, the way the Java side's `Posix.describe` words it.
func describeErrno(_ code: Int32) -> String {
    String(cString: strerror(code)) + " (errno \(code))"
}

/// `FIONREAD` (`_IOR('f', 127, int)`): Swift cannot import the macro.
let FIONREAD_REQUEST: UInt = 0x4004_667F

/// The PTY master descriptor, shared by one reader and any number of writers, closed
/// exactly once and never used after: a descriptor number is reused by the next
/// `open` anywhere in the process, so a late write to a closed number could land in an
/// unrelated file. Every operation registers itself as in flight; `close` marks the
/// descriptor closed and releases it only once nothing is in flight. Reads wait in
/// `poll` on the master and on a wake pipe rather than blocking in `read`:
/// `close` writes to the pipe, so a close never waits on output that will not come,
/// and an idle session costs no wakeups at all. Should the pipe be unavailable, the wait
/// falls back to a short poll timeout.
final class MasterFd: @unchecked Sendable {

    /// Poll timeout used only when the wake pipe could not be created.
    private static let fallbackPollMillis: Int32 = 100

    let fd: Int32
    /// The wake pipe's read and write ends, or -1 when it could not be created.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var inFlight = 0        // guarded by lock
    private var closing = false     // guarded by lock
    private var released = false    // guarded by lock

    /// Set by the reader once poll reports output and before it reads any of it; cleared
    /// by the consumer once what it read is applied. Together with `unread`, some
    /// unapplied output is always visible: see `outputPending`.
    private var readPending = false // guarded by pendingLock
    private let pendingLock = NSLock()

    /// There is one reader; this serializes readers should there ever be more.
    private let readLock = NSLock()

    init(_ fd: Int32) {
        self.fd = fd
        let pipe = MasterFd.openWakePipe()
        wakeRead = pipe.0
        wakeWrite = pipe.1
    }

    /// A close-on-exec pipe, so the shells this process spawns never inherit it; (-1, -1)
    /// when it cannot be created.
    private static func openWakePipe() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        if Darwin.pipe(&fds) != 0 {
            return (-1, -1)
        }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    /// Registers an operation; false when the descriptor is closing or closed.
    private func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closing { return false }
        inFlight += 1
        return true
    }

    private func exit() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        if inFlight == 0 && closing {
            release()
        }
    }

    private func setReadPending(_ value: Bool) {
        pendingLock.lock(); readPending = value; pendingLock.unlock()
    }

    /// Reads up to `count` bytes; returns -1 at end of output: the slave side has been
    /// closed by every process (EOF on macOS, EIO on Linux), or this descriptor closed.
    func read(_ buffer: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        if count == 0 { return 0 }
        readLock.lock(); defer { readLock.unlock() }
        let wakeable = wakeRead >= 0
        let nfds: nfds_t = wakeable ? 2 : 1
        let timeout: Int32 = wakeable ? -1 : MasterFd.fallbackPollMillis
        var pollfds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while true {
            if !enter() { return -1 }
            defer { exit() }
            pollfds[0].revents = 0
            pollfds[1].revents = 0
            let ready = poll(&pollfds, nfds, timeout)
            if ready < 0 {
                let e = errno
                if e == EINTR || e == EAGAIN { continue }
                throw PtyError("poll on the PTY failed: \(describeErrno(e))")
            }
            if ready == 0 { continue } // fallback timeout: re-check whether we are closing
            if wakeable && pollfds[1].revents != 0 {
                return -1 // close() woke us
            }
            if (Int32(pollfds[0].revents) & POLLNVAL) != 0 {
                return -1
            }
            // Before the read takes the bytes out of the kernel, so that a caller
            // checking outputPending() never sees them in neither place.
            setReadPending(true)
            let n = Darwin.read(fd, buffer, count)
            if n <= 0 { setReadPending(false) }
            if n > 0 { return n }
            if n == 0 { return -1 }
            let e = errno
            if e == EINTR || e == EAGAIN { continue }
            if e == EIO { return -1 } // every slave descriptor is closed
            throw PtyError("reading the PTY failed: \(describeErrno(e))")
        }
    }

    /// Writes every byte, or throws once the descriptor is closed.
    func write(_ bytes: UnsafeRawBufferPointer) throws {
        if bytes.count == 0 { return }
        if !enter() { throw PtyError("the PTY is closed") }
        defer { exit() }
        var written = 0
        while written < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
            if n < 0 {
                let e = errno
                if e == EINTR || e == EAGAIN { continue }
                throw PtyError("writing the PTY failed: \(describeErrno(e))")
            }
            written += n
        }
    }

    /// True while the program has output this process has not finished consuming: bytes
    /// still in the kernel buffer, or bytes the reader took since the consumer last called
    /// `outputConsumed`. False once the descriptor is closed.
    func outputPending() -> Bool {
        pendingLock.lock()
        let pending = readPending
        pendingLock.unlock()
        return pending || unread() > 0
    }

    /// The consumer has applied everything the reader returned so far.
    func outputConsumed() {
        setReadPending(false)
    }

    /// `FIONREAD`: bytes waiting in the kernel; 0 when closed or unknown.
    private func unread() -> Int32 {
        var count: Int32 = 0
        _ = with { descriptor in
            var n: Int32 = 0
            if ioctl(descriptor, FIONREAD_REQUEST, &n) == 0 {
                count = n
            }
            return true
        }
        return count
    }

    /// Runs `op` with the live descriptor; false (op not run) once closing.
    @discardableResult
    func with(_ op: (Int32) -> Bool) -> Bool {
        if !enter() { return false }
        defer { exit() }
        return op(fd)
    }

    /// Marks the descriptor closed; it is released now, or when the last in-flight
    /// operation finishes (a read waiting in poll is woken through the pipe). Idempotent.
    func close() {
        lock.lock(); defer { lock.unlock() }
        if closing { return }
        closing = true
        if inFlight == 0 {
            release()
            return
        }
        // A read is in flight: wake it. The pipe stays open until release().
        wake()
    }

    private func wake() {
        if wakeWrite < 0 { return }
        var one: UInt8 = 1
        _ = Darwin.write(wakeWrite, &one, 1)
    }

    /// Must hold `lock`.
    private func release() {
        if released { return }
        released = true
        _ = Darwin.close(fd)
        if wakeRead >= 0 {
            _ = Darwin.close(wakeRead)
            _ = Darwin.close(wakeWrite)
        }
    }
}
