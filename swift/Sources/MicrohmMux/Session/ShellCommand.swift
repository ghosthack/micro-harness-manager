import Foundation

/// What a session runs and the environment it runs in.
///
/// Command: an explicit command when the caller gave one; otherwise the login shell —
/// `$SHELL` (fallback `/bin/sh`) with `-l`.
///
/// Environment: the daemon's own, plus `TERM=xterm-256color`, `COLORTERM=truecolor`,
/// `LANG` defaulted to `en_US.UTF-8` and `MICROHM_SESSION=<name>`, then the caller's extra
/// variables (which may override `COLORTERM`, `LANG` or anything inherited, but never
/// `TERM` or `MICROHM_SESSION`). (The Java original also chose a Windows shell; this port is
/// macOS only.)
public struct ShellCommand: Equatable, Sendable {

    static let TERM = "xterm-256color"
    static let DEFAULT_LANG = "en_US.UTF-8"

    /// argv, never empty
    public let command: [String]
    /// the complete environment for the PTY process
    public let environment: [String: String]

    public init(command: [String], environment: [String: String]) {
        precondition(!command.isEmpty, "command must not be empty")
        self.command = command
        self.environment = environment
    }

    /// The command for `sessionName` on this machine: `explicitCommand` (nil/empty = the
    /// login shell) with the session environment and `extraEnvironment` merged over it.
    public static func forSession(_ sessionName: String, _ explicitCommand: [String]?,
                                  _ extraEnvironment: [String: String]? = nil) -> ShellCommand {
        build(sessionName, explicitCommand, ProcessInfo.processInfo.environment, extraEnvironment)
    }

    /// The pure core of `forSession`: every input is a parameter so it is unit-testable.
    static func build(_ sessionName: String, _ explicitCommand: [String]?, _ inherited: [String: String],
                      _ extra: [String: String]? = nil) -> ShellCommand {
        let command: [String]
        if let explicitCommand, !explicitCommand.isEmpty {
            command = explicitCommand
        } else {
            command = unixShell(inherited)
        }
        var env = inherited
        for marker in AGENT_PROCESS_MARKERS { env.removeValue(forKey: marker) }
        env["TERM"] = TERM
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = DEFAULT_LANG }
        if let extra {
            env.merge(extra) { _, new in new }
        }
        // Not overridable: the emulator is xterm-256color and the name is the session's.
        env["TERM"] = TERM
        env["MICROHM_SESSION"] = sessionName
        return ShellCommand(command: command, environment: env)
    }

    /// Variables a coding agent sets for its own process and its children, which a session
    /// must not inherit when the daemon (or the app before it) was started from inside one:
    /// a terminal running Claude Code, say, or a Claude Code session in Microhm itself. With
    /// them, a `claude` started in the session takes itself for that agent's child and,
    /// among other things, does not save its transcript, so the conversation cannot be
    /// resumed. Settings users put in their environment (`CLAUDE_CODE_USE_BEDROCK` and the
    /// like) are not markers and pass through.
    static let AGENT_PROCESS_MARKERS: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    private static func unixShell(_ inherited: [String: String]) -> [String] {
        var shell = inherited["SHELL"] ?? ""
        if shell.trimmingCharacters(in: .whitespaces).isEmpty {
            shell = "/bin/sh"
        }
        return [shell, "-l"]
    }
}
