import Foundation

/// One tool as advertised by `tools/list`: the name agents call, what it does (the
/// documentation agents actually read) and the JSON Schema of its `arguments` object.
public struct ToolDef: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: CoreJSON

    public init(_ name: String, _ description: String, _ inputSchema: CoreJSON) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// The outcome of one tool call: a single text content block, flagged as a tool-level
/// error (`isError`) when the call failed. Tool errors are results, not JSON-RPC errors,
/// so the agent sees the message.
public struct ToolResult: Equatable, Sendable {
    public let text: String
    public let isError: Bool

    public init(_ text: String, _ isError: Bool) {
        self.text = text
        self.isError = isError
    }

    public static func ok(_ text: String) -> ToolResult {
        ToolResult(text, false)
    }

    public static func error(_ text: String) -> ToolResult {
        ToolResult(text, true)
    }
}

/// The tools an `McpServer` exposes. The server owns the transport (HTTP, JSON-RPC, auth);
/// a toolset only describes its tools and answers calls.
public protocol McpToolset: AnyObject {

    /// The tools offered by `tools/list`, in display order.
    func tools() -> [ToolDef]

    /// Runs one `tools/call`. Errors thrown here become an `isError` result carrying the
    /// message; they never fail the HTTP request.
    ///
    /// - caller: the calling session's name from the URL path, or nil for an anonymous
    ///   caller (`/mcp` without a path segment)
    /// - tool: the tool name; may be one not listed by `tools()`
    /// - arguments: the call's `arguments` object (an empty object when absent)
    func call(_ caller: String?, _ tool: String, _ arguments: CoreJSON) throws -> ToolResult

    /// The hosting `McpService` started listening: start any background work the tools
    /// need (called after a successful start, also after each restart).
    func serverStarted()

    /// The hosting `McpService` stopped: stop that background work.
    func serverStopped()
}

public extension McpToolset {
    func serverStarted() {
    }

    func serverStopped() {
    }
}

/// A running server's per-session URL (no token in it) and its bearer token.
public struct McpLink: Equatable, Sendable, CustomStringConvertible {
    public let url: String
    public let token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    /// Never prints the token.
    public var description: String { "McpLink[url=\(url)]" }
}
