import MicrohmVT

/// Web links in the terminal's text, for ⌘-click; the phone page finds them the same way
/// (findLinks in app.js). A long link may run on over several rows: where the terminal
/// soft-wrapped it, and where the program broke it at the right edge itself (Claude Code
/// does), going on in the next row at the same indent.
public enum Links {

    /// Rows looked at above and below the clicked one: a link longer than this is unlikely.
    private static let reach = 8

    /// A piece of a link: on `row` (an index into the rows given), columns `[from, to)`.
    public struct Span: Equatable {
        public let row: Int
        public let from: Int
        public let to: Int
        public let url: String
    }

    /// The web link covering cell `(row, column)` (an emulator line index), or nil. The
    /// caller holds the emulator's lock.
    public static func urlAt(_ emulator: TerminalEmulator, _ row: Int, _ column: Int) -> String? {
        let first = max(-emulator.historySize(), row - reach)
        let last = min(emulator.rows() - 1, row + reach)
        if first > last {
            return nil
        }
        var rows: [[Unicode.Scalar]] = []
        var wrapped: [Bool] = []
        for r in first...last {
            let line = emulator.line(r)
            rows.append(cells(line))
            wrapped.append(line.isWrapped())
        }
        for span in find(rows, wrapped, emulator.columns()) {
            if span.row == row - first && column >= span.from && column < span.to {
                return span.url
            }
        }
        return nil
    }

    /// One character per cell, so string columns are cell columns: wide tails, and cells
    /// that hold more than one UTF-16 unit (an emoji, a combining mark), never belong to a
    /// link and read as spaces.
    private static func cells(_ line: Line) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(line.columns())
        for x in 0..<line.columns() {
            if line.isEmpty(x) || line.isWideTail(x) || line.hasExtras(x) {
                out.append(" ")
                continue
            }
            let cp = line.codePoint(x)
            out.append(cp > 0xFFFF ? " " : (Unicode.Scalar(UInt32(cp)) ?? " "))
        }
        return out
    }

    /// Java's `\s`.
    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return true
        default: return false
        }
    }

    /// `[^\s<>"'`]`
    private static func isUrlChar(_ c: Unicode.Scalar) -> Bool {
        if isSpace(c) {
            return false
        }
        switch c {
        case "<", ">", "\"", "'", "`": return false
        default: return true
        }
    }

    /// The end of the run of URL characters from `at` (== `at` when there is none).
    private static func urlChars(_ text: [Unicode.Scalar], _ at: Int) -> Int {
        var end = at
        while end < text.count && isUrlChar(text[end]) {
            end += 1
        }
        return end
    }

    /// The next `https?://[^\s<>"'`]+` in `text` at or after `from`, as `[start, end)`.
    private static func nextUrl(_ text: [Unicode.Scalar], _ from: Int) -> (Int, Int)? {
        var i = from
        while i < text.count {
            if text[i] == "h", let schemeEnd = scheme(text, i) {
                let end = urlChars(text, schemeEnd)
                if end > schemeEnd {
                    return (i, end)
                }
            }
            i += 1
        }
        return nil
    }

    private static func scheme(_ text: [Unicode.Scalar], _ at: Int) -> Int? {
        for prefix in ["https://", "http://"] {
            let p = Array(prefix.unicodeScalars)
            if at + p.count <= text.count && Array(text[at..<(at + p.count)]) == p {
                return at + p.count
            }
        }
        return nil
    }

    public static func find(_ rows: [String], _ wrapped: [Bool], _ columns: Int) -> [Span] {
        return find(rows.map { Array($0.unicodeScalars) }, wrapped, columns)
    }

    /// The links in `rows` as spans, every piece of a link carrying the whole link.
    /// `wrapped[i]`: row i soft-wraps into the next.
    static func find(_ rows: [[Unicode.Scalar]], _ wrapped: [Bool], _ columns: Int) -> [Span] {
        var spans: [Span] = []
        var taken = [Int](repeating: 0, count: rows.count) // columns already part of a link from above
        for i in 0..<rows.count {
            let text = rows[i]
            var searchFrom = 0
            while let (start, matchEnd) = nextUrl(text, searchFrom) {
                searchFrom = matchEnd
                if start < taken[i] {
                    continue
                }
                var pieces: [(row: Int, from: Int, to: Int)] = [(i, start, matchEnd)]
                var raw = String(String.UnicodeScalarView(text[start..<matchEnd]))
                var row = i
                var end = matchEnd
                let base = indent(text)
                while row + 1 < rows.count && runsOn(rows[row], end, columns) {
                    let next = rows[row + 1]
                    let at = wrapped[row] ? 0 : indent(next)
                    if !wrapped[row] && at != base {
                        break
                    }
                    let pieceEnd = urlChars(next, at)
                    if pieceEnd == at {
                        break
                    }
                    row += 1
                    end = pieceEnd
                    taken[row] = end
                    pieces.append((row, at, end))
                    raw += String(String.UnicodeScalarView(next[at..<pieceEnd]))
                }
                let url = trim(raw)
                var cut = raw.unicodeScalars.count - url.unicodeScalars.count
                var p = pieces.count - 1
                while p >= 0 && cut > 0 {
                    let s = pieces[p]
                    let drop = min(cut, s.to - s.from)
                    cut -= drop
                    pieces[p] = (s.row, s.from, s.to - drop)
                    p -= 1
                }
                for s in pieces where s.to > s.from {
                    spans.append(Span(row: s.row, from: s.from, to: s.to, url: url))
                }
            }
        }
        return spans
    }

    /// A link ending at `end` goes on in the next row: nothing follows it on its row, and
    /// it reaches the right edge (a program leaves a column or two free there).
    private static func runsOn(_ row: [Unicode.Scalar], _ end: Int, _ columns: Int) -> Bool {
        let blank = row[min(end, row.count)...].allSatisfy { $0.properties.isWhitespace }
        return blank && end >= columns - 2
    }

    private static func indent(_ row: [Unicode.Scalar]) -> Int {
        var n = 0
        while n < row.count && row[n] == " " {
            n += 1
        }
        return n
    }

    /// Drops what usually ends the sentence around a link rather than the link: trailing
    /// punctuation, and a closing bracket the link did not open.
    public static func trim(_ url: String) -> String {
        let s = Array(url.unicodeScalars)
        var end = s.count
        while end > 0 {
            let c = s[end - 1]
            if ".,;:!?".unicodeScalars.contains(c) {
                end -= 1
            } else if (c == ")" && count(s, "(", end) < count(s, ")", end))
                        || (c == "]" && count(s, "[", end) < count(s, "]", end))
                        || (c == "}" && count(s, "{", end) < count(s, "}", end)) {
                end -= 1
            } else {
                break
            }
        }
        return String(String.UnicodeScalarView(s[0..<end]))
    }

    private static func count(_ s: [Unicode.Scalar], _ c: Unicode.Scalar, _ end: Int) -> Int {
        var n = 0
        for i in 0..<end where s[i] == c {
            n += 1
        }
        return n
    }
}
