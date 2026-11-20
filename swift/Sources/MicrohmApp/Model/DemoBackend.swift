import Foundation
import MicrohmCore
import MicrohmTerminal

/// Canned sessions for UI work and screenshots (`MICROHM_DEMO=1`): a few live sessions in
/// every state, one dead one, terminals that draw a plausible screen and echo typing.
/// Never starts a daemon or a process; its registry rows go to whatever `MICROHM_HOME`
/// points at.
final class DemoBackend: SessionBackend, @unchecked Sendable {
    var name: String { "demo" }

    private let lock = NSLock()
    private var live: [String: Classification?] = [:]
    private let registry: SessionRegistry
    private var mcpOn = false
    private var phoneOn = false
    private var changed: ((String?) -> Void)?

    init(registry: SessionRegistry) {
        self.registry = registry
        let home = NSHomeDirectory()
        let microhm = home + "/Projects/gitlab/micro-harness-manager"
        let site = home + "/Projects/site"
        let notes = home + "/Documents/notes"
        let api = home + "/Projects/api"
        let seed: [(String, String, HarnessType, String?, Classification?, Bool)] = [
            ("mhm-micro-harness-manager", microhm, .claudeCode, "Port the AppKit UI",
             Classification(.working, .high, "spinner on screen", .plugin), true),
            ("mhm-micro-harness-manager-2", microhm, .codex, nil,
             Classification(.waitingForInput, .high, "approval prompt", .plugin), true),
            ("mhm-micro-harness-manager-3", microhm, .shell, nil,
             Classification(.idle, .high, "shell prompt", .behavioral), true),
            ("mhm-site", site, .claudeCode, "Landing page copy",
             Classification(.idle, .medium, "quiet composer", .plugin), true),
            ("mhm-notes", notes, .opencode, nil, nil, true),
            ("mhm-api", api, .grok, "Rate limiter", nil, false),
        ]
        for (name, path, harness, display, state, isLive) in seed {
            if registry.find(name) == nil {
                let entry = SessionEntry.newlyCreated(name, path, harness, nil)
                registry.put(display.map { entry.withDisplayName($0) } ?? entry)
            }
            if isLive {
                live[name] = .some(state)
            }
        }
    }

    func listSessions() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(live.keys)
    }

    func hasSession(_ session: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live[session] != nil
    }

    func sendKeys(_ session: String, _ command: String) throws {}

    func capture(_ session: String) throws -> Screen {
        let alive = (try? hasSession(session)) ?? false
        return Screen("$ ", !alive, Date(), "zsh", 1, "")
    }

    func fixedClassification(_ session: String) -> Classification? {
        lock.lock(); defer { lock.unlock() }
        if let state = live[session] { return state }
        return nil
    }

    func killSession(_ session: String) throws {
        lock.lock()
        live[session] = nil
        lock.unlock()
    }

    func attach(_ session: String, columns: Int, rows: Int) throws -> TerminalTransport {
        guard try hasSession(session) else { throw AppError("no session named \(session)") }
        Thread.sleep(forTimeInterval: 0.15) // a daemon connect takes a moment
        let harness = registry.find(session)?.harnessType ?? .shell
        return DemoTransport(screen: DemoScreens.screen(for: harness, session: session))
    }

    func create(projectPath: URL, harness: HarnessType, resumeId: String?, displayName: String?,
                firstMessage: String?, onNoResumeSyntax: @escaping () -> Void) throws -> String {
        let name = try SessionNaming.deriveUnique(projectPath) { [self] candidate in
            registry.find(candidate) != nil || ((try? hasSession(candidate)) ?? false)
        }
        let entry = SessionEntry.newlyCreated(name, projectPath.path, harness, resumeId)
        registry.put(displayName.map { entry.withDisplayName($0) } ?? entry)
        lock.lock()
        live[name] = .some(nil)
        lock.unlock()
        return name
    }

    func resume(_ entry: SessionEntry, onNoResumeSyntax: @escaping () -> Void) throws {
        lock.lock()
        live[entry.sessionName] = .some(Classification(.idle, .low, "resumed", .behavioral))
        lock.unlock()
    }

    func discardMcpConfig(_ session: String) {}

    var mcpRunning: Bool { mcpOn }
    func startMcp(port: Int, token: String) throws { mcpOn = true }
    func stopMcp() { mcpOn = false }

    var phoneRunning: Bool { phoneOn }
    func startPhone(port: Int, token: String) throws { phoneOn = true }
    func stopPhone() { phoneOn = false }
    func phoneLink(port: Int, token: String) -> String { PhoneLink.link(port: port, token: token) }

    func setEventHandlers(changed: @escaping (String?) -> Void, killed: @escaping (String) -> Void,
                          runEnded: @escaping (String) -> Void) {
        self.changed = changed
    }

    func describeShell(_ setting: String) -> String { ShellChoices.describe(setting) }
    func installedShells() -> [(value: String, label: String)] { ShellChoices.installed() }
    func shutdown() {}
}

