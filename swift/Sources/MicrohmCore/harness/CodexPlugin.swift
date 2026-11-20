import Foundation

/// Bootstrap + state-detection patterns for the OpenAI Codex CLI. Adapted from an
/// earlier six-state detector's `CodexPlugin` (captured against codex-cli 0.147.0) and
/// collapsed onto this app's 3-state `SessionState` the same way `ClaudeCodePlugin` and
/// `CursorAgentPlugin` are: approval, question widget and stalled goal loop all read
/// WAITING_FOR_INPUT, and a crashed codex folds into IDLE.
///
/// Re-grounded against **codex-cli 0.149.0** (macOS, pane 120x40, zsh); what was
/// re-verified live at that version is called out per pattern below. Everything else is
/// inherited from the 0.147.0 capture session and rots the same way the other plugins'
/// patterns do — nil means "fall back to the behavioral heuristics".
///
/// Two things still make codex differ from the other two plugins:
///
/// - Its running-turn line carries a live elapsed-time counter
///   ("• Working (5s • esc to interrupt)"), so a running turn never goes quiescent and
///   `StateDetector`'s behavioral layer already reads WORKING without consulting this
///   plugin. The esc-to-interrupt check below is the safety net for a turn whose render
///   freezes.
/// - Codex puts its own modals — startup directory-trust, the rate-limit "switch model?"
///   nudge — in the same numbered-selector widget it uses for permission prompts. All of
///   them need a human, so an unrecognized numbered selector reads WAITING_FOR_INPUT
///   rather than being left to fall through to idle.
public final class CodexPlugin: HarnessPlugin, @unchecked Sendable {

    static let patternsVersion = "2026-08-21.2"

