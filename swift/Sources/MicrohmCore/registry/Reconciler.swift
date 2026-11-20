import Foundation

/// Result of diffing the registry against what the daemon actually has running.
///
/// - `liveManaged`: registry entries whose session is alive right now
/// - `deadRegistered`: registry entries whose session is gone — shown dead/resumable
public struct ReconciliationResult: Equatable, Sendable {
    public let liveManaged: [SessionEntry]
    public let deadRegistered: [SessionEntry]

    public init(liveManaged: [SessionEntry], deadRegistered: [SessionEntry]) {
        self.liveManaged = liveManaged
        self.deadRegistered = deadRegistered
    }
}

/// Startup (and on-demand refresh) reconciliation: the daemon's live list diffed against
/// the registry. A pure function of its inputs — the caller reads the registry and the
/// host — so it needs no live daemon to test and this package does not depend on `host`.
public enum Reconciler {

    /// Every session this app owns is named with this prefix.
    public static let sessionPrefix = "mhm-"

    public static func reconcile(_ registered: [SessionEntry], _ liveSessions: [String]) -> ReconciliationResult {
        let live = Set(liveSessions)
        var liveManaged: [SessionEntry] = []
        var deadRegistered: [SessionEntry] = []
        for entry in registered {
            if live.contains(entry.sessionName) {
                liveManaged.append(entry)
            } else {
                deadRegistered.append(entry)
            }
        }
        return ReconciliationResult(liveManaged: liveManaged, deadRegistered: deadRegistered)
    }
}