/// A transport that paints a canned screen, then echoes what is typed.
final class DemoTransport: TerminalTransport, @unchecked Sendable {
    var onBytes: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    private let screen: String
    private var closed = false

    init(screen: String) {
        self.screen = screen
    }

    func start() {
        let bytes = Data(screen.utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.onBytes?(bytes)
        }
    }

    func send(_ bytes: Data) {
        var echo = Data()
        for byte in bytes {
            switch byte {
            case 0x0D: echo.append(contentsOf: [0x0D, 0x0A])
            case 0x7F: echo.append(contentsOf: [0x08, 0x20, 0x08])
            default: echo.append(byte)
            }
        }
        onBytes?(echo)
    }

    func resize(cols: Int, rows: Int) {}

    var isAlive: Bool { !closed }

    func close() {
        closed = true
    }
}

enum DemoScreens {
    private static let esc = "\u{1B}["

    static func screen(for harness: HarnessType, session: String) -> String {
        switch harness {
        case .claudeCode: return claude
        case .codex: return codex
        default: return shell(session)
        }
    }

    private static var claude: String {
        let o = esc + "38;5;209m", d = esc + "2m", r = esc + "0m", b = esc + "1m", g = esc + "32m"
        return """
        \(o)╭───────────────────────────────────────────────╮\(r)\r
        \(o)│\(r) \(o)✻\(r) Welcome to \(b)Claude Code\(r)!                       \(o)│\(r)\r
        \(o)│\(r)                                               \(o)│\(r)\r
        \(o)│\(r)   \(d)cwd: ~/Projects/gitlab/micro-harness-manager\(r)\(o)│\(r)\r
        \(o)╰───────────────────────────────────────────────╯\(r)\r
        \r
        \(b)>\(r) Port the sidebar to an NSOutlineView source list\r
        \r
        \(g)⏺\(r) I'll start with the row view: avatar, name, path and badge.\r
        \r
        \(g)⏺\(r) \(b)Update\(r)(swift/Sources/MicrohmApp/Sidebar/SidebarCellView.swift)\r
          ⎿  Updated with \(g)142 additions\(r) and \(esc)31m3 removals\(r)\r
        \r
        \(o)✶\(r) Compiling… \(d)(12s · ↓ 2.1k tokens · esc to interrupt)\(r)\r
        \r
        \(d)╭─────────────────────────────────────────────────────────╮\(r)\r
        \(d)│\(r) >                                                       \(d)│\(r)\r
        \(d)╰─────────────────────────────────────────────────────────╯\(r)\r
          \(d)⏵⏵ accept edits on (shift+tab to cycle)\(r)
        """
    }

    private static var codex: String {
        let c = esc + "36m", d = esc + "2m", r = esc + "0m", b = esc + "1m", y = esc + "33m"
        return """
        \(b)>_ OpenAI Codex\(r) \(d)(v0.58)\(r)\r
        \r
        \(c)model:\(r)     gpt-5-codex  \(d)/model to change\(r)\r
        \(c)directory:\(r) ~/Projects/gitlab/micro-harness-manager\r
        \r
        \(b)▌\(r) Run the Swift test suite and fix what fails\r
        \r
        \(y)•\(r) Ran swift test --scratch-path .build-ui\r
          └ \(d)Build complete! (41.2s)\(r)\r
        \r
        \(b)Allow command?\(r)\r
          \(c)$ git checkout -- swift/Package.resolved\(r)\r
        \r
          \(b)› 1. Yes, proceed\(r)\r
            2. Yes, and don't ask again for this command\r
            3. No, and tell Codex what to do differently \(d)esc\(r)\r
        \r
        \(d)Press enter to confirm or esc to cancel\(r)
        """
    }

    private static func shell(_ session: String) -> String {
        let g = esc + "32m", bl = esc + "34m", d = esc + "2m", r = esc + "0m", b = esc + "1m"
        return """
        \(d)Last login: Fri Nov 20 09:41:07 on ttys004\(r)\r
        \(g)\(b)tester@m2air\(r) \(bl)micro-harness-manager\(r) % git status --short\r
         M swift/Sources/microhm-mux/main.swift\r
        ?? swift/Sources/MicrohmApp/\r
        \(g)\(b)tester@m2air\(r) \(bl)micro-harness-manager\(r) % ls swift/Sources\r
        \(bl)MicrohmApp\(r)       \(bl)MicrohmMux\(r)       \(bl)MicrohmShared\(r)    \(bl)MicrohmVT\(r)\r
        \(bl)MicrohmCore\(r)      \(bl)MicrohmPTY\(r)       \(bl)MicrohmTerminal\(r)  \(bl)microhm-mux\(r)\r
        \(g)\(b)tester@m2air\(r) \(bl)micro-harness-manager\(r) %
        """
    }
}
