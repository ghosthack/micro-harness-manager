import Foundation

/// The three sidebar-badge buckets the manager cares about. Trimmed from a
/// six-value `HarnessState` (which also has `WAITING_FOR_APPROVAL`/`WAITING_FOR_QUESTION`
/// split out, and a `BROKEN` state) — this app doesn't nudge or babysit, it just shows a
/// badge, so approval and question collapse into one "needs you" bucket, and a
/// harness that crashed but left its session alive folds into IDLE (still gray; the
/// tooltip reason says why).
///
/// Raw values are the Java enum names (what `toString()` printed there).
public enum SessionState: String, CaseIterable, Sendable, CustomStringConvertible {
    case working = "WORKING"
    case waitingForInput = "WAITING_FOR_INPUT"
    case idle = "IDLE"

    /// The Java enum constant name.
    public var name: String { rawValue }
    public var description: String { rawValue }
}

/// Detector confidence. The manager doesn't gate any action on it, but it's useful in
/// the tooltip and in tests.
public enum Confidence: String, CaseIterable, Sendable, CustomStringConvertible {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"

    public var name: String { rawValue }
    public var description: String { rawValue }
}

/// Result of one detector pass over a captured screen. `origin` records whether a
/// harness plugin's textual pattern recognized the screen or the generic behavioral
/// heuristic (screen quiescence) produced the state. Adapted from an earlier six-state
/// detector's `Classification`, dropping `textAnswerable` — that field only matters to
/// code that types an answer back in, which this app never does.
public struct Classification: Equatable, Sendable {
    public enum Origin: String, Sendable {
        case behavioral = "BEHAVIORAL"
        case plugin = "PLUGIN"
    }

    public let state: SessionState
    public let confidence: Confidence
    public let reason: String
    public let origin: Origin

    public init(_ state: SessionState, _ confidence: Confidence, _ reason: String, _ origin: Origin) {
        self.state = state
        self.confidence = confidence
        self.reason = reason
        self.origin = origin
    }
}
