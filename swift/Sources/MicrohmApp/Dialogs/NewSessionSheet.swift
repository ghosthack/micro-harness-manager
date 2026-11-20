import AppKit
import MicrohmCore

/// The New Session sheet (Java's `OpenSessionDialog`, plus the phone page's optional
/// name and first message): folder (with Choose…), harness, name, first message, and a
/// resume id under Advanced.
final class NewSessionSheet: NSWindowController, NSWindowDelegate {

    struct Result {
        let projectPath: URL
        let harness: HarnessType
        let displayName: String?
        let firstMessage: String?
        let resumeId: String?
    }

    private static var current: NewSessionSheet?

    private let pathField = NSTextField()
    private let harnessPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let messageView = NSTextView()
    private let resumeField = NSTextField()
    private let shellLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var completion: ((Result?) -> Void)?

    static func present(on parent: NSWindow, prefillPath: String?, prefillHarness: HarnessType?,
                        shellDescription: String, completion: @escaping (Result?) -> Void) {
        guard current == nil else { return }
        let sheet = NewSessionSheet(prefillPath: prefillPath, prefillHarness: prefillHarness, shell: shellDescription)
        sheet.completion = completion
        current = sheet
        guard let window = sheet.window else { return }
        parent.beginSheet(window) { _ in
            current = nil
        }
        window.makeFirstResponder(sheet.pathField)
    }

    private init(prefillPath: String?, prefillHarness: HarnessType?, shell: String) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                             styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        window.title = "New Session"
        super.init(window: window)
        build(prefillPath: prefillPath, prefillHarness: prefillHarness, shell: shell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func build(prefillPath: String?, prefillHarness: HarnessType?, shell: String) {
        guard let window else { return }
        let title = NSTextField(labelWithString: "New Session")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Start an agent or a shell in a folder. Sessions keep running in the background daemon.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        pathField.stringValue = SidebarEntry.abbreviate(prefillPath ?? NSHomeDirectory())
        pathField.placeholderString = "~/Projects/my-app"
        pathField.lineBreakMode = .byTruncatingHead
        pathField.setAccessibilityLabel("Folder")
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))
        let pathRow = NSStackView(views: [pathField, choose])
        pathRow.spacing = 8

        for type in HarnessType.allCases {
            harnessPopup.addItem(withTitle: type == .shell ? "Shell" : "\(SidebarView.label(type))  ·  \(type.id)")
            harnessPopup.lastItem?.image = HarnessIcons.image(type, size: 16)
            harnessPopup.lastItem?.representedObject = type.id
        }
        if let prefillHarness, let index = HarnessType.allCases.firstIndex(of: prefillHarness) {
            harnessPopup.selectItem(at: index)
        }
        harnessPopup.target = self
        harnessPopup.action = #selector(harnessChanged(_:))

        nameField.placeholderString = "Optional — shown in the sidebar"
        nameField.setAccessibilityLabel("Name")

        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.textContainerInset = NSSize(width: 4, height: 5)
        messageView.setAccessibilityLabel("First message")
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageView.autoresizingMask = [.width]
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let messageHint = hint("Optional. Typed into the agent once it is ready at its prompt.")

        resumeField.placeholderString = "Blank starts a fresh conversation"
        resumeField.setAccessibilityLabel("Resume session id")

        shellLabel.stringValue = shell
        shellLabel.textColor = .secondaryLabelColor
        let shellHint = hint("Change it in Settings → Sessions → Shell.")

        let grid = NSGridView(views: [
            [label("Folder:"), pathRow],
            [label("Harness:"), harnessPopup],
            [label("Name:"), nameField],
            [label("First message:"), messageScroll],
            [NSGridCell.emptyContentView, messageHint],
            [label("Resume id:"), resumeField],
            [label("Shell:"), shellLabel],
            [NSGridCell.emptyContentView, shellHint],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 3).yPlacement = .top
        grid.row(at: 4).topPadding = -4
        grid.row(at: 7).topPadding = -4
        for row in [3] {
            grid.cell(atColumnIndex: 0, rowIndex: row).yPlacement = .top
        }
        grid.column(at: 1).width = 380

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: "Start Session", target: self, action: #selector(create(_:)))
        create.keyEquivalent = "\r"
        create.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [errorLabel, NSView(), cancel, create])
        buttons.spacing = 10

        let stack = NSStackView(views: [title, subtitle, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(18, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
        harnessChanged(nil)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .tertiaryLabelColor
        return field
    }

    private var selectedHarness: HarnessType {
        let index = harnessPopup.indexOfSelectedItem
        let all = HarnessType.allCases
        return index >= 0 && index < all.count ? all[index] : .claudeCode
    }

    @objc private func harnessChanged(_ sender: Any?) {
        // a first message and a resume id mean nothing to a plain shell
        let shell = selectedHarness == .shell
        messageView.isEditable = !shell
        messageView.textColor = shell ? .tertiaryLabelColor : .labelColor
        resumeField.isEnabled = !shell
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder the session starts in."
        let current = expanded(pathField.stringValue)
        panel.directoryURL = URL(fileURLWithPath: current.isEmpty ? NSHomeDirectory() : current)
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.pathField.stringValue = SidebarEntry.abbreviate(url.path)
            }
        }
    }

    private func expanded(_ text: String) -> String {
        (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
        NSSound.beep()
    }

    @objc private func create(_ sender: Any?) {
        let path = expanded(pathField.stringValue)
        guard !path.isEmpty else {
            showError("A folder is required.")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showError("'\(SidebarEntry.abbreviate(path))' is not a folder.")
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 64 || name.contains("·") || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            showError("A name is at most 64 characters, on one line, without “·”.")
            return
        }
        let harness = selectedHarness
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let resume = resumeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(Result(projectPath: URL(fileURLWithPath: path), harness: harness,
                      displayName: name.isEmpty ? nil : name,
                      firstMessage: harness == .shell || message.isEmpty ? nil : message,
                      resumeId: harness == .shell || resume.isEmpty ? nil : resume))
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    private func finish(_ result: Result?) {
        guard let window else { return }
        let completion = self.completion
        self.completion = nil
        window.sheetParent?.endSheet(window)
        completion?(result)
    }
}