    private static let autoResolveCountdown = JRegex(#"(?i)auto-resolves in \d+s"#)

    /// Printed after /quit, immediately before control returns to the pane shell.
    private static let exitResume = JRegex(
        #"(?is)To continue this session,\s+run\s+codex\s+resume\s+"#
            + #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#)

    // Must match the whole "Working (… esc to interrupt)" shape, not the bare hint: the
    // request_user_input widget's hint bar ends with "tab to add notes | enter to submit
    // answer | esc to interrupt", so a bare match classifies a pending question as a
    // running turn and the sidebar never goes amber for it.
    private static let workingIndicator = JRegex(#"(?i)Working\s*\([^)]*esc to interrupt"#)

    // The directory-trust wording and "Press enter to continue" were re-verified live at
    // 0.149.0; the exec/patch approval phrasings are inherited
    // from the 0.147.0 captures. The remaining alternatives come from the binary's string
    // table and have never been confirmed against a live render — they can only add
    // WAITING_FOR_INPUT, which is the "needs you" badge, so an over-match is the safe
    // direction here.
    private static let approvalExplicit = JRegex(
        #"(?i)(would you like to (run the following command|make the following edits)"#
            + #"|do you trust the contents of this directory"#
            + #"|press enter to (confirm|continue)"#
            + #"|needs your approval"#
            + #"|do you want to approve network access to"#
            + #"|codex wants to edit)"#)

    // request_user_input widget, gated behind codex's default_mode_request_user_input
    // feature flag. Derived from the binary's string table, not confirmed against a live
    // render. Kept separate from approvalExplicit even though both now yield the same
    // state, because the reason string lands in the sidebar tooltip and "consent dialog"
    // and "question" are different things to be told.
    private static let questionWidget = JRegex(
        #"(?i)(enter to submit answer|\d+ unanswered|auto-resolves in|^\s*Question \d+/\d+\b)"#,
        multiline: true)

    // "› 1. Yes, continue" — the caret is U+203A. Re-verified live at 0.149.0 against the
    // startup directory-trust prompt. Note this caret is not exclusive to selectors:
    // codex draws the composer and echoes submitted prompts with it too, so the branch
    // that uses this is guarded on the composer being absent.
    private static let optionSelector = JRegex(#"^\s*›\s*\d+\.\s"#)

    // Narrow on purpose: a coding agent's transcript is full of "command not found" and
    // "fatal error" from commands it ran, so only codex's own death counts. Both shell
    // spellings — bash says "codex: command not found", zsh says "command not found: codex".
    private static let broken = JRegex(
        #"(?i)(codex: command not found|command not found: codex(?![\w-])"#
            + #"|killed\s+codex\b"#
            + #"|agent errored:"#
            + #"|failed to start codex session:)"#)

    // Idle is read off the composer+footer layout at the bottom of the screen, never off
    // the caret being empty: codex renders a rotating dim placeholder inside the caret
    // ("› Ask Codex to do anything" at 0.149.0) and a capture cannot tell ghost text
    // from a real draft.
    private static let composerLine = JRegex(#"^\s*›"#)

    // /goal is codex's own self-loop. "Pursuing goal (7s)" rides alongside the normal
    // running-turn line so it needs no pattern, and "Goal achieved (11s)" freezes at its
    // final duration and reads as ordinary idle. These variants are the ones that look
    // idle but are not: the loop has stopped and only a human typing `/goal resume` will
    // restart it, which is a "needs you" badge, not a gray one. Wording is verbatim from
    // the 0.147.0 string table and unconfirmed; a miss falls through to idle.
    private static let goalNeedsHuman = JRegex(#"(?i)Goal (paused|stalled|hit usage limits|abandoned)"#)

    // Fast path for the footers that name a recognizable component, so idle still
    // resolves if the composer line itself is scrolled or styled unexpectedly. Note this
    // is only ever a fast path: the 0.149.0 default footer is "<model> <effort> · <cwd>"
    // ("gpt-5.6-sol high · /private/tmp/…"), which matches none of these alternatives and
    // is caught by the structural branch of composerVisible instead — which is exactly
    // why that branch exists. The footer's contents are operator configuration ([tui]
    // status_line picks from ~20 components), so its text can never be the primary signal.
    private static let footerComponent = JRegex(
        #"(?i)(Context\s+\d+%\s+left|\d+%\s+context|\d+K\s+window"#
            + #"|Fast\s+(on|off)|\bv?\d+\.\d+\.\d+\b)"#)

    // Everything that is UI furniture rather than agent speech, stripped before the
    // trailing-question-mark check: composer/echoed prompts/selector carets (all "›"),
    // horizontal rules, the welcome box, tool-output tree rows, option rows, the command
    // preview, the approval receipt, and the tip banners. The status footer is NOT in
    // here — it is dropped positionally by contentLines(), because its text is operator
    // configuration. The "Context N% left" alternative below only survives as a fast path
    // for the operators who do configure that component.
    private static let chrome = JRegex(
        #"(?i)(^\s*›"#
            + #"|^\s*─+\s*$"#
            + #"|^\s*[╭╮╰╯│└]"#
            + #"|^\s*\d+\.\s"#
            + #"|^\s*\$\s"#
            + #"|^\s*✔"#
            + #"|^\s*⚠"#
            + #"|^\s*Tip:"#
            + #"|^\s*Environment:\s"#
            + #"|press enter to "#
            + #"|esc to interrupt"#
            + #"|Context\s+\d+%\s+left)"#)

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

    public var type: HarnessType { .codex }

    // processName() is left at its default of type.id — "codex". The launcher at
    // ~/.local/bin/codex is a real Mach-O binary (a symlink into the versioned standalone
    // release), not a shim that execs something else, and the foreground probe reports the
    // command as "codex": verified at 0.149.0. On Windows the npm shim runs node.exe as the
    // shell's child instead, so the foreground is "node" there — hence the override below.
    public func ownsProcess(_ foregroundCommand: String) -> Bool {
        processName() == foregroundCommand || windows && foregroundCommand == "node"
    }

    public func launchCommand() -> String { "codex" }

    /// `codex resume <SESSION_ID>` — verified against the 0.149.0 binary's own
    /// `codex resume --help`, which documents the positional as "Session id (UUID) or
    /// session name". Unlike `CursorAgentPlugin` this is a real, checked syntax rather
    /// than a guess, so the "Open…" dialog can resume codex conversations by id without
    /// falling back to a fresh launch.
    public func resumeCommand(_ harnessSessionId: String) -> String? {
        "codex resume " + HarnessPlugins.shellArgument(harnessSessionId)
    }

    /// `codex -c 'mcp_servers.micro-harness-manager.url="<url>"'
    /// -c 'mcp_servers.micro-harness-manager.bearer_token_env_var="MHM_MCP_TOKEN"'` — per-run
    /// config overrides that add a streamable-HTTP server next to the user's configured
    /// ones, authenticating with the token the launcher put into the session's
    /// `MHM_MCP_TOKEN` environment variable (so the token itself is never typed). `-c` is a
    /// global option, so both go right after the leading `codex`, ahead of the `resume`
    /// subcommand.
    public func withMcpServer(_ command: String, _ endpoint: McpEndpoint) -> String {
        let prefix = "mcp_servers." + HarnessPlugins.mcpServerName + "."
        return ScreenMask.insertAfterProgram(command, "codex",
            "-c " + HarnessPlugins.shellArgument(prefix + "url=" + ScreenMask.quoted(endpoint.url))
                + " -c " + HarnessPlugins.shellArgument(
                    prefix + "bearer_token_env_var=" + ScreenMask.quoted(HarnessPlugins.mcpTokenEnv)))
    }

    /// The bearer token comes from `MHM_MCP_TOKEN`; see `withMcpServer`.
    public func usesMcpTokenEnv() -> Bool { true }

    /// Drops the status footer by position (the indented line directly below the
    /// composer — see `contentLines` for why never by text), then every chrome line,
    /// which takes the composer, echoed prompts and the running-turn line with its
    /// elapsed counter.
    public func maskChrome(_ screenText: String) -> String {
        var lines = ScreenMask.lines(stripVolatile(screenText))
        let last = ScreenMask.lastNonBlank(lines, lines.count - 1)
        let above = ScreenMask.lastNonBlank(lines, last - 1)
        if above >= 0 {
            let footer = ScreenMask.plain(lines[last])
            if CodexPlugin.composerLine.find(ScreenMask.plain(lines[above]))
                && JavaText.startsWithWhitespace(footer) {
                lines.remove(at: last)
            }
        }
        return ScreenMask.join(lines.filter { !CodexPlugin.chrome.find(ScreenMask.plain($0)) })
    }

    public func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? {
        lastExitSelector(CodexPlugin.exitResume, exitScreen.text)
    }

    /// `/quit` — "exit Codex". Grounded in the 0.149.0 binary's string table, which
    /// lists both `quit` and `exit` in its slash-command registry with that description;
    /// not confirmed against a live render, same caveat as the string-table patterns
    /// above. `/quit` over `/exit` because the table also carries "archive this session
    /// and exit" siblings near `exit` — quit is unambiguous.
    public func quitCommand() -> String? { "/quit" }

    /// "Question 1/1 (1 unanswered) · auto-resolves in 52s" repaints every second while
    /// codex waits for an answer. Without normalizing the counter away the screen never
    /// goes quiescent, `StateDetector` never consults this plugin, and the whole wait
    /// reads as a running turn. Deliberately not applied to the running-turn counter:
    /// that churn is a true liveness signal.
    public func stripVolatile(_ screenText: String) -> String {
        CodexPlugin.autoResolveCountdown.replaceAll(screenText, with: "auto-resolves in <n>s")
    }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(20)
        let tailText = tail.joined(separator: "\n")

        if CodexPlugin.broken.find(tailText) {
            return CodexPlugin.classified(.idle, "error signature on screen — codex likely crashed")
        }
        if CodexPlugin.workingIndicator.find(tailText) {
            return CodexPlugin.classified(.working,
                                          "esc-to-interrupt visible: turn still running despite quiescent screen")
        }
        if CodexPlugin.approvalExplicit.find(tailText) {
            return CodexPlugin.classified(.waitingForInput, "consent dialog shape")
        }
        if CodexPlugin.questionWidget.find(tailText) {
            return CodexPlugin.classified(.waitingForInput, "request-user-input selector widget")
        }
        // Guarded by "no composer": codex's modals replace the composer region rather
        // than drawing above it, so a visible composer means this caret is not a modal's.
        // Without the guard, an echoed prompt that happens to start with "1. " — codex
        // echoes submitted prompts with the same "›" caret it uses for selector rows —
        // pins an idle session to the "needs you" badge for the rest of its life.
        if !CodexPlugin.composerVisible(tail) && tail.contains(where: { CodexPlugin.optionSelector.find($0) }) {
            return CodexPlugin.classified(.waitingForInput,
                                          "numbered selector widget — a consent or modal decision only a human can make")
        }
        let content = CodexPlugin.contentLines(tail)
        if let last = content.last, JavaText.hasSuffix(JavaText.stripTrailing(last), "?") {
            return CodexPlugin.classified(.waitingForInput, "quiescent with trailing question above UI chrome")
        }
        if CodexPlugin.goalNeedsHuman.find(tailText) {
            return CodexPlugin.classified(.waitingForInput,
                                          "goal loop is paused/stalled — needs `/goal resume` from a human")
        }
        if CodexPlugin.composerVisible(tail) {
            return CodexPlugin.classified(.idle, "composer and status footer present, no running-turn indicator")
        }
        return nil
    }

    /// The tail with UI furniture removed, for the trailing-question check.
    ///
    /// The status footer is dropped by *position*, not by matching its text. Its contents
    /// are operator configuration — `[tui] status_line` picks from ~20 components — so no
    /// pattern can be relied on to recognize it, and in fact none of the chrome pattern's
    /// alternatives match the 0.149.0 default ("gpt-5.6-sol high · /Users/x/Projects/foo").
    /// Matching by text is how this check silently died between codex versions upstream:
    /// with the footer left in, it is always the last content line, it never ends in "?",
    /// and a turn that ends by asking the human a plain prose question badges gray
    /// instead of amber. What holds across status_line configurations is the footer's
    /// position — the line directly below the composer.
    private static func contentLines(_ tail: [String]) -> [String] {
        let lines = footerBelowComposer(tail) ? Array(tail.dropLast()) : tail
        return lines.filter { !chrome.find($0) }
    }

    /// True when the bottom of the screen is codex's composer region rather than a modal.
    /// Accepts the three shapes the configurable status line can produce: a recognizable
    /// footer component on the last line, a composer line directly above an indented
    /// footer (the 0.149.0 default — verified live), or a composer line as the last line
    /// (status_line configured empty).
    private static func composerVisible(_ tail: [String]) -> Bool {
        guard let last = tail.last else {
            return false
        }
        return composerLine.find(last) || footerComponent.find(last) || footerBelowComposer(tail)
    }

    /// The composer+footer shape: a "›" composer line directly above an indented footer.
    private static func footerBelowComposer(_ tail: [String]) -> Bool {
        if tail.count < 2 {
            return false
        }
        let last = tail[tail.count - 1]
        return composerLine.find(tail[tail.count - 2])
            && !JavaText.isBlank(last)
            && JavaText.startsWithWhitespace(last)
    }

    private static func classified(_ state: SessionState, _ reason: String) -> Classification {
        Classification(state, .high, reason + " (patterns \(patternsVersion))", .plugin)
    }
}
