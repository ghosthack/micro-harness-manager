import Darwin
import Foundation

/// A child process whose stdin, stdout and stderr are the slave side of a new pseudo-
/// terminal, which is also its controlling terminal; the parent holds the master side.
///
/// How the child gets its controlling terminal: `forkpty(3)` opens the pair, forks, and in
/// the child runs `login_tty` — `setsid` (a new session, the child its leader) and
/// `ioctl(TIOCSCTTY)` on the slave, which macOS requires of the session leader itself (BSD
/// semantics: opening a terminal never makes it the controlling one). The Java port could
/// not run code between fork and exec and needed a trampoline JVM for that ioctl; here the
/// child runs only async-signal-safe calls on buffers prepared before the fork: every
/// signal back to its default disposition and an empty signal mask (so the child does not
/// inherit ours), `chdir`, every descriptor above 2 closed, and `execve` with exactly the
/// given environment. Without a controlling terminal (bash takes the terminal for itself,
/// zsh does not) a shell would have no job control, no `/dev/tty`, and `tpgid` — how the
/// foreground program is found — would be 0. A failed `chdir` or `execve` is reported back
/// through a close-on-exec pipe, so `start` throws instead of returning a dead process.
///
/// The initial window size is given to `forkpty`, which sets it on the slave before the
/// fork; the parent never holds the slave, so output ends (EOF on the master) once the
/// child and its descendants have closed the terminal.
///
/// Exit: a reaper thread blocks in `waitpid` for this pid only; the exit value is the exit
/// status, or 128 + the signal number when the child was killed by a signal (the shell
/// convention).
public final class PtyProcess: @unchecked Sendable, CustomStringConvertible {

    public let pid: Int32
    private let master: MasterFd
    private let exit = ExitStatus()

    private init(pid: Int32, master: MasterFd) {
        self.pid = pid
        self.master = master
    }

    /// Serializes spawns: a descriptor `forkpty` just opened is not close-on-exec until the
    /// parent marks it, and a concurrent spawn's child must not inherit it in between (the
    /// child also closes every descriptor above 2, but other spawners are not ours).
    private static let spawnLock = NSLock()

