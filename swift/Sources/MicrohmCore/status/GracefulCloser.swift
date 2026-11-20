import Foundation

/// Cmd+W's "close tab, but politely": ends a session by asking the processes inside to
/// quit themselves — the harness via its own quit command, then the shell underneath via
/// `exit` — instead of a kill's SIGHUP. Refuses outright when anything is still in
/// progress: an agent mid-turn or waiting on an approval, or a foreground program the
/// user started (caffeinate, vim, a build) — closing would kill work in flight, which is
/// exactly what "graceful" must never do.
///
/// Blocking (captures, quit-then-wait polling loops with real sleeps) — call from a
/// background queue, never the main thread. One-shot and stateless across calls, so a
/// single instance serves every session.
///
/// The busy checks are two layers deep because each sees what the other can't: the
/// poller's last `SessionState` knows a quiescent-looking harness is actually mid-turn
/// (its patterns read "esc to interrupt"), while the fresh foreground-process check knows
/// about programs the poller files under generic idle (caffeinate produces no output and
/// polls as IDLE forever). The poll state is up to one poll interval stale — accepted:
/// the window between an agent starting a turn and Cmd+W landing inside that same
/// interval is small, and the cost of the miss is a `/exit` typed into a running turn's
/// composer, not data loss.
public final class GracefulCloser: @unchecked Sendable {

    public enum Outcome: String, Sendable {
        /// The session ended; safe to drop its runtime UI artifacts.
        case closed = "CLOSED"
        /// The pane/session was already gone before anything was sent — same cleanup.
        case alreadyGone = "ALREADY_GONE"
        /// Refused: the harness is working or waiting on the human, or its status has
        /// never been polled (an unknown harness state must not have quit text typed
        /// into it blind).
        case busyState = "BUSY_STATE"
        /// Refused: a foreground program that is neither the harness nor a shell is
        /// still running; detail carries its process name.
        case busyForeground = "BUSY_FOREGROUND"
        /// Refused: this harness has no verified quit syntax and one must not be
        /// guessed — the caller should point at Kill session instead.
        case noQuitSyntax = "NO_QUIT_SYNTAX"
        /// The quit command was sent but the harness outlived the timeout. Nothing was
        /// cleaned up — the session is intact, just still running.
        case quitTimeout = "QUIT_TIMEOUT"
        /// `exit` was sent to the shell but the session outlived the timeout (a stray
        /// background child keeping the shell alive, say).
        case exitTimeout = "EXIT_TIMEOUT"
    }

    /// `detail` is the human-facing specifics: the busy foreground's name, the quit
    /// command that went unanswered — whatever the outcome needs to explain itself.
    public struct Result: Equatable, Sendable {
        public let outcome: Outcome
        public let detail: String
        public let harnessSessionId: String?

        public init(_ outcome: Outcome, _ detail: String, _ harnessSessionId: String? = nil) {
            self.outcome = outcome
            self.detail = detail
            self.harnessSessionId = harnessSessionId
        }

        public var harnessSessionIdOpt: String? {
            guard let id = harnessSessionId, !JavaText.isBlank(id) else { return nil }
            return id
        }
    }

    private struct Inspection {
        let terminalResult: Result?
        let screen: Screen?
    }

    /// A successful harness-exit wait. `screen` is the returned shell screen, or nil when
    /// exiting the harness ended the entire session.
    private struct HarnessExit {
        let screen: Screen?
    }

    private let host: StatusSessionHost
    private let pollInterval: TimeInterval
    private let quitTimeout: TimeInterval
    private let exitTimeout: TimeInterval

    /// Intervals in seconds.
    public init(_ host: StatusSessionHost, _ pollInterval: TimeInterval, _ quitTimeout: TimeInterval,
                _ exitTimeout: TimeInterval) {
        self.host = host
        self.pollInterval = pollInterval
        self.quitTimeout = quitTimeout
        self.exitTimeout = exitTimeout
    }

    /// Performs the read-only half of `close`: returns the result that would stop the
    /// close before any input is sent, or nil when it is safe to offer the user a
    /// confirmation. The actual close repeats the inspection after confirmation because
    /// pane state can change while the dialog is open.
    public func preflight(_ session: String, _ plugin: HarnessPlugin, _ lastPolled: SessionState?) throws -> Result? {
        try inspect(session, plugin, lastPolled).terminalResult
    }

