import Darwin
import Foundation
import MicrohmShared

/// Runs a short diagnostic command (`ps`, `lsof`) for the probes and returns its stdout.
/// Never throws: a missing tool, a failure or a timeout is nil, and the probe falls through
/// to its next strategy. Only ever called from user actions and the status poll, never
/// from the pump or under a session lock.
///
/// The deadline covers the read: the output only ends once the child closes its stdout, so
/// a child that hangs with the pipe open (`lsof` stuck in `stat()` on a dead network mount)
/// would otherwise block the caller for as long as the mount does. On the deadline the
/// command and its live descendants are killed, closing inherited stdout handles as well.
enum ProbeCommand {

    static let TIMEOUT: TimeInterval = 5

    /// Stdout of `command`, regardless of exit code (`ps -p` exits 1 when any listed pid is
    /// gone but still prints the rest); nil when it could not run, timed out or printed
    /// nothing.
    static func output(_ command: [String], timeout: TimeInterval = TIMEOUT) -> String? {
        var pipe: [Int32] = [-1, -1]
        if Darwin.pipe(&pipe) != 0 { return nil }
        let readEnd = pipe[0]
        let writeEnd = pipe[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var empty = sigset_t()
        var all = sigset_t()
        sigemptyset(&empty)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, command[0], &actions, &attr, argv, envp)
        Darwin.close(writeEnd)
        if rc != 0 {
            Darwin.close(readEnd)
            Log.debug("cannot run \(command[0]): \(String(cString: strerror(rc)))", tag: "probe")
            return nil
        }
        defer { Darwin.close(readEnd) }

        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date(timeIntervalSinceNow: timeout)
        var timedOut = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                break
            }
            var fds = [pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 1, Int32(min(remaining * 1000 + 1, 60_000)))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out += buffer[0..<n]
        }
        if timedOut {
            terminate(pid)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if timedOut {
            Log.debug("\(command[0]) timed out after \(timeout) s", tag: "probe")
            return nil
        }
        return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
    }

    private static func terminate(_ pid: Int32) {
        // Snapshot descendants before killing their parent, while ancestry is known; kill
        // them first so inherited stdout handles cannot keep the read blocked.
        for descendant in ProcessTable.descendants(of: pid).reversed() {
            Darwin.kill(descendant.pid, SIGKILL)
        }
        Darwin.kill(pid, SIGKILL)
    }
}
