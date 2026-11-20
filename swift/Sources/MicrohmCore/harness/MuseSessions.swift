import Foundation

/// Where Muse keeps its conversations: one directory per session,
/// `<root>/YYYY/MM/DD/<session id>/`, holding the session's event log `session.jsonl`
/// (JSONL; the assistant's replies are its `assistant_message_committed` events) next to
/// locks, databases and sub-agent folders. The root is `$XDG_DATA_HOME/muse/sessions`,
/// else `~/.local/share/muse/sessions`. A running Muse holds its session directory's
/// `.session.lock` open, which is how a pane's session is told from the others.
public enum MuseSessions {

    /// The event log in a session directory.
    public static let transcriptName = "session.jsonl"

    private static let sessionId = JRegex("[A-Za-z0-9-]+")
    private static let year = JRegex(#"\d{4}"#)
    private static let twoDigits = JRegex(#"\d{2}"#)

    /// `$XDG_DATA_HOME/muse/sessions`, else `~/.local/share/muse/sessions`.
    public static func root() -> URL {
        let base: URL
        if let data = PathCompat.env("XDG_DATA_HOME"), !JavaText.isBlank(data) {
            base = URL(fileURLWithPath: data)
        } else {
            base = PathCompat.userHome.appendingPathComponent(".local").appendingPathComponent("share")
        }
        return base.appendingPathComponent("muse").appendingPathComponent("sessions")
    }

    /// Whether an executable's file name is Muse's (`muse`, or the versioned
    /// `muse-bin-<version>` its launcher runs).
    public static func isExecutable(_ fileName: String) -> Bool {
        fileName == "muse" || fileName.hasPrefix("muse-")
    }

    /// The `session.jsonl` of the session directory `open` is in (its lock, its log or
    /// anything below it), when that log exists; nil for any file outside a dated session
    /// directory under `root` (the index database, the view caches, …).
    public static func transcriptOf(_ root: URL, _ open: URL) -> URL? {
        let base = PathCompat.normalize(root)
        let file = PathCompat.normalize(open)
        if !PathCompat.startsWith(file, base) {
            return nil
        }
        let relative = Array(PathCompat.components(file).dropFirst(PathCompat.components(base).count))
        // YYYY / MM / DD / <id> / <something in it>
        if relative.count < 5
            || !year.matches(relative[0])
            || !twoDigits.matches(relative[1])
            || !twoDigits.matches(relative[2])
            || !sessionId.matches(relative[3]) {
            return nil
        }
        var transcript = base
        for part in relative[0..<4] {
            transcript.appendPathComponent(part)
        }
        transcript.appendPathComponent(transcriptName)
        return PathCompat.isRegularFile(transcript) ? transcript : nil
    }
}
