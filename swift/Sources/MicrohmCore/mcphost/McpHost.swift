import Darwin
import Foundation
import MicrohmMux
import MicrohmShared

/// The session launcher, the MCP tools (the session controller over the daemon) and the MCP
/// service, wired together. Built the same way by the window and by the headless host, so
/// an agent sees the same tools whichever one is serving.
///
/// Sessions launched while the service runs get its URL in their launch command (the token
/// rides in their environment or an owner-only config file, never on the command line).
/// The launcher asks the service for URLs and tokens and the service hosts the controller
/// that uses the launcher, hence the late-bound reference. `events` carries what agents
/// create or kill to whoever listens (the window's sidebar). `phone` serves the phone page
/// over the same controller.
public final class McpStack: @unchecked Sendable {
    public let launcher: SessionLauncher
    public let controller: SessionController
    public let service: McpService
    public let events: SessionEvents
    public let phone: PhoneService

    init(_ launcher: SessionLauncher, _ controller: SessionController, _ service: McpService, _ events: SessionEvents,
         _ phone: PhoneService) {
        self.launcher = launcher
        self.controller = controller
        self.service = service
        self.events = events
        self.phone = phone
    }

    public static func create(_ registry: SessionRegistry, _ host: SessionServerHost) -> McpStack {
        let serviceRef = Atomic<McpService?>(wrappedValue: nil)
        let events = SessionEvents()
        let launcher = SessionLauncher(registry, host, { session in serviceRef.wrappedValue?.linkFor(session) },
                                       RegistryPaths.resolveMcpConfigDir(), { try host.label($0, $1) },
                                       { try host.newSession($0, $1, $2, $3, env: $4) })
        let controller = SessionController(ClientDaemonControl(host.client()), registry,
                                           LauncherSpawner(launcher, host, events), SystemClock.shared)
        let service = McpService(controller)
        serviceRef.wrappedValue = service
        let phone = PhoneService(PhoneBackends.of(controller, PhoneCloser(host, registry, events)))
        return McpStack(launcher, controller, service, events, phone)
    }
}

/// The background host: what keeps running for the user while the app is closed and their
/// sessions run on. It serves the app's MCP server, so agents keep their session tools,
/// when that is on, and the phone page when that is on; with neither it does not run.
/// Started by the app as it quits (see `HostLauncher`) while registered sessions are live; it
///
/// - waits for the registry's instance lock, which the quitting app releases as it exits,
///   and records itself in `HostOwner.file`;
/// - when MCP is on, serves the same tools on the same port and token as the app, so every
///   session's MCP config keeps working unchanged;
/// - exits once no registered session is live on the daemon, and when the app starts again,
///   which stops it (`HostOwner.stop`) and takes the lock over.
///
/// State an agent built up in the server is not carried across a hand-off: an incremental
/// `read` starts over with the whole screen, and pending `notify` waits end.
///
/// (The Java host also showed a menu-bar icon; this build's host has none.)
public enum McpHost {

    /// The command-line flag that selects this mode.
    public static let FLAG = "--mcp-host"
    /// The phone page on its own (Java's `PhoneMain`): no background-host lifecycle, no lock.
    public static let PHONE_ONLY_FLAG = "--phone-only"
    /// The app's registry file, so the host finds the same settings, MCP configs and lock.
    public static let REGISTRY_OPTION = "--registry="
    /// The app's state directory (the registry's folder).
    public static let HOME_OPTION = "--home="
    /// The app's daemon home, so the host talks to the same daemon.
    public static let MUX_HOME_OPTION = "--mux-home="
    /// What `--phone-only` prints once it serves (the end-to-end tests wait for it).
    public static let READY = "phone page ready on port "

    /// How long to wait for the quitting app to release the lock.
    static let LOCK_WAIT: TimeInterval = 30
    /// How often to check whether any registered session is still live.
    static let CHECK_EVERY: TimeInterval = 15
    /// Consecutive checks that must find nothing live before exiting: one daemon hiccup must
    /// not end the host.
    static let EMPTY_CHECKS_TO_EXIT = 2

