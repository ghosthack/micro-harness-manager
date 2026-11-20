import AppKit
import MicrohmCore

/// The graceful-close ladder for one session in a batch (Java's `BatchCloseDialog
/// .attemptClose` and the Shutdown loop): nil when it closed, otherwise the "name —
/// reason" line for the summary. Blocks: run it off the main thread.
enum BatchActions {
    static func close(_ entry: SessionEntry, _ lastPolled: SessionState?, _ closer: GracefulCloser,
                      _ registry: SessionRegistry) -> String? {
        let name = entry.sessionName
        do {
            let result = try closer.close(name, HarnessPlugins.of(entry.harnessType), lastPolled)
            if let id = result.harnessSessionIdOpt {
                registry.recordHarnessSessionId(name, id)
            }
            switch result.outcome {
            case .closed, .alreadyGone: return nil
            case .busyState: return "\(name) — \(result.detail)"
            case .busyForeground: return "\(name) — '\(result.detail)' is still running in it"
            case .noQuitSyntax: return "\(name) — no verified graceful-quit syntax"
            case .quitTimeout, .exitTimeout: return "\(name) — didn't exit in time"
            }
        } catch {
            return "\(name) — \(error.localizedDescription)"
        }
    }
}

/// "Pick some sessions, then act on them" (Java's `BatchOperationDialog` and
/// `SessionChecklist`): a checklist grouped by folder with tri-state folder boxes and
/// Select All, then a live progress pass, then a summary of whatever could not be done.
/// The pass is sequential — two mutations racing on one daemon or registry is needless
/// risk for something this destructive.
final class BatchOperationSheet: NSWindowController {

    struct Words {
        let gerund: String
        let past: String
        let infinitive: String
    }

    private static var current: BatchOperationSheet?

    private var groups: [(title: String, members: [SidebarEntry])] = []
    private var boxes: [ObjectIdentifier: NSButton] = [:]
    private var headerBoxes: [NSButton] = []
    private let selectAll = NSButton(checkboxWithTitle: "Select All", target: nil, action: nil)
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()
    private let doneButton = NSButton()
    private let checklist = NSScrollView()
    private let progress = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var candidates: [SidebarEntry] = []

    private var words = Words(gerund: "", past: "", infinitive: "")
    private var queue = DispatchQueue.global()
    private var operation: (SidebarEntry) -> String? = { _ in nil }
    private var onSucceeded: (SidebarEntry) -> Void = { _ in }
    private var onFinished: () -> Void = {}

