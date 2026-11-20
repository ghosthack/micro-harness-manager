import Foundation

/// One managed session: the daemon session that hosts it, the harness running inside
/// it, and enough to resume that harness conversation later. Conceptually the mapping is
/// harness-session -> daemon session; in practice they are 1-1, so `sessionName` (always
/// `mhm-`-prefixed) is the registry's key. Rows are only ever rebuilt through the
/// with-ers or `newlyCreated`, so no flow can silently drop a field on the way through.
public struct SessionEntry: Equatable, Sendable {
    public let sessionName: String
    public let projectPath: String
    public let harnessType: HarnessType
    public let harnessSessionId: String?
    public let createdAt: Date
    public let displayName: String?

    public init(_ sessionName: String, _ projectPath: String, _ harnessType: HarnessType,
                _ harnessSessionId: String?, _ createdAt: Date, _ displayName: String? = nil) {
        self.sessionName = sessionName
        self.projectPath = projectPath
        self.harnessType = harnessType
        self.harnessSessionId = harnessSessionId
        self.createdAt = createdAt
        self.displayName = displayName
    }

    /// Returns a copy with a persisted sidebar name. Blank means use the live pane title
    /// (when present), then fall back to the session name.
    public func withDisplayName(_ displayName: String?) -> SessionEntry {
        let normalized = displayName.flatMap { JavaText.isBlank($0) ? nil : JavaText.strip($0) }
        return SessionEntry(sessionName, projectPath, harnessType, harnessSessionId, createdAt, normalized)
    }

    /// Returns a copy associated with the provider conversation recovered at exit.
    public func withHarnessSessionId(_ harnessSessionId: String?) -> SessionEntry {
        let normalized = harnessSessionId.flatMap { JavaText.isBlank($0) ? nil : JavaText.strip($0) }
        return SessionEntry(sessionName, projectPath, harnessType, normalized, createdAt, displayName)
    }

    /// `harnessSessionId` is optional (blank/nil means "no resume id recorded yet").
    public var harnessSessionIdOpt: String? {
        guard let id = harnessSessionId, !JavaText.isBlank(id) else { return nil }
        return id
    }

    /// New entry for a session created just now. The timestamp is kept to whole
    /// milliseconds so it survives the registry's ISO-8601 round trip exactly.
    public static func newlyCreated(_ sessionName: String, _ projectPath: String,
                                    _ harnessType: HarnessType, _ harnessSessionId: String?) -> SessionEntry {
        let millis = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        return SessionEntry(sessionName, projectPath, harnessType, harnessSessionId,
                            Date(timeIntervalSince1970: Double(millis) / 1000), nil)
    }
}
