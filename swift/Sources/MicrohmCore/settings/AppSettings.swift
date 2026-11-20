import Foundation
import MicrohmShared
import Security

/// App-level settings, read from `settings.properties` beside the registry file
/// (`MicrohmPaths.settingsFile`, so a scratch home gets isolated settings too). Read on
/// demand rather than cached, so edits take effect on the next use without a restart. A
/// missing file, missing key, or unreadable file all fall back to defaults.
public enum AppSettings {

    /// Serializes every read and load-mutate-store in this process: without it, two
    /// saves racing from different threads each rewrite the file from their own stale
    /// load and one change is silently lost. Other processes are covered by the atomic
    /// replace in `save` — a reader sees the old file or the new one, never a truncated
    /// one. Recursive, like Java's `synchronized`, because `mcpToken` saves while holding it.
    private static let lock = NSRecursiveLock()

    public static let minTerminalFontSize = 8
    public static let maxTerminalFontSize = 36
    public static let defaultTerminalFontSize = 14

    public static let minStatusPollIntervalMs = 1000
    public static let maxStatusPollIntervalMs = 60_000
    public static let defaultStatusPollIntervalMs = 4000

    public static let minMcpPort = 1024
    public static let maxMcpPort = 65_535
    /// 7402 in this port (the Java app's was 7392), so both can run side by side.
    public static let defaultMcpPort = MicrohmPaths.defaultMcpPort
    /// 7403 in this port (the Java app's was 7393).
    public static let defaultPhonePort = MicrohmPaths.defaultPhonePort

    /// Random bytes behind a generated `mcpToken`: 32, i.e. 43 url-safe base64 chars.
    private static let mcpTokenBytes = 32

    // MARK: - terminal font

    /// Terminal font shared by every attached tab. The unset default is the platform's
    /// stock monospace face: Menlo on macOS.
    public static func terminalFontFamily() -> String {
        guard let value = load().getProperty("terminal.font-family"), !JavaText.isBlank(value) else {
            return defaultTerminalFontFamily()
        }
        return JavaText.trim(value)
    }

    /// Terminal font size in points, clamped so hand-edited settings remain usable.
    public static func terminalFontSize() -> Int {
        guard let value = load().getProperty("terminal.font-size") else {
            return defaultTerminalFontSize
        }
        guard let parsed = parseInt(value) else {
            return defaultTerminalFontSize
        }
        return clampTerminalFontSize(parsed)
    }

    public static func clampTerminalFontSize(_ size: Int) -> Int {
        max(minTerminalFontSize, min(maxTerminalFontSize, size))
    }

    /// Persists the app-wide font in one rewrite so family and size cannot get out of step.
    public static func saveTerminalFont(_ family: String?, _ size: Int) {
        let normalizedFamily = family.map { JavaText.isBlank($0) ? defaultTerminalFontFamily() : JavaText.trim($0) }
            ?? defaultTerminalFontFamily()
        let normalizedSize = clampTerminalFontSize(size)
        save { p in
            p.setProperty("terminal.font-family", normalizedFamily)
            p.setProperty("terminal.font-size", String(normalizedSize))
        }
    }

    private static func defaultTerminalFontFamily() -> String {
        "Menlo"
    }

    // MARK: - terminal background

    /// Terminal default background. `terminal.background=black|white` pins it
    /// explicitly; unset (the default), terminals follow `uiTheme()` — black in the dark
    /// look, white in the light one.
    public enum TerminalBackground: String, CaseIterable, Sendable {
        case black = "BLACK"
        case white = "WHITE"

        /// The background matching an app theme: dark UI, black terminal; light, white.
        public static func forTheme(_ theme: UiTheme) -> TerminalBackground {
            theme == .light ? .white : .black
        }

        static func parse(_ value: String?) -> TerminalBackground? {
            guard let value else { return nil }
            let trimmed = JavaText.trim(value)
            if trimmed.caseInsensitiveCompare("black") == .orderedSame { return .black }
            if trimmed.caseInsensitiveCompare("white") == .orderedSame { return .white }
            return nil // unrecognized -> no pin, follow the theme
        }
    }

