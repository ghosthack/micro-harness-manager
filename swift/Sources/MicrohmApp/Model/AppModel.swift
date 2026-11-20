import Foundation
import MicrohmCore
import MicrohmShared
import MicrohmTerminal

/// Everything the window needs from the session daemon, the launcher, the MCP stack and
/// the phone page, as one seam. This protocol and its implementations (in this folder) are
/// the only code in the app that touches `control/`, `session/`, `daemon/`, `mcp/`,
/// `mcphost/` and `phone/` — the window, dialogs and status item only ever see
/// `AppModel`. Every call here may block (socket round trips, process launches): callers
/// run them off the main thread.
///
/// Error semantics mirror Java's `SessionHost`: "no server running" is not an error for
/// `listSessions` (empty) and `hasSession` (false); everything else throws with a
/// message fit for the user.
protocol SessionBackend: StatusSessionHost {

    /// Short description for the About panel and the log.
    var name: String { get }

    func listSessions() throws -> [String]
    func killSession(_ session: String) throws

    /// Opens an attach stream to `session` at the given grid size.
    func attach(_ session: String, columns: Int, rows: Int) throws -> TerminalTransport

    /// Creates and registers a new session; returns its session name. `firstMessage`, when
    /// present, is typed into the agent once it is ready at its prompt (the phone page's
    /// and MCP spawn's "prompt").
    func create(projectPath: URL, harness: HarnessType, resumeId: String?, displayName: String?,
                firstMessage: String?, onNoResumeSyntax: @escaping () -> Void) throws -> String

    /// Starts a fresh daemon session under a dead row's name and relaunches its harness.
    func resume(_ entry: SessionEntry, onNoResumeSyntax: @escaping () -> Void) throws

    /// Deletes a gone session's MCP config file (its copy of the token).
    func discardMcpConfig(_ session: String)

    // MCP server
    var mcpRunning: Bool { get }
    func startMcp(port: Int, token: String) throws
    func stopMcp()

    // phone page
    var phoneRunning: Bool { get }
    func startPhone(port: Int, token: String) throws
    func stopPhone()
    func phoneLink(port: Int, token: String) -> String

    /// Sessions created or killed outside the window (MCP agents, the phone page). The
    /// callbacks may fire on any thread.
    func setEventHandlers(changed: @escaping (String?) -> Void, killed: @escaping (String) -> Void,
                          runEnded: @escaping (String) -> Void)

    /// The New dialog's "Shell:" line, and Settings' shell choices.
    func describeShell(_ setting: String) -> String
    func installedShells() -> [(value: String, label: String)]

    /// Demo backends pin each session's state so screenshots show every badge; real
    /// backends return nil and the status poller decides.
    func fixedClassification(_ session: String) -> Classification?

    /// The app is quitting: stop serving and hand off to the background host if needed.
    func shutdown()
}

extension SessionBackend {
    func fixedClassification(_ session: String) -> Classification? { nil }
}

/// The app's model: the session registry (real, from `MicrohmCore`) and the backend
/// seam. Created once in `AppDelegate`.
final class AppModel: @unchecked Sendable {

    static let appName = "Microhm"

    let registry: SessionRegistry
    let backend: SessionBackend
    let usage = HarnessUsageService()

    init(registry: SessionRegistry, backend: SessionBackend) {
        self.registry = registry
        self.backend = backend
    }

    /// Picks the backend: `MICROHM_DEMO=1` for the canned demo sessions (screenshots,
    /// UI work without a daemon); otherwise the real daemon stack once it is linked in,
    /// and until then a stand-in that reports the daemon unavailable.
    static func makeDefault() -> AppModel {
        let registry = SessionRegistry.load()
        let env = ProcessInfo.processInfo.environment
        if env["MICROHM_DEMO"] == "1" {
            return AppModel(registry: registry, backend: DemoBackend(registry: registry))
        }
        return AppModel(registry: registry, backend: CoreBackendFactory.make(registry: registry))
    }

    /// Whether `ui.theme` is set explicitly; unset, the app follows the system live.
    static func hasExplicitSetting(_ key: String) -> Bool {
        guard let text = try? String(contentsOf: AppSettings.settingsFile(), encoding: .isoLatin1) else {
            return false
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("!") { continue }
            if line.hasPrefix(key) {
                let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("=") || rest.hasPrefix(":") { return true }
            }
        }
        return false
    }
}

/// A backend for when the daemon stack is not available in this build: the sidebar shows
/// the registry's sessions as dead (resumable once it is), and anything that needs the
/// daemon fails with a clear message instead of crashing.
final class UnavailableBackend: SessionBackend, @unchecked Sendable {
    let reason: String
    var name: String { "unavailable (\(reason))" }

    init(reason: String) {
        self.reason = reason
    }

    private func failure() -> Error {
        AppError("The session daemon is not available in this build: \(reason)")
    }

    func listSessions() throws -> [String] { [] }
    func hasSession(_ session: String) throws -> Bool { false }
    func sendKeys(_ session: String, _ command: String) throws { throw failure() }
    func capture(_ session: String) throws -> Screen { Screen("", true, Date()) }
    func killSession(_ session: String) throws { throw failure() }
    func attach(_ session: String, columns: Int, rows: Int) throws -> TerminalTransport { throw failure() }
    func create(projectPath: URL, harness: HarnessType, resumeId: String?, displayName: String?,
                firstMessage: String?, onNoResumeSyntax: @escaping () -> Void) throws -> String {
        throw failure()
    }
    func resume(_ entry: SessionEntry, onNoResumeSyntax: @escaping () -> Void) throws { throw failure() }
    func discardMcpConfig(_ session: String) {}
    var mcpRunning: Bool { false }
    func startMcp(port: Int, token: String) throws { throw failure() }
    func stopMcp() {}
    var phoneRunning: Bool { false }
    func startPhone(port: Int, token: String) throws { throw failure() }
    func stopPhone() {}
    func phoneLink(port: Int, token: String) -> String { PhoneLink.link(port: port, token: token) }
    func setEventHandlers(changed: @escaping (String?) -> Void, killed: @escaping (String) -> Void,
                          runEnded: @escaping (String) -> Void) {}
    func describeShell(_ setting: String) -> String { ShellChoices.describe(setting) }
    func installedShells() -> [(value: String, label: String)] { ShellChoices.installed() }
    func shutdown() {}
}

/// A plain error with a user-facing message.
struct AppError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

/// Java's `PhoneService.link`: `http://<this Mac's LAN address>:<port>/#<token>`. Used by
/// backends that have no phone service of their own.
enum PhoneLink {
    static func link(port: Int, token: String) -> String {
        "http://\(lanAddress() ?? "localhost"):\(port)/#k=\(token)"
    }

    /// The first non-loopback IPv4 address, preferring en0.
    static func lanAddress() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var candidates: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: ifa.pointee.ifa_name)
                candidates.append((name, String(cString: host)))
            }
        }
        return (candidates.first { $0.0 == "en0" } ?? candidates.first)?.1
    }
}

/// The shells a session can start in, as the core's `SessionShell` lists them.
enum ShellChoices {
    static func describe(_ setting: String) -> String {
        SessionShell.system().describe(setting)
    }

    static func installed() -> [(value: String, label: String)] {
        let shells = SessionShell.system()
        return shells.installedNames().map { ($0, shells.displayName($0)) }
    }
}
