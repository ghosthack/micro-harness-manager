import Foundation

/// What the phone page can do with the sessions. In the app it is the session controller
/// behind the MCP tools (`PhoneBackends.of`), so the phone sees and drives sessions exactly
/// as an agent does; tests give a fake.
public protocol PhoneBackend: AnyObject {

    /// The running sessions; throws when the daemon does not answer.
    func sessions() throws -> [SessionController.SessionSummary]

    /// One session's screen; nil once it has exited; throws with a message for the user
    /// when no session matches.
    func screen(_ session: String) throws -> SessionController.ScreenView?

    /// Resizes `session`'s terminal, for every viewer.
    func resize(_ session: String, _ columns: Int, _ rows: Int) throws

    /// `session`'s screen with its styles, to draw in colour; nil when unavailable.
    func ansi(_ session: String) throws -> SessionController.AnsiView?

    /// Scrollback added after the first `since` lines (0: all still held); nil when there
    /// is none to give.
    func history(_ session: String, _ since: Int64) throws -> SessionController.HistoryView?

    /// Saved sessions that are not running, newest first.
    func ended() throws -> [SessionController.EndedSession]

    /// Starts an ended session again, resuming its conversation; returns its name. Throws
    /// with a message for the user when it cannot.
    func resume(_ session: String) throws -> String

    /// Why `session` cannot be closed right now, or nil when it can.
    func closeBlocker(_ session: String) throws -> String?

    /// Closes `session` politely, as the window's Close does; refuses rather than
    /// interrupting work.
    func close(_ session: String) throws -> PhoneCloser.Outcome

    /// Runs `send`, `keys` or `spawn` with MCP-style arguments.
    func call(_ tool: String, _ arguments: CoreJSON) -> ToolResult
}

public extension PhoneBackend {
    func ansi(_ session: String) throws -> SessionController.AnsiView? {
        nil
    }
}

public enum PhoneBackends {

    /// The phone page over `controller`, closing through `closer`.
    public static func of(_ controller: SessionController, _ closer: PhoneCloser) -> PhoneBackend {
        ControllerBackend(controller, closer)
    }

    private final class ControllerBackend: PhoneBackend, @unchecked Sendable {
        let controller: SessionController
        let closer: PhoneCloser

        init(_ controller: SessionController, _ closer: PhoneCloser) {
            self.controller = controller
            self.closer = closer
        }

        /// The session's name, harness and state, as the closer needs them.
        private func live(_ session: String) throws -> (String, HarnessType, SessionState?) {
            guard let view = try controller.screen(session) else {
                throw SessionHostException(session + " has already ended")
            }
            return (view.name, (try? HarnessType.fromId(view.harness)) ?? .shell, SessionState(rawValue: view.state))
        }

        func closeBlocker(_ session: String) throws -> String? {
            let (name, harness, state) = try live(session)
            return closer.blocker(name, harness, state)
        }

        func close(_ session: String) throws -> PhoneCloser.Outcome {
            let (name, harness, state) = try live(session)
            return closer.close(name, harness, state)
        }

        func sessions() throws -> [SessionController.SessionSummary] {
            try controller.summaries()
        }

        func screen(_ session: String) throws -> SessionController.ScreenView? {
            try controller.screen(session)
        }

        func resize(_ session: String, _ columns: Int, _ rows: Int) throws {
            try controller.resize(session, columns, rows)
        }

        func ansi(_ session: String) throws -> SessionController.AnsiView? {
            try controller.ansi(session)
        }

        func history(_ session: String, _ since: Int64) throws -> SessionController.HistoryView? {
            try controller.history(session, since)
        }

        func ended() throws -> [SessionController.EndedSession] {
            try controller.ended()
        }

        func resume(_ session: String) throws -> String {
            try controller.resume(session)
        }

        func call(_ tool: String, _ arguments: CoreJSON) -> ToolResult {
            // no caller: the phone is not a session, so nothing is "your own session" and a
            // spawned session carries no spawned-by label
            controller.call(nil, tool, arguments)
        }
    }
}

/// Close for the phone page: the window's polite close (`GracefulCloser`), with its
/// refusals. It never closes a session whose agent is working or waiting for you, or that
/// has a program running in front; otherwise it asks the agent to quit, then the shell to
/// exit, and keeps the conversation's id so Resume picks it up again.
public final class PhoneCloser: @unchecked Sendable {

    /// `message` explains a refusal or a close that did not finish.
    public struct Outcome: Equatable, Sendable {
        public let closed: Bool
        public let message: String

        public init(_ closed: Bool, _ message: String) {
            self.closed = closed
            self.message = message
        }
    }

    private let closer: GracefulCloser
    private let registry: SessionRegistry
    private let events: SessionEvents

    public convenience init(_ host: SessionHost, _ registry: SessionRegistry, _ events: SessionEvents) {
        self.init(GracefulCloser(host, 0.25, 10, 5), registry, events)
    }

    init(_ closer: GracefulCloser, _ registry: SessionRegistry, _ events: SessionEvents) {
        self.closer = closer
        self.registry = registry
        self.events = events
    }

    /// Why `session` cannot be closed now, or nil when it can (nothing is sent).
    public func blocker(_ session: String, _ harness: HarnessType, _ state: SessionState?) -> String? {
        do {
            guard let result = try closer.preflight(session, HarnessPlugins.of(harness), state),
                  result.outcome != .alreadyGone else {
                return nil
            }
            return PhoneCloser.explain(result, state)
        } catch {
            return "Couldn't check it: " + errorMessage(error)
        }
    }

    public func close(_ session: String, _ harness: HarnessType, _ state: SessionState?) -> Outcome {
        let result: GracefulCloser.Result
        do {
            result = try closer.close(session, HarnessPlugins.of(harness), state)
        } catch {
            return Outcome(false, "Couldn't close it: " + errorMessage(error))
        }
        if let id = result.harnessSessionIdOpt {
            registry.recordHarnessSessionId(session, id)
        }
        let closed = result.outcome == .closed || result.outcome == .alreadyGone
        if closed {
            events.fireSessionRunEnded(session)
            return Outcome(true, "Closed")
        }
        events.fireSessionsChanged(nil)
        return Outcome(false, PhoneCloser.explain(result, state))
    }

    /// The phone's words for why a close did not happen.
    static func explain(_ result: GracefulCloser.Result, _ state: SessionState?) -> String {
        switch result.outcome {
        case .busyState:
            return state == .working ? "It's still working. Close it once it's done."
                : state == .waitingForInput ? "It's waiting for you. Answer it first, or stop it with ^C."
                : "Its status isn't known yet. Try again in a moment."
        case .busyForeground:
            return "'" + result.detail + "' is still running in it. Stop that first."
        case .noQuitSyntax:
            return result.detail + " has no safe way to be asked to quit. Close it from Microhm on the Mac."
        case .quitTimeout:
            return "Sent " + result.detail + ", but the agent didn't exit in time. It's still running."
        case .exitTimeout:
            return "Sent exit, but the shell didn't end in time. Something may still be running in it."
        case .closed, .alreadyGone:
            return "Closed"
        }
    }
}
