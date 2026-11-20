import Foundation
import XCTest
@testable import MicrohmCore





/**
 * Pins `HarnessPlugin#withMcpServer` (the exact shell line a session is launched
 * with) and `HarnessPlugin#maskChrome` (what counts as "the content changed")
 * per plugin. The screens reuse the shapes `StateDetectorTest` was grounded on.
 */
final class HarnessMcpAndMaskTests: XCTestCase {

    private let URL_ = "http://127.0.0.1:7391/mcp/mhm-proj"
    private let TOKEN = "abc_DEF-123"
    private var MCP: McpEndpoint {
        McpEndpoint(url: URL_, token: TOKEN,
                    configFile: URL(fileURLWithPath: "/home/u/.micro-harness-manager/mcp/mhm-proj.json"))
    }

    // ---- withMcpServer

    /** POSIX paths and quoting; Windows is `#powershellQuotingDoublesInnerQuotes`. */
    func testClaudeGetsItsMcpConfigFileBeforeItsResumeFlag() {
        let claude = ClaudeCodePlugin()
        let flag = "--mcp-config /home/u/.micro-harness-manager/mcp/mhm-proj.json" // nothing to quote
        XCTAssertEqual("claude " + flag, claude.withMcpServer(claude.launchCommand(), MCP))
        XCTAssertEqual("claude " + flag + " --resume 0b4a-9", claude.withMcpServer(
                claude.resumeCommand("0b4a-9")!, MCP))
    }

    func testClaudesConfigFileCarriesTheUrlAndTheTokenAsABearerHeader() {
        XCTAssertEqual(Optional("{\"mcpServers\":{\"micro-harness-manager\":{\"type\":\"http\",\"url\":\"" + URL_
                        + "\",\"headers\":{\"Authorization\":\"Bearer " + TOKEN + "\"}}}}\n"),
                ClaudeCodePlugin().mcpConfigFile(MCP))
    }

    func testCodexGetsUrlAndTokenEnvOverridesAheadOfTheResumeSubcommand() {
        let codex = CodexPlugin()
        let flags = "-c 'mcp_servers.micro-harness-manager.url=\"" + URL_ + "\"'"
                + " -c 'mcp_servers.micro-harness-manager.bearer_token_env_var=\"MHM_MCP_TOKEN\"'"
        XCTAssertEqual("codex " + flags, codex.withMcpServer("codex", MCP))
        XCTAssertEqual("codex " + flags + " resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
                codex.withMcpServer(codex.resumeCommand("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")!, MCP))
        XCTAssertNil( codex.mcpConfigFile(MCP), "codex reads the token from the environment")
    }

    func testOnlyCodexReadsTheTokenFromTheEnvironment() {
        for type in HarnessType.allCases {
            XCTAssertEqual(type == HarnessType.codex, HarnessPlugins.of(type).usesMcpTokenEnv(), type.id)
        }
    }

    func testTheTokenNeverReachesTheTypedLine() {
        for type in HarnessType.allCases {
            let plugin = HarnessPlugins.of(type)
            let line = plugin.withMcpServer(plugin.launchCommand(), MCP)
            XCTAssertFalse(line.contains(TOKEN), type.id + ": " + line)
        }
    }

    /** POSIX paths and quoting; Windows is `#powershellQuotingDoublesInnerQuotes`. */
    func testOddPathsAndUrlsStayOneQuotedArgument() {
        let odd = McpEndpoint(url: "http://127.0.0.1:1/mcp/it's\"x", token: "t",
                configFile: URL(fileURLWithPath: "/home/o'neil/.micro-harness-manager/mcp/a b.json"))
        XCTAssertEqual("claude --mcp-config '/home/o'\"'\"'neil/.micro-harness-manager/mcp/a b.json'",
                ClaudeCodePlugin().withMcpServer("claude", odd))
        XCTAssertEqual("codex -c 'mcp_servers.micro-harness-manager.url=\"http://127.0.0.1:1/mcp/it'\"'\"'s\\\"x\"'"
                        + " -c 'mcp_servers.micro-harness-manager.bearer_token_env_var=\"MHM_MCP_TOKEN\"'",
                CodexPlugin().withMcpServer("codex", odd))
    }