    /// `microhm-host`'s entry point; returns the exit status.
    /// Makes the menu-bar icon (Java's `StatusIcon`) for the host's life; set by the
    /// `microhm-host` executable, which owns AppKit (this module doesn't link it). Called on
    /// the host's watch thread; nil (or a nil result) means no icon.
    nonisolated(unsafe) public static var statusIconFactory:
        ((_ onOpen: @escaping () -> Void, _ onHide: @escaping () -> Void) -> HostStatusIcon?)?

    public static func main(_ args: [String]) -> Int32 {
        if args.contains(PHONE_ONLY_FLAG) {
            return phoneMain(args)
        }
        return run(args)
    }

    /// The background host's life (see the type's documentation).
    public static func run(_ args: [String]) -> Int32 {
        applyStateOptions(args)
        let mcp = AppSettings.mcpServerEnabled()
        let phone = AppSettings.phoneServerEnabled()
        let wantIcon = AppSettings.trayIconEnabled() && statusIconFactory != nil
        if !mcp && !phone && !wantIcon {
            Log.info("neither the MCP server, the phone page nor the menu-bar icon is on; nothing to host", tag: "host")
            return 0
        }
        let registryFile = RegistryPaths.resolve()
        if InstanceLock.acquire(registryFile, LOCK_WAIT) == .HELD {
            Log.info("the registry at \(registryFile.path) is in use (the app is open); not hosting", tag: "host")
            return 0
        }
        let me = HostOwner.current()
        if let me {
            do {
                try HostOwner.write(registryFile, me)
            } catch {
                Log.warn("could not record the background host in \(HostOwner.file(registryFile).path): \(error)", tag: "host")
            }
        }
        let registry = SessionRegistry.load(registryFile)
        let host = SessionServerHost.forDefaultHome()
        var live = liveRegistered(registry, host)
        if live == 0 {
            Log.info("no registered session is live; not hosting", tag: "host")
            me.map { HostOwner.clear(registryFile, $0) }
            return 0
        }

        let stack = McpStack.create(registry, host)
        var servingPort = -1
        if mcp {
            do {
                try stack.service.start(AppSettings.mcpPort(), AppSettings.mcpToken())
                servingPort = AppSettings.mcpPort()
            } catch {
                Log.warn("background host could not serve MCP on port \(AppSettings.mcpPort()): \(error)", tag: "host")
            }
        }
        var phoneServing = false
        if phone {
            do {
                try stack.phone.start(AppSettings.phonePort(), AppSettings.phoneToken())
                phoneServing = true
            } catch {
                Log.warn("background host could not serve the phone page on port \(AppSettings.phonePort()): \(error)",
                         tag: "host")
            }
        }
        // the icon's Hide flips this from the main thread; the watch loop below reads it
        let iconLock = NSLock()
        var icon: HostStatusIcon?
        if wantIcon, let factory = statusIconFactory {
            icon = factory({ HostLauncher.openApp() }, {
                AppSettings.saveTrayIconEnabled(false)
                iconLock.lock()
                let shown = icon
                icon = nil
                iconLock.unlock()
                shown?.remove()
                // with nothing else to do, hiding the icon ends the host, as in Java
                if servingPort <= 0 && !phoneServing {
                    Log.info("menu-bar icon hidden and nothing to serve; background host exiting", tag: "host")
                    me.map { HostOwner.clear(registryFile, $0) }
                    exit(0)
                }
            })
        }
        func refreshIcon(_ live: Int) {
            iconLock.lock()
            let shown = icon
            iconLock.unlock()
            shown?.update(liveSessions: live, mcpPort: servingPort > 0 ? servingPort : nil,
                          phonePort: phoneServing ? AppSettings.phonePort() : nil)
        }
        refreshIcon(live)
        if servingPort <= 0 && !phoneServing && icon == nil {
            Log.info("nothing to show or serve (no icon, MCP and the phone page off or unavailable); exiting", tag: "host")
            me.map { HostOwner.clear(registryFile, $0) }
            return 0
        }
        onTermination {
            stack.service.stop()
            stack.phone.stop()
            me.map { HostOwner.clear(registryFile, $0) }
        }
        Log.info("background host running while the app is closed: "
                 + (servingPort > 0 ? "MCP on 127.0.0.1:\(servingPort)" : "no MCP")
                 + (phoneServing ? ", phone page on port \(AppSettings.phonePort())" : "")
                 + (icon != nil ? ", menu-bar icon shown" : ", no menu-bar icon")
                 + " (" + (me.map(HostOwner.describe) ?? "pid \(getpid())") + ")", tag: "host")

        var empty = 0
        while empty < EMPTY_CHECKS_TO_EXIT {
            Thread.sleep(forTimeInterval: CHECK_EVERY)
            live = liveRegistered(registry, host)
            empty = live == 0 ? empty + 1 : 0
            refreshIcon(live)
        }
        iconLock.lock()
        let shown = icon
        iconLock.unlock()
        shown?.remove()
        Log.info("no registered session is live any more; background host exiting", tag: "host")
        stack.service.stop()
        stack.phone.stop()
        me.map { HostOwner.clear(registryFile, $0) }
        return 0
    }

