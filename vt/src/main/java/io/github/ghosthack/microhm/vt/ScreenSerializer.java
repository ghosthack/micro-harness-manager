package io.github.ghosthack.microhm.vt;

import java.nio.charset.StandardCharsets;

/**
 * Turns a {@link TerminalEmulator}'s state back into the escape-sequence stream a freshly
 * attached client needs to show the same thing. The contract is a round trip: feeding the
 * output of {@link #serialize} into a fresh emulator of the same size yields the same cells
 * (an empty cell and a default-style space count as equal), styles, wrapped flags, history,
 * cursor (including a pending wrap), pen, modes, scroll region, tab stops, charsets, title,
 * alternate screen and saved cursors (ScreenSerializerTest and the corpus round trips).
 *
 * <p>Output order:
 * <ol>
 *   <li>reset to a known state: {@code CSI ?1049 l}, {@code CSI 0 m}, {@code CSI ?7 h},
 *       {@code CSI r}, {@code CSI ?25 l} (hidden while drawing), {@code CSI H},
 *       {@code CSI 2 J}, {@code CSI 3 J}, {@code ESC ( B}, {@code SI}, {@code CSI 4 l};</li>
 *   <li>the last {@code historyLines} history lines, then the main screen's rows, each as
 *       styled runs. A wide character's tail cell is skipped. A non-wrapped row stops at its
 *       last cell that is not a default-style blank, then {@code CSI 0 m} and {@code CSI K}
 *       (unless the row is full) and {@code CR LF} except after the last row. A wrapped row
 *       writes all its cells and no {@code CR LF}, so the client's deferred wrap marks it on
 *       the next write; an entirely blank continuation row still writes its first cell so
 *       that wrap fires. (A wrapped <em>last</em> row cannot be reproduced without scrolling;
 *       its flag is lost.)</li>
 *   <li>the main screen's saved cursor, staged (origin mode, cursor, pending wrap, autowrap,
 *       pen, charsets) and saved. On the alternate screen it is saved by {@code CSI ?1049 h}
 *       ({@code CSI ?1047 h} when nothing was saved), followed by the alternate rows drawn
 *       from home the same way and, if one exists, its own saved cursor ({@code ESC 7});
 *       otherwise by {@code ESC 7};</li>
 *   <li>the tail: scroll region, tab stops, origin mode, the cursor (re-writing the last
 *       cell when a wrap is pending), then the modes that do not move the cursor (autowrap,
 *       DECSCUSR, cursor blink, bracketed paste, cursor keys, keypad, mouse tracking and
 *       encoding, focus reporting, reverse video, insert and newline modes, kitty keyboard
 *       flags), the title, charsets, the pen, synchronized output, and cursor visibility last.</li>
 * </ol>
 * The caller holds the emulator's lock so the snapshot is consistent.
 */
public final class ScreenSerializer {

    private static final String CSI = "\u001b[";

    /** The redraw stream for {@code emulator}, with up to {@code historyLines} history lines. */
    public static byte[] serialize(TerminalEmulator emulator, int historyLines) {
        return new Writer(emulator).write(historyLines).getBytes(StandardCharsets.UTF_8);
    }

    private static final class Writer {
        private final TerminalEmulator t;
        private final int columns;
        private final int rows;
        private final StringBuilder sb = new StringBuilder(4096);
        /** The client's pen after our last SGR. */
        private long pen = Style.DEFAULT;

        Writer(TerminalEmulator t) {
            this.t = t;
            this.columns = t.columns();
            this.rows = t.rows();
        }

        String write(int historyLines) {
            sb.append(CSI).append("?1049l").append(CSI).append("0m").append(CSI).append("?7h")
                    .append(CSI).append('r').append(CSI).append("?25l").append(CSI).append('H')
                    .append(CSI).append("2J").append(CSI).append("3J").append("\u001b(B\u000f")
                    .append(CSI).append("4l");

            int history = Math.min(Math.max(0, historyLines), t.mainHistorySize());
            int total = history + rows;
            boolean afterWrap = false;
            for (int i = -history; i < rows; i++) {
                afterWrap = emitLine(t.mainLine(i), i + history == total - 1, afterWrap);
            }
            TerminalEmulator.SavedCursor savedMain = t.savedCursor(false);
            if (t.alternateScreen()) {
                if (savedMain != null) {
                    stage(savedMain, false);
                    sb.append(CSI).append("?1049h");
                    unstage();
                } else {
                    sb.append(CSI).append("?1047h");
                }
                sb.append(CSI).append('H');
                afterWrap = false;
                for (int y = 0; y < rows; y++) {
                    afterWrap = emitLine(t.line(y), y == rows - 1, afterWrap);
                }
                TerminalEmulator.SavedCursor savedAlt = t.savedCursor(true);
                if (savedAlt != null) {
                    stage(savedAlt, true);
                    sb.append("\u001b7");
                    unstage();
                }
            } else if (savedMain != null) {
                stage(savedMain, false);
                sb.append("\u001b7");
                unstage();
            }
            emitTail();
            return sb.toString();
        }

