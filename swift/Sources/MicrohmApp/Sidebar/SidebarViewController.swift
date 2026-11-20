import AppKit
import MicrohmCore

protocol SidebarViewControllerDelegate: AnyObject {
    /// The user changed the selection (not a programmatic reselect).
    func sidebarSelectionDidChange(_ sidebar: SidebarViewController)
    /// The context menu for a right-clicked row (already selected).
    func sidebar(_ sidebar: SidebarViewController, menuFor entry: SidebarEntry) -> NSMenu?
    func sidebarSortMenu(_ sidebar: SidebarViewController) -> NSMenu
    func sidebarStatusFilterMenu(_ sidebar: SidebarViewController) -> NSMenu
    func sidebarHarnessFilterMenu(_ sidebar: SidebarViewController) -> NSMenu
    /// A double-click or Return on a row.
    func sidebarActivate(_ sidebar: SidebarViewController)
}

/// The sidebar: a "Sessions" heading with the sort and filter controls, the session list
/// (a source-list outline, grouped by folder when asked), and the budgets panel at the
/// bottom. Owns no session state — `MainWindowController` hands it the visible rows.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    weak var delegate: SidebarViewControllerDelegate?

    let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    let budgetPanel = HarnessBudgetPanel()
    private let sortButton = NSButton()
    private let filterButton = NSButton()
    private let harnessButton = NSButton()
    private let heading = NSTextField(labelWithString: "Sessions")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let backgroundView = NSView()

    /// Top-level outline items: `FolderGroup`s (when grouping) and `SidebarEntry`s.
    private var roots: [AnyObject] = []
    /// The visible sessions in on-screen order — what Ctrl+1..9 counts.
    private(set) var visibleEntries: [SidebarEntry] = []
    private(set) var grouping = false
    var reticuleEnabled = false
    /// Set while the list is rebuilt, so the rebuild's own selection changes are not
    /// reported as the user's.
    private var rebuilding = false

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backgroundView)

        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, symbol, name, action) in [
            (sortButton, "arrow.up.arrow.down", "Sort", #selector(showSortMenu(_:))),
            (filterButton, "line.3.horizontal.decrease.circle", "Filter statuses", #selector(showFilterMenu(_:))),
            (harnessButton, "square.stack.3d.up", "Filter harnesses", #selector(showHarnessMenu(_:))),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.image = HarnessIcons.symbol(symbol, nil, pointSize: 12)
            button.imagePosition = .imageOnly
            button.refusesFirstResponder = true
            button.setAccessibilityLabel(name)
            button.target = self
            button.action = action
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let header = NSStackView(views: [heading, NSView(), sortButton, filterButton, harnessButton])
        header.orientation = .horizontal
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 0
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setAccessibilityLabel("Sessions")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.onReturn = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebarActivate(self)
        }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)
        budgetPanel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(budgetPanel)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: root.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            budgetPanel.topAnchor.constraint(equalTo: separator.bottomAnchor),
            budgetPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            budgetPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            budgetPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        view = root
    }

    // MARK: - content

    /// Replaces the visible rows and restores the selection to `select` (a session name)
    /// when it is still visible. Never reports the change as the user's.
    func setEntries(_ entries: [SidebarEntry], grouping: Bool, select target: String?) {
        rebuilding = true
        defer { rebuilding = false }
        self.grouping = grouping
        visibleEntries = entries
        roots = []
        if grouping {
            var current: FolderGroup?
            for entry in entries {
                let key = SidebarView.folderGroupKey(entry)
                if key.isEmpty {
                    current = nil
                    roots.append(entry)
                } else if let group = current, group.key == key {
                    group.entries.append(entry)
                } else {
                    let group = FolderGroup(key: key, path: entry.sessionEntry.projectPath, entries: [entry])
                    roots.append(group)
                    current = group
                }
            }
        } else {
            roots = entries
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        select(sessionName: target, scroll: true)
    }

    /// The empty list's hint, e.g. "No sessions yet" or "Every session is filtered out".
    func setEmptyText(_ text: String) {
        emptyLabel.stringValue = text
        emptyLabel.isHidden = !visibleEntries.isEmpty || text.isEmpty
    }

    var selectedEntry: SidebarEntry? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? SidebarEntry : nil
    }

    /// Selects `sessionName`'s row (nil, or a hidden row, clears the selection). Not
    /// reported to the delegate.
    @discardableResult
    func select(sessionName: String?, scroll: Bool) -> Bool {
        let wasRebuilding = rebuilding
        rebuilding = true
        defer { rebuilding = wasRebuilding }
        guard let sessionName, let entry = visibleEntries.first(where: { $0.sessionName == sessionName }) else {
            outlineView.deselectAll(nil)
            return false
        }
        let row = outlineView.row(forItem: entry)
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return false
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll {
            outlineView.scrollRowToVisible(row)
        }
        return true
    }

    /// Redraws one session's row in place (state, title or attachment changed).
    func reload(_ entry: SidebarEntry) {
        let row = outlineView.row(forItem: entry)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else {
            return
        }
        cell.configure(entry, grouped: grouping && !SidebarView.folderGroupKey(entry).isEmpty,
                       reticuleEnabled: reticuleEnabled)
    }

    func reloadAllRows() {
        for entry in visibleEntries {
            reload(entry)
        }
    }

    /// Heading controls: compact icon buttons (the sidebar is too narrow for "Sort:
    /// Session" labels); a filled glyph shows a filter is hiding something, and the
    /// tooltips carry the full summaries.
    func updateControls(sortLabel: String, sortDescending: Bool, filterSummary: String, filtering: Bool,
                        harnessSummary: String, harnessFiltering: Bool) {
        filterButton.image = HarnessIcons.symbol(filtering ? "line.3.horizontal.decrease.circle.fill"
                                                 : "line.3.horizontal.decrease.circle", "Filter", pointSize: 12)
        filterButton.contentTintColor = filtering ? .controlAccentColor : nil
        harnessButton.image = HarnessIcons.symbol(harnessFiltering ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                                                  "Harnesses", pointSize: 12)
        harnessButton.contentTintColor = harnessFiltering ? .controlAccentColor : nil
        sortButton.toolTip = "Sort: \(sortLabel) (\(sortDescending ? "descending" : "ascending")) — choose how sessions are sorted"
        filterButton.toolTip = "\(filterSummary) — choose which statuses are visible"
        harnessButton.toolTip = "\(harnessSummary) — choose which harness families are visible"
        heading.stringValue = "Sessions · by \(sortLabel.lowercased())"
    }

    /// The sidebar surface: the system's translucent source list, or a solid fill.
    func applyBackground(_ color: NSColor?) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundView.layer?.backgroundColor = color?.cgColor
        }
        let style: NSTableView.Style = color == nil ? .sourceList : .fullWidth
        outlineView.backgroundColor = color ?? .clear
        guard outlineView.style != style else { return }
        // a style change re-measures rows; keep the selection across the reload
        let selected = selectedEntry?.sessionName
        outlineView.style = style
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        select(sessionName: selected, scroll: false)
    }

    // MARK: - actions

    @objc private func showSortMenu(_ sender: NSButton) {
        guard let delegate else { return }
        popUp(delegate.sidebarSortMenu(self), under: sender)
    }

    @objc private func showFilterMenu(_ sender: NSButton) {
        guard let delegate else { return }
        popUp(delegate.sidebarStatusFilterMenu(self), under: sender)
    }

    @objc private func showHarnessMenu(_ sender: NSButton) {
        guard let delegate else { return }
        popUp(delegate.sidebarHarnessFilterMenu(self), under: sender)
    }

    private func popUp(_ menu: NSMenu, under button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard outlineView.clickedRow >= 0, outlineView.item(atRow: outlineView.clickedRow) is SidebarEntry else { return }
        delegate?.sidebarActivate(self)
    }

    // MARK: - context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        // a click in the blank area below the list must not select (and attach) anything
        guard row >= 0, let entry = outlineView.item(atRow: row) as? SidebarEntry else { return }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard let built = delegate?.sidebar(self, menuFor: entry) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        return (item as? FolderGroup)?.entries.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        if let group = item as? FolderGroup { return group.entries[index] }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FolderGroup
    }

    // MARK: - delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? FolderGroup {
            let view = outlineView.makeView(withIdentifier: FolderHeaderView.identifier, owner: self) as? FolderHeaderView
                ?? FolderHeaderView(frame: .zero)
            view.configure(group)
            return view
        }
        guard let entry = item as? SidebarEntry else { return nil }
        let view = outlineView.makeView(withIdentifier: SidebarCellView.identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView(frame: .zero)
        view.configure(entry, grouped: grouping && !SidebarView.folderGroupKey(entry).isEmpty,
                       reticuleEnabled: reticuleEnabled)
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is FolderGroup {
            return outlineView.row(forItem: item) == 0 ? 22 : 30
        }
        if let entry = item as? SidebarEntry, grouping, !SidebarView.folderGroupKey(entry).isEmpty {
            return 36
        }
        return 44
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is FolderGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarEntry
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !rebuilding {
            delegate?.sidebarSelectionDidChange(self)
        }
    }
}

/// The session list: Return activates the selected row (focuses its terminal).
final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { // Return, keypad Enter
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}
