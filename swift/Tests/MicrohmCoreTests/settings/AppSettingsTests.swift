import Foundation
import XCTest
@testable import MicrohmCore
import MicrohmShared

/// Pins the parsing of the settings keys. Settings live in the Microhm home, so pointing
/// `MicrohmPaths.homeOverride` at a temp dir isolates each test from the developer's
/// real settings.
final class AppSettingsTests: XCTestCase {

    private var dir: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
        previousOverride = MicrohmPaths.homeOverride
        MicrohmPaths.homeOverride = dir
    }

    override func tearDown() {
        MicrohmPaths.homeOverride = previousOverride
    }

    private func settings(_ content: String) throws {
        try writeString(dir.appendingPathComponent("settings.properties"), content)
    }

    func testConcurrentSavesOfDifferentKeysNeitherLoseAChangeNorLeaveTempFiles() throws {
        for round in 0..<50 {
            try settings("")
            let on = round % 2 == 0
            let group = DispatchGroup()
            for task in [{ AppSettings.saveToolbarLabels(on) }, { AppSettings.saveToolbarPageButtons(on) }] {
                group.enter()
                Thread {
                    task()
                    group.leave()
                }.start()
            }
            group.wait()
            XCTAssertEqual(on, AppSettings.toolbarLabels(), "round \(round)")
            XCTAssertEqual(on, AppSettings.toolbarPageButtons(), "round \(round)")
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(siblings.contains { $0.hasSuffix(".tmp") })
    }

    func testScrollbarDefaultsToVisible() throws {
        XCTAssertFalse(AppSettings.terminalScrollbarHidden()) // no file at all
        try settings("")
        XCTAssertFalse(AppSettings.terminalScrollbarHidden())
        try settings("terminal.scrollbar=visible\n")
        XCTAssertFalse(AppSettings.terminalScrollbarHidden())
        try settings("terminal.scrollbar=nonsense\n")
        XCTAssertFalse(AppSettings.terminalScrollbarHidden())
    }

    func testScrollbarHiddenIsRecognizedCaseInsensitively() throws {
        try settings("terminal.scrollbar=hidden\n")
        XCTAssertTrue(AppSettings.terminalScrollbarHidden())
        try settings("terminal.scrollbar= HIDDEN \n")
        XCTAssertTrue(AppSettings.terminalScrollbarHidden())
    }

    func testOptionAsMetaIsOnUnlessExplicitlyOff() throws {
        XCTAssertTrue(AppSettings.optionAsMeta()) // no file at all
        try settings("terminal.option-as-meta=nonsense\n")
        XCTAssertTrue(AppSettings.optionAsMeta())
        try settings("terminal.option-as-meta= OFF \n")
        XCTAssertFalse(AppSettings.optionAsMeta())
        AppSettings.saveOptionAsMeta(true)
        XCTAssertTrue(AppSettings.optionAsMeta())
        AppSettings.saveOptionAsMeta(false)
        XCTAssertFalse(AppSettings.optionAsMeta())
    }

    func testCodexMouseWheelDefaultsToDisabledAndOnlyOnEnables() throws {
        XCTAssertTrue(AppSettings.codexMouseWheelDisabled()) // no file at all
        try settings("")
        XCTAssertTrue(AppSettings.codexMouseWheelDisabled())
        try settings("codex.mouse-wheel=nonsense\n")
        XCTAssertTrue(AppSettings.codexMouseWheelDisabled())
        try settings("codex.mouse-wheel= ON \n")
        XCTAssertFalse(AppSettings.codexMouseWheelDisabled())
        try settings("codex.mouse-wheel=off\n")
        XCTAssertTrue(AppSettings.codexMouseWheelDisabled())
    }

    func testPaletteDefaultsToMacosTerminal() throws {
        XCTAssertEqual(AppSettings.TerminalPalette.macosTerminal, AppSettings.terminalPalette()) // no file
        try settings("")
        XCTAssertEqual(AppSettings.TerminalPalette.macosTerminal, AppSettings.terminalPalette())
        try settings("terminal.palette=nonsense\n")
        XCTAssertEqual(AppSettings.TerminalPalette.macosTerminal, AppSettings.terminalPalette())
    }

    func testPaletteParsesEachChoiceCaseInsensitively() throws {
        try settings("terminal.palette=macos\n")
        XCTAssertEqual(AppSettings.TerminalPalette.macosTerminal, AppSettings.terminalPalette())
        try settings("terminal.palette= ITERM2 \n")
        XCTAssertEqual(AppSettings.TerminalPalette.iterm2, AppSettings.terminalPalette())
        try settings("terminal.palette=xterm\n")
        XCTAssertEqual(AppSettings.TerminalPalette.xterm, AppSettings.terminalPalette())
        try settings("terminal.palette=jediterm\n") // the pre-rename value still loads
        XCTAssertEqual(AppSettings.TerminalPalette.xterm, AppSettings.terminalPalette())
    }

    func testTerminalFontDefaultsAndParsingAreBounded() throws {
        XCTAssertEqual(14, AppSettings.terminalFontSize())
        try settings("terminal.font-family= JetBrains Mono \nterminal.font-size=20\n")
        XCTAssertEqual("JetBrains Mono", AppSettings.terminalFontFamily())
        XCTAssertEqual(20, AppSettings.terminalFontSize())

        try settings("terminal.font-family=  \nterminal.font-size=999\n")
        XCTAssertFalse(JavaText.isBlank(AppSettings.terminalFontFamily()))
        XCTAssertEqual(AppSettings.maxTerminalFontSize, AppSettings.terminalFontSize())

        try settings("terminal.font-size=not-a-number\n")
        XCTAssertEqual(AppSettings.defaultTerminalFontSize, AppSettings.terminalFontSize())
    }

    func testPageKeysDefaultToOnAndOnlyOffDisables() throws {
        XCTAssertTrue(AppSettings.pageKeys()) // no file at all
        try settings("")
        XCTAssertTrue(AppSettings.pageKeys())
        try settings("terminal.page-keys=nonsense\n")
        XCTAssertTrue(AppSettings.pageKeys())
        try settings("terminal.page-keys= OFF \n")
        XCTAssertFalse(AppSettings.pageKeys())
        try settings("terminal.page-keys=on\n")
        XCTAssertTrue(AppSettings.pageKeys())
    }

    func testToolbarPageButtonsDefaultToOffAndOnlyOnEnables() throws {
        XCTAssertFalse(AppSettings.toolbarPageButtons()) // no file at all
        try settings("")
        XCTAssertFalse(AppSettings.toolbarPageButtons())
        try settings("toolbar.page-buttons=nonsense\n")
        XCTAssertFalse(AppSettings.toolbarPageButtons())
        try settings("toolbar.page-buttons= ON \n")
        XCTAssertTrue(AppSettings.toolbarPageButtons())
        try settings("toolbar.page-buttons=off\n")
        XCTAssertFalse(AppSettings.toolbarPageButtons())
    }

    func testToolbarStopLadderDefaultsToOffAndOnlyOnEnablesIt() throws {
        XCTAssertFalse(AppSettings.toolbarStopLadder()) // no file at all
        try settings("")
        XCTAssertFalse(AppSettings.toolbarStopLadder())
        try settings("toolbar.stop-ladder=nonsense\n")
        XCTAssertFalse(AppSettings.toolbarStopLadder())
        try settings("toolbar.stop-ladder= ON \n")
        XCTAssertTrue(AppSettings.toolbarStopLadder())
        try settings("toolbar.stop-ladder=off\n")
        XCTAssertFalse(AppSettings.toolbarStopLadder())
    }

    func testSidebarFocusBorderDefaultsToHiddenAndOnlyVisibleEnablesIt() throws {
        XCTAssertTrue(AppSettings.sidebarFocusBorderHidden()) // no file at all
        try settings("")
        XCTAssertTrue(AppSettings.sidebarFocusBorderHidden())
        try settings("sidebar.focus-border=nonsense\n")
        XCTAssertTrue(AppSettings.sidebarFocusBorderHidden())
        try settings("sidebar.focus-border= VISIBLE \n")
        XCTAssertFalse(AppSettings.sidebarFocusBorderHidden())
        try settings("sidebar.focus-border=hidden\n")
        XCTAssertTrue(AppSettings.sidebarFocusBorderHidden())
    }

    func testSidebarReticuleDefaultsToOffAndOnlyOnEnablesIt() throws {
        XCTAssertFalse(AppSettings.sidebarReticule()) // no file at all
        try settings("")
        XCTAssertFalse(AppSettings.sidebarReticule())
        try settings("sidebar.reticule=nonsense\n")
        XCTAssertFalse(AppSettings.sidebarReticule())
        try settings("sidebar.reticule= ON \n")
        XCTAssertTrue(AppSettings.sidebarReticule())
        try settings("sidebar.reticule=off\n")
        XCTAssertFalse(AppSettings.sidebarReticule())
    }

    func testSidebarFolderGroupsDefaultToOnAndOnlyOffDisablesThem() throws {
        XCTAssertTrue(AppSettings.sidebarFolderGroups()) // no file at all
        try settings("")
        XCTAssertTrue(AppSettings.sidebarFolderGroups())
        try settings("sidebar.folder-groups=nonsense\n")
        XCTAssertTrue(AppSettings.sidebarFolderGroups())
        try settings("sidebar.folder-groups= OFF \n")
        XCTAssertFalse(AppSettings.sidebarFolderGroups())
        try settings("sidebar.folder-groups=on\n")
        XCTAssertTrue(AppSettings.sidebarFolderGroups())
    }

    func testSidebarViewDefaultsToSessionSortWithNothingHidden() throws {
        let defaults = AppSettings.sidebarViewSettings()
        XCTAssertEqual("session", defaults.sort)
        XCTAssertFalse(defaults.descending)
        XCTAssertEqual(Set<String>(), defaults.hiddenStatuses)
        XCTAssertEqual(Set<String>(), defaults.hiddenHarnessFamilies)

        try settings("sidebar.sort= folder \n"
                + "sidebar.sort-direction= descending \n"
                + "sidebar.hidden-statuses= working, dead,working \n"
                + "sidebar.hidden-harnesses= CODEX, shell \n")
        let configured = AppSettings.sidebarViewSettings()
        XCTAssertEqual("folder", configured.sort)
        XCTAssertTrue(configured.descending)
        XCTAssertEqual(Set(["working", "dead"]), configured.hiddenStatuses)
        XCTAssertEqual(Set(["codex", "shell"]), configured.hiddenHarnessFamilies)
    }

    func testSavesRoundTripAndEmptyPinsClearTheirKeys() throws {
        AppSettings.saveTerminalScrollbarHidden(true)
        AppSettings.saveCodexMouseWheelDisabled(false)
        AppSettings.saveTerminalBackgroundOverride(Optional(AppSettings.TerminalBackground.white))
        AppSettings.saveTerminalPalette(AppSettings.TerminalPalette.iterm2)
        AppSettings.savePageKeys(false)
        AppSettings.saveToolbarPageButtons(true)
        AppSettings.saveToolbarStopLadder(true)
        AppSettings.saveSidebarFocusBorderHidden(false)
        AppSettings.saveSidebarReticule(true)
        AppSettings.saveSidebarFolderGroups(false)
        AppSettings.saveTerminalFont("JetBrains Mono", 18)
        AppSettings.saveSidebarViewSettings("status", true, Set(["idle", "working"]),
                Set(["claude", "codex"]))
        XCTAssertEqual(AppSettings.TerminalPalette.iterm2, AppSettings.terminalPalette())
        XCTAssertFalse(AppSettings.pageKeys())
        XCTAssertTrue(AppSettings.toolbarPageButtons())
        XCTAssertTrue(AppSettings.toolbarStopLadder())
        XCTAssertFalse(AppSettings.sidebarFocusBorderHidden())
        XCTAssertTrue(AppSettings.sidebarReticule())
        XCTAssertFalse(AppSettings.sidebarFolderGroups())
        XCTAssertEqual("JetBrains Mono", AppSettings.terminalFontFamily())
        XCTAssertEqual(18, AppSettings.terminalFontSize())
        XCTAssertEqual(AppSettings.SidebarViewSettings(
                        "status", true, Set(["idle", "working"]), Set(["claude", "codex"])),
                AppSettings.sidebarViewSettings())
        XCTAssertTrue(AppSettings.terminalScrollbarHidden())
        XCTAssertFalse(AppSettings.codexMouseWheelDisabled())
        XCTAssertEqual(Optional(AppSettings.TerminalBackground.white),
                AppSettings.terminalBackgroundOverride())

        AppSettings.saveCodexMouseWheelDisabled(true)
        AppSettings.saveTerminalBackgroundOverride(nil)
        AppSettings.savePageKeys(true)
        AppSettings.saveToolbarPageButtons(false)
        AppSettings.saveToolbarStopLadder(false)
        AppSettings.saveSidebarFocusBorderHidden(true)
        AppSettings.saveSidebarReticule(false)
        AppSettings.saveSidebarFolderGroups(true)
        XCTAssertTrue(AppSettings.codexMouseWheelDisabled())
        XCTAssertNil(AppSettings.terminalBackgroundOverride())
        XCTAssertTrue(AppSettings.pageKeys())
        XCTAssertFalse(AppSettings.toolbarPageButtons())
        XCTAssertFalse(AppSettings.toolbarStopLadder())
        XCTAssertTrue(AppSettings.sidebarFocusBorderHidden())
        XCTAssertFalse(AppSettings.sidebarReticule())
        XCTAssertTrue(AppSettings.sidebarFolderGroups())
        // load-mutate-store: clearing the pins must not have dropped the scrollbar choice
        XCTAssertTrue(AppSettings.terminalScrollbarHidden())
    }

    func testUiThemeParsesExplicitChoicesAndLeavesTheRestToTheSystem() throws {
        XCTAssertEqual(Optional(AppSettings.UiTheme.light), AppSettings.UiTheme.parse(" Light "))
        XCTAssertEqual(Optional(AppSettings.UiTheme.dark), AppSettings.UiTheme.parse("dark"))
        XCTAssertNil(AppSettings.UiTheme.parse(nil))
        XCTAssertNil(AppSettings.UiTheme.parse("system"))
        try settings("ui.theme=dark\n")
        XCTAssertEqual(AppSettings.UiTheme.dark, AppSettings.uiTheme())
    }

    func testSidebarBackgroundDefaultsToThemeBlackWhite() throws {
        XCTAssertEqual(AppSettings.SidebarBackground.terminal, AppSettings.sidebarBackground())
        try settings("sidebar.background=nonsense\n")
        XCTAssertEqual(AppSettings.SidebarBackground.terminal, AppSettings.sidebarBackground())
        try settings("sidebar.background=default\n")
        XCTAssertEqual(AppSettings.SidebarBackground.`default`, AppSettings.sidebarBackground())
        try settings("sidebar.background=ui-gray\n")
        XCTAssertEqual(AppSettings.SidebarBackground.uiGray, AppSettings.sidebarBackground())
    }

    func testSidebarMatchesDefaultOnAndOnlyOffUnlinks() throws {
        XCTAssertTrue(AppSettings.rightPaneMatchesSidebar())
        XCTAssertTrue(AppSettings.toolbarMatchesSidebar())
        XCTAssertTrue(AppSettings.sidebarSectionsMatchBackground())
        try settings("right-pane.match-sidebar=off\ntoolbar.match-sidebar=off\n")
        XCTAssertFalse(AppSettings.rightPaneMatchesSidebar())
        XCTAssertFalse(AppSettings.toolbarMatchesSidebar())
        AppSettings.saveRightPaneMatchesSidebar(true)
        XCTAssertTrue(AppSettings.rightPaneMatchesSidebar())
    }

    func testSavingOneKeyPreservesHandWrittenOthers() throws {
        try settings("ui.theme=light\ntoolbar.labels=off\n")
        AppSettings.saveTerminalScrollbarHidden(true)
        XCTAssertEqual(AppSettings.UiTheme.light, AppSettings.uiTheme())
        XCTAssertFalse(AppSettings.toolbarLabels())
        XCTAssertTrue(AppSettings.terminalScrollbarHidden())
    }

    func testSessionLogsDefaultToOffAndAreSavedBothWays() throws {
        XCTAssertFalse(AppSettings.mcpSessionLogs()) // no file at all
        AppSettings.saveMcpSessionLogs(true)
        XCTAssertTrue(AppSettings.mcpSessionLogs())
        AppSettings.saveMcpSessionLogs(false)
        XCTAssertFalse(AppSettings.mcpSessionLogs())
    }

    func testMcpServerDefaultsToOffAndOnlyOnEnablesIt() throws {
        XCTAssertFalse(AppSettings.mcpServerEnabled()) // no file at all
        try settings("")
        XCTAssertFalse(AppSettings.mcpServerEnabled())
        try settings("mcp.server=nonsense\n")
        XCTAssertFalse(AppSettings.mcpServerEnabled())
        try settings("mcp.server= ON \n")
        XCTAssertTrue(AppSettings.mcpServerEnabled())
        try settings("mcp.server=off\n")
        XCTAssertFalse(AppSettings.mcpServerEnabled())
        AppSettings.saveMcpServerEnabled(true)
        XCTAssertTrue(AppSettings.mcpServerEnabled())
        AppSettings.saveMcpServerEnabled(false)
        XCTAssertFalse(AppSettings.mcpServerEnabled())
    }

    func testMcpPortDefaultsAndIsClampedToTheUnprivilegedRange() throws {
        XCTAssertEqual(AppSettings.defaultMcpPort, AppSettings.mcpPort()) // no file at all
        XCTAssertEqual(7402, AppSettings.defaultMcpPort)
        try settings("mcp.port= 8123 \n")
        XCTAssertEqual(8123, AppSettings.mcpPort())
        try settings("mcp.port=80\n")
        XCTAssertEqual(AppSettings.minMcpPort, AppSettings.mcpPort())
        try settings("mcp.port=700000\n")
        XCTAssertEqual(AppSettings.maxMcpPort, AppSettings.mcpPort())
        try settings("mcp.port=not-a-port\n")
        XCTAssertEqual(AppSettings.defaultMcpPort, AppSettings.mcpPort())
        AppSettings.saveMcpPort(1)
        XCTAssertEqual(AppSettings.minMcpPort, AppSettings.mcpPort())
        AppSettings.saveMcpPort(9000)
        XCTAssertEqual(9000, AppSettings.mcpPort())
    }

    func testMcpTokenIsGeneratedOnceThenStable() throws {
        let tokenShape = JRegex("[A-Za-z0-9_-]{43}")
        let first = AppSettings.mcpToken() // no file at all: generated and saved
        XCTAssertTrue(tokenShape.matches(first), first)
        XCTAssertEqual(first, AppSettings.mcpToken())
        XCTAssertTrue(try readString(dir.appendingPathComponent("settings.properties")).contains(first))

        try settings("mcp.token= hand-written \n")
        XCTAssertEqual("hand-written", AppSettings.mcpToken())

        try settings("mcp.token=  \n")
        let regenerated = AppSettings.mcpToken()
        XCTAssertTrue(tokenShape.matches(regenerated), regenerated)
        XCTAssertNotEqual(regenerated, first, "a fresh random token")
    }

    /// A hand-edited Windows path holds a backslash-u that is no unicode escape:
    /// Properties rejects the whole file for it, which used to stop the app starting.
    func testAMalformedUnicodeEscapeDoesNotLoseTheSettings() throws {
        try settings("mcp.port=9100\nsession.shell=C:\\users\\me\\pwsh.exe\n")
        XCTAssertEqual(9100, AppSettings.mcpPort())
        AppSettings.saveMcpPort(9200)
        XCTAssertEqual(9200, AppSettings.mcpPort(), "and the file can still be saved")
    }

    func testTheMcpTokenIsStableWhileTheSettingsFileCannotBeWritten() throws {
        // the settings file's place is taken by a folder: nothing can be saved there
        try createDirectories(dir.appendingPathComponent("settings.properties").appendingPathComponent("x"))
        let first = AppSettings.mcpToken()
        XCTAssertEqual(first, AppSettings.mcpToken())
    }

    func testRegeneratingTheMcpTokenReplacesAndPersistsIt() {
        let first = AppSettings.mcpToken()
        AppSettings.saveMcpPort(9000)
        let second = AppSettings.regenerateMcpToken()
        XCTAssertTrue(JRegex("[A-Za-z0-9_-]{43}").matches(second), second)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, AppSettings.mcpToken())
        XCTAssertEqual(9000, AppSettings.mcpPort(), "other settings survive")
    }

    func testRacingFirstMcpTokenCallsAgreeOnOneToken() throws {
        for round in 0..<20 {
            try settings("")
            final class Seen: @unchecked Sendable { var tokens = [String?](repeating: nil, count: 2) }
            let seen = Seen()
            let group = DispatchGroup()
            for i in 0..<2 {
                group.enter()
                Thread {
                    seen.tokens[i] = AppSettings.mcpToken()
                    group.leave()
                }.start()
            }
            group.wait()
            XCTAssertEqual(seen.tokens[0], seen.tokens[1], "round \(round)")
            XCTAssertEqual(seen.tokens[0], AppSettings.mcpToken(), "round \(round)")
        }
    }

    /// The Java Properties format, both ways: escapes, separators, continuations, comments.
    func testPropertiesFormatMatchesJava() throws {
        let loaded = try JavaProperties.load(Data("""
            # comment
            ! also a comment
              spaced.key   =  value with spaces  
            colon:separated
            ws separated
            multi=one \\
                two
            escaped\\=key=a\\tb\\u00e9
            empty=

            """.utf8))
        XCTAssertEqual("value with spaces  ", loaded["spaced.key"])
        XCTAssertEqual("separated", loaded["colon"])
        XCTAssertEqual("separated", loaded["ws"])
        XCTAssertEqual("one two", loaded["multi"])
        XCTAssertEqual("a\tb\u{e9}", loaded["escaped=key"])
        XCTAssertEqual("", loaded["empty"])
        XCTAssertThrowsError(try JavaProperties.load(Data("k=C:\\users".utf8)))

        var props = JavaProperties()
        props.setProperty("a key", " lead=x:y#\u{e9}")
        let stored = String(decoding: props.store(comments: "c"), as: UTF8.self)
        let lines = stored.split(separator: "\n").map(String.init)
        XCTAssertEqual("#c", lines[0])
        XCTAssertTrue(lines[1].hasPrefix("#"))
        XCTAssertEqual("a\\ key=\\ lead\\=x\\:y\\#\\u00E9", lines[2])
        XCTAssertEqual(props, try JavaProperties.load(props.store(comments: "c")))
    }
}
