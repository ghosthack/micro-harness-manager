import Darwin
import Foundation
import MicrohmShared

/// The registry's single-owner lock: an `instance.lock` file beside the registry file.
/// Saves are full-snapshot rewrites, so two processes on one registry would clobber each
/// other's entries; the app and the headless MCP host both take this lock and hand it over
/// rather than share it. Held for the process lifetime; the OS releases it on exit, however
/// the process ends. (An exclusive `flock`, as the app's own `InstanceLock` takes.)
public enum InstanceLock {

    /// What `tryAcquire` found.
    public enum Result: Sendable {
        /// This process now holds the lock.
        case ACQUIRED
        /// Another process holds it.
        case HELD
        /// The lock could not even be attempted (unwritable directory, exotic file system);
        /// callers run unguarded, as a working session manager beats refusing to start.
        case UNAVAILABLE
    }

    private static let POLL: TimeInterval = 0.1
    private static let lock = NSLock()
    /// Never closed deliberately: each lock lives as long as the process. Keyed by lock file,
    /// as tests take locks on scratch registries.
    nonisolated(unsafe) private static var held: [String: Int32] = [:]

    public static func lockFile(_ registryFile: URL) -> URL {
        registryFile.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("instance.lock")
    }

    /// One attempt.
    public static func tryAcquire(_ registryFile: URL) -> Result {
        let file = lockFile(registryFile)
        lock.lock(); defer { lock.unlock() }
        if held[file.path] != nil {
            return .ACQUIRED
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .UNAVAILABLE
        }
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .UNAVAILABLE
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd)
            return error == EWOULDBLOCK ? .HELD : .UNAVAILABLE
        }
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        held[file.path] = fd
        return .ACQUIRED
    }

    /// Retries until the lock is free or `timeout` passes; HELD on timeout.
    public static func acquire(_ registryFile: URL, _ timeout: TimeInterval) -> Result {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let result = tryAcquire(registryFile)
            if result != .HELD || Date() >= deadline {
                return result
            }
            Thread.sleep(forTimeInterval: POLL)
        }
    }

    /// Lets go of the lock on `registryFile` early (tests, or a host handing over).
    public static func release(_ registryFile: URL) {
        let file = lockFile(registryFile)
        lock.lock(); defer { lock.unlock() }
        if let fd = held.removeValue(forKey: file.path) {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

/// Who the headless MCP host is: an `mcp-host.pid` file beside the registry holding the
/// host's pid and its start instant. The pair, not the pid alone, identifies the process,
/// so the app never signals an unrelated process that reused the number.
public enum HostOwner {

    /// The recorded identity of a host process.
    public struct Record: Equatable, Sendable {
        public let pid: Int64
        public let startEpochMillis: Int64

        public init(_ pid: Int64, _ startEpochMillis: Int64) {
            self.pid = pid
            self.startEpochMillis = startEpochMillis
        }

        func encode() -> String {
            "\(pid) \(startEpochMillis)\n"
        }

        static func decode(_ text: String) -> Record? {
            let parts = JavaText.strip(text).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            guard parts.count == 2, let pid = Int64(parts[0]), let start = Int64(parts[1]) else {
                return nil
            }
            return Record(pid, start)
        }
    }

    /// Start instants are compared with this slack: platforms report them at different
    /// resolutions, and a reused pid starts far later than that.
    static let START_TOLERANCE_MILLIS: Int64 = 2000

    public static func file(_ registryFile: URL) -> URL {
        registryFile.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("mcp-host.pid")
    }

    /// This process's record, or nil when the system does not report a start time.
    public static func current() -> Record? {
        let pid = Int64(getpid())
        return startMillis(pid).map { Record(pid, $0) }
    }

    /// When process `pid` started, in epoch milliseconds; nil when there is no such process.
    static func startMillis(_ pid: Int64) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000
    }

    /// Writes `record` atomically, so a reader never sees half of it.
    public static func write(_ registryFile: URL, _ record: Record) throws {
        let target = file(registryFile)
        let tmp = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".tmp")
        try Data(record.encode().utf8).write(to: tmp)
        if rename(tmp.path, target.path) != 0 {
            throw SessionHostException("cannot write \(target.path): \(String(cString: strerror(errno)))")
        }
    }

    public static func read(_ registryFile: URL) -> Record? {
        guard let data = try? Data(contentsOf: file(registryFile)) else { return nil }
        return Record.decode(String(decoding: data, as: UTF8.self))
    }

    /// Removes the file only if it still names `record`: a newer host's file stays.
    public static func clear(_ registryFile: URL, _ record: Record) {
        if read(registryFile) == record {
            try? FileManager.default.removeItem(at: file(registryFile))
        }
    }

    /// Whether `record` names a live process that is still that process.
    public static func live(_ record: Record) -> Bool {
        live(record) { startMillis($0) }
    }

    static func live(_ record: Record, _ lookup: (Int64) -> Int64?) -> Bool {
        guard record.pid > 0, let start = lookup(record.pid) else { return false }
        return abs(start - record.startEpochMillis) <= START_TOLERANCE_MILLIS && isAlive(record.pid)
    }

    private static func isAlive(_ pid: Int64) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Stops the recorded host, if one is running, and waits up to `timeout` for it to exit
    /// (it releases the instance lock as it does). True when no host is left running.
    @discardableResult
    public static func stop(_ registryFile: URL, _ timeout: TimeInterval) -> Bool {
        guard let record = read(registryFile) else {
            return true
        }
        if !live(record) {
            clear(registryFile, record)
            return true
        }
        let pid = pid_t(record.pid)
        kill(pid, SIGTERM) // its handler stops the servers and clears the file
        let deadline = Date().addingTimeInterval(timeout)
        while live(record) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if live(record) {
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.2)
        }
        clear(registryFile, record)
        return !live(record)
    }

    /// For log lines.
    static func describe(_ record: Record) -> String {
        "pid \(record.pid), started \(IsoInstant.format(Date(timeIntervalSince1970: Double(record.startEpochMillis) / 1000)))"
    }
}
