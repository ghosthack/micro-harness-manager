import AppKit
import MicrohmCore
import MicrohmShared

/// The application: builds the model, the main window, the menu bar and the status item;
/// starts the MCP server and phone page when Settings say so; persists and applies
/// Settings; and tidies up on quit (Java's `MicroHarnessManagerApp` + `MainWindow`'s
/// shutdown).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private let statusItem = StatusItemController()
    private let settingsQueue = DispatchQueue(label: "microhm-app-settings")
    private let serviceQueue = DispatchQueue(label: "microhm-services")
    private var statusTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        if let icon = AppResources.appIcon, Bundle.main.bundleIdentifier == nil {
            // a plain SwiftPM executable has no bundle icon; the .app has its .icns
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.makeDefault()
        self.model = model
        Log.info("started; backend: \(model.backend.name); home: \(MicrohmPaths.home.path)", tag: "app")

        let window = MainWindowController(model: model)
        window.onOpenSettings = { [weak self] in self?.showSettings(nil) }
        window.onLiveSessionsChanged = { [weak self] in self?.updateStatusItem() }
        mainWindow = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        StartupTimes.markWindowShown()
        NSApp.activate(ignoringOtherApps: true)

        startServices(model.backend)

        statusItem.onOpen = { [weak self] in self?.showMainWindow(nil) }
        statusItem.onHide = { [weak self] in
            self?.statusItem.remove()
            self?.settingsQueue.async { AppSettings.saveTrayIconEnabled(false) }
        }
        if AppSettings.trayIconEnabled() {
            statusItem.show()
        }
        // the MCP and phone servers change state off the main thread: keep the menu honest
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.updateStatusItem() }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        updateStatusItem()
        DebugHooks.install { [weak self] verb, args in self?.debugCommand(verb, args) }
    }

    private func debugCommand(_ verb: String, _ args: [String]) {
        switch verb {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "system": NSApp.appearance = nil
        case "select": args.first.map { mainWindow?.debugSelect($0) }
        case "settings":
            showSettings(nil)
            if let tab = args.first.flatMap(Int.init),
               let tabs = settingsWindow?.window?.contentViewController as? NSTabViewController,
               tab < tabs.tabViewItems.count {
                tabs.selectedTabViewItemIndex = tab
            }
        case "new": mainWindow?.newSession(nil)
        case "create":
            if args.count >= 2, let harness = HarnessType(rawValue: args[1]) {
                mainWindow?.debugCreate(args[0], harness, message: args.count > 2 ? args.dropFirst(2).joined(separator: " ") : nil)
            }
        case "type":
            if let responder = mainWindow?.window?.firstResponder as? NSResponder {
                responder.insertText(args.joined(separator: " ") + "\r")
            }
        case "refresh": mainWindow?.refreshSessions(nil)
        case "usage": mainWindow?.showUsage(nil)
        case "about": showAbout(nil)
        case "batch": mainWindow?.batchCloseSessions(nil)
        case "kill": mainWindow?.killSession(nil)
        case "endsheet":
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        case "closeaux":
            for window in NSApp.windows where window !== mainWindow?.window && window.isVisible {
                window.close()
            }
        case "size":
            if args.count == 2, let w = Double(args[0]), let h = Double(args[1]) {
                mainWindow?.window?.setContentSize(NSSize(width: w, height: h))
            }
        case "sort": mainWindow?.debugSort(args.first ?? "session")
        case "dump":
            func walk(_ view: NSView, _ depth: Int) {
                if let field = view as? NSTextField, !field.stringValue.isEmpty {
                    Log.info("dump: \(field.stringValue) hidden=\(field.isHiddenOrHasHiddenAncestor) frame=\(field.frame)", tag: "debug")
                }
                view.subviews.forEach { walk($0, depth + 1) }
            }
            for window in NSApp.windows where window.isVisible {
                Log.info("dump window \(window.title) \(type(of: window)) sheet=\(window.isSheet) appearance=\(window.effectiveAppearance.name.rawValue)", tag: "debug")
                window.contentView.map { walk($0, 0) }
            }
        default: Log.warn("unknown debug command \(verb)", tag: "debug")
        }
    }

    /// Starts the MCP server and phone page when their settings are on. A taken port
    /// leaves the app running without it — Settings can pick another.
    private func startServices(_ backend: SessionBackend) {
        serviceQueue.async { [weak self] in
            if AppSettings.mcpServerEnabled() {
                let port = AppSettings.mcpPort()
                do {
                    try backend.startMcp(port: port, token: AppSettings.mcpToken())
                } catch {
                    Log.warn("MCP server could not start on \(port): \(error)", tag: "app")
                    self?.warn("MCP server", "The MCP server could not start on port \(port): \(error.localizedDescription)\n"
                               + "\(AppModel.appName) runs without it; pick another port in Settings.")
                }
            }
            if AppSettings.phoneServerEnabled() {
                let port = AppSettings.phonePort()
                do {
                    try backend.startPhone(port: port, token: AppSettings.phoneToken())
                } catch {
                    Log.warn("phone page could not start on \(port): \(error)", tag: "app")
                    self?.warn("Phone page", "The phone page could not start on port \(port): \(error.localizedDescription)\n"
                               + "\(AppModel.appName) runs without it; pick another port in Settings.")
                }
            }
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    private func warn(_ title: String, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow?.showAlert(title, message, style: .warning)
        }
    }

    private func updateStatusItem() {
        guard let model, statusItem.isShown else { return }
        let live = mainWindow?.liveManagedEntries.count ?? 0
        let backend = model.backend
        serviceQueue.async { [weak self] in
            let mcp = backend.mcpRunning ? AppSettings.mcpPort() : nil
            let phone = backend.phoneRunning ? AppSettings.phonePort() : nil
            DispatchQueue.main.async {
                self?.statusItem.update(liveSessions: live, mcpPort: mcp, phonePort: phone)
            }
        }
    }

    // MARK: - menu actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Runs coding agents — Claude Code, Codex, Cursor Agent, Grok, OpenCode, Pi, Muse — and shells side by side, in sessions that outlive the window.\n\nState: \(SidebarEntry.abbreviate(MicrohmPaths.home.path))",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppModel.appName,
            .credits: credits,
        ]
        if Bundle.main.infoDictionary?["CFBundleShortVersionString"] == nil {
            options[.applicationVersion] = "1.0.0"
            options[.version] = "SwiftPM build"
        }
        if let icon = AppResources.appIcon {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        guard let model else { return }
        let controller = settingsWindow ?? SettingsWindowController()
        settingsWindow = controller
        let backend = model.backend
        controller.phoneLink = { port in backend.phoneLink(port: port, token: AppSettings.phoneToken()) }
        controller.shells = backend.installedShells()
        controller.describeShell = { backend.describeShell($0) }
        controller.onSave = { [weak self] result in self?.applySettings(result) }
        controller.present()
    }

    @objc func showMainWindow(_ sender: Any?) {
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openProjectPage(_ sender: Any?) {
        if let url = URL(string: "https://github.com/ghosthack/micro-harness-manager") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func revealLog(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([MicrohmPaths.appLog])
    }

    // MARK: - settings

    /// Persists Settings off the main thread, applies them to the window at once, and
    /// starts, restarts or stops the MCP server and phone page to match.
    private func applySettings(_ result: SettingsResult) {
        guard let model else { return }
        let backend = model.backend
        let mcpWasRunning = backend.mcpRunning
        settingsQueue.async { [weak self] in
            result.persist()
            self?.serviceQueue.async {
                if SettingsResult.mcpNeedsApply(result.mcpChanged, enabled: result.mcpServerEnabled, running: mcpWasRunning) {
                    self?.applyMcp(backend, result)
                }
                self?.applyPhone(backend, result)
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
        }
        // the window's own copy of the settings, applied now so the change shows at once
        mainWindow?.applySettings(result)
        if result.trayIcon { statusItem.show() } else { statusItem.remove() }
        updateStatusItem()
    }

    /// A regenerated token is saved first; a running server then restarts with it.
    private func applyMcp(_ backend: SessionBackend, _ result: SettingsResult) {
        let token = result.mcpTokenRegenerated ? AppSettings.regenerateMcpToken() : AppSettings.mcpToken()
        backend.stopMcp()
        guard result.mcpServerEnabled else { return }
        do {
            try backend.startMcp(port: result.mcpPort, token: token)
        } catch {
            warn("MCP server", "The MCP server could not start on port \(result.mcpPort): \(error.localizedDescription)\n"
                 + "Pick another port in Settings.")
        }
    }

    private func applyPhone(_ backend: SessionBackend, _ result: SettingsResult) {
        if !result.phoneServerEnabled {
            backend.stopPhone()
            return
        }
        do {
            try backend.startPhone(port: result.phonePort, token: AppSettings.phoneToken())
        } catch {
            warn("Phone page", "The phone page could not start on port \(result.phonePort): \(error.localizedDescription)\n"
                 + "Pick another port in Settings.")
        }
    }

    // MARK: - lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        mainWindow?.shutdown()
        statusItem.remove()
        // stops serving and hands MCP to the background host while sessions live
        model?.backend.shutdown()
        settingsQueue.sync {}
        Log.info("quit", tag: "app")
        InstanceLock.release(RegistryPaths.resolve())
    }
}
