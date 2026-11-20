import AppKit
import MicrohmCore

/// Usage & Limits (Java's `UsageLimitsDialog`): pick a harness, see its provider account's
/// limit windows, how much of each is used and when it resets, plus usage statistics.
/// Loading runs in the background; a newer request supersedes an older one.
final class UsageWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: UsageWindowController?

    private let usage: HarnessUsageService
    private let harnessPopup = NSPopUpButton()
    private let refreshButton = NSButton()
    private let content = NSStackView()
    private let scroll = NSScrollView()
    private var requestSequence = 0
    private static let resetFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func show(initial: HarnessType, usage: HarnessUsageService) {
        let controller = shared ?? UsageWindowController(usage: usage)
        shared = controller
        controller.select(initial == .shell ? .claudeCode : initial)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.load()
    }

    private init(usage: HarnessUsageService) {
        self.usage = usage
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Usage & Limits"
        window.minSize = NSSize(width: 460, height: 360)
        window.toolbarStyle = .unifiedCompact
        window.setFrameAutosaveName("MicrohmUsageWindow")
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func build() {
        guard let window else { return }
        for type in HarnessType.allCases where type != .shell {
            harnessPopup.addItem(withTitle: SidebarView.label(type))
            harnessPopup.lastItem?.image = HarnessIcons.image(type, size: 16)
        }
        harnessPopup.target = self
        harnessPopup.action = #selector(harnessChanged(_:))
        refreshButton.bezelStyle = .push
        refreshButton.image = HarnessIcons.symbol("arrow.clockwise", "Refresh")
        refreshButton.imagePosition = .imageLeading
        refreshButton.title = "Refresh"
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = .command
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        let harnessLabel = NSTextField(labelWithString: "Harness:")
        let selector = NSStackView(views: [harnessLabel, harnessPopup, NSView(), refreshButton])
        selector.spacing = 8
        selector.translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(selector)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 14),
            selector.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            selector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        window.contentView = root
    }

    private var budgeted: [HarnessType] { HarnessType.allCases.filter { $0 != .shell } }

    private func select(_ harness: HarnessType) {
        if let index = budgeted.firstIndex(of: harness) {
            harnessPopup.selectItem(at: index)
        }
    }

    private var selectedHarness: HarnessType {
        let index = harnessPopup.indexOfSelectedItem
        return index >= 0 && index < budgeted.count ? budgeted[index] : .claudeCode
    }

    /// ⌘W closes this window (in the main window it closes the selected session).
    @objc func closeSession(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc private func harnessChanged(_ sender: Any?) { load() }
    @objc private func refresh(_ sender: Any?) { load() }

    private func load() {
        let harness = selectedHarness
        requestSequence += 1
        let request = requestSequence
        harnessPopup.isEnabled = false
        refreshButton.isEnabled = false
        replace([loadingView(harness)])
        let usage = self.usage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try usage.load(harness) }
            DispatchQueue.main.async {
                guard let self, request == self.requestSequence else { return }
                self.harnessPopup.isEnabled = true
                self.refreshButton.isEnabled = true
                switch result {
                case .success(let snapshot): self.replace(self.snapshotViews(snapshot))
                case .failure(let error): self.replace(self.errorViews(harness, error))
                }
            }
        }
    }

    private func replace(_ views: [NSView]) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            content.addArrangedSubview(view)
            if view is CardView {
                view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
            } else {
                view.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40).isActive = true
            }
        }
    }

    private func loadingView(_ harness: HarnessType) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Loading \(SidebarView.label(harness)) usage…")
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        return row
    }

    private func snapshotViews(_ snapshot: UsageSnapshot) -> [NSView] {
        var views: [NSView] = []
        let heading = NSTextField(labelWithString: snapshot.heading)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        views.append(heading)
        views.append(muted("Source: \(snapshot.source)"))
        if snapshot.limits.isEmpty {
            views.append(NSTextField(labelWithString: "No live limit windows available."))
        } else {
            for limit in snapshot.limits {
                views.append(limitCard(limit))
            }
        }
        if !snapshot.statistics.isEmpty {
            let title = NSTextField(labelWithString: "Usage details")
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            views.append(title)
            let grid = NSGridView(views: snapshot.statistics.map { stat -> [NSView] in
                let value = NSTextField(labelWithString: stat.value)
                value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
                value.isSelectable = true
                let label = muted("\(stat.label):")
                label.setContentHuggingPriority(.required, for: .horizontal)
                value.setContentHuggingPriority(.required, for: .horizontal)
                // an empty third column takes the slack, so values sit beside their labels
                let slack = NSView()
                slack.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
                return [label, value, slack]
            })
            grid.rowSpacing = 4
            grid.columnSpacing = 14
            grid.xPlacement = .leading
            grid.rowAlignment = .firstBaseline
            views.append(grid)
        }
        if let note = snapshot.note {
            let label = NSTextField(wrappingLabelWithString: note)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            views.append(label)
        }
        return views
    }

    private func limitCard(_ limit: UsageSnapshot.Limit) -> NSView {
        let title = NSTextField(labelWithString: limit.label)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let used = NSTextField(labelWithString: "\(limit.usedPercent)% used")
        used.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        used.textColor = limit.usedPercent >= 90 ? .systemRed : (limit.usedPercent >= 70 ? .systemOrange : .secondaryLabelColor)
        let top = NSStackView(views: [title, NSView(), used])
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = Double(max(0, min(100, limit.usedPercent)))
        var detail: [String] = []
        if let text = limit.detail { detail.append(text) }
        if let reset = limit.resetsAt { detail.append("Resets \(UsageWindowController.resetFormat.string(from: reset))") }
        let stack = NSStackView(views: [top, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        if !detail.isEmpty {
            stack.addArrangedSubview(muted(detail.joined(separator: " · ")))
        }
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for view in [top, bar] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        return CardView(stack)
    }

    private func errorViews(_ harness: HarnessType, _ error: Error) -> [NSView] {
        let heading = NSTextField(labelWithString: "Couldn’t load \(SidebarView.label(harness)) usage")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: error.localizedDescription)
        detail.textColor = .secondaryLabelColor
        return [heading, detail]
    }

    private func muted(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }
}

/// A rounded, softly filled card around one view.
final class CardView: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
