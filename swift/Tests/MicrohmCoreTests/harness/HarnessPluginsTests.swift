import Foundation
import XCTest
@testable import MicrohmCore





/**
 * Guards the wiring a new harness has to get right. The `switch` in
 * `HarnessPlugins` is exhaustive so the compiler catches a missing branch, but
 * nothing stops a branch from returning the wrong plugin, or a plugin from reporting a
 * type that disagrees with the one it was looked up by.
 */
final class HarnessPluginsTests: XCTestCase {

    func testEveryHarnessTypeResolvesToItsOwnPlugin() {
        for type in HarnessType.allCases {
            let plugin = HarnessPlugins.of(type)
                        XCTAssertEqual(type, plugin.type, "plugin registered under the wrong type")
            if type == HarnessType.shell {
                // the documented exception: blank means "the pane's shell is the
                // harness", and MainWindow skips send-keys entirely for it
                XCTAssertTrue(JavaText.isBlank(plugin.launchCommand()), "shell must launch nothing")
            } else {
                XCTAssertFalse(JavaText.isBlank(plugin.launchCommand()), "\(type) has no launch command")
            }
            XCTAssertFalse(JavaText.isBlank(plugin.processName()), "\(type) has no process name")
        }
    }

    /** The shell harness claims every shell `StateDetector` knows, and only those:
     * a foreground program the user launched must fall through to the behavioral layer,
     * and a conversation id must never resolve to a guessed resume command. */
    func testShellOwnsShellsAndNothingElse() {
        let shell = HarnessPlugins.of(HarnessType.shell)
        XCTAssertTrue(shell.ownsProcess("zsh"))
        XCTAssertTrue(shell.ownsProcess("bash"))
        XCTAssertFalse(shell.ownsProcess("vim"))
        XCTAssertFalse(shell.ownsProcess("claude"))
        XCTAssertNil( shell.resumeCommand("abc-123"))
    }

    /** npm shims on Windows run `node.exe` as the shell's child, so the foreground
     * probe reports "node" for claude and codex there — and only there: on macOS/Linux
     * a bare node process in the pane is the user's own program. */
    func testClaudeOwnsNodeOnlyOnWindows() {
        XCTAssertTrue(ClaudeCodePlugin(windows: true).ownsProcess("node"))
        XCTAssertTrue(ClaudeCodePlugin(windows: true).ownsProcess("claude"))
        XCTAssertTrue(ClaudeCodePlugin(windows: true).ownsProcess("2.1.235"))
        XCTAssertFalse(ClaudeCodePlugin(windows: false).ownsProcess("node"))
        XCTAssertTrue(ClaudeCodePlugin(windows: false).ownsProcess("claude"))
        XCTAssertTrue(ClaudeCodePlugin(windows: false).ownsProcess("2.1.235"))
    }

    func testCodexOwnsNodeOnlyOnWindows() {
        XCTAssertTrue(CodexPlugin(windows: true).ownsProcess("node"))
        XCTAssertTrue(CodexPlugin(windows: true).ownsProcess("codex"))
        XCTAssertFalse(CodexPlugin(windows: false).ownsProcess("node"))
        XCTAssertTrue(CodexPlugin(windows: false).ownsProcess("codex"))
        XCTAssertFalse(CodexPlugin(windows: false).ownsProcess("vim"))
    }

    func testPlatformCheckIsAPrefixMatchOnTheOsName() {
        XCTAssertTrue(Platform.isWindows("Windows 11"))
        XCTAssertTrue(Platform.isWindows("windows server 2022"))
        XCTAssertFalse(Platform.isWindows("Mac OS X"))
        XCTAssertFalse(Platform.isWindows("Linux"))
    }

    func testEveryHarnessTypeIdRoundTrips() throws {
        for type in HarnessType.allCases {
            XCTAssertEqual(type, try HarnessType.fromId(type.id))
        }
        XCTAssertThrowsError(try HarnessType.fromId("no-such-harness"))
    }

    /**
     * Verified against the codex-cli 0.149.0 binary: `codex resume --help` documents
     * the positional as "Session id (UUID) or session name", and the foreground probe
     * reports the command as "codex" for a pane running it — so the default
     * `processName()` of `HarnessType#id()` is correct and needs no override.
     */
    func testCodexBootstrapMatchesTheRealBinary() {
        let codex = HarnessPlugins.of(HarnessType.codex)
        XCTAssertEqual("codex", codex.launchCommand())
        XCTAssertEqual("codex", codex.processName())
        XCTAssertEqual(Optional("codex resume 0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f"),
                codex.resumeCommand("0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f"))
    }

