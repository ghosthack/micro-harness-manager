import Darwin
import Foundation
import MicrohmShared

/// Everything `serve` is told on its command line, plus the one tunable the design fixes at
/// 30 s (`behindTimeout`) that tests shorten so a stuck client can be observed being
/// dropped without waiting half a minute.
public struct ServeOptions: Sendable {

    public static let DEFAULT_HISTORY_LINES = 2000
    public static let DEFAULT_CLIENT_BUFFER_BYTES = 4 * 1024 * 1024
    public static let DEFAULT_BEHIND_TIMEOUT: TimeInterval = 30

    /// the server home (`ServerHome`)
    public let home: URL
    /// redirect stdio to `server.log` and ignore SIGHUP/SIGINT
    public let daemon: Bool
    /// ignore the idle timer (never auto-exit)
    public let keepAlive: Bool
    /// scrollback lines a redraw-on-attach replays
    public let historyLines: Int
    /// per-client outbound queue bound before the BEHIND policy kicks in
    public let clientBufferBytes: Int
    /// how long a BEHIND client may go without a completed write
    public let behindTimeout: TimeInterval

    public init(home: URL, daemon: Bool, keepAlive: Bool, historyLines: Int, clientBufferBytes: Int,
                behindTimeout: TimeInterval) throws {
        if historyLines < 0 { throw MuxError("history lines must be zero or greater") }
        if clientBufferBytes <= 0 { throw MuxError("client buffer must be positive") }
        self.home = home
        self.daemon = daemon
        self.keepAlive = keepAlive
        self.historyLines = historyLines
        self.clientBufferBytes = clientBufferBytes
        self.behindTimeout = behindTimeout
    }

    /// Foreground, auto-exiting, default sizes: what tests and plain `serve` use.
    public static func defaults(_ home: URL) -> ServeOptions {
        try! ServeOptions(home: home, daemon: false, keepAlive: false, historyLines: DEFAULT_HISTORY_LINES,
                          clientBufferBytes: DEFAULT_CLIENT_BUFFER_BYTES, behindTimeout: DEFAULT_BEHIND_TIMEOUT)
    }

    public func withClientBufferBytes(_ bytes: Int) -> ServeOptions {
        try! ServeOptions(home: home, daemon: daemon, keepAlive: keepAlive, historyLines: historyLines,
                          clientBufferBytes: bytes, behindTimeout: behindTimeout)
    }

    public func withBehindTimeout(_ timeout: TimeInterval) -> ServeOptions {
        try! ServeOptions(home: home, daemon: daemon, keepAlive: keepAlive, historyLines: historyLines,
                          clientBufferBytes: clientBufferBytes, behindTimeout: timeout)
    }

    public func withKeepAlive(_ value: Bool) -> ServeOptions {
        try! ServeOptions(home: home, daemon: daemon, keepAlive: value, historyLines: historyLines,
                          clientBufferBytes: clientBufferBytes, behindTimeout: behindTimeout)
    }
}

/// The version a server reports on `ping` and the CLI prints on `version`: the bundle's
/// `CFBundleShortVersionString` when there is one, else `"dev"`. Never empty, so a
/// mismatch message always has something to name.
public enum ServerVersion {
    public static let DEV = "dev"

    public static func current() -> String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return v
        }
        return DEV
    }
}

/// The one place `serve` obtains the real, PTY-backed `SessionManager`.
public enum SessionManagerFactory {
    public static func createSessionManager(_ options: ServeOptions) -> SessionManager {
        SessionManagerImpl(historyLines: options.historyLines)
    }
}

/// What `serve --daemon` does beyond plain `serve`: its own stdio goes to `server.log`
/// (append — the launcher already redirected the process's descriptors there, but a server
/// started by hand from a terminal must not die with that terminal's pipe either) and
/// SIGHUP and SIGINT are ignored so the parent's terminal closing or a Ctrl+C in it cannot
/// take the daemon down with the sessions it hosts.
public enum DaemonMode {
    public static func enter(_ log: URL) throws {
        try ServerHome.secure(log.deletingLastPathComponent())
        try ServerHome.createLog(log)
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw MuxIOError("cannot open \(log.path): \(errnoText())")
        }
        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            dup2(devNull, 0)
            close(devNull)
        }
        dup2(fd, 1)
        dup2(fd, 2)
        close(fd)
        setvbuf(stdout, nil, _IOLBF, 0)
        Log.shared.open(log)
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
    }
}
