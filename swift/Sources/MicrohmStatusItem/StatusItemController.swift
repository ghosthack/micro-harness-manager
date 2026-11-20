import AppKit

/// The menu-bar icon (Java's `mcphost.StatusIcon`), shown by the app while it runs and by the background host while it is closed: a resistor glyph
/// with the number of running sessions beside it, and a menu that says how many sessions
/// run, whether MCP is serving, and opens the app or hides the icon. Ending sessions stays
/// in the window, whose close flow asks each harness to quit.
public final class StatusItemController: NSObject {

    public static let appName = "Microhm"

    public override init() { super.init() }

    public var onOpen: (() -> Void)?
    public var onHide: (() -> Void)?

    private var item: NSStatusItem?
    private let sessionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let mcpItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let phoneItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sessions = -1
    private var mcpPort = -2
    private var phonePort = -2

    public var isShown: Bool { item != nil }

    public func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusItemController.glyph()
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Microhm")
        let menu = NSMenu()
        for info in [sessionsItem, mcpItem, phoneItem] {
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open \(StatusItemController.appName)", action: #selector(open(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide This Icon", action: #selector(hide(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        item.menu = menu
        self.item = item
        sessions = -1
        update(liveSessions: 0, mcpPort: nil, phonePort: nil)
    }

    public func remove() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
    }

    public func update(liveSessions: Int, mcpPort: Int?, phonePort: Int?) {
        guard let item else { return }
        let mcp = mcpPort ?? -1, phone = phonePort ?? -1
        guard liveSessions != sessions || mcp != self.mcpPort || phone != self.phonePort else { return }
        sessions = liveSessions
        self.mcpPort = mcp
        self.phonePort = phone
        item.button?.title = liveSessions > 0 ? " \(liveSessions)" : ""
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        sessionsItem.title = StatusItemController.sessionsLabel(liveSessions)
        mcpItem.title = StatusItemController.mcpLabel(mcp)
        phoneItem.title = phone > 0 ? "Phone page on port \(phone)" : "Phone page off"
        item.button?.toolTip = StatusItemController.tooltip(liveSessions, mcp)
    }

    static func sessionsLabel(_ sessions: Int) -> String {
        sessions == 1 ? "1 session running" : "\(sessions) sessions running"
    }

    static func mcpLabel(_ port: Int) -> String {
        port > 0 ? "MCP serving on 127.0.0.1:\(port)" : "MCP server off"
    }

    static func tooltip(_ sessions: Int, _ port: Int) -> String {
        "\(StatusItemController.appName) — \(sessionsLabel(sessions))" + (port > 0 ? " · MCP :\(port)" : "")
    }

    @objc private func open(_ sender: Any?) { onOpen?() }
    @objc private func hide(_ sender: Any?) { onHide?() }

    /// A schematic resistor on the diagonal — two leads and a zigzag body — as a template
    /// image, so the menu bar tints it for light, dark and highlighted states.
    public static func glyph() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.rotate(by: .pi / 4)
            ctx.translateBy(x: -s / 2, y: -s / 2)
            let y = s / 2
            let amplitude = s * 0.17
            let path = NSBezierPath()
            path.move(to: NSPoint(x: s * 0.06, y: y))
            path.line(to: NSPoint(x: s * 0.27, y: y))
            let teeth = 6
            let step = (s * 0.46) / CGFloat(teeth)
            for i in 0..<teeth {
                path.line(to: NSPoint(x: s * 0.27 + step * (CGFloat(i) + 0.5), y: y + (i % 2 == 0 ? amplitude : -amplitude)))
            }
            path.line(to: NSPoint(x: s * 0.73, y: y))
            path.line(to: NSPoint(x: s * 0.94, y: y))
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = StatusItemController.appName
        return image
    }
}
