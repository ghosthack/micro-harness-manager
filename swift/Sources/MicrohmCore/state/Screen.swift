import Foundation

/// One capture of a session's rendered text, plus its foreground process name when the
/// daemon could report it. `paneTitle` is the title the program in the session
/// set via OSC (e.g. Claude Code's /rename), empty when never set or the daemon couldn't
/// report it. `paneProcessId` is the session shell's PID, used to discover provider
/// metadata without changing pane contents (-1 when unknown).
public struct Screen: Equatable, Sendable {
    public let text: String
    public let paneDead: Bool
    public let capturedAt: Date
    public let foregroundCommand: String
    public let paneProcessId: Int64
    public let paneTitle: String

    public init(text: String, paneDead: Bool, capturedAt: Date, foregroundCommand: String = "",
                paneProcessId: Int64 = -1, paneTitle: String = "") {
        self.text = text
        self.paneDead = paneDead
        self.capturedAt = capturedAt
        self.foregroundCommand = foregroundCommand
        self.paneProcessId = paneProcessId
        self.paneTitle = paneTitle
    }

    /// Positional form mirroring the Java record constructors.
    public init(_ text: String, _ paneDead: Bool, _ capturedAt: Date, _ foregroundCommand: String = "",
                _ paneProcessId: Int64 = -1, _ paneTitle: String = "") {
        self.init(text: text, paneDead: paneDead, capturedAt: capturedAt, foregroundCommand: foregroundCommand,
                  paneProcessId: paneProcessId, paneTitle: paneTitle)
    }

    /// Last `n` non-blank lines, oldest first — the region prompts live in.
    public func tailLines(_ n: Int) -> [String] {
        let nonBlank = JavaText.lines(text).filter { !JavaText.isBlank($0) }
        return Array(nonBlank[max(0, nonBlank.count - n)...])
    }
}
