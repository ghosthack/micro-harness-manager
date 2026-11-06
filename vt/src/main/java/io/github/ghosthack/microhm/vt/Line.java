package io.github.ghosthack.microhm.vt;

import java.util.Arrays;

/**
 * One row of cells, on the screen or in the scrollback history. Read it only while holding
 * the owning {@link TerminalEmulator#lock()}: the emulator mutates and recycles line objects
 * in place (a line scrolled out of a full history becomes the new bottom row).
 *
 * <p>Each cell has a base code point, a column {@link #width(int) width}, a {@link Style}
 * and, rarely, extra code points that attached to it (combining marks, ZWJ sequences,
 * variation selectors, emoji modifiers, the second regional indicator of a flag):
 * <ul>
 *   <li>an <b>empty</b> cell (never written, or erased) has code point 0 and width 1; it
 *       reads as a space;</li>
 *   <li>a <b>wide</b> character occupies two cells: the lead cell (width 2) holds it, the
 *       following {@link #isWideTail(int) tail} cell has width 0 and no text;</li>
 *   <li>everything else has width 1.</li>
 * </ul>
 * A history line keeps the width the screen had when it scrolled off, so {@link #columns()}
 * can differ from the terminal's current width; reads past the end return an empty cell.
 */
public final class Line {

    /** Marker in {@link #codePoints} for the right half of a wide character. */
    static final int WIDE_TAIL = -1;
    /** Bound on the code units attached to one cell, so a hostile stream can't grow it. */
    private static final int MAX_EXTRA_CHARS = 32;

    int[] codePoints;
    long[] styles;
    /** Attached code points per cell, as UTF-16; null until a cell needs one. */
    String[] extras;
    boolean wrapped;

    Line(int columns) {
        codePoints = new int[columns];
        styles = new long[columns];
    }

    /** The number of cells. */
    public int columns() {
        return codePoints.length;
    }

    /** True when the text continues on the next line because it auto-wrapped here (a soft
     * wrap): copying should join the two lines without a newline. */
    public boolean isWrapped() {
        return wrapped;
    }

    /** The cell's base code point, or 0 for an empty cell or a wide tail. */
    public int codePoint(int x) {
        if (x < 0 || x >= codePoints.length) {
            return 0;
        }
        int cp = codePoints[x];
        return cp == WIDE_TAIL ? 0 : cp;
    }

    /** Columns covered by the cell: 2 for a wide lead, 0 for a wide tail, 1 otherwise. */
    public int width(int x) {
        if (x < 0 || x >= codePoints.length) {
            return 1;
        }
        int cp = codePoints[x];
        if (cp == WIDE_TAIL) {
            return 0;
        }
        return x + 1 < codePoints.length && codePoints[x + 1] == WIDE_TAIL ? 2 : 1;
    }

    /** True for the right half of a wide character. */
    public boolean isWideTail(int x) {
        return x >= 0 && x < codePoints.length && codePoints[x] == WIDE_TAIL;
    }

    /** True for a never-written or erased cell. */
    public boolean isEmpty(int x) {
        return x < 0 || x >= codePoints.length || codePoints[x] == 0;
    }

    /** The cell's style; {@link Style#DEFAULT} past the end. */
    public long style(int x) {
        return x < 0 || x >= styles.length ? Style.DEFAULT : styles[x];
    }

    /** True when code points attached to the cell (see {@link #text(int)}). */
    public boolean hasExtras(int x) {
        return extras != null && x >= 0 && x < extras.length && extras[x] != null;
    }

    /** The cell's grapheme as a string: base code point plus anything attached; "" for an
     * empty cell or a wide tail. Allocates; a renderer can use {@link #appendText}. */
    public String text(int x) {
        StringBuilder sb = new StringBuilder(2);
        appendText(x, sb);
        return sb.toString();
    }

    /** Appends {@link #text(int)} to {@code sb}. */
    public void appendText(int x, StringBuilder sb) {
        int cp = codePoint(x);
        if (cp == 0) {
            return;
        }
        sb.appendCodePoint(cp);
        if (hasExtras(x)) {
            sb.append(extras[x]);
        }
    }