    /**
     * Verified against a live grok 1.0.5 (5115b46bc909) [stable] pane: `grok --help`
     * documents `-r, --resume [<SESSION_ID_OR_TITLE>]`, the foreground probe
     * reports the command as "grok" when the binary is invoked directly by that
     * name, and a real `/quit` printed back exactly this resume line.
     */
    func testGrokBootstrapMatchesTheRealBinary() {
        let grok = HarnessPlugins.of(HarnessType.grok)
        XCTAssertEqual("grok", grok.launchCommand())
        XCTAssertEqual("grok", grok.processName())
        XCTAssertEqual(Optional("grok --resume 01a03151-c3f2-7e91-b819-be449127e073"),
                grok.resumeCommand("01a03151-c3f2-7e91-b819-be449127e073"))
        XCTAssertTrue(grok.ownsProcess("grok"), "exact binary name")
        // the foreground probe truncates the command name to 15 bytes; the launcher execs the
        // downloaded versioned binary — verified live.
        XCTAssertTrue(grok.ownsProcess("grok-1.0.5-maco"), "truncated versioned binary name")
        XCTAssertFalse(grok.ownsProcess("grokking-tool"), "unrelated binary sharing the prefix")
    }

    /**
     * Verified against a live opencode 1.18.21 pane: `opencode --help` documents
     * `-s, --session <id>` to continue a specific session, the foreground probe
     * reports the command as "opencode" for a pane running it (the installed
     * binary is a self-contained executable, not a launcher that execs a versioned copy),
     * and resuming with the flag live replayed the full prior transcript.
     */
    func testOpenCodeBootstrapMatchesTheRealBinary() {
        let openCode = HarnessPlugins.of(HarnessType.opencode)
        XCTAssertEqual("opencode", openCode.launchCommand())
        XCTAssertEqual("opencode", openCode.processName())
        XCTAssertEqual(Optional("opencode --session ses_fce87a83fffelfbjovglvpMeuS"),
                openCode.resumeCommand("ses_fce87a83fffelfbjovglvpMeuS"))
        XCTAssertTrue(openCode.ownsProcess("opencode"), "exact binary name")
    }

    /**
     * Verified against a live pi v0.84.2 pane: `pi --help` documents
     * `--session <path|id>` to use a specific session file or partial UUID, and
     * resuming with the flag live replayed the full prior transcript. The installed binary
     * is a JS file run via a `#!/usr/bin/env node` shebang that sets its process
     * title to "pi": the daemon's probe (`ps` command name) reports "pi" (pi 1.5.0,
     * verified live; Close refused with "pi is running" while only "node" was accepted),
     * the probe's fallback and tmux report "node".
     */
    func testPiBootstrapMatchesTheRealBinary() {
        let pi = HarnessPlugins.of(HarnessType.pi)
        XCTAssertEqual("pi", pi.launchCommand())
        XCTAssertEqual("pi", pi.processName())
        XCTAssertEqual(Optional("pi --session 01a03190-5463-719c-94f2-c8a627bc2e33"),
                pi.resumeCommand("01a03190-5463-719c-94f2-c8a627bc2e33"))
        XCTAssertTrue(pi.ownsProcess("pi"), "its process title, what the daemon's probe reports")
        XCTAssertTrue(pi.ownsProcess("node"), "its process image, what the fallback and tmux report")
        XCTAssertFalse(pi.ownsProcess("vim"))
    }

