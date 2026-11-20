import Foundation

/// Where Claude Code keeps its conversations: one JSONL per session id in a per-project
/// directory, `<root>/<project path with every non-alphanumeric character replaced by
/// '-'>` (older builds replaced only `/` and `.`, so both are tried). The root is
/// `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`; `rootOverride` replaces it
/// (tests — Java's `microhm.claudeProjects` system property).
public enum ClaudeProjects {

    /// Replaces `root()` when set (tests).
    nonisolated(unsafe) public static var rootOverride: URL?

    private static let sessionId = JRegex("[A-Za-z0-9-]+")

    /// `rootOverride` when set, else `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`.
    public static func root() -> URL {
        if let o = rootOverride {
            return o
        }
        let configDir = PathCompat.env("CLAUDE_CONFIG_DIR")
        let claude = configDir.map { !JavaText.isBlank($0) } == true
            ? URL(fileURLWithPath: configDir!)
            : PathCompat.userHome.appendingPathComponent(".claude")
        return claude.appendingPathComponent("projects")
    }

    /// The project's existing transcript directory under `root`, if any.
    public static func directory(_ root: URL, _ project: URL) -> URL? {
        let absolute = PathCompat.normalize(project).path
        for dirName in [replaceUnits(absolute) { !isAsciiAlphanumeric($0) },
                        replaceUnits(absolute) { $0 == 0x2F || $0 == 0x2E }] {
            let dir = root.appendingPathComponent(dirName)
            if PathCompat.isDirectory(dir) {
                return dir
            }
        }
        return nil
    }

    /// The transcript of session `id` in `project`, if Claude has written it.
    public static func transcript(_ root: URL, _ project: URL, _ id: String) -> URL? {
        if !sessionId.matches(id) {
            return nil
        }
        guard let dir = directory(root, project) else { return nil }
        let file = dir.appendingPathComponent(id + ".jsonl")
        return PathCompat.isRegularFile(file) ? file : nil
    }

    /// The project's most recently written transcript — any session's.
    public static func newest(_ root: URL, _ project: URL) -> URL? {
        guard let dir = directory(root, project), let files = PathCompat.list(dir) else {
            return nil
        }
        return files
            .filter { $0.lastPathComponent.hasSuffix(".jsonl") && PathCompat.isRegularFile($0) }
            .max { (PathCompat.lastModifiedMillis($0) ?? 0) < (PathCompat.lastModifiedMillis($1) ?? 0) }
    }

    private static func isAsciiAlphanumeric(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
    }

    /// Replaces each UTF-16 unit `matching` with '-' — Java's (and Claude Code's own JS)
    /// regex replace works on UTF-16 units, so a non-BMP character becomes "--".
    private static func replaceUnits(_ s: String, _ matching: (UInt16) -> Bool) -> String {
        let units = s.utf16.map { matching($0) ? UInt16(0x2D) : $0 }
        return String(decoding: units, as: UTF16.self)
    }
}
