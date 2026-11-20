import Foundation

/// Where the Swift port keeps its state. Deliberately separate from the Java app's
/// `~/.micro-harness-manager` so both can run side by side without touching each other's
/// sessions, daemon, settings or ports.
///
/// Overrides (checked in order): environment `MICROHM_HOME`, then the default
/// `~/.micro-harness-manager-swift`. The daemon home is `$home/mux` unless
/// `MICROHM_MUX_HOME` is set. Tests always point `MICROHM_HOME` at a scratch directory.
public enum MicrohmPaths {
    public static let defaultHomeName = ".micro-harness-manager-swift"

    /// Default ports — offset from the Java app's 7392/7393 so both can run at once.
    public static let defaultMcpPort = 7402
    public static let defaultPhonePort = 7403

    /// Per-process override, set by tests or `--home` flags before anything resolves a path.
    nonisolated(unsafe) public static var homeOverride: URL?

    public static var home: URL {
        if let o = homeOverride { return o }
        if let env = ProcessInfo.processInfo.environment["MICROHM_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultHomeName, isDirectory: true)
    }

    public static var muxHome: URL {
        if let env = ProcessInfo.processInfo.environment["MICROHM_MUX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("mux", isDirectory: true)
    }

    public static var registryFile: URL { home.appendingPathComponent("sessions.json") }
    public static var settingsFile: URL { home.appendingPathComponent("settings.properties") }
    public static var mcpConfigDir: URL { home.appendingPathComponent("mcp", isDirectory: true) }
    public static var instanceLock: URL { home.appendingPathComponent("instance.lock") }
    public static var appLog: URL { home.appendingPathComponent("app.log") }
    public static var mcpHostLog: URL { home.appendingPathComponent("mcp-host.log") }

    /// Creates `dir` (and parents) owner-only (0700) if missing.
    @discardableResult
    public static func ensureDirectory(_ dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Locates a sibling executable (`microhm-mux`, `microhm-host`) next to the running one:
    /// inside the .app that is Contents/MacOS, in a SwiftPM build it is the products dir.
    public static func siblingExecutable(_ name: String) -> URL? {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            me.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