    /// Starts `command` in a new `columns`×`rows` PTY.
    ///
    /// - Parameters:
    ///   - command: argv; a program name without '/' is looked up on the PATH from
    ///     `environment` (falling back to this process's PATH)
    ///   - environment: the child's entire environment
    ///   - directory: the child's working directory
    public static func start(_ command: [String], environment: [String: String], directory: URL,
                             columns: Int, rows: Int) throws -> PtyProcess {
        guard let first = command.first else {
            throw PtyError("empty command")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            throw PtyError("not a directory: \(directory.path)")
        }
        let program = resolve(first, environment)
        // Checked here, since the child could only fail after starting.
        var programIsDirectory: ObjCBool = false
        if !program.hasPrefix("/")
            || !FileManager.default.fileExists(atPath: program, isDirectory: &programIsDirectory)
            || programIsDirectory.boolValue
            || !FileManager.default.isExecutableFile(atPath: program) {
            throw PtyError("cannot run \(program): not an executable file")
        }

        // Everything the child touches is prepared before the fork: after it, the child may
        // only make async-signal-safe calls (no allocation, no locks, no Swift runtime).
        let argv = CStringArray(command)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let path = strdup(program)!
        let dir = strdup(directory.path)!
        defer { free(path); free(dir) }
        let report = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { report.deallocate() }
        let defaultAction = UnsafeMutablePointer<sigaction>.allocate(capacity: 1)
        defer { defaultAction.deallocate() }
        defaultAction.initialize(to: sigaction())
        defaultAction.pointee.__sigaction_u.__sa_handler = nil // SIG_DFL
        defaultAction.pointee.sa_flags = 0
        sigemptyset(&defaultAction.pointee.sa_mask)
        let emptyMask = UnsafeMutablePointer<sigset_t>.allocate(capacity: 1)
        defer { emptyMask.deallocate() }
        emptyMask.initialize(to: 0)
        sigemptyset(emptyMask)
        let size = UnsafeMutablePointer<winsize>.allocate(capacity: 1)
        defer { size.deallocate() }
        size.initialize(to: winsize(ws_row: clampDimension(rows), ws_col: clampDimension(columns),
                                    ws_xpixel: 0, ws_ypixel: 0))
        var descriptorLimit = getdtablesize()
        if descriptorLimit <= 0 || descriptorLimit > 1 << 16 { descriptorLimit = 1 << 16 }

        var errorPipe: [Int32] = [-1, -1]
        if Darwin.pipe(&errorPipe) != 0 {
            throw PtyError("pipe failed: \(describeErrno(errno))")
        }
        let errorRead = errorPipe[0]
        let errorWrite = errorPipe[1]
        _ = fcntl(errorRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(errorWrite, F_SETFD, FD_CLOEXEC)

        var masterFd: Int32 = -1
        spawnLock.lock()
        let pid = forkpty(&masterFd, nil, nil, size)
        if pid == 0 {
            // ---- child: async-signal-safe calls only ----
            var signal: Int32 = 1
            while signal < 32 {
                _ = sigaction(signal, defaultAction, nil)
                signal += 1
            }
            _ = sigprocmask(SIG_SETMASK, emptyMask, nil)
            if chdir(dir) != 0 {
                report[0] = 1
                report[1] = errno
                _ = Darwin.write(errorWrite, report, 8)
                _exit(126)
            }
            var fd: Int32 = 3
            while fd < descriptorLimit {
                if fd != errorWrite { _ = Darwin.close(fd) }
                fd += 1
            }
            _ = execve(path, argv.pointer, envp.pointer)
            report[0] = 2
            report[1] = errno
            _ = Darwin.write(errorWrite, report, 8)
            _exit(127)
        }
        let forkErrno = errno
        if pid > 0 {
            _ = fcntl(masterFd, F_SETFD, FD_CLOEXEC)
        }
        spawnLock.unlock()
        _ = Darwin.close(errorWrite)
        defer { _ = Darwin.close(errorRead) }
        if pid < 0 {
            throw PtyError("starting \(first) in a PTY failed: forkpty: \(describeErrno(forkErrno))")
        }

        // EOF on the pipe = the exec succeeded (its write end was close-on-exec).
        var got = 0
        let raw = UnsafeMutableRawPointer(report)
        while got < 8 {
            let n = Darwin.read(errorRead, raw + got, 8 - got)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            got += n
        }
        if got == 8 {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            _ = Darwin.close(masterFd)
            if report[0] == 1 {
                throw PtyError("cannot change directory to \(directory.path): \(describeErrno(report[1]))")
            }
            throw PtyError("cannot run \(program): \(describeErrno(report[1]))")
        }

        let process = PtyProcess(pid: pid, master: MasterFd(masterFd))
        let exit = process.exit
        let reaper = Thread { PtyProcess.reap(pid, exit) }
        reaper.name = "pty-reaper-\(pid)"
        reaper.stackSize = 64 * 1024
        reaper.start()
        return process
    }

    private static func clampDimension(_ value: Int) -> UInt16 {
        UInt16(max(1, min(value, Int(Int16.max))))
    }

    // MARK: - streams

    /// Reads the terminal's output into `buffer`. Returns -1 once every holder of the slave
    /// side closed it (or the terminal was closed here).
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        return try master.read(base, buffer.count)
    }

