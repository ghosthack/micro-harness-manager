import Foundation

/// Bootstrap + state-detection patterns for earendil-works' `pi` CLI
/// (`@earendil-works/pi-coding-agent`), collapsed onto this app's 3-state
/// `SessionState` the same way `GrokPlugin` and `OpenCodePlugin` are. There was no
/// earlier plugin to adapt this from either, so everything here was grounded directly
/// against a live `pi v0.84.2` pane (macOS, 120x40): a fresh launch, a bash-tool turn, a
/// project-trust prompt (triggered via a scratch `.pi/settings.json`), and a real
/// `/quit`. Pi's own bundled docs confirm there is no approval dialog to ground for an
/// individual tool call — `docs/usage.md`'s Design Principles section states pi
/// "intentionally does not include ... permission popups", and `docs/security.md` adds
/// that built-in tools run bash/edit/write "with the permissions of the pi process" with
/// "no built-in sandbox" — so unlike the other four plugins, `classifyQuiescent` has no
/// per-tool-call APPROVAL pattern; the one interactive prompt it recognizes is the
/// one-time project-trust dialog.
///
/// Two things make pi differ from the other four plugins:
///
/// - The installed `pi` binary is a JS file run via a `#!/usr/bin/env node` shebang: the
///   process image is node, which then sets its process title to "pi". The daemon's
///   foreground probe reads `ps`'s command name, which is that title — "pi", verified
///   live with pi 1.5.0 — while its fallback (the process's executable) and tmux's
///   `pane_current_command` report "node". Both are pi's; see `ownsProcess`.
/// - Its composer is a plain two-line frame — a bare box-drawing rule above the
///   (possibly empty) input text and another below it, with no side rails and no prompt
///   caret — so `contentLines` splits transcript from footer on the rule immediately
///   above that frame rather than on any glyph within it.
public final class PiPlugin: HarnessPlugin, @unchecked Sendable {

    static let patternsVersion = "2026-08-23.1"

