import Foundation

/// A request the server refused, a protocol mismatch, a server that could not be started,
/// (with `isNoServer`) no server running where one is required, or (with `isUnsupported`)
/// an operation or option the running daemon predates. The message is meant for the user.
public struct SessionServerException: Error, CustomStringConvertible, LocalizedError {

    /// How every `isUnsupported` message starts.
    public static let UNSUPPORTED_PREFIX = "unsupported by this session daemon: "

    public let message: String
    public let isNoServer: Bool
    public let isUnsupported: Bool
    public let cause: Error?

    public init(_ message: String, cause: Error? = nil, noServer: Bool = false) {
        self.init(message, cause: cause, noServer: noServer, unsupported: false)
    }

    private init(_ message: String, cause: Error?, noServer: Bool, unsupported: Bool) {
        self.message = message
        self.cause = cause
        self.isNoServer = noServer
        self.isUnsupported = unsupported
    }

    public static func noServer(_ what: String) -> SessionServerException {
        SessionServerException("no such session: \(what) (no session server is running)", noServer: true)
    }

    /// The running daemon (same protocol, older build) lacks `what`; restarting it on the
    /// current build is the remedy.
    public static func unsupported(_ what: String) -> SessionServerException {
        SessionServerException(UNSUPPORTED_PREFIX + what + " (the running daemon predates it;"
                               + " finish its sessions or run `microhm-mux shutdown`, then retry)",
                               cause: nil, noServer: false, unsupported: true)
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
