package io.github.ghosthack.microhm.vt;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Whole-model comparison of two {@link TerminalEmulator}s, for the serializer round trip:
 * every cell (text with an empty cell equal to a space, width, style), every wrapped flag
 * (except the last screen row's, which a redraw cannot reproduce — see {@link
 * ScreenSerializer}), the history, cursor, pen, modes, margins, tab stops, charsets, title
 * and saved cursors. The alternate screen and its saved cursor are compared only while it is
 * shown (a redraw does not carry an inactive alternate screen).
 */
final class ModelAssert {

    /** Feeds {@code a}'s redraw into a fresh emulator of the same size and asserts equality;
     * returns the copy. The redraw goes to the copy as is, as it goes to a client (it is not
     * SGR-normalised: the emulator reads colon sub-parameters itself). */
    static TerminalEmulator roundTrip(TerminalEmulator a, int historyLines) {
        byte[] redraw;
        a.lock().lock();
        try {
            redraw = ScreenSerializer.serialize(a, historyLines);
        } finally {
            a.lock().unlock();
        }
        TerminalEmulator b = new TerminalEmulator(a.columns(), a.rows(), historyLines);
        b.feed(redraw);
        assertSameState(a, b, historyLines);
        return b;
    }

    static void assertSameState(TerminalEmulator a, TerminalEmulator b, int historyLines) {
        assertEquals(a.columns(), b.columns(), "columns");
        assertEquals(a.rows(), b.rows(), "rows");
        assertEquals(describeState(a), describeState(b), "cursor, pen and modes");
        assertEquals(a.savedCursor(false), b.savedCursor(false), "main saved cursor");
        if (a.alternateScreen()) {
            assertEquals(a.savedCursor(true), b.savedCursor(true), "alternate saved cursor");
        }
        int history = Math.min(historyLines, a.mainHistorySize());
        assertEquals(history, b.mainHistorySize(), "history size");
        for (int i = -history; i < 0; i++) {
            assertSameLine(a.mainLine(i), b.mainLine(i), a.columns(), true, "history[" + i + "]");
        }
        for (int y = 0; y < a.rows(); y++) {
            assertSameLine(a.mainLine(y), b.mainLine(y), a.columns(), y < a.rows() - 1, "main row " + y);
        }
        if (a.alternateScreen()) {
            for (int y = 0; y < a.rows(); y++) {
                assertSameLine(a.line(y), b.line(y), a.columns(), y < a.rows() - 1, "alternate row " + y);
            }
        }
    }

    /** Everything but the cells, as one comparable string. */
    static String describeState(TerminalEmulator t) {
        StringBuilder tabs = new StringBuilder();
        for (int x = 0; x < t.columns(); x++) {
            if (t.isTabStop(x)) {
                tabs.append(x).append(',');
            }
        }
        return "cursor=" + t.cursorRow() + "," + t.cursorColumn() + (t.cursorPendingWrap() ? "+wrap" : "")
                + " pen=" + Style.describe(t.pen())
                + " visible=" + t.cursorVisible() + " shape=" + t.cursorShape() + " blink=" + t.cursorBlink()
                + " alt=" + t.alternateScreen() + " paste=" + t.bracketedPaste()
                + " ckm=" + t.applicationCursorKeys() + " keypad=" + t.applicationKeypad()
                + " mouse=" + t.mouseTracking() + "/" + t.mouseEncoding() + " focus=" + t.focusReporting()
                + " sync=" + t.synchronizedOutput() + " rv=" + t.reverseVideo() + " awm=" + t.autoWrap()
                + " decom=" + t.originMode() + " irm=" + t.insertMode() + " lnm=" + t.newLineMode()
                + " region=" + t.scrollTop() + "-" + t.scrollBottom() + " kitty=" + t.kittyKeyboardFlags()
                + " charsets=" + t.charsetState() + " title=" + t.title() + " tabs=" + tabs;
    }

    /** Compares the first {@code width} cells (a history line may be wider than the screen
     * it is redrawn on) and, if asked, the wrapped flag. */
    static void assertSameLine(Line a, Line b, int width, boolean compareWrapped, String label) {
        if (compareWrapped) {
            assertEquals(a.isWrapped(), b.isWrapped(), label + " wrapped");
        }
        for (int x = 0; x < width; x++) {
            assertEquals(cell(a, x), cell(b, x), label + " cell " + x + " in\n  " + a + "\n  " + b);
            assertEquals(Style.describe(a.style(x)), Style.describe(b.style(x)), label + " style " + x);
        }
    }

    private static String cell(Line line, int x) {
        if (line.isWideTail(x)) {
            return "<tail>";
        }
        String text = line.text(x);
        return text.isEmpty() ? " " : text;
    }

    private ModelAssert() {
    }
}