    /// The phone page on its own: no window, no background host, no instance lock. It
    /// serves the page on a port with a secret, over the same controller the app builds
    /// (`McpStack`), until the process is stopped. For working on the page and for its
    /// end-to-end tests, which point it at a scratch registry and daemon home so it never
    /// sees the user's sessions:
    ///
    ///     microhm-host --phone-only --port=7403 --token=SECRET [--registry=/tmp/x/sessions.json] [--mux-home=/tmp/x/mux]
    ///
    /// Prints `phone page ready on port N` once it is serving. `--mcp-port=N` (and optionally
    /// `--mcp-token=`, else the phone secret) also serves the MCP tools on 127.0.0.1.
    public static func phoneMain(_ args: [String]) -> Int32 {
        applyStateOptions(args)
        guard let portText = option(args, "--port="), let port = Int(portText),
              let token = option(args, "--token="), !JavaText.isBlank(token) else {
            FileHandle.standardError.write(Data("usage: microhm-host --phone-only --port=N --token=SECRET [--registry=FILE] [--mux-home=DIR]\n".utf8))
            return 2
        }
        let registry = SessionRegistry.load(RegistryPaths.resolve())
        let stack = McpStack.create(registry, SessionServerHost.forDefaultHome())
        do {
            try stack.phone.start(port, token)
        } catch {
            FileHandle.standardError.write(Data("phone page could not start: \(error)\n".utf8))
            return 1
        }
        if let mcpPort = option(args, "--mcp-port=").flatMap({ Int($0) }) {
            // the MCP tools too, on 127.0.0.1 with the same secret (for trying them by hand)
            do {
                try stack.service.start(mcpPort, option(args, "--mcp-token=") ?? token)
                print("MCP ready on port " + String(stack.service.port()))
            } catch {
                FileHandle.standardError.write(Data("MCP could not start: \(error)\n".utf8))
                return 1
            }
        }
        onTermination {
            stack.service.stop()
            stack.phone.stop()
        }
        print(READY + String(stack.phone.port()))
        fflush(stdout)
        while true {
            Thread.sleep(forTimeInterval: 3600)
        }
    }

    /// Applies `--registry=`, `--home=` and `--mux-home=` as the overrides every path
    /// resolution reads, for the app and the host alike.
    public static func applyStateOptions(_ args: [String]) {
        for arg in args {
            if arg.hasPrefix(REGISTRY_OPTION) {
                let file = URL(fileURLWithPath: String(arg.dropFirst(REGISTRY_OPTION.count)))
                MicrohmPaths.homeOverride = file.deletingLastPathComponent()
            } else if arg.hasPrefix(HOME_OPTION) {
                MicrohmPaths.homeOverride = URL(fileURLWithPath: String(arg.dropFirst(HOME_OPTION.count)), isDirectory: true)
            } else if arg.hasPrefix(MUX_HOME_OPTION) {
                setenv(ServerHome.HOME_ENV, String(arg.dropFirst(MUX_HOME_OPTION.count)), 1)
            }
        }
    }