        /** Puts the client in the state {@code saved} records, ready for it to be saved. The
         * region is full-screen here, so a CUP after {@code ?6 h} is absolute. */
        private void stage(TerminalEmulator.SavedCursor saved, boolean alternate) {
            sb.append(CSI).append(saved.originMode() ? "?6h" : "?6l");
            placeCursor(saved.row(), saved.column(), saved.pendingWrap(), alternate);
            if (!saved.autoWrap()) {
                sb.append(CSI).append("?7l");
            }
            emitSgr(saved.style());
            emitCharsets(saved.charsets());
        }

        /** Back to the drawing state after a {@link #stage}. */
        private void unstage() {
            sb.append("\u001b(B\u001b)B\u001b*B\u001b+B\u000f");
            sb.append(CSI).append("0m").append(CSI).append("?7h").append(CSI).append("?6l");
            pen = Style.DEFAULT;
        }

        private void emitTail() {
            sb.append(CSI).append("?6l");
            int top = t.scrollTop();
            int bottom = t.scrollBottom();
            if (top != 0 || bottom != rows - 1) {
                sb.append(CSI).append(top + 1).append(';').append(bottom + 1).append('r');
            }
            if (!t.defaultTabs()) {
                sb.append(CSI).append("3g");
                for (int x = 0; x < columns; x++) {
                    if (t.isTabStop(x)) {
                        sb.append(CSI).append("1;").append(x + 1).append("H\u001bH");
                    }
                }
            }
            if (t.originMode()) {
                sb.append(CSI).append("?6h");
            }
            int row = t.originMode() ? t.cursorRow() - top : t.cursorRow();
            placeCursor(row, t.cursorColumn(), t.cursorPendingWrap(), t.alternateScreen(), t.cursorRow());

            sb.append(CSI).append(t.autoWrap() ? "?7h" : "?7l");
            if (t.cursorShape() != 0) {
                sb.append(CSI).append(t.cursorShape()).append(" q");
            }
            if (t.cursorBlink()) {
                sb.append(CSI).append("?12h");
            }
            if (t.bracketedPaste()) {
                sb.append(CSI).append("?2004h");
            }
            if (t.applicationCursorKeys()) {
                sb.append(CSI).append("?1h");
            }
            if (t.applicationKeypad()) {
                sb.append("\u001b=");
            }
            if (t.mouseTracking() != TerminalEmulator.MouseTracking.NONE) {
                sb.append(CSI).append('?').append(t.mouseTracking().mode).append('h');
            }
            switch (t.mouseEncoding()) {
                case UTF8 -> sb.append(CSI).append("?1005h");
                case SGR -> sb.append(CSI).append("?1006h");
                case URXVT -> sb.append(CSI).append("?1015h");
                case DEFAULT -> {
                }
            }
            if (t.focusReporting()) {
                sb.append(CSI).append("?1004h");
            }
            if (t.reverseVideo()) {
                sb.append(CSI).append("?5h");
            }
            if (t.insertMode()) {
                sb.append(CSI).append("4h");
            }
            if (t.newLineMode()) {
                sb.append(CSI).append("20h");
            }
            if (t.kittyKeyboardFlags() != 0) {
                sb.append(CSI).append('=').append(t.kittyKeyboardFlags()).append(";1u");
            }
            if (!t.title().isEmpty()) {
                sb.append("\u001b]2;");
                t.title().codePoints().filter(c -> c >= 0x20 && c != 0x7F).forEach(sb::appendCodePoint);
                sb.append('\u0007');
            }
            emitCharsets(t.charsetState());
            emitSgr(t.pen());
            if (t.synchronizedOutput()) {
                sb.append(CSI).append("?2026h");
            }
            sb.append(CSI).append(t.cursorVisible() ? "?25h" : "?25l");
        }

        private void placeCursor(int row, int column, boolean pendingWrap, boolean alternate) {
            placeCursor(row, column, pendingWrap, alternate, row);
        }