    // "To resume this session: pi --session 01a03190-5463-719c-94f2-c8a627bc2e33" —
    // printed to the pane's own shell right after /quit, verified live.
    private static let exitResume = JRegex(
        #"(?is)To resume this session:\s*pi\s+--session\s+([A-Za-z0-9_@%+=:,./-]+)"#)

    /// Node execs itself in place of the shebang script, so a live pane reports "node"
    /// rather than "pi" for `pane_current_command` — verified live at 0.84.2. This is
    /// necessarily broader than the other plugins' process checks (any node process in
    /// the pane reads as "owned"), since the probe's report carries no argv to narrow it
    /// further; see the class comment.
    private static let nodeProcess = "node"

    /// "⠹ Working..." (a braille spinner glyph plus this literal text) — verified live.
    /// Since the spinner repaints every poll, `StateDetector`'s behavioral layer already
    /// reads WORKING without consulting this plugin; this is the same safety net
    /// `CodexPlugin`'s workingIndicator is, for a turn whose render freezes.
    private static let workingIndicator = JRegex(#"(?i)working\.\.\."#)

    /// The one interactive prompt pi has: a one-time "Trust project folder?" dialog shown
    /// at session start for a project carrying `.pi` resources with no saved trust
    /// decision (see `docs/security.md`'s Project Trust section) — verified live by
    /// launching in a scratch directory seeded with a bare `.pi/settings.json`. The same
    /// shape `CodexPlugin`'s directory-trust prompt is for codex.
    private static let trustPrompt = JRegex(#"(?i)trust project folder\?"#)

    /// Both shell spellings for a missing binary, plus generic crash signatures — the
    /// same narrow BROKEN shape `GrokPlugin` and `OpenCodePlugin` use, so a command a
    /// running pi happens to run that itself isn't found doesn't get folded in.
    private static let broken = JRegex(
        #"(?i)(pi: command not found|command not found: pi(?![\w-])"#
            + #"|panic:|segmentation fault|fatal error)"#)

    /// The composer's plain box-drawing rule, top and bottom, verified live as the stable
    /// divider between the transcript above and the (possibly wrapped) cwd-plus-usage
    /// footer below — present in every state, working or idle, the same way
    /// `OpenCodePlugin`'s composer border is.
    private static let composerBorder = JRegex(#"^─+$"#)

    public init() {}

    public var type: HarnessType { .pi }

    public func launchCommand() -> String { "pi" }

    public func processName() -> String { "pi" }

    /// "pi" (its process title, what the probe reads) or "node" (its process image, what
    /// the probe's fallback and tmux read): either way the harness is in the foreground.
    public func ownsProcess(_ foregroundCommand: String) -> Bool {
        foregroundCommand == "pi" || foregroundCommand == PiPlugin.nodeProcess
    }

    /// `pi --session <id>` — the `--session <path|id>` flag documented by `pi --help` and
    /// confirmed live: resuming with it replayed the full prior transcript rather than
    /// starting fresh, and it's the exact syntax a real `/quit` printed back (see
    /// `harnessSessionIdFromExit`).
    public func resumeCommand(_ harnessSessionId: String) -> String? {
        "pi --session " + HarnessPlugins.shellArgument(harnessSessionId)
    }

    public func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? {
        lastExitSelector(PiPlugin.exitResume, exitScreen.text)
    }

    /// `/quit` — verified live via the composer's own slash-command autocomplete
    /// ("/quit  Quit pi"); `/exit` is not a recognized command (typing it leaves the
    /// composer showing plain, unmatched text rather than an autocomplete entry).
    public func quitCommand() -> String? { "/quit" }

    /// The transcript above the composer frame's top rule, the same split `contentLines`
    /// makes: the frame and the cwd-plus-usage footer below it are all chrome.
    public func maskChrome(_ screenText: String) -> String {
        let lines = ScreenMask.lines(stripVolatile(screenText))
        let borderAt = PiPlugin.frameTop(lines) { ScreenMask.plain($0) }
        return ScreenMask.join(borderAt >= 0 ? Array(lines[..<borderAt]) : lines)
    }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(20)
        let tailText = tail.joined(separator: "\n")

        if PiPlugin.broken.find(tailText) {
            return PiPlugin.classified(.idle, "error signature on screen — pi likely crashed")
        }
        if PiPlugin.workingIndicator.find(tailText) {
            return PiPlugin.classified(.working, "working indicator visible: turn still running despite quiescent screen")
        }
        if PiPlugin.trustPrompt.find(tailText) {
            return PiPlugin.classified(.waitingForInput, "project-trust prompt shape")
        }
        let content = PiPlugin.contentLines(tail)
        if let last = content.last, JavaText.hasSuffix(JavaText.stripTrailing(last), "?") {
            return PiPlugin.classified(.waitingForInput, "quiescent with trailing question above UI chrome")
        }
        if tail.contains(where: { PiPlugin.composerBorder.find(JavaText.strip($0)) }) {
            return PiPlugin.classified(.idle, "composer frame, no running-turn indicator")
        }
        return nil
    }

    /// The transcript above the composer's top rule (see `composerBorder`): the frame's
    /// own rule lines are the only chrome pi draws outside the footer, so unlike
    /// `OpenCodePlugin.contentLines` no separate per-line chrome pattern is needed once
    /// the split point is found.
    private static func contentLines(_ tail: [String]) -> [String] {
        let borderAt = frameTop(tail) { $0 }
        return borderAt >= 0 ? Array(tail[..<borderAt]) : tail
    }

    /// Index of the second rule line counting up from the bottom (the frame's top), or
    /// of the only one, or -1.
    private static func frameTop(_ lines: [String], _ view: (String) -> String) -> Int {
        var borderAt = -1
        var seen = 0
        var i = lines.count - 1
        while i >= 0 {
            if composerBorder.find(JavaText.strip(view(lines[i]))) {
                seen += 1
                borderAt = i
                if seen == 2 {
                    break
                }
            }
            i -= 1
        }
        return borderAt
    }

    private static func classified(_ state: SessionState, _ reason: String) -> Classification {
        Classification(state, .high, reason + " (patterns \(patternsVersion))", .plugin)
    }
}
