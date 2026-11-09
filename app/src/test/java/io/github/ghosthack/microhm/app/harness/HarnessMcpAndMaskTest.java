package io.github.ghosthack.microhm.app.harness;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

/**
 * Pins {@link HarnessPlugin#withMcpServer} (the exact shell line a session is launched
 * with) and {@link HarnessPlugin#maskChrome} (what counts as "the content changed")
 * per plugin. The screens reuse the shapes {@link StateDetectorTest} was grounded on.
 */
final class HarnessMcpAndMaskTest {

    private static final String URL = "http://127.0.0.1:7391/mcp/mhm-proj";
    private static final String TOKEN = "abc_DEF-123";
    private static final McpEndpoint MCP = new McpEndpoint(URL, TOKEN,
            Path.of("/home/u/.micro-harness-manager/mcp/mhm-proj.json"));

    // ---- withMcpServer

    /** POSIX paths and quoting; Windows is {@link #powershellQuotingDoublesInnerQuotes}. */
    @Test
    @org.junit.jupiter.api.condition.DisabledOnOs(org.junit.jupiter.api.condition.OS.WINDOWS)
    void claudeGetsItsMcpConfigFileBeforeItsResumeFlag() {
        HarnessPlugin claude = new ClaudeCodePlugin();
        String flag = "--mcp-config /home/u/.micro-harness-manager/mcp/mhm-proj.json"; // nothing to quote
        assertEquals("claude " + flag, claude.withMcpServer(claude.launchCommand(), MCP));
        assertEquals("claude " + flag + " --resume 0b4a-9", claude.withMcpServer(
                claude.resumeCommand("0b4a-9").orElseThrow(), MCP));
    }

    @Test
    void claudesConfigFileCarriesTheUrlAndTheTokenAsABearerHeader() {
        assertEquals(Optional.of("{\"mcpServers\":{\"micro-harness-manager\":{\"type\":\"http\",\"url\":\"" + URL
                        + "\",\"headers\":{\"Authorization\":\"Bearer " + TOKEN + "\"}}}}\n"),
                new ClaudeCodePlugin().mcpConfigFile(MCP));
    }

    @Test
    void codexGetsUrlAndTokenEnvOverridesAheadOfTheResumeSubcommand() {
        HarnessPlugin codex = new CodexPlugin();
        String flags = "-c 'mcp_servers.micro-harness-manager.url=\"" + URL + "\"'"
                + " -c 'mcp_servers.micro-harness-manager.bearer_token_env_var=\"MHM_MCP_TOKEN\"'";
        assertEquals("codex " + flags, codex.withMcpServer("codex", MCP));
        assertEquals("codex " + flags + " resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
                codex.withMcpServer(codex.resumeCommand("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b").orElseThrow(), MCP));
        assertEquals(Optional.empty(), codex.mcpConfigFile(MCP), "codex reads the token from the environment");
    }

    @Test
    void onlyCodexReadsTheTokenFromTheEnvironment() {
        for (HarnessType type : HarnessType.values()) {
            assertEquals(type == HarnessType.CODEX, HarnessPlugins.of(type).usesMcpTokenEnv(), type.id());
        }
    }

    @Test
    void theTokenNeverReachesTheTypedLine() {
        for (HarnessType type : HarnessType.values()) {
            HarnessPlugin plugin = HarnessPlugins.of(type);
            String line = plugin.withMcpServer(plugin.launchCommand(), MCP);
            assertFalse(line.contains(TOKEN), type.id() + ": " + line);
        }
    }

    /** POSIX paths and quoting; Windows is {@link #powershellQuotingDoublesInnerQuotes}. */
    @Test
    @org.junit.jupiter.api.condition.DisabledOnOs(org.junit.jupiter.api.condition.OS.WINDOWS)
    void oddPathsAndUrlsStayOneQuotedArgument() {
        McpEndpoint odd = new McpEndpoint("http://127.0.0.1:1/mcp/it's\"x", "t",
                Path.of("/home/o'neil/.micro-harness-manager/mcp/a b.json"));
        assertEquals("claude --mcp-config '/home/o'\"'\"'neil/.micro-harness-manager/mcp/a b.json'",
                new ClaudeCodePlugin().withMcpServer("claude", odd));
        assertEquals("codex -c 'mcp_servers.micro-harness-manager.url=\"http://127.0.0.1:1/mcp/it'\"'\"'s\\\"x\"'"
                        + " -c 'mcp_servers.micro-harness-manager.bearer_token_env_var=\"MHM_MCP_TOKEN\"'",
                new CodexPlugin().withMcpServer("codex", odd));
    }

