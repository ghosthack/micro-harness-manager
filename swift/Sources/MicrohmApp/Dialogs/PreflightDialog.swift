import AppKit
import MicrohmCore

/// The shared confirmation for actions that end a session (Java's `PreflightDialog`): one
/// copy and layout for every entry point, so the toolbar, the menus and the keyboard never
/// drift into different confirmations. Cancel is the default button — Return never ends a
/// session by accident.
enum PreflightDialog {

    /// One affected session as the review list shows it.
    struct Session {
        let displayName: String
        let sessionName: String
        let status: String

        init(_ entry: SidebarEntry) {
            displayName = entry.displayName
            sessionName = entry.sessionName
            status = entry.statusPhrase
        }

        var label: String {
            let name = displayName == sessionName ? displayName : "\(displayName) (\(sessionName))"
            return "\(name) — \(status)"
        }
    }

    struct Request {
        let title: String
        let prompt: String
        let sessions: [Session]
        let consequence: String
        let confirmLabel: String
        let destructive: Bool

        static func kill(_ session: Session) -> Request {
            Request(title: "Kill session", prompt: "Kill “\(session.displayName)”?", sessions: [session],
                    consequence: "This kills the session and ends the harness process inside it. "
                        + "Any unsaved terminal work is lost, and this cannot be undone.",
                    confirmLabel: "Kill Session", destructive: true)
        }

        static func close(_ session: Session) -> Request {
            Request(title: "Close session", prompt: "Close “\(session.displayName)” gracefully?", sessions: [session],
                    consequence: "\(AppModel.appName) will ask the harness and its shell to exit. If the session "
                        + "closes, its terminal and scrollback cannot be restored, but its saved entry remains "
                        + "available to Resume. If it is busy or does not exit in time, it is left running.",
                    confirmLabel: "Close Session", destructive: false)
        }

        static func reload(_ session: Session) -> Request {
            Request(title: "Reload session", prompt: "Reload “\(session.displayName)”?", sessions: [session],
                    consequence: "\(AppModel.appName) will ask the harness and its shell to exit, then immediately "
                        + "relaunch the harness in a fresh session, resuming its conversation where it left off. "
                        + "Useful after the harness auto-updates and needs a restart to pick up the new version. "
                        + "If it is busy or does not exit in time, it is left running.",
                    confirmLabel: "Reload Session", destructive: false)
        }

        static func closeAll(_ sessions: [Session]) -> Request {
            Request(title: "Close all sessions",
                    prompt: "Close \(sessions.count == 1 ? "the live session" : "all \(sessions.count) live sessions")?",
                    sessions: sessions,
                    consequence: "Each harness is asked to exit gracefully. A closed terminal and its scrollback "
                        + "cannot be restored, but every saved entry remains available to Resume. Busy sessions "
                        + "and sessions that do not exit in time are left running and reported afterward.",
                    confirmLabel: "Close All", destructive: false)
        }
    }

    /// Shows `request` as a sheet on `window` (app-modal without one) and reports the answer.
    static func present(_ request: Request, on window: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard !request.sessions.isEmpty else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = request.destructive ? .critical : .warning
        alert.messageText = request.prompt
        alert.informativeText = request.consequence
        let confirm = alert.addButton(withTitle: request.confirmLabel)
        let cancel = alert.addButton(withTitle: "Cancel")
        confirm.hasDestructiveAction = request.destructive
        // Cancel stays the default: Return must never end a session by accident
        confirm.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.accessoryView = review(request.sessions)
        if let window, window.attachedSheet == nil, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// The affected sessions: a plain list for a few, a scrolling one for many.
    private static func review(_ sessions: [Session]) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for session in sessions {
            let label = NSTextField(wrappingLabelWithString: "• " + session.label)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.preferredMaxLayoutWidth = 280
            rows.addArrangedSubview(label)
        }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        box.contentViewMargins = .zero
        let height = min(170, rows.fittingSize.height)
        if sessions.count <= 6 {
            box.contentView = rows
            box.frame = NSRect(x: 0, y: 0, width: 300, height: rows.fittingSize.height)
            return box
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 284, height: rows.fittingSize.height))
        rows.frame = document.bounds
        rows.autoresizingMask = [.width]
        document.addSubview(rows)
        scroll.documentView = document
        box.contentView = scroll
        box.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        return box
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Rename: a custom sidebar name, or Clear to go back to the harness's own.
enum RenameSheet {
    enum Choice {
        case rename(String)
        case clear
        case cancel
    }

    static func present(on window: NSWindow, current: String, inherited: String,
                        completion: @escaping (Choice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Inherited from the harness: \(inherited)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = current
        field.placeholderString = inherited
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.rename(field.stringValue))
            case .alertThirdButtonReturn: completion(.clear)
            default: completion(.cancel)
            }
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }
}
