import Foundation
import MicrohmVT

/// Text and boundaries for the selection, read from the emulator (caller holds its lock).
/// Rows are emulator line indices (`-historySize()..rows()-1`); a range is from
/// `(startRow, startColumn)` inclusive to `(endRow, endColumn)` exclusive, columns being
/// caret positions between cells.
///
/// Extraction joins a soft-wrapped line to the next without a newline, trims the trailing
/// blanks of a hard line, copies a wide character once (its tail is skipped, and a range
/// starting on a tail takes the whole character), and copies each cell's whole grapheme
/// (combining marks included). Empty cells inside a line read as spaces.
public enum SelectionText {

    /// Characters besides letters and digits that a double-click word takes in: paths,
    /// URLs, flags and identifiers stay whole.
    private static let wordChars = Set("_-./~:@%+#?=&$!*,".unicodeScalars.map { Int($0.value) })

    public static func extract(_ emulator: TerminalEmulator, _ startRow: Int, _ startColumn: Int,
                               _ endRow: Int, _ endColumn: Int) -> String {
        // built as scalars: trimming by scalar keeps "\n" and combining marks apart
        var sb: [Unicode.Scalar] = []
        let first = max(startRow, -emulator.historySize())
        let last = min(endRow, emulator.rows() - 1)
        if first > last {
            return ""
        }
        var cell = ""
        for row in first...last {
            let line = emulator.line(row)
            let columns = line.columns()
            var from = row == startRow ? min(startColumn, columns) : 0
            let to = row == endRow ? min(endColumn, columns) : columns
            if from > 0 && from < columns && line.isWideTail(from) {
                from -= 1
            }
            let lineStart = sb.count
            var x = from
            while x < to {
                if line.isWideTail(x) {
                    x += 1
                    continue
                }
                if line.isEmpty(x) {
                    sb.append(" ")
                } else {
                    cell.removeAll(keepingCapacity: true)
                    line.appendText(x, &cell)
                    sb.append(contentsOf: cell.unicodeScalars)
                }
                x += 1
            }
            let continues = line.isWrapped() && to == columns
            if continues {
                // a wrapped line's tail can only be empty where a wide character did not fit
                var end = sb.count
                var x = to - 1
                while x >= from && line.isEmpty(x) && end > lineStart {
                    end -= 1
                    x -= 1
                }
                sb.removeLast(sb.count - end)
            } else {
                var end = sb.count
                while end > lineStart && sb[end - 1] == " " {
                    end -= 1
                }
                sb.removeLast(sb.count - end)
                if row < last {
                    sb.append("\n")
                }
            }
        }
        return String(String.UnicodeScalarView(sb))
    }

    /// The word around `column` as `[from, to)` carets; a blank cell selects the run of
    /// blanks, any other non-word character just itself.
    public static func word(_ line: Line, _ column: Int) -> (Int, Int) {
        let columns = line.columns()
        if columns == 0 {
            return (0, 0)
        }
        var x = max(0, min(column, columns - 1))
        if line.isWideTail(x) && x > 0 {
            x -= 1
        }
        let k = kind(line, x)
        var from = x
        while from > 0 {
            var prev = from - 1
            if line.isWideTail(prev) && prev > 0 {
                prev -= 1
            }
            if kind(line, prev) != k || k == 2 {
                break
            }
            from = prev
        }
        var to = x + max(1, line.width(x))
        while to < columns && k != 2 {
            if kind(line, to) != k {
                break
            }
            to += max(1, line.width(to))
        }
        return (from, min(to, columns))
    }

    /// 0 blank, 1 word character, 2 anything else (selected alone).
    private static func kind(_ line: Line, _ x: Int) -> Int {
        if line.isEmpty(x) {
            return 0
        }
        let cp = line.codePoint(x)
        if cp == 0x20 {
            return 0
        }
        if isLetterOrDigit(cp) || wordChars.contains(cp) || line.width(x) == 2 {
            return 1
        }
        return 2
    }

    private static func isLetterOrDigit(_ cp: Int) -> Bool {
        guard let s = Unicode.Scalar(UInt32(cp)) else {
            return false
        }
        let p = s.properties
        return p.isAlphabetic || p.numericType == .decimal
    }

    /// The rows of the logical line through `row`: back while the previous row soft-wrapped
    /// into this one, forward while this one wraps.
    public static func logicalLine(_ emulator: TerminalEmulator, _ row: Int) -> (Int, Int) {
        var top = row
        let min = -emulator.historySize()
        while top > min && emulator.line(top - 1).isWrapped() {
            top -= 1
        }
        var bottom = row
        let max = emulator.rows() - 1
        while bottom < max && emulator.line(bottom).isWrapped() {
            bottom += 1
        }
        return (top, bottom)
    }
}
