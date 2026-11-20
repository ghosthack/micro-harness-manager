import Foundation

/// java.nio.file.Path operations the ported code relies on, over file URLs. Like
/// `Path.normalize()`, nothing here resolves symlinks.
enum PathCompat {

    /// `toAbsolutePath().normalize()`: relative paths resolve against the current
    /// directory; `.` and `..` segments are folded lexically.
    static func normalize(_ url: URL) -> URL {
        let raw = url.path
        let absolute = raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
        var parts: [String] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }

    /// Path components of an absolute path, without the root.
    static func components(_ url: URL) -> [String] {
        url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `Path.startsWith(Path)`: whole components, not string prefix.
    static func startsWith(_ path: URL, _ base: URL) -> Bool {
        let p = components(path)
        let b = components(base)
        return p.count >= b.count && Array(p[0..<b.count]) == b
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Last-modified time in milliseconds, or nil when the file can't be stat'ed.
    static func lastModifiedMillis(_ url: URL) -> Int64? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
    }

    /// The directory's entries (`Files.list`), empty when it can't be read.
    static func list(_ dir: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.map { dir.appendingPathComponent($0) }
    }

    /// The user's home directory (`System.getProperty("user.home")`).
    static var userHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}