    static func present(on parent: NSWindow, title: String, intro: String, confirm: String,
                        candidates: [SidebarEntry], defaultChecked: (SidebarEntry) -> Bool,
                        rowLabel: (SidebarEntry) -> String, words: Words, queue: DispatchQueue,
                        operation: @escaping (SidebarEntry) -> String?,
                        onSucceeded: @escaping (SidebarEntry) -> Void, onFinished: @escaping () -> Void) {
        guard current == nil, !candidates.isEmpty else { return }
        let sheet = BatchOperationSheet()
        sheet.words = words
        sheet.queue = queue
        sheet.operation = operation
        sheet.onSucceeded = onSucceeded
        sheet.onFinished = onFinished
        sheet.build(title: title, intro: intro, confirm: confirm, candidates: candidates,
                    defaultChecked: defaultChecked, rowLabel: rowLabel)
        current = sheet
        guard let window = sheet.window else { return }
        parent.beginSheet(window) { _ in current = nil }
    }

    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                             styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func build(title: String, intro: String, confirm: String, candidates: [SidebarEntry],
                       defaultChecked: (SidebarEntry) -> Bool, rowLabel: (SidebarEntry) -> String) {
        guard let window else { return }
        self.candidates = candidates
        window.title = title
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let introLabel = NSTextField(wrappingLabelWithString: intro)
        introLabel.textColor = .secondaryLabelColor

        var byFolder: [String: [SidebarEntry]] = [:]
        for entry in candidates {
            let key = entry.abbreviatedPath.isEmpty ? entry.sessionName : entry.abbreviatedPath
            byFolder[key, default: []].append(entry)
        }
        groups = byFolder.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { key in
            (key, (byFolder[key] ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        }

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        rows.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for (index, group) in groups.enumerated() {
            let header = NSButton(checkboxWithTitle: "\(group.title) (\(group.members.count))", target: self,
                                  action: #selector(headerToggled(_:)))
            header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            header.allowsMixedState = true
            header.tag = index
            headerBoxes.append(header)
            if index > 0 { rows.setCustomSpacing(10, after: rows.arrangedSubviews.last ?? header) }
            rows.addArrangedSubview(header)
            for entry in group.members {
                let box = NSButton(checkboxWithTitle: "\(entry.displayName)  —  \(rowLabel(entry))", target: self,
                                   action: #selector(boxToggled(_:)))
                box.image = nil
                box.state = defaultChecked(entry) ? .on : .off
                boxes[ObjectIdentifier(entry)] = box
                let indent = NSStackView(views: [NSView(), harnessIcon(entry), box])
                indent.spacing = 4
                indent.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: 14).isActive = true
                rows.addArrangedSubview(indent)
            }
        }
        let document = FlippedView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        checklist.documentView = document
        checklist.hasVerticalScroller = true
        checklist.borderType = .bezelBorder
        checklist.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: checklist.contentView.widthAnchor).isActive = true
        let listHeight = min(300, max(120, rows.fittingSize.height + 8))
        checklist.heightAnchor.constraint(equalToConstant: listHeight).isActive = true

        selectAll.target = self
        selectAll.action = #selector(selectAllToggled(_:))

        progress.style = .bar
        progress.isIndeterminate = false
        progress.isHidden = true
        progressLabel.isHidden = true
        summary.isHidden = true
        summary.isSelectable = true

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        confirmButton.title = confirm
        confirmButton.bezelStyle = .push
        confirmButton.target = self
        confirmButton.action = #selector(run(_:))
        doneButton.title = "Done"
        doneButton.bezelStyle = .push
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(cancel(_:))
        doneButton.isHidden = true
        let buttons = NSStackView(views: [NSView(), cancelButton, confirmButton, doneButton])
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, introLabel, selectAll, checklist, progressLabel, progress, summary, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        for view in [introLabel, checklist, progress, summary, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = content
        window.setContentSize(content.fittingSize)
        refreshTriState()
    }

    private func harnessIcon(_ entry: SidebarEntry) -> NSView {
        let view = NSImageView(image: HarnessIcons.image(entry.harnessType, size: 13))
        view.contentTintColor = .secondaryLabelColor
        return view
    }

    private var selected: [SidebarEntry] {
        groups.flatMap(\.members).filter { boxes[ObjectIdentifier($0)]?.state == .on }
    }

    private func refreshTriState() {
        for (index, group) in groups.enumerated() where index < headerBoxes.count {
            let on = group.members.filter { boxes[ObjectIdentifier($0)]?.state == .on }.count
            headerBoxes[index].state = on == 0 ? .off : (on == group.members.count ? .on : .mixed)
        }
        let total = boxes.count
        let on = boxes.values.filter { $0.state == .on }.count
        selectAll.state = on == total && total > 0 ? .on : .off
        confirmButton.isEnabled = on > 0
        confirmButton.keyEquivalent = on > 0 ? "\r" : ""
    }

    @objc private func boxToggled(_ sender: NSButton) {
        refreshTriState()
    }

    @objc private func headerToggled(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < groups.count else { return }
        // a mixed header click selects the whole folder
        let state: NSControl.StateValue = sender.state == .off ? .off : .on
        sender.state = state
        for entry in groups[sender.tag].members {
            boxes[ObjectIdentifier(entry)]?.state = state
        }
        refreshTriState()
    }

    @objc private func selectAllToggled(_ sender: NSButton) {
        for box in boxes.values {
            box.state = sender.state
        }
        refreshTriState()
    }

    @objc private func cancel(_ sender: Any?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    @objc private func run(_ sender: Any?) {
        let chosen = selected
        guard !chosen.isEmpty else { return }
        confirmButton.isHidden = true
        cancelButton.isEnabled = false
        selectAll.isEnabled = false
        checklist.isHidden = true
        progress.isHidden = false
        progressLabel.isHidden = false
        progress.maxValue = Double(chosen.count)
        progress.doubleValue = 0
        progressLabel.stringValue = "\(words.gerund) \(chosen.count) session\(chosen.count == 1 ? "" : "s")…"
        let operation = self.operation
        let words = self.words
        queue.async { [weak self] in
            var succeeded = 0
            var failed: [String] = []
            for (index, entry) in chosen.enumerated() {
                DispatchQueue.main.async {
                    self?.progressLabel.stringValue = "\(words.gerund) '\(entry.sessionName)'… (\(index + 1) of \(chosen.count))"
                }
                let failure = operation(entry)
                DispatchQueue.main.async {
                    if let failure {
                        failed.append(failure)
                    } else {
                        succeeded += 1
                        self?.onSucceeded(entry)
                    }
                    self?.progress.doubleValue = Double(index + 1)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var text = "\(words.past) \(succeeded) of \(chosen.count) session\(chosen.count == 1 ? "" : "s")."
                if !failed.isEmpty {
                    text += "\n\nCould not \(words.infinitive) \(failed.count):\n" + failed.map { "• " + $0 }.joined(separator: "\n")
                }
                self.summary.stringValue = text
                self.summary.isHidden = false
                self.progressLabel.stringValue = "Done."
                self.cancelButton.isHidden = true
                self.doneButton.isHidden = false
                self.window.map { $0.setContentSize($0.contentView?.fittingSize ?? $0.frame.size) }
                self.onFinished()
            }
        }
    }
}