    func testUnsupportedHarnessesAndForeignCommandsAreLeftAlone() {
        for type in [HarnessType.cursorAgent, HarnessType.grok,
                HarnessType.opencode, HarnessType.pi, HarnessType.muse, HarnessType.shell] {
            let plugin = HarnessPlugins.of(type)
            XCTAssertEqual(plugin.launchCommand(), plugin.withMcpServer(plugin.launchCommand(), MCP), type.id)
            XCTAssertNil( plugin.mcpConfigFile(MCP), type.id)
        }
        // a command that is not the harness's own binary (e.g. a user-edited alias) is not touched
        XCTAssertEqual("claudex --resume x", ClaudeCodePlugin().withMcpServer("claudex --resume x", MCP))
        XCTAssertEqual("", CodexPlugin().withMcpServer("", MCP))
    }

    func testAnEndpointNeverPrintsItsToken() {
        XCTAssertFalse(MCP.description.contains(TOKEN), MCP.description)
    }

    // ---- maskChrome

    func testDefaultMaskCollapsesBlankRunsAndDropsTheCursorMarker() {
        let shell = HarnessPlugins.of(HarnessType.shell)
        XCTAssertEqual("$ ls\na  b\n\n$", shell.maskChrome("\n\n$ ls   \na  b\n\n\n\n$ ▮\n\n"))
        XCTAssertEqual(shell.maskChrome("$ echo hi▮\n"), shell.maskChrome("$ echo hi\n"))
    }

    func testClaudeMaskDropsTheInputBoxHintsAndSpinnerLine() {
        let claude = ClaudeCodePlugin()
        let working = """
            ● Reading the parser.

            ✻ Thinking… (12s · esc to interrupt)
            ────────────────────────────────
            ❯ ▮
            ────────────────────────────────
              ⏵⏵ auto mode on (shift+tab to cycle)

            """
        XCTAssertEqual("● Reading the parser.", claude.maskChrome(working))
        XCTAssertEqual(claude.maskChrome(working), claude.maskChrome(working.replacingOccurrences(of: "12s", with: "13s")),
                "the turn timer is chrome")
        XCTAssertNotEqual(claude.maskChrome(working),
                claude.maskChrome(working.replacingOccurrences(of: "● Reading the parser.", with: "● Reading the lexer.")))
    }

    func testCodexMaskDropsTheComposerTheRunningLineAndTheFooterByPosition() {
        let codex = CodexPlugin()
        let idle = """
            • Done: renamed the module.

            › Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/codex-scratch

            """
        XCTAssertEqual("• Done: renamed the module.", codex.maskChrome(idle))
        // an annotated capture: the composer row is highlighted and holds the cursor
        let annotated = """
            • Done: renamed the module.

            ▶ › ▮Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/other-dir

            """
        XCTAssertEqual(codex.maskChrome(idle), codex.maskChrome(annotated))
        let running = """
            • Running tests

            • Working (5s • esc to interrupt)

            › Ask Codex to do anything
              gpt-5.6-sol high · /private/tmp/codex-scratch

            """
        XCTAssertEqual("• Running tests", codex.maskChrome(running))
        // an indented content line that is not below a composer is not a footer
        XCTAssertEqual("• Plan:\n  1 step left", codex.maskChrome("• Plan:\n  1 step left\n"))
    }

    func testCodexMaskNormalizesTheAutoResolveCountdown() {
        let codex = CodexPlugin()
        let frame = "  Question 1/1 (1 unanswered) · auto-resolves in %ds\n  Pick one\n"
        XCTAssertEqual(codex.maskChrome(String(format: frame, 52)), codex.maskChrome(String(format: frame, 51)))
    }

    func testOpenCodeMaskCutsAtTheComposerBorder() {
        let openCode = HarnessPlugins.of(HarnessType.opencode)
        let idle = """
            The directory is empty — just . and .., no files or subdirectories.

            ▣  Build · Big Pickle · 5.4s

            ┃
            ┃  Build · Big Pickle OpenCode Zen
            ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
             /Users/sample/Projects/sample/harness-manager                        8.3K (4%)ctrl+p
                                                                                             commands

            """
        XCTAssertEqual("The directory is empty — just . and .., no files or subdirectories.",
                openCode.maskChrome(idle))
        XCTAssertEqual(openCode.maskChrome(idle), openCode.maskChrome(idle.replacingOccurrences(of: "8.3K (4%)", with: "9.1K (5%)")))
    }

