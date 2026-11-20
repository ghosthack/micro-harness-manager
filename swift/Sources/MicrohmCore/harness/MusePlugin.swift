import Foundation

/// Muse Code 1.4.7: launch/resume help and live trusted/untrusted workspace captures
/// ground its bootstrap, trust/login prompts, echo-provider working/idle UI and /quit
/// receipt. The launcher execs a versioned native binary; the foreground probe truncates
/// its process name to "muse-bin-1.4.7-" on macOS. No safety or trust flags are added at
/// launch.
public final class MusePlugin: HarnessPlugin, @unchecked Sendable {

    private static let exitResume = JRegex(
        #"(?m)^\s*To continue this session, run muse resume "#
            + #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b"#)
    private static let working = JRegex(#"(?m)^\s*◇\s+Thinking\b"#)
    private static let border = JRegex(#"^(?:── Voice input .*─+|─{3,})$"#)

    public init() {}

    public var type: HarnessType { .muse }

    public func launchCommand() -> String { "muse" }

    public func ownsProcess(_ command: String) -> Bool {
        command == "muse" || JavaText.hasPrefix(command, "muse-bin-")
    }

    public func resumeCommand(_ sessionId: String) -> String? {
        "muse resume " + HarnessPlugins.shellArgument(sessionId)
    }

    public func quitCommand() -> String? { "/quit" }

    public func harnessSessionIdFromExit(_ screen: Screen) -> String? {
        lastExitSelector(MusePlugin.exitResume, screen.text)
    }

    public func maskChrome(_ text: String) -> String {
        let lines = ScreenMask.lines(text)
        var borderAt = -1
        var seen = 0
        var i = lines.count - 1
        while i >= 0 {
            if MusePlugin.border.matches(JavaText.strip(ScreenMask.plain(lines[i]))) {
                borderAt = i
                seen += 1
                if seen == 2 {
                    break
                }
            }
            i -= 1
        }
        return ScreenMask.join(borderAt >= 0 ? Array(lines[..<borderAt]) : lines)
    }

    public func classifyQuiescent(_ screen: Screen, _ quietFor: TimeInterval) -> Classification? {
        let tail = screen.tailLines(24).joined(separator: "\n")
        if tail.contains("Do you trust this workspace?") {
            return MusePlugin.classified(.waitingForInput, "workspace trust decision")
        }
        if tail.contains("Log in with browser") && tail.contains("Set an API key") {
            return MusePlugin.classified(.waitingForInput, "Muse login choice")
        }
        // Muse's documented approval choices; require the full pair, not quoted prose.
        if tail.contains("Allow once") && tail.contains("Always allow in this workspace")
            && tail.contains("Reject") {
            return MusePlugin.classified(.waitingForInput, "tool approval choices")
        }
        if MusePlugin.working.find(tail) {
            return MusePlugin.classified(.working, "Muse thinking indicator")
        }
        let content = JavaText.stripTrailing(maskChrome(tail))
        if JavaText.hasSuffix(content, "?") {
            return MusePlugin.classified(.waitingForInput, "trailing question above composer")
        }
        if JavaText.lines(tail).contains(where: { MusePlugin.border.matches(JavaText.strip($0)) }) {
            return MusePlugin.classified(.idle, "Muse composer without running-turn indicator")
        }
        return nil
    }

    private static func classified(_ state: SessionState, _ reason: String) -> Classification {
        Classification(state, .high, reason + " (Muse Code 1.4.7)", .plugin)
    }
}
