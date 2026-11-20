import Foundation
import MicrohmMux
import MicrohmShared

/// Creates and resumes registered sessions: the blocking body behind the window's
/// Open…/Duplicate/Shell-here/Resume actions, and behind the MCP `spawn` tool. Free of UI
/// and safe from any background thread — every call blocks on host round trips (and
/// `sendKeys`' deliberate 400 ms pause), so never call it on the main thread.
///
/// A launch is: a unique `mhm-` name, the daemon session at the standard terminal size,
/// the `harness`/`project`/`display` labels (best effort), the harness launch command typed
/// into its shell, and the registry row. When the MCP service is running, the launch
/// command also registers the app's MCP server for that session (see
/// `HarnessPlugin.withMcpServer`).
///
/// The MCP token is never typed: a harness that reads it from the environment
/// (`HarnessPlugin.usesMcpTokenEnv`) gets a session started with it in its
/// `MHM_MCP_TOKEN` environment variable — no other session carries it — and a harness
/// that reads its MCP config from a file gets an owner-only `<mcpConfigDir>/<session>.json`
/// (rewritten on resume; `discardMcpConfig` deletes it once the session is gone). A daemon
/// that predates per-session environments starts the session without the variable; such a
/// session is launched without MCP (logged), since its harness could not authenticate.
public final class SessionLauncher: @unchecked Sendable {

    /// Label keys every launched session carries.
    public static let LABEL_HARNESS = "harness"
    public static let LABEL_PROJECT = "project"
    public static let LABEL_DISPLAY = "display"

    /// The standard terminal size a session starts at (`SessionTerminal.COLUMNS`/`ROWS`).
    public static let COLUMNS = 120
    public static let ROWS = 32

    /// How many times `reserveName` re-derives before giving up.
    static let MAX_NAME_ATTEMPTS = 32

    private let registry: SessionRegistry
    private let host: SessionHost
    private let mcpLinkFor: (String) -> McpLink?
    private let mcpConfigDir: URL
    private let labeller: SessionLabeller
    private let envStarter: EnvSessionStarter
    /// Whether to start agents in one step (`AppSettings.directLaunch`), asked per launch.
    var directLaunch: () -> Bool = { AppSettings.directLaunch() }
    /// The shell setting (`AppSettings.sessionShell`), asked per launch.
    var sessionShell: () -> String = { AppSettings.sessionShell() }
    var shells: SessionShell = SessionShell.system()

    /// Names derived but not yet visible to the host or registry; guarded by `reservedLock`.
    private var reserved: Set<String> = []
    private let reservedLock = NSLock()

    /// - mcpLinkFor: the MCP URL and token for a session name, or nil while the MCP service
    ///   is not running (then nothing is injected)
    /// - mcpConfigDir: where per-session MCP config files go (created owner-only)
    /// - labeller: sets daemon labels; `SessionLabellers.none` for none
    /// - envStarter: starts a session with the MCP token in its environment (used only while
    ///   the MCP service runs, and only for a harness that reads the token from there)
    public init(_ registry: SessionRegistry, _ host: SessionHost, _ mcpLinkFor: @escaping (String) -> McpLink?,
                _ mcpConfigDir: URL, _ labeller: @escaping SessionLabeller, _ envStarter: @escaping EnvSessionStarter) {
        self.registry = registry
        self.host = host
        self.mcpLinkFor = mcpLinkFor
        self.mcpConfigDir = mcpConfigDir
        self.labeller = labeller
        self.envStarter = envStarter
    }

    /// A launcher that never injects MCP (so never writes a config file or passes an
    /// environment): plain host sessions plus `labeller`'s labels.
    public static func withoutMcp(_ registry: SessionRegistry, _ host: SessionHost,
                                  _ labeller: @escaping SessionLabeller) -> SessionLauncher {
        SessionLauncher(registry, host, { _ in nil },
                        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("micro-harness-manager-unused-mcp"),
                        labeller, { _, _, _, _, _ in
                            throw SessionHostException("no MCP, no environment to pass")
                        })
    }

