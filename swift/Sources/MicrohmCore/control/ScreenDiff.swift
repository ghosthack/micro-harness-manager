import Foundation

/// Pure text helpers behind the `read` tool: turning an annotated capture into the lines an
/// agent sees and the plain text state detection compares, working out which lines are new
/// since the caller's previous read, and capping the output. Lengths count UTF-16 units,
/// as Java's `String.length()` did.
enum ScreenDiff {

    /// the daemon's annotated-capture markers (see `HeadlessTerminal.annotatedText`).
    static let SELECTION_MARKER = "▶ "
    static let CURSOR_MARKER = "▮"

    /// An incremental read needs at least this many non-blank lines of overlap.
    static let MIN_OVERLAP = 3
    /// More new lines than this share of the screen and the whole screen is returned.
    static let MAX_NEW_SHARE = 0.6

    /// The new lines of a read and how many unchanged lines precede them on screen.
    struct Delta: Equatable {
        let unchangedAbove: Int
        let lines: [String]
    }

    /// The screen's lines with trailing blank lines dropped (the empty rows below the
    /// content), markers kept: what a read shows.
    static func bodyLines(_ annotated: String) -> [String] {
        var lines = JavaText.lines(annotated)
        while let last = lines.last, isBlank(last) {
            lines.removeLast()
        }
        return lines
    }

    /// The annotated capture back as the daemon's plain `text` capture: no selection prefix,
    /// no cursor marker, no trailing whitespace — what the harness plugins' patterns and the
    /// state detector were written against.
    static func plain(_ annotated: String) -> String {
        var out = ""
        for line in JavaText.lines(annotated) {
            let l = line.hasPrefix(SELECTION_MARKER) ? String(line.dropFirst(SELECTION_MARKER.count)) : line
            out += JavaText.stripTrailing(l.replacingOccurrences(of: CURSOR_MARKER, with: ""))
            out += "\n"
        }
        return out
    }

    /// A plain-text capture with trailing whitespace dropped from every line, as `plain`
    /// leaves it — for a daemon that only gives plain text, whose real `▶ `/`▮` characters
    /// must not be taken for markers.
    static func trimmed(_ text: String) -> String {
        var out = ""
        for line in JavaText.lines(text) {
            out += JavaText.stripTrailing(line)
            out += "\n"
        }
        return out
    }

    /// The lines of `current` that are new since `previous`, or nil when the whole screen
    /// should be shown. The overlap is the longest leading block of `current` (at least
    /// `MIN_OVERLAP` non-blank lines) that occurs as a contiguous block in `previous`:
    /// output scrolled up by the new lines below it. Everything after that block is
    /// returned — new output, and the prompt or footer area, changed or not. No such
    /// overlap, nothing after it, or more than `MAX_NEW_SHARE` of the screen new: nil.
    static func newLines(_ previous: [String], _ current: [String]) -> Delta? {
        let size = current.count
        let maxNew = Int((Double(size) * MAX_NEW_SHARE).rounded(.down))
        var k = size - 1
        while k >= 1 && size - k <= maxNew {
            let prefix = Array(current[0..<k])
            if nonBlank(prefix) < MIN_OVERLAP {
                break // shorter prefixes only have fewer
            }
            if occursIn(previous, prefix) {
                return Delta(unchangedAbove: k, lines: Array(current[k..<size]))
            }
            k -= 1
        }
        return nil
    }

    /// `lines` joined, keeping the tail within `maxChars`: when lines must go, the oldest
    /// are dropped and a `"… (N earlier lines omitted)"` line leads.
    static func cap(_ lines: [String], _ maxChars: Int) -> String {
        let joined = lines.joined(separator: "\n")
        if joined.utf16.count <= maxChars {
            return joined
        }
        let budget = maxChars - 40 // room for the omission line
        var used = 0
        var first = lines.count
        while first > 0 && used + lines[first - 1].utf16.count + 1 <= budget {
            first -= 1
            used += lines[first].utf16.count + 1
        }
        var kept = Array(lines[first...])
        if kept.isEmpty {
            let last = lines[lines.count - 1]
            let units = Array(last.utf16)
            let tail = units[max(0, units.count - budget)...]
            kept.append(String(decoding: tail, as: UTF16.self))
            first = lines.count - 1
        }
        return "… (\(first) earlier lines omitted)\n" + kept.joined(separator: "\n")
    }

    private static func occursIn(_ haystack: [String], _ block: [String]) -> Bool {
        if block.count > haystack.count { return false }
        var start = 0
        outer: while start + block.count <= haystack.count {
            for i in 0..<block.count where haystack[start + i] != block[i] {
                start += 1
                continue outer
            }
            return true
        }
        return false
    }

    private static func nonBlank(_ lines: [String]) -> Int {
        lines.filter { !isBlank($0) }.count
    }

    private static func isBlank(_ line: String) -> Bool {
        JavaText.isBlank(line.replacingOccurrences(of: CURSOR_MARKER, with: ""))
    }
}
