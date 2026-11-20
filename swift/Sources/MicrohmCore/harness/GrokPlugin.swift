import Foundation

/// Bootstrap + state-detection patterns for xAI's Grok CLI (`grok`), collapsed onto this
/// app's 3-state `SessionState` the same way `ClaudeCodePlugin` and `CodexPlugin` are.
/// There was no earlier plugin to adapt this from, so everything here was grounded
/// directly against a live `grok 1.0.5 (5115b46bc909) [stable]` pane (macOS, 120x40) or,
/// where noted, the installed binary's own string table when a live render could not be
/// produced.
///
/// Grok prints a clock timestamp flush-right on the same line as each chat bubble
/// (e.g. `"Hi. What would you like to work on?                    6:04 PM"`), which none
/// of the other three harnesses do — `stripTrailingClock` removes it before the
/// trailing-question check, or every quiescent turn ending in "?" would instead end in a
/// time and never match.
public final class GrokPlugin: HarnessPlugin, @unchecked Sendable {

    static let patternsVersion = "2026-08-23.1"

    // "grok 1.0.5 (5115b46bc909) [stable]": Resume this session with:
    //   grok --resume <session-id>
    // Captured verbatim from a real /quit — see harnessSessionIdFromExit below.
    private static let exitResume = JRegex(
        #"(?is)Resume this session with:\s*grok\s+--resume\s+"#
            + #"(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_@%+=:,./-]+))"#)

    /// The foreground probe, like `pane_current_command`, truncates to 15 bytes; the
    /// launcher execs the downloaded versioned binary, so a live pane reports
    /// "grok-1.0.5-maco" rather than "grok" — verified live at 1.0.5.
    private static let versionedBinary = JRegex(#"grok-\d.*"#)

    /// The status line while a turn is in flight reads e.g. "Waiting for response… 1.0s",
    /// "Responding… 0.0s", or "Thinking… 0.2s", and the composer's hint bar swaps in
    /// "Esc:cancel" for the duration — all verified live. Since the elapsed-time counter
    /// on that status line ticks every poll, `StateDetector`'s behavioral layer already
    /// reads WORKING without consulting this plugin; this is the same safety net
    /// `CodexPlugin`'s workingIndicator is, for a turn whose render freezes.
    private static let workingIndicator = JRegex(#"(?i)(esc:cancel|(waiting for response|responding|thinking)…)"#)

    /// Derived from the installed 1.0.5 binary's own string table
    /// (`xai_grok_pager::app::acp_handler::permissions`), which lists the approval
    /// headings verbatim: "Allow Edit?", "Allow Delete?", "Allow Execute?", "Allow?", and
    /// "Allow `<command>`?" for a shell command. Not confirmed against a live render —
    /// this install's global settings auto-approve every tool call, so the dialog never
    /// painted during grounding. An over-match here only adds WAITING_FOR_INPUT, the
    /// "needs you" badge, so the safe direction is the same one `CodexPlugin`'s
    /// string-table-derived patterns take.
    private static let approval = JRegex(
        #"(?i)(allow (edit|delete|execute)\?|allow edit to\b|allow `[^`]*`\?|allow\?)"#)

    /// Grok's own death, both shell phrasings, plus generic crash signatures — the same
    /// narrow BROKEN shape `CodexPlugin` and `CursorAgentPlugin` use, so a command a
    /// running Grok happens to run that itself isn't found doesn't get folded in.
    private static let broken = JRegex(
        #"(?i)(grok: command not found|command not found: grok(?![\w-])"#
            + #"|panic:|segmentation fault|fatal error)"#)

    /// UI furniture stripped before the trailing-question check: the composer's rounded
    /// border and side rails, the echoed input caret, transient "◆ Thought for …s" /
    /// "◆ Creating …" tool-activity rows, the per-turn "Worked for …s" footer, and the
    /// hint-bar legends — all verified live.
    private static let chrome = JRegex(
        #"(?i)(^\s*[╭╮╰╯│]"#
            + #"|^\s*❯"#
            + #"|^\s*◆"#
            + #"|shift\+tab:mode"#
            + #"|ctrl\+x:shortcuts"#
            + #"|esc:cancel"#
            + #"|enter:send"#
            + #"|^\s*worked for [0-9.]+s\s*$"#
            // the in-flight status row, e.g. "⠙ Responding… 3.6s   10s ⇣1.68k [stop]"
            + #"|^\s*[⠀-⣿]\s"#
            + #"|\[stop\]\s*$"#
            // the header's context counter, e.g. "1.3K / 256K │ [Dashboard]"
            + #"|\d[\d.]*[km]? / \d[\d.]*[km]\b"#
            // the "more above" arrow of the scrolled answer pane
            + #"|^\s*[▲▼]\s*$)"#)

    /// The answer pane's scrollbar: a block in the last column of the rows it spans,
    /// which moves as the pane scrolls — verified live at 120 columns.
    private static let scrollbar = JRegex(#"\s*[█▐▌]\s*$"#)

    /// The idle hint bar carries both legends with no "Esc:cancel" between them —
    /// verified live as "Shift+Tab:mode  │  Ctrl+x:shortcuts".
    private static let idleHint = JRegex(#"(?i)shift\+tab:mode.*ctrl\+x:shortcuts"#)

    /// A clock timestamp Grok right-pads onto the same line as each chat bubble, e.g.
    /// "...work on?                    6:04 PM" — verified live. Stripped before the
    /// trailing-question check; see the class comment.
    private static let trailingClock = JRegex(#"\s{2,}\d{1,2}:\d{2}\s?[AaPp][Mm]\s*$"#)

    public init() {}

    public var type: HarnessType { .grok }

    public func launchCommand() -> String { "grok" }

    public func ownsProcess(_ foregroundCommand: String) -> Bool {
        foregroundCommand == "grok" || GrokPlugin.versionedBinary.matches(foregroundCommand)
    }

    /// `grok --resume <id>` — the `-r, --resume` flag documented by `grok --help` and,
    /// independently, the exact syntax a real `/quit` printed back (see
    /// `harnessSessionIdFromExit`).
    public func resumeCommand(_ harnessSessionId: String) -> String? {
        "grok --resume " + HarnessPlugins.shellArgument(harnessSessionId)
    }

    public func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? {
        lastExitSelector(GrokPlugin.exitResume, exitScreen.text)
    }

    /// `/quit` — verified live via the composer's own slash-command autocomplete
    /// ("/quit  Quit the application"), and the bundled docs list `/exit` as an alias.
    /// `/quit` is used here for the same unambiguous-over-alias reasoning `CodexPlugin`
    /// gives for preferring it over `/exit`.
    public func quitCommand() -> String? { "/quit" }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(20)
        let tailText = tail.joined(separator: "\n")

        if GrokPlugin.broken.find(tailText) {
            return GrokPlugin.classified(.idle, "error signature on screen — grok likely crashed")
        }
        if GrokPlugin.workingIndicator.find(tailText) {
            return GrokPlugin.classified(.working, "esc-to-cancel visible: turn still running despite quiescent screen")
        }
        if GrokPlugin.approval.find(tailText) {
            return GrokPlugin.classified(.waitingForInput, "allow/deny approval prompt shape")
        }
        let content = tail
            .map(GrokPlugin.stripTrailingClock)
            .filter { !GrokPlugin.chrome.find($0) }
        if let last = content.last, JavaText.hasSuffix(JavaText.stripTrailing(last), "?") {
            return GrokPlugin.classified(.waitingForInput, "quiescent with trailing question above UI chrome")
        }
        if tail.contains(where: { GrokPlugin.idleHint.find($0) }) {
            return GrokPlugin.classified(.idle, "idle hint bar, no running-turn indicator")
        }
        return nil
    }

    /// Each bubble's flush-right clock stripped (see `trailingClock`), then every chrome
    /// line dropped — the composer box, hint bars, activity and status rows, the context
    /// counter and the "Worked for Ns" footer — and the scrollbar column cut.
    public func maskChrome(_ screenText: String) -> String {
        ScreenMask.join(ScreenMask.lines(stripVolatile(screenText))
            .map { GrokPlugin.stripTrailingClock(GrokPlugin.scrollbar.replaceAll($0, with: "")) }
            .filter { !GrokPlugin.chrome.find(ScreenMask.plain($0)) })
    }

    private static func stripTrailingClock(_ line: String) -> String {
        trailingClock.replaceAll(line, with: "")
    }

    private static func classified(_ state: SessionState, _ reason: String) -> Classification {
        Classification(state, .high, reason + " (patterns \(patternsVersion))", .plugin)
    }
}