    /// Creates and registers a new session running `harness` in `projectPath` and returns
    /// its session name. The caller validates the directory beforehand. `labels` are extra
    /// daemon labels; `displayName`, when present and non-blank, becomes the row's
    /// display-name override. A resume id the harness has no syntax for falls back to a
    /// fresh launch: `onNoResumeSyntax` runs (on this thread) just before it (default: a
    /// logged warning).
    ///
    /// Throws whatever the host threw; a half-created session may be left behind, exactly
    /// as the window's create always did.
    @discardableResult
    public func create(_ projectPath: URL, _ harness: HarnessType, _ harnessSessionId: String?,
                       _ displayName: String?, _ labels: [String: String] = [:],
                       onNoResumeSyntax: (() -> Void)? = nil) throws -> String {
        let onNoResume = onNoResumeSyntax ?? {
            Log.warn("'\(harness.id)' has no known resume syntax — starting a fresh session instead", tag: "launcher")
        }
        let name = try reserveName(projectPath)
        defer {
            reservedLock.lock()
            reserved.remove(name)
            reservedLock.unlock()
        }
        let plugin = HarnessPlugins.of(harness)
        let display = displayName.flatMap { JavaText.isBlank($0) ? nil : $0 }
        var all = labels
        all[SessionLauncher.LABEL_HARNESS] = harness.id
        all[SessionLauncher.LABEL_PROJECT] = projectPath.path
        if let display {
            all[SessionLauncher.LABEL_DISPLAY] = display
        }
        var id = harnessSessionId
        let command: String
        let freshId = UUID().uuidString.lowercased()
        if id == nil, let withId = plugin.launchCommandWithId(freshId) {
            // a fresh launch names its own conversation, so the row knows the id
            // (transcript, resume) from the start; other harnesses learn it at exit
            command = withId
            id = freshId
        } else {
            command = SessionLauncher.launchCommand(plugin, id, onNoResume)
        }
        try start(name, projectPath, plugin, mcpLinkFor(name), command, all)
        let entry = SessionEntry.newlyCreated(name, projectPath.path, harness, id)
        registry.put(display.map { entry.withDisplayName($0) } ?? entry)
        return name
    }

    /// Starts a fresh daemon session under a dead registered row's name and relaunches its
    /// harness — resuming its conversation when the row has an id. The row itself is
    /// unchanged.
    public func resume(_ entry: SessionEntry, _ onNoResumeSyntax: @escaping () -> Void = {}) throws {
        let name = entry.sessionName
        let plugin = HarnessPlugins.of(entry.harnessType)
        var all: [String: String] = [
            SessionLauncher.LABEL_HARNESS: entry.harnessType.id,
            SessionLauncher.LABEL_PROJECT: entry.projectPath,
        ]
        if let display = entry.displayName, !JavaText.isBlank(display) {
            all[SessionLauncher.LABEL_DISPLAY] = display
        }
        let id = entry.harnessSessionIdOpt
        let project = URL(fileURLWithPath: entry.projectPath)
        var fresh: String?
        if let id, !plugin.canResume(id, project) {
            fresh = plugin.launchCommandWithId(id) ?? plugin.launchCommand()
        }
        // an id given at launch whose conversation never got a message has nothing to
        // resume: start it fresh, under the same id when the harness allows
        try start(name, project, plugin, mcpLinkFor(name),
                  fresh ?? SessionLauncher.launchCommand(plugin, id, onNoResumeSyntax), all)
    }

