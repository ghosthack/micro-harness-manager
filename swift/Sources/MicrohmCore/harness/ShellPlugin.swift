import Foundation

/// The "no harness" harness: the pane runs the user's default shell and nothing else.
/// The daemon's `new-session` already starts that shell, so there is no bootstrap
/// command to send — `launchCommand()` is blank, which callers treat as "skip send-keys"
/// rather than a command line.
///
/// State detection inverts the other plugins' liveness rule: for them a shell in the
/// foreground means the harness died, but here the shell *is* the harness, so
/// `ownsProcess` claims every shell `StateDetector` knows about. A foreground program the
/// user launched (vim, top, a build) is deliberately not claimed — it falls through to
/// the behavioral layer, which reads changing output as WORKING and long quiescence as
/// IDLE, which is as much as anyone can say about an arbitrary program.
public final class ShellPlugin: HarnessPlugin, @unchecked Sendable {

    public init() {}

    public var type: HarnessType { .shell }

    /// Blank on purpose — see the class comment. The one launch command that is not a
    /// command: the pane's own shell is already running when this is consulted.
    public func launchCommand() -> String { "" }

    // resumeCommand() stays at its nil default: shells have no conversation ids. The
    // "Open…" dialog warns and falls back to a fresh (blank) launch if one is supplied.

    /// A shell's own graceful quit. In practice graceful close never consults this — a
    /// shell foreground goes straight to the closer's exit stage — but it keeps the
    /// contract honest for a caller that asks the plugin directly.
    public func quitCommand() -> String? { "exit" }

    public func ownsProcess(_ foregroundCommand: String) -> Bool {
        StateDetector.isShell(foregroundCommand)
    }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        if StateDetector.isShell(screen.foregroundCommand) {
            return Classification(.idle, .high, "shell sitting at its prompt", .plugin)
        }
        return nil
    }
}