    /** The row as text: empty cells as spaces, wide tails omitted, untrimmed. */
    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder(codePoints.length);
        appendTo(sb);
        return sb.toString();
    }

    /** Appends {@link #toString()} to {@code sb}. */
    public void appendTo(StringBuilder sb) {
        for (int x = 0; x < codePoints.length; x++) {
            int cp = codePoints[x];
            if (cp == WIDE_TAIL) {
                continue;
            }
            if (cp == 0) {
                sb.append(' ');
            } else {
                sb.appendCodePoint(cp);
                if (extras != null && extras[x] != null) {
                    sb.append(extras[x]);
                }
            }
        }
    }

    // --- mutation (emulator only) ------------------------------------------------------

    /** Clears every cell to empty with {@code style} and drops the wrapped flag. */
    void clear(long style) {
        Arrays.fill(codePoints, 0);
        Arrays.fill(styles, style);
        extras = null;
        wrapped = false;
    }

    /** Resizes to {@code columns} cells (truncating or padding with empty default cells),
     * never leaving half a wide character at the new right edge. */
    void resize(int columns) {
        int old = codePoints.length;
        if (columns == old) {
            return;
        }
        boolean cutsWide = columns > 0 && columns < old && codePoints[columns] == WIDE_TAIL;
        codePoints = Arrays.copyOf(codePoints, columns);
        styles = Arrays.copyOf(styles, columns);
        if (extras != null) {
            extras = Arrays.copyOf(extras, columns);
        }
        if (cutsWide) {
            clearCell(columns - 1);
        }
    }

    /** Sets cell {@code x} (narrow) — callers have already {@link #breakWide broken} any
     * wide character overlapping it. */
    void set(int x, int cp, long style) {
        codePoints[x] = cp;
        styles[x] = style;
        if (extras != null) {
            extras[x] = null;
        }
    }

    /** Sets a wide character at {@code x} and its tail at {@code x + 1}. */
    void setWide(int x, int cp, long style) {
        set(x, cp, style);
        set(x + 1, WIDE_TAIL, style);
    }

    /** Appends attached code point {@code cp} to cell {@code x}. */
    void attach(int x, int cp) {
        if (extras == null) {
            extras = new String[codePoints.length];
        }
        String old = extras[x];
        if (old != null && old.length() >= MAX_EXTRA_CHARS) {
            return;
        }
        String add = Character.toString(cp);
        extras[x] = old == null ? add : old + add;
    }

    /** The last attached code point of cell {@code x}, or 0. */
    int lastExtra(int x) {
        if (!hasExtras(x)) {
            return 0;
        }
        String s = extras[x];
        return s.codePointBefore(s.length());
    }

    /**
     * Before cells {@code [from, to)} are overwritten, erases the other half of any wide
     * character the range cuts: a tail at {@code from} loses its lead, a lead at
     * {@code to - 1} loses its tail. The orphaned half becomes an empty cell keeping its style.
     */
    void breakWide(int from, int to) {
        int n = codePoints.length;
        if (from > 0 && from < n && codePoints[from] == WIDE_TAIL) {
            clearCell(from - 1);
        }
        if (to < n && to > 0 && codePoints[to] == WIDE_TAIL) {
            clearCell(to);
        }
    }

    private void clearCell(int x) {
        codePoints[x] = 0;
        if (extras != null) {
            extras[x] = null;
        }
    }

    /** Erases cells {@code [from, to)} to empty with {@code style}, breaking cut wide chars. */
    void erase(int from, int to, long style) {
        from = Math.max(0, from);
        to = Math.min(codePoints.length, to);
        if (from >= to) {
            return;
        }
        breakWide(from, to);
        Arrays.fill(codePoints, from, to, 0);
        Arrays.fill(styles, from, to, style);
        if (extras != null) {
            Arrays.fill(extras, from, to, null);
        }
    }

    /** Inserts {@code count} empty cells with {@code style} at {@code x}, shifting the rest
     * right; cells pushed past the end are lost. */
    void insertCells(int x, int count, long style) {
        int n = codePoints.length;
        if (x >= n || count <= 0) {
            return;
        }
        count = Math.min(count, n - x);
        breakWide(x, x);
        int keep = n - x - count;
        // A wide char whose lead lands on the last column loses its tail off the edge.
        boolean cut = keep > 0 && codePoints[x + keep] == WIDE_TAIL;
        System.arraycopy(codePoints, x, codePoints, x + count, keep);
        System.arraycopy(styles, x, styles, x + count, keep);
        if (extras != null) {
            System.arraycopy(extras, x, extras, x + count, keep);
        }
        Arrays.fill(codePoints, x, x + count, 0);
        Arrays.fill(styles, x, x + count, style);
        if (extras != null) {
            Arrays.fill(extras, x, x + count, null);
        }
        if (cut) {
            clearCell(n - 1);
        }
    }

    /** Deletes {@code count} cells at {@code x}, shifting the rest left and filling the end
     * with empty cells of {@code style}. */
    void deleteCells(int x, int count, long style) {
        int n = codePoints.length;
        if (x >= n || count <= 0) {
            return;
        }
        count = Math.min(count, n - x);
        breakWide(x, x + count);
        int move = n - x - count;
        System.arraycopy(codePoints, x + count, codePoints, x, move);
        System.arraycopy(styles, x + count, styles, x, move);
        if (extras != null) {
            System.arraycopy(extras, x + count, extras, x, move);
        }
        Arrays.fill(codePoints, n - count, n, 0);
        Arrays.fill(styles, n - count, n, style);
        if (extras != null) {
            Arrays.fill(extras, n - count, n, null);
        }
    }
}
