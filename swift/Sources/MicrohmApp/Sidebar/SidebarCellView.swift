import AppKit
import MicrohmCore

/// Status colours shared by the sidebar badges, the status item and the batch lists
/// (Java's `SidebarCellRenderer.WORKING`/`WAITING`/`IDLE`, here the system's own greens
/// and oranges so they adapt to light, dark and increased contrast).
enum StatusColors {
    static var working: NSColor { .systemGreen }
    static var waiting: NSColor { .systemOrange }
    static var idle: NSColor { .systemGray }
}

/// A sidebar row, laid out like a macOS source list (Java's `SidebarCellRenderer`):
///
/// - **Avatar** (left): the harness's mark on a soft rounded tile, with the session's
///   status as a presence badge on the tile's corner — green working (it breathes while
///   attached), orange waiting, gray idle, a hollow ring while the first poll is pending,
///   a cross for a dead session, whose whole avatar also fades.
/// - **Text** (middle): the session's name, and under it the project path in a muted,
///   smaller face, truncated from the left so the project folder survives. Inside a folder
///   group the path line is dropped (the group header carries it).
/// - **Attention pill** (right): shown only for a session waiting on the human, the one
///   state worth interrupting for. Everything calm stays quiet.
final class SidebarCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let avatar = AvatarView()
    private let nameField = NSTextField(labelWithString: "")
    private let pathField = NSTextField(labelWithString: "")
    private let pill = AttentionPill()
    private let reticule = ReticuleView()
    private var textStackTopToCenter: NSLayoutConstraint?
    private var dead = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = SidebarCellView.identifier

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingHead
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = nameField

        let lines = NSStackView(views: [nameField, pathField])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [avatar, lines, pill, reticule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: AvatarView.side),
            avatar.heightAnchor.constraint(equalToConstant: AvatarView.side),
            lines.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 9),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -6),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            reticule.leadingAnchor.constraint(equalTo: leadingAnchor),
            reticule.trailingAnchor.constraint(equalTo: trailingAnchor),
            reticule.topAnchor.constraint(equalTo: topAnchor),
            reticule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func configure(_ entry: SidebarEntry, grouped: Bool, reticuleEnabled: Bool) {
        dead = entry.status == .dead
        nameField.stringValue = entry.displayName
        pathField.stringValue = entry.abbreviatedPath
        pathField.isHidden = grouped
        toolTip = entry.tooltipText

        avatar.glyph = HarnessIcons.image(entry.harnessType, size: 16)
        avatar.faded = dead
        avatar.badge = AvatarView.Badge.of(entry)
        avatar.pulsing = entry.status == .live && entry.isAttached && entry.state == .working
        pill.isHidden = dead || entry.state != .waitingForInput
        reticule.isHidden = !(reticuleEnabled && entry.status == .live && !entry.isAttached)
        setAccessibilityLabel("\(entry.displayName), \(SidebarView.label(entry.harnessType)), \(entry.statusPhrase)")
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        nameField.textColor = emphasized ? .alternateSelectedControlTextColor : (dead ? .secondaryLabelColor : .labelColor)
        pathField.textColor = emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        avatar.emphasized = emphasized
        pill.emphasized = emphasized
    }
}

/// The harness mark on a rounded tile, with the status badge on its corner.
final class AvatarView: NSView {
    static let side: CGFloat = 28

    enum Badge {
        case working, waiting, idle, pending, dead

        static func of(_ entry: SidebarEntry) -> Badge {
            if entry.status == .dead { return .dead }
            switch entry.state {
            case .working?: return .working
            case .waitingForInput?: return .waiting
            case .idle?: return .idle
            case nil: return .pending
            }
        }
    }

    var glyph: NSImage? { didSet { needsDisplay = true } }
    var faded = false { didSet { needsDisplay = true } }
    var emphasized = false { didSet { needsDisplay = true; updateBadge() } }
    var badge: Badge = .pending { didSet { updateBadge() } }
    var pulsing = false {
        didSet {
            if pulsing != oldValue { updatePulse() }
        }
    }

