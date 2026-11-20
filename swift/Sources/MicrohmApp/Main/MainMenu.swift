import AppKit
import MicrohmCore

/// The menu bar, and the sidebar's sort, filter and context menus. Session items use
/// nil-targeted actions, so they reach the main window controller through the responder
/// chain and validate against its current selection.
enum MainMenu {

    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let name = AppModel.appName

        // App
        let app = submenu(main, name)
        app.addItem(withTitle: "About \(name)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
            .target = appDelegate
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
            .target = appDelegate
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                    keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, "File")
        add(file, "New Session…", #selector(MainWindowController.newSession(_:)), "n")
        add(file, "New Session Here…", #selector(MainWindowController.newSessionHere(_:)), "n", [.command, .shift])
        add(file, "New Shell Here", #selector(MainWindowController.newShellHere(_:)), "t")
        add(file, "Duplicate Session", #selector(MainWindowController.duplicateSession(_:)), "d")
        file.addItem(.separator())
        add(file, "Close Session…", #selector(MainWindowController.closeSession(_:)), "w")
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .option])

        // Edit — the terminal answers copy:, paste: and selectAll: itself
        let edit = submenu(main, "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        // Session
        let session = submenu(main, "Session")
        add(session, "Rename…", #selector(MainWindowController.renameSession(_:)), "")
        add(session, "Copy Path", #selector(MainWindowController.copySessionPath(_:)), "c", [.command, .option])
        add(session, "Show in Finder", #selector(MainWindowController.revealSessionFolder(_:)), "r", [.command, .shift])
        session.addItem(.separator())
        add(session, "Detach", #selector(MainWindowController.detachSession(_:)), "")
        add(session, "Close…", #selector(MainWindowController.closeSession(_:)), "")
        add(session, "Reload…", #selector(MainWindowController.reloadSession(_:)), "r", [.command, .option])
        add(session, "Kill…", #selector(MainWindowController.killSession(_:)), "")
        session.addItem(.separator())
        add(session, "Resume…", #selector(MainWindowController.resumeSession(_:)), "")
        add(session, "Remove from Registry", #selector(MainWindowController.removeFromRegistry(_:)), "\u{8}")
        session.addItem(.separator())
        add(session, "Close All Sessions…", #selector(MainWindowController.closeAllSessions(_:)), "")
        add(session, "Batch Close…", #selector(MainWindowController.batchCloseSessions(_:)), "")
        add(session, "Remove Dead Sessions…", #selector(MainWindowController.removeDeadSessions(_:)), "")
        session.addItem(.separator())
        add(session, "Usage & Limits", #selector(MainWindowController.showUsage(_:)), "u", [.command, .shift])
        add(session, "Refresh", #selector(MainWindowController.refreshSessions(_:)), "r")

        // View
        let view = submenu(main, "View")
        add(view, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        add(view, "Go to Session List", #selector(MainWindowController.focusSidebar(_:)), "l", [.command, .shift])
        view.addItem(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sort.submenu = sortMenu(nil)
        view.addItem(sort)
        let filter = NSMenuItem(title: "Show Statuses", action: nil, keyEquivalent: "")
        filter.submenu = statusFilterMenu(nil)
        view.addItem(filter)
        let harness = NSMenuItem(title: "Show Harnesses", action: nil, keyEquivalent: "")
        harness.submenu = harnessFilterMenu(nil)
        view.addItem(harness)
        add(view, "Group by Folder", #selector(MainWindowController.toggleFolderGroups(_:)), "")
        view.addItem(.separator())
        add(view, "Use Light Appearance", #selector(MainWindowController.toggleAppearance(_:)), "")
        view.addItem(.separator())
        add(view, "Bigger", #selector(MainWindowController.terminalZoomIn(_:)), "=")
        let plus = add(view, "Bigger", #selector(MainWindowController.terminalZoomIn(_:)), "+")
        plus.isAlternate = true
        plus.isHidden = true
        add(view, "Smaller", #selector(MainWindowController.terminalZoomOut(_:)), "-")
        add(view, "Default Size", #selector(MainWindowController.terminalZoomReset(_:)), "0")
        view.addItem(.separator())
        add(view, "Scroll Page Up", #selector(MainWindowController.scrollSessionPageUp(_:)), "\u{F72C}", [.command])
        add(view, "Scroll Page Down", #selector(MainWindowController.scrollSessionPageDown(_:)), "\u{F72D}", [.command])
        add(view, "Scroll to Top", #selector(MainWindowController.scrollSessionToTop(_:)), "\u{F729}", [.command])
        add(view, "Scroll to Bottom", #selector(MainWindowController.scrollSessionToBottom(_:)), "\u{F72B}", [.command])
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Window
        let window = submenu(main, "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        add(window, "Show Next Session", #selector(MainWindowController.selectNextSession(_:)), "\t", [.control])
        add(window, "Show Previous Session", #selector(MainWindowController.selectPreviousSession(_:)), "\t",
            [.control, .shift])
        for n in 1...9 {
            let item = add(window, n == 9 ? "Show Last Session" : "Show Session \(n)",
                           #selector(MainWindowController.selectSessionNumber(_:)), String(n), [.control])
            item.tag = n
        }
        window.addItem(.separator())
        add(window, "Main Window", #selector(AppDelegate.showMainWindow(_:)), "0", [.command, .option]).target = appDelegate
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window

        // Help
        let help = submenu(main, "Help")
        add(help, "\(name) on GitHub", #selector(AppDelegate.openProjectPage(_:)), "").target = appDelegate
        add(help, "Show Log File", #selector(AppDelegate.revealLog(_:)), "").target = appDelegate
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                            _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        menu.addItem(item)
        return item
    }

    // MARK: - sidebar menus

    static func sortMenu(_ target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: "Sort By")
        for mode in SidebarView.SortMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(MainWindowController.sortBy(_:)), keyEquivalent: "")
            item.representedObject = mode.key
            item.target = target
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let descending = NSMenuItem(title: "Descending", action: #selector(MainWindowController.toggleSortDescending(_:)),
                                    keyEquivalent: "")
        descending.target = target
        menu.addItem(descending)
        if target != nil {
            menu.addItem(.separator())
            let group = NSMenuItem(title: "Group by Folder", action: #selector(MainWindowController.toggleFolderGroups(_:)),
                                   keyEquivalent: "")
            group.target = target
            group.toolTip = "Applies while sorting by folder."
            menu.addItem(group)
        }
        return menu
    }

    static func statusFilterMenu(_ target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: "Show Statuses")
        for status in SidebarView.FilterStatus.allCases {
            let item = NSMenuItem(title: status.label, action: #selector(MainWindowController.toggleStatusFilter(_:)),
                                  keyEquivalent: "")
            item.tag = status.rawValue
            item.target = target
            item.image = statusDot(status)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let showAll = NSMenuItem(title: "Show All Statuses", action: #selector(MainWindowController.showAllStatuses(_:)),
                                 keyEquivalent: "")
        showAll.target = target
        menu.addItem(showAll)
        let hideAll = NSMenuItem(title: "Hide All Statuses", action: #selector(MainWindowController.hideAllStatuses(_:)),
                                 keyEquivalent: "")
        hideAll.target = target
        menu.addItem(hideAll)
        return menu
    }

    static func harnessFilterMenu(_ target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: "Show Harnesses")
        for (index, family) in SidebarView.HarnessFamily.allCases.enumerated() {
            let item = NSMenuItem(title: family.label, action: #selector(MainWindowController.toggleHarnessFilter(_:)),
                                  keyEquivalent: "")
            item.tag = index
            item.target = target
            item.image = HarnessIcons.image(family.harnessType, size: 14)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let showAll = NSMenuItem(title: "Show All Harnesses", action: #selector(MainWindowController.showAllHarnesses(_:)),
                                 keyEquivalent: "")
        showAll.target = target
        menu.addItem(showAll)
        let hideAll = NSMenuItem(title: "Hide All Harnesses", action: #selector(MainWindowController.hideAllHarnesses(_:)),
                                 keyEquivalent: "")
        hideAll.target = target
        menu.addItem(hideAll)
        return menu
    }

    private static func statusDot(_ status: SidebarView.FilterStatus) -> NSImage {
        let color: NSColor
        switch status {
        case .working: color = StatusColors.working
        case .waitingForInput: color = StatusColors.waiting
        case .idle, .dead: color = StatusColors.idle
        case .statusPending: color = .clear
        }
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            dot.fill()
            if status == .statusPending || status == .dead {
                StatusColors.idle.setStroke()
                dot.lineWidth = 1.2
                dot.stroke()
            }
            return true
        }
    }

    /// The row's context menu: rename, the stop ladder (gentlest first) or resume/remove,
    /// then the "here" actions. Items carry the row's session name, so they act on the
    /// clicked row.
    static func contextMenu(for entry: SidebarEntry, attached: Bool) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = entry.sessionName
            if let symbol { item.image = HarnessIcons.symbol(symbol, nil) }
            menu.addItem(item)
        }
        add("Rename…", #selector(MainWindowController.renameSession(_:)), "pencil")
        menu.addItem(.separator())
        switch entry.status {
        case .live:
            add("Detach", #selector(MainWindowController.detachSession(_:)), "eject")
            add("Close…", #selector(MainWindowController.closeSession(_:)), "xmark.circle")
            add("Reload…", #selector(MainWindowController.reloadSession(_:)), "arrow.clockwise")
            add("Kill…", #selector(MainWindowController.killSession(_:)), "bolt.circle")
        case .dead:
            add("Resume…", #selector(MainWindowController.resumeSession(_:)), "play.circle")
            add("Remove from Registry", #selector(MainWindowController.removeFromRegistry(_:)), "trash")
        }
        menu.addItem(.separator())
        add("New Session Here…", #selector(MainWindowController.newSessionHere(_:)), "folder.badge.plus")
        add("New Shell Here", #selector(MainWindowController.newShellHere(_:)), "apple.terminal")
        add("Duplicate", #selector(MainWindowController.duplicateSession(_:)), "plus.square.on.square")
        menu.addItem(.separator())
        add("Copy Path", #selector(MainWindowController.copySessionPath(_:)), "doc.on.doc")
        add("Show in Finder", #selector(MainWindowController.revealSessionFolder(_:)), "folder")
        return menu
    }
}
