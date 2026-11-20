import Foundation

/// The slice of `host.SessionHost` (the app's session daemon seam, ported separately into
/// `host/`) that status polling and graceful close need. Defined here so this package
/// builds before — and independently of — the host port; `SessionHost` conforms by
/// declaring `extension SessionHost: StatusSessionHost` (or by refining it).
///
/// "No server running" semantics, as `SessionHost` documents them: `hasSession` is false,
/// `capture` reports a dead pane, and `sendKeys` throws. Java's `SessionHostException` is
/// unchecked; here a failure is any thrown error.
public protocol StatusSessionHost: AnyObject {

    func hasSession(_ session: String) throws -> Bool

    /// Sends `command` literally to the session, pauses, then Enter.
    func sendKeys(_ session: String, _ command: String) throws

    /// Captures the rendered screen for status polling. A missing session or dead pane
    /// yields `paneDead == true`. Read-only — never attaches a client.
    func capture(_ session: String) throws -> Screen
}
