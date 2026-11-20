import AppKit
import MicrohmCore

/// The window's unified toolbar (Java's control row): the sidebar toggle, the create
/// actions, the optional paging, stop-ladder and batch groups, and on the trailing side
/// usage, settings and the light/dark switch. Settings → Toolbar picks labels and groups;
/// a change rebuilds the toolbar.
final class MainToolbar: NSObject, NSToolbarDelegate {

    private enum Item {
        static let newSession = NSToolbarItem.Identifier("microhm.new")
        static let newHere = NSToolbarItem.Identifier("microhm.newHere")
        static let shellHere = NSToolbarItem.Identifier("microhm.shellHere")
        static let duplicate = NSToolbarItem.Identifier("microhm.duplicate")
        static let pageUp = NSToolbarItem.Identifier("microhm.pageUp")
        static let pageDown = NSToolbarItem.Identifier("microhm.pageDown")
        static let detach = NSToolbarItem.Identifier("microhm.detach")
        static let close = NSToolbarItem.Identifier("microhm.close")
        static let kill = NSToolbarItem.Identifier("microhm.kill")
        static let closeAll = NSToolbarItem.Identifier("microhm.closeAll")
        static let batchClose = NSToolbarItem.Identifier("microhm.batchClose")
        static let removeDead = NSToolbarItem.Identifier("microhm.removeDead")
        static let usage = NSToolbarItem.Identifier("microhm.usage")
        static let settings = NSToolbarItem.Identifier("microhm.settings")
        static let theme = NSToolbarItem.Identifier("microhm.theme")
    }

    let toolbar: NSToolbar
    private weak var owner: MainWindowController?
    private var themeItem: NSToolbarItem?

    init(owner: MainWindowController) {
        self.owner = owner
        toolbar = NSToolbar(identifier: "MicrohmMainToolbar-\(UUID().uuidString)")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = owner.toolbarLabels ? .iconAndLabel : .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    func validate() {
        toolbar.validateVisibleItems()
    }

    func updateThemeItem() {
        guard let themeItem, let owner else { return }
        let dark = owner.isDark
        themeItem.image = HarnessIcons.symbol(dark ? "sun.max" : "moon", dark ? "Light" : "Dark")
        themeItem.label = dark ? "Light" : "Dark"
        themeItem.toolTip = dark ? "Switch to the light appearance" : "Switch to the dark appearance"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        guard let owner else { return [] }
        var items: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator,
                                                  Item.newSession, Item.newHere, Item.shellHere, Item.duplicate]
        if owner.toolbarPageButtons {
            items += [.space, Item.pageUp, Item.pageDown]
        }
        if owner.toolbarStopLadder {
            items += [.space, Item.detach, Item.close, Item.kill, Item.closeAll]
        }
        if owner.toolbarBatchActions {
            items += [.space, Item.batchClose, Item.removeDead]
        }
        items += [.flexibleSpace, Item.usage, Item.settings, Item.theme]
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.newSession:
            return item(id, "New…", "plus.rectangle.on.folder", "Start a new session… (⌘N)",
                        #selector(MainWindowController.newSession(_:)))
        case Item.newHere:
            return item(id, "New Here", "folder.badge.plus", "New session where the selected session is (⇧⌘N)",
                        #selector(MainWindowController.newSessionHere(_:)))
        case Item.shellHere:
            return item(id, "Shell Here", "apple.terminal", "New shell in the selected session's folder (⌘T)",
                        #selector(MainWindowController.newShellHere(_:)))
        case Item.duplicate:
            return item(id, "Duplicate", "plus.square.on.square", "Duplicate the selected session (⌘D)",
                        #selector(MainWindowController.duplicateSession(_:)))
        case Item.pageUp:
            return item(id, "Page Up", "chevron.up.2", "Scroll the selected session one page up",
                        #selector(MainWindowController.scrollSessionPageUp(_:)))
        case Item.pageDown:
            return item(id, "Page Down", "chevron.down.2", "Scroll the selected session one page down",
                        #selector(MainWindowController.scrollSessionPageDown(_:)))
        case Item.detach:
            return item(id, "Detach", "eject", "Detach the selected session (keeps it running)",
                        #selector(MainWindowController.detachSession(_:)))
        case Item.close:
            return item(id, "Close", "xmark.circle", "Close the selected session gracefully (⌘W)",
                        #selector(MainWindowController.closeSession(_:)))
        case Item.kill:
            return item(id, "Kill", "bolt.circle", "Kill the selected session…",
                        #selector(MainWindowController.killSession(_:)))
        case Item.closeAll:
            return item(id, "Close All", "power", "Gracefully close all live sessions…",
                        #selector(MainWindowController.closeAllSessions(_:)))
        case Item.batchClose:
            return item(id, "Batch Close", "checklist", "Close a chosen batch of live sessions…",
                        #selector(MainWindowController.batchCloseSessions(_:)))
        case Item.removeDead:
            return item(id, "Remove Dead", "trash", "Remove a chosen batch of dead sessions from the registry…",
                        #selector(MainWindowController.removeDeadSessions(_:)))
        case Item.usage:
            return item(id, "Usage", "gauge.with.dots.needle.50percent", "Show harness usage and limits",
                        #selector(MainWindowController.showUsage(_:)))
        case Item.settings:
            return item(id, "Settings", "gearshape", "Settings (⌘,)", #selector(MainWindowController.openSettings(_:)))
        case Item.theme:
            let item = item(id, "Light", "sun.max", "", #selector(MainWindowController.toggleAppearance(_:)))
            themeItem = item
            updateThemeItem()
            return item
        default:
            return nil
        }
    }

    private func item(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ tip: String,
                      _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = HarnessIcons.symbol(symbol, label)
        item.action = action
        item.target = owner
        item.isBordered = true
        item.autovalidates = true
        return item
    }
}
