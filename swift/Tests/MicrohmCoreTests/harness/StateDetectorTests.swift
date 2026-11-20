import Foundation
import XCTest
@testable import MicrohmCore

/// Classification fixtures adapted from an earlier six-state detector's `StateDetectorTest`,
/// collapsed onto this app's 3-state `SessionState` (approval/question fixtures now
/// assert `WAITING_FOR_INPUT` instead of the split
/// `WAITING_FOR_APPROVAL`/`WAITING_FOR_QUESTION`; the broken-pane fixtures
/// assert `IDLE` instead of `BROKEN`).
final class StateDetectorTests: XCTestCase {

    private let SHORT: TimeInterval = 5
    private let LONG: TimeInterval = 30

    private final class NoPatterns: HarnessPlugin, @unchecked Sendable {
        var type: HarnessType { .claudeCode }
        func launchCommand() -> String { "null-harness" }
        func processName() -> String { "null-harness" }
        func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? { nil }
    }

    private let NO_PATTERNS = NoPatterns()

    private let clock = MutableClock()

    private func screen(_ text: String) -> Screen {
        Screen(text, false, epoch)
    }

    /** The daemon spawns pwsh/powershell/cmd on Windows and reports them lower-cased
     * without ; they must read as "at a prompt" exactly like zsh does. */
    func testWindowsShellsCountAsShells() {
        for shell in ["pwsh", "powershell", "cmd", "zsh", "bash"] {
            XCTAssertTrue(StateDetector.isShell(shell), shell)
        }
        XCTAssertFalse(StateDetector.isShell("node"))
        XCTAssertFalse(StateDetector.isShell("claude"))
        XCTAssertFalse(StateDetector.isShell("cmd.exe"), "the probe strips .exe before reporting")
    }

