package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The redraw on attach ({@link ScreenSerializer}). The contract is the round trip: feed a byte stream into emulator A, serialize A, feed the
 * result into a fresh emulator B of the same size, and assert A and B agree on every cell,
 * wrapped flag, cursor, scroll region, autowrap, origin mode, current style and mode (see
 * {@link ModelAssert}).
 */
class ScreenSerializerTest {

    private static final int HISTORY = 2000;

    private static HeadlessTerminal build(int cols, int rows, String... inputs) {
        HeadlessTerminal term = new HeadlessTerminal(cols, rows, HISTORY, b -> {
        });
        VtTokenizer tok = new VtTokenizer();
        for (String s : inputs) {
            apply(term, tok, s);
        }
        return term;
    }

    private static void apply(HeadlessTerminal term, VtTokenizer tok, String s) {
        VtTokenizer.Batch batch = tok.feed(s.getBytes(StandardCharsets.UTF_8));
        List<VtToken> norm = new ArrayList<>(batch.tokens().size());
        for (VtToken t : batch.tokens()) {
            norm.add(SgrNormalizer.normalize(t));
        }
        term.apply(norm);
    }

    /** Serialize A into a fresh B of the same size (through {@link HeadlessTerminal#serialize})
     * and assert they match. Returns B so a follow-up write can be applied to both. */
    private static HeadlessTerminal roundTrip(HeadlessTerminal a) {
        byte[] redraw = a.serialize(HISTORY);
        HeadlessTerminal b = new HeadlessTerminal(a.columns(), a.rows(), HISTORY, x -> {
        });
        apply(b, new VtTokenizer(), new String(redraw, StandardCharsets.UTF_8));
        assertSameState(a, b);
        assertEquals(a.modes(), b.modes(), "modes");
        assertEquals(a.screenText(), b.screenText(), "screen text");
        return b;
    }

    private static void assertSameState(HeadlessTerminal a, HeadlessTerminal b) {
        ModelAssert.assertSameState(a.emulator(), b.emulator(), HISTORY);
    }

    private static int cursorX(HeadlessTerminal t) {
        return t.emulator().cursorColumn();
    }

    // --- fixtures --------------------------------------------------------------------

    @Test
    void plainText() {
        roundTrip(build(40, 6, "hello world\r\nsecond line\r\nthird"));
    }

    @Test
    void stylesRgb256AndInverseSpaceRuns() {
        roundTrip(build(40, 6,
                "[1;31mbold red[m normal\r\n"
                        + "[38;5;208m256orange[m\r\n"
                        + "[38;2;10;200;30mtruecolor[m\r\n"
                        + "[7m inverse spaces [m done"));
    }

    @Test
    void colours256AndRgb() {
        roundTrip(build(30, 4,
                "[48;5;27m bg256 [m[48;2;1;2;3m bgrgb [m"));
    }

    @Test
    void titleIsRestored() {
        roundTrip(build(30, 3, "]0;My Sessioncontent"));
    }

    @Test
    void bracketedPasteAndMouseModes() {
        roundTrip(build(30, 3,
                "[?2004h[?1002h[?1006h[?25l[3 qprompt"));
    }

