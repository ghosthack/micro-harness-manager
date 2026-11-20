import Foundation
import MicrohmCore

/// The Settings window's choices on Save (Java's `SettingsDialog.Result`). The window
/// never touches disk or a session itself: `AppDelegate` persists this and the main
/// window applies it.
struct SettingsResult {
    var backgroundOverride: AppSettings.TerminalBackground?
    var palette: AppSettings.TerminalPalette
    var scrollbarHidden: Bool
    var codexMouseWheelDisabled: Bool
    var optionAsMeta: Bool
    var pageKeys: Bool
    var toolbarLabels: Bool
    var toolbarPageButtons: Bool
    var toolbarStopLadder: Bool
    var toolbarBatchActions: Bool
    var sidebarBackground: AppSettings.SidebarBackground
    var rightPaneMatchesSidebar: Bool
    var sidebarReticule: Bool
    var sidebarFolderGroups: Bool
    var fontFamily: String
    var fontSize: Int
    var statusPollingEnabled: Bool
    var statusPollIntervalMs: Int
    var activeTabPollMode: AppSettings.ActiveTabPollMode
    var mcpServerEnabled: Bool
    var mcpPort: Int
    var mcpTokenRegenerated: Bool
    var mcpChanged: Bool
    var trayIcon: Bool
    var sessionShell: String
    var directLaunch: Bool
    var mcpSessionLogs: Bool
    var phoneServerEnabled: Bool
    var phonePort: Int

    /// Whether Save must re-apply the MCP server: switched on or off, a new port while it
    /// stays on, or a regenerated token (the running server must restart with it).
    static func mcpChanged(wasEnabled: Bool, wasPort: Int, enabled: Bool, port: Int, tokenRegenerated: Bool) -> Bool {
        enabled != wasEnabled || (enabled && port != wasPort) || tokenRegenerated
    }

    /// Whether a Save applies the MCP server: an MCP change, or the server is meant to be
    /// on but is not running (a bind that failed earlier is retried by any Save).
    static func mcpNeedsApply(_ mcpChanged: Bool, enabled: Bool, running: Bool) -> Bool {
        mcpChanged || (enabled && !running)
    }

    /// Writes every choice, the way Java's Save does (one settings rewrite per key). Runs
    /// on the settings queue, never the main thread.
    func persist() {
        AppSettings.saveTerminalBackgroundOverride(backgroundOverride)
        AppSettings.saveTerminalPalette(palette)
        AppSettings.saveTerminalScrollbarHidden(scrollbarHidden)
        AppSettings.saveCodexMouseWheelDisabled(codexMouseWheelDisabled)
        AppSettings.saveOptionAsMeta(optionAsMeta)
        AppSettings.savePageKeys(pageKeys)
        AppSettings.saveToolbarLabels(toolbarLabels)
        AppSettings.saveToolbarPageButtons(toolbarPageButtons)
        AppSettings.saveToolbarStopLadder(toolbarStopLadder)
        AppSettings.saveToolbarBatchActions(toolbarBatchActions)
        AppSettings.saveSidebarBackground(sidebarBackground)
        AppSettings.saveRightPaneMatchesSidebar(rightPaneMatchesSidebar)
        AppSettings.saveSidebarReticule(sidebarReticule)
        AppSettings.saveSidebarFolderGroups(sidebarFolderGroups)
        AppSettings.saveTerminalFont(fontFamily, fontSize)
        AppSettings.saveStatusPollIntervalMs(statusPollIntervalMs)
        AppSettings.saveStatusPollingEnabled(statusPollingEnabled)
        AppSettings.saveActiveTabPollMode(activeTabPollMode)
        AppSettings.saveMcpServerEnabled(mcpServerEnabled)
        AppSettings.saveMcpPort(mcpPort)
        AppSettings.saveMcpSessionLogs(mcpSessionLogs)
        AppSettings.saveTrayIconEnabled(trayIcon)
        AppSettings.saveSessionShell(sessionShell)
        AppSettings.saveDirectLaunch(directLaunch)
        AppSettings.savePhoneServerEnabled(phoneServerEnabled)
        AppSettings.savePhonePort(phonePort)
    }
}
