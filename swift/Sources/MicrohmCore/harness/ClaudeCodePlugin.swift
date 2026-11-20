import Foundation

/// Bootstrap + state-detection patterns for the Claude Code CLI. Adapted from an
/// earlier six-state detector's `ClaudeCodePlugin`: same regexes, collapsed onto the
/// manager's 3-state `SessionState` (approval and question both read WAITING_FOR_INPUT;
/// the error-signature check folds into IDLE since there's no separate "broken" badge
/// here). These patterns rot with harness UI updates the same way they do upstream —
/// nil falls back to the generic behavioral heuristics.
public final class ClaudeCodePlugin: HarnessPlugin, @unchecked Sendable {

    static let patternsVersion = "2026-11-20.1"

    private static let workingIndicator = JRegex(#"(?i)esc to interrupt"#)

    private static let approval = JRegex(
        #"(?i)(do you want to|don't ask again|[❯›]?\s*1\.\s*yes\b"#
            + #"|allow this|\[y/n]|\(y/n\))"#)

    private static let optionSelector = JRegex(#"[❯›]\s*\d+\.\s"#)
    /// The footer under Claude Code's unnumbered menus, the folder trust prompt among them
    /// (`❯ No, exit` / `Yes, I trust this folder`), which `optionSelector` misses.
    private static let menuFooter = JRegex(#"(?i)enter to confirm\s*·\s*esc to (cancel|exit|go back)"#)

    private static let backgroundWork = JRegex(#"(?im)(·\s*\d+\s+shells?\s*·|^\s*◯\s+\S+)"#)

    private static let inputLine = JRegex(#"(^[\s ]*❯|^[\s ]*│[\s ]*>)"#)

    private static let idleStatus = JRegex(
        #"(shift\+tab to cycle|\? for shortcuts|auto mode on|accept edits on"#
            + #"|^[\s ]*│?[\s ]*>[\s ]*│?[\s ]*$"#
            + #"|^[\s ]*❯[\s ]*$)"#)

    // Narrow on purpose, as in CodexPlugin: a coding agent's screen is full of "panic:",
    // "fatal error" and tracebacks from the commands it runs, and reading those as a crash
    // marks a working (or asking) session idle, which Close then types /exit into. Only
    // claude's own absence counts, in both shell spellings.
    private static let broken = JRegex(
        #"(?i)(claude: command not found|command not found: claude(?![\w-]))"#)

    private static let versionedBinary = JRegex(#"\d+\.\d+\.\d+"#)

    /// Claude Code prints this receipt after /exit. The selector is normally a UUID,
    /// but a renamed session is printed as a quoted name and is equally resumable.
    private static let exitResume = JRegex(
        #"(?is)Resume this session with:\s*claude\s+--resume\s+"#
            + #"(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_@%+=:,./-]+))"#)

    // box-drawing borders (input box and dialogs), horizontal rules, hint bars,
    // the bare input caret, and the emoji status line
    private static let chrome = JRegex(
        #"(?i)(^\s*[╭╰│⏵❯]|^\s*─+\s*$|\? for shortcuts|esc to |shift\+tab"#
            + #"|auto-accept|plan mode|bypass permissions|tokens?\s*$|📁|🧠)"#)

    /// Whether `node` counts as this harness (see `ownsProcess`).
    private let windows: Bool

    public convenience init() {
        self.init(windows: Platform.isWindows())
    }

    /// `windows` is injectable so both branches of `ownsProcess` have a unit test
    /// regardless of the platform the suite runs on.
    init(windows: Bool) {
        self.windows = windows
    }

    public var type: HarnessType { .claudeCode }

    public func processName() -> String { "claude" }

    // the launcher execs the versioned binary, so the foreground probe reports e.g. "2.1.235"; on
    // Windows the npm shim runs node.exe as the shell's child instead, so the
    // foreground is "node" there — as broad as PiPlugin's check, for the same reason
    public func ownsProcess(_ foregroundCommand: String) -> Bool {
        foregroundCommand == "claude"
            || ClaudeCodePlugin.versionedBinary.matches(foregroundCommand)
            || windows && foregroundCommand == "node"
    }

    public func launchCommand() -> String { "claude" }

    public func resumeCommand(_ harnessSessionId: String) -> String? {
        "claude --resume " + HarnessPlugins.shellArgument(harnessSessionId)
    }

    /// `claude --session-id <uuid>`: Claude Code names the new conversation (and its
    /// transcript, `<id>.jsonl`) after the id it is given.
    public func launchCommandWithId(_ harnessSessionId: String) -> String? {
        "claude --session-id " + HarnessPlugins.shellArgument(harnessSessionId)
    }

    /// Claude Code writes `<id>.jsonl` with the conversation's first message; before
    /// that, `--resume <id>` fails with "No conversation found".
    public func canResume(_ harnessSessionId: String, _ project: URL) -> Bool {
        ClaudeProjects.transcript(ClaudeProjects.root(), project, harnessSessionId) != nil
    }

    public func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? {
        lastExitSelector(ClaudeCodePlugin.exitResume, exitScreen.text)
    }

    /// `claude --mcp-config <file>` — the file form of `--mcp-config`, which adds to
    /// (never replaces) the user's own servers for this run. The file (`mcpConfigFile`)
    /// carries the URL and the bearer token as an `Authorization` header, so the token
    /// stays out of the typed line. Inserted right after the leading `claude` so a
    /// resume's `--resume <id>` still follows it; `--mcp-config` takes a list of values,
    /// and the next `--` option is what ends that list.
    public func withMcpServer(_ command: String, _ endpoint: McpEndpoint) -> String {
        ScreenMask.insertAfterProgram(command, "claude",
                                      "--mcp-config " + HarnessPlugins.shellArgument(endpoint.configFile.path))
    }

    /// `{"mcpServers":{"micro-harness-manager":{"type":"http","url":…,"headers":{"Authorization":"Bearer …"}}}}`.
    public func mcpConfigFile(_ endpoint: McpEndpoint) -> String? {
        "{\"mcpServers\":{" + ScreenMask.quoted(HarnessPlugins.mcpServerName)
            + ":{\"type\":\"http\",\"url\":" + ScreenMask.quoted(endpoint.url)
            + ",\"headers\":{\"Authorization\":" + ScreenMask.quoted("Bearer " + endpoint.token)
            + "}}}}\n"
    }

    /// Drops chrome lines: the input box, rules, hint bars and the spinner line (its "esc
    /// to interrupt" hint), so a ticking turn timer is not a content change.
    public func maskChrome(_ screenText: String) -> String {
        ScreenMask.mask(stripVolatile(screenText), ClaudeCodePlugin.isChrome)
    }

    /// `/exit` ends the Claude Code session from its idle prompt.
    public func quitCommand() -> String? { "/exit" }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(20)
        let tailText = tail.joined(separator: "\n")
        let v = ClaudeCodePlugin.patternsVersion

        if ClaudeCodePlugin.broken.find(tailText) {
            return Classification(.idle, .high,
                                  "error signature on screen — claude likely crashed (patterns \(v))", .plugin)
        }
        if ClaudeCodePlugin.workingIndicator.find(tailText) {
            return Classification(.working, .high,
                                  "esc-to-interrupt visible: turn still running despite quiescent screen (patterns \(v))",
                                  .plugin)
        }
        if ClaudeCodePlugin.approval.find(tailText) {
            return Classification(.waitingForInput, .high, "permission dialog shape (patterns \(v))", .plugin)
        }
        if ClaudeCodePlugin.optionSelector.find(tailText) || ClaudeCodePlugin.menuFooter.find(tailText) {
            return Classification(.waitingForInput, .high, "option selector widget (patterns \(v))", .plugin)
        }
        let content = tail.filter { !ClaudeCodePlugin.isChrome($0) }
        if let last = content.last, JavaText.hasSuffix(JavaText.stripTrailing(last), "?") {
            return Classification(.waitingForInput, .high,
                                  "quiescent with trailing question above UI chrome (patterns \(v))", .plugin)
        }
        var lastInput = -1
        for (i, line) in tail.enumerated() where ClaudeCodePlugin.inputLine.find(line) {
            lastInput = i
        }
        if lastInput >= 0 {
            let belowInput = tail[(lastInput + 1)...].joined(separator: "\n")
            if ClaudeCodePlugin.backgroundWork.find(belowInput) {
                return Classification(.working, .high,
                                      "main idle but subagents/background work running (patterns \(v))", .plugin)
            }
        }
        if tail.contains(where: { ClaudeCodePlugin.idleStatus.find($0) }) {
            return Classification(.idle, .high,
                                  "idle status bar, no running-turn indicator (patterns \(v))", .plugin)
        }
        return nil
    }

    private static func isChrome(_ line: String) -> Bool {
        chrome.find(line)
    }
}