    @Test
    void historyBeyondTheScreen() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 30; i++) {
            sb.append("line ").append(i).append("\r\n");
        }
        sb.append("last");
        roundTrip(build(20, 5, sb.toString()));
    }

    @Test
    void wrappedLineWhoseLastCellIsSpace() {
        // 10 columns; write 9 chars + a space then keep going so the line wraps.
        roundTrip(build(10, 4, "ABCDEFGHI JKLMNOP"));
    }

    @Test
    void eraseAfterBackgroundColour() {
        // CSI 44 m then erase to end of line: BCE fills the rest with a blue background.
        roundTrip(build(20, 4, "hi[44m[K\r\nnext"));
    }

    @Test
    void eraseDisplayAfterBackgroundColour() {
        roundTrip(build(20, 4, "[41mstart[2J[Hafter"));
    }

    @Test
    void deleteCharOnWrappedLine() {
        // Fill a wrapped line, then CSI P (delete character) in the middle of it.
        roundTrip(build(8, 4, "ABCDEFGHijkl[3;1H[2P"));
    }

    @Test
    void lineExactlyColumnsWideNoCarriageReturn() {
        // Exactly 12 columns, cursor left on the last column with the wrap pending.
        HeadlessTerminal a = build(12, 4, "ABCDEFGHIJKL");
        assertEquals(11, cursorX(a));
        assertTrue(a.emulator().cursorPendingWrap());
        HeadlessTerminal b = roundTrip(a);
        assertEquals(11, cursorX(b));
        assertTrue(b.emulator().cursorPendingWrap());

        // Follow-up write on both sides must wrap identically.
        apply(a, new VtTokenizer(), "Z");
        apply(b, new VtTokenizer(), "Z");
        assertSameState(a, b);
    }

    @Test
    void pendingWrapFollowUpWrite() {
        HeadlessTerminal a = build(6, 4, "[1;33mABCDEF");
        assertTrue(a.emulator().cursorPendingWrap());
        HeadlessTerminal b = roundTrip(a);
        // A styled follow-up character wraps to the next row on both.
        apply(a, new VtTokenizer(), "g");
        apply(b, new VtTokenizer(), "g");
        assertSameState(a, b);
    }

    @Test
    void wideCharAtLastColumn() {
        // 6 columns: 4 half-width + a wide CJK filling columns 5-6 -> pending wrap.
        HeadlessTerminal a = build(6, 4, "abcd中");
        HeadlessTerminal b = roundTrip(a);
        apply(a, new VtTokenizer(), "x");
        apply(b, new VtTokenizer(), "x");
        assertSameState(a, b);
    }

    @Test
    void emojiOnScreen() {
        roundTrip(build(20, 4, "hi 🛑 stop 🚀 go"));
    }

    @Test
    void altScreenWithNonHomeCursorSgrAndOrigin() {
        // Set a title + cursor on main, then enter alt with SGR + DECOM and a non-home cursor.
        HeadlessTerminal a = build(20, 6,
                "]0;mainmain text[3;5H"
                        + "[?1049h[?6h[2;10r[4;3H[1;32malt screen");
        HeadlessTerminal b = roundTrip(a);
        // Leaving the alternate screen on both restores the stored (main) cursor + modes, and
        // the main screen (redrawn underneath the alternate one) is back unchanged.
        apply(a, new VtTokenizer(), "[?1049l");
        apply(b, new VtTokenizer(), "[?1049l");
        assertSameState(a, b);
    }

    @Test
    void scrollRegionSetThenResized() {
        HeadlessTerminal a = build(20, 10, "[3;8rregion text\r\nmore");
        a.resize(20, 14);
        roundTrip(a);
    }

    @Test
    void altScreenEnteredFromNonZeroMainColumnDrawsRowZeroFromHome() {
        // A shell prompt leaves the main cursor at column > 0; the program enters alt,
        // clears, homes and writes row 0. The redraw must not start row 0 at the saved column.
        HeadlessTerminal a = build(20, 6,
                "main text\r\nlong prompt $ "
                        + "[?1049h[2J[Hheader row\r\nsecond row");
        roundTrip(a); // assertSameState compares every alt-screen cell
    }

    @Test
    void wrappedLineWithBlankContinuation() {
        // 10 columns: the wrapped remainder is only spaces, then another line below it.
        roundTrip(build(10, 4, "abcdefghij   \r\nnext"));
    }

    @Test
    void spacePaddedLineWiderThanTheScreen() {
        // printf '%-14s' on a 10-column pane, followed by a prompt.
        HeadlessTerminal a = build(10, 4, "short         \r\n$ ");
        assertEquals(2, a.emulator().cursorRow());
        roundTrip(a);
    }

    @Test
    void wrappedHistoryLineWhoseBlankContinuationIsScreenRowZero() {
        // 4 rows: the wrapped line scrolls into history while its blank continuation stays
        // as screen row 0, so the pending wrap crosses the history/screen boundary.
        HeadlessTerminal a = build(10, 4, "abcdefghij   \r\none\r\ntwo\r\nthree");
        assertEquals(1, a.emulator().historySize());
        assertTrue(a.emulator().line(-1).isWrapped());
        roundTrip(a);
    }

    @Test
    void scrollRegionRoundTrips() {
        roundTrip(build(20, 10, "[2;9rinside"));
    }
}
