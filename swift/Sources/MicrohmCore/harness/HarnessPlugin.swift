import Foundation

/// Per-harness bootstrap commands, plus the state-detection surface `StateDetector`
/// consults. Ported from harness-manager's `HarnessPlugin` — this app doesn't babysit, so
/// there's no nudge logic anywhere near this interface, but it does need to tell a
/// working session from an idle one for the sidebar badge.
///
/// Every member is a protocol requirement (with defaults in the extension below) so a
/// plugin's override is dispatched dynamically even through `any HarnessPlugin`. Java's
/// static members (`shellArgument`, `MCP_SERVER_NAME`, `MCP_TOKEN_ENV`) live on
/// `HarnessPlugins`.
public protocol HarnessPlugin: AnyObject, Sendable {

    var type: HarnessType { get }

    /// Command that starts the harness fresh, with no prior conversation. Blank means
    /// there is nothing to launch — the shell the daemon started in the session is
    /// already the harness (`ShellPlugin`) — and callers must skip send-keys rather than
    /// send an empty line.
    func launchCommand() -> String

    /// Command that resumes an existing harness conversation by id. Nil means this
    /// harness has no verified resume syntax — callers must not guess one.
    func resumeCommand(_ harnessSessionId: String) -> String?

    /// Command that starts a fresh conversation under an id the caller chose, so the id
    /// (and with it the transcript and a later resume) is known from the start rather
    /// than only once the harness exits. Nil means the harness can't be told its id.
    func launchCommandWithId(_ harnessSessionId: String) -> String?

    /// Whether a conversation with this id exists to resume in `project`, for a harness
    /// that can tell from local files. A conversation that was given its id at launch
    /// but never got a message has nothing to resume, and resuming it fails. The
    /// default, for harnesses that can't tell, is true.
    func canResume(_ harnessSessionId: String, _ project: URL) -> Bool

    /// Extracts the stable conversation selector printed by the harness while it exits.
    /// The graceful closer calls this on the shell screen returned by the native quit
    /// command, before it sends `exit` to that shell and ends the session. Nil means this
    /// harness has no grounded exit-receipt format.
    func harnessSessionIdFromExit(_ exitScreen: Screen) -> String?

    /// Text that, typed into the harness's own idle prompt and submitted, makes it exit
    /// gracefully — its own quit command, not a signal. Nil means no verified quit
    /// syntax: callers must refuse to close rather than guess, the same rule as
    /// `resumeCommand` (a guessed slash command lands in the conversation as a prompt).
    func quitCommand() -> String?

    /// The session's foreground process name while this harness runs, as the daemon's
    /// foreground probe reports it. Defaults to `type.id`; override when the profile
    /// name and the binary name differ.
    func processName() -> String

    /// Whether a pane whose foreground is `foregroundCommand` is running this harness.
    /// Equality with `processName()` by default; override when the harness execs into
    /// something else.
    func ownsProcess(_ foregroundCommand: String) -> Bool

    /// Blanks regions that repaint on a timer while the harness is waiting, so that
    /// screen quiescence still fires and the plugin still gets consulted. The motivating
    /// case is a countdown that never stops changing.
    func stripVolatile(_ screenText: String) -> String

    /// `command` — a shell line from `launchCommand` or `resumeCommand` — with the flags
    /// that register an HTTP MCP server named `HarnessPlugins.mcpServerName` at
    /// `endpoint` for this one run, so an agent launched in a session can reach the app's
    /// session controller. The token never appears in the returned line (it would land in
    /// shell history, process argv and the screen): the flags point at
    /// `McpEndpoint.configFile` (see `mcpConfigFile`) or name the
    /// `HarnessPlugins.mcpTokenEnv` environment variable instead. The default returns
    /// `command` unchanged: a harness without verified per-run MCP syntax simply does
    /// not get the server, the same don't-guess rule as `resumeCommand`. A blank command
    /// (the shell harness) is always returned as is.
    func withMcpServer(_ command: String, _ endpoint: McpEndpoint) -> String

    /// The contents of `McpEndpoint.configFile` for a harness whose `withMcpServer`
    /// flags read the server (token included) from that file, or nil when the harness
    /// needs no file. The launcher writes it owner-only before typing the command, and
    /// launches without MCP when it cannot.
    func mcpConfigFile(_ endpoint: McpEndpoint) -> String?

    /// The screen text reduced to what an agent would call "the content", for deciding
    /// whether a session's screen changed between two reads and for feeding change
    /// comparison: `stripVolatile`, then the harness's own UI chrome (composer, hint
    /// bars, spinners, positional footers) dropped line by line, then runs of blank lines
    /// collapsed to one and leading/trailing blank lines removed. Accepts both plain and
    /// annotated captures: a line's `"▶ "` selection prefix is ignored when deciding
    /// whether it is chrome, and the `"▮"` cursor marker is removed, so a moving cursor
    /// alone never reads as a change. The default drops no lines.
    func maskChrome(_ screenText: String) -> String

    /// Whether `withMcpServer` has the harness read its bearer token from the
    /// `HarnessPlugins.mcpTokenEnv` environment variable — only then does the launcher
    /// put the token into the session's environment (and only then does a daemon that
    /// cannot set an environment rule out MCP for the session). The default is false.
    func usesMcpTokenEnv() -> Bool

    /// Per-harness textual pattern layer, consulted once the screen is behaviorally
    /// quiescent. Nil falls back to the generic behavioral heuristics — expected
    /// whenever a harness UI update outruns these patterns.
    func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification?
}

public extension HarnessPlugin {
    func resumeCommand(_ harnessSessionId: String) -> String? { nil }
    func launchCommandWithId(_ harnessSessionId: String) -> String? { nil }
    func canResume(_ harnessSessionId: String, _ project: URL) -> Bool { true }
    func harnessSessionIdFromExit(_ exitScreen: Screen) -> String? { nil }
    func quitCommand() -> String? { nil }
    func processName() -> String { type.id }
    func ownsProcess(_ foregroundCommand: String) -> Bool { processName() == foregroundCommand }
    func stripVolatile(_ screenText: String) -> String { screenText }
    func withMcpServer(_ command: String, _ endpoint: McpEndpoint) -> String { command }
    func mcpConfigFile(_ endpoint: McpEndpoint) -> String? { nil }
    func maskChrome(_ screenText: String) -> String { ScreenMask.mask(stripVolatile(screenText)) { _ in false } }
    func usesMcpTokenEnv() -> Bool { false }
    func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? { nil }
}

/// The last match's selector from an exit receipt whose alternatives are a double-quoted,
/// a single-quoted and a bare form (groups 1–3), or group 1 alone.
func lastExitSelector(_ regex: JRegex, _ text: String) -> String? {
    var last: String?
    for groups in regex.allGroups(text) {
        last = groups.dropFirst().compactMap { $0 }.first
    }
    return last
}
