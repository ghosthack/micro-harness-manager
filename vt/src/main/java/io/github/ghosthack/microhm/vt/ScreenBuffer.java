package io.github.ghosthack.microhm.vt;

/**
 * The lines of one screen (main or alternate) plus its scrollback history, kept in a ring of
 * {@link Line} objects so that scrolling a full-height region is O(1): the ring's start
 * advances and the line that falls out of a full history is recycled as the new bottom row.
 *
 * <p>Logical order is oldest history line first, then screen rows 0..rows-1; {@link
 * #line(int)} takes the index jediterm and the serializer use: negative for history ({@code
 * -1} is the newest history line), {@code 0..rows-1} for the screen. With {@code maxHistory
 * == 0} (the alternate screen) lines scrolled off the top are simply recycled.
 */
final class ScreenBuffer {

    private final int maxHistory;
    private int columns;
    private int rows;
    private Line[] ring;
    /** Physical index of logical line 0. */
    private int start;
    /** History lines in use, at most {@link #maxHistory}. */
    private int history;
    /** Lines ever moved into history (monotonic; 0 without history). */
    private long linesAdded;

    ScreenBuffer(int columns, int rows, int maxHistory) {
        this.maxHistory = Math.max(0, maxHistory);
        this.columns = columns;
        this.rows = rows;
        this.ring = new Line[this.maxHistory + rows];
        for (int y = 0; y < rows; y++) {
            ring[y] = new Line(columns);
        }
    }

    int history() {
        return history;
    }

    long linesAdded() {
        return linesAdded;
    }

    /** Screen row {@code y}, 0-based. */
    Line row(int y) {
        return ring[phys(history + y)];
    }

    /** History ({@code -history..-1}) or screen ({@code 0..rows-1}) line. */
    Line line(int index) {
        return ring[phys(history + index)];
    }

    private void setRow(int y, Line line) {
        ring[phys(history + y)] = line;
    }

    private int phys(int logical) {
        int p = start + logical;
        return p >= ring.length ? p - ring.length : p;
    }

    /**
     * Scrolls rows {@code [top, bottom]} up by {@code n}, filling the rows uncovered at the
     * bottom with empty cells of {@code fill}. With {@code toHistory} (callers pass it only
     * for {@code top == 0} on the main screen) the rows leaving the top go into history even
     * when {@code bottom} is above the last row — the inline-viewport technique ratatui uses.
     */
    void scrollUp(int top, int bottom, int n, long fill, boolean toHistory) {
        int size = bottom - top + 1;
        n = Math.min(n, size);
        if (n <= 0) {
            return;
        }
        if (toHistory && top == 0) {
            for (int i = 0; i < n; i++) {
                scrollOneIntoHistory(bottom, fill);
            }
            return;
        }
        Line[] moved = new Line[n];
        for (int i = 0; i < n; i++) {
            moved[i] = row(top + i);
        }
        for (int y = top; y + n <= bottom; y++) {
            setRow(y, row(y + n));
        }
        for (int i = 0; i < n; i++) {
            moved[i].clear(fill);
            setRow(bottom - n + 1 + i, moved[i]);
        }
    }

    /** Moves screen row 0 into history (or recycles it) and puts a cleared line at {@code bottom}. */
    private void scrollOneIntoHistory(int bottom, long fill) {
        Line fresh;
        if (maxHistory > 0) {
            linesAdded++;
        }
        if (history < maxHistory) {
            int p = phys(history + rows);
            fresh = ring[p];
            if (fresh == null) {
                fresh = new Line(columns);
                ring[p] = fresh;
            }
            history++;
        } else {
            // The oldest history line (or, with no history, row 0 itself) becomes the bottom.
            fresh = ring[start];
            start = start + 1 == ring.length ? 0 : start + 1;
        }
        fresh.resize(columns);
        fresh.clear(fill);
        for (int y = rows - 1; y > bottom; y--) {
            setRow(y, row(y - 1));
        }
        setRow(bottom, fresh);
    }

    /** Scrolls rows {@code [top, bottom]} down by {@code n}, filling the rows uncovered at
     * the top with empty cells of {@code fill}; lines pushed past {@code bottom} are lost. */
    void scrollDown(int top, int bottom, int n, long fill) {
        int size = bottom - top + 1;
        n = Math.min(n, size);
        if (n <= 0) {
            return;
        }
        Line[] moved = new Line[n];
        for (int i = 0; i < n; i++) {
            moved[i] = row(bottom - i);
        }
        for (int y = bottom; y - n >= top; y--) {
            setRow(y, row(y - n));
        }
        for (int i = 0; i < n; i++) {
            moved[i].clear(fill);
            setRow(top + i, moved[i]);
        }
    }

    /** Drops every history line (ED 3). */
    void clearHistory() {
        start = phys(history);
        history = 0;
    }

    /**
     * Resizes to {@code newColumns} × {@code newRows}. First {@code pushTop} screen rows are
     * moved into history (recycled without one); then the screen keeps its first {@code
     * newRows} rows or is padded with empty rows at the bottom. Screen lines are truncated or
     * padded to the new width; history lines keep theirs.
     */
    void resize(int newColumns, int newRows, int pushTop) {
        for (int i = 0; i < pushTop; i++) {
            scrollOneIntoHistory(rows - 1, Style.DEFAULT);
        }
        Line[] next = new Line[maxHistory + newRows];
        for (int i = 0; i < history; i++) {
            next[i] = line(i - history);
        }
        for (int y = 0; y < newRows; y++) {
            Line line = y < rows ? row(y) : new Line(newColumns);
            line.resize(newColumns);
            next[history + y] = line;
        }
        ring = next;
        start = 0;
        columns = newColumns;
        rows = newRows;
    }
}