    /// `lastPolled` is the poller's latest state for this session, or nil if none has
    /// landed yet — nil refuses unless the pane is at a bare shell prompt, where the
    /// foreground check alone is definitive.
    public func close(_ session: String, _ plugin: HarnessPlugin, _ lastPolled: SessionState?) throws -> Result {
        let inspection = try inspect(session, plugin, lastPolled)
        if let terminal = inspection.terminalResult {
            return terminal
        }
        let screen = inspection.screen!
        let foreground = screen.foregroundCommand
        var harnessSessionId = StateDetector.isShell(foreground) ? plugin.harnessSessionIdFromExit(screen) : nil
        if !StateDetector.isShell(foreground) {
            // inspect() proved that a verified quit command exists on this path.
            let quit = plugin.quitCommand()!
            try host.sendKeys(session, quit)
            guard let harnessExit = try awaitHarnessGone(session) else {
                return Result(.quitTimeout, quit)
            }
            if let exitScreen = harnessExit.screen {
                harnessSessionId = plugin.harnessSessionIdFromExit(exitScreen) ?? harnessSessionId
            }
        }
        // The pane is (now) a bare shell — or the whole session already collapsed with
        // the harness, when the harness was the session's root process rather than a
        // shell's child.
        if try host.hasSession(session) {
            try host.sendKeys(session, "exit")
            if !(try awaitCondition(exitTimeout, { try !self.host.hasSession(session) })) {
                return Result(.exitTimeout, session, harnessSessionId)
            }
        }
        return Result(.closed, session, harnessSessionId)
    }

    /// One fresh, non-mutating safety inspection shared by pre-flight and execution.
    private func inspect(_ session: String, _ plugin: HarnessPlugin, _ lastPolled: SessionState?) throws -> Inspection {
        if let lastPolled, lastPolled == .working || lastPolled == .waitingForInput {
            return Inspection(terminalResult: Result(.busyState, "session is \(lastPolled.name)"), screen: nil)
        }
        let screen = try host.capture(session)
        if screen.paneDead {
            return Inspection(terminalResult: Result(.alreadyGone, "pane already dead"), screen: screen)
        }
        let foreground = screen.foregroundCommand
        if !foreground.isEmpty && !plugin.ownsProcess(foreground) && !StateDetector.isShell(foreground) {
            return Inspection(terminalResult: Result(.busyForeground, foreground), screen: screen)
        }
        if !StateDetector.isShell(foreground) {
            // The harness itself is in the foreground (or the host couldn't say — treated
            // the same, since typing quit text blind is the risk being managed here).
            if lastPolled == nil {
                return Inspection(terminalResult: Result(.busyState, "status not yet polled — try again in a moment"),
                                  screen: screen)
            }
            if plugin.quitCommand() == nil {
                return Inspection(terminalResult: Result(.noQuitSyntax, plugin.type.id), screen: screen)
            }
        }
        return Inspection(terminalResult: nil, screen: screen)
    }

    /// Waits until the harness hands the pane back to its shell, retaining that exact
    /// screen so provider-specific exit metadata can be recovered before shell exit
    /// destroys the session and its scrollback. Nil means the timeout elapsed.
    private func awaitHarnessGone(_ session: String) throws -> HarnessExit? {
        let deadline = DispatchTime.now().uptimeNanoseconds + GracefulCloser.nanos(quitTimeout)
        while true {
            if !(try host.hasSession(session)) {
                return HarnessExit(screen: nil)
            }
            let screen = try host.capture(session)
            if screen.paneDead {
                return HarnessExit(screen: nil)
            }
            if StateDetector.isShell(screen.foregroundCommand) {
                return HarnessExit(screen: screen)
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return nil
            }
            pause()
        }
    }

    private func awaitCondition(_ timeout: TimeInterval, _ check: () throws -> Bool) throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + GracefulCloser.nanos(timeout)
        while true {
            if try check() {
                return true
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return false
            }
            pause()
        }
    }

    private func pause() {
        Thread.sleep(forTimeInterval: pollInterval)
    }

    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}