    func testChangingScreenIsWorking() {
        let d = StateDetector(NO_PATTERNS, clock, SHORT, LONG)
        XCTAssertEqual(SessionState.working, d.classify(screen("a")).state)
        clock.advance(2)
        let c = d.classify(screen("ab"))
        XCTAssertEqual(SessionState.working, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testBrieflyQuiescentIsStillWorkingMediumConfidence() {
        let d = StateDetector(NO_PATTERNS, clock, SHORT, LONG)
        d.classify(screen("a"))
        clock.advance(3)
        let c = d.classify(screen("a"))
        XCTAssertEqual(SessionState.working, c.state)
        XCTAssertEqual(Confidence.medium, c.confidence)
    }

    func testQuiescentUnmatchedIsIdleLowConfidence() {
        let d = StateDetector(NO_PATTERNS, clock, SHORT, LONG)
        d.classify(screen("a"))
        clock.advance(10)
        let c = d.classify(screen("a"))
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.low, c.confidence)
    }

    func testLongQuiescenceFallsBackToIdleHighConfidence() {
        let d = StateDetector(NO_PATTERNS, clock, SHORT, LONG)
        d.classify(screen("a"))
        clock.advance(31)
        let c = d.classify(screen("a"))
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testDeadPaneIsIdle() {
        let d = StateDetector(NO_PATTERNS, clock, SHORT, LONG)
        let c = d.classify(Screen("", true, epoch))
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testCursorAgentApprovalPromptIsWaitingForInput() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("doing item 8\nRun this command? [y/n]")
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    func testApprovalWinsOverQuestionWhenPromptEndsWithQuestionMark() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("Do you want to run date > notes/item_08.txt?")
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    func testCursorAgentTrailingQuestionIsWaitingForInput() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("Item 14: should notes/item_14.txt contain option A or option B?")
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    func testQuestionDetectedAboveInputBoxAndFooterChrome() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("""
            Should notes/item_14.txt contain "option A" or "option B"?
            → Add a follow-up                              ctrl+c to stop
            Auto Balance · 7.2% · 1 file edited
            /private/tmp/babysit-scratch · main
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testQuestionSelectorWidgetDetected() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("""
            │ 1. Should test.txt contain option A or option B?      │
            │   › [ ] Option A                                       │
            │     [ ] Option B                                       │
            │     [ ] Other: (type to answer)                        │
            │ ↑/↓ option · Space select · Enter next/submit · Esc to skip │
            └────────────────────────────────────────────────────────┘
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testIdleWithChromeStaysIdleWhenLastContentLineIsNotAQuestion() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("""
            Item 12 is done: created notes/item_12.txt and checked it off.
            Waiting for further instructions.
            → Add a follow-up
            Auto Balance · 7.3% · 1 file edited
            /private/tmp/babysit-scratch · main
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.idle, d.classify(s).state)
    }

    func testCursorAgentEmptyInputBoxIsIdleBeforeLongFallback() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("checked off item 3\n❯ ")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testCursorAgentBackgroundTasksBelowInputIsWorking() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("""
            Background subagent launched for sleep 60. Ready for further instructions.
            → Add a follow-up
            2 tasks
            Auto Balance · 6.3%
            /private/tmp/babysit-ca-bg
            """)
        d.classify(s)
        clock.advance(45)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.working, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
    }

    func testCursorAgentStaleTasksMentionAboveInputIsIdle() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("""
            I finished 2 tasks
            → Add a follow-up
            Auto Balance · 6.5%
            /private/tmp/babysit-ca-bg
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.idle, d.classify(s).state)
    }

    func testCursorAgentErrorSignatureFoldsIntoIdle() {
        let d = StateDetector(CursorAgentPlugin(), clock, SHORT, LONG)
        let s = screen("zsh: cursor-agent: command not found")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    // ------------------------------------------------------------------
    // codex. The first two fixtures are verbatim `capture-pane -p` output from
    // codex-cli 0.149.0 (macOS, tmux 3.7b, 120x40); the rest are adapted from
    // that detector's CodexPluginTest.
    // ------------------------------------------------------------------

    func testCodexDirectoryTrustPromptIsWaitingForInput() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
            > You are in /private/tmp/codex-scratch
              Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt
              injection. Trusting the directory allows project-local config, hooks, and exec policies to load.
            › 1. Yes, continue
              2. No, quit
              Press enter to continue
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    /**
     * The 0.149.0 default footer is "&lt;model&gt; &lt;effort&gt; · &lt;cwd&gt;", which
     * matches none of the plugin's named footer components — idle here rests entirely on
     * the structural "composer line above an indented footer" branch. That is the branch
     * most likely to be broken by a careless edit, so this fixture stays verbatim.
     */
    func testCodexIdleComposerIsIdleEvenWhenTheFooterNamesNoKnownComponent() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
            ╭────────────────────────────────────────────────────────╮
            │ >_ OpenAI Codex (v0.149.0)                             │
            │ model:       gpt-5.6-sol high   /model to change       │
            │ directory:   /private/tmp/…/codex-scratch              │
            ╰────────────────────────────────────────────────────────╯
              Tip: NEW: Prevent sleep while running is now available in /experimental.
            • You have 1 usage limit reset available. Run /usage to use one.
            › Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/codex-scratch
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    func testCodexWorkingIndicatorIsWorkingDespiteQuiescentScreen() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("• Working (5s • esc to interrupt)")
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.working, d.classify(s).state)
    }

    /**
     * The question widget's hint bar ends in "esc to interrupt" — the same string the
     * running-turn line carries. A bare match on it reads a pending question as a running
     * turn, and the sidebar never goes amber for a session that is waiting on the human.
     */
    func testCodexQuestionWidgetIsNotMistakenForARunningTurn() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
              Question 1/1 (1 unanswered)
              Which text should notes/item_14.txt contain?
            › 1. option A (Recommended)  Write the text "option A" to the file.
              2. option B                Write the text "option B" to the file.
              tab to add notes | enter to submit answer | esc to interrupt
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    /**
     * The auto-resolve countdown repaints every second. Without
     *  normalizing it away the screen never reaches
     * quiescence, the plugin is never consulted, and the whole wait reads as WORKING.
     */
    func testCodexAutoResolveCountdownStillReachesQuiescence() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let frame = "  Question 1/1 (1 unanswered) · auto-resolves in %ds\n"
                + "  Which text should notes/item_14.txt contain?"
        d.classify(screen(String(format: frame, 52)))
        clock.advance(6)
        let c = d.classify(screen(String(format: frame, 46)))
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    /**
     * Codex renders its own modals — here the rate-limit model-switch nudge — in the same
     * numbered selector it uses for permission prompts. They are consent decisions that
     * stall the session until a human clears them, so an unrecognized selector must reach
     * the "needs you" badge rather than falling through to idle.
     */
    func testCodexUnrecognizedNumberedSelectorIsWaitingForInput() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
              Approaching rate limits — Switch to gpt-5.6-luna for lower credit usage?
            › 1. Yes, switch
              2. Not now
              3. Keep current model (never show again)
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertTrue(c.reason.contains("numbered selector"),
                "expected the selector branch to classify this, got: " + c.reason)
    }

    /** A stalled /goal loop looks idle but only `/goal resume` from a human restarts it. */
    func testCodexStalledGoalLoopIsWaitingForInput() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
            Wrote notes/item_09.txt and checked it off.
            Goal paused (4m 12s)
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    func testCodexErrorSignatureFoldsIntoIdle() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("zsh: command not found: codex")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    /**
     * A coding agent's transcript is full of failures from commands it ran. Only codex's
     * own death is an error signature; "command not found" for anything else is content.
     */
    func testCodexBrokenPatternIgnoresCommandFailuresInTheTranscript() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
              $ codex-helper --check
              zsh: command not found: codex-helper
            › Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/codex-scratch
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        // The state alone cannot fail this test — a session codex crashed out of is IDLE
        // too. The reason is the only thing that distinguishes "idle at the composer"
        // from "we think the process died", so assert on it or the regression walks past.
        XCTAssertTrue(c.reason.contains("composer"),
                "expected the idle-composer branch, not the crash branch: " + c.reason)
    }

