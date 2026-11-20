import Foundation

/// The controller's own view of one session's state: a `StateDetector` for the session's
/// harness, fed by every capture the controller takes (reads, keys, list, the monitor),
/// independent of the sidebar poller's.
///
/// A fresh detector has no history, so its first look at a long-idle session would say
/// "screen output changing" (WORKING). Before that first look the tracker asks the daemon
/// how long the output has already been quiet (a non-blocking quiet probe) and backdates
/// the detector's baseline by that much, so an idle session reads as idle at once.
final class SessionTracker: @unchecked Sendable {

    /// The quiet probe: has the session produced no output for this long, right now?
    typealias QuietProbe = (TimeInterval) -> Bool

    let harness: HarnessType
    let plugin: HarnessPlugin
    private let clock: OffsetClock
    private let detector: StateDetector
    private let shortQuiescence: TimeInterval
    private let longQuiescence: TimeInterval
    private var primed = false
    private let lock = NSLock()

    init(_ harness: HarnessType, _ base: MicrohmClock, _ shortQuiescence: TimeInterval, _ longQuiescence: TimeInterval) {
        self.harness = harness
        self.plugin = HarnessPlugins.of(harness)
        self.clock = OffsetClock(base)
        self.detector = StateDetector(plugin, clock, shortQuiescence, longQuiescence)
        self.shortQuiescence = shortQuiescence
        self.longQuiescence = longQuiescence
    }

    /// Classifies `screen` (plain text), priming the detector on its first real look.
    func classify(_ screen: Screen, _ probe: QuietProbe) -> Classification {
        lock.lock(); defer { lock.unlock() }
        if !primed && !screen.paneDead && !atShell(screen.foregroundCommand) {
            primed = true
            let quiet: TimeInterval = probe(longQuiescence) ? longQuiescence
                : probe(shortQuiescence) ? shortQuiescence : 0
            if quiet != 0 {
                clock.offset = -quiet
                _ = detector.classify(screen) // sets the baseline, backdated
                clock.offset = 0
            }
        }
        return detector.classify(screen)
    }

    /// The plain-text `Screen` for an annotated capture.
    static func screen(_ plainText: String, _ alive: Bool, _ at: Date, _ foreground: String?, _ pid: Int64,
                       _ title: String?) -> Screen {
        Screen(plainText, !alive, at, foreground ?? "", pid, title ?? "")
    }

    /// Whether the harness's process is running in the pane (a shell harness always is once
    /// its shell is in the foreground).
    func harnessRunning(_ foreground: String?) -> Bool {
        guard let foreground, !foreground.isEmpty else { return false }
        return plugin.ownsProcess(foreground)
    }

    /// Whether a shell, not the harness, is in the foreground — the harness exited or never
    /// started (never true for the shell harness, which owns its shell).
    func atShell(_ foreground: String?) -> Bool {
        guard let foreground, !foreground.isEmpty else { return false }
        return !plugin.ownsProcess(foreground) && StateDetector.isShell(foreground)
    }

    /// The controller's clock shifted by `offset` — only ever non-zero while `classify`
    /// primes the detector, under the tracker's lock.
    private final class OffsetClock: MicrohmClock, @unchecked Sendable {
        private let base: MicrohmClock
        var offset: TimeInterval = 0

        init(_ base: MicrohmClock) {
            self.base = base
        }

        func instant() -> Date {
            base.instant().addingTimeInterval(offset)
        }
    }
}
