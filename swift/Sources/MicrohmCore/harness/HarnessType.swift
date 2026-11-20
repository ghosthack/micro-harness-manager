import Foundation

/// The harness CLIs the manager knows how to bootstrap. The raw value is the stable id —
/// this is what's persisted in the registry JSON, not the case name.
public enum HarnessType: String, CaseIterable, Codable, Sendable, CustomStringConvertible {
    case claudeCode = "claude-code"
    case codex = "codex"
    case cursorAgent = "cursor-agent"
    case grok = "grok"
    case opencode = "opencode"
    case pi = "pi"
    case muse = "muse"
    /// No harness CLI at all — the pane just runs the user's default shell.
    case shell = "shell"

    public struct UnknownHarnessType: Error, CustomStringConvertible {
        public let id: String
        public var description: String { "unknown harness type: \(id)" }
    }

    /// Stable id — this is what's persisted in the registry JSON, not the enum name.
    public var id: String { rawValue }

    /// The Java enum constant name (`CLAUDE_CODE`, …).
    public var name: String { rawValue.uppercased().replacingOccurrences(of: "-", with: "_") }

    public static func fromId(_ id: String) throws -> HarnessType {
        guard let t = HarnessType(rawValue: id) else { throw UnknownHarnessType(id: id) }
        return t
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        self = try HarnessType.fromId(id)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
