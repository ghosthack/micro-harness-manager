import Foundation

/// Derives `mhm-`-prefixed session names that are safe and, given a collision check,
/// unique.
public enum SessionNaming {

    private static let unsafe = JRegex("[^A-Za-z0-9_-]+")

    public struct NamingExhausted: Error, CustomStringConvertible {
        public let project: String
        public var description: String { "could not derive a unique session name for \(project)" }
    }

    /// Base name from a project directory, e.g. `/Users/x/Projects/foo` -> `mhm-foo`.
    /// `taken` should report whether a candidate name is already in use (registry entry
    /// or live session) so the caller can suffix `-2`, `-3`, ... until free.
    public static func deriveUnique(_ projectPath: URL, _ taken: (String) -> Bool) throws -> String {
        let base = PathCompat.normalize(projectPath)
        let rawBasename = PathCompat.components(base).last ?? "root"
        var sanitized = unsafe.replaceAll(rawBasename, with: "-")
        if JavaText.isBlank(sanitized) {
            sanitized = "session"
        }
        let candidate = Reconciler.sessionPrefix + sanitized
        if !taken(candidate) {
            return candidate
        }
        for suffix in 2..<10_000 {
            let next = candidate + "-" + String(suffix)
            if !taken(next) {
                return next
            }
        }
        throw NamingExhausted(project: projectPath.path)
    }
}
