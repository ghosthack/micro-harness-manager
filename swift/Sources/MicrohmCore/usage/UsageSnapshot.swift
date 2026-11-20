import Foundation

/// Provider-neutral usage data rendered by the usage/limits dialog.
public struct UsageSnapshot: Equatable, Sendable {
    public let heading: String
    public let source: String
    public let limits: [Limit]
    public let statistics: [Statistic]
    public let note: String?

    public init(_ heading: String, _ source: String, _ limits: [Limit], _ statistics: [Statistic], _ note: String?) {
        self.heading = heading
        self.source = source
        self.limits = limits
        self.statistics = statistics
        self.note = note
    }

    /// A percentage-based provider limit and its optional reset time.
    public struct Limit: Equatable, Sendable {
        public let label: String
        public let usedPercent: Int
        public let resetsAt: Date?
        public let detail: String?

        public init(_ label: String, _ usedPercent: Int, _ resetsAt: Date?, _ detail: String?) {
            self.label = label
            self.usedPercent = min(max(usedPercent, 0), 100)
            self.resetsAt = resetsAt
            self.detail = detail
        }
    }

    /// A non-window aggregate such as lifetime tokens or an account credit balance.
    public struct Statistic: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }
}

/// A usage source failed: no credentials, an HTTP error, a timeout. `message` is the
/// user-facing text (Java's IOException messages, verbatim).
public struct UsageError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}
