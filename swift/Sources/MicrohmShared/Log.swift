import Darwin
import Foundation

/// Minimal append-only file logger (the Java app used slf4j-simple). Thread-safe.
///
/// Writes go through `write(2)` on a plain descriptor, never `FileHandle.write(_:)`, which
/// raises an Objective-C exception (and so kills the process) on ENOSPC, EIO or EPIPE. A log
/// line that cannot be written is dropped.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    private let lock = NSLock()
    private var fd: Int32 = -1
    private let fmt: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    /// Directs output to `file` (created 0600). Until called, logs go to stderr.
    public func open(_ file: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if opened < 0 {
            return
        }
        // the log may be a pipe: a vanished reader is EPIPE (dropped), not a fatal SIGPIPE
        _ = fcntl(opened, F_SETNOSIGPIPE, 1)
        if fd >= 0 {
            Darwin.close(fd)
        }
        fd = opened
    }

    public func write(_ level: String, _ msg: @autoclosure () -> String, _ tag: String = "") {
        let line = "\(fmt.string(from: Date())) \(level) \(tag.isEmpty ? "" : "[\(tag)] ")\(msg())\n"
        lock.lock(); defer { lock.unlock() }
        Log.writeAll(fd >= 0 ? fd : STDERR_FILENO, Array(line.utf8))
    }

    /// Every byte, across partial writes and EINTR; any other error drops the rest.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    public static func info(_ m: @autoclosure () -> String, tag: String = "") { shared.write("INFO", m(), tag) }
    public static func warn(_ m: @autoclosure () -> String, tag: String = "") { shared.write("WARN", m(), tag) }
    public static func error(_ m: @autoclosure () -> String, tag: String = "") { shared.write("ERROR", m(), tag) }
    public static func debug(_ m: @autoclosure () -> String, tag: String = "") {
        if ProcessInfo.processInfo.environment["MICROHM_DEBUG"] != nil { shared.write("DEBUG", m(), tag) }
    }
}
