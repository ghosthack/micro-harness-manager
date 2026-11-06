package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.util.List;
import java.util.function.Consumer;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Every place the emulator deliberately differs from jediterm-core (3.76, the reference the
 * golden files were checked against), each with the reason and an assertion of the
 * emulator's (xterm's) behaviour. The fuzz generator ({@link VtFuzz}) steers clear of
 * exactly these situations in its common mode, the one its goldens were frozen in.
 */
class KnownDifferencesTest {

    private static final String E = "\u001b";
    private static final String C = E + "[";

    /** A difference: {@code xterm} asserts the emulator's behaviour, {@code replies} (when not
     * null) the exact replies it sends. */
    record Case(String name, String reason, int columns, int rows, String input, Consumer<TerminalEmulator> xterm,
                List<String> replies) {
        Case(String name, String reason, int columns, int rows, String input, Consumer<TerminalEmulator> xterm) {
            this(name, reason, columns, rows, input, xterm, null);
        }

        @Override
        public String toString() {
            return name;
        }
    }

    private static Consumer<TerminalEmulator> cursorAt(int row, int column) {
        return e -> {
            assertEquals(row, e.cursorRow(), "row");
            assertEquals(column, e.cursorColumn(), "column");
        };
    }

    private static Consumer<TerminalEmulator> row(int y, String text) {
        return e -> assertEquals(text, e.line(y).toString().stripTrailing(), "row " + y);
    }

