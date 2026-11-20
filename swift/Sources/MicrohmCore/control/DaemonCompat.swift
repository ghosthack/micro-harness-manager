import Foundation
import MicrohmMux
import MicrohmShared

/// What the running daemon is known not to support. The daemon outlives app upgrades — it
/// keeps running until its last session ends — so the controller may talk to one that
/// predates input, wait, watch or annotated capture. The first refusal of a feature
/// (`isUnsupported`) is remembered for that daemon, identified by the pid its ping
/// reports, so the controller stops asking and takes its fallback at once; everything is
/// forgotten once a different daemon (or none) answers.
///
/// Thread-safe; never holds its lock across a daemon round trip.
final class DaemonCompat: @unchecked Sendable {

    /// A protocol feature newer daemons have and old ones refuse.
    enum Feature: String {
        case ANNOTATED_CAPTURE, INPUT, WAIT, WATCH
    }

    private let pidSource: () throws -> Int64?
    private let lock = NSLock()
    private var missing: Set<Feature> = []
    /// The daemon `missing` describes; -1 = unknown (its ping did not answer).
    private var missingPid: Int64 = -1

    init(_ pid: @escaping () throws -> Int64?) {
        self.pidSource = pid
    }

    /// Whether `error` is a daemon's refusal of an op it predates.
    static func isUnsupported(_ error: Error) -> Bool {
        (error as? SessionServerException)?.isUnsupported ?? false
    }

    /// Whether `feature` is worth trying: not known to be missing from the running daemon.
    func has(_ feature: Feature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !missing.contains(feature)
    }

    /// The old daemon's pid as its ping reported it, -1 when unknown.
    func pid() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return missingPid
    }

    /// Records that the running daemon refused `feature`; true the first time (for this
    /// daemon), so the caller can log it once.
    @discardableResult
    func markMissing(_ feature: Feature) -> Bool {
        let current = ping()
        lock.lock(); defer { lock.unlock() }
        if missing.isEmpty {
            missingPid = current
        }
        let first = missing.insert(feature).inserted
        if first && missing.count == 1 {
            Log.info("the running daemon (pid \(missingPid)) predates \(feature.rawValue); micro-harness-manager "
                     + "falls back until it is replaced (once every session has ended)", tag: "control")
        }
        return first
    }

    /// Forgets what was missing once the daemon that lacked it is gone: a different pid (or
    /// none) answers the ping. A no-op — no round trip — while nothing is missing.
    func revalidate() {
        lock.lock()
        if missing.isEmpty {
            lock.unlock()
            return
        }
        let known = missingPid
        lock.unlock()
        let current = ping()
        lock.lock(); defer { lock.unlock() }
        if current < 0 || current != known {
            if !missing.isEmpty {
                Log.info("the daemon changed (pid \(known) -> \(current < 0 ? "none" : String(current))); trying "
                         + "every feature again", tag: "control")
            }
            missing.removeAll()
            missingPid = -1
        }
    }

    private func ping() -> Int64 {
        ((try? pidSource()) ?? nil) ?? -1
    }
}
