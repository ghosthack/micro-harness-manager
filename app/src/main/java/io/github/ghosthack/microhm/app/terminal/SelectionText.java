package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.Line;
import io.github.ghosthack.microhm.vt.TerminalEmulator;

/**
 * Text and boundaries for the selection, read from the emulator (caller holds its lock). Rows
 * are emulator line indices ({@code -historySize()..rows()-1}); a range is from
 * {@code (startRow, startColumn)} inclusive to {@code (endRow, endColumn)} exclusive, columns
 * being caret positions between cells.
 *
 * <p>Extraction joins a soft-wrapped line to the next without a newline, trims the trailing
 * blanks of a hard line, copies a wide character once (its tail is skipped, and a range
 * starting on a tail takes the whole character), and copies each cell's whole grapheme
 * (combining marks included). Empty cells inside a line read as spaces.
 */
final class SelectionText {

    /** Characters besides letters and digits that a double-click word takes in: paths,
     * URLs, flags and identifiers stay whole. */
    private static final String WORD_CHARS = "_-./~:@%+#?=&$!*,";

    static String extract(TerminalEmulator emulator, int startRow, int startColumn, int endRow,
                          int endColumn) {
        StringBuilder sb = new StringBuilder();
        int first = Math.max(startRow, -emulator.historySize());
        int last = Math.min(endRow, emulator.rows() - 1);
        for (int row = first; row <= last; row++) {
            Line line = emulator.line(row);
            int columns = line.columns();
            int from = row == startRow ? Math.min(startColumn, columns) : 0;
            int to = row == endRow ? Math.min(endColumn, columns) : columns;
            if (from > 0 && from < columns && line.isWideTail(from)) {
                from--;
            }
            int lineStart = sb.length();
            for (int x = from; x < to; x++) {
                if (line.isWideTail(x)) {
                    continue;
                }
                if (line.isEmpty(x)) {
                    sb.append(' ');
                } else {
                    line.appendText(x, sb);
                }
            }
            boolean continues = line.isWrapped() && to == columns;
            if (continues) {
                // a wrapped line's tail can only be empty where a wide character did not fit
                int end = sb.length();
                for (int x = to - 1; x >= from && line.isEmpty(x) && end > lineStart; x--) {
                    end--;
                }
                sb.setLength(end);
            } else {
                int end = sb.length();
                while (end > lineStart && sb.charAt(end - 1) == ' ') {
                    end--;
                }
                sb.setLength(end);
                if (row < last) {
                    sb.append('\n');
                }
            }
        }
        return sb.toString();
    }

    /** The word around {@code column} as {@code [from, to)} carets; a blank cell selects the
     * run of blanks, any other non-word character just itself. */
    static int[] word(Line line, int column) {
        int columns = line.columns();
        if (columns == 0) {
            return new int[]{0, 0};
        }
        int x = Math.max(0, Math.min(column, columns - 1));
        if (line.isWideTail(x) && x > 0) {
            x--;
        }
        int kind = kind(line, x);
        int from = x;
        while (from > 0) {
            int prev = from - 1;
            if (line.isWideTail(prev) && prev > 0) {
                prev--;
            }
            if (kind(line, prev) != kind || kind == 2) {
                break;
            }
            from = prev;
        }
        int to = x + Math.max(1, line.width(x));
        while (to < columns && kind != 2) {
            if (kind(line, to) != kind) {
                break;
            }
            to += Math.max(1, line.width(to));
        }
        return new int[]{from, Math.min(to, columns)};
    }

    /** 0 blank, 1 word character, 2 anything else (selected alone). */
    private static int kind(Line line, int x) {
        if (line.isEmpty(x)) {
            return 0;
        }
        int cp = line.codePoint(x);
        if (cp == ' ') {
            return 0;
        }
        if (Character.isLetterOrDigit(cp) || WORD_CHARS.indexOf(cp) >= 0 || line.width(x) == 2) {
            return 1;
        }
        return 2;
    }

    /** The rows of the logical line through {@code row}: back while the previous row
     * soft-wrapped into this one, forward while this one wraps. */
    static int[] logicalLine(TerminalEmulator emulator, int row) {
        int top = row;
        int min = -emulator.historySize();
        while (top > min && emulator.line(top - 1).isWrapped()) {
            top--;
        }
        int bottom = row;
        int max = emulator.rows() - 1;
        while (bottom < max && emulator.line(bottom).isWrapped()) {
            bottom++;
        }
        return new int[]{top, bottom};
    }

    private SelectionText() {
    }
}
