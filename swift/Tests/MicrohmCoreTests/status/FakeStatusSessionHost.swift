import Foundation
@testable import MicrohmCore

/// In-memory `StatusSessionHost` (the slice of Java's `host.FakeSessionHost` that status
/// polling and graceful close use): the test sets up live sessions and screens directly;
/// no process is ever spawned.
final class FakeStatusSessionHost: StatusSessionHost, @unchecked Sendable {

    struct NoSuchSession: Error, CustomStringConvertible {
        let session: String
        var description: String { "no such session: \(session)" }
    }

    private var sessions: [String] = []
    var sentCommands: [String] = []
    var captureCalls: [String] = []
    private var currentScreen: [String: Screen] = [:]

    /// Invoked with `"session: command"` after each successful `sendKeys` — lets a test
    /// script the pane's reaction to input.
    var onSendKeys: (String) -> Void = { _ in }

    func seedLiveSession(_ session: String) {
        if !sessions.contains(session) { sessions.append(session) }
    }

    /// Sets what `capture` returns for `session` until changed again, keeping its
    /// foreground command.
    func screen(_ session: String, _ text: String) {
        screen(session, text, (currentScreen[session] ?? blank()).foregroundCommand)
    }

    func screen(_ session: String, _ text: String, _ foregroundCommand: String) {
        // title survives text updates, same as the daemon (OSC titles outlive redraws)
        let current = currentScreen[session] ?? blank()
        currentScreen[session] = Screen(text, false, epoch, foregroundCommand, current.paneProcessId, current.paneTitle)
    }

    func paneTitle(_ session: String, _ title: String) {
        let c = currentScreen[session] ?? blank()
        currentScreen[session] = Screen(c.text, c.paneDead, c.capturedAt, c.foregroundCommand, c.paneProcessId, title)
    }

    func paneProcessId(_ session: String, _ processId: Int64) {
        let c = currentScreen[session] ?? blank()
        currentScreen[session] = Screen(c.text, c.paneDead, c.capturedAt, c.foregroundCommand, processId, c.paneTitle)
    }

    /// The session's process exited on its own.
    func endSession(_ session: String) {
        sessions.removeAll { $0 == session }
    }

    private func blank() -> Screen {
        Screen("", false, epoch, "")
    }

    func hasSession(_ session: String) throws -> Bool {
        sessions.contains(session)
    }

    func sendKeys(_ session: String, _ command: String) throws {
        guard sessions.contains(session) else { throw NoSuchSession(session: session) }
        sentCommands.append(session + ": " + command)
        onSendKeys(session + ": " + command)
    }

    func capture(_ session: String) throws -> Screen {
        captureCalls.append(session)
        if !sessions.contains(session) {
            return Screen("", true, epoch, "")
        }
        return currentScreen[session] ?? blank()
    }
}
