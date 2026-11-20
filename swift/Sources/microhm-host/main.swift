import AppKit
import Foundation
import MicrohmCore
import MicrohmStatusItem

// The background host (Java's `McpHost`), and with `--phone-only` the phone page on its own
// (Java's `PhoneMain`). See `McpHost`.
//
// The host proper blocks while it watches the sessions, so it runs on a thread of its own;
// the main thread runs an accessory (no Dock icon) NSApplication for the menu-bar icon, and
// the process exits with the host's status when the host returns.
setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

if args.contains(McpHost.PHONE_ONLY_FLAG) {
    exit(McpHost.main(args))
}

/// Puts `StatusItemController` (main-thread AppKit) behind the host's thread-agnostic hook.
final class MenuBarIcon: HostStatusIcon {
    private let item = StatusItemController()

    init(onOpen: @escaping () -> Void, onHide: @escaping () -> Void) {
        DispatchQueue.main.sync {
            item.onOpen = onOpen
            item.onHide = onHide
            item.show()
        }
    }

    func update(liveSessions: Int, mcpPort: Int?, phonePort: Int?) {
        DispatchQueue.main.async { self.item.update(liveSessions: liveSessions, mcpPort: mcpPort, phonePort: phonePort) }
    }

    func remove() {
        if Thread.isMainThread { item.remove() } else { DispatchQueue.main.sync { self.item.remove() } }
    }
}

McpHost.statusIconFactory = { onOpen, onHide in MenuBarIcon(onOpen: onOpen, onHide: onHide) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Thread.detachNewThread {
    let status = McpHost.main(args)
    DispatchQueue.main.async { exit(status) }
}
app.run()
