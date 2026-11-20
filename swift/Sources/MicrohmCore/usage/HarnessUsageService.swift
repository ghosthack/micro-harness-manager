import Foundation

/// Selects the live usage source for a harness family.
public final class HarnessUsageService: @unchecked Sendable {

    private let claude = ClaudeUsageClient()
    private let codex = CodexUsageClient()

    public init() {}

    /// Blocking (an HTTP round trip or an app-server exchange) — never on the main thread.
    public func load(_ harness: HarnessType) throws -> UsageSnapshot {
        switch harness {
        case .claudeCode:
            return try claude.load()
        case .codex:
            return try codex.load()
        case .cursorAgent:
            return HarnessUsageService.unavailable("Cursor Agent", "Cursor Settings → Usage",
                "Cursor does not publish individual-plan usage through its CLI or a public API.")
        case .grok:
            return HarnessUsageService.unavailable("Grok", "xAI account settings",
                "Grok's CLI exposes context-window usage via /status but no session or "
                    + "weekly provider budget, and there is no public usage API to poll instead.")
        case .opencode:
            return HarnessUsageService.unavailable("OpenCode", "opencode stats",
                "opencode is provider-agnostic — its own `stats` command reports token/cost "
                    + "totals it tallied locally across whichever providers are configured, "
                    + "not a session or weekly budget from a single provider account, so "
                    + "there is no one budget to poll.")
        case .pi:
            return HarnessUsageService.unavailable("Pi", "/session",
                "pi is provider-agnostic — --provider/--model select whichever of google, "
                    + "openai, anthropic, xai, or another configured provider a session uses, "
                    + "so there is no single provider account to poll for a session or weekly "
                    + "budget; its own /session command and footer report local cost/token "
                    + "totals instead.")
        case .muse:
            return HarnessUsageService.unavailable("Muse Code", "Meta AI account usage",
                "Muse's live provider budget is not integrated. Check your Meta AI account for usage.")
        case .shell:
            return HarnessUsageService.unavailable("Shell", "Local shell",
                "A shell has no model usage or provider limits.")
        }
    }

    private static func unavailable(_ heading: String, _ source: String, _ note: String) -> UsageSnapshot {
        UsageSnapshot(heading, source, [], [], note)
    }
}
