import Foundation

/// Bootstrap + state-detection patterns for the cursor-agent CLI. Adapted from an
/// earlier six-state detector's `CursorAgentPlugin`: same regexes, collapsed onto the
/// manager's 3-state `SessionState` the same way `ClaudeCodePlugin` is. Resume, quit,
/// and exit-receipt syntax are grounded against Cursor Agent 2026.08.11-e8db854:
/// `--resume [chatId]`, `/quit`, and the emitted
/// `To resume this session: cursor-agent --resume=<chatId>` breadcrumb.
public final class CursorAgentPlugin: HarnessPlugin, @unchecked Sendable {

    static let patternsVersion = "2026-08-17.5"

    private static let approval = JRegex(
        #"(?i)(\[y/n]|\(y/n\)|\by/N\b|\byes/no\b|allow this|allow\?"#
            + #"|run this command|run command\?|press enter to (confirm|continue|approve)"#
            + #"|do you want to (run|proceed|continue|allow)"#
            + #"|[▸❯>]\s*(yes|allow|approve))"#)

    private static let idleInputBox = JRegex(
        #"(?i)(^\s*[❯>]\s*$|type a message|add a follow-up|send a message)"#)

    private static let backgroundTasks = JRegex(#"(?i)^\s*\d+\s+tasks?\s*$"#)

    private static let inputLine = JRegex(
        #"(?i)(add a follow-up|type a message|send a message|^\s*[❯>]\s*$)"#)

    private static let broken = JRegex(
        #"(?i)(cursor-agent: command not found|panic:|traceback \(most recent call last\)"#
            + #"|segmentation fault|fatal error)"#)

    private static let questionWidget = JRegex(
        #"(?i)(enter next/submit|space select|\(type to answer\)|[›▸]\s*\[[ x]\])"#)

    private static let chrome = JRegex(
        #"(?i)(^\s*[→▸❯>]?\s*(add a follow-up|type a message|send a message)"#
            + #"|\s·\s"#
            + #"|ctrl\+\w"#
            + #"|^\s*tip:"#
            + #"|^\s*[/~]\S*\s*$"#
            + #"|^\s*[⠀-⣿]+\s*working)"#)

    /// The command name reflects how the binary was invoked; accept both official
    /// entry points while still requiring Cursor's complete exit-receipt prefix.
    private static let exitResume = JRegex(
        #"(?is)To resume this session:\s*(?:cursor-agent|agent)\s+--resume(?:=|\s+)"#
            + #"(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_@%+:,./-]+))"#)

    public init() {}

    public var type: HarnessType { .cursorAgent }

    public func launchCommand() -> String { "cursor-agent" }

    public func resumeCommand(_ harnessSessionId: String) -> String? {
        "cursor-agent --resume=" + HarnessPlugins.shellArgument(harnessSessionId)
    }

    public func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? {
        lastExitSelector(CursorAgentPlugin.exitResume, exitScreen.text)
    }

    public func quitCommand() -> String? { "/quit" }

    /// Drops chrome lines: the follow-up input box, hint and tip lines, the bare cwd
    /// line and the spinner's "working" row.
    public func maskChrome(_ screenText: String) -> String {
        ScreenMask.mask(stripVolatile(screenText)) { CursorAgentPlugin.chrome.find($0) }
    }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(15)
        let tailText = tail.joined(separator: "\n")
        let v = CursorAgentPlugin.patternsVersion

        if CursorAgentPlugin.broken.find(tailText) {
            return Classification(.idle, .high,
                                  "error signature on screen — cursor-agent likely crashed (patterns \(v))", .plugin)
        }
        if CursorAgentPlugin.approval.find(tailText) {
            return Classification(.waitingForInput, .high, "approval prompt shape (patterns \(v))", .plugin)
        }
        if CursorAgentPlugin.questionWidget.find(tailText) {
            return Classification(.waitingForInput, .high, "question selector widget (patterns \(v))", .plugin)
        }
        let content = tail.filter { !CursorAgentPlugin.chrome.find($0) }
        if let last = content.last, JavaText.hasSuffix(JavaText.stripTrailing(last), "?") {
            return Classification(.waitingForInput, .high,
                                  "quiescent with trailing question above UI chrome (patterns \(v))", .plugin)
        }
        var lastInput = -1
        for (i, line) in tail.enumerated() where CursorAgentPlugin.inputLine.find(line) {
            lastInput = i
        }
        if lastInput >= 0 && tail[(lastInput + 1)...].contains(where: { CursorAgentPlugin.backgroundTasks.find($0) }) {
            return Classification(.working, .high,
                                  "main idle but background tasks running (patterns \(v))", .plugin)
        }
        if tail.contains(where: { CursorAgentPlugin.idleInputBox.find($0) }) {
            return Classification(.idle, .high, "empty input box (patterns \(v))", .plugin)
        }
        return nil
    }
}