    /// The explicit `terminal.background` pin, or nil to follow the app theme.
    public static func terminalBackgroundOverride() -> TerminalBackground? {
        TerminalBackground.parse(load().getProperty("terminal.background"))
    }

    /// What a terminal attaching right now should use: the pin if set, else the theme's pair.
    public static func terminalBackground() -> TerminalBackground {
        terminalBackgroundOverride() ?? TerminalBackground.forTheme(uiTheme())
    }

    // MARK: - palette

    /// ANSI palette for the 16 base colors: `terminal.palette=macos|iterm2|xterm`. Only
    /// those 16 slots — the 256-color cube and truecolor are what they are. Default (unset
    /// or unrecognized): macOS Terminal's colors, so plain ANSI output matches what the
    /// stock terminal shows; `xterm` is the xterm-style palette the app's first terminal
    /// widget (JediTerm) used, which is why the legacy value `jediterm` still loads as it.
    public enum TerminalPalette: String, CaseIterable, Sendable {
        case macosTerminal = "macos"
        case iterm2 = "iterm2"
        case xterm = "xterm"

        /// The value settings files written before the in-house terminal used for `xterm`.
        private static let legacyXtermKey = "jediterm"

        var key: String { rawValue }

        static func parse(_ value: String?) -> TerminalPalette {
            if let value {
                let trimmed = JavaText.trim(value)
                if trimmed.caseInsensitiveCompare(legacyXtermKey) == .orderedSame {
                    return .xterm
                }
                for palette in allCases where palette.key.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return palette
                }
            }
            return .macosTerminal
        }
    }

    public static func terminalPalette() -> TerminalPalette {
        TerminalPalette.parse(load().getProperty("terminal.palette"))
    }

    /// Persists the palette choice — always written, so the file documents the default too.
    public static func saveTerminalPalette(_ palette: TerminalPalette) {
        save { $0.setProperty("terminal.palette", palette.key) }
    }

    // MARK: - on/off switches

    /// Whether attached terminals hide their scrollbar: `terminal.scrollbar=hidden`.
    /// Default (unset or anything else): visible. Applies to terminals attached after the
    /// change; already-attached widgets keep the bar they were built with.
    public static func terminalScrollbarHidden() -> Bool {
        isExactly("terminal.scrollbar", "hidden")
    }

    /// Whether toolbar buttons carry a text label next to their glyph:
    /// `toolbar.labels=on|off`. On (unset, or anything but `off` — the default): labeled;
    /// off: icon-only, tooltips still name every action.
    public static func toolbarLabels() -> Bool {
        !isExactly("toolbar.labels", "off")
    }

    /// Persists the label choice — written explicitly both ways, so the file documents it.
    public static func saveToolbarLabels(_ on: Bool) {
        saveOnOff("toolbar.labels", on)
    }

    /// Whether the toolbar shows its Page Up/Down controls: `toolbar.page-buttons=on|off`.
    /// Off (unset, or anything but `on` — the default): the controls stay hidden; their
    /// optional keyboard mapping remains independent and can still be enabled.
    public static func toolbarPageButtons() -> Bool {
        isExactly("toolbar.page-buttons", "on")
    }

    /// Persists the toolbar paging-control visibility explicitly both ways.
    public static func saveToolbarPageButtons(_ on: Bool) {
        saveOnOff("toolbar.page-buttons", on)
    }

    /// Whether the toolbar shows its stop-ladder controls — take over, detach, close,
    /// kill, and shutdown: `toolbar.stop-ladder=on|off`. Off (unset, or anything but `on`
    /// — the default): the controls stay hidden.
    public static func toolbarStopLadder() -> Bool {
        isExactly("toolbar.stop-ladder", "on")
    }

    /// Persists the stop-ladder visibility explicitly both ways.
    public static func saveToolbarStopLadder(_ on: Bool) {
        saveOnOff("toolbar.stop-ladder", on)
    }

    /// Whether the toolbar shows its batch-action controls — Batch close and Remove dead
    /// sessions: `toolbar.batch-actions=on|off`. On (unset, or anything but `off` — the
    /// default): the controls are shown, in their own group.
    public static func toolbarBatchActions() -> Bool {
        !isExactly("toolbar.batch-actions", "off")
    }

    /// Persists the batch-action controls' visibility explicitly both ways.
    public static func saveToolbarBatchActions(_ on: Bool) {
        saveOnOff("toolbar.batch-actions", on)
    }

    /// Sidebar surface: `sidebar.background=default|ui-gray|terminal` — the original list
    /// gray, the UI panel gray, or theme black/white. Unset or unrecognized: terminal.
    public enum SidebarBackground: String, CaseIterable, Sendable {
        case `default` = "DEFAULT"
        case uiGray = "UI_GRAY"
        case terminal = "TERMINAL"

        /// The settings-file spelling: `default`, `ui-gray`, `terminal`.
        var key: String { rawValue.lowercased().replacingOccurrences(of: "_", with: "-") }

        static func parse(_ value: String?) -> SidebarBackground {
            if let value {
                let trimmed = JavaText.trim(value)
                for background in allCases
                where background.rawValue.replacingOccurrences(of: "_", with: "-")
                    .caseInsensitiveCompare(trimmed) == .orderedSame {
                    return background
                }
            }
            return .terminal
        }
    }

    public static func sidebarBackground() -> SidebarBackground {
        SidebarBackground.parse(load().getProperty("sidebar.background"))
    }

    public static func saveSidebarBackground(_ background: SidebarBackground) {
        save { $0.setProperty("sidebar.background", background.key) }
    }

    /// Whether the right pane follows the sidebar surface instead of its own background;
    /// on unless explicitly `off`.
    public static func rightPaneMatchesSidebar() -> Bool {
        "off".caseInsensitiveCompare(JavaText.trim(load().getProperty("right-pane.match-sidebar", "on"))) != .orderedSame
    }

    public static func saveRightPaneMatchesSidebar(_ on: Bool) {
        saveOnOff("right-pane.match-sidebar", on)
    }

    /// Whether main-window toolbar surfaces and buttons follow the sidebar background; on
    /// unless explicitly `off`.
    public static func toolbarMatchesSidebar() -> Bool {
        "off".caseInsensitiveCompare(JavaText.trim(load().getProperty("toolbar.match-sidebar", "on"))) != .orderedSame
    }

    public static func saveToolbarMatchesSidebar(_ on: Bool) {
        saveOnOff("toolbar.match-sidebar", on)
    }

    /// Preserve matching sidebar sections unless the user explicitly unlinks them.
    public static func sidebarSectionsMatchBackground() -> Bool {
        "off".caseInsensitiveCompare(
            JavaText.trim(load().getProperty("sidebar.sections-match-background", "on"))) != .orderedSame
    }

    public static func saveSidebarSectionsMatchBackground(_ on: Bool) {
        saveOnOff("sidebar.sections-match-background", on)
    }

    /// Whether the sidebar suppresses the focus decoration:
    /// `sidebar.focus-border=hidden|visible`. Hidden (unset, or anything but `visible` —
    /// the default) keeps the normal neutral boundary but does not recolor or expand it
    /// when the session list briefly receives keyboard focus.
    public static func sidebarFocusBorderHidden() -> Bool {
        !isExactly("sidebar.focus-border", "visible")
    }

    /// Persists the sidebar focus-decoration choice explicitly both ways.
    public static func saveSidebarFocusBorderHidden(_ hidden: Bool) {
        save { $0.setProperty("sidebar.focus-border", hidden ? "hidden" : "visible") }
    }

    /// Whether unattached and dead sidebar sessions use the dithered reticule treatment:
    /// `sidebar.reticule=on|off`. Off (unset, or anything but `on` — the default) leaves
    /// session rows and dead-session icons unobscured.
    public static func sidebarReticule() -> Bool {
        isExactly("sidebar.reticule", "on")
    }

    /// Persists the sidebar reticule choice explicitly both ways.
    public static func saveSidebarReticule(_ on: Bool) {
        saveOnOff("sidebar.reticule", on)
    }

    /// Whether a run of sidebar sessions sharing a project folder is drawn as one visual
    /// group — a folder heading above the run, no repeated path on the rows below:
    /// `sidebar.folder-groups=on|off`. On (unset, or anything but `off` — the default).
    /// Only the folder sort can group, since only there is a folder's sessions guaranteed
    /// to be adjacent; every other sort renders the plain rows either way.
    public static func sidebarFolderGroups() -> Bool {
        !isExactly("sidebar.folder-groups", "off")
    }

    /// Persists the folder-grouping choice explicitly both ways.
    public static func saveSidebarFolderGroups(_ on: Bool) {
        saveOnOff("sidebar.folder-groups", on)
    }

    /// Whether bare Page Up/Down and Home/End page the terminal's scrollback:
    /// `terminal.page-keys=on|off`. On (unset, or anything but `off` — the default): the
    /// app intercepts those four keys for an attached view. Off: they pass through to the
    /// program in the session unchanged.
    public static func pageKeys() -> Bool {
        !isExactly("terminal.page-keys", "off")
    }

    /// Persists the Page Up/Down mapping explicitly both ways.
    public static func savePageKeys(_ on: Bool) {
        saveOnOff("terminal.page-keys", on)
    }

    // MARK: - sidebar view

    /// Persisted sidebar projection. Hidden keys are stored instead of visible keys so a
    /// status or harness family introduced by a future build starts visible by default.
    /// Empty hidden sets mean "show all"; a set containing every current key means "hide
    /// all" and round-trips without a sentinel value.
    public struct SidebarViewSettings: Equatable, Sendable {
        public let sort: String
        public let descending: Bool
        public let hiddenStatuses: Set<String>
        public let hiddenHarnessFamilies: Set<String>

        public init(_ sort: String, _ descending: Bool, _ hiddenStatuses: Set<String>,
                    _ hiddenHarnessFamilies: Set<String>) {
            self.sort = sort
            self.descending = descending
            self.hiddenStatuses = hiddenStatuses
            self.hiddenHarnessFamilies = hiddenHarnessFamilies
        }
    }

    public static func sidebarViewSettings() -> SidebarViewSettings {
        let properties = load()
        return SidebarViewSettings(
            JavaText.trim(properties.getProperty("sidebar.sort", "session")),
            JavaText.trim(properties.getProperty("sidebar.sort-direction", "ascending"))
                .caseInsensitiveCompare("descending") == .orderedSame,
            parseCsv(properties.getProperty("sidebar.hidden-statuses")),
            parseCsv(properties.getProperty("sidebar.hidden-harnesses")))
    }

    /// Saves the complete sidebar projection in one settings-file rewrite.
    public static func saveSidebarViewSettings(_ sort: String, _ descending: Bool,
                                               _ hiddenStatuses: Set<String>,
                                               _ hiddenHarnessFamilies: Set<String>) {
        save { p in
            p.setProperty("sidebar.sort", sort)
            p.setProperty("sidebar.sort-direction", descending ? "descending" : "ascending")
            p.setProperty("sidebar.hidden-statuses", toCsv(hiddenStatuses))
            p.setProperty("sidebar.hidden-harnesses", toCsv(hiddenHarnessFamilies))
        }
    }

    // MARK: - theme

    /// App-wide look: `ui.theme=dark|light`. Unset or unrecognized, the app follows the
    /// OS light/dark setting, and is dark where that can't be read.
    public enum UiTheme: String, CaseIterable, Sendable {
        case dark = "DARK"
        case light = "LIGHT"

        static func parse(_ value: String?) -> UiTheme? {
            guard let value else { return nil }
            let trimmed = JavaText.trim(value)
            return allCases.first { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
    }

    public static func uiTheme() -> UiTheme {
        UiTheme.parse(load().getProperty("ui.theme")) ?? SystemAppearance.detected() ?? .dark
    }

    /// Persists the theme so the next launch starts in it.
    public static func saveUiTheme(_ theme: UiTheme) {
        save { $0.setProperty("ui.theme", theme.rawValue.lowercased()) }
    }

    /// Persists the background pin; nil clears it so terminals follow the theme again.
    public static func saveTerminalBackgroundOverride(_ pin: TerminalBackground?) {
        save { p in
            if let pin {
                p.setProperty("terminal.background", pin.rawValue.lowercased())
            } else {
                p.remove("terminal.background")
            }
        }
    }

    /// Persists the scrollbar choice — written explicitly both ways, so the file documents it.
    public static func saveTerminalScrollbarHidden(_ hidden: Bool) {
        save { $0.setProperty("terminal.scrollbar", hidden ? "hidden" : "visible") }
    }

    // MARK: - status polling

    /// How often live sidebar sessions are polled for their status badge, in
    /// milliseconds: `status.poll-interval-ms`. Each tick is one daemon capture round
    /// trip per live session; clamped so hand-edited settings remain usable.
    public static func statusPollIntervalMs() -> Int {
        guard let value = load().getProperty("status.poll-interval-ms") else {
            return defaultStatusPollIntervalMs
        }
        guard let parsed = parseInt(value) else {
            return defaultStatusPollIntervalMs
        }
        return clampStatusPollIntervalMs(parsed)
    }

    public static func clampStatusPollIntervalMs(_ intervalMs: Int) -> Int {
        max(minStatusPollIntervalMs, min(maxStatusPollIntervalMs, intervalMs))
    }

    /// Persists the status poll interval, clamped so it always saves a usable value.
    public static func saveStatusPollIntervalMs(_ intervalMs: Int) {
        save { $0.setProperty("status.poll-interval-ms", String(clampStatusPollIntervalMs(intervalMs))) }
    }

    /// Whether live sidebar sessions are polled for their status badge at all:
    /// `status.poll-enabled=on|off`. On (unset, or anything but `off` — the default). Off
    /// stops the capture round trips entirely; the sidebar's working/idle/waiting badge
    /// and pane title then freeze at their last known value. Attached terminals and
    /// session-death detection are unaffected either way — neither depends on this poll
    /// loop.
    public static func statusPollingEnabled() -> Bool {
        !isExactly("status.poll-enabled", "off")
    }

    /// Persists the polling on/off choice explicitly both ways.
    public static func saveStatusPollingEnabled(_ enabled: Bool) {
        saveOnOff("status.poll-enabled", enabled)
    }

    /// How the active sidebar tab is kept fresh while `statusPollingEnabled` is off:
    /// `status.active-tab-poll-mode=off|once|scheduled`. Irrelevant (and ignored) while
    /// the periodic timer is on — every live session already gets polled every interval
    /// then.
    public enum ActiveTabPollMode: String, CaseIterable, Sendable {
        /// No extra polling; the badge only refreshes via Close/Reload's own catch-up.
        case off = "off"
        /// Default. A single catch-up poll fires the moment a live session becomes the
        /// active tab; the badge can go stale again if its state changes while still
        /// selected.
        case once = "once"
        /// The active tab alone keeps polling on the configured interval for as long as
        /// it stays selected — live, but resumes that one tab's capture round trips that
        /// turning the timer off was meant to avoid.
        case scheduled = "scheduled"

        var key: String { rawValue }

        static func parse(_ value: String?) -> ActiveTabPollMode {
            if let value {
                let trimmed = JavaText.trim(value)
                for mode in allCases where mode.key.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return mode
                }
            }
            return .once
        }
    }

    public static func activeTabPollMode() -> ActiveTabPollMode {
        ActiveTabPollMode.parse(load().getProperty("status.active-tab-poll-mode"))
    }

    /// Persists the active-tab poll mode — always written, so the file documents the default too.
    public static func saveActiveTabPollMode(_ mode: ActiveTabPollMode) {
        save { $0.setProperty("status.active-tab-poll-mode", mode.key) }
    }

    // MARK: - terminal input

    /// Whether wheel events are swallowed before they reach a Codex terminal:
    /// `codex.mouse-wheel=off|on`. Off (unset, unrecognized, or explicitly `off` — the
    /// default) prevents an accidental wheel gesture from navigating Codex. On passes
    /// wheel events to the terminal normally.
    public static func codexMouseWheelDisabled() -> Bool {
        !isExactly("codex.mouse-wheel", "on")
    }

    /// Persists whether Codex terminal wheel events are blocked.
    public static func saveCodexMouseWheelDisabled(_ disabled: Bool) {
        save { $0.setProperty("codex.mouse-wheel", disabled ? "off" : "on") }
    }

    /// macOS: whether Option+letter/digit is sent as Meta (`ESC` + key, for word motion
    /// and agent shortcuts) or composes characters as macOS does natively (é via Option+e
    /// then e, å, ©): `terminal.option-as-meta=on|off`. On unless explicitly `off`.
    public static func optionAsMeta() -> Bool {
        !isExactly("terminal.option-as-meta", "off")
    }

    /// Persists the Option-as-Meta choice explicitly both ways.
    public static func saveOptionAsMeta(_ on: Bool) {
        saveOnOff("terminal.option-as-meta", on)
    }

    // MARK: - MCP

    /// Whether the app hosts its MCP server, which lets agents running in its sessions
    /// list, read and drive other sessions: `mcp.server=on|off`. Off (unset, or anything
    /// but `on` — the default). Only sessions created or resumed while the server runs get
    /// it registered in their launch command.
    public static func mcpServerEnabled() -> Bool {
        isExactly("mcp.server", "on")
    }

    /// Persists the MCP server on/off choice explicitly both ways.
    public static func saveMcpServerEnabled(_ on: Bool) {
        saveOnOff("mcp.server", on)
    }

    /// Whether an agent that reads another session gets a plain-text log of that
    /// session's output kept in its own project folder (`.microhm-sessions/`):
    /// `mcp.session-logs=on|off`. Off (unset, or anything but `on` — the default): it
    /// copies one session's output into another's project, which only an agent that
    /// cannot read outside its project needs. Read on each use, so it applies live.
    public static func mcpSessionLogs() -> Bool {
        isExactly("mcp.session-logs", "on")
    }

    public static func saveMcpSessionLogs(_ on: Bool) {
        saveOnOff("mcp.session-logs", on)
    }

    /// Whether a menu-bar icon shows while sessions run with the app closed:
    /// `tray.icon=on|off`. On unless set to `off`.
    public static func trayIconEnabled() -> Bool {
        !isExactly("tray.icon", "off")
    }

    public static func saveTrayIconEnabled(_ on: Bool) {
        saveOnOff("tray.icon", on)
    }

    /// The shell new sessions start in: `session.shell`, empty for the user's default
    /// (see `session.SessionShell`).
    public static func sessionShell() -> String {
        load().getProperty("session.shell").map(JavaText.trim) ?? ""
    }

    public static func saveSessionShell(_ shell: String?) {
        save { $0.setProperty("session.shell", shell.map(JavaText.trim) ?? "") }
    }

    /// Whether agents start in one step inside the shell (the default) rather than being
    /// typed into it once the shell is up (`session.launch=typed`).
    public static func directLaunch() -> Bool {
        !isExactly("session.launch", "typed")
    }

    public static func saveDirectLaunch(_ direct: Bool) {
        save { $0.setProperty("session.launch", direct ? "direct" : "typed") }
    }

    /// The loopback port the MCP server binds: `mcp.port`, default `defaultMcpPort`;
    /// clamped to the unprivileged range so hand-edited settings remain usable, and
    /// unparseable values fall back to the default.
    public static func mcpPort() -> Int {
        guard let value = load().getProperty("mcp.port") else {
            return defaultMcpPort
        }
        guard let parsed = parseInt(value) else {
            return defaultMcpPort
        }
        return clampMcpPort(parsed)
    }

    public static func clampMcpPort(_ port: Int) -> Int {
        max(minMcpPort, min(maxMcpPort, port))
    }

    /// Persists the MCP port, clamped so it always saves a usable value.
    public static func saveMcpPort(_ port: Int) {
        save { $0.setProperty("mcp.port", String(clampMcpPort(port))) }
    }

    /// The token in use while the settings file could not take it; nil otherwise.
    nonisolated(unsafe) private static var unsavedMcpToken: String?

    /// The shared secret every MCP request must carry: `mcp.token`. The first call on a
    /// file without one generates a random url-safe token (32 bytes from
    /// `SecRandomCopyBytes`) and saves it, so the URL baked into a session's launch
    /// command stays valid across restarts. The check-and-generate happens inside one
    /// load-mutate-store, so two racing first calls agree on the same token. When the
    /// file cannot be written the generated token is still returned — usable for this run.
    public static func mcpToken() -> String {
        if let existing = load().getProperty("mcp.token"), !JavaText.isBlank(existing) {
            return JavaText.trim(existing)
        }
        lock.lock(); defer { lock.unlock() }
        var token: String?
        let saved = save { p in
            if let current = p.getProperty("mcp.token"), !JavaText.isBlank(current) {
                token = JavaText.trim(current)
            } else {
                let fresh = unsavedMcpToken ?? newMcpToken()
                token = fresh
                p.setProperty("mcp.token", fresh)
            }
        }
        let result = token ?? unsavedMcpToken ?? newMcpToken()
        // While the file cannot be written every caller must still get one and the same
        // token: a fresh one per call would give the server and the sessions different
        // tokens.
        unsavedMcpToken = saved ? nil : result
        return result
    }

    /// Replaces `mcp.token` with a fresh random one and returns it — returned even when
    /// the file cannot be written, so the caller can still serve this run with it.
    /// Agents launched with the old token are locked out until their session is resumed.
    @discardableResult
    public static func regenerateMcpToken() -> String {
        let token = newMcpToken()
        lock.lock(); defer { lock.unlock() }
        unsavedMcpToken = save { $0.setProperty("mcp.token", token) } ? nil : token
        return token
    }

    // MARK: - phone

    /// Whether the app serves the phone page, a web page for phones on the local network
    /// (or reaching it over a VPN) to list, watch, type into and start sessions:
    /// `phone.server=on|off`. Off unless set to `on`.
    public static func phoneServerEnabled() -> Bool {
        isExactly("phone.server", "on")
    }

    public static func savePhoneServerEnabled(_ on: Bool) {
        saveOnOff("phone.server", on)
    }

    /// The port the phone page listens on, on every interface: `phone.port`, default
    /// `defaultPhonePort`, clamped like the MCP port.
    public static func phonePort() -> Int {
        guard let value = load().getProperty("phone.port") else {
            return defaultPhonePort
        }
        guard let parsed = parseInt(value) else {
            return defaultPhonePort
        }
        return clampMcpPort(parsed)
    }

    public static func savePhonePort(_ port: Int) {
        save { $0.setProperty("phone.port", String(clampMcpPort(port))) }
    }

    /// The secret in the phone link, shared by every phone: `phone.token`, generated and
    /// saved on first use.
    public static func phoneToken() -> String {
        if let existing = load().getProperty("phone.token"), !JavaText.isBlank(existing) {
            return JavaText.trim(existing)
        }
        lock.lock(); defer { lock.unlock() }
        var token: String?
        save { p in
            if let current = p.getProperty("phone.token"), !JavaText.isBlank(current) {
                token = JavaText.trim(current)
            } else {
                token = newMcpToken()
            }
            p.setProperty("phone.token", token!)
        }
        return token ?? newMcpToken()
    }

    private static func newMcpToken() -> String {
        var bytes = [UInt8](repeating: 0, count: mcpTokenBytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - file access

    /// `<home>/settings.properties` (`MicrohmPaths.settingsFile`).
    public static func settingsFile() -> URL {
        MicrohmPaths.settingsFile
    }

    /// Load-mutate-store. Best-effort: an unwritable settings file must not break the
    /// running app — the in-memory change already took, losing persistence is the lesser
    /// harm. Rewrites the file the way `Properties.store` does, so hand-written comments
    /// in it don't survive a save. The new contents go to a temp file that atomically
    /// replaces the old one, so a crash or full disk mid-write can't leave a truncated
    /// file behind; and a file that exists but can't be read is left alone rather than
    /// rewritten from defaults, which would wipe every other setting in it.
    @discardableResult
    private static func save(_ mutation: (inout JavaProperties) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let file = settingsFile()
        do {
            var properties = try readFile(file)
            mutation(&properties)
            try AtomicFile.write(properties.store(comments: "micro-harness-manager settings"), to: file,
                                 tempPrefix: "settings-", tempSuffix: ".properties.tmp")
            return true
        } catch {
            // see method doc — logged, never thrown
            Log.warn("failed to save settings to \(file.path): \(error)", tag: "settings")
            return false
        }
    }

    private static func load() -> JavaProperties {
        let file = settingsFile()
        lock.lock(); defer { lock.unlock() }
        do {
            return try readFile(file)
        } catch {
            // unreadable settings must never keep the app from starting — use defaults
            Log.warn("failed to read settings from \(file.path) — using defaults: \(error)", tag: "settings")
            return JavaProperties()
        }
    }

    private struct UnreadableSettings: Error, CustomStringConvertible {
        let description: String
    }

    private static let malformedUnicodeEscape = JRegex(#"\\u(?![0-9a-fA-F]{4})"#)

    /// The file's properties, empty when it doesn't exist; throws when it can't be read.
    private static func readFile(_ file: URL) throws -> JavaProperties {
        guard PathCompat.isRegularFile(file) else {
            return JavaProperties()
        }
        let bytes = try Data(contentsOf: file)
        do {
            return try JavaProperties.load(bytes)
        } catch {
            // A hand-edited path can hold a backslash-u without four hex digits, which
            // Properties rejects outright. Read such a backslash as a literal one rather
            // than lose every setting (or the app's start) to it.
            let text = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
            let repaired = malformedUnicodeEscape.replaceAll(text, with: "\\\\u")
            do {
                let properties = try JavaProperties.load(chars: Array(repaired.utf16))
                Log.warn("settings file \(file.path) has a malformed \\u escape; read it as a literal backslash",
                         tag: "settings")
                return properties
            } catch {
                throw UnreadableSettings(description: "malformed settings file \(file.path)")
            }
        }
    }

    // MARK: - helpers

    /// `value != null && value.trim().equalsIgnoreCase(expected)`.
    private static func isExactly(_ key: String, _ expected: String) -> Bool {
        guard let value = load().getProperty(key) else { return false }
        return JavaText.trim(value).caseInsensitiveCompare(expected) == .orderedSame
    }

    private static func saveOnOff(_ key: String, _ on: Bool) {
        save { $0.setProperty(key, on ? "on" : "off") }
    }

    /// `Integer.parseInt(value.trim())`, nil on NumberFormatException.
    private static func parseInt(_ value: String) -> Int? {
        let t = JavaText.trim(value)
        return Int32(t).map(Int.init)
    }

    private static func parseCsv(_ value: String?) -> Set<String> {
        guard let value, !JavaText.isBlank(value) else {
            return []
        }
        var parsed = Set<String>()
        for item in JavaText.splitKeepingEmpty(value, on: ",") {
            let key = JavaText.trim(item).lowercased()
            if !key.isEmpty {
                parsed.insert(key)
            }
        }
        return parsed
    }

    private static func toCsv(_ values: Set<String>) -> String {
        values.map { JavaText.trim($0).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
    }
}
