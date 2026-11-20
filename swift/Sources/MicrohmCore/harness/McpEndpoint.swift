import Foundation

/// Where an agent launched in one session reaches the app's MCP server, and how it
/// authenticates — everything `HarnessPlugin.withMcpServer` may need. The secret never
/// goes into the typed command line itself: a harness either reads it from `configFile`
/// (written by the launcher from `HarnessPlugin.mcpConfigFile`, owner-only) or from the
/// `MHM_MCP_TOKEN` environment variable the launcher puts into the session's environment.
///
/// - `url`: the session's MCP URL, carrying no token (`http://127.0.0.1:<port>/mcp/<session>`)
/// - `token`: the bearer token the server expects
/// - `configFile`: the per-session file a harness with a file-based MCP config uses
public struct McpEndpoint: Equatable, Sendable, CustomStringConvertible {
    public let url: String
    public let token: String
    public let configFile: URL

    public init(url: String, token: String, configFile: URL) {
        self.url = url
        self.token = token
        self.configFile = configFile
    }

    /// Hides the token, which must never reach a log line.
    public var description: String {
        "McpEndpoint[url=\(url), configFile=\(configFile.path)]"
    }
}
