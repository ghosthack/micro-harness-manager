import Foundation

/// java.time.Clock, as far as the detector and the poller need it: the current instant.
/// Tests inject a mutable one.
public protocol MicrohmClock: AnyObject {
    func instant() -> Date
}

/// The wall clock.
public final class SystemClock: MicrohmClock, @unchecked Sendable {
    public static let shared = SystemClock()
    public init() {}
    public func instant() -> Date { Date() }
}

/// Behavioral-first state detection, ported from harness-manager's `StateDetector`. The
/// core signal is screen quiescence, which survives harness UI updates; the per-harness
/// plugin's textual patterns only refine a quiescent screen. Stateful: tracks the last
/// screen across calls, so one instance belongs to exactly one session —
/// `SessionStatusPoller` keeps a map of these, one per polled session, so quiescence
/// timing survives across polls.
public final class StateDetector: @unchecked Sendable {

    /// If the pane's foreground process is one of these while the harness is supposed to
    /// be running, the harness has exited and left a shell prompt behind — quiescent, but
    /// not the same "idle" as a harness sitting at its own prompt. Folded into IDLE (this
    /// app doesn't have a fourth badge color), with a reason that says so. The last three
    /// are the Windows shells the Java daemon spawns (its foreground probe reports names
    /// lower-cased with `.exe` stripped).
    private static let shells: Set<String> =
        ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "pwsh", "powershell", "cmd"]

    /// Public because it answers "is this pane at a bare prompt?" for more than state
    /// detection: `ShellPlugin` claims shells as its own process, and graceful close uses
    /// it to decide between quitting a harness and exiting a shell.
    public static func isShell(_ foregroundCommand: String) -> Bool {
        shells.contains(foregroundCommand)
    }

    private let plugin: HarnessPlugin
    private let clock: MicrohmClock
    private let shortQuiescence: TimeInterval
    private let longQuiescence: TimeInterval
    private let lock = NSLock()

    private var lastText: String?
    private var lastChange = Date(timeIntervalSince1970: 0)

    /// Quiescence thresholds are in seconds.
    public init(_ plugin: HarnessPlugin, _ clock: MicrohmClock, _ shortQuiescence: TimeInterval,
                _ longQuiescence: TimeInterval) {
        self.plugin = plugin
        self.clock = clock
        self.shortQuiescence = shortQuiescence
        self.longQuiescence = longQuiescence
    }

    /// Whether an ordinary screen has been captured to compare the next one against.
    public func hasScreenBaseline() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lastText != nil
    }

    /// Locked: callers serialize per session (SessionStatusPoller's in-flight guard), but
    /// consecutive polls run on different threads — this puts the lastText/lastChange
    /// handoff between them beyond doubt. Uncontended in practice.
    @discardableResult
    public func classify(_ screen: Screen) -> Classification {
        lock.lock(); defer { lock.unlock() }
        if screen.paneDead {
            return Classification(.idle, .high, "pane dead or session gone", .behavioral)
        }
        let foreground = screen.foregroundCommand
        if !foreground.isEmpty && !plugin.ownsProcess(foreground) && StateDetector.isShell(foreground) {
            return Classification(.idle, .high,
                                  "pane is at a \(foreground) prompt: the \(plugin.processName())"
                                      + " process is not running (never started, exited, or crashed)",
                                  .behavioral)
        }
        let now = clock.instant()
        let comparable = plugin.stripVolatile(screen.text)
        // compared code point by code point, as Java's equals does — Swift's == would
        // treat canonically equivalent text as unchanged
        if lastText.map({ !$0.unicodeScalars.elementsEqual(comparable.unicodeScalars) }) ?? true {
            lastText = comparable
            lastChange = now
            return Classification(.working, .high, "screen output changing", .behavioral)
        }
        let quiet = now.timeIntervalSince(lastChange)
        let quietSeconds = Int64(quiet.rounded(.towardZero))
        if quiet < shortQuiescence {
            return Classification(.working, .medium,
                                  "quiescent only \(quietSeconds)s, may still be working", .behavioral)
        }
        if let refined = plugin.classifyQuiescent(screen, quiet) {
            return refined
        }
        if quiet >= longQuiescence {
            return Classification(.idle, .high,
                                  "quiescent \(quietSeconds)s, generic behavioral fallback", .behavioral)
        }
        return Classification(.idle, .low, "quiescent \(quietSeconds)s but no pattern matched", .behavioral)
    }
}
