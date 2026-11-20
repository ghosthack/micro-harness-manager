import Foundation

/// Minimal append-only file logger (the Java app used slf4j-simple). Thread-safe.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    private let lock = NSLock()
    private var handle: FileHandle?
    private let fmt: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    /// Directs output to `file` (created 0600). Until called, logs go to stderr.
    public func open(_ file: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: file)
        handle?.seekToEndOfFile()
    }

    public func write(_ level: String, _ msg: @autoclosure () -> String, _ tag: String = "") {
        let line = "\(fmt.string(from: Date())) \(level) \(tag.isEmpty ? "" : "[\(tag)] ")\(msg())\n"
        lock.lock(); defer { lock.unlock() }
        if let h = handle { h.write(Data(line.utf8)) } else { FileHandle.standardError.write(Data(line.utf8)) }
    }

    public static func info(_ m: @autoclosure () -> String, tag: String = "") { shared.write("INFO", m(), tag) }
    public static func warn(_ m: @autoclosure () -> String, tag: String = "") { shared.write("WARN", m(), tag) }
    public static func error(_ m: @autoclosure () -> String, tag: String = "") { shared.write("ERROR", m(), tag) }
    public static func debug(_ m: @autoclosure () -> String, tag: String = "") {
        if ProcessInfo.processInfo.environment["MICROHM_DEBUG"] != nil { shared.write("DEBUG", m(), tag) }
    }
}
