import AppKit
import MicrohmCore

/// Settings (Java's `SettingsDialog`): a window with toolbar tabs — Sessions, Look,
/// Input, Agents, Phone, Performance — seeded from the settings file on open. Save hands
/// the choices to `onSave`; Cancel (or closing the window) drops them. Tabs keep unsaved
/// edits while switching.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onSave: ((SettingsResult) -> Void)?
    /// The phone page link for the current port (the backend knows the address).
    var phoneLink: ((Int) -> String)?
    var shells: [(value: String, label: String)] = []
    var describeShell: ((String) -> String)?

    private let tabs = NSTabViewController()

    // Sessions
    private let pollingBox = NSButton(checkboxWithTitle: "Poll sessions for their status badge", target: nil, action: nil)
    private let pollInterval = NumberField(min: AppSettings.minStatusPollIntervalMs, max: AppSettings.maxStatusPollIntervalMs, step: 500)
    private let activeTabPopup = NSPopUpButton()
    private let shellPopup = NSPopUpButton()
    private let directLaunchBox = NSButton(checkboxWithTitle: "Start agents in one step (zsh, bash, sh, fish)", target: nil, action: nil)
    private let trayBox = NSButton(checkboxWithTitle: "Show a menu-bar icon with the running sessions", target: nil, action: nil)
    // Look
    private let sidebarBackgroundPopup = NSPopUpButton()
    private let matchRightPaneBox = NSButton(checkboxWithTitle: "Match the right pane to the sidebar", target: nil, action: nil)
    private let reticuleBox = NSButton(checkboxWithTitle: "Dither sessions that are not attached", target: nil, action: nil)
    private let folderGroupsBox = NSButton(checkboxWithTitle: "Group same-folder sessions under one heading", target: nil, action: nil)
    private let labelsBox = NSButton(checkboxWithTitle: "Show text labels under the icons", target: nil, action: nil)
    private let pageButtonsBox = NSButton(checkboxWithTitle: "Page Up / Page Down", target: nil, action: nil)
    private let stopLadderBox = NSButton(checkboxWithTitle: "Detach, Close, Kill, Close All", target: nil, action: nil)
    private let batchBox = NSButton(checkboxWithTitle: "Batch Close, Remove Dead", target: nil, action: nil)
    private let terminalBackgroundPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let fontSize = NumberField(min: AppSettings.minTerminalFontSize, max: AppSettings.maxTerminalFontSize, step: 1)
    private let palettePopup = NSPopUpButton()
    private let scrollbarBox = NSButton(checkboxWithTitle: "Hide the scrollbar", target: nil, action: nil)
    // Input
    private let optionMetaBox = NSButton(checkboxWithTitle: "Use Option as Meta", target: nil, action: nil)
    private let pageKeysBox = NSButton(checkboxWithTitle: "Page Up/Down and Home/End scroll the scrollback", target: nil, action: nil)
    private let codexWheelBox = NSButton(checkboxWithTitle: "Don't send mouse wheel events to Codex", target: nil, action: nil)
    // Agents
    private let mcpBox = NSButton(checkboxWithTitle: "Let agents in its sessions list, read and drive other sessions", target: nil, action: nil)
    private let mcpPort = NumberField(min: AppSettings.minMcpPort, max: AppSettings.maxMcpPort, step: 1, grouping: false)
    private let regenerateButton = NSButton(title: "Regenerate Token", target: nil, action: nil)
    private let sessionLogsBox = NSButton(checkboxWithTitle: "Keep a log of each session an agent reads, in its project", target: nil, action: nil)
    // Phone
    private let phoneBox = NSButton(checkboxWithTitle: "Serve a page phones on your network can use", target: nil, action: nil)
    private let phonePort = NumberField(min: AppSettings.minMcpPort, max: AppSettings.maxMcpPort, step: 1, grouping: false)
    private let qrView = NSImageView()
    private let linkField = NSTextField(labelWithString: "")
    private let copyLinkButton = NSButton(title: "Copy Link", target: nil, action: nil)
    // Performance
    private let perfGrid = NSGridView()

    private var mcpWasEnabled = false
    private var mcpWasPort = 0
    private var regenerateToken = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        buildTabs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Re-reads the settings file into every control, then shows the window.
    func present() {
        load()
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - building

    private func buildTabs() {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        addTab("Sessions", "rectangle.stack", sessionsPage())
        addTab("Look", "paintpalette", lookPage())
        addTab("Input", "keyboard", inputPage())
        addTab("Agents", "point.3.connected.trianglepath.dotted", agentsPage())
        addTab("Phone", "iphone", phonePage())
        addTab("Performance", "speedometer", performancePage())

        window?.contentViewController = tabs
    }

    /// Each tab is its page over the shared footer (Save applies every tab), at one fixed
    /// size so switching tabs never resizes the window.
    private func addTab(_ label: String, _ symbol: String, _ view: NSView) {
        let content = NSView()
        let footer = footerBar()
        for part in [view, footer] {
            part.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(part)
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            footer.topAnchor.constraint(equalTo: view.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 660),
            content.heightAnchor.constraint(equalToConstant: 520),
        ])
        let controller = NSViewController()
        controller.view = content
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = HarnessIcons.symbol(symbol, label)
        tabs.addTabViewItem(item)
    }

    private func footerBar() -> NSView {
        let hint = NSTextField(labelWithString: "Save applies changes from every tab.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.toolTip = AppSettings.settingsFile().path
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let stack = NSStackView(views: [hint, NSView(), cancel, save])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        let separator = NSBox()
        separator.boxType = .separator
        let wrapper = NSStackView(views: [separator, stack])
        wrapper.orientation = .vertical
        wrapper.spacing = 0
        separator.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        stack.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        return wrapper
    }

    /// One settings page: right-aligned labels, controls, small muted notes.
    private func page(_ rows: [(String, NSView, [String])]) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        for (label, control, notes) in rows {
            let title = NSTextField(labelWithString: label)
            title.alignment = .right
            let row = grid.addRow(with: [label.isEmpty ? NSGridCell.emptyContentView : title, control])
            if control is NSStackView && !(control is NumberField) {
                // a group has no baseline of its own: line the label up with its top
                row.rowAlignment = .none
                row.yPlacement = .top
                title.setContentHuggingPriority(.required, for: .vertical)
            }
            for note in notes {
                let field = NSTextField(wrappingLabelWithString: note)
                field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                field.textColor = .secondaryLabelColor
                field.preferredMaxLayoutWidth = 400
                let noteRow = grid.addRow(with: [NSGridCell.emptyContentView, field])
                noteRow.topPadding = -4
            }
            if let last = grid.row(at: grid.numberOfRows - 1) as NSGridRow? {
                last.bottomPadding = 6
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.column(at: 1).width = 410
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -10),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
        ])
        return view
    }

    private func sessionsPage() -> NSView {
        for (title, mode) in [("Off", AppSettings.ActiveTabPollMode.off), ("Once, on select", .once),
                              ("Scheduled while selected", .scheduled)] {
            activeTabPopup.addItem(withTitle: title)
            activeTabPopup.lastItem?.representedObject = mode.rawValue
        }
        pollingBox.target = self
        pollingBox.action = #selector(updateEnabled(_:))
        activeTabPopup.target = self
        activeTabPopup.action = #selector(updateEnabled(_:))
        shellPopup.target = self
        shellPopup.action = #selector(shellChosen(_:))
        let interval = NSStackView(views: [pollInterval, NSTextField(labelWithString: "ms")])
        return page([
            ("Status polling:", pollingBox, ["Off freezes status badges and pane titles."]),
            ("Poll interval:", interval, ["Milliseconds between status polls. Applies live."]),
            ("Selected session:", activeTabPopup, ["While polling is off, keeps the selected session's badge fresh."]),
            ("Shell:", shellPopup, ["For new sessions. Your default is your login shell."]),
            ("Agent start:", directLaunchBox, ["On: the shell starts the agent itself, so nothing is typed during startup. Other shells always type it."]),
            ("Menu bar:", trayBox, ["Shows how many sessions run and whether MCP is serving."]),
        ])
    }

    private func lookPage() -> NSView {
        for (title, value) in [("Translucent (system)", AppSettings.SidebarBackground.default),
                               ("Window gray", .uiGray), ("Black / white (follows appearance)", .terminal)] {
            sidebarBackgroundPopup.addItem(withTitle: title)
            sidebarBackgroundPopup.lastItem?.representedObject = value.rawValue
        }
        for (title, value) in [("Follow appearance", ""), ("Black", AppSettings.TerminalBackground.black.rawValue),
                               ("White", AppSettings.TerminalBackground.white.rawValue)] {
            terminalBackgroundPopup.addItem(withTitle: title)
            terminalBackgroundPopup.lastItem?.representedObject = value
        }
        for (title, value) in [("macOS Terminal", AppSettings.TerminalPalette.macosTerminal), ("iTerm2", .iterm2),
                               ("xterm", .xterm)] {
            palettePopup.addItem(withTitle: title)
            palettePopup.lastItem?.representedObject = value.rawValue
        }
        matchRightPaneBox.target = self
        matchRightPaneBox.action = #selector(updateEnabled(_:))
        let font = NSStackView(views: [fontPopup, fontSize, NSTextField(labelWithString: "pt")])
        font.spacing = 6
        let groups = NSStackView(views: [pageButtonsBox, stopLadderBox, batchBox])
        groups.orientation = .vertical
        groups.alignment = .leading
        groups.spacing = 4
        return page([
            ("Sidebar:", sidebarBackgroundPopup, []),
            ("", matchRightPaneBox, []),
            ("", reticuleBox, []),
            ("Folder groups:", folderGroupsBox, ["Applies while sorting by folder."]),
            ("Toolbar:", labelsBox, []),
            ("Toolbar groups:", groups, []),
            ("Terminal background:", terminalBackgroundPopup, []),
            ("Terminal font:", font, ["Applies live. ⌘+ and ⌘− resize it too."]),
            ("ANSI palette:", palettePopup, ["The 16 base colours. Applies live, to open terminals too."]),
            ("Scrollbar:", scrollbarBox, ["Applies to terminals attached from now on."]),
        ])
    }

    private func inputPage() -> NSView {
        page([
            ("Option key:", optionMetaBox, ["On: Option+letter is Meta (word motion, shortcuts).",
                                            "Off: Option types accents and symbols (Option+e, e = é). Applies live."]),
            ("Paging keys:", pageKeysBox, ["Off passes all four keys through to the program. Full-screen programs always get them."]),
            ("Codex mouse wheel:", codexWheelBox, ["On by default. Applies live to Codex sessions."]),
        ])
    }

    private func agentsPage() -> NSView {
        mcpBox.target = self
        mcpBox.action = #selector(updateEnabled(_:))
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerate(_:))
        let warning = NSTextField(wrappingLabelWithString:
            "Turning this on lets every agent you start read and type into your other sessions, and start new ones (a shell included) in any folder. Leave it off for agents you would not give that.")
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = 400
        return page([
            ("MCP server:", mcpBox, ["Off by default. Loopback only, token-protected; applies on Save.",
                                     "New Claude Code and Codex sessions connect automatically."]),
            ("", warning, []),
            ("Port:", mcpPort, []),
            ("Token:", regenerateButton, ["A new token restarts the server. Earlier sessions reconnect after Resume."]),
            ("Session logs:", sessionLogsBox, ["Copies the sessions an agent reads into .microhm-sessions/ in its project, as plain text: for agents that cannot read outside it."]),
        ])
    }

    private func phonePage() -> NSView {
        phoneBox.target = self
        phoneBox.action = #selector(updateEnabled(_:))
        phonePort.onChange = { [weak self] in self?.updatePhoneLink() }
        copyLinkButton.target = self
        copyLinkButton.action = #selector(copyLink(_:))
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.widthAnchor.constraint(equalToConstant: 148).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 148).isActive = true
        qrView.wantsLayer = true
        qrView.layer?.cornerRadius = 8
        qrView.layer?.masksToBounds = true
        linkField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        linkField.textColor = .secondaryLabelColor
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.isSelectable = true
        linkField.preferredMaxLayoutWidth = 240
        let hint = NSTextField(wrappingLabelWithString: "Point the phone's camera at the code, then tap the link it shows. Safari remembers it after that.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 240
        let side = NSStackView(views: [hint, linkField, copyLinkButton])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 8
        let link = NSStackView(views: [qrView, side])
        link.alignment = .top
        link.spacing = 14
        return page([
            ("Phone page:", phoneBox, ["Off by default. Applies on Save and keeps running after you quit."]),
            ("Port:", phonePort, []),
            ("Link:", link, ["Anyone with the link can type into your sessions, shells included. Plain HTTP, meant for a home network or a VPN such as Tailscale."]),
        ])
    }

    private func performancePage() -> NSView {
        perfGrid.rowSpacing = 6
        perfGrid.columnSpacing = 14
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshPerformance(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPerformance(_:)))
        copy.toolTip = "Copy these figures as text, for a bug report"
        let buttons = NSStackView(views: [refresh, copy])
        let note = NSTextField(labelWithString: "Figures for this run of the app. Nothing here is a setting.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [perfGrid, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
        ])
        refreshPerformance(nil)
        return view
    }

    // MARK: - load / save

    private func load() {
        pollingBox.state = AppSettings.statusPollingEnabled() ? .on : .off
        pollInterval.value = AppSettings.statusPollIntervalMs()
        select(activeTabPopup, AppSettings.activeTabPollMode().rawValue)
        loadShells()
        directLaunchBox.state = AppSettings.directLaunch() ? .on : .off
        trayBox.state = AppSettings.trayIconEnabled() ? .on : .off

        select(sidebarBackgroundPopup, MainWindowController.effectiveSidebarBackground().rawValue)
        matchRightPaneBox.state = AppSettings.rightPaneMatchesSidebar() ? .on : .off
        reticuleBox.state = AppSettings.sidebarReticule() ? .on : .off
        folderGroupsBox.state = AppSettings.sidebarFolderGroups() ? .on : .off
        labelsBox.state = AppSettings.toolbarLabels() ? .on : .off
        pageButtonsBox.state = AppSettings.toolbarPageButtons() ? .on : .off
        stopLadderBox.state = AppSettings.toolbarStopLadder() ? .on : .off
        batchBox.state = AppSettings.toolbarBatchActions() ? .on : .off
        select(terminalBackgroundPopup, AppSettings.terminalBackgroundOverride()?.rawValue ?? "")
        loadFonts(AppSettings.terminalFontFamily())
        fontSize.value = AppSettings.terminalFontSize()
        select(palettePopup, AppSettings.terminalPalette().rawValue)
        scrollbarBox.state = AppSettings.terminalScrollbarHidden() ? .on : .off

        optionMetaBox.state = AppSettings.optionAsMeta() ? .on : .off
        pageKeysBox.state = AppSettings.pageKeys() ? .on : .off
        codexWheelBox.state = AppSettings.codexMouseWheelDisabled() ? .on : .off

        mcpWasEnabled = AppSettings.mcpServerEnabled()
        mcpWasPort = AppSettings.mcpPort()
        mcpBox.state = mcpWasEnabled ? .on : .off
        mcpPort.value = mcpWasPort
        regenerateToken = false
        regenerateButton.title = "Regenerate Token"
        regenerateButton.isEnabled = true
        sessionLogsBox.state = AppSettings.mcpSessionLogs() ? .on : .off

        phoneBox.state = AppSettings.phoneServerEnabled() ? .on : .off
        phonePort.value = AppSettings.phonePort()
        updatePhoneLink()
        updateEnabled(nil)
        refreshPerformance(nil)
    }

    private func select(_ popup: NSPopUpButton, _ raw: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == raw }) {
            popup.select(item)
        }
    }

    private func loadShells() {
        shellPopup.removeAllItems()
        let current = AppSettings.sessionShell()
        shellPopup.addItem(withTitle: describeShell?("") ?? "Your default")
        shellPopup.lastItem?.representedObject = ""
        for shell in shells {
            shellPopup.addItem(withTitle: shell.label)
            shellPopup.lastItem?.representedObject = shell.value
        }
        if !current.isEmpty, !shellPopup.itemArray.contains(where: { ($0.representedObject as? String) == current }) {
            shellPopup.addItem(withTitle: describeShell?(current) ?? current)
            shellPopup.lastItem?.representedObject = current
        }
        shellPopup.menu?.addItem(.separator())
        shellPopup.addItem(withTitle: "Other…")
        shellPopup.lastItem?.representedObject = nil
        select(shellPopup, current)
    }

    private var lastShellIndex = 0

    @objc private func shellChosen(_ sender: NSPopUpButton) {
        guard sender.selectedItem?.representedObject == nil, let window else {
            lastShellIndex = sender.indexOfSelectedItem
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/bin")
        panel.message = "Choose a shell"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let path = panel.url?.path {
                let index = max(0, self.shellPopup.numberOfItems - 2)
                self.shellPopup.insertItem(withTitle: self.describeShell?(path) ?? path, at: index)
                self.shellPopup.item(at: index)?.representedObject = path
                self.shellPopup.selectItem(at: index)
                self.lastShellIndex = index
            } else {
                self.shellPopup.selectItem(at: self.lastShellIndex)
            }
        }
    }

    private func loadFonts(_ current: String) {
        fontPopup.removeAllItems()
        let manager = NSFontManager.shared
        let fixed = Set(manager.availableFontNames(with: .fixedPitchFontMask) ?? [])
        var families = manager.availableFontFamilies.filter { family in
            (manager.availableMembers(ofFontFamily: family) ?? []).contains { member in
                (member.first as? String).map(fixed.contains) ?? false
            }
        }
        // a family from a hand-edited file is kept even when not installed
        if !families.contains(current) {
            families.insert(current, at: 0)
        }
        for family in families.sorted() {
            fontPopup.addItem(withTitle: family)
            if let font = NSFont(name: family, size: 13) {
                fontPopup.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        fontPopup.selectItem(withTitle: current)
    }

    @objc private func updateEnabled(_ sender: Any?) {
        let polling = pollingBox.state == .on
        let scheduled = (activeTabPopup.selectedItem?.representedObject as? String) == AppSettings.ActiveTabPollMode.scheduled.rawValue
        pollInterval.isEnabled = polling || scheduled
        activeTabPopup.isEnabled = !polling
        terminalBackgroundPopup.isEnabled = matchRightPaneBox.state == .off
            || (sidebarBackgroundPopup.selectedItem?.representedObject as? String) == AppSettings.SidebarBackground.default.rawValue
        let mcp = mcpBox.state == .on
        mcpPort.isEnabled = mcp
        sessionLogsBox.isEnabled = mcp
        let phone = phoneBox.state == .on
        phonePort.isEnabled = true
        qrView.alphaValue = phone ? 1 : 0.35
    }

    @objc private func regenerate(_ sender: Any?) {
        // regenerated on Save, not on click, so Cancel really cancels
        regenerateToken = true
        regenerateButton.title = "Token Regenerates on Save"
        regenerateButton.isEnabled = false
    }

    private func updatePhoneLink() {
        let link = phoneLink?(phonePort.value) ?? ""
        linkField.stringValue = link
        linkField.toolTip = link
        qrView.image = QRCode.image(link, scale: 6)
        copyLinkButton.title = "Copy Link"
    }

    @objc private func copyLink(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(linkField.stringValue, forType: .string)
        copyLinkButton.title = "Copied"
    }

    @objc private func refreshPerformance(_ sender: Any?) {
        while perfGrid.numberOfRows > 0 {
            perfGrid.removeRow(at: 0)
        }
        for row in PerfStats.snapshot() {
            let (label, value) = (row.label, row.value)
            let title = NSTextField(labelWithString: label + ":")
            title.textColor = .secondaryLabelColor
            title.alignment = .right
            let field = NSTextField(labelWithString: value)
            field.isSelectable = true
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            perfGrid.addRow(with: [title, field])
        }
        if perfGrid.numberOfColumns > 0 {
            perfGrid.column(at: 0).xPlacement = .trailing
        }
    }

    @objc private func copyPerformance(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PerfStats.asText(PerfStats.snapshot()), forType: .string)
    }

    /// ⌘W closes this window (in the main window it closes the selected session).
    @objc func closeSession(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc private func cancel(_ sender: Any?) {
        window?.close()
    }

    @objc private func save(_ sender: Any?) {
        window?.makeFirstResponder(nil) // commit a field still being edited
        let mcpEnabled = mcpBox.state == .on
        let port = AppSettings.clampMcpPort(mcpPort.value)
        let result = SettingsResult(
            backgroundOverride: (terminalBackgroundPopup.selectedItem?.representedObject as? String)
                .flatMap { AppSettings.TerminalBackground(rawValue: $0) },
            palette: (palettePopup.selectedItem?.representedObject as? String)
                .flatMap { AppSettings.TerminalPalette(rawValue: $0) } ?? .macosTerminal,
            scrollbarHidden: scrollbarBox.state == .on,
            codexMouseWheelDisabled: codexWheelBox.state == .on,
            optionAsMeta: optionMetaBox.state == .on,
            pageKeys: pageKeysBox.state == .on,
            toolbarLabels: labelsBox.state == .on,
            toolbarPageButtons: pageButtonsBox.state == .on,
            toolbarStopLadder: stopLadderBox.state == .on,
            toolbarBatchActions: batchBox.state == .on,
            sidebarBackground: (sidebarBackgroundPopup.selectedItem?.representedObject as? String)
                .flatMap { AppSettings.SidebarBackground(rawValue: $0) } ?? .default,
            rightPaneMatchesSidebar: matchRightPaneBox.state == .on,
            sidebarReticule: reticuleBox.state == .on,
            sidebarFolderGroups: folderGroupsBox.state == .on,
            fontFamily: fontPopup.titleOfSelectedItem ?? AppSettings.terminalFontFamily(),
            fontSize: AppSettings.clampTerminalFontSize(fontSize.value),
            statusPollingEnabled: pollingBox.state == .on,
            statusPollIntervalMs: AppSettings.clampStatusPollIntervalMs(pollInterval.value),
            activeTabPollMode: (activeTabPopup.selectedItem?.representedObject as? String)
                .flatMap { AppSettings.ActiveTabPollMode(rawValue: $0) } ?? .once,
            mcpServerEnabled: mcpEnabled,
            mcpPort: port,
            mcpTokenRegenerated: regenerateToken,
            mcpChanged: SettingsResult.mcpChanged(wasEnabled: mcpWasEnabled, wasPort: mcpWasPort, enabled: mcpEnabled,
                                                  port: port, tokenRegenerated: regenerateToken),
            trayIcon: trayBox.state == .on,
            sessionShell: shellPopup.selectedItem?.representedObject as? String ?? "",
            directLaunch: directLaunchBox.state == .on,
            mcpSessionLogs: sessionLogsBox.state == .on,
            phoneServerEnabled: phoneBox.state == .on,
            phonePort: AppSettings.clampMcpPort(phonePort.value))
        onSave?(result)
        window?.close()
    }
}

/// An integer field with a stepper, clamped to its range.
final class NumberField: NSStackView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let min: Int
    private let max: Int
    var onChange: (() -> Void)?

    init(min: Int, max: Int, step: Int, grouping: Bool = true) {
        self.min = min
        self.max = max
        super.init(frame: .zero)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        formatter.allowsFloats = false
        field.formatter = formatter
        field.alignment = .right
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        stepper.minValue = Double(min)
        stepper.maxValue = Double(max)
        stepper.increment = Double(step)
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped(_:))
        addArrangedSubview(field)
        addArrangedSubview(stepper)
        spacing = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    var value: Int {
        get { Swift.max(min, Swift.min(max, field.integerValue)) }
        set {
            let clamped = Swift.max(min, Swift.min(max, newValue))
            field.integerValue = clamped
            stepper.integerValue = clamped
        }
    }

    var isEnabled: Bool {
        get { field.isEnabled }
        set {
            field.isEnabled = newValue
            stepper.isEnabled = newValue
        }
    }

    @objc private func stepped(_ sender: NSStepper) {
        field.integerValue = sender.integerValue
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        stepper.integerValue = field.integerValue
        onChange?()
    }
}
