import Foundation

/// Finds harness CLIs even when a macOS app launch supplies a minimal PATH.
enum CliLocator {

    static func find(_ executable: String) throws -> String {
        let fm = FileManager.default
        if executable.hasPrefix("/") && fm.isExecutableFile(atPath: executable) {
            return executable
        }

        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":", omittingEmptySubsequences: false)
            where !JavaText.isBlank(String(entry)) {
                directories.append(String(entry))
            }
        }
        let home = PathCompat.userHome.path
        directories.append(home + "/.local/bin")
        directories.append(home + "/.cargo/bin")
        directories.append("/opt/homebrew/bin")
        directories.append("/usr/local/bin")
        directories.append("/usr/bin")

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable)
            if PathCompat.isRegularFile(candidate) && fm.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        throw UsageError(executable + " is not installed or is not on PATH")
    }
}
