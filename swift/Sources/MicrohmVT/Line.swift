/**
 * One row of cells, on the screen or in the scrollback history. Read it only while holding
 * the owning `TerminalEmulator.lock()`: the emulator mutates and recycles line objects in
 * place (a line scrolled out of a full history becomes the new bottom row).
 *
 * Each cell has a base code point, a column `width(_:)`, a `Style` and, rarely, extra code
 * points that attached to it (combining marks, ZWJ sequences, variation selectors, emoji
 * modifiers, the second regional indicator of a flag):
 *  - an **empty** cell (never written, or erased) has code point 0 and width 1; it reads as
 *    a space;
 *  - a **wide** character occupies two cells: the lead cell (width 2) holds it, the following
 *    `isWideTail(_:)` cell has width 0 and no text;
 *  - everything else has width 1.
 *
 * A history line keeps the width the screen had when it scrolled off, so `columns()` can
 * differ from the terminal's current width; reads past the end return an empty cell.
 *
 * Storage is two manually managed buffers (code points, styles) so the emulator's hot paths
 * index raw memory without copy-on-write or exclusivity checks.
 */
import Foundation

public final class Line: CustomStringConvertible {

    /** Marker in `codePoints` for the right half of a wide character. */
    static let WIDE_TAIL: Int32 = -1
    /** Bound on the UTF-16 code units attached to one cell, so a hostile stream can't grow it. */
    private static let MAX_EXTRA_CHARS = 32

    var codePoints: UnsafeMutablePointer<Int32>
    var styles: UnsafeMutablePointer<Int64>
    /** The number of cells. */
    var count: Int
    /** Attached code points per cell; nil until a cell needs one. */
    var extras: [String?]?
    var wrapped = false
    /** Bumped by every mutation; see `version()`. */
    private var _version: Int64 = 0