    /// Reads up to `maxLength` bytes; nil at the end of output.
    public func read(maxLength: Int = 16 * 1024) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let n = try buffer.withUnsafeMutableBytes { try read(into: $0) }
        if n < 0 { return nil }
        return Array(buffer[0..<n])
    }

    /// Typing into the terminal. Throws once the master is closed.
    public func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try master.write($0) }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { try master.write($0) }
    }

    // MARK: - control

    /// Sets the terminal size (SIGWINCH to the foreground group).
    public func setWinSize(columns: Int, rows: Int) throws {
        var failure: PtyError?
        let live = master.with { fd in
            var size = winsize(ws_row: PtyProcess.clampDimension(rows), ws_col: PtyProcess.clampDimension(columns),
                               ws_xpixel: 0, ws_ypixel: 0)
            if ioctl(fd, TIOCSWINSZ, &size) != 0 {
                failure = PtyError("TIOCSWINSZ failed: \(describeErrno(errno))")
                return false
            }
            return true
        }
        if let failure { throw failure }
        if !live { throw PtyError("the PTY is closed") }
    }

    public var isAlive: Bool { !exit.isDone }

    /// Blocks until the child exits; returns its exit value.
    @discardableResult
    public func waitFor() -> Int32 { exit.await() }

    /// Waits up to `timeout` seconds; returns whether the child exited.
    public func waitFor(timeout: TimeInterval) -> Bool { exit.await(timeout: timeout) != nil }

    /// The exit value; nil while running (Java threw IllegalThreadStateException).
    public func exitValue() -> Int32? { exit.value }

    /// Calls `callback` with the exit value once the child exited (at once if it has).
    public func onExit(_ callback: @escaping @Sendable (Int32) -> Void) { exit.onComplete(callback) }

    /// SIGHUP, what closing a terminal delivers: interactive shells exit on it (they ignore
    /// SIGTERM) and forward it to their jobs.
    public func hangup() { signal(SIGHUP) }

    /// SIGTERM.
    public func destroy() { signal(SIGTERM) }

    /// SIGKILL.
    public func destroyForcibly() { signal(SIGKILL) }

    private func signal(_ signal: Int32) {
        if exit.isDone {
            return // never signal a pid that may already have been reused
        }
        _ = Darwin.kill(pid, signal)
    }

    /// True while the child has written output that the reader has not yet reported
    /// consumed through `outputConsumed`: bytes still in the kernel, or bytes a read
    /// already returned. Lets a caller act on the screen as of everything the program
    /// printed so far.
    public func outputPending() -> Bool { master.outputPending() }

    /// The reader has applied all it read so far.
    public func outputConsumed() { master.outputConsumed() }

    /// Closes the master side. Output ends; further writes fail. Idempotent.
    public func closeTerminal() { master.close() }

    /// The terminal's foreground process group id (`tcgetpgrp` on the master, no fork);
    /// -1 when unknown: the terminal is closed, or no process has it as its controlling
    /// terminal yet.
    public func foregroundProcessGroup() -> Int32 {
        var group: Int32 = -1
        master.with { fd in
            group = tcgetpgrp(fd)
            return true
        }
        return group > 0 ? group : -1
    }

    // MARK: - reaping

    private static func reap(_ pid: Int32, _ exit: ExitStatus) {
        var status: Int32 = 0
        while true {
            let rc = waitpid(pid, &status, 0)
            if rc == pid {
                exit.complete(decode(status))
                return
            }
            if rc < 0 && errno == EINTR { continue }
            // ECHILD: someone else reaped it; the exit status is lost.
            exit.complete(-1)
            return
        }
    }

    /// `WIFEXITED → WEXITSTATUS`, `WIFSIGNALED → 128 + WTERMSIG`.
    static func decode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    /// `program` as given when it contains '/', else the first executable match on the
    /// child's PATH (or ours); unresolved names are returned as is and fail to start.
    static func resolve(_ program: String, _ environment: [String: String]) -> String {
        if program.contains("/") {
            return program
        }
        if let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = "\(dir)/\(program)"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return program
    }

    public var description: String {
        "PtyProcess[pid \(pid)\(exit.value.map { ", exited \($0)" } ?? "")]"
    }
}

/// A NULL-terminated `char *[]` owned until deinit.
private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() {
            pointer[i] = strdup(s)
        }
        pointer[strings.count] = nil
    }

    deinit {
        for i in 0..<count { free(pointer[i]) }
        pointer.deallocate()
    }
}

/// The exit value, completed once by the reaper (Java: `CompletableFuture<Integer>`).
final class ExitStatus: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Int32?
    private var callbacks: [@Sendable (Int32) -> Void] = []

    var isDone: Bool {
        condition.lock(); defer { condition.unlock() }
        return result != nil
    }

    var value: Int32? {
        condition.lock(); defer { condition.unlock() }
        return result
    }

    func complete(_ value: Int32) {
        condition.lock()
        if result != nil {
            condition.unlock()
            return
        }
        result = value
        let pending = callbacks
        callbacks = []
        condition.broadcast()
        condition.unlock()
        for callback in pending { callback(value) }
    }

    func onComplete(_ callback: @escaping @Sendable (Int32) -> Void) {
        condition.lock()
        if let result {
            condition.unlock()
            callback(result)
            return
        }
        callbacks.append(callback)
        condition.unlock()
    }

    func await() -> Int32 {
        condition.lock(); defer { condition.unlock() }
        while result == nil { condition.wait() }
        return result!
    }

    func await(timeout: TimeInterval) -> Int32? {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock(); defer { condition.unlock() }
        while result == nil {
            if !condition.wait(until: deadline) { break }
        }
        return result
    }
}
