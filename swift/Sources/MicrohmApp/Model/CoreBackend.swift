import Foundation
import MicrohmCore
import MicrohmShared
import MicrohmTerminal

/// The daemon attachment is already push-style; it only needs to be named a transport.
extension SessionServerConnection: TerminalTransport {}

/// Builds the real backend over the core's daemon stack.
enum CoreBackendFactory {
    static func make(registry: SessionRegistry) -> SessionBackend {
        CoreBackend(registry: registry, host: SessionServerHost.forDefaultHome())
    }
}

/// The real backend (Java's wiring in `MicroHarnessManagerApp` and `MainWindow`): the
/// session daemon (`SessionServerHost`), and over it the `McpStack` — the launcher that
/// creates and resumes sessions, the session controller behind the MCP tools and the
/// phone page, the MCP service, the events agents' spawns and kills raise, and the phone
/// service. Only newSession ever spawns the daemon; with no daemon running every other call
/// answers "no sessions", so an app with no sessions costs nothing.
final class CoreBackend: SessionBackend, @unchecked Sendable {
    var name: String { "daemon at \(MicrohmPaths.muxHome.path)" }

    private let registry: SessionRegistry
    private let host: SessionServerHost
    private let stack: McpStack
    private var tokens: [SessionEvents.Token] = []
    private let tokensLock = NSLock()

    init(registry: SessionRegistry, host: SessionServerHost) {
        self.registry = registry
        self.host = host
        self.stack = McpStack.create(registry, host)
        // the phone page draws sessions in the app's own ANSI palette
        PhoneService.palette = { StyledScreen.palette(AppSettings.terminalPalette()) }
    }

    // StatusSessionHost
    func hasSession(_ session: String) throws -> Bool { try host.hasSession(session) }
    func sendKeys(_ session: String, _ command: String) throws { try host.sendKeys(session, command) }
    func capture(_ session: String) throws -> Screen { try host.capture(session) }

    func listSessions() throws -> [String] { try host.listSessions() }
    func killSession(_ session: String) throws { try host.killSession(session) }

    func attach(_ session: String, columns: Int, rows: Int) throws -> TerminalTransport {
        try host.attachConnection(session, columns, rows)
    }

    func create(projectPath: URL, harness: HarnessType, resumeId: String?, displayName: String?,
                firstMessage: String?, onNoResumeSyntax: @escaping () -> Void) throws -> String {
        guard let firstMessage, resumeId == nil else {
            return try stack.launcher.create(projectPath, harness, resumeId, displayName, [:],
                                             onNoResumeSyntax: onNoResumeSyntax)
        }
        // A first message goes through the controller's spawn, which types it in once the
        // agent is ready at its prompt (the phone page's New does the same).
        var args: [(String, CoreJSON)] = [("harness", .string(harness.id)), ("project", .string(projectPath.path)),
                                          ("prompt", .string(firstMessage))]
        if let displayName {
            args.append(("name", .string(displayName)))
        }
        let result = stack.controller.call(nil, "spawn", CoreJSON.obj(args))
        if result.isError {
            throw AppError(result.text)
        }
        // "<session> started (<harness> in <project>)…"
        return result.text.split(separator: " ").first.map(String.init) ?? ""
    }

    func resume(_ entry: SessionEntry, onNoResumeSyntax: @escaping () -> Void) throws {
        try stack.launcher.resume(entry, onNoResumeSyntax)
    }

    func discardMcpConfig(_ session: String) {
        stack.launcher.discardMcpConfig(session)
    }

    var mcpRunning: Bool { stack.service.isRunning() }
    func startMcp(port: Int, token: String) throws { try stack.service.start(port, token) }
    func stopMcp() { stack.service.stop() }

    var phoneRunning: Bool { stack.phone.isRunning() }
    func startPhone(port: Int, token: String) throws { try stack.phone.start(port, token) }
    func stopPhone() { stack.phone.stop() }
    func phoneLink(port: Int, token: String) -> String { PhoneService.link(port, token) }

    func setEventHandlers(changed: @escaping (String?) -> Void, killed: @escaping (String) -> Void,
                          runEnded: @escaping (String) -> Void) {
        let events = stack.events
        tokensLock.lock()
        tokens.append(events.addSessionsChangedListener(changed))
        tokens.append(events.addSessionKilledListener(killed))
        tokens.append(events.addSessionRunEndedListener(runEnded))
        tokensLock.unlock()
    }

    func describeShell(_ setting: String) -> String { ShellChoices.describe(setting) }
    func installedShells() -> [(value: String, label: String)] { ShellChoices.installed() }

    /// Stops serving, then — however many sessions still run — hands MCP and the phone
    /// page to the background host, which takes the registry until the app is back.
    func shutdown() {
        stack.service.stop()
        stack.phone.stop()
        if HostLauncher.launchIfNeeded(registry, host) {
            Log.info("background host started for the sessions still running", tag: "app")
        }
    }
}