    init(_ columns: Int) {
        count = columns
        codePoints = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, columns))
        codePoints.initialize(repeating: 0, count: max(1, columns))
        styles = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, columns))
        styles.initialize(repeating: 0, count: max(1, columns))
    }

    deinit {
        codePoints.deallocate()
        styles.deallocate()
    }

    /**
     * A modification counter: it changes whenever any cell, the width or the wrapped flag of
     * this line changes (it never repeats for one line object). A renderer that remembers which
     * line object it painted at a row, and that line's version, can tell whether the row needs
     * repainting. Read it under the emulator lock, like everything else here.
     */
    public func version() -> Int64 {
        return _version
    }

    /** Records a mutation made by code that writes the buffers directly (the emulator's fast
     * paths); every mutating method here calls it itself. */
    @inline(__always) func touch() {
        _version &+= 1
    }

    /** Sets the soft-wrap flag. */
    func setWrapped(_ wrapped: Bool) {
        if self.wrapped != wrapped {
            self.wrapped = wrapped
            _version &+= 1
        }
    }

    /** The number of cells. */
    public func columns() -> Int {
        return count
    }

    /** True when the text continues on the next line because it auto-wrapped here (a soft
     * wrap): copying should join the two lines without a newline. */
    public func isWrapped() -> Bool {
        return wrapped
    }

    /** The cell's base code point, or 0 for an empty cell or a wide tail. */
    public func codePoint(_ x: Int) -> Int {
        if x < 0 || x >= count {
            return 0
        }
        let cp = codePoints[x]
        return cp == Line.WIDE_TAIL ? 0 : Int(cp)
    }

    /** Columns covered by the cell: 2 for a wide lead, 0 for a wide tail, 1 otherwise. */
    public func width(_ x: Int) -> Int {
        if x < 0 || x >= count {
            return 1
        }
        if codePoints[x] == Line.WIDE_TAIL {
            return 0
        }
        return x + 1 < count && codePoints[x + 1] == Line.WIDE_TAIL ? 2 : 1
    }

    /** True for the right half of a wide character. */
    public func isWideTail(_ x: Int) -> Bool {
        return x >= 0 && x < count && codePoints[x] == Line.WIDE_TAIL
    }

    /** True for a never-written or erased cell. */
    public func isEmpty(_ x: Int) -> Bool {
        return x < 0 || x >= count || codePoints[x] == 0
    }

    /** The cell's style; `Style.default` past the end. */
    public func style(_ x: Int) -> Int64 {
        return x < 0 || x >= count ? Style.default : styles[x]
    }

    /** True when code points attached to the cell (see `text(_:)`). */
    public func hasExtras(_ x: Int) -> Bool {
        guard let extras = extras, x >= 0, x < extras.count else {
            return false
        }
        return extras[x] != nil
    }

    /** The code points attached to the cell (empty when none). */
    public func extraText(_ x: Int) -> String {
        guard let extras = extras, x >= 0, x < extras.count else {
            return ""
        }
        return extras[x] ?? ""
    }

    /** The cell's grapheme as a string: base code point plus anything attached; "" for an
     * empty cell or a wide tail. Allocates; a renderer can use `appendText`. */
    public func text(_ x: Int) -> String {
        var s = ""
        appendText(x, &s)
        return s
    }

    /** Appends `text(_:)` to `sb`. */
    public func appendText(_ x: Int, _ sb: inout String) {
        let cp = codePoint(x)
        if cp == 0 {
            return
        }
        sb.unicodeScalars.append(Line.scalar(cp))
        if let extras = extras, let e = extras[x] {
            sb += e
        }
    }

    /** Appends the cell's text as UTF-8 (nothing for an empty cell or a wide tail). */
    public func appendUtf8(_ x: Int, _ out: inout [UInt8]) {
        let cp = codePoint(x)
        if cp == 0 {
            return
        }
        Line.appendUtf8(cp, &out)
        if let extras = extras, let e = extras[x] {
            out.append(contentsOf: e.utf8)
        }
    }

    /** The row as text: empty cells as spaces, wide tails omitted, untrimmed. */
    public var description: String {
        var sb = ""
        sb.reserveCapacity(count)
        appendTo(&sb)
        return sb
    }

    /** `description`, by its Java name. */
    public func toString() -> String {
        return description
    }

    /** Appends `toString()` to `sb`. */
    public func appendTo(_ sb: inout String) {
        for x in 0..<count {
            let cp = codePoints[x]
            if cp == Line.WIDE_TAIL {
                continue
            }
            if cp == 0 {
                sb.unicodeScalars.append(" ")
            } else {
                sb.unicodeScalars.append(Line.scalar(Int(cp)))
                if let extras = extras, let e = extras[x] {
                    sb += e
                }
            }
        }
    }

    @inline(__always) static func scalar(_ cp: Int) -> Unicode.Scalar {
        return Unicode.Scalar(UInt32(truncatingIfNeeded: cp)) ?? "\u{FFFD}"
    }

    @inline(__always) static func appendUtf8(_ cp: Int, _ out: inout [UInt8]) {
        if cp < 0x80 {
            out.append(UInt8(cp))
        } else if cp < 0x800 {
            out.append(UInt8(0xC0 | (cp >> 6)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        } else if cp < 0x10000 {
            if cp >= 0xD800 && cp <= 0xDFFF {
                out.append(UInt8(ascii: "?")) // as Java's encoder does for a lone surrogate
                return
            }
            out.append(UInt8(0xE0 | (cp >> 12)))
            out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        } else {
            out.append(UInt8(0xF0 | (cp >> 18)))
            out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        }
    }

    // --- mutation (emulator only) ------------------------------------------------------

    /** Clears every cell to empty with `style` and drops the wrapped flag. */
    func clear(_ style: Int64) {
        _version &+= 1
        codePoints.update(repeating: 0, count: count)
        styles.update(repeating: style, count: count)
        extras = nil
        wrapped = false
    }

    /** Resizes to `columns` cells (truncating or padding with empty default cells), never
     * leaving half a wide character at the new right edge. */
    func resize(_ columns: Int) {
        let old = count
        if columns == old {
            return
        }
        _version &+= 1
        let cutsWide = columns > 0 && columns < old && codePoints[columns] == Line.WIDE_TAIL
        let cps = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, columns))
        cps.initialize(repeating: 0, count: max(1, columns))
        let sts = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, columns))
        sts.initialize(repeating: 0, count: max(1, columns))
        let keep = min(old, columns)
        cps.update(from: codePoints, count: keep)
        sts.update(from: styles, count: keep)
        codePoints.deallocate()
        styles.deallocate()
        codePoints = cps
        styles = sts
        count = columns
        if let e = extras {
            if columns < e.count {
                extras!.removeLast(e.count - columns)
            } else {
                extras!.append(contentsOf: repeatElement(nil, count: columns - e.count))
            }
        }
        if cutsWide {
            clearCell(columns - 1)
        }
    }

    /** Sets cell `x` (narrow) — callers have already broken (`breakWide`) any wide character
     * overlapping it. */
    func set(_ x: Int, _ cp: Int32, _ style: Int64) {
        _version &+= 1
        codePoints[x] = cp
        styles[x] = style
        if extras != nil {
            extras![x] = nil
        }
    }

    /** Sets a wide character at `x` and its tail at `x + 1`. */
    func setWide(_ x: Int, _ cp: Int32, _ style: Int64) {
        set(x, cp, style)
        set(x + 1, Line.WIDE_TAIL, style)
    }

    /** Appends attached code point `cp` to cell `x`. */
    func attach(_ x: Int, _ cp: Int) {
        _version &+= 1
        if extras == nil {
            extras = [String?](repeating: nil, count: count)
        }
        let old = extras![x]
        if let old = old, old.utf16.count >= Line.MAX_EXTRA_CHARS {
            return
        }
        var add = old ?? ""
        add.unicodeScalars.append(Line.scalar(cp))
        extras![x] = add
    }

    /** The last attached code point of cell `x`, or 0. */
    func lastExtra(_ x: Int) -> Int {
        guard hasExtras(x), let s = extras![x], let last = s.unicodeScalars.last else {
            return 0
        }
        return Int(last.value)
    }

    /**
     * Before cells `[from, to)` are overwritten, erases the other half of any wide character
     * the range cuts: a tail at `from` loses its lead, a lead at `to - 1` loses its tail. The
     * orphaned half becomes an empty cell keeping its style.
     */
    @inline(__always)
    func breakWide(_ from: Int, _ to: Int) {
        let n = count
        if from > 0 && from < n && codePoints[from] == Line.WIDE_TAIL {
            clearCell(from - 1)
        }
        if to < n && to > 0 && codePoints[to] == Line.WIDE_TAIL {
            clearCell(to)
        }
    }

    private func clearCell(_ x: Int) {
        _version &+= 1
        codePoints[x] = 0
        if extras != nil {
            extras![x] = nil
        }
    }

    private func fillExtras(_ from: Int, _ to: Int) {
        if extras != nil && from < to {
            for i in from..<to {
                extras![i] = nil
            }
        }
    }

    /** Erases cells `[from, to)` to empty with `style`, breaking cut wide chars. */
    func erase(_ from: Int, _ to: Int, _ style: Int64) {
        let from = max(0, from)
        let to = min(count, to)
        if from >= to {
            return
        }
        _version &+= 1
        breakWide(from, to)
        (codePoints + from).update(repeating: 0, count: to - from)
        (styles + from).update(repeating: style, count: to - from)
        fillExtras(from, to)
    }

    /** Inserts `count` empty cells with `style` at `x`, shifting the rest right; cells pushed
     * past the end are lost. */
    func insertCells(_ x: Int, _ count: Int, _ style: Int64) {
        let n = self.count
        if x >= n || count <= 0 {
            return
        }
        let count = min(count, n - x)
        _version &+= 1
        breakWide(x, x)
        let keep = n - x - count
        // A wide char whose lead lands on the last column loses its tail off the edge.
        let cut = keep > 0 && codePoints[x + keep] == Line.WIDE_TAIL
        memmove(codePoints + x + count, codePoints + x, keep * MemoryLayout<Int32>.stride)
        memmove(styles + x + count, styles + x, keep * MemoryLayout<Int64>.stride)
        if extras != nil {
            for i in stride(from: keep - 1, through: 0, by: -1) {
                extras![x + count + i] = extras![x + i]
            }
        }
        (codePoints + x).update(repeating: 0, count: count)
        (styles + x).update(repeating: style, count: count)
        fillExtras(x, x + count)
        if cut {
            clearCell(n - 1)
        }
    }

    /** Deletes `count` cells at `x`, shifting the rest left and filling the end with empty
     * cells of `style`. */
    func deleteCells(_ x: Int, _ count: Int, _ style: Int64) {
        let n = self.count
        if x >= n || count <= 0 {
            return
        }
        let count = min(count, n - x)
        _version &+= 1
        breakWide(x, x + count)
        let move = n - x - count
        memmove(codePoints + x, codePoints + x + count, move * MemoryLayout<Int32>.stride)
        memmove(styles + x, styles + x + count, move * MemoryLayout<Int64>.stride)
        if extras != nil {
            for i in 0..<move {
                extras![x + i] = extras![x + count + i]
            }
        }
        (codePoints + n - count).update(repeating: 0, count: count)
        (styles + n - count).update(repeating: style, count: count)
        fillExtras(n - count, n)
    }
}