    private let badgeLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(badgeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        updateBadge()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBadge()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7)
        let base: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        base.withAlphaComponent(emphasized ? 0.2 : 0.08).setFill()
        path.fill()
        guard let glyph else { return }
        let size: CGFloat = 16
        let rect = NSRect(x: tile.midX - size / 2, y: tile.midY - size / 2, width: size, height: size)
        let tinted = NSImage(size: rect.size, flipped: false) { r in
            glyph.draw(in: r)
            base.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: faded ? 0.4 : 0.9,
                    respectFlipped: true, hints: nil)
    }

    private func updateBadge() {
        let diameter: CGFloat = 11
        // a flipped view's layer is geometry-flipped too: this is the bottom-right corner
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        badgeLayer.frame = CGRect(x: bounds.maxX - diameter + 2, y: bounds.maxY - diameter + 2,
                                  width: diameter, height: diameter)
        let ring: NSColor = emphasized ? .controlAccentColor : .windowBackgroundColor
        var fill: NSColor = .clear
        var stroke: NSColor = ring
        var lineWidth: CGFloat = 2
        var path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: diameter - 2, height: diameter - 2), transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch badge {
            case .working:
                fill = StatusColors.working
            case .waiting:
                fill = StatusColors.waiting
            case .idle:
                fill = StatusColors.idle
            case .pending:
                fill = ring
                stroke = StatusColors.idle
                lineWidth = 1.6
                path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: diameter - 4, height: diameter - 4), transform: nil)
            case .dead:
                let cross = CGMutablePath()
                cross.addEllipse(in: CGRect(x: 1, y: 1, width: diameter - 2, height: diameter - 2))
                fill = StatusColors.idle
                path = cross
            }
            badgeLayer.path = path
            badgeLayer.fillColor = fill.cgColor
            badgeLayer.strokeColor = stroke.cgColor
            badgeLayer.lineWidth = lineWidth
        }
        badgeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        if badge == .dead {
            let x = CAShapeLayer()
            let p = CGMutablePath()
            let inset: CGFloat = 3.6
            p.move(to: CGPoint(x: inset, y: inset))
            p.addLine(to: CGPoint(x: diameter - inset, y: diameter - inset))
            p.move(to: CGPoint(x: diameter - inset, y: inset))
            p.addLine(to: CGPoint(x: inset, y: diameter - inset))
            x.path = p
            x.lineWidth = 1.4
            x.lineCap = .round
            effectiveAppearance.performAsCurrentDrawingAppearance {
                x.strokeColor = NSColor.windowBackgroundColor.cgColor
            }
            badgeLayer.addSublayer(x)
        }
    }

    /// Only the attached working dot breathes — a veiled (not-attached) row keeps its dot
    /// still, so the row reads as quiet. Core Animation drives it: no timer, no redraws.
    private func updatePulse() {
        badgeLayer.removeAnimation(forKey: "pulse")
        guard pulsing, window != nil else {
            badgeLayer.opacity = 1
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.3
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        badgeLayer.add(animation, forKey: "pulse")
    }
}

/// "Waiting", as an amber pill: the one row state that asks for the human.
final class AttentionPill: NSView {
    private let label = NSTextField(labelWithString: "Waiting")
    var emphasized = false { didSet { needsDisplay = true; applyColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Waiting for input")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func applyColors() {
        label.textColor = emphasized ? StatusColors.waiting : StatusColors.waiting
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (emphasized ? NSColor.white : StatusColors.waiting.withAlphaComponent(0.18)).setFill()
        path.fill()
    }
}

/// The screen door over a live row that is not attached yet (Settings → Look →
/// Reticule): every other pixel veiled in the window's background.
final class ReticuleView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let step = 2 / scale * 1.0
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        var y = bounds.minY
        var row = 0
        while y < bounds.maxY {
            var x = bounds.minX + (row % 2 == 0 ? 0 : step)
            while x < bounds.maxX {
                NSRect(x: x, y: y, width: step, height: step).fill()
                x += step * 2
            }
            y += step
            row += 1
        }
    }
}

/// A folder group's heading: the folder's name, its parent path muted, and the number of
/// sessions in it at the trailing edge.
final class FolderHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FolderHeader")

    private let icon = NSImageView()
    private let folderField = NSTextField(labelWithString: "")
    private let parentField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = FolderHeaderView.identifier
        icon.image = HarnessIcons.symbol("folder", "Folder", pointSize: 11, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        folderField.font = .systemFont(ofSize: 11, weight: .semibold)
        folderField.textColor = .secondaryLabelColor
        folderField.lineBreakMode = .byTruncatingTail
        folderField.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        parentField.font = .systemFont(ofSize: 11)
        parentField.textColor = .tertiaryLabelColor
        parentField.lineBreakMode = .byTruncatingHead
        parentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countField.textColor = .tertiaryLabelColor
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField = folderField
        for view in [icon, folderField, parentField, countField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: folderField.centerYAnchor),
            folderField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            folderField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            parentField.leadingAnchor.constraint(equalTo: folderField.trailingAnchor, constant: 6),
            parentField.firstBaselineAnchor.constraint(equalTo: folderField.firstBaselineAnchor),
            parentField.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -8),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countField.firstBaselineAnchor.constraint(equalTo: folderField.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func configure(_ group: FolderGroup) {
        folderField.stringValue = group.folderName
        parentField.stringValue = SidebarEntry.abbreviate(group.parentPath)
        countField.stringValue = String(group.entries.count)
        toolTip = SidebarEntry.abbreviate(group.path)
        setAccessibilityLabel("\(group.folderName), \(group.entries.count) sessions")
    }
}