    /**
     * A turn that ends by asking the human a plain prose question — no widget, no
     * selector, just text above the composer. This is the ordinary way codex asks
     * something, since its request-user-input widget is behind a feature flag that is off
     * by default, so it is the branch that matters most.
     *
     * <p>It is also the branch that quietly dies when codex changes its status footer: if
     * the footer is not recognized as chrome it becomes the last content line, and a
     * footer never ends in "?". Hence the 0.149.0 default footer here, which matches none
     * of the plugin's footer patterns — the footer must be dropped by position for this
     * to pass.
     */
    func testCodexTrailingQuestionAboveTheComposerIsWaitingForInput() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
            • I can either rewrite the parser or patch it in place. Which would you prefer?
            › Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/codex-scratch
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertTrue(c.reason.contains("trailing question"),
                "expected the trailing-question branch: " + c.reason)
    }

    /** Same question, an operator who configured `status_line = ["current-dir"]`. The
     * footer's contents are configuration, so they must not decide the answer. */
    func testCodexTrailingQuestionSurvivesACustomStatusFooter() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
            • Should notes/item_14.txt contain "option A" or "option B"?
            › Ask Codex to do anything
              /private/tmp/codex-scratch
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    /**
     * Codex echoes a submitted prompt with the same "›" caret it draws selector rows
     * with, so a perfectly ordinary numbered instruction looks exactly like option 1 of a
     * consent dialog. What tells them apart is the composer: codex's modals replace that
     * region rather than drawing above it, so a visible composer means no modal — and
     * without that guard this session would sit on the "needs you" badge forever.
     */
    func testCodexEchoedNumberedPromptIsNotMistakenForASelectorWidget() {
        let d = StateDetector(CodexPlugin(), clock, SHORT, LONG)
        let s = screen("""
            › 1. run the unit tests, 2. fix whatever fails
            • Ran 74 tests, all green. Nothing to fix.
            › Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/codex-scratch
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.idle, d.classify(s).state)
    }

    // ------------------------------------------------------------------
    // shell. The liveness rule inverts for this plugin: a shell foreground is the
    // harness running, not the harness dead.
    // ------------------------------------------------------------------

    func testShellAtItsPromptIsIdleViaThePlugin() {
        let d = StateDetector(ShellPlugin(), clock, SHORT, LONG)
        let s = Screen("sample@host project %", false, epoch, "zsh")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    /** For every other plugin a shell foreground short-circuits to "process died" IDLE
     * even while output is changing. The shell harness must not inherit that: a scrolling
     * command run from its prompt is WORKING. */
    func testShellWithChangingOutputIsWorkingNotDead() {
        let d = StateDetector(ShellPlugin(), clock, SHORT, LONG)
        d.classify(Screen("$ make\ncc -c a.c", false, epoch, "zsh"))
        clock.advance(2)
        let c = d.classify(Screen("$ make\ncc -c a.c\ncc -c b.c", false, epoch, "zsh"))
        XCTAssertEqual(SessionState.working, c.state)
        XCTAssertEqual(Classification.Origin.behavioral, c.origin)
    }

    /** A quiescent foreground program (vim, a REPL) is nobody's known pattern — the
     * plugin must stay silent and let the behavioral fallback answer. */
    func testShellForegroundProgramFallsThroughToBehavioralFallback() {
        let d = StateDetector(ShellPlugin(), clock, SHORT, LONG)
        let s = Screen("~ some file open in vim ~", false, epoch, "vim")
        d.classify(s)
        clock.advance(45)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.behavioral, c.origin)
    }

    func testPaneBackAtAShellPromptFoldsIntoIdleNotWorking() {
        // the harness exited and left a bare shell prompt: quiescent, no output changing —
        // without the liveness check this would eventually read as a generic IDLE anyway,
        // but the reason text should say the process died, not "no pattern matched"
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let s = Screen("sample@host project %", false, epoch, "zsh")
        d.classify(s)
        clock.advance(45)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
        XCTAssertEqual(Classification.Origin.behavioral, c.origin)
    }

    func testLivenessCheckUsesTheBinaryNameNotTheProfileName() {
        // profile "claude-code" runs a process called "claude"
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let running = Screen("""
            ● Done. Waiting for further instructions.
            ❯
              ⏵⏵ auto mode on (shift+tab to cycle)
            """, false, epoch, "claude")
        d.classify(running)
        clock.advance(6)
        XCTAssertEqual(SessionState.idle, d.classify(running).state)
    }

    func testDeadPaneStillWinsOverEverything() {
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        XCTAssertEqual(SessionState.idle,
                d.classify(Screen("", true, epoch, "zsh")).state)
    }

    func testClaudeCodeEscToInterruptIsWorkingDespiteQuiescentScreen() {
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let s = screen("Running a long tool call...\n(esc to interrupt)")
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.working, d.classify(s).state)
    }

    func testClaudeCodeApprovalDialogIsWaitingForInput() {
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let s = screen("Do you want to make this edit?\n❯ 1. Yes")
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    /// Claude Code's folder trust prompt, captured live (2026-11-20, 100x30): an unnumbered
    /// menu, so only its footer marks it as waiting.
    func testClaudeCodeFolderTrustPromptIsWaitingForInput() {
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let s = screen([
            String(repeating: "─", count: 100),
            " Accessing workspace:",
            "",
            " /private/tmp/trust-probe.SpRT",
            "",
            " Quick safety check: Is this a project you created or one you trust? (Like your own code, a",
            " well-known open source project, or work from your team). If not, take a moment to review what's in",
            " this folder first.",
            "",
            " Claude Code'll be able to read, edit, and execute files here.",
            "",
            " Security guide",
            "",
            " ❯ No, exit",
            "   Yes, I trust this folder",
            "",
            " Enter to confirm · Esc to cancel",
        ].joined(separator: "\n"))
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    /** Build output on the screen is content: "fatal error" and "panic:" from a command
     * claude ran must not read as claude having crashed while it works or asks. */
    func testClaudeCodeErrorTextFromACommandIsNotACrash() {
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let working = screen("main.c:3: fatal error: x.h: No such file\npanic: boom\n(esc to interrupt)")
        d.classify(working)
        clock.advance(6)
        XCTAssertEqual(SessionState.working, d.classify(working).state)

        let asking = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let dialog = screen("Traceback (most recent call last):\nDo you want to make this edit?\n❯ 1. Yes")
        asking.classify(dialog)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, asking.classify(dialog).state)
    }

    func testClaudeCodeMissingBinaryFoldsIntoIdle() {
        let d = StateDetector(ClaudeCodePlugin(), clock, SHORT, LONG)
        let s = screen("zsh: command not found: claude")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    // ------------------------------------------------------------------
    // grok. Grounded directly against a live grok 1.0.5 (5115b46bc909) [stable] pane
    // (macOS, tmux 3.6a, 120x40) via tmux capture-pane, except the approval wording, which
    // is derived from the installed binary's own string table — this install's settings
    // auto-approve every tool call, so the live dialog never painted. See GrokPlugin's
    // class comment.
    // ------------------------------------------------------------------

    func testGrokWorkingIndicatorIsWorkingDespiteQuiescentScreen() {
        let d = StateDetector(GrokPlugin(), clock, SHORT, LONG)
        let s = screen("""
            ⠦ Waiting for response… 1.0s
            Shift+Tab:mode  │  Esc:cancel  │  Ctrl+x:shortcuts
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.working, d.classify(s).state)
    }

    func testGrokAllowPromptIsWaitingForInput() {
        let d = StateDetector(GrokPlugin(), clock, SHORT, LONG)
        let s = screen("""
            I'll run rm -rf tmp/scratch now.
            Allow Execute?
            ❯
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    /**
     * Grok right-pads a clock timestamp onto the same line as each chat bubble, so a naive
     * trailing-content check would see "...option B?                    6:05 PM" and miss
     * the question.  strips it before checking.
     */
    func testGrokTrailingQuestionSurvivesTheRightAlignedTimestamp() {
        let d = StateDetector(GrokPlugin(), clock, SHORT, LONG)
        let s = screen("""
            Should notes/item_14.txt contain option A or option B?                    6:05 PM

            ╭──────────────────────────────────────────────╮
            │ ❯                                              │
            ╰──────────────────────────────────────── Grok 4.6 (high) ─╯
            Shift+Tab:mode  │  Ctrl+x:shortcuts
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertTrue(c.reason.contains("trailing question"),
                "expected the trailing-question branch: " + c.reason)
    }

    func testGrokIdleComposerIsIdleBeforeLongFallback() {
        let d = StateDetector(GrokPlugin(), clock, SHORT, LONG)
        let s = screen("""
            Created probe.txt in the current directory with the text test.          6:05 PM

            Worked for 6.4s

            ╭──────────────────────────────────────────────╮
            │ ❯                                              │
            ╰──────────────────────────────────────── Grok 4.6 (high) ─╯
            Shift+Tab:mode  │  Ctrl+x:shortcuts
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    func testGrokErrorSignatureFoldsIntoIdle() {
        let d = StateDetector(GrokPlugin(), clock, SHORT, LONG)
        let s = screen("zsh: command not found: grok")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    // ------------------------------------------------------------------
    // opencode. Grounded directly against a live opencode 1.18.21 pane (macOS, tmux 3.6a,
    // 120x40) via tmux capture-pane, including a real "Allow once / Allow always / Reject"
    // permission dialog (driven by a temporary project-local opencode.json setting
    // permission.bash/edit to "ask" — the default install auto-approved both). See
    // OpenCodePlugin's class comment.
    // ------------------------------------------------------------------

    func testOpenCodeWorkingIndicatorIsWorkingDespiteQuiescentScreen() {
        let d = StateDetector(OpenCodePlugin(), clock, SHORT, LONG)
        let s = screen("""
            ┃
            ┃  ⠋ echo test > probe.txt
            ┃

            ▣  Build · Big Pickle

            ┃
            ┃
            ┃
            ┃  Build · Big Pickle OpenCode Zen
            ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
             ⬝⬝⬝⬝⬝⬝■■  esc interrupt                                        8.1K (4%)  ctrl+p commands
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.working, d.classify(s).state)
    }

    func testOpenCodePermissionDialogIsWaitingForInput() {
        let d = StateDetector(OpenCodePlugin(), clock, SHORT, LONG)
        let s = screen("""
            ┃  △ Permission required
            ┃    # Shell command
            ┃
            ┃  $ ls -la
            ┃
            ┃
            ┃   Allow once   Allow always   Reject         ctrl+f fullscreen  ⇆ select  enter confirm
            ┃
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.waitingForInput, d.classify(s).state)
    }

    func testOpenCodeTrailingQuestionIsWaitingForInput() {
        let d = StateDetector(OpenCodePlugin(), clock, SHORT, LONG)
        let s = screen("""
            Which file would you like me to rename, and what should its new name be?

            ▣  Build · Big Pickle · 13.9s

            ┃
            ┃
            ┃
            ┃  Build · Big Pickle OpenCode Zen
            ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
             /Users/sample/Projects/sample/harness-manager                        8.3K (4%)ctrl+p
                                                                                             commands
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertTrue(c.reason.contains("trailing question"),
                "expected the trailing-question branch: " + c.reason)
    }

    func testOpenCodeIdleComposerIsIdleBeforeLongFallback() {
        let d = StateDetector(OpenCodePlugin(), clock, SHORT, LONG)
        let s = screen("""
            The directory is empty — just . and .., no files or subdirectories.

            ▣  Build · Big Pickle · 5.4s

            ┃
            ┃
            ┃
            ┃  Build · Big Pickle OpenCode Zen
            ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
             /Users/sample/Projects/sample/harness-manager                        8.3K (4%)ctrl+p
                                                                                             commands
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    func testOpenCodeErrorSignatureFoldsIntoIdle() {
        let d = StateDetector(OpenCodePlugin(), clock, SHORT, LONG)
        let s = screen("zsh: command not found: opencode")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    // ------------------------------------------------------------------
    // pi. Grounded directly against a live pi v0.84.2 pane (macOS, tmux 3.6a, 120x40) via
    // tmux capture-pane, including a real one-time "Trust project folder?" prompt
    // (triggered by a scratch .pi/settings.json). Pi's own docs/security.md, shipped
    // alongside the installed binary, confirms there is no per-tool-call approval
    // dialog to ground. See PiPlugin's class comment.
    // ------------------------------------------------------------------

    func testPiWorkingIndicatorIsWorkingDespiteQuiescentScreen() {
        let d = StateDetector(PiPlugin(), clock, SHORT, LONG)
        let s = screen("""
            ⠹ Working...

            ────────────────────────────────────────────────────────────────

            ────────────────────────────────────────────────────────────────
            /Users/sample/Projects/sample/harness-manager
            $0.005 (sub) 0.4%/500k (auto)                    (xai) grok-4.6 • medium
            """)
        d.classify(s)
        clock.advance(6)
        XCTAssertEqual(SessionState.working, d.classify(s).state)
    }

    func testPiTrustPromptIsWaitingForInput() {
        let d = StateDetector(PiPlugin(), clock, SHORT, LONG)
        let s = screen("""
            ────────────────────────────────────────────────────────────────

             Trust project folder?
             /Users/sample/Projects/sample/harness-manager

             This allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.

             → Trust
               Trust parent folder
               Trust (this session only)
               Do not trust
               Do not trust (this session only)

             ↑↓ navigate  enter select  escape/ctrl+c cancel
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    func testPiTrailingQuestionIsWaitingForInput() {
        let d = StateDetector(PiPlugin(), clock, SHORT, LONG)
        let s = screen("""
            I can either rewrite the parser or patch it in place. Which would you prefer?

            ────────────────────────────────────────────────────────────────

            ────────────────────────────────────────────────────────────────
            /Users/sample/Projects/sample/harness-manager
            $0.018 (sub) 0.7%/500k (auto)                    (xai) grok-4.6 • medium
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.waitingForInput, c.state)
        XCTAssertTrue(c.reason.contains("trailing question"),
                "expected the trailing-question branch: " + c.reason)
    }

    /** Verbatim (trimmed to a portable path) capture-pane output from a real pi bash-tool
     * turn against the live 0.84.2 pane. */
    func testPiIdleComposerIsIdleBeforeLongFallback() {
        let d = StateDetector(PiPlugin(), clock, SHORT, LONG)
        let s = screen("""
            The directory is empty. I should list the files and say hi.

            Hi.

            This directory is empty — only . and .. are present.

            ────────────────────────────────────────────────────────────────

            ────────────────────────────────────────────────────────────────
            /Users/sample/Projects/sample/harness-manager
            $0.005 (sub) 0.4%/500k (auto)                    (xai) grok-4.6 • medium
            """)
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Confidence.high, c.confidence)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }

    func testPiErrorSignatureFoldsIntoIdle() {
        let d = StateDetector(PiPlugin(), clock, SHORT, LONG)
        let s = screen("zsh: command not found: pi")
        d.classify(s)
        clock.advance(6)
        let c = d.classify(s)
        XCTAssertEqual(SessionState.idle, c.state)
        XCTAssertEqual(Classification.Origin.plugin, c.origin)
    }
}

