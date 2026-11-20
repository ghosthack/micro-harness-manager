import Foundation

/// Creates and kills sessions on behalf of agents, the way the window does — registered,
/// labelled, MCP-injected and announced to the sidebar. The production implementation is
/// `LauncherSpawner`; tests use a fake. Calls block and may throw.
public protocol SessionSpawner: AnyObject {

    /// Starts `request` on the daemon and returns the new session's name.
    func spawn(_ request: SpawnRequest) throws -> String

    /// Ends the session (no-op when already gone) and drops it from the sidebar.
    func kill(_ session: String) throws

    /// Starts an ended registered session again under its name, resuming its conversation
    /// when it has one, as the window's Resume does.
    func resume(_ entry: SessionEntry) throws
}

public extension SessionSpawner {
    func resume(_ entry: SessionEntry) throws {
        throw SessionHostException("resume is not supported")
    }
}

/// - project: an existing directory
/// - displayName: the sidebar name, when the agent gave one
/// - labels: extra daemon labels
public struct SpawnRequest: Equatable, Sendable {
    public let harness: HarnessType
    public let project: URL
    public let displayName: String?
    public let labels: [String: String]

    public init(_ harness: HarnessType, _ project: URL, _ displayName: String?, _ labels: [String: String]) {
        self.harness = harness
        self.project = project
        self.displayName = displayName
        self.labels = labels
    }
}

/// The production `SessionSpawner`: launches through the window's own `SessionLauncher`
/// (so the session is named, registered, labelled and MCP-injected exactly like one opened
/// from the toolbar), then tells the window through `SessionEvents` so the sidebar picks it
/// up without stealing focus.
public final class LauncherSpawner: SessionSpawner, @unchecked Sendable {

    private let launcher: SessionLauncher
    private let host: SessionHost
    private let events: SessionEvents

    public init(_ launcher: SessionLauncher, _ host: SessionHost, _ events: SessionEvents) {
        self.launcher = launcher
        self.host = host
        self.events = events
    }

    public func spawn(_ request: SpawnRequest) throws -> String {
        let name = try launcher.create(request.project, request.harness, nil, request.displayName, request.labels)
        events.fireSessionsChanged(name)
        return name
    }

    public func resume(_ entry: SessionEntry) throws {
        // the window lets go of the ended run's terminal first, as its own Resume does
        events.fireSessionRunEnded(entry.sessionName)
        try launcher.resume(entry, {})
        events.fireSessionsChanged(entry.sessionName)
    }

    public func kill(_ session: String) throws {
        try host.killSession(session)
        launcher.discardMcpConfig(session)
        events.fireSessionKilled(session)
    }
}