    func testPiMaskKeepsOnlyTheTranscriptAboveTheComposerFrame() {
        let pi = HarnessPlugins.of(HarnessType.pi)
        let idle = """
            Hi.

            This directory is empty — only . and .. are present.

            ────────────────────────────────────────────────────────────────
            draft▮
            ────────────────────────────────────────────────────────────────
            /Users/sample/Projects/sample/harness-manager
            $0.005 (sub) 0.4%/500k (auto)                    (xai) grok-4.6 • medium

            """
        XCTAssertEqual("Hi.\n\nThis directory is empty — only . and .. are present.", pi.maskChrome(idle))
        XCTAssertEqual(pi.maskChrome(idle), pi.maskChrome(idle.replacingOccurrences(of: "$0.005", with: "$0.006")))
    }

    func testGrokMaskStripsBubbleClocksAndTheComposerBox() {
        let grok = HarnessPlugins.of(HarnessType.grok)
        let idle = """
            Should notes/item_14.txt contain option A or option B?                    6:05 PM

            ╭──────────────────────────────────────────────╮
            │ ❯                                              │
            ╰──────────────────────────────────────── Grok 4.6 (high) ─╯
            Shift+Tab:mode  │  Ctrl+x:shortcuts

            """
        XCTAssertEqual("Should notes/item_14.txt contain option A or option B?", grok.maskChrome(idle))
    }

    func testGrokMaskDropsTheStatusRowCounterAndScrollArrowAndCutsTheScrollbar() {
        let grok = HarnessPlugins.of(HarnessType.grok)
        // as recorded live at 120 columns, mid-answer
        let working = """
              /p/t/c/-/5/scratchpad/grokprobe                                      19K / 256K │ [Dashboard]

                                                                       ▲
                 99. Sperm whales can dive for more than an hour.
                100. Narwhals are Arctic whales known for a long spiral tusk.      █
                                                                                   █
               ⠙ Responding… 3.6s                                          10s ⇣1.68k [stop]

            """
        let masked = "     99. Sperm whales can dive for more than an hour.\n"
                + "    100. Narwhals are Arctic whales known for a long spiral tusk."
        XCTAssertEqual(masked, grok.maskChrome(working))
        XCTAssertEqual(masked, grok.maskChrome(working.replacingOccurrences(of: "19K", with: "21K").replacingOccurrences(of: "⠙ Responding… 3.6s", with: "⠴ Responding… 5.3s")
                .replacingOccurrences(of: "tusk.      █", with: "tusk.       ")), "spinner, counter and scrollbar moves are no change")
    }

    func testCursorAgentMaskDropsTheFollowUpBoxAndStatusLines() {
        let cursor = HarnessPlugins.of(HarnessType.cursorAgent)
        let idle = """
              Item 12 is done: created notes/item_12.txt and checked it off.
              Waiting for further instructions.
              → Add a follow-up
              Auto Balance · 7.3% · 1 file edited
              /private/tmp/babysit-scratch

            """
        XCTAssertEqual("  Item 12 is done: created notes/item_12.txt and checked it off.\n"
                + "  Waiting for further instructions.", cursor.maskChrome(idle))
    }

    func testAMovedSelectionIsAChange() {
        let shell = HarnessPlugins.of(HarnessType.shell)
        XCTAssertNotEqual(shell.maskChrome("▶ 1. Yes\n  2. No\n"), shell.maskChrome("  1. Yes\n▶ 2. No\n"))
    }

    /** On Windows commands are typed into PowerShell, where a single-quoted string escapes
     * an inner quote by doubling it (POSIX's '"'"' would end the string there). */
    func testPowershellQuotingDoublesInnerQuotes() {
        XCTAssertEqual("'C:\\Users\\o''neil\\mcp\\a b.json'",
                HarnessPlugins.shellArgument("C:\\Users\\o'neil\\mcp\\a b.json", powershell: true))
        XCTAssertEqual("'it'\"'\"'s'", HarnessPlugins.shellArgument("it's", powershell: false))
        XCTAssertEqual("01a03190-5463-719c", HarnessPlugins.shellArgument("01a03190-5463-719c", powershell: true), "ids stay bare")
    }
}

