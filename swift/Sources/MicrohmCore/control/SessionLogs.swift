import Foundation
import MicrohmMux

/// Plain-text copies of sessions' output, written into the folder of the agent that asked
/// about them (`FOLDER` in its project), so an agent whose sandbox keeps it inside its
/// project can still grep a session's history.
///
/// A session's log is `<session>.log`: the lines that scrolled off the top of its screen,
/// each once, in order. A full-screen program (the alternate screen) scrolls nothing off,
/// so for it the log gets its screen's lines, without the harness's chrome, as they appear:
/// each line not among the last `RECENT_LINES` written (the bottom one once it has held for
/// a sample, as it may be still being drawn), under a `--- microhm · <time> · screen ---`
/// line when it took over the screen. Other such lines mark a restarted session and lines
/// that scrolled past before they could be copied. (Sampling the screen each second and
/// keeping only unseen lines keeps a streamed answer whole, in order and about once, where
/// copying the screen whenever it stopped changing logged the same lines many times over,
/// mid-answer and while the user typed.)
///
/// Nothing is deleted: once the live file would pass `MAX_LIVE_LINES` lines it is
/// compressed to `<session>.<NNNN>.log.gz` (0001 the oldest) and started afresh. The folder
/// ignores itself for git (`.gitignore` holding `*`), and keeps each log's progress in a
/// hidden `.<session>.state` file so a restarted app neither repeats nor skips lines.
///
/// Each `Log` is used under its own lock (`Log.lock`).
final class SessionLogs: @unchecked Sendable {

    static let FOLDER = ".microhm-sessions"
    static let MAX_LIVE_LINES = 8000
    /// How many of the lines last written a full-screen program's line is checked against.
    static let RECENT_LINES = 400

    private let lock = NSLock()
    private var logs: [String: Log] = [:]

    /// The live log file of `session` for an agent working in `dir`.
    static func file(_ dir: URL, _ session: String) -> URL {
        dir.appendingPathComponent(FOLDER).appendingPathComponent(safe(session) + ".log")
    }

    /// The log of `session` in `dir`'s folder, opened (and the folder made) on first use.
    func open(_ dir: URL, _ session: String) throws -> Log {
        let key = SessionLogs.file(dir, session).path
        lock.lock(); defer { lock.unlock() }
        if let log = logs[key] {
            return log
        }
        let log = try Log.open(dir.appendingPathComponent(SessionLogs.FOLDER), SessionLogs.safe(session))
        logs[key] = log
        return log
    }

    /// Forgets an open log (its files stay).
    func close(_ file: URL) {
        lock.lock(); defer { lock.unlock() }
        logs.removeValue(forKey: file.path)
    }

    static func safe(_ session: String) -> String {
        SessionLauncher.fileSafe(session)
    }

    struct LogError: Error, CustomStringConvertible {
        let description: String
    }

    /// One session's log in one folder.
    final class Log: @unchecked Sendable {
        let lock = NSRecursiveLock()
        private let folder: URL
        private let base: String
        private let live: URL
        private let state: URL
        private(set) var pid: Int64 = 0
        private var added: Int64 = 0
        private var lines = 0
        private var parts = 0
        /// Whether the previous record saw the alternate screen.
        private var onAlternateScreen = false
        /// The last row of the full screen the previous record saw.
        private var lastRow: String?
        /// The last `RECENT_LINES` lines written, oldest first, and how often each is among
        /// them.
        private var recent: [String] = []
        private var recentHead = 0
        private var recentCounts: [String: Int] = [:]
        /// The progress last written to the state file; nil before any.
        private var saved: String?

        private init(_ folder: URL, _ base: String) {
            self.folder = folder
            self.base = base
            self.live = folder.appendingPathComponent(base + ".log")
            self.state = folder.appendingPathComponent("." + base + ".state")
        }

        static func open(_ folder: URL, _ base: String) throws -> Log {
            let log = Log(folder, base)
            try log.ensureFolder()
            try ownerOnly(folder, 0o700) // also one an earlier version left open to others
            try log.load()
            return log
        }

        var file: URL { live }

        /// The scrollback count to read from: what the log has, for the session it has.
        func since() -> Int64 {
            added
        }

        /// Makes the folder and its `.gitignore` when they are missing, which is also after
        /// something in the project deleted them (`git clean -x`). The project is not
        /// trusted: a folder or file planted there as a symbolic link would send sessions'
        /// output wherever it points, so links are refused, never followed. The folder holds
        /// other sessions' output, so it and the files made in it are the owner's alone.
        private func ensureFolder() throws {
            var st = stat()
            if lstat(folder.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    throw LogError(description: "\(folder.path) is a symbolic link; not writing session logs through it")
                }
            }
            if !(lstat(folder.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Log.ownerOnly(folder, 0o700)
            }
            let ignore = folder.appendingPathComponent(".gitignore")
            if lstat(ignore.path, &st) != 0 {
                try Log.createNew(ignore, "*\n")
                try Log.ownerOnly(ignore, 0o600)
            }
        }

