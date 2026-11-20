import Foundation

/// Bootstrap + state-detection patterns for opencode's `opencode` CLI, collapsed onto this
/// app's 3-state `SessionState` the same way `ClaudeCodePlugin`, `CodexPlugin`, and
/// `GrokPlugin` are. There was no earlier plugin to adapt this from either, so everything
/// here was grounded directly against a live `opencode 1.18.21` pane (macOS, 120x40): a
/// fresh launch, a shell-command turn and a file-edit turn each driven through both an
/// "Allow once" approval and a "Reject", a trailing-question turn, a crash, and two real
/// `/exit`s.
///
/// Two things make opencode differ from the other three plugins:
///
/// - Its composer is a persistent bordered box drawn at the bottom of the screen in every
///   state — working, idle, and mid-approval all show it — so, unlike `CodexPlugin`'s
///   configurable footer, the box itself is never the signal; only the line(s) below its
///   bottom border (`╹▀▀▀…`) change between states, and that border is what
///   `contentLines` cuts on rather than matching the footer text.
/// - The permission dialog replaces the composer with its own bordered box rather than
///   drawing over it, headed "Permission required" with a "# Shell command" or
///   "→ Edit <file>" subheading depending on the tool, and three buttons — "Allow once",
///   "Allow always", "Reject" — all verified live.
public final class OpenCodePlugin: HarnessPlugin, @unchecked Sendable {

    static let patternsVersion = "2026-08-23.1"

