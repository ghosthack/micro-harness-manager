import Foundation

/// Looks up the plugin for a `HarnessType`, and holds what Java kept as static members
/// of the `HarnessPlugin` interface.
public enum HarnessPlugins {

    private static let claudeCode = ClaudeCodePlugin()
    private static let codex = CodexPlugin()
    private static let cursorAgent = CursorAgentPlugin()
    private static let grok = GrokPlugin()
    private static let opencode = OpenCodePlugin()
    private static let pi = PiPlugin()
    private static let muse = MusePlugin()
    private static let shell = ShellPlugin()

    public static func of(_ type: HarnessType) -> HarnessPlugin {
        switch type {
        case .claudeCode: return claudeCode
        case .codex: return codex
        case .cursorAgent: return cursorAgent
        case .grok: return grok
        case .opencode: return opencode
        case .pi: return pi
        case .muse: return muse
        case .shell: return shell
        }
    }

    /// The name every injected MCP server is registered under in a harness's config
    /// (`HarnessPlugin.MCP_SERVER_NAME`).
    public static let mcpServerName = "micro-harness-manager"

    /// The environment variable a launched session carries the MCP token in, for
    /// harnesses that read a bearer token from the environment (`HarnessPlugin.MCP_TOKEN_ENV`).
    public static let mcpTokenEnv = "MHM_MCP_TOKEN"

    /// Sessions on this port type their commands into a POSIX shell (Java switched to
    /// PowerShell quoting on Windows).
    public static let windows = false

    private static let bareArgument = JRegex("[A-Za-z0-9_@%+=:,./-]+")

    /// Quotes a value as one argument for the shell a session's commands are typed into.
    /// UUID-like ids stay pleasantly readable; anything with spaces or punctuation is
    /// single-quoted: POSIX shells escape an inner quote as `'"'"'`, PowerShell as `''`.
    public static func shellArgument(_ value: String, powershell: Bool = windows) -> String {
        if bareArgument.matches(value) {
            return value
        }
        return powershell
            ? "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
            : "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