        /// Keeps `url` (never a link: the callers made it or checked it) to its owner.
        private static func ownerOnly(_ url: URL, _ mode: mode_t) throws {
            if chmod(url.path, mode) != 0 {
                throw LogError(description: "chmod \(url.path): \(String(cString: strerror(errno)))")
            }
        }

        /// Creates `url` (failing if anything, a link included, is there) holding `text`.
        private static func createNew(_ url: URL, _ text: String) throws {
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw LogError(description: "create \(url.path): \(String(cString: strerror(errno)))")
            }
            defer { Darwin.close(fd) }
            try writeAll(fd, Array(text.utf8), url)
        }

        private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ url: URL) throws {
            var written = 0
            while written < bytes.count {
                let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    throw LogError(description: "write \(url.path): \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }

        /// Marks the start of another session under the same name (its scrollback counts
        /// afresh: read it since 0).
        func restarted(_ newPid: Int64, _ now: Date) throws {
            try write(Log.marker(now, "a new session (pid \(newPid))"))
            // only once the marker is written: a failed write is retried at the next sample
            pid = newPid
            added = 0
            onAlternateScreen = false
            lastRow = nil
            save()
        }

        /// Appends what `capture` (taken with its scrollback) adds: its new scrollback, and
        /// on the alternate screen, where nothing scrolls off, the lines of its screen
        /// reduced by `chrome` (the harness's `maskChrome`) that are not among those written
        /// lately.
        func record(_ capture: SessionCapture, _ chrome: (String) -> String, _ now: Date) throws {
            // A write that fails (folder gone, disk full) must leave the log where it was,
            // so the same lines are read and written again at the next sample.
            let addedBefore = added
            let pidBefore = pid
            let alternateBefore = onAlternateScreen
            let lastRowBefore = lastRow
            let recentBefore = recentLines()
            do {
                try append(capture, chrome, now)
            } catch {
                added = addedBefore
                pid = pidBefore
                onAlternateScreen = alternateBefore
                lastRow = lastRowBefore
                recent = []
                recentHead = 0
                recentCounts = [:]
                for line in recentBefore {
                    push(line)
                }
                throw error
            }
        }

        private func append(_ capture: SessionCapture, _ chrome: (String) -> String, _ now: Date) throws {
            var out = ""
            guard let history = capture.history else {
                throw LogError(description: "history")
            }
            let fresh = history.added - min(added, history.added)
            let got = Int64(Log.count(history.text))
            if fresh > got {
                out += Log.marker(now, "\(fresh - got) lines scrolled past before they could be copied")
            }
            out += history.text
            added = history.added
            remember(history.text)
            if history.alternateScreen {
                let screen = chrome(capture.text)
                let rows = JavaText.lines(screen).map(JavaText.stripTrailing).filter { !JavaText.isBlank($0) }
                // the last row may be still being drawn: it waits until it has held for a sample
                let last = rows.last
                let lastHeld = last != nil && (last == lastRow || !capture.alive)
                lastRow = last
                var unseen = ""
                for (i, line) in rows.enumerated() where (i < rows.count - 1 || lastHeld) && recentCounts[line] == nil {
                    unseen += line + "\n"
                    remember(line + "\n")
                }
                if !unseen.isEmpty {
                    if !onAlternateScreen {
                        out += Log.marker(now, "screen")
                    }
                    out += unseen
                    onAlternateScreen = true
                }
            } else {
                onAlternateScreen = false
                lastRow = nil
            }
            pid = capture.processId
            try write(out)
            save()
        }

        private func recentLines() -> [String] {
            Array(recent[recentHead...])
        }

        private func push(_ line: String) {
            recent.append(line)
            recentCounts[line, default: 0] += 1
            if recent.count - recentHead > SessionLogs.RECENT_LINES {
                let dropped = recent[recentHead]
                recentHead += 1
                if let n = recentCounts[dropped] {
                    recentCounts[dropped] = n == 1 ? nil : n - 1
                }
                if recentHead > 4 * SessionLogs.RECENT_LINES {
                    recent.removeFirst(recentHead)
                    recentHead = 0
                }
            }
        }

        /// Adds `text`'s lines to the recent ones, letting the oldest go.
        private func remember(_ text: String) {
            if text.isEmpty {
                return
            }
            for raw in JavaText.splitKeepingEmpty(text, on: "\n") {
                let line = JavaText.stripTrailing(raw)
                if JavaText.isBlank(line) {
                    continue
                }
                push(line)
            }
        }

        private func write(_ text: String) throws {
            if text.isEmpty {
                return
            }
            let n = Log.count(text)
            try ensureFolder()
            var st = stat()
            let fresh = lstat(live.path, &st) != 0
            if fresh {
                lines = 0 // deleted under us: start it afresh
            }
            if lines > 0 && lines + n > SessionLogs.MAX_LIVE_LINES {
                try roll()
            }
            if fresh {
                try Log.createNew(live, "") // owner-only before it holds a line
            }
            let fd = Darwin.open(live.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw LogError(description: "open \(live.path): \(String(cString: strerror(errno)))")
            }
            defer { Darwin.close(fd) }
            try Log.writeAll(fd, Array(text.utf8), live)
            lines += n
        }

        /// Compresses the live file into the next part and empties it.
        private func roll() throws {
            var part: URL
            repeat {
                parts += 1
                part = folder.appendingPathComponent(base + "." + String(format: "%04d", parts) + ".log.gz")
            } while FileManager.default.fileExists(atPath: part.path)
            let partial = folder.appendingPathComponent("." + part.lastPathComponent + ".tmp")
            let data = try Data(contentsOf: live)
            try Gzip.compress(data).write(to: partial)
            try Log.ownerOnly(partial, 0o600)
            if rename(partial.path, part.path) != 0 {
                throw LogError(description: "rename \(partial.path): \(String(cString: strerror(errno)))")
            }
            let fd = Darwin.open(live.path, O_WRONLY | O_TRUNC | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { Darwin.close(fd) }
            lines = 0
        }

        private func load() throws {
            var st = stat()
            if lstat(state.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                let p = (try? JavaProperties.load(Data(contentsOf: state))) ?? JavaProperties()
                // a damaged state file: start from nothing rather than fail
                pid = Log.number(p, "pid")
                added = Log.number(p, "added")
                parts = Int(Log.number(p, "parts"))
                saved = signature()
            }
            if lstat(live.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                let all = JavaText.lines(String(decoding: try Data(contentsOf: live), as: UTF8.self))
                lines = all.count
                remember(all.suffix(SessionLogs.RECENT_LINES).joined(separator: "\n"))
            }
        }

        private func signature() -> String {
            "\(pid):\(added):\(parts)"
        }

        private func save() {
            // sampled every second: an idle session must not rewrite its state each time
            let now = signature()
            var st = stat()
            if now == saved && lstat(state.path, &st) == 0 {
                return
            }
            var p = JavaProperties()
            p.setProperty("pid", String(pid))
            p.setProperty("added", String(added))
            p.setProperty("parts", String(parts))
            let partial = folder.appendingPathComponent("." + base + ".state.tmp")
            do {
                try ensureFolder()
                unlink(partial.path)
                let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else {
                    throw LogError(description: "create \(partial.path)")
                }
                defer { Darwin.close(fd) }
                try Log.writeAll(fd, [UInt8](p.store(comments: "microhm session log progress")), partial)
                if rename(partial.path, state.path) != 0 {
                    throw LogError(description: "rename \(partial.path)")
                }
                saved = now
            } catch {
                // the lines are in the log already: failing here would have them written
                // again, so the progress is simply saved at the next sample instead
                saved = nil
            }
        }

        private static func number(_ p: JavaProperties, _ key: String) -> Int64 {
            Int64(JavaText.strip(p.getProperty(key, "0"))) ?? 0
        }

        static func marker(_ now: Date, _ what: String) -> String {
            let seconds = Date(timeIntervalSince1970: (now.timeIntervalSince1970).rounded(.down))
            return "--- microhm · \(IsoInstant.format(seconds)) · \(what) ---\n"
        }

        private static func count(_ text: String) -> Int {
            text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        }
    }
}

/// A gzip member (RFC 1952) around Foundation's raw deflate.
enum Gzip {

    static func compress(_ data: Data) throws -> Data {
        let deflated = data.isEmpty ? Data([0x03, 0x00]) : try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated)
        appendLE(&out, crc32(data))
        appendLE(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// The payload of a single-member gzip file.
    static func decompress(_ gz: Data) throws -> Data {
        let bytes = [UInt8](gz)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw SessionLogs.LogError(description: "not gzip")
        }
        let flags = bytes[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        if flags & 8 != 0 { while bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let body = Data(bytes[i..<(bytes.count - 8)])
        return try (body as NSData).decompressed(using: .zlib) as Data
    }

    private static func appendLE(_ out: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in data {
            c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8)
        }
        return c ^ 0xffff_ffff
    }
}