    // "Session   New session - …" / "Continue  opencode -s ses_…" — printed to the pane's
    // own shell right after /exit, verified live across two separate real exits.
    private static let exitResume = JRegex(#"(?is)Continue\s+opencode\s+-s\s+([A-Za-z0-9_@%+=:,./-]+)"#)

    /// The composer's running-turn footer reads e.g. "⬝⬝⬝⬝⬝⬝■■  esc interrupt" — no "to",
    /// unlike the other three harnesses' "esc to interrupt" — verified live. Since that
    /// progress animation repaints every poll, `StateDetector`'s behavioral layer already
    /// reads WORKING without consulting this plugin; this is the same safety net
    /// `CodexPlugin`'s workingIndicator is, for a turn whose render freezes.
    private static let workingIndicator = JRegex(#"(?i)esc interrupt"#)

    /// "△ Permission required" plus its three-button row — verified live for both a shell
    /// command ("# Shell command" subheading) and a file edit ("→ Edit <file>"
    /// subheading). Matching the heading and button row rather than either subheading
    /// covers both without guessing a third alternative for tool kinds (webfetch, etc.)
    /// that were not exercised live.
    private static let approval = JRegex(#"(?i)(permission required|allow once\s+allow always\s+reject)"#)

    /// Both shell spellings — bash says "opencode: command not found", zsh says "command
    /// not found: opencode" (verified live) — plus generic crash signatures, the same
    /// narrow BROKEN shape `CodexPlugin` and `GrokPlugin` use, so a command a running
    /// opencode happens to run that itself isn't found doesn't get folded in.
    private static let broken = JRegex(
        #"(?i)(opencode: command not found|command not found: opencode(?![\w-])"#
            + #"|panic:|segmentation fault|fatal error)"#)

    /// The composer's bottom border, verified live as the stable divider between the
    /// composer/transcript above and the cwd-plus-hints footer below. The footer's left
    /// half is the working directory, which wraps across two rows when long — so unlike
    /// the chrome pattern this is matched positionally, everything from this border
    /// onward is footer rather than transcript, the same reasoning
    /// `CodexPlugin.footerBelowComposer` uses for its configurable status line.
    private static let composerBorder = JRegex(#"^\s*╹"#)

    /// The footer's right half, present whenever the composer is idle-visible — either the
    /// pre-conversation "tab agents  ctrl+p commands" hint or, once a turn has run, the
    /// token-usage "8.3K (4%)  ctrl+p commands" readout. Checked only after
    /// `workingIndicator` has already failed to match, so (unlike the working footer,
    /// which also carries "ctrl+p" alongside "esc interrupt") its presence here is
    /// unambiguous — the same ordering `GrokPlugin`'s idleHint relies on.
    private static let idleHint = JRegex(#"(?i)ctrl\+p"#)

    /// UI furniture stripped before the trailing-question check: the composer's left
    /// rail, the per-turn "▣  <mode> · <model>[ · Ns]" marker, "Thought: …" asides, and
    /// tool-activity preview rows (a shell echo, an edit/write summary, a "~ Preparing…"
    /// status) — all verified live. The footer below `composerBorder` is dropped by
    /// position instead, per that field's comment.
    private static let chrome = JRegex(
        #"(?i)(^\s*┃"#
            + #"|^\s*▣\s"#
            + #"|^\s*thought:\s"#
            + #"|^\s*[$~]\s"#
            + #"|^\s*[←→]\s)"#)

    public init() {}

    public var type: HarnessType { .opencode }

    // processName() is left at its default of type.id — "opencode". The installed
    // binary at ~/.opencode/bin/opencode is a self-contained Mach-O executable, not a
    // launcher that execs a versioned copy the way ClaudeCodePlugin's and GrokPlugin's
    // binaries do, so the foreground probe reports "opencode" verbatim — verified
    // live at 1.18.21. No versionedBinary-style override is needed.

    public func launchCommand() -> String { "opencode" }

    /// `opencode --session <id>` — the `-s, --session` flag documented by
    /// `opencode --help` and confirmed live: resuming with it replayed the full prior
    /// transcript rather than starting fresh.
    public func resumeCommand(_ harnessSessionId: String) -> String? {
        "opencode --session " + HarnessPlugins.shellArgument(harnessSessionId)
    }

    public func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? {
        lastExitSelector(OpenCodePlugin.exitResume, exitScreen.text)
    }

    /// `/exit` — verified live via the composer's own slash-command autocomplete
    /// ("/exit  Exit the app"), and it's the exact word the exit receipt's own wording names.
    public func quitCommand() -> String? { "/exit" }

    /// Drops everything from the composer's bottom border down (the positional footer,
    /// see `composerBorder`), then every chrome line above it.
    public func maskChrome(_ screenText: String) -> String {
        let lines = ScreenMask.lines(stripVolatile(screenText))
        var borderAt = -1
        for (i, line) in lines.enumerated() where OpenCodePlugin.composerBorder.find(ScreenMask.plain(line)) {
            borderAt = i
        }
        let above = borderAt >= 0 ? Array(lines[..<borderAt]) : lines
        return ScreenMask.join(above.filter { !OpenCodePlugin.chrome.find(ScreenMask.plain($0)) })
    }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(20)
        let tailText = tail.joined(separator: "\n")

        if OpenCodePlugin.broken.find(tailText) {
            return OpenCodePlugin.classified(.idle, "error signature on screen — opencode likely crashed")
        }
        if OpenCodePlugin.workingIndicator.find(tailText) {
            return OpenCodePlugin.classified(.working,
                                             "esc-interrupt visible: turn still running despite quiescent screen")
        }
        if OpenCodePlugin.approval.find(tailText) {
            return OpenCodePlugin.classified(.waitingForInput, "permission dialog shape")
        }
        let content = OpenCodePlugin.contentLines(tail)
        if let last = content.last, JavaText.hasSuffix(JavaText.stripTrailing(last), "?") {
            return OpenCodePlugin.classified(.waitingForInput, "quiescent with trailing question above UI chrome")
        }
        if OpenCodePlugin.idleHint.find(tailText) {
            return OpenCodePlugin.classified(.idle, "composer footer, no running-turn indicator")
        }
        return nil
    }

    /// The transcript above the composer's footer (see `composerBorder`), with the
    /// remaining UI chrome filtered out, for the trailing-question check.
    private static func contentLines(_ tail: [String]) -> [String] {
        var borderAt = -1
        for (i, line) in tail.enumerated() where composerBorder.find(line) {
            borderAt = i
        }
        let above = borderAt >= 0 ? Array(tail[..<borderAt]) : tail
        return above.filter { !chrome.find($0) }
    }

    private static func classified(_ state: SessionState, _ reason: String) -> Classification {
        Classification(state, .high, reason + " (patterns \(patternsVersion))", .plugin)
    }
}
