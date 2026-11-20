import AppKit
import MicrohmCore
import MicrohmShared
import MicrohmTerminal

/// The main window: the sessions sidebar on the left, the selected session's terminal on
/// the right, a unified toolbar on top (Java's `MainWindow`). Owns the window's session
/// state — the reconciled rows, the attached terminals, the status polling — and every
/// session action the toolbar, the menus and the keyboard reach.
///
/// Threading: everything here runs on the main thread except the closures handed to
/// `background`, which make the blocking daemon round trips (listing, attaching,
/// capturing, creating, killing) and hop back with `DispatchQueue.main.async`.
final class MainWindowController: NSWindowController, NSWindowDelegate, SidebarViewControllerDelegate,
    NSMenuItemValidation, NSToolbarItemValidation {

    static let sidebarWidth: CGFloat = 280
    /// Keep the session part of the window title useful without a prompt-derived Codex
    /// preview crowding out everything else.
    static let windowTitleSessionMaxChars = 64

    let model: AppModel
    private var backend: SessionBackend { model.backend }
    private var registry: SessionRegistry { model.registry }

    private let splitController = NSSplitViewController()
    let sidebar = SidebarViewController()
    private let terminalArea = TerminalAreaViewController()
    private var sidebarItem: NSSplitViewItem?
    private var toolbarController: MainToolbar?

    /// Runs every blocking daemon round trip, so the main thread only paints and reacts.
    private let background = DispatchQueue(label: "microhm-background", qos: .userInitiated, attributes: .concurrent)
    /// Serializes settings rewrites so rapid UI changes cannot land out of order.
    private let settingsQueue = DispatchQueue(label: "microhm-settings")

    private var statusPoller: SessionStatusPoller!
    private var gracefulCloser: GracefulCloser!
    private var statusPollTimer: Timer?
    private var activeTabPollTimer: Timer?
    private var keyMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    /// Complete reconciled set; the sidebar shows its sorted/filtered projection.
    private var allEntries: [SidebarEntry] = []
    /// Live terminal attachments, keyed by session name. Survive sidebar rebuilds.
    private var attached: [String: SessionTerminal] = [:]
    /// Attaches in flight, each mapped to its generation ticket: a later
    /// `removeAttachment` invalidates a result that has not landed yet.
    private var attaching: [String: Int] = [:]
    private var attachGeneration: [String: Int] = [:]
    /// Sessions in the order they were first attached this run — the Ctrl+Tab order.
    private var attachOrder: [String] = []
    /// Live rows a poll found gone, already being refreshed away.
    private var goneSessions: Set<String> = []
    private var refreshFailureShowing = false
    private let refreshTickets = SidebarRefreshTickets()
    private var budgetsLoaded = false
    private var budgetRefreshSeq = 0
    private var createInFlight = false
    private var disposed = false
    private var lastSelectedSessionName: String?
    private var activeTabCatchUpAt: [String: Date] = [:]

    // view settings, seeded from AppSettings
    private(set) var sidebarSort = SidebarView.SortMode.sessionName
    private(set) var sidebarSortDescending = false
    private(set) var visibleStatuses = Set(SidebarView.FilterStatus.allCases)
    private(set) var visibleHarnesses = Set(SidebarView.HarnessFamily.allCases)
    private(set) var toolbarLabels = AppSettings.toolbarLabels()
    private(set) var toolbarPageButtons = AppSettings.toolbarPageButtons()
    private(set) var toolbarStopLadder = AppSettings.toolbarStopLadder()
    private(set) var toolbarBatchActions = AppSettings.toolbarBatchActions()
    private var pageKeys = AppSettings.pageKeys()
    private var sidebarBackground = MainWindowController.effectiveSidebarBackground()
    private var rightPaneMatchesSidebar = AppSettings.rightPaneMatchesSidebar()
    private var terminalBackgroundOverride = AppSettings.terminalBackgroundOverride()
    private var sidebarReticule = AppSettings.sidebarReticule()
    private(set) var sidebarFolderGroups = AppSettings.sidebarFolderGroups()
    private var terminalFontFamily = AppSettings.terminalFontFamily()
    private var terminalFontSize = AppSettings.terminalFontSize()
    private var statusPollInterval = Double(AppSettings.statusPollIntervalMs()) / 1000
    private var statusPollingEnabled = AppSettings.statusPollingEnabled()
    private var activeTabPollMode = AppSettings.activeTabPollMode()

    /// Called whenever the number of live sessions may have changed (the status item).
    var onLiveSessionsChanged: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = AppModel.appName
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("MicrohmMainWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        statusPoller = SessionStatusPoller(backend, { [background] task in background.async(execute: task) },
                                           { task in DispatchQueue.main.async(execute: task) }, SystemClock.shared)
        gracefulCloser = GracefulCloser(backend, 0.25, 10, 5)

        restoreSidebarViewSettings()
        buildContent()
        installToolbar()
        applyAppearance()
        applySurfaces()
        updateSidebarControls()
        // the split view controller sizes the window to its views' fitting size
        window.setContentSize(NSSize(width: 1180, height: 760))
        if !window.setFrameUsingName("MicrohmMainWindow") {
            window.center()
        }

        backend.setEventHandlers(changed: { [weak self] _ in
            // never reselect: an agent's spawn must not steal focus
            DispatchQueue.main.async { self?.refreshSidebar(nil) }
        }, killed: { [weak self] session in
            DispatchQueue.main.async { self?.sessionKilledExternally(session) }
        }, runEnded: { [weak self] session in
            DispatchQueue.main.async { self?.dropRuntimeArtifacts(session) }
        })

        startPollTimers()
        installKeyMonitor()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.effectiveAppearanceChanged() }
        }
        refreshSidebar(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: - layout

    private func buildContent() {
        sidebar.delegate = self
        sidebar.reticuleEnabled = sidebarReticule
        sidebar.loadViewIfNeeded()
        sidebar.budgetPanel.onRefresh = { [weak self] in self?.refreshHarnessBudgets() }
        terminalArea.onNewSession = { [weak self] in self?.newSession(nil) }
        terminalArea.onResume = { [weak self] in self?.resumeSession(nil) }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        self.sidebarItem = sidebarItem
        let contentItem = NSSplitViewItem(viewController: terminalArea)
        contentItem.titlebarSeparatorStyle = .line
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "MicrohmSplit"
        window?.contentViewController = splitController
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MicrohmSplit") == nil {
            splitController.splitView.setPosition(MainWindowController.sidebarWidth, ofDividerAt: 0)
        }
    }

    private func installToolbar() {
        let toolbar = MainToolbar(owner: self)
        toolbarController = toolbar
        window?.toolbar = toolbar.toolbar
    }

    /// Rebuilds the toolbar after a Settings change to labels or the optional groups.
    private func rebuildToolbar() {
        installToolbar()
    }

    // MARK: - appearance

    /// Applies `ui.theme`: explicit light or dark, or (unset) the system's, live.
    private func applyAppearance() {
        if AppModel.hasExplicitSetting("ui.theme") {
            NSApp.appearance = NSAppearance(named: AppSettings.uiTheme() == .light ? .aqua : .darkAqua)
        } else {
            NSApp.appearance = nil
        }
    }

    var isDark: Bool {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func effectiveAppearanceChanged() {
        guard !disposed else { return }
        applySurfaces()
        toolbarController?.updateThemeItem()
    }

    /// The toolbar's sun/moon: switches between light and dark, live, and saves it.
    @objc func toggleAppearance(_ sender: Any?) {
        let theme: AppSettings.UiTheme = isDark ? .light : .dark
        NSApp.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        settingsQueue.async { AppSettings.saveUiTheme(theme) }
        // the explicit-setting check reads the file: apply now, not after the save lands
        applySurfaces()
        toolbarController?.updateThemeItem()
    }

    /// `sidebar.background` as this port reads it: unset means the native translucent
    /// sidebar (the setting's "default").
    static func effectiveSidebarBackground() -> AppSettings.SidebarBackground {
        AppModel.hasExplicitSetting("sidebar.background") ? AppSettings.sidebarBackground() : .default
    }

    /// The sidebar's solid fill, or nil for the system's translucent source list.
    private func sidebarFill() -> NSColor? {
        switch sidebarBackground {
        case .default: return nil
        case .uiGray: return .windowBackgroundColor
        case .terminal: return isDark ? .black : .white
        }
    }

    /// Re-resolves every surface: on startup, Settings Save and every theme switch.
    private func applySurfaces() {
        let fill = sidebarFill()
        sidebar.applyBackground(fill)
        terminalArea.applyBackground(rightPaneMatchesSidebar ? fill : nil)
        for terminal in attached.values {
            applyTerminalBackground(terminal)
        }
    }

    private func applyTerminalBackground(_ terminal: SessionTerminal) {
        let light = !isDark
        if rightPaneMatchesSidebar, let fill = sidebarFill(), let rgb = MainWindowController.rgb(fill, in: window) {
            terminal.applyBackground(rgb, light: light)
        } else if let pin = terminalBackgroundOverride {
            terminal.applyBackground(light: pin == .white)
        } else {
            terminal.applyBackground(light: light)
        }
    }

    /// `0xRRGGBB` of a (possibly dynamic) colour as the window draws it.
    static func rgb(_ color: NSColor, in window: NSWindow?) -> Int? {
        var result: Int?
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
            let b = Int((c.blueComponent * 255).rounded())
            result = (r << 16) | (g << 8) | b
        }
        return result
    }

    // MARK: - sidebar view settings

    private func restoreSidebarViewSettings() {
        let saved = AppSettings.sidebarViewSettings()
        sidebarSort = SidebarView.SortMode.fromKey(saved.sort)
        sidebarSortDescending = saved.descending
        visibleStatuses = Set(SidebarView.FilterStatus.allCases.filter { !saved.hiddenStatuses.contains($0.key) })
        visibleHarnesses = Set(SidebarView.HarnessFamily.allCases.filter { !saved.hiddenHarnessFamilies.contains($0.key) })
    }

    /// Only the folder sort keeps a folder's sessions adjacent, so grouping follows the
    /// setting and the current sort together.
    private var folderGrouping: Bool {
        sidebarFolderGroups && sidebarSort == .directoryName
    }

    /// Applies one view change immediately, then saves its snapshot in the background.
    private func applySidebarViewChange() {
        updateSidebarControls()
        rebuildVisibleSidebar(lastSelectedSessionName, activate: false)
        let hiddenStatuses = Set(SidebarView.FilterStatus.allCases.filter { !visibleStatuses.contains($0) }.map(\.key))
        let hiddenHarnesses = Set(SidebarView.HarnessFamily.allCases.filter { !visibleHarnesses.contains($0) }.map(\.key))
        let sort = sidebarSort.key
        let descending = sidebarSortDescending
        settingsQueue.async {
            AppSettings.saveSidebarViewSettings(sort, descending, hiddenStatuses, hiddenHarnesses)
        }
    }

    private func updateSidebarControls() {
        let total = SidebarView.FilterStatus.allCases.count
        let totalHarnesses = SidebarView.HarnessFamily.allCases.count
        let filter = visibleStatuses.count == total ? "Filter: All" : "Filter: \(visibleStatuses.count)/\(total)"
        let harness = visibleHarnesses.count == totalHarnesses
            ? "Harness: All" : "Harness: \(visibleHarnesses.count)/\(totalHarnesses)"
        sidebar.updateControls(sortLabel: sidebarSort.label, sortDescending: sidebarSortDescending,
                               filterSummary: filter, filtering: visibleStatuses.count != total,
                               harnessSummary: harness, harnessFiltering: visibleHarnesses.count != totalHarnesses)
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        sidebarSort = SidebarView.SortMode.fromKey(mode)
        applySidebarViewChange()
    }

    @objc func toggleSortDescending(_ sender: Any?) {
        sidebarSortDescending.toggle()
        applySidebarViewChange()
    }

    @objc func toggleStatusFilter(_ sender: NSMenuItem) {
        guard let status = SidebarView.FilterStatus(rawValue: sender.tag) else { return }
        if visibleStatuses.contains(status) { visibleStatuses.remove(status) } else { visibleStatuses.insert(status) }
        applySidebarViewChange()
    }

    @objc func showAllStatuses(_ sender: Any?) {
        visibleStatuses = Set(SidebarView.FilterStatus.allCases)
        applySidebarViewChange()
    }

    @objc func hideAllStatuses(_ sender: Any?) {
        visibleStatuses = []
        applySidebarViewChange()
    }

    @objc func toggleHarnessFilter(_ sender: NSMenuItem) {
        let families = SidebarView.HarnessFamily.allCases
        guard sender.tag >= 0, sender.tag < families.count else { return }
        let family = families[sender.tag]
        if visibleHarnesses.contains(family) { visibleHarnesses.remove(family) } else { visibleHarnesses.insert(family) }
        applySidebarViewChange()
    }

    @objc func showAllHarnesses(_ sender: Any?) {
        visibleHarnesses = Set(SidebarView.HarnessFamily.allCases)
        applySidebarViewChange()
    }

    @objc func hideAllHarnesses(_ sender: Any?) {
        visibleHarnesses = []
        applySidebarViewChange()
    }

    @objc func toggleFolderGroups(_ sender: Any?) {
        sidebarFolderGroups.toggle()
        let on = sidebarFolderGroups
        settingsQueue.async { AppSettings.saveSidebarFolderGroups(on) }
        rebuildVisibleSidebar(lastSelectedSessionName, activate: false)
    }

    func sidebarSortMenu(_ sidebar: SidebarViewController) -> NSMenu { MainMenu.sortMenu(self) }
    func sidebarStatusFilterMenu(_ sidebar: SidebarViewController) -> NSMenu { MainMenu.statusFilterMenu(self) }
    func sidebarHarnessFilterMenu(_ sidebar: SidebarViewController) -> NSMenu { MainMenu.harnessFilterMenu(self) }

    // MARK: - refresh / reconciliation

    /// Reconciles the registry against the daemon off the main thread — listing is a
    /// socket round trip, and a wedged daemon must never freeze painting — then applies
    /// the result. Only the newest of overlapping refreshes applies (`refreshTickets`).
    /// `quiet`: a refresh nobody asked for (a session ended by itself) fails silently.
    func refreshSidebar(_ reselect: String?, quiet: Bool = false) {
        guard !disposed else { return }
        let seq = refreshTickets.issue(reselect)
        let registry = self.registry
        let backend = self.backend
        background.async { [weak self] in
            let result: ReconciliationResult
            do {
                result = Reconciler.reconcile(registry.sessions(), try backend.listSessions())
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshTickets.failed(seq)
                    if quiet || self.refreshFailureShowing || self.disposed { return }
                    self.refreshFailureShowing = true
                    self.showAlert("Refresh failed", "The session daemon is unreachable: \(error.localizedDescription)",
                                   style: .critical) { self.refreshFailureShowing = false }
                }
                return
            }
            DispatchQueue.main.async {
                guard let self, !self.disposed, self.refreshTickets.isCurrent(seq) else { return }
                self.applySidebar(result, reselect: self.refreshTickets.takeReselect())
            }
        }
    }

    private func applySidebar(_ result: ReconciliationResult, reselect: String?) {
        goneSessions.removeAll()
        let toReselect = reselect ?? sidebar.selectedEntry?.sessionName
        // Carry each live row's last poll result across the rebuild: acting on one
        // session must not blank every other session's badge until the next tick.
        var previousLive: [String: SidebarEntry] = [:]
        for entry in allEntries where entry.status == .live {
            previousLive[entry.sessionName] = entry
        }
        // Sessions that left the daemon leave a dead connection behind; evict it so
        // reattach and Resume start clean, and so Ctrl+Tab stops cycling onto ghosts.
        let live = Set(result.liveManaged.map(\.sessionName))
        let toEvict = Set(attached.keys).union(attaching.keys).subtracting(live)
        for name in toEvict {
            removeAttachment(name)
            statusPoller.forget(name)
        }
        allEntries = []
        for entry in result.liveManaged {
            let row = SidebarEntry.live(entry)
            row.isAttached = attached[entry.sessionName] != nil
            if let previous = previousLive[entry.sessionName] {
                if previous.state != nil {
                    row.setState(previous.state, previous.stateReason)
                }
                row.setPaneTitle(previous.paneTitle)
            }
            allEntries.append(row)
        }
        for entry in result.deadRegistered {
            allEntries.append(SidebarEntry.dead(entry))
        }
        if reselect != nil {
            lastSelectedSessionName = reselect
        }
        rebuildVisibleSidebar(toReselect, activate: toReselect != nil)
        if !budgetsLoaded {
            budgetsLoaded = true
            refreshHarnessBudgets()
        }
        onLiveSessionsChanged?()
    }

    /// Rebuilds the visible projection without disturbing cached terminal attachments.
    private func rebuildVisibleSidebar(_ reselect: String?, activate: Bool) {
        let visible = SidebarView.sorted(allEntries.filter { SidebarView.isVisible($0, visibleStatuses, visibleHarnesses) },
                                         sidebarSort, descending: sidebarSortDescending)
        let previouslySelected = sidebar.selectedEntry?.sessionName
        sidebar.reticuleEnabled = sidebarReticule
        sidebar.setEntries(visible, grouping: folderGrouping, select: nil)
        var selected = reselect.flatMap { name in visible.contains { $0.sessionName == name } ? name : nil }
        let reselectHidden = reselect != nil && selected == nil
        if selected == nil, let previouslySelected, visible.contains(where: { $0.sessionName == previouslySelected }) {
            // the reselect target (e.g. a session just created) may be filtered out —
            // don't drop the user's still-live prior selection because of it
            selected = previouslySelected
        }
        sidebar.select(sessionName: selected, scroll: true)
        if reselectHidden, let reselect, allEntries.contains(where: { $0.sessionName == reselect }) {
            terminalArea.showBanner("'\(reselect)' was created but is hidden by your current filter.")
        }
        if allEntries.isEmpty {
            sidebar.setEmptyText("No sessions yet.\nPress ⌘N to start one.")
        } else {
            sidebar.setEmptyText(visible.isEmpty ? "Every session is hidden by the current filters." : "")
        }
        if sidebar.selectedEntry != nil, activate {
            activateSelected()
        } else {
            let entry = sidebar.selectedEntry
            updateWindowTitle(entry)
            if entry == nil {
                terminalArea.showDefault()
            }
            toolbarController?.validate()
        }
    }

    /// Thread-safe in Java; here always called on main: a session killed by something
    /// other than this window (an agent's MCP `kill`) drops exactly what Kill drops.
    private func sessionKilledExternally(_ session: String) {
        guard !disposed else { return }
        dropSessionArtifacts(session)
        refreshSidebar(nil)
    }

    // MARK: - selection → lazy attach

    func sidebarSelectionDidChange(_ sidebar: SidebarViewController) {
        activateSelected()
    }

    func sidebarActivate(_ sidebar: SidebarViewController) {
        activateSelected()
    }

    func sidebar(_ sidebar: SidebarViewController, menuFor entry: SidebarEntry) -> NSMenu? {
        MainMenu.contextMenu(for: entry, attached: entry.isAttached)
    }

    /// Reflects the current selection in the terminal area, attaching lazily.
    private func activateSelected() {
        let entry = sidebar.selectedEntry
        updateWindowTitle(entry)
        defer { toolbarController?.validate() }
        guard let entry else {
            terminalArea.showDefault()
            return
        }
        lastSelectedSessionName = entry.sessionName
        switch entry.status {
        case .live:
            attachAndShow(entry)
            maybeCatchUpActiveTab(entry)
        case .dead:
            terminalArea.showDead(entry.displayName)
        }
    }

    /// Window title: the selected session's name, its folder as the subtitle.
    private func updateWindowTitle(_ entry: SidebarEntry?) {
        guard let window else { return }
        guard let entry else {
            window.title = AppModel.appName
            window.subtitle = ""
            return
        }
        window.title = MainWindowController.ellipsizeRight(entry.displayName, MainWindowController.windowTitleSessionMaxChars)
        window.subtitle = entry.abbreviatedPath
    }

    static func ellipsizeRight(_ text: String, _ max: Int) -> String {
        if text.count <= max { return text }
        if max <= 1 { return "…" }
        return String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Attaches on first selection only; re-selecting an attached session just shows its
    /// terminal. A cached terminal whose stream died is evicted and replaced.
    private func attachAndShow(_ entry: SidebarEntry) {
        let name = entry.sessionName
        if let terminal = attached[name], !terminal.isAlive {
            removeAttachment(name)
            statusPoller.forget(name) // a dead connection means that lifecycle ended
        }
        if let terminal = attached[name] {
            terminalArea.showTerminal(name)
            terminal.focus()
            return
        }
        if attaching[name] == nil {
            let generation = bumpAttachGeneration(name)
            attaching[name] = generation
            let disableWheel = entry.harnessType == .codex && AppSettings.codexMouseWheelDisabled()
            let backend = self.backend
            background.async { [weak self] in
                do {
                    let transport = try backend.attach(name, columns: SessionTerminal.columns, rows: SessionTerminal.rows)
                    DispatchQueue.main.async {
                        self?.landAttach(name, generation, transport, disableWheel)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.failAttach(name, generation, error.localizedDescription)
                    }
                }
            }
        }
        if isSelected(name) {
            terminalArea.showPlaceholder("Attaching to '\(entry.displayName)'…", progress: true)
        }
    }

    private func bumpAttachGeneration(_ name: String) -> Int {
        let next = (attachGeneration[name] ?? 0) + 1
        attachGeneration[name] = next
        return next
    }

    private func isCurrentAttach(_ name: String, _ generation: Int) -> Bool {
        (attachGeneration[name] ?? 0) == generation
    }

    private func settleInFlight(_ name: String, _ generation: Int) {
        if attaching[name] == generation {
            attaching[name] = nil
        }
    }

    /// Builds the terminal for a landed attach and caches it whatever the selection is
    /// now; shows it only if its row is still selected. A superseded result is closed.
    private func landAttach(_ name: String, _ generation: Int, _ transport: TerminalTransport, _ disableWheel: Bool) {
        settleInFlight(name, generation)
        if disposed || !isCurrentAttach(name, generation) {
            transport.close()
            return
        }
        let config = SessionTerminal.Config(
            background: nil, light: !isDark,
            palette: AnsiPalettes.forSetting(MainWindowController.palette(AppSettings.terminalPalette())),
            scrollbarHidden: AppSettings.terminalScrollbarHidden(), mouseWheelDisabled: disableWheel,
            fontFamily: terminalFontFamily, fontSize: terminalFontSize, optionAsMeta: AppSettings.optionAsMeta())
        let terminal = SessionTerminal(transport: transport, config: config, name: name)
        terminal.applyPageKeys(pageKeys)
        applyTerminalBackground(terminal)
        // a session that ends by itself (exit typed in a shell) must stop showing as live
        terminal.onEnded { [weak self] in
            self?.refreshSidebar(nil, quiet: true)
        }
        attached[name] = terminal
        if !attachOrder.contains(name) {
            attachOrder.append(name)
        }
        terminalArea.addTerminal(name, view: terminal.view)
        if let row = findEntry(name) {
            row.isAttached = true
            sidebar.reload(row)
        }
        toolbarController?.validate()
        if isSelected(name) {
            terminalArea.showTerminal(name)
            terminal.focus()
        }
    }

    /// Shown only while the row is still selected, so keystrokes never land in the wrong
    /// session's terminal.
    private func failAttach(_ name: String, _ generation: Int, _ message: String) {
        settleInFlight(name, generation)
        if isCurrentAttach(name, generation), isSelected(name) {
            terminalArea.showPlaceholder("Failed to attach to '\(name)': \(message)", symbol: "exclamationmark.triangle")
        }
    }

    private func isSelected(_ name: String) -> Bool {
        sidebar.selectedEntry?.sessionName == name
    }

    private func findEntry(_ name: String) -> SidebarEntry? {
        allEntries.first { $0.sessionName == name }
    }

    /// Drops one terminal and invalidates any attach still in flight, without touching
    /// the daemon.
    private func removeAttachment(_ name: String) {
        _ = bumpAttachGeneration(name)
        attaching[name] = nil
        if let terminal = attached.removeValue(forKey: name) {
            terminal.detach()
            terminalArea.removeTerminal(name)
        }
        attachOrder.removeAll { $0 == name }
    }

    static func palette(_ setting: AppSettings.TerminalPalette) -> AnsiPalettes.Palette {
        switch setting {
        case .macosTerminal: return .macosTerminal
        case .iterm2: return .iterm2
        case .xterm: return .xterm
        }
    }

    // MARK: - status polling

    private func startPollTimers() {
        statusPollTimer?.invalidate()
        activeTabPollTimer?.invalidate()
        statusPollTimer = nil
        activeTabPollTimer = nil
        if statusPollingEnabled {
            let timer = Timer(timeInterval: statusPollInterval, repeats: true) { [weak self] _ in self?.pollLiveSessions() }
            timer.tolerance = statusPollInterval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            statusPollTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollLiveSessions() }
        } else if activeTabPollMode == .scheduled {
            let timer = Timer(timeInterval: statusPollInterval, repeats: true) { [weak self] _ in self?.pollActiveTabOnly() }
            RunLoop.main.add(timer, forMode: .common)
            activeTabPollTimer = timer
        }
    }

    private func pollLiveSessions() {
        let live = allEntries.filter { $0.status == .live }.map(\.sessionEntry)
        poll(live)
    }

    private func pollActiveTabOnly() {
        guard let entry = sidebar.selectedEntry, entry.status == .live else { return }
        poll([entry.sessionEntry])
    }

    /// One round of polls; a backend that pins states (the demo) answers without capturing.
    private func poll(_ sessions: [SessionEntry], _ completion: ((String, SessionStatusPoller.PollResult) -> Void)? = nil) {
        guard !sessions.isEmpty, !disposed else { return }
        var real: [SessionEntry] = []
        for session in sessions {
            if let fixed = backend.fixedClassification(session.sessionName) {
                onFixedStatus(session.sessionName, fixed)
            } else {
                real.append(session)
            }
        }
        if !real.isEmpty {
            statusPoller.pollAll(real) { [weak self] name, result in
                self?.onStatusResult(name, result)
                completion?(name, result)
            }
        }
    }

    private func onFixedStatus(_ name: String, _ classification: Classification) {
        guard let entry = allEntries.first(where: { $0.status == .live && $0.sessionName == name }) else { return }
        if entry.state != classification.state || entry.stateReason != classification.reason {
            entry.setState(classification.state, classification.reason)
            rowChanged(entry, oldStatus: nil, oldDisplayName: entry.displayName)
        }
    }

    private func onStatusResult(_ name: String, _ result: SessionStatusPoller.PollResult) {
        guard !disposed else { return }
        if result.sessionGone, goneSessions.insert(name).inserted {
            refreshSidebar(nil, quiet: true) // the daemon no longer has it: the row goes dead
        }
        guard let entry = allEntries.first(where: { $0.status == .live && $0.sessionName == name }) else {
            return // went dead or was removed between the poll firing and this result
        }
        let oldStatus = SidebarView.filterStatus(entry)
        let oldDisplayName = entry.displayName
        let oldState = entry.state, oldReason = entry.stateReason, oldTitle = entry.paneTitle
        if result.stateConfirmed {
            entry.setState(result.classification.state, result.classification.reason)
        }
        entry.setPaneTitle(result.paneTitle)
        let changed = oldState != entry.state || oldReason != entry.stateReason || oldTitle != entry.paneTitle
        if changed {
            rowChanged(entry, oldStatus: oldStatus, oldDisplayName: oldDisplayName)
        }
    }

    /// Repaints one row, or rebuilds the list when its filter membership or sort
    /// position may have moved.
    private func rowChanged(_ entry: SidebarEntry, oldStatus: SidebarView.FilterStatus?, oldDisplayName: String) {
        let newStatus = SidebarView.filterStatus(entry)
        let statusMoved = oldStatus == nil || oldStatus != newStatus
        let filterMayChange = statusMoved && visibleStatuses.count != SidebarView.FilterStatus.allCases.count
        let orderMayChange = (sidebarSort == .status && statusMoved)
            || (sidebarSort == .sessionName && oldDisplayName != entry.displayName)
        if filterMayChange || orderMayChange {
            rebuildVisibleSidebar(lastSelectedSessionName, activate: false)
        } else {
            sidebar.reload(entry)
        }
        if sidebar.selectedEntry === entry {
            updateWindowTitle(entry) // a /rename must reach the window title too
        }
        onLiveSessionsChanged?()
    }

    /// ONCE active-tab mode: with the periodic timer off, catch a newly selected live
    /// session's badge up the moment it becomes the active tab (rate-limited per session).
    private func maybeCatchUpActiveTab(_ entry: SidebarEntry) {
        guard !statusPollingEnabled, activeTabPollMode == .once else { return }
        let last = entry.state
        guard last == nil || last == .working || last == .waitingForInput else { return }
        let now = Date()
        if let firedAt = activeTabCatchUpAt[entry.sessionName], now.timeIntervalSince(firedAt) < statusPollInterval {
            return
        }
        activeTabCatchUpAt[entry.sessionName] = now
        let sessionEntry = entry.sessionEntry
        background.async { [weak self] in
            _ = self?.catchUpConfirmedState(sessionEntry, last)
        }
    }

    /// With the periodic timer off, a never-polled (or stale busy) session has no
    /// confirmed state, and Close/Reload would refuse forever. Polls a few times until a
    /// confirmed classification lands (the detector needs two samples). Blocks: call it
    /// off the main thread. A no-op while the periodic timer runs.
    private func catchUpConfirmedState(_ session: SessionEntry, _ lastPolled: SessionState?) -> SessionState? {
        let staleOrUnknown = lastPolled == nil || lastPolled == .working || lastPolled == .waitingForInput
        var polling = true
        DispatchQueue.main.sync { polling = self.statusPollingEnabled }
        if !staleOrUnknown || polling {
            return lastPolled
        }
        if let fixed = backend.fixedClassification(session.sessionName) {
            return fixed.state
        }
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            if let confirmed = pollOnceForConfirmedState(session) {
                return confirmed
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    private func pollOnceForConfirmedState(_ session: SessionEntry) -> SessionState? {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var state: SessionState?
        DispatchQueue.main.async { [weak self] in
            guard let self else { done.signal(); return }
            self.statusPoller.pollAll([session]) { [weak self] name, result in
                self?.onStatusResult(name, result)
                lock.lock()
                state = result.stateConfirmed ? result.classification.state : nil
                lock.unlock()
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 3)
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Loads one provider quota snapshot per harness with a live session.
    func refreshHarnessBudgets() {
        budgetRefreshSeq += 1
        let sequence = budgetRefreshSeq
        let harnesses = HarnessBudgetPanel.budgetedHarnesses(SidebarView.activeHarnesses(allEntries))
        sidebar.budgetPanel.showLoading(harnesses)
        let usage = model.usage
        for harness in harnesses {
            background.async { [weak self] in
                do {
                    let snapshot = try usage.load(harness)
                    DispatchQueue.main.async {
                        guard let self, sequence == self.budgetRefreshSeq else { return }
                        self.sidebar.budgetPanel.showSnapshot(harness, snapshot)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, sequence == self.budgetRefreshSeq else { return }
                        self.sidebar.budgetPanel.showError(harness, error)
                    }
                }
            }
        }
    }

    // MARK: - keyboard

    /// Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+1..9 switch sessions. Taken before the focused
    /// terminal sees them — it would otherwise send them to the program — and only while
    /// this window is key with no sheet on it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil else {
                return event
            }
            let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
            guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else { return event }
            if event.keyCode == 48 { // Tab
                self.cycleAttached(flags.contains(.shift) ? -1 : 1)
                return nil
            }
            if !flags.contains(.shift), let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                self.jumpToNthSession(digit)
                return nil
            }
            return event
        }
    }

    /// Cycles through the sessions in the order they were first attached (fixed
    /// position, like a browser's tab strip), wrapping at both ends.
    private func cycleAttached(_ direction: Int) {
        let visible = Set(sidebar.visibleEntries.map(\.sessionName))
        let cycle = attachOrder.filter { attached[$0] != nil && visible.contains($0) }
        guard !cycle.isEmpty else { return }
        let current = sidebar.selectedEntry?.sessionName
        let next: Int
        if let current, let index = cycle.firstIndex(of: current) {
            next = ((index + direction) % cycle.count + cycle.count) % cycle.count
        } else {
            next = direction > 0 ? 0 : cycle.count - 1
        }
        selectSession(cycle[next])
    }

    /// Ctrl+1..8 jump to the nth visible session; Ctrl+9 always to the last.
    private func jumpToNthSession(_ n: Int) {
        let rows = sidebar.visibleEntries
        guard !rows.isEmpty else { return }
        let index = n == 9 ? rows.count - 1 : n - 1
        guard index >= 0, index < rows.count else { return }
        selectSession(rows[index].sessionName)
    }

    private func selectSession(_ name: String) {
        if sidebar.select(sessionName: name, scroll: true) {
            activateSelected()
        }
    }

    @objc func selectNextSession(_ sender: Any?) { cycleAttached(1) }
    @objc func selectPreviousSession(_ sender: Any?) { cycleAttached(-1) }
    @objc func selectSessionNumber(_ sender: NSMenuItem) { jumpToNthSession(sender.tag) }

    /// Reachable from the View menu even when nothing inside the split view has focus.
    @objc func toggleSidebar(_ sender: Any?) {
        splitController.toggleSidebar(sender)
    }

    @objc func focusSidebar(_ sender: Any?) {
        window?.makeFirstResponder(sidebar.outlineView)
    }

    // MARK: - terminal font and paging

    private func adjustTerminalFontSize(to size: Int) {
        let adjusted = AppSettings.clampTerminalFontSize(size)
        guard adjusted != terminalFontSize else { return }
        terminalFontSize = adjusted
        for terminal in attached.values {
            terminal.applyFont(family: terminalFontFamily, size: terminalFontSize)
        }
        let family = terminalFontFamily
        settingsQueue.async { AppSettings.saveTerminalFont(family, adjusted) }
    }

    @objc func terminalZoomIn(_ sender: Any?) { adjustTerminalFontSize(to: terminalFontSize + 1) }
    @objc func terminalZoomOut(_ sender: Any?) { adjustTerminalFontSize(to: terminalFontSize - 1) }
    @objc func terminalZoomReset(_ sender: Any?) { adjustTerminalFontSize(to: AppSettings.defaultTerminalFontSize) }

    private var selectedTerminal: SessionTerminal? {
        guard let entry = sidebar.selectedEntry, entry.status == .live else { return nil }
        return attached[entry.sessionName]
    }

    @objc func scrollSessionPageUp(_ sender: Any?) { selectedTerminal?.pageUp() }
    @objc func scrollSessionPageDown(_ sender: Any?) { selectedTerminal?.pageDown() }
    @objc func scrollSessionToTop(_ sender: Any?) { selectedTerminal?.scrollToTop() }
    @objc func scrollSessionToBottom(_ sender: Any?) { selectedTerminal?.scrollToBottom() }

    // MARK: - validation

    var liveManagedEntries: [SidebarEntry] { allEntries.filter { $0.status == .live } }
    private var deadEntries: [SidebarEntry] { allEntries.filter { $0.status == .dead } }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action {
            switch action {
            case #selector(sortBy(_:)):
                menuItem.state = (menuItem.representedObject as? String) == sidebarSort.key ? .on : .off
            case #selector(toggleSortDescending(_:)):
                menuItem.state = sidebarSortDescending ? .on : .off
            case #selector(toggleStatusFilter(_:)):
                let status = SidebarView.FilterStatus(rawValue: menuItem.tag)
                menuItem.state = status.map { visibleStatuses.contains($0) } == true ? .on : .off
            case #selector(toggleHarnessFilter(_:)):
                let families = SidebarView.HarnessFamily.allCases
                menuItem.state = menuItem.tag >= 0 && menuItem.tag < families.count
                    && visibleHarnesses.contains(families[menuItem.tag]) ? .on : .off
            case #selector(toggleFolderGroups(_:)):
                menuItem.state = sidebarFolderGroups ? .on : .off
            case #selector(toggleAppearance(_:)):
                menuItem.title = isDark ? "Use Light Appearance" : "Use Dark Appearance"
            default:
                break
            }
        }
        return validate(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action)
    }

    /// Enables each action exactly when it would do something (Java's
    /// `updateSelectionButtons`, plus the context menu's per-status offerings).
    func validate(_ action: Selector?) -> Bool {
        guard let action else { return true }
        let entry = sidebar.selectedEntry
        switch action {
        case #selector(newSession(_:)):
            return !createInFlight
        case #selector(newSessionHere(_:)):
            return !createInFlight
        case #selector(newShellHere(_:)), #selector(duplicateSession(_:)):
            return entry != nil && !createInFlight
        case #selector(scrollSessionPageUp(_:)), #selector(scrollSessionPageDown(_:)),
             #selector(scrollSessionToTop(_:)), #selector(scrollSessionToBottom(_:)):
            return selectedTerminal != nil
        case #selector(detachSession(_:)):
            return entry?.status == .live && entry?.isAttached == true
        case #selector(closeSession(_:)), #selector(killSession(_:)), #selector(reloadSession(_:)):
            return entry?.status == .live
        case #selector(resumeSession(_:)), #selector(removeFromRegistry(_:)):
            return entry?.status == .dead
        case #selector(renameSession(_:)), #selector(copySessionPath(_:)), #selector(revealSessionFolder(_:)):
            return entry != nil
        case #selector(closeAllSessions(_:)), #selector(batchCloseSessions(_:)):
            return !liveManagedEntries.isEmpty
        case #selector(removeDeadSessions(_:)):
            return !deadEntries.isEmpty
        case #selector(selectNextSession(_:)), #selector(selectPreviousSession(_:)):
            return attached.count > 0
        case #selector(selectSessionNumber(_:)):
            return !sidebar.visibleEntries.isEmpty
        case #selector(terminalZoomIn(_:)):
            return terminalFontSize < AppSettings.maxTerminalFontSize
        case #selector(terminalZoomOut(_:)):
            return terminalFontSize > AppSettings.minTerminalFontSize
        default:
            return true
        }
    }

    // MARK: - session actions

    @objc func newSession(_ sender: Any?) {
        showNewSessionSheet(prefillPath: nil, prefillHarness: nil)
    }

    /// "Another one of these, right there": the New sheet seeded with the selected
    /// session's folder and harness.
    @objc func newSessionHere(_ sender: Any?) {
        guard let entry = sidebar.selectedEntry else {
            newSession(sender)
            return
        }
        showNewSessionSheet(prefillPath: entry.sessionEntry.projectPath, prefillHarness: entry.harnessType)
    }

    private func showNewSessionSheet(prefillPath: String?, prefillHarness: HarnessType?) {
        guard let window, !createInFlight else { return }
        let shell = backend.describeShell(AppSettings.sessionShell())
        NewSessionSheet.present(on: window, prefillPath: prefillPath, prefillHarness: prefillHarness,
                                shellDescription: shell) { [weak self] result in
            guard let self, let result else { return }
            self.createSession(result.projectPath, result.harness, resumeId: result.resumeId,
                               displayName: result.displayName, firstMessage: result.firstMessage)
        }
    }

    /// ⌘T: a new shell in the selected session's folder. No selection is a no-op.
    @objc func newShellHere(_ sender: Any?) {
        guard let entry = sidebar.selectedEntry else { return }
        createSession(URL(fileURLWithPath: entry.sessionEntry.projectPath), .shell)
    }

    /// ⌘D: a fresh session of the same harness in the same folder — no resume id, so a
    /// dead row duplicates to a new life rather than resuming the old one.
    @objc func duplicateSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender) else { return }
        createSession(URL(fileURLWithPath: entry.sessionEntry.projectPath), entry.harnessType)
    }

    /// Creates and registers a new session off the main thread (several daemon round
    /// trips); `createInFlight` doubles as reentry protection.
    private func createSession(_ path: URL, _ harness: HarnessType, resumeId: String? = nil,
                               displayName: String? = nil, firstMessage: String? = nil) {
        guard !createInFlight else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showAlert("Invalid path", "'\(path.path)' is not a folder.", style: .warning)
            return
        }
        createInFlight = true
        toolbarController?.validate()
        let backend = self.backend
        background.async { [weak self] in
            do {
                let name = try backend.create(projectPath: path, harness: harness, resumeId: resumeId,
                                              displayName: displayName, firstMessage: firstMessage,
                                              onNoResumeSyntax: { self?.warnNoResumeSyntax(harness) })
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.createInFlight = false
                    self.refreshSidebar(name)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.createInFlight = false
                    self.toolbarController?.validate()
                    self.showAlert("Couldn’t start the session", error.localizedDescription, style: .critical)
                    self.refreshSidebar(nil) // reflect whatever half-state the failure left
                }
            }
        }
    }

    private func warnNoResumeSyntax(_ harness: HarnessType) {
        DispatchQueue.main.async { [weak self] in
            self?.showAlert("No resume syntax",
                            "'\(harness.id)' has no known resume syntax — starting a fresh session instead.",
                            style: .warning)
        }
    }

    /// The row a context-menu item was built for, else the selection.
    private func clickedOrSelected(_ sender: Any?) -> SidebarEntry? {
        if let item = sender as? NSMenuItem, let name = item.representedObject as? String {
            return findEntry(name)
        }
        return sidebar.selectedEntry
    }

    @objc func detachSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender), entry.status == .live, entry.isAttached else { return }
        removeAttachment(entry.sessionName)
        entry.isAttached = false
        sidebar.reload(entry)
        toolbarController?.validate()
        if isSelected(entry.sessionName) {
            terminalArea.showPlaceholder("'\(entry.displayName)' is detached and still running. Select it again to reattach.",
                                         symbol: "pause.circle")
        }
    }

    /// ⌘W: gracefully ends the selected live session — the harness quits itself and the
    /// shell under it exits; the registry entry stays as a resumable row. Refuses (with an
    /// explanation) while anything is in progress.
    @objc func closeSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender) else { return }
        gracefulCloseFlow(entry, reload: false)
    }

    /// Close, then immediately relaunch the harness from the resume id just captured.
    @objc func reloadSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender) else { return }
        gracefulCloseFlow(entry, reload: true)
    }

    private func gracefulCloseFlow(_ entry: SidebarEntry, reload: Bool) {
        guard entry.status == .live else { return }
        let sessionEntry = entry.sessionEntry
        let lastPolled = entry.state
        let name = sessionEntry.sessionName
        let plugin = HarnessPlugins.of(sessionEntry.harnessType)
        let review = PreflightDialog.Session(entry)
        let closer = gracefulCloser!
        background.async { [weak self] in
            guard let self else { return }
            do {
                let resolved = self.catchUpConfirmedState(sessionEntry, lastPolled)
                let blocker = try closer.preflight(name, plugin, resolved)
                DispatchQueue.main.async {
                    if let blocker {
                        self.handleGracefulCloseResult(name, blocker)
                        return
                    }
                    PreflightDialog.present(reload ? .reload(review) : .close(review), on: self.window) { confirmed in
                        if confirmed {
                            self.executeGracefulClose(sessionEntry, plugin, resolved, reloadAfter: reload)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(reload ? "Reload pre-flight failed" : "Close pre-flight failed",
                                   "Could not check whether '\(name)' can \(reload ? "reload" : "close") safely: \(error.localizedDescription)",
                                   style: .critical)
                }
            }
        }
    }

    private func executeGracefulClose(_ sessionEntry: SessionEntry, _ plugin: HarnessPlugin, _ lastPolled: SessionState?,
                                      reloadAfter: Bool) {
        let name = sessionEntry.sessionName
        let closer = gracefulCloser!
        let registry = self.registry
        terminalArea.showBanner(reloadAfter ? "Reloading '\(name)'…" : "Closing '\(name)'…")
        background.async { [weak self] in
            do {
                let result = try closer.close(name, plugin, lastPolled)
                // persist the provider's exit receipt before the terminal is dropped: the
                // row survives close and now knows which conversation Resume must reopen
                if let id = result.harnessSessionIdOpt {
                    registry.recordHarnessSessionId(name, id)
                }
                let closedOk = result.outcome == .closed || result.outcome == .alreadyGone
                DispatchQueue.main.async {
                    guard let self else { return }
                    if reloadAfter && closedOk {
                        self.dropRuntimeArtifacts(name)
                        self.resume(registry.find(name) ?? sessionEntry)
                    } else {
                        self.handleGracefulCloseResult(name, result)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showAlert("Close failed", "Graceful close of '\(name)' failed: \(error.localizedDescription)",
                                    style: .critical)
                }
            }
        }
    }

    /// Cleanup on success, an explanation on refusal (refusals leave the session intact).
    private func handleGracefulCloseResult(_ name: String, _ result: GracefulCloser.Result) {
        switch result.outcome {
        case .closed, .alreadyGone:
            dropRuntimeArtifacts(name)
            refreshSidebar(nil)
        case .busyState:
            showAlert("Session busy", "'\(name)' is not closed: \(result.detail).", style: .informational)
        case .busyForeground:
            showAlert("Session busy", "'\(name)' is not closed: '\(result.detail)' is still running in it.",
                      style: .informational)
        case .noQuitSyntax:
            showAlert("No quit syntax",
                      "'\(result.detail)' has no verified graceful-quit syntax — use Kill Session… to force it.",
                      style: .warning)
        case .quitTimeout:
            showAlert("Close timed out",
                      "Sent '\(result.detail)' but the harness in '\(name)' didn't exit in time — leaving the session as it is.",
                      style: .warning)
            refreshSidebar(nil)
        case .exitTimeout:
            showAlert("Close timed out",
                      "Sent 'exit' but the shell in '\(name)' didn't end in time — something may still be running in it.",
                      style: .warning)
            refreshSidebar(nil)
        }
    }

    @objc func killSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender), entry.status == .live else { return }
        let name = entry.sessionName
        PreflightDialog.present(.kill(PreflightDialog.Session(entry)), on: window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let backend = self.backend
            self.background.async { [weak self] in
                // cleanup only if the session is really gone: a failed kill must not
                // orphan a running harness by deleting its registry entry
                var gone: Bool
                var failure: String?
                do {
                    try backend.killSession(name)
                    gone = true
                } catch {
                    failure = error.localizedDescription
                    gone = !((try? backend.hasSession(name)) ?? true)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if gone {
                        self.dropSessionArtifacts(name)
                    } else {
                        self.showAlert("Kill failed",
                                       "Kill failed: \(failure ?? "unknown error")\nThe session is still running; its registry entry is kept.",
                                       style: .critical)
                    }
                    self.refreshSidebar(nil)
                }
            }
        }
    }

    @objc func resumeSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender), entry.status == .dead else { return }
        resume(entry.sessionEntry)
    }

    private func resume(_ sessionEntry: SessionEntry) {
        let name = sessionEntry.sessionName
        // a fresh lifecycle under the same name: reset quiescence timing and evict any
        // terminal left over from the dead one
        statusPoller.forget(name)
        removeAttachment(name)
        let backend = self.backend
        if isSelected(name) {
            terminalArea.showPlaceholder("Resuming '\(name)'…", progress: true)
        }
        background.async { [weak self] in
            do {
                try backend.resume(sessionEntry, onNoResumeSyntax: { self?.warnNoResumeSyntax(sessionEntry.harnessType) })
                DispatchQueue.main.async { self?.refreshSidebar(name) }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.showAlert("Resume failed", "Failed to resume '\(name)': \(error.localizedDescription)",
                                   style: .critical)
                    self.refreshSidebar(nil)
                }
            }
        }
    }

    @objc func removeFromRegistry(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender), entry.status == .dead else { return }
        let name = entry.sessionName
        registry.remove(name)
        discardMcpConfig(name)
        statusPoller.forget(name)
        refreshSidebar(nil)
    }

    /// Changes only the user-facing sidebar name; the session key stays.
    @objc func renameSession(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender), let current = registry.find(entry.sessionName),
              let window else { return }
        RenameSheet.present(on: window, current: current.displayName ?? "", inherited: entry.detectedName) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .cancel:
                return
            case .clear:
                self.registry.put(current.withDisplayName(nil))
            case .rename(let name):
                self.registry.put(current.withDisplayName(name))
            }
            self.refreshSidebar(entry.sessionName)
        }
    }

    @objc func copySessionPath(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sessionEntry.projectPath, forType: .string)
    }

    @objc func revealSessionFolder(_ sender: Any?) {
        guard let entry = clickedOrSelected(sender) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.sessionEntry.projectPath)
    }

    /// Close All: every live session through the same ladder as Close; whatever refuses
    /// or times out is reported together at the end.
    @objc func closeAllSessions(_ sender: Any?) {
        let live = liveManagedEntries
        guard !live.isEmpty else { return }
        PreflightDialog.present(.closeAll(live.map(PreflightDialog.Session.init)), on: window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let targets = live.map { ($0.sessionEntry, $0.state) }
            let closer = self.gracefulCloser!
            let registry = self.registry
            self.background.async { [weak self] in
                var closed: [String] = []
                var leftRunning: [String] = []
                for (entry, lastPolled) in targets {
                    if let failure = BatchActions.close(entry, lastPolled, closer, registry) {
                        leftRunning.append(failure)
                    } else {
                        closed.append(entry.sessionName)
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    closed.forEach(self.dropRuntimeArtifacts)
                    if !leftRunning.isEmpty {
                        self.showAlert("Some sessions are still running", "Left running:\n" + leftRunning.joined(separator: "\n"),
                                       style: .informational)
                    }
                    self.refreshSidebar(nil)
                }
            }
        }
    }

    @objc func batchCloseSessions(_ sender: Any?) {
        let live = liveManagedEntries
        guard !live.isEmpty, let window else { return }
        let closer = gracefulCloser!
        let registry = self.registry
        BatchOperationSheet.present(
            on: window, title: "Close a batch of sessions",
            intro: "Idle sessions are pre-selected. Uncheck any folder or session you want to leave running.",
            confirm: "Close Selected", candidates: live, defaultChecked: { $0.state == .idle },
            rowLabel: { $0.statusPhrase }, words: .init(gerund: "Closing", past: "Closed", infinitive: "close"),
            queue: background,
            operation: { entry in BatchActions.close(entry.sessionEntry, entry.state, closer, registry) },
            onSucceeded: { [weak self] entry in self?.dropRuntimeArtifacts(entry.sessionName) },
            onFinished: { [weak self] in self?.refreshSidebar(nil) })
    }

    @objc func removeDeadSessions(_ sender: Any?) {
        let dead = deadEntries
        guard !dead.isEmpty, let window else { return }
        let registry = self.registry
        let poller = statusPoller!
        BatchOperationSheet.present(
            on: window, title: "Remove dead sessions",
            intro: "Removing forgets a session for good — its saved conversation can no longer be resumed. "
                + "Uncheck any folder or session you want to keep.",
            confirm: "Remove Selected", candidates: dead, defaultChecked: { _ in true },
            rowLabel: { $0.harnessType.id }, words: .init(gerund: "Removing", past: "Removed", infinitive: "remove"),
            queue: background,
            operation: { entry in
                registry.remove(entry.sessionName)
                poller.forget(entry.sessionName)
                return nil
            },
            onSucceeded: { [weak self] entry in self?.discardMcpConfig(entry.sessionName) },
            onFinished: { [weak self] in self?.refreshSidebar(nil) })
    }

    /// Runtime state of an ended lifecycle; the saved entry stays (resumable).
    private func dropRuntimeArtifacts(_ name: String) {
        removeAttachment(name)
        statusPoller.forget(name)
    }

    /// Runtime state plus the saved entry: Kill and Remove from registry only.
    private func dropSessionArtifacts(_ name: String) {
        dropRuntimeArtifacts(name)
        registry.remove(name)
        discardMcpConfig(name)
    }

    private func discardMcpConfig(_ name: String) {
        let backend = self.backend
        background.async { backend.discardMcpConfig(name) }
    }

    @objc func showUsage(_ sender: Any?) {
        UsageWindowController.show(initial: sidebar.selectedEntry?.harnessType ?? .claudeCode, usage: model.usage)
    }

    @objc func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }

    @objc func refreshSessions(_ sender: Any?) {
        refreshSidebar(nil)
        refreshHarnessBudgets()
    }

    // MARK: - settings

    /// Applies a saved Settings sheet live: surfaces, terminals, polling, toolbar.
    func applySettings(_ result: SettingsResult) {
        pageKeys = result.pageKeys
        toolbarLabels = result.toolbarLabels
        toolbarPageButtons = result.toolbarPageButtons
        toolbarStopLadder = result.toolbarStopLadder
        toolbarBatchActions = result.toolbarBatchActions
        sidebarBackground = result.sidebarBackground
        rightPaneMatchesSidebar = result.rightPaneMatchesSidebar
        terminalBackgroundOverride = result.backgroundOverride
        sidebarReticule = result.sidebarReticule
        sidebarFolderGroups = result.sidebarFolderGroups
        terminalFontFamily = result.fontFamily
        terminalFontSize = AppSettings.clampTerminalFontSize(result.fontSize)
        statusPollInterval = Double(AppSettings.clampStatusPollIntervalMs(result.statusPollIntervalMs)) / 1000
        statusPollingEnabled = result.statusPollingEnabled
        activeTabPollMode = result.activeTabPollMode
        startPollTimers()
        applySurfaces()
        rebuildVisibleSidebar(lastSelectedSessionName, activate: false)
        updateSidebarControls()
        rebuildToolbar()
        for (name, terminal) in attached {
            terminal.applyPalette(MainWindowController.palette(result.palette))
            terminal.applyFont(family: terminalFontFamily, size: terminalFontSize)
            terminal.applyOptionAsMeta(result.optionAsMeta)
            terminal.applyPageKeys(result.pageKeys)
            terminal.applyMouseWheelDisabled(result.codexMouseWheelDisabled && findEntry(name)?.harnessType == .codex)
        }
    }

    // MARK: - alerts

    /// A sheet on the window; app-modal when another sheet is already up.
    func showAlert(_ title: String, _ message: String, style: NSAlert.Style, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let window, window.attachedSheet == nil, window.isVisible {
            alert.beginSheetModal(for: window) { _ in completion?() }
        } else {
            alert.runModal()
            completion?()
        }
    }

    /// `DebugHooks`: start a session as the New sheet would.
    func debugCreate(_ path: String, _ harness: HarnessType, message: String?) {
        createSession(URL(fileURLWithPath: path), harness, firstMessage: message)
    }

    /// `DebugHooks`: select a row as a click would.
    func debugSelect(_ name: String) {
        selectSession(name)
    }

    // MARK: - lifecycle

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    /// Everything the window does on quit: stops timers, detaches every terminal (kills
    /// nothing).
    func shutdown() {
        guard !disposed else { return }
        disposed = true
        statusPollTimer?.invalidate()
        activeTabPollTimer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        appearanceObservation = nil
        for terminal in attached.values {
            terminal.detach()
        }
        settingsQueue.sync {}
    }
}

extension MainWindowController {
    /// `DebugHooks`: switch the sort as the Sort menu would.
    func debugSort(_ key: String) {
        let item = NSMenuItem()
        item.representedObject = key
        sortBy(item)
    }
}
