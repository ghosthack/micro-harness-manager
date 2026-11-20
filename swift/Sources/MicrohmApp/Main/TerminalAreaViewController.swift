import AppKit

/// The right pane: exactly one "card" at a time — the empty-selection message, an
/// "Attaching…"/detached/failed placeholder, the dead-session message, or one attached
/// session's terminal — plus a transient banner floating over whichever is showing.
/// Terminal views stay in the hierarchy while hidden, so switching sessions never rebuilds
/// a terminal (Java's CardLayout).
final class TerminalAreaViewController: NSViewController {

    var onNewSession: (() -> Void)?
    var onResume: (() -> Void)?

    private let cards = NSView()
    private let defaultCard = MessageCard()
    private let placeholderCard = MessageCard()
    private let deadCard = MessageCard()
    private let banner = BannerView()
    private var terminals: [String: NSView] = [:]
    private var bannerHide: DispatchWorkItem?
    private(set) var visibleTerminal: String?

    override func loadView() {
        let root = BackgroundView()
        cards.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cards)
        for card in [defaultCard, placeholderCard, deadCard] {
            add(card)
        }
        defaultCard.set(symbol: "rectangle.stack.badge.plus",
                        title: "No session selected",
                        message: "Select a session in the sidebar, or start a new one.",
                        button: "New Session…", action: { [weak self] in self?.onNewSession?() })
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        root.addSubview(banner)
        NSLayoutConstraint.activate([
            cards.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cards.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            cards.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            banner.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            banner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        view = root
        show(defaultCard)
    }

    private func add(_ card: NSView) {
        card.translatesAutoresizingMaskIntoConstraints = false
        cards.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: cards.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cards.trailingAnchor),
            card.topAnchor.constraint(equalTo: cards.topAnchor),
            card.bottomAnchor.constraint(equalTo: cards.bottomAnchor),
        ])
    }

    private func show(_ card: NSView) {
        for view in cards.subviews {
            view.isHidden = view !== card
        }
        visibleTerminal = terminals.first { $0.value === card }?.key
    }

    // MARK: - cards

    func showDefault() {
        show(defaultCard)
    }

    /// "Attaching to 'x'…", "'x' is detached…", "Failed to attach…".
    func showPlaceholder(_ message: String, symbol: String = "hourglass", progress: Bool = false) {
        placeholderCard.set(symbol: symbol, title: nil, message: message, button: nil, action: nil, progress: progress)
        show(placeholderCard)
    }

    func showDead(_ sessionName: String) {
        deadCard.set(symbol: "moon.zzz",
                     title: "'\(sessionName)' has stopped",
                     message: "Its saved entry can be resumed, or right-click it in the sidebar to remove it.",
                     button: "Resume…", action: { [weak self] in self?.onResume?() })
        show(deadCard)
    }

    func addTerminal(_ name: String, view terminalView: NSView) {
        if let old = terminals[name], old !== terminalView {
            old.removeFromSuperview()
        }
        terminals[name] = terminalView
        if terminalView.superview !== cards {
            terminalView.isHidden = true
            add(terminalView)
        }
    }

    func removeTerminal(_ name: String) {
        terminals.removeValue(forKey: name)?.removeFromSuperview()
        if visibleTerminal == name {
            visibleTerminal = nil
        }
    }

    func showTerminal(_ name: String) {
        guard let terminal = terminals[name] else { return }
        show(terminal)
    }

    /// The right pane's surface behind the message cards (the terminals paint their own).
    func applyBackground(_ color: NSColor?) {
        (view as? BackgroundView)?.fill = color
    }

    // MARK: - banner

    /// A transient message over whichever card is showing; a fresh message restarts the clock.
    func showBanner(_ text: String) {
        banner.text = text
        banner.isHidden = false
        banner.alphaValue = 1
        bannerHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self?.banner.animator().alphaValue = 0
            }, completionHandler: {
                self?.banner.isHidden = true
            })
        }
        bannerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }
}

/// A solid fill when one is set; otherwise the window background.
final class BackgroundView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        (fill ?? .windowBackgroundColor).setFill()
        dirtyRect.fill()
    }
}

/// A centred symbol, title, message and optional button: the empty states.
final class MessageCard: NSView {
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.symbolConfiguration = .init(pointSize: 40, weight: .light)
        imageView.contentTintColor = .tertiaryLabelColor
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .center
        messageField.alignment = .center
        messageField.textColor = .secondaryLabelColor
        messageField.preferredMaxLayoutWidth = 420
        button.bezelStyle = .push
        button.controlSize = .large
        button.target = self
        button.action = #selector(clicked(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        let stack = NSStackView(views: [imageView, spinner, titleField, messageField, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: messageField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            messageField.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func set(symbol: String, title: String?, message: String, button title2: String?, action: (() -> Void)?,
             progress: Bool = false) {
        imageView.image = progress ? nil : HarnessIcons.symbol(symbol)
        imageView.isHidden = progress
        spinner.isHidden = !progress
        if progress { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        titleField.stringValue = title ?? ""
        titleField.isHidden = title == nil
        messageField.stringValue = message
        button.title = title2 ?? ""
        button.isHidden = title2 == nil
        self.action = action
    }

    @objc private func clicked(_ sender: Any?) {
        action?()
    }
}

/// The floating banner: a rounded, translucent capsule with one line of text.
final class BannerView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}