    @Test
    void unsupportedHarnessesAndForeignCommandsAreLeftAlone() {
        for (HarnessType type : new HarnessType[] {HarnessType.CURSOR_AGENT, HarnessType.GROK,
                HarnessType.OPENCODE, HarnessType.PI, HarnessType.MUSE, HarnessType.SHELL}) {
            HarnessPlugin plugin = HarnessPlugins.of(type);
            assertEquals(plugin.launchCommand(), plugin.withMcpServer(plugin.launchCommand(), MCP), type.id());
            assertEquals(Optional.empty(), plugin.mcpConfigFile(MCP), type.id());
        }
        // a command that is not the harness's own binary (e.g. a user-edited alias) is not touched
        assertEquals("claudex --resume x", new ClaudeCodePlugin().withMcpServer("claudex --resume x", MCP));
        assertEquals("", new CodexPlugin().withMcpServer("", MCP));
    }

    @Test
    void anEndpointNeverPrintsItsToken() {
        assertFalse(MCP.toString().contains(TOKEN), MCP.toString());
    }

    // ---- maskChrome

    @Test
    void defaultMaskCollapsesBlankRunsAndDropsTheCursorMarker() {
        HarnessPlugin shell = HarnessPlugins.of(HarnessType.SHELL);
        assertEquals("$ ls\na  b\n\n$", shell.maskChrome("\n\n$ ls   \na  b\n\n\n\n$ ▮\n\n"));
        assertEquals(shell.maskChrome("$ echo hi▮\n"), shell.maskChrome("$ echo hi\n"));
    }

    @Test
    void claudeMaskDropsTheInputBoxHintsAndSpinnerLine() {
        HarnessPlugin claude = new ClaudeCodePlugin();
        String working = """
                ● Reading the parser.

                ✻ Thinking… (12s · esc to interrupt)
                ────────────────────────────────
                ❯ ▮
                ────────────────────────────────
                  ⏵⏵ auto mode on (shift+tab to cycle)
                """;
        assertEquals("● Reading the parser.", claude.maskChrome(working));
        assertEquals(claude.maskChrome(working), claude.maskChrome(working.replace("12s", "13s")),
                "the turn timer is chrome");
        assertNotEquals(claude.maskChrome(working),
                claude.maskChrome(working.replace("● Reading the parser.", "● Reading the lexer.")));
    }

    @Test
    void codexMaskDropsTheComposerTheRunningLineAndTheFooterByPosition() {
        HarnessPlugin codex = new CodexPlugin();
        String idle = """
                • Done: renamed the module.

                › Ask Codex to do anything
                  gpt-5.6-sol high · /private/tmp/codex-scratch
                """;
        assertEquals("• Done: renamed the module.", codex.maskChrome(idle));
        // an annotated capture: the composer row is highlighted and holds the cursor
        String annotated = """
                • Done: renamed the module.

                ▶ › ▮Ask Codex to do anything
                  gpt-5.6-sol high · /private/tmp/other-dir
                """;
        assertEquals(codex.maskChrome(idle), codex.maskChrome(annotated));
        String running = """
                • Running tests

                • Working (5s • esc to interrupt)

                › Ask Codex to do anything
                  gpt-5.6-sol high · /private/tmp/codex-scratch
                """;
        assertEquals("• Running tests", codex.maskChrome(running));
        // an indented content line that is not below a composer is not a footer
        assertEquals("• Plan:\n  1 step left", codex.maskChrome("• Plan:\n  1 step left\n"));
    }

    @Test
    void codexMaskNormalizesTheAutoResolveCountdown() {
        HarnessPlugin codex = new CodexPlugin();
        String frame = "  Question 1/1 (1 unanswered) · auto-resolves in %ds\n  Pick one\n";
        assertEquals(codex.maskChrome(frame.formatted(52)), codex.maskChrome(frame.formatted(51)));
    }

    @Test
    void openCodeMaskCutsAtTheComposerBorder() {
        HarnessPlugin openCode = HarnessPlugins.of(HarnessType.OPENCODE);
        String idle = """
                The directory is empty — just . and .., no files or subdirectories.

                ▣  Build · Big Pickle · 5.4s

                ┃
                ┃  Build · Big Pickle OpenCode Zen
                ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
                 /Users/sample/Projects/sample/harness-manager                        8.3K (4%)ctrl+p
                                                                                                 commands
                """;
        assertEquals("The directory is empty — just . and .., no files or subdirectories.",
                openCode.maskChrome(idle));
        assertEquals(openCode.maskChrome(idle), openCode.maskChrome(idle.replace("8.3K (4%)", "9.1K (5%)")));
    }

