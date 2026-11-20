import Foundation

/// Where Grok keeps its conversations: `<home>/sessions/<URL-encoded cwd>/<session id>/`,
/// whose `chat_history.jsonl` is the conversation (JSONL rows of `"type"` `system`,
/// `user`, `assistant` and `tool_result`). A running Grok registers itself in
/// `<home>/active_sessions.json` — its pid, its start time in microseconds
/// (`pid_start`), its cwd and its session id — which is how a pane's session is found
/// without guessing. The home is `$GROK_HOME`, else `~/.grok`.
public enum GrokSessions {

    /// The conversation in a session directory.
    public static let transcriptName = "chat_history.jsonl"

    /// How far a registered start time may be from the process's own and still be it.
    static let startToleranceMillis: Int64 = 2_000

    private static let sessionId = JRegex("[A-Za-z0-9-]+")

    /// `$GROK_HOME`, else `~/.grok`.
    public static func home() -> URL {
        if let home = PathCompat.env("GROK_HOME"), !JavaText.isBlank(home) {
            return URL(fileURLWithPath: home)
        }
        return PathCompat.userHome.appendingPathComponent(".grok")
    }

    /// Whether an executable's file name is Grok's (`grok`, or the versioned
    /// `grok-<version>-<platform>` it links to).
    public static func isExecutable(_ fileName: String) -> Bool {
        fileName == "grok" || fileName.hasPrefix("grok-")
    }

    /// The transcript of the Grok process `pid` (started at `startMillis`, 0 = unknown),
    /// when it is registered in `active_sessions.json` and its `chat_history.jsonl`
    /// exists. A registration with the same pid but another start time is a process that
    /// held the pid before, not this one.
    public static func transcript(_ home: URL, _ pid: Int64, _ startMillis: Int64) -> URL? {
        let registry = home.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: registry),
              let sessions = try? CoreJSON.parse(data), sessions.isArray else {
            return nil
        }
        for session in sessions.elements {
            if session.path("pid").asLong(-1) != pid {
                continue
            }
            let registeredMillis = session.path("pid_start").asLong(0) / 1000
            if startMillis > 0 && registeredMillis > 0
                && abs(registeredMillis - startMillis) > startToleranceMillis {
                continue
            }
            let id = session.path("session_id").asText("") ?? ""
            if sessionId.matches(id), let found = sessionTranscript(home.appendingPathComponent("sessions"), id) {
                return found
            }
        }
        return nil
    }

    /// `<sessions>/<any cwd folder>/<id>/chat_history.jsonl`: the id is unique, so the cwd
    /// folder's encoding never has to be reproduced.
    private static func sessionTranscript(_ sessions: URL, _ id: String) -> URL? {
        guard let folders = PathCompat.list(sessions) else { return nil }
        return folders
            .map { $0.appendingPathComponent(id).appendingPathComponent(transcriptName) }
            .first(where: PathCompat.isRegularFile)
    }
}
