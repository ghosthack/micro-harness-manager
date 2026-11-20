import Foundation

/// Finds a session's conversation transcript on disk, for the `list` tool. May block for a
/// moment (Codex is found through `lsof`); never throws.
///
/// - project: the session's project directory
/// - harnessSessionId: the harness's own conversation id when known
/// - paneProcessId: the PID of the session's shell, or -1
public typealias TranscriptLocator = (_ harness: HarnessType, _ project: URL, _ harnessSessionId: String?,
                                      _ paneProcessId: Int64) -> URL?

public enum TranscriptLocators {
    public static let none: TranscriptLocator = { _, _, _, _ in nil }
}

/// The transcript locations the app knows:
/// - Codex: the rollout file its process has open (found from the pane's process tree, see
///   `CodexSessionNameResolver.transcript`);
/// - Claude Code: its per-project JSONL directory (`ClaudeProjects`): the session's own
///   `<id>.jsonl` when the id is known (nothing until Claude has written it), else the
///   project's newest file — which the caller must not present as this session's when other
///   Claude sessions share the project;
/// - Muse: the `session.jsonl` of the session directory whose lock its process holds open
///   (`MuseSessions`);
/// - Grok: the `chat_history.jsonl` of the session its process registered in
///   `active_sessions.json` (`GrokSessions`).
/// Other harnesses have none (yet).
public final class HarnessTranscripts: @unchecked Sendable {

    private let claudeProjects: URL
    private let codex: CodexSessionNameResolver
    private let muse: (Int64) -> URL?
    private let grok: (Int64) -> URL?

    /// - muse: a pane's Muse transcript, from the pane's shell pid
    /// - grok: a pane's Grok transcript, from the pane's shell pid
    public init(_ claudeProjects: URL, _ codex: CodexSessionNameResolver,
                _ muse: @escaping (Int64) -> URL? = { _ in nil }, _ grok: @escaping (Int64) -> URL? = { _ in nil }) {
        self.claudeProjects = claudeProjects
        self.codex = codex
        self.muse = muse
        self.grok = grok
    }

    /// `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR/projects`), the default Codex home,
    /// Muse's sessions under its data directory and `$GROK_HOME`.
    public static func standard() -> HarnessTranscripts {
        let museRoot = MuseSessions.root()
        let grokHome = GrokSessions.home()
        let museLocator = OpenFileLocator.overLsof(MuseSessions.isExecutable) { MuseSessions.transcriptOf(museRoot, $0) }
        return HarnessTranscripts(ClaudeProjects.root(), CodexSessionNameResolver(),
                                  { museLocator.apply($0) }, { grokTranscript(grokHome, $0) })
    }

    /// The newest transcript of the Grok processes under the pane.
    static func grokTranscript(_ grokHome: URL, _ paneProcessId: Int64) -> URL? {
        OpenFileLocator.processes(paneProcessId, GrokSessions.isExecutable)
            .compactMap { GrokSessions.transcript(grokHome, $0.pid, $0.startMillis) }
            .max { (PathCompat.lastModifiedMillis($0) ?? 0) < (PathCompat.lastModifiedMillis($1) ?? 0) }
    }

    /// As a `TranscriptLocator`.
    public var locator: TranscriptLocator {
        { [self] harness, project, id, pid in transcript(harness, project, id, pid) }
    }

    public func transcript(_ harness: HarnessType, _ project: URL, _ harnessSessionId: String?,
                           _ paneProcessId: Int64) -> URL? {
        switch harness {
        case .codex: return codex.transcript(paneProcessId)
        case .claudeCode: return claude(project, harnessSessionId)
        case .muse: return paneProcessId > 0 ? muse(paneProcessId) : nil
        case .grok: return paneProcessId > 0 ? grok(paneProcessId) : nil
        default: return nil
        }
    }

    private func claude(_ project: URL, _ harnessSessionId: String?) -> URL? {
        if let id = harnessSessionId {
            // never another session's file: a known id whose conversation has no message
            // yet has no transcript
            return ClaudeProjects.transcript(claudeProjects, project, id)
        }
        return ClaudeProjects.newest(claudeProjects, project)
    }
}
