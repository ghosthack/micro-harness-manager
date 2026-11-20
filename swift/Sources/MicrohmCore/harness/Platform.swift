import Foundation

/// The one OS check the plugins need: npm shims on Windows run `node.exe` as the shell's
/// child, so the harnesses installed through npm report as `node` there (see
/// `ClaudeCodePlugin.ownsProcess` and `CodexPlugin.ownsProcess`). This port is
/// macOS/POSIX only, so `isWindows()` is always false; the OS-name form stays so each
/// plugin keeps its per-platform unit test.
enum Platform {

    static func isWindows() -> Bool {
        false
    }

    static func isWindows(_ osName: String) -> Bool {
        osName.lowercased().hasPrefix("windows")
    }
}