    /// Starts the session, labels it, and launches `command` in it: typed into the shell
    /// once it is up (the default), or, when the settings ask for one-step starts and the
    /// session's shell supports it, as the shell's own command, so nothing is typed while
    /// the shell's startup files run.
    private func start(_ name: String, _ workdir: URL, _ plugin: HarnessPlugin, _ mcp: McpLink?,
                       _ command: String, _ labels: [String: String]) throws {
        if !JavaText.isBlank(command), directLaunch(), let direct = host as? DirectSessionStarter {
            let line = mcp.map { withMcpServer(name, plugin, command, $0) } ?? command
            if let argv = shells.oneStep(sessionShell(), line) {
                if mcp == nil {
                    discardMcpConfig(name) // a stale token's file from an earlier lifecycle
                }
                let env: [String: String] = mcp != nil && plugin.usesMcpTokenEnv()
                    ? [HarnessPlugins.mcpTokenEnv: mcp!.token] : [:]
                let envApplied = try direct.newSession(name, workdir, SessionLauncher.COLUMNS, SessionLauncher.ROWS,
                                                       command: argv, env: env)
                if !env.isEmpty && !envApplied {
                    Log.warn("the running daemon predates per-session environment variables, so \(name) started "
                             + "without its MCP token; restart the daemon for MCP in such sessions", tag: "launcher")
                }
                label(name, labels)
                return
            }
        }
        let link = try newSession(name, workdir, plugin, mcp)
        label(name, labels)
        try sendLaunch(name, plugin, command, link)
    }

    /// The command a launch types: the resume command when an id is given and the harness
    /// has resume syntax, otherwise the fresh launch command (`onNoResumeSyntax` runs first
    /// when an id had to be dropped).
    public static func launchCommand(_ plugin: HarnessPlugin, _ harnessSessionId: String?,
                                     _ onNoResumeSyntax: () -> Void) -> String {
        guard let id = harnessSessionId else {
            return plugin.launchCommand()
        }
        if let resume = plugin.resumeCommand(id) {
            return resume
        }
        onNoResumeSyntax()
        return plugin.launchCommand()
    }

    /// Starts the host session at the standard size and returns the MCP link the launch may
    /// inject (`mcp`, or nil for none). A plain `newSession` — except while the MCP service
    /// runs for a harness that reads the token from the environment: then with the token in
    /// the session's environment. When the daemon predates per-session environments and
    /// starts the session without it, the harness could not authenticate, so the session is
    /// launched without MCP (nil).
    private func newSession(_ name: String, _ workdir: URL, _ plugin: HarnessPlugin, _ mcp: McpLink?) throws -> McpLink? {
        guard let mcp, plugin.usesMcpTokenEnv() else {
            try host.newSession(name, workdir, SessionLauncher.COLUMNS, SessionLauncher.ROWS)
            return mcp
        }
        let envApplied = try envStarter(name, workdir, SessionLauncher.COLUMNS, SessionLauncher.ROWS,
                                        [HarnessPlugins.mcpTokenEnv: mcp.token])
        if envApplied {
            return mcp
        }
        Log.warn("the running daemon predates per-session environment variables, so \(name) could not be given "
                 + "its MCP token: launching its \(plugin.type.id) without the micro-harness-manager MCP server. MCP "
                 + "for such sessions needs the daemon to be restarted (it is replaced once every session has ended)",
                 tag: "launcher")
        return nil
    }

    /// Types `command` unless blank (the pane's shell is the harness), with the MCP server
    /// injected while the service runs.
    private func sendLaunch(_ name: String, _ plugin: HarnessPlugin, _ command: String, _ mcp: McpLink?) throws {
        if mcp == nil {
            discardMcpConfig(name) // a stale token's file from an earlier lifecycle
        }
        if JavaText.isBlank(command) {
            return
        }
        try host.sendKeys(name, mcp.map { withMcpServer(name, plugin, command, $0) } ?? command)
    }

    /// `command` with the MCP server injected, after writing the harness's config file if
    /// it reads one; a file that cannot be written means launching without MCP.
    private func withMcpServer(_ name: String, _ plugin: HarnessPlugin, _ command: String, _ mcp: McpLink) -> String {
        let endpoint = McpEndpoint(url: mcp.url, token: mcp.token, configFile: mcpConfigFile(name))
        if let config = plugin.mcpConfigFile(endpoint) {
            do {
                try SessionLauncher.writeOwnerOnly(endpoint.configFile, config)
            } catch {
                Log.warn("could not write the MCP config for \(name) — launching it without MCP: \(error)", tag: "launcher")
                return command
            }
        }
        return plugin.withMcpServer(command, endpoint)
    }

