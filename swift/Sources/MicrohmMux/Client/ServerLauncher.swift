import Darwin
import Foundation
import MicrohmShared

/// A daemon process a client started: its pid, and whether it is still running (a reaper
/// thread `waitpid`s it, so a daemon that exits while the app runs leaves no zombie).
public final class SpawnedProcess: @unchecked Sendable {
    public let pid: Int32
    private let condition = NSCondition()
    private var status: Int32?

    init(pid: Int32) {
        self.pid = pid
        let reaper = Thread { [self] in
            var raw: Int32 = 0
            var rc: Int32
            repeat { rc = waitpid(pid, &raw, 0) } while rc < 0 && errno == EINTR
            let code: Int32 = rc == pid ? ((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)) : -1
            condition.lock()
            status = code
            condition.broadcast()
            condition.unlock()
        }
        reaper.name = "microhm-mux-daemon-reaper-\(pid)"
        reaper.stackSize = 64 * 1024
        reaper.start()
    }

    /// For test seams: a process that has already exited with `exitValue`.
    init(exited exitValue: Int32) {
        pid = -1
        status = exitValue
    }

    public var isAlive: Bool {
        condition.lock(); defer { condition.unlock() }
        return status == nil
    }

    /// Nil while running.
    public var exitValue: Int32? {
        condition.lock(); defer { condition.unlock() }
        return status
    }

    /// Waits up to `timeout` seconds; true once exited.
    public func waitFor(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        while status == nil {
            if !condition.wait(until: deadline) { break }
        }
        return status != nil
    }
}

/// How a client starts a server when none is listening. Resolution order:
///  1. an explicit executable the caller passes (the app bundles `microhm-mux` in
///     Contents/MacOS and may name it), or `MICROHM_MUX_LAUNCHER` — run as
///     `<launcher> serve --daemon --home <home>`;
///  2. a sibling `microhm-mux` next to the current process's executable
///     (`MicrohmPaths.siblingExecutable`): the .app's Contents/MacOS, or the SwiftPM
///     products directory.
///
/// The child is started with `posix_spawn` as the leader of a new session
/// (`POSIX_SPAWN_SETSID`): no controlling terminal and its own process group, so neither a
/// terminal closing nor a Ctrl+C in it nor the app quitting reaches it, and it outlives
/// the app. It starts in the user's home directory, stdin `/dev/null`, stdout and stderr
/// appended to `<home>/server.log`, every other descriptor closed
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), default signal dispositions and an empty mask. (`serve
/// --daemon` redirects its own stdio too and ignores SIGHUP/SIGINT; see `DaemonMode`.)
public enum ServerLauncher {

    public static let LAUNCHER_ENV = "MICROHM_MUX_LAUNCHER"
    public static let NATIVE_LAUNCHER = "microhm-mux"

    /// The subcommand and flag every resolved command ends with, before `--home`.
    static let SERVE_ARGS = ["serve", "--daemon"]

    /// The argv that would be used, ending in `serve --daemon` (`spawn` appends `--home
    /// <home>`), or nil when nothing resolves. Never spawns. Parameterised for tests.
    public static func resolveCommand(explicit: URL?, launcherEnv: String?, sibling: URL?) -> [String]? {
        if let explicit {
            return [explicit.standardizedFileURL.path] + SERVE_ARGS
        }
        if let env = launcherEnv, !env.trimmingCharacters(in: .whitespaces).isEmpty {
            // Configured on purpose: used as given, so a wrong path fails loudly at spawn
            // instead of silently falling through to a different server build.
            return [URL(fileURLWithPath: env).standardizedFileURL.path] + SERVE_ARGS
        }
        if let sibling {
            return [sibling.path] + SERVE_ARGS
        }
        return nil
    }

    public static func resolveCommand(explicit: URL? = nil) -> [String]? {
        resolveCommand(explicit: explicit, launcherEnv: ProcessInfo.processInfo.environment[LAUNCHER_ENV],
                       sibling: MicrohmPaths.siblingExecutable(NATIVE_LAUNCHER))
    }

    /// Spawns the server for `home`; returns the process. Throws `SessionServerException`
    /// when nothing resolves or the spawn fails.
    public static func spawn(_ home: URL, launcher: URL? = nil) throws -> SpawnedProcess {
        guard var command = resolveCommand(explicit: launcher) else {
            throw SessionServerException("cannot start the session daemon: no launcher given, no \(LAUNCHER_ENV),"
                                         + " and no \(NATIVE_LAUNCHER) next to \(CommandLine.arguments.first ?? "this program")")
        }
        command += ["--home", home.standardizedFileURL.path]
        do {
            // The append redirect below would create the log with the umask's permissions.
            try ServerHome.secure(home)
            try ServerHome.createLog(ServerHome.log(home))
            return try posixSpawn(command, log: ServerHome.log(home))
        } catch let error as SessionServerException {
            throw error
        } catch {
            throw SessionServerException("cannot start the session daemon (\(error)): \(command.joined(separator: " "))",
                                         cause: error)
        }
    }

    private static func posixSpawn(_ command: [String], log: URL) throws -> SpawnedProcess {
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        posix_spawn_file_actions_addchdir_np(&actions, userHome)

        var empty = sigset_t()
        var all = sigset_t()
        sigemptyset(&empty)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setsigdefault(&attr, &all)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let environment = ProcessInfo.processInfo.environment
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, command[0], &actions, &attr, argv, envp)
        if rc != 0 {
            throw MuxIOError("cannot run \(command[0]): \(errnoText(rc))")
        }
        return SpawnedProcess(pid: pid)
    }
}
