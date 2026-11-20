/**
 * The lines of one screen (main or alternate) plus its scrollback history, kept in a ring of
 * `Line` objects so that scrolling a full-height region is O(1): the ring's start advances and
 * the line that falls out of a full history is recycled as the new bottom row.
 *
 * Logical order is oldest history line first, then screen rows 0..rows-1; `line(_:)` takes
 * the index the serializer uses: negative for history (`-1` is the newest history line),
 * `0..rows-1` for the screen. With `maxHistory == 0` (the alternate screen) lines scrolled off
 * the top are simply recycled.
 */
final class ScreenBuffer {

    private let maxHistory: Int
    private var columns: Int
    private var rows: Int
    private var ring: [Line?]
    /** Physical index of logical line 0. */
    private var start = 0
    /** History lines in use, at most `maxHistory`. */
    private var historyCount = 0
    /** Lines ever moved into history (monotonic; 0 without history). */
    private var added: Int64 = 0

    init(_ columns: Int, _ rows: Int, _ maxHistory: Int) {
        self.maxHistory = max(0, maxHistory)
        self.columns = columns
        self.rows = rows
        self.ring = [Line?](repeating: nil, count: self.maxHistory + rows)
        for y in 0..<rows {
            ring[y] = Line(columns)
        }
    }

    func history() -> Int {
        return historyCount
    }

    func linesAdded() -> Int64 {
        return added
    }

    /** Screen row `y`, 0-based. */
    @inline(__always)
    func row(_ y: Int) -> Line {
        return ring[phys(historyCount + y)]!
    }

    /** History (`-history..-1`) or screen (`0..rows-1`) line. */
    func line(_ index: Int) -> Line {
        return ring[phys(historyCount + index)]!
    }

    @inline(__always)
    private func setRow(_ y: Int, _ line: Line) {
        ring[phys(historyCount + y)] = line
    }

    @inline(__always)
    private func phys(_ logical: Int) -> Int {
        let p = start + logical
        return p >= ring.count ? p - ring.count : p
    }

    /**
     * Scrolls rows `[top, bottom]` up by `n`, filling the rows uncovered at the bottom with
     * empty cells of `fill`. With `toHistory` (callers pass it only for `top == 0` on the main
     * screen) the rows leaving the top go into history even when `bottom` is above the last
     * row — the inline-viewport technique ratatui uses.
     */
    func scrollUp(_ top: Int, _ bottom: Int, _ n: Int, _ fill: Int64, _ toHistory: Bool) {
        let size = bottom - top + 1
        let n = min(n, size)
        if n <= 0 {
            return
        }
        if toHistory && top == 0 {
            for _ in 0..<n {
                scrollOneIntoHistory(bottom, fill)
            }
            return
        }
        var moved = [Line]()
        moved.reserveCapacity(n)
        for i in 0..<n {
            moved.append(row(top + i))
        }
        var y = top
        while y + n <= bottom {
            setRow(y, row(y + n))
            y += 1
        }
        for i in 0..<n {
            moved[i].clear(fill)
            setRow(bottom - n + 1 + i, moved[i])
        }
    }

    /** Moves screen row 0 into history (or recycles it) and puts a cleared line at `bottom`. */
    private func scrollOneIntoHistory(_ bottom: Int, _ fill: Int64) {
        let fresh: Line
        if maxHistory > 0 {
            added += 1
        }
        if historyCount < maxHistory {
            let p = phys(historyCount + rows)
            if let existing = ring[p] {
                fresh = existing
            } else {
                fresh = Line(columns)
                ring[p] = fresh
            }
            historyCount += 1
        } else {
            // The oldest history line (or, with no history, row 0 itself) becomes the bottom.
            fresh = ring[start]!
            start = start + 1 == ring.count ? 0 : start + 1
        }
        fresh.resize(columns)
        fresh.clear(fill)
        var y = rows - 1
        while y > bottom {
            setRow(y, row(y - 1))
            y -= 1
        }
        setRow(bottom, fresh)
    }

    /** Scrolls rows `[top, bottom]` down by `n`, filling the rows uncovered at the top with
     * empty cells of `fill`; lines pushed past `bottom` are lost. */
    func scrollDown(_ top: Int, _ bottom: Int, _ n: Int, _ fill: Int64) {
        let size = bottom - top + 1
        let n = min(n, size)
        if n <= 0 {
            return
        }
        var moved = [Line]()
        moved.reserveCapacity(n)
        for i in 0..<n {
            moved.append(row(bottom - i))
        }
        var y = bottom
        while y - n >= top {
            setRow(y, row(y - n))
            y -= 1
        }
        for i in 0..<n {
            moved[i].clear(fill)
            setRow(top + i, moved[i])
        }
    }

    /** Drops every history line (ED 3). */
    func clearHistory() {
        start = phys(historyCount)
        historyCount = 0
    }

    /**
     * Resizes to `newColumns` × `newRows`. First `pushTop` screen rows are moved into history
     * (recycled without one); then the screen keeps its first `newRows` rows or is padded with
     * empty rows at the bottom. Screen lines are truncated or padded to the new width; history
     * lines keep theirs.
     */
    func resize(_ newColumns: Int, _ newRows: Int, _ pushTop: Int) {
        for _ in 0..<max(0, pushTop) {
            scrollOneIntoHistory(rows - 1, Style.default)
        }
        var next = [Line?](repeating: nil, count: maxHistory + newRows)
        for i in 0..<historyCount {
            next[i] = line(i - historyCount)
        }
        for y in 0..<newRows {
            let line = y < rows ? row(y) : Line(newColumns)
            line.resize(newColumns)
            next[historyCount + y] = line
        }
        ring = next
        start = 0
        columns = newColumns
        rows = newRows
    }
}