    func testExitReceiptsRecoverProviderConversationSelectors() {
        let codexExit = Screen("""
            Token usage: total=12,345
            To continue this session,
            run codex resume 0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f
            sample@host project %

            """, false, epoch, "zsh")
        XCTAssertEqual(Optional("0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f"),
                HarnessPlugins.of(HarnessType.codex).harnessSessionIdFromExit(codexExit))

        let claudeExit = Screen("""
            Resume this session with:
            claude --resume "my analysis session"
            sample@host project %

            """, false, epoch, "zsh")
        let claude = HarnessPlugins.of(HarnessType.claudeCode)
        XCTAssertEqual(Optional("my analysis session"),
                claude.harnessSessionIdFromExit(claudeExit))
        XCTAssertEqual(Optional("claude --resume 'my analysis session'"),
                claude.resumeCommand("my analysis session"))

        let cursorExit = Screen("""
            To resume this session: cursor-agent --resume=bc-abc123
            sample@host project %

            """, false, epoch, "zsh")
        let cursor = HarnessPlugins.of(HarnessType.cursorAgent)
        XCTAssertEqual(Optional("bc-abc123"), cursor.harnessSessionIdFromExit(cursorExit))
        XCTAssertEqual(Optional("cursor-agent --resume=bc-abc123"),
                cursor.resumeCommand("bc-abc123"))

        // Verbatim capture-pane output from a real /quit against grok 1.0.5.
        let grokExit = Screen("""
            Hi. What would you like to work on?

            Resume this session with:
              grok --resume 01a03151-c3f2-7e91-b819-be449127e073
            sample@host project %

            """, false, epoch, "zsh")
        let grok = HarnessPlugins.of(HarnessType.grok)
        XCTAssertEqual(Optional("01a03151-c3f2-7e91-b819-be449127e073"),
                grok.harnessSessionIdFromExit(grokExit))
        XCTAssertEqual(Optional("grok --resume 01a03151-c3f2-7e91-b819-be449127e073"),
                grok.resumeCommand("01a03151-c3f2-7e91-b819-be449127e073"))

        // Verbatim capture-pane output from a real /exit against opencode 1.18.21.
        let openCodeExit = Screen("""
            Session   New session - 2026-08-24T01:52:45.508Z
            Continue  opencode -s ses_fce87a83fffelfbjovglvpMeuS

            sample@host project %

            """, false, epoch, "zsh")
        let openCode = HarnessPlugins.of(HarnessType.opencode)
        XCTAssertEqual(Optional("ses_fce87a83fffelfbjovglvpMeuS"),
                openCode.harnessSessionIdFromExit(openCodeExit))
        XCTAssertEqual(Optional("opencode --session ses_fce87a83fffelfbjovglvpMeuS"),
                openCode.resumeCommand("ses_fce87a83fffelfbjovglvpMeuS"))

        // Verbatim capture-pane output from a real /quit against pi v0.84.2.
        let piExit = Screen("""

            To resume this session: pi --session 01a03190-5463-719c-94f2-c8a627bc2e33
            sample@mac pi-workspace %

            """, false, epoch, "zsh")
        let pi = HarnessPlugins.of(HarnessType.pi)
        XCTAssertEqual(Optional("01a03190-5463-719c-94f2-c8a627bc2e33"),
                pi.harnessSessionIdFromExit(piExit))
        XCTAssertEqual(Optional("pi --session 01a03190-5463-719c-94f2-c8a627bc2e33"),
                pi.resumeCommand("01a03190-5463-719c-94f2-c8a627bc2e33"))
    }

    func testUnrelatedResumeTextIsNotTreatedAsAnExitReceipt() {
        let conversation = Screen(
                "Try codex resume 0199f0a1-8b2c-7d3e-9f40-5a6b7c8d9e0f later",
                false, epoch, "zsh")
        XCTAssertNil(
                HarnessPlugins.of(HarnessType.codex).harnessSessionIdFromExit(conversation))
        XCTAssertNil(
                HarnessPlugins.of(HarnessType.claudeCode).harnessSessionIdFromExit(conversation))
        XCTAssertNil(
                HarnessPlugins.of(HarnessType.cursorAgent).harnessSessionIdFromExit(conversation))
        XCTAssertNil(
                HarnessPlugins.of(HarnessType.grok).harnessSessionIdFromExit(conversation))
        XCTAssertNil(
                HarnessPlugins.of(HarnessType.opencode).harnessSessionIdFromExit(conversation))
        XCTAssertNil(
                HarnessPlugins.of(HarnessType.pi).harnessSessionIdFromExit(conversation))
    }

    /**
     * Graceful close (Cmd/Ctrl+W) types these into the harness's own prompt, so a wrong
     * value lands in a conversation as a prompt. These are grounded against their
     * corresponding CLIs rather than inferred from a shared convention.
     */
    func testQuitSyntaxIsVerifiedOrAbsent() {
        XCTAssertEqual(Optional("/exit"), HarnessPlugins.of(HarnessType.claudeCode).quitCommand())
        XCTAssertEqual(Optional("/quit"), HarnessPlugins.of(HarnessType.codex).quitCommand())
        XCTAssertEqual(Optional("/quit"), HarnessPlugins.of(HarnessType.cursorAgent).quitCommand())
        XCTAssertEqual(Optional("/quit"), HarnessPlugins.of(HarnessType.grok).quitCommand())
        XCTAssertEqual(Optional("/exit"), HarnessPlugins.of(HarnessType.opencode).quitCommand())
        XCTAssertEqual(Optional("/quit"), HarnessPlugins.of(HarnessType.pi).quitCommand())
        XCTAssertEqual(Optional("exit"), HarnessPlugins.of(HarnessType.shell).quitCommand())
    }
}

