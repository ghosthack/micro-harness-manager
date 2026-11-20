import Foundation

/// Java's `Files.createTempFile(dir, prefix, suffix)` + `Files.move(…, ATOMIC_MOVE)`: the
/// new contents go to an owner-only temp file in the target's directory that is then
/// renamed over the target, so a reader sees the old file or the new one, never a
/// truncated one.
enum AtomicFile {

    struct WriteError: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes `data` to `file` atomically. On failure the temp file is removed and the
    /// error rethrown; the target is untouched.
    static func write(_ data: Data, to file: URL, tempPrefix: String, tempSuffix: String) throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var template = Array((parent.path + "/" + tempPrefix + "XXXXXXXXXX" + tempSuffix).utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { buf in
            mkstemps(buf.baseAddress!, Int32(tempSuffix.utf8.count))
        }
        if fd < 0 {
            throw WriteError(description: "cannot create a temp file in \(parent.path): \(String(cString: strerror(errno)))")
        }
        let tmpPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var ok = false
        defer {
            if !ok { unlink(tmpPath) }
        }
        fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        let closed = close(fd) == 0
        if !written || !closed {
            throw WriteError(description: "cannot write \(tmpPath): \(String(cString: strerror(errno)))")
        }
        if rename(tmpPath, file.path) != 0 {
            throw WriteError(description: "cannot replace \(file.path): \(String(cString: strerror(errno)))")
        }
        ok = true
    }
}