    /// How many registered sessions the daemon still runs; 0 when it does not answer.
    static func liveRegistered(_ registry: SessionRegistry, _ host: SessionHost) -> Int {
        guard let live = try? Set(host.listSessions()) else { return 0 }
        return registry.sessions().filter { live.contains($0.sessionName) }.count
    }

    private static func option(_ args: [String], _ prefix: String) -> String? {
        args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Runs `cleanup` and exits on SIGTERM, SIGINT or SIGHUP.
    private static func onTermination(_ cleanup: @escaping () -> Void) {
        let queue = DispatchQueue(label: "mhm-host-signals")
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                cleanup()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// Starts the background host (`McpHost`) as the app quits: the `microhm-host` executable
/// beside the app's own. The child is detached in the way that matters here: its own
/// session, started from the user's home directory, output appended to `mcp-host.log`
/// beside the registry, holding none of this process's terminal.
public enum HostLauncher {

    /// Launches the host when a registered session is live and it has something to do: the
    /// MCP server, the phone page or the menu-bar icon is on. True when a host process was started.
    @discardableResult
    public static func launchIfNeeded(_ registry: SessionRegistry, _ host: SessionHost) -> Bool {
        if !AppSettings.mcpServerEnabled() && !AppSettings.trayIconEnabled() && !AppSettings.phoneServerEnabled() {
            return false
        }
        if McpHost.liveRegistered(registry, host) == 0 {
            return false
        }
        guard let executable = MicrohmPaths.siblingExecutable("microhm-host") else {
            Log.warn("could not start the background host: microhm-host is not beside this app", tag: "host")
            return false
        }
        return start(command([executable.path], RegistryPaths.resolve(), ServerHome.resolve(), McpHost.FLAG),
                     MicrohmPaths.mcpHostLog, "the background host")
    }

    /// The host command: `launcher` then `mode` (if any), then this process's registry and
    /// daemon home spelled out, so the child serves exactly the same state however this
    /// process was started (overrides, environment, home).
    static func command(_ launcher: [String], _ registry: URL, _ muxHome: URL, _ mode: String...) -> [String] {
        launcher + mode + [McpHost.REGISTRY_OPTION + registry.standardizedFileURL.path,
                           McpHost.MUX_HOME_OPTION + muxHome.standardizedFileURL.path]
    }

    static func start(_ command: [String], _ log: URL, _ what: String) -> Bool {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        posix_spawn_file_actions_addchdir_np(&actions, home)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, command[0], &actions, &attributes, argv, environ)
        if status != 0 {
            Log.warn("could not start \(what) (\(command.joined(separator: " "))): \(String(cString: strerror(status)))",
                     tag: "host")
            return false
        }
        Log.info("started \(what) (pid \(pid))", tag: "host")
        return true
    }
}


/// The background host's menu-bar icon, as `McpHost` drives it. Implementations hop to the
/// main thread themselves: these are called from the host's watch thread.
public protocol HostStatusIcon: AnyObject {
    func update(liveSessions: Int, mcpPort: Int?, phonePort: Int?)
    func remove()
}

extension HostLauncher {
    /// Opens the app (from the icon's menu); it stops this host as it starts. The app
    /// bundle is the one this executable sits in (`…/Microhm.app/Contents/MacOS/`), else the
    /// `Microhm` executable beside it (a SwiftPM build).
    public static func openApp() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        if bundle.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [bundle.path]
        } else if let app = MicrohmPaths.siblingExecutable("Microhm") {
            process.executableURL = app
        } else {
            Log.warn("could not open the app: no Microhm beside \(exe.path)", tag: "host")
            return
        }
        do { try process.run() } catch { Log.warn("could not open the app: \(error)", tag: "host") }
    }
}