    @Test
    void piMaskKeepsOnlyTheTranscriptAboveTheComposerFrame() {
        HarnessPlugin pi = HarnessPlugins.of(HarnessType.PI);
        String idle = """
                Hi.

                This directory is empty — only . and .. are present.

                ────────────────────────────────────────────────────────────────
                draft▮
                ────────────────────────────────────────────────────────────────
                /Users/sample/Projects/sample/harness-manager
                $0.005 (sub) 0.4%/500k (auto)                    (xai) grok-4.6 • medium
                """;
        assertEquals("Hi.\n\nThis directory is empty — only . and .. are present.", pi.maskChrome(idle));
        assertEquals(pi.maskChrome(idle), pi.maskChrome(idle.replace("$0.005", "$0.006")));
    }

    @Test
    void grokMaskStripsBubbleClocksAndTheComposerBox() {
        HarnessPlugin grok = HarnessPlugins.of(HarnessType.GROK);
        String idle = """
                Should notes/item_14.txt contain option A or option B?                    6:05 PM

                ╭──────────────────────────────────────────────╮
                │ ❯                                              │
                ╰──────────────────────────────────────── Grok 4.6 (high) ─╯
                Shift+Tab:mode  │  Ctrl+x:shortcuts
                """;
        assertEquals("Should notes/item_14.txt contain option A or option B?", grok.maskChrome(idle));
    }

    @Test
    void grokMaskDropsTheStatusRowCounterAndScrollArrowAndCutsTheScrollbar() {
        HarnessPlugin grok = HarnessPlugins.of(HarnessType.GROK);
        // as recorded live at 120 columns, mid-answer
        String working = """
                  /p/t/c/-/5/scratchpad/grokprobe                                      19K / 256K │ [Dashboard]

                                                                           ▲
                     99. Sperm whales can dive for more than an hour.
                    100. Narwhals are Arctic whales known for a long spiral tusk.      █
                                                                                       █
                   ⠙ Responding… 3.6s                                          10s ⇣1.68k [stop]
                """;
        String masked = "     99. Sperm whales can dive for more than an hour.\n"
                + "    100. Narwhals are Arctic whales known for a long spiral tusk.";
        assertEquals(masked, grok.maskChrome(working));
        assertEquals(masked, grok.maskChrome(working.replace("19K", "21K").replace("⠙ Responding… 3.6s", "⠴ Responding… 5.3s")
                .replace("tusk.      █", "tusk.       ")), "spinner, counter and scrollbar moves are no change");
    }

    @Test
    void cursorAgentMaskDropsTheFollowUpBoxAndStatusLines() {
        HarnessPlugin cursor = HarnessPlugins.of(HarnessType.CURSOR_AGENT);
        String idle = """
                  Item 12 is done: created notes/item_12.txt and checked it off.
                  Waiting for further instructions.
                  → Add a follow-up
                  Auto Balance · 7.3% · 1 file edited
                  /private/tmp/babysit-scratch
                """;
        assertEquals("  Item 12 is done: created notes/item_12.txt and checked it off.\n"
                + "  Waiting for further instructions.", cursor.maskChrome(idle));
    }

    @Test
    void aMovedSelectionIsAChange() {
        HarnessPlugin shell = HarnessPlugins.of(HarnessType.SHELL);
        assertNotEquals(shell.maskChrome("▶ 1. Yes\n  2. No\n"), shell.maskChrome("  1. Yes\n▶ 2. No\n"));
    }

    /** On Windows commands are typed into PowerShell, where a single-quoted string escapes
     * an inner quote by doubling it (POSIX's '"'"' would end the string there). */
    @Test
    void powershellQuotingDoublesInnerQuotes() {
        assertEquals("'C:\\Users\\o''neil\\mcp\\a b.json'",
                HarnessPlugin.shellArgument("C:\\Users\\o'neil\\mcp\\a b.json", true));
        assertEquals("'it'\"'\"'s'", HarnessPlugin.shellArgument("it's", false));
        assertEquals("01a03190-5463-719c", HarnessPlugin.shellArgument("01a03190-5463-719c", true), "ids stay bare");
    }
}
