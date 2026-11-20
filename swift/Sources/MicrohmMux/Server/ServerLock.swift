import Darwin
import Foundation

/// The exclusive `server.lock` a server holds for its whole life — step (1) of the fixed
/// startup order. Only the server process ever opens this file; clients never lock or probe
/// it, so a held lock means exactly "another live server owns this home".
///
/// The lock is a POSIX record lock (`fcntl(F_SETLK)`) over the whole file, the kind Java's
/// `FileChannel.tryLock` takes, so a Java daemon and a Swift daemon exclude each other on
/// the same home. Record locks are per process, so a second server in this same process (as
/// tests make) is refused through an in-process registry, as Java's
/// `OverlappingFileLockException` refused it.
///
/// The pid written by `writePid` is for diagnostics only (`cat server.lock`); the lock
/// itself is what carries the ownership, because a pid in a file cannot tell a crashed
/// server from a live one and an OS file lock can.
final class ServerLock: @unchecked Sendable {

    private static let registryLock = NSLock()
    private static var heldPaths: Set<String> = []

    private let fd: Int32
    private let path: String
    private var closed = false

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    /// Nil when another server (in this or any other process) already holds the lock.
    static func tryAcquire(_ lockFile: URL) throws -> ServerLock? {
        try? FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let path = lockFile.standardizedFileURL.path
        registryLock.lock(); defer { registryLock.unlock() }
        if heldPaths.contains(path) {
            return nil
        }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw MuxIOError("cannot open \(path): \(errnoText())")
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        if fcntl(fd, F_SETLK, &lock) != 0 {
            let e = errno
            Darwin.close(fd)
            if e == EAGAIN || e == EACCES {
                return nil
            }
            throw MuxIOError("cannot lock \(path): \(errnoText(e))")
        }
        heldPaths.insert(path)
        return ServerLock(fd: fd, path: path)
    }

    func writePid(_ pid: Int32) throws {
        if ftruncate(fd, 0) != 0 {
            throw MuxIOError("cannot write \(path): \(errnoText())")
        }
        let bytes = Array("\(pid)\n".utf8)
        let n = pwrite(fd, bytes, bytes.count, 0)
        if n != bytes.count {
            throw MuxIOError("cannot write \(path): \(errnoText())")
        }
        fsync(fd)
    }

    /// Releases the lock and closes the file; the file itself stays (it is the next
    /// server's lock target).
    func close() {
        ServerLock.registryLock.lock(); defer { ServerLock.registryLock.unlock() }
        if closed { return }
        closed = true
        Darwin.close(fd) // releases the record lock
        ServerLock.heldPaths.remove(path)
    }
}