        /**
         * {@code CSI row;col H} (1-based from the 0-based {@code row}, which is relative to
         * the region in origin mode; {@code screenRow} is the absolute one). With a pending
         * wrap the cursor sits on the last column, which a CUP cannot express: move to the
         * cell the last character occupies and write it again with its style, which re-arms
         * the wrap.
         */
        private void placeCursor(int row, int column, boolean pendingWrap, boolean alternate, int screenRow) {
            if (!pendingWrap) {
                sb.append(CSI).append(row + 1).append(';').append(column + 1).append('H');
                return;
            }
            Line line = alternate ? t.line(screenRow) : t.mainLine(screenRow);
            int x = line.isWideTail(column) ? column - 1 : column;
            sb.append(CSI).append(row + 1).append(';').append(x + 1).append('H');
            long restore = pen;
            emitCell(line, x);
            emitSgr(restore);
        }

        private void emitCharsets(int packed) {
            char[] designators = {'(', ')', '*', '+'};
            for (int i = 0; i < 4; i++) {
                int set = (packed >> (2 * i)) & 3;
                if (set != TerminalEmulator.CHARSET_ASCII) {
                    sb.append('\u001b').append(designators[i])
                            .append(set == TerminalEmulator.CHARSET_DEC_GRAPHICS ? '0' : 'A');
                }
            }
            switch ((packed >> 8) & 3) {
                case 1 -> sb.append('\u000e');
                case 2 -> sb.append("\u001bn");
                case 3 -> sb.append("\u001bo");
                default -> {
                }
            }
        }

        /** Emits one line and returns whether it was wrapped. */
        private boolean emitLine(Line line, boolean isLast, boolean afterWrap) {
            int width = Math.min(line.columns(), columns);
            if (line.isWrapped()) {
                for (int x = 0; x < width; x++) {
                    emitCell(line, x);
                }
                return true;
            }
            int last = width - 1;
            while (last >= 0 && isDroppable(line, last)) {
                last--;
            }
            if (last < 0 && afterWrap) {
                // A blank continuation: write one cell so the client's deferred wrap fires.
                emitCell(line, 0);
            }
            for (int x = 0; x <= last; x++) {
                emitCell(line, x);
            }
            emitSgr(Style.DEFAULT);
            if (last + 1 < columns) {
                sb.append(CSI).append('K');
            }
            if (!isLast) {
                sb.append("\r\n");
            }
            return false;
        }

        /** A cell CSI K reproduces: empty or a space, default style, nothing attached. */
        private static boolean isDroppable(Line line, int x) {
            int cp = line.codePoint(x);
            return (cp == 0 || cp == ' ') && !line.isWideTail(x) && line.style(x) == Style.DEFAULT
                    && !line.hasExtras(x);
        }

        private void emitCell(Line line, int x) {
            if (line.isWideTail(x)) {
                return; // written with its lead
            }
            emitSgr(line.style(x));
            if (line.codePoint(x) == 0) {
                sb.append(' ');
            } else {
                line.appendText(x, sb);
            }
        }

        /** Moves the client's pen to {@code target}: {@code CSI 0;…m}, restating it in full. */
        private void emitSgr(long target) {
            if (target == pen) {
                return;
            }
            sb.append(CSI).append('0');
            appendSgrParams(sb, target);
            sb.append('m');
            pen = target;
        }
    }

    /** The SGR parameters for {@code s}, each prefixed with ';'; empty for the default style. */
    static void appendSgrParams(StringBuilder p, long s) {
        if (Style.bold(s)) p.append(";1");
        if (Style.dim(s)) p.append(";2");
        if (Style.italic(s)) p.append(";3");
        switch (Style.underline(s)) {
            case Style.UNDERLINE_NONE -> {
            }
            case Style.UNDERLINE_SINGLE -> p.append(";4");
            case Style.UNDERLINE_DOUBLE -> p.append(";21");
            default -> p.append(";4:").append(Style.underline(s));
        }
        if (Style.blink(s)) p.append(";5");
        if (Style.rapidBlink(s)) p.append(";6");
        if (Style.inverse(s)) p.append(";7");
        if (Style.invisible(s)) p.append(";8");
        if (Style.strikethrough(s)) p.append(";9");
        if (Style.overline(s)) p.append(";53");
        appendColor(p, Style.foreground(s), 30, 90, 38);
        appendColor(p, Style.background(s), 40, 100, 48);
    }

    private static void appendColor(StringBuilder p, int color, int base, int brightBase, int extended) {
        if (Style.isIndexed(color)) {
            int idx = Style.index(color);
            if (idx < 8) {
                p.append(';').append(base + idx);
            } else if (idx < 16) {
                p.append(';').append(brightBase + idx - 8);
            } else {
                p.append(';').append(extended).append(";5;").append(idx);
            }
        } else if (Style.isRgb(color)) {
            int rgb = Style.rgbValue(color);
            p.append(';').append(extended).append(";2;").append(rgb >> 16).append(';')
                    .append((rgb >> 8) & 0xFF).append(';').append(rgb & 0xFF);
        }
    }

    private ScreenSerializer() {
    }
}
