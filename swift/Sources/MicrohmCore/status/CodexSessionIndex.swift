import Foundation

/// Codex's `session_index.jsonl` parsed into thread id → latest non-blank `thread_name`,
/// re-read only when the file's size or mtime changes. Codex only appends to it, so when
/// it merely grew just the appended bytes are parsed; a shrunk or replaced file
/// (different file key, or the byte before the parsed prefix no longer a newline) is
/// parsed again from the start. A trailing line without its newline yet is honoured but
/// not committed, so it is parsed again once complete. Thread-safe.
final class CodexSessionIndex: @unchecked Sendable {

    private struct FileKey: Equatable {
        let device: Int64
        let inode: UInt64
    }

    private let file: URL
    private let lock = NSLock()
    private var names: [String: String] = [:]
    /// The last line without a terminating newline, if it parsed: overrides `names`.
    private var pendingId: String?
    private var pendingName: String?
    /// Bytes of complete lines already folded into `names`.
    private var committedOffset: Int64 = 0
    private var seenSize: Int64 = -1
    private var seenModified = Int64.min
    private var seenFileKey: FileKey?
    private var parses = 0

    init(_ file: URL) {
        self.file = file
    }

    func name(_ threadId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if !refresh() {
            return nil
        }
        if threadId == pendingId {
            return pendingName
        }
        return names[threadId]
    }

    /// How many times the file has been (fully or incrementally) read (for tests).
    func parseCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return parses
    }

    /// Brings the cache up to date; false when the index cannot be read.
    private func refresh() -> Bool {
        var st = stat()
        guard stat(file.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            reset()
            return false
        }
        let size = Int64(st.st_size)
        let modified = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
        let fileKey = FileKey(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
        if size == seenSize && modified == seenModified && fileKey == seenFileKey {
            return true
        }
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            reset()
            return false
        }
        defer { try? handle.close() }
        do {
            var appendOnly = seenSize >= 0 && fileKey == seenFileKey && size >= committedOffset
            if appendOnly {
                appendOnly = try endsWithNewlineAt(handle, committedOffset)
            }
            if !appendOnly {
                names.removeAll()
                committedOffset = 0
            }
            try parseFrom(handle, committedOffset)
        } catch {
            reset()
            return false
        }
        seenSize = size
        seenModified = modified
        seenFileKey = fileKey
        parses += 1
        return true
    }

    /// Whether the parsed prefix still ends where it did: offset 0, or a newline just before.
    private func endsWithNewlineAt(_ handle: FileHandle, _ offset: Int64) throws -> Bool {
        if offset == 0 {
            return true
        }
        try handle.seek(toOffset: UInt64(offset - 1))
        let one = try handle.read(upToCount: 1) ?? Data()
        return one.count == 1 && one.first == 0x0A
    }

    private func parseFrom(_ handle: FileHandle, _ offset: Int64) throws {
        try handle.seek(toOffset: UInt64(offset))
        let bytes = [UInt8](try handle.readToEnd() ?? Data())
        pendingId = nil
        pendingName = nil
        var lineStart = 0
        for i in 0..<bytes.count where bytes[i] == 0x0A {
            fold(String(decoding: bytes[lineStart..<i], as: UTF8.self))
            lineStart = i + 1
        }
        committedOffset = offset + Int64(lineStart)
        if lineStart < bytes.count {
            // Possibly a half-written append: use it if it parses, re-read it next time.
            if let row = CodexSessionIndex.parseRow(String(decoding: bytes[lineStart...], as: UTF8.self)) {
                pendingId = row.id
                pendingName = row.name
            }
        }
    }

    private func fold(_ line: String) {
        if let row = CodexSessionIndex.parseRow(line) {
            names[row.id] = row.name
        }
    }

    /// `(id, name)` for a row carrying a non-blank name.
    private static func parseRow(_ line: String) -> (id: String, name: String)? {
        // One partial/corrupt append must not hide an earlier valid rename.
        guard let row = try? CoreJSON.parse(line), row != .missing else {
            return nil
        }
        let name = JavaText.strip(row.path("thread_name").asText())
        if name.isEmpty {
            return nil
        }
        return (row.path("id").asText(), name)
    }

    private func reset() {
        names.removeAll()
        pendingId = nil
        pendingName = nil
        committedOffset = 0
        seenSize = -1
        seenModified = Int64.min
        seenFileKey = nil
    }
}