    static Stream<Case> cases() {
        return Stream.of(
                new Case("CUU stops at the top margin outside origin mode",
                        "xterm limits CUU/CUD to the margins whenever the cursor is inside the region; jediterm "
                                + "only in origin mode", 20, 8, C + "3;6r" + C + "5;1H" + C + "9A", cursorAt(2, 0)),
                new Case("relative move from a pending wrap starts at the last column",
                        "xterm clears the pending wrap and moves from the last column; jediterm's cursor is one "
                                + "past it", 5, 3, "abcde" + C + "D", cursorAt(0, 3)),
                new Case("line feed clears a pending wrap",
                        "after LF the next character goes in the last column of the next row; jediterm still "
                                + "wraps it to column 0 of the row after", 5, 4, "abcde\nX",
                        row(1, "    X")),
                new Case("EL 0 at a pending wrap erases the last cell",
                        "the cursor is on the last column; jediterm's EL does nothing past the margin", 5, 3,
                        "abcde" + C + "K", row(0, "abcd")),
                new Case("autowrap off overwrites the last column",
                        "DECAWM reset: further characters replace the last cell; jediterm wraps to column 0 of the "
                                + "same row", 5, 3, C + "?7labcdefg", row(0, "abcdg")),
                new Case("IL and DL return to column 0",
                        "xterm moves the cursor to the left margin; jediterm keeps the column", 20, 5,
                        C + "2;5H" + C + "L", cursorAt(1, 0)),
                new Case("DECOM homes the cursor",
                        "setting or resetting origin mode moves the cursor to the (region's) home; jediterm "
                                + "leaves it", 20, 6, C + "2;5r" + C + "4;4H" + C + "?6h", cursorAt(1, 0)),
                new Case("ED 3 keeps the screen",
                        "xterm's ED 3 only clears the scrollback; jediterm also clears the screen", 20, 3,
                        "keep" + C + "3J", row(0, "keep")),
                new Case("ED 1 keeps the rest of the cursor row",
                        "ED 1 erases up to and including the cursor; jediterm clears the whole cursor row "
                                + "(an off-by-one)", 20, 3, "abcdef" + C + "1;3H" + C + "1J", row(0, "   def")),
                new Case("EL with a background reaches the margin",
                        "background colour erase fills to the right margin; jediterm's EL stops at the written "
                                + "text, so the rest keeps the default background", 10, 3, "ab" + C + "44m" + C + "K",
                        e -> assertEquals(Style.indexed(4), Style.background(e.line(0).style(9)))),
                new Case("tab only moves the cursor",
                        "HT writes nothing; jediterm writes spaces in the pen up to the stop, over erased cells",
                        20, 3, C + "41m" + C + "K" + C + "0m\tx",
                        e -> assertEquals(Style.indexed(1), Style.background(e.line(0).style(3)))),
                new Case("DCH fills at the right margin",
                        "xterm inserts the blanks at the right margin; jediterm at the end of the written text",
                        20, 3, "abcdef" + C + "1;2H" + C + "42m" + C + "2P",
                        e -> assertEquals(Style.indexed(2), Style.background(e.line(0).style(19)))),
                new Case("CHA in origin mode keeps the row",
                        "jediterm's CHA/HPA/CNL/CPL go through its CUP and re-apply the origin offset", 20, 8,
                        C + "3;6r" + C + "?6h" + C + "2;1H" + C + "5G", cursorAt(3, 4)),
                new Case("VPA in origin mode is relative to the region",
                        "jediterm treats VPA as absolute", 20, 8, C + "3;6r" + C + "?6h" + C + "2d", cursorAt(3, 0)),
                new Case("restored cursor is confined to the region in origin mode",
                        "as xterm's CursorRestore; jediterm restores it outside", 20, 8,
                        C + "?6h" + C + "1;1H" + E + "7" + C + "4;6r" + E + "8", cursorAt(3, 0)),
                new Case("saved cursor per screen",
                        "xterm keeps one DECSC slot per screen, so ESC 7 on the alternate screen does not change "
                                + "what CSI ?1049 l restores; jediterm has a single slot", 20, 6,
                        C + "2;3H" + C + "?1049h" + C + "5;5H" + E + "7" + C + "?1049l", cursorAt(1, 2)),
                new Case("RIS resets tab stops, bracketed paste and the saved cursor",
                        "jediterm's reset keeps them", 20, 3,
                        C + "3g" + C + "?2004h" + C + "2;5H" + E + "7" + E + "c" + E + "8\tx",
                        e -> {
                            assertFalse(e.bracketedPaste());
                            assertEquals("        x", e.line(0).toString().stripTrailing());
                        }),
                new Case("DECALN resets the margins and homes",
                        "jediterm fills with the pen and keeps cursor and margins", 6, 3,
                        C + "2;3r" + C + "3;4H" + E + "#8", cursorAt(0, 0)),
                new Case("DECSTBM needs two lines",
                        "xterm ignores a region with top >= bottom; jediterm applies it", 20, 6,
                        C + "4;4r", e -> assertEquals(5, e.scrollBottom())),
                new Case("backspace at column 0 stays",
                        "without reverse-wrap (DECSET 45) BS does not leave the row; jediterm moves to the end "
                                + "of the previous row", 10, 3, "\r\n\b", cursorAt(1, 0)),
                new Case("DEL is ignored",
                        "xterm ignores DEL; jediterm prints it", 10, 3, "a\u007fb", row(0, "ab")),
                new Case("SO selects G1",
                        "jediterm ignores SO unless a system property enables it", 10, 3,
                        E + ")0\u000eq\u000fq", row(0, "─q")),
                new Case("insert mode",
                        "IRM shifts the line right; jediterm ignores it", 10, 3, "abc\r" + C + "4hX", row(0, "Xabc")),
                new Case("REP, CHT, CBT, HPR, VPR, CSI s/u",
                        "jediterm does not implement them", 20, 4,
                        "x" + C + "3b" + C + "I" + "y" + C + "Z" + "z" + C + "2a" + C + "e" + C + "s" + C + "1;1H" + C + "u!",
                        e -> {
                            assertEquals("xxxx    z", e.line(0).toString().stripTrailing());
                            assertEquals("           !", e.line(1).toString().stripTrailing());
                        }),
                new Case("alternate screen 47 is not cleared",
                        "xterm's mode 47 switches without clearing; jediterm makes a fresh buffer every time",
                        20, 3, C + "?47hkept" + C + "?47l" + C + "?47h", row(0, "kept")),
                new Case("combining marks attach to the previous cell",
                        "jediterm NFC-normalises and gives a cell to each mark that does not compose", 10, 3,
                        "x́̂y", e -> assertEquals("x́̂", e.line(0).text(0))),
                new Case("supplementary narrow characters are one cell",
                        "jediterm gives every surrogate pair two cells", 10, 3, "𝐀b", row(0, "𝐀b")),
                new Case("emoji sequences are one wide cell",
                        "modifiers, ZWJ sequences and flags join the previous cell; jediterm stores each code "
                                + "point", 20, 3, "👍🏽🇺🇸!",
                        e -> assertEquals('!', e.line(0).codePoint(4))),
                new Case("C1 controls are not printed",
                        "U+0080..U+009F have no width; jediterm prints them", 10, 3, "a\u0085b", row(0, "ab")),
                new Case("strikethrough, overline and underline styles",
                        "jediterm models none of SGR 9, 53, 21 and 4:x (the daemon's normaliser turns 4:3 into 4)",
                        10, 3,
                        C + "9;53;4:3mx", e -> {
                            long style = e.line(0).style(0);
                            assertTrue(Style.strikethrough(style) && Style.overline(style));
                        }),
                new Case("DA1 identifies as a VT220 with ANSI colour",
                        "jediterm answers VT102 (CSI ? 6 c)", 10, 3, C + "c", e -> {
                        }, List.of(C + "?62;22c")),
                new Case("CPR at a pending wrap reports the last column",
                        "jediterm reports one past the margin", 5, 3, "abcde" + C + "6n", e -> {
                        }, List.of(C + "1;5R")));
    }

    @ParameterizedTest
    @MethodSource("cases")
    void behavesAsXtermDoes(Case c) {
        Subject s = new Subject(c.columns(), c.rows(), 100);
        s.feed(c.input());
        c.xterm().accept(s.emulator());
        if (c.replies() != null) {
            assertEquals(c.replies(), s.replies, "replies");
        }
    }

    @ParameterizedTest
    @MethodSource("cases")
    void serializerRoundTrips(Case c) {
        TerminalEmulator e = new TerminalEmulator(c.columns(), c.rows(), 100);
        e.feed(c.input().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        ModelAssert.roundTrip(e, 100);
    }
}
