import Darwin
import Foundation
import MicrohmShared

/// Where one server lives: a directory holding the socket, the lock and the log. One
/// server per home; the app and the CLI share the default home, and tests use a temporary
/// one so they never touch (or spawn) the user's real server.
///
/// Default: `MicrohmPaths.muxHome` (`~/.micro-harness-manager-swift/mux`). Override with
/// `MICROHM_MUX_HOME` (or `MICROHM_HOME`, whose `mux` it then is). Unix-domain socket paths
/// have a small length ceiling (104 bytes on macOS), so a deeply nested override may fail
/// to bind with a clear error.
///
/// Access control: whoever can connect to the socket can run commands as the daemon's
/// user, so the home is the trust boundary. It is private to its owner (`0700`, as are the
/// socket and the log at `0600`), and neither side uses a home that belongs to someone
/// else: a directory another user created could hold their socket in place of ours.
public enum ServerHome {

    public static let HOME_ENV = "MICROHM_MUX_HOME"
    public static let SOCKET_FILE = "server.sock"
    public static let LOCK_FILE = "server.lock"
    public static let LOG_FILE = "server.log"

    public static func resolve() -> URL {
        URL(fileURLWithPath: MicrohmPaths.muxHome.path, isDirectory: true).standardizedFileURL
    }

    public static func socket(_ home: URL) -> URL { home.appendingPathComponent(SOCKET_FILE) }
    public static func lock(_ home: URL) -> URL { home.appendingPathComponent(LOCK_FILE) }
    public static func log(_ home: URL) -> URL { home.appendingPathComponent(LOG_FILE) }

    /// Creates `home` private to the current user, or makes an existing one of theirs
    /// private. Throws when it belongs to someone else. Used by whoever is about to create
    /// something in the home: the daemon, and the client that launches it.
    public static func secure(_ home: URL) throws {
        let path = home.path
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try? FileManager.default.createDirectory(at: home.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // Created private rather than tightened afterwards: no moment in between.
            if mkdir(path, 0o700) != 0 && errno != EEXIST {
                throw MuxIOError("cannot create \(path): \(errnoText())")
            }
        }
        try requireOwned(home)
        var st = stat()
        if stat(path, &st) == 0 && (st.st_mode & 0o777) != 0o700 {
            if chmod(path, 0o700) != 0 {
                throw MuxIOError("cannot make \(path) private: \(errnoText())")
            }
        }
    }

    /// Throws when `home` exists and belongs to another user; a missing home is fine (no
    /// server there). What a client checks before it connects.
    public static func requireOwned(_ home: URL) throws {
        var st = stat()
        if stat(home.path, &st) != 0 {
            return
        }
        if st.st_uid != getuid() {
            let owner = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? String(st.st_uid)
            throw MuxIOError("the session server home \(home.path) belongs to another user (\(owner)); refusing"
                             + " to use it. Set \(HOME_ENV) to a directory of your own")
        }
    }

    /// Creates the log private to its owner if it is missing, and makes an existing one
    /// private: it records every session's command line. Call after `secure`.
    public static func createLog(_ log: URL) throws {
        let fd = open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd >= 0 {
            close(fd)
            return
        }
        if errno != EEXIST {
            throw MuxIOError("cannot create \(log.path): \(errnoText())")
        }
        try restrict(log)
    }

    /// Makes a file of ours in the home (`server.sock`, `server.log`) readable and writable
    /// by its owner only.
    static func restrict(_ file: URL) throws {
        var st = stat()
        if stat(file.path, &st) == 0 && (st.st_mode & 0o777) != 0o600 {
            if chmod(file.path, 0o600) != 0 {
                throw MuxIOError("cannot restrict \(file.path): \(errnoText())")
            }
        }
    }
}