    /// The per-session MCP config file; the name is reduced to file-safe characters.
    public func mcpConfigFile(_ session: String) -> URL {
        mcpConfigDir.appendingPathComponent(SessionLauncher.fileSafe(session) + ".json")
    }

    /// `name` with every character outside `[A-Za-z0-9._-]` replaced by `_`.
    static func fileSafe(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { s in
            let ok = (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
                || s == "." || s == "_" || s == "-"
            return ok ? s : "_"
        }))
    }

    /// Deletes `session`'s MCP config file (and the token in it), best effort — for when
    /// the session is killed or forgotten. Safe from any thread.
    public func discardMcpConfig(_ session: String) {
        let file = mcpConfigFile(session)
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            Log.warn("could not delete the MCP config for \(session): \(error)", tag: "launcher")
        }
    }

    /// Writes `content` to `file` so it is never readable by anyone but the owner, not even
    /// mid-write: a 0600 temp file in a 0700 directory, then an atomic replace.
    static func writeOwnerOnly(_ file: URL, _ content: String) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let temp = dir.appendingPathComponent(".mcp-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SessionHostException("cannot create \(temp.path): \(String(cString: strerror(errno)))")
        }
        let bytes = Array(content.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                let error = String(cString: strerror(errno))
                close(fd)
                throw SessionHostException("cannot write \(temp.path): \(error)")
            }
            written += n
        }
        close(fd)
        if rename(temp.path, file.path) != 0 {
            throw SessionHostException("cannot replace \(file.path): \(String(cString: strerror(errno)))")
        }
    }

    /// A name free in the registry, on the daemon, and among launches still in flight here
    /// — two concurrent launches in the same folder (the window and an agent) must not both
    /// derive `mhm-x-2`. The daemon probes run outside the lock, so a slow round trip never
    /// stalls another launch; the lock only covers re-checking the one chosen candidate —
    /// still not reserved and still not in the registry (a concurrent launch may have
    /// registered and released it meanwhile; a launch registers before it releases) — and
    /// adding it. A candidate that fails the re-check is re-derived, at most
    /// `MAX_NAME_ATTEMPTS` times.
    private func reserveName(_ projectPath: URL) throws -> String {
        for _ in 0..<SessionLauncher.MAX_NAME_ATTEMPTS {
            reservedLock.lock()
            let inFlight = reserved
            reservedLock.unlock()
            var probeError: Error?
            let name = try SessionNaming.deriveUnique(projectPath) { candidate in
                if inFlight.contains(candidate) || self.registry.find(candidate) != nil {
                    return true
                }
                do {
                    return try self.host.hasSession(candidate)
                } catch {
                    probeError = error
                    return true
                }
            }
            if let probeError {
                throw probeError
            }
            reservedLock.lock()
            if !reserved.contains(name) && registry.find(name) == nil {
                reserved.insert(name)
                reservedLock.unlock()
                return name
            }
            reservedLock.unlock()
        }
        throw SessionHostException("could not reserve a session name for \(projectPath.path) after "
                                   + "\(SessionLauncher.MAX_NAME_ATTEMPTS) attempts")
    }

    private func label(_ name: String, _ labels: [String: String]) {
        do {
            try labeller(name, labels)
        } catch {
            if SessionLauncher.predatesLabels(error) {
                // a daemon older than labels: the registry entry still names the session
                Log.debug("not labelling session \(name): \(error)", tag: "launcher")
            } else {
                Log.warn("could not label session \(name): \(error)", tag: "launcher")
            }
        }
    }

    /// Whether `error` (or what it wraps) is a daemon refusing an op it predates.
    static func predatesLabels(_ error: Error) -> Bool {
        var current: Error? = error
        while let e = current {
            if let s = e as? SessionServerException {
                if s.isUnsupported { return true }
                current = s.cause
            } else if let h = e as? SessionHostException {
                current = h.cause
            } else {
                return false
            }
        }
        return false
    }
}
