package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Unit tests of {@link TerminalEmulator}, per feature area, against xterm's behaviour. */
class TerminalEmulatorTest {

    private static final String E = "\u001b";
    private static final String C = E + "[";

    /** A terminal with replies captured in the FULL scope. */
    static final class Term {
        final TerminalEmulator e;
        final List<String> replies = new ArrayList<>();

        Term(int columns, int rows, int history) {
            e = new TerminalEmulator(columns, rows, history);
            e.setReplies(b -> replies.add(new String(b, StandardCharsets.UTF_8)), TerminalEmulator.ReplyScope.FULL);
        }

        Term feed(String s) {
            e.feed(s.getBytes(StandardCharsets.UTF_8));
            return this;
        }

        String row(int y) {
            return e.line(y).toString().stripTrailing();
        }

        long style(int y, int x) {
            return e.line(y).style(x);
        }

        void cursor(int row, int column) {
            assertEquals(row + "," + column, e.cursorRow() + "," + e.cursorColumn(), "cursor");
        }
    }

    static Term term(int columns, int rows) {
        return new Term(columns, rows, 100);
    }

    @Nested
    class Printing {
        @Test
        void deferredWrapAtTheLastColumn() {
            Term t = term(5, 3).feed("abcde");
            t.cursor(0, 4);
            assertTrue(t.e.cursorPendingWrap());
            t.feed("f");
            assertEquals("abcde", t.row(0));
            assertEquals("f", t.row(1));
            assertTrue(t.e.line(0).isWrapped());
            assertFalse(t.e.line(1).isWrapped());
        }

        @Test
        void carriageReturnClearsThePendingWrap() {
            Term t = term(5, 3).feed("abcde\rX");
            assertEquals("Xbcde", t.row(0));
            assertFalse(t.e.line(0).isWrapped());
        }

        @Test
        void autowrapOffOverwritesTheLastColumn() {
            Term t = term(5, 3).feed(C + "?7labcdefg");
            assertEquals("abcdg", t.row(0));
            assertEquals("", t.row(1));
        }

        @Test
        void wrappingAtTheBottomScrollsIntoHistory() {
            Term t = term(3, 2).feed("abcdefghi");
            assertEquals(1, t.e.historySize());
            assertEquals("abc", t.e.line(-1).toString());
            assertTrue(t.e.line(-1).isWrapped());
            assertEquals("def", t.row(0));
            assertEquals("ghi", t.row(1));
        }

        @Test
        void wideCharactersTakeTwoCells() {
            Term t = term(10, 2).feed("a中b");
            Line l = t.e.line(0);
            assertEquals(2, l.width(1));
            assertTrue(l.isWideTail(2));
            assertEquals(0, l.width(2));
            assertEquals("", l.text(2));
            assertEquals('b', l.codePoint(3));
            t.cursor(0, 4);
        }

        @Test
        void wideCharacterThatDoesNotFitWraps() {
            Term t = term(4, 3).feed("abc中");
            assertEquals("abc", t.row(0));
            assertTrue(t.e.line(0).isEmpty(3));
            assertTrue(t.e.line(0).isWrapped());
            assertEquals("中", t.row(1));
            t.cursor(1, 2);
        }

        @Test
        void overwritingHalfAWideCharacterBlanksTheOtherHalf() {
            Term t = term(10, 2).feed("中文" + C + "1;2Hx");
            assertEquals(" x文", t.row(0));
            t.feed(C + "1;3Hy");
            assertEquals(" xy ", t.e.line(0).toString().substring(0, 4));
            assertFalse(t.e.line(0).isWideTail(3));
        }

        @Test
        void combiningMarksAttachToThePreviousCell() {
            Term t = term(10, 2).feed("éx");
            assertEquals("é", t.e.line(0).text(0));
            assertEquals('x', t.e.line(0).codePoint(1));
            t.cursor(0, 2);
        }

        @Test
        void combiningMarkAtThePendingWrapAttachesToTheLastCell() {
            Term t = term(3, 2).feed("abé");
            assertEquals("é", t.e.line(0).text(2));
            assertTrue(t.e.cursorPendingWrap());
        }

        @Test
        void emojiSequencesShareOneCell() {
            Term t = term(20, 2).feed("👩‍💻|👍🏽|🇺🇸|❤️|");
            assertEquals("👩‍💻|👍🏽|🇺🇸|❤️|",
                    t.row(0).replace(" ", ""));
            assertEquals(2, t.e.line(0).width(0));
            assertEquals('|', t.e.line(0).codePoint(2));
            assertEquals('|', t.e.line(0).codePoint(5));
            assertEquals('|', t.e.line(0).codePoint(8));
            assertEquals('|', t.e.line(0).codePoint(10)); // U+2764 is narrow; VS16 attaches
        }

        @Test
        void asciiAfterZwjDoesNotJoin() {
            Term t = term(10, 2).feed("a‍b");
            assertEquals("a‍", t.e.line(0).text(0));
            assertEquals('b', t.e.line(0).codePoint(1));
        }

        @Test
        void insertModeShiftsTheLine() {
            Term t = term(6, 2).feed("abcdef\r" + C + "4hXY" + C + "4lZ");
            assertEquals("XYZbcd", t.row(0));
        }

        @Test
        void repeatsTheLastCharacter() {
            assertEquals("ab" + "bbb", term(10, 2).feed("ab" + C + "3b").row(0));
        }

        @Test
        void decSpecialGraphicsAndUkCharsets() {
            Term t = term(20, 2).feed(E + "(0lqkx_" + E + "(B lqk " + E + "(A#" + E + "(B#");
            assertEquals("┌─┐│  lqk £#", t.row(0));
        }

        @Test
        void shiftOutAndShiftIn() {
            Term t = term(10, 2).feed(E + ")0a\u000eq\u000fq" + E + "*0" + E + "Nqq");
            assertEquals("a─q─q", t.row(0));
        }

        @Test
        void malformedUtf8BecomesReplacementCharacters() {
            Term t = term(10, 2);
            t.e.feed(new byte[]{'a', (byte) 0xC3, 'b', (byte) 0xFF, (byte) 0xE4, (byte) 0xB8, (byte) 0xAD});
            assertEquals("a�b�中", t.row(0));
        }

        @Test
        void utf8SplitAcrossFeeds() {
            Term t = term(10, 2);
            byte[] bytes = "x中y".getBytes(StandardCharsets.UTF_8);
            for (byte b : bytes) {
                t.e.feed(new byte[]{b});
            }
            assertEquals("x中y", t.row(0));
        }

        @Test
        void c1ControlsAndDelAreDropped() {
            assertEquals("abc", term(10, 2).feed("a\u0085b\u007fc").row(0));
        }
    }

    @Nested
    class CursorMovement {
        @Test
        void absolutePositioning() {
            Term t = term(20, 10);
            t.feed(C + "3;4H").cursor(2, 3);
            t.feed(C + "5;6f").cursor(4, 5);
            t.feed(C + "H").cursor(0, 0);
            t.feed(C + "99;99H").cursor(9, 19);
            t.feed(C + "7G").cursor(9, 6);
            t.feed(C + "3`").cursor(9, 2);
            t.feed(C + "2d").cursor(1, 2);
            t.feed(C + "0;0H").cursor(0, 0);
        }

        @Test
        void relativeMovesWithDefaultsAndClamping() {
            Term t = term(20, 10).feed(C + "5;5H");
            t.feed(C + "A").cursor(3, 4);
            t.feed(C + "0B").cursor(4, 4);
            t.feed(C + "3C").cursor(4, 7);
            t.feed(C + "2D").cursor(4, 5);
            t.feed(C + "99D").cursor(4, 0);
            t.feed(C + "99A").cursor(0, 0);
            t.feed(C + "2a").cursor(0, 2); // HPR
            t.feed(C + "3e").cursor(3, 2); // VPR
            t.feed(C + "2E").cursor(5, 0);
            t.feed(C + "4;4H" + C + "F").cursor(2, 0);
        }

        @Test
        void verticalMovesRespectTheMarginsFromInside() {
            Term t = term(20, 10).feed(C + "3;6r" + C + "5;1H");
            t.feed(C + "9A").cursor(2, 0);
            t.feed(C + "9B").cursor(5, 0);
            t.feed(C + "8;1H" + C + "9A").cursor(2, 0); // from below the region it stops at the top margin
            t.feed(C + "1;1H" + C + "9B").cursor(5, 0);
            t.feed(C + "2;1H" + C + "A").cursor(0, 0);
        }

        @Test
        void originModeIsRelativeToTheRegion() {
            Term t = term(20, 10).feed(C + "3;6r" + C + "?6h");
            t.cursor(2, 0);
            t.feed(C + "2;3H").cursor(3, 2);
            t.feed(C + "99;1H").cursor(5, 0);
            t.feed(C + "1d").cursor(2, 0);
            t.feed(C + "6n");
            assertEquals(C + "1;1R", t.replies.getLast());
            t.feed(C + "?6l").cursor(0, 0);
        }

        @Test
        void backspaceStopsAtColumnZeroAndClearsThePendingWrap() {
            Term t = term(5, 3).feed("\b").feed("abcde\bX");
            assertEquals("abcXe", t.row(0));
        }

        @Test
        void relativeMoveFromAPendingWrapStartsAtTheLastColumn() {
            term(5, 3).feed("abcde" + C + "D").cursor(0, 3);
        }

        @Test
        void tabsAndTabStops() {
            Term t = term(30, 3).feed("\tx");
            t.cursor(0, 9);
            t.feed(C + "2I").cursor(0, 24);
            t.feed("\t\t\t").cursor(0, 29);
            t.feed(C + "Z").cursor(0, 24);
            t.feed(C + "3Z").cursor(0, 0);
            t.feed(C + "3g" + C + "1;4H" + E + "H\r\t").cursor(0, 3);
            t.feed("\t").cursor(0, 29);
            t.feed(C + "1;4H" + C + "g\r\t").cursor(0, 29);
            assertFalse(t.e.isTabStop(3));
        }

        @Test
        void saveAndRestoreCursor() {
            Term t = term(20, 5).feed(C + "2;3H" + C + "1;31m" + C + "?7l" + E + "7");
            t.feed(C + "0m" + C + "?7h" + C + "5;5H" + E + "8");
            t.cursor(1, 2);
            assertTrue(Style.bold(t.e.pen()));
            assertFalse(t.e.autoWrap());
            t.feed(C + "4;4H" + C + "s" + C + "1;1H" + C + "u").cursor(3, 3);
        }

        @Test
        void restoreWithoutSaveHomesAndResets() {
            Term t = term(20, 5).feed(C + "3;3H" + C + "1m" + E + "(0" + E + "8q");
            t.cursor(0, 1);
            assertEquals(Style.DEFAULT, t.e.pen());
            assertEquals("q", t.row(0));
        }

        @Test
        void restoredPendingWrapStillWraps() {
            Term t = term(4, 3).feed("abcd" + E + "7" + C + "3;1H" + E + "8x");
            assertEquals("x", t.row(1));
        }
    }

    @Nested
    class EraseAndEdit {
        @Test
        void eraseInDisplay() {
            Term t = term(5, 3).feed("aaaaa\r\nbbbbb\r\nccccc" + C + "2;3H" + C + "J");
            assertEquals(List.of("aaaaa", "bb", ""), List.of(t.row(0), t.row(1), t.row(2)));
            t = term(5, 3).feed("aaaaa\r\nbbbbb\r\nccccc" + C + "2;3H" + C + "1J");
            assertEquals(List.of("", "   bb", "ccccc"), List.of(t.row(0), t.row(1), t.row(2)));
        }

        @Test
        void eraseDisplayTwoMovesTheScreenToHistory() {
            Term t = term(5, 3).feed("one\r\ntwo" + C + "2J");
            assertEquals(2, t.e.historySize());
            assertEquals("one", t.e.line(-2).toString().strip());
            assertEquals("", t.row(0));
            t.feed(C + "3J");
            assertEquals(0, t.e.historySize());
        }

        @Test
        void eraseInLine() {
            assertEquals("ab", term(6, 2).feed("abcdef" + C + "1;3H" + C + "K").row(0));
            assertEquals("   def", term(6, 2).feed("abcdef" + C + "1;3H" + C + "1K").row(0));
            assertEquals("", term(6, 2).feed("abcdef" + C + "2K").row(0));
        }

        @Test
        void eraseUsesTheBackgroundOnly() {
            Term t = term(6, 2).feed("ab" + C + "1;4;31;44m" + C + "K");
            long erased = t.style(0, 5);
            assertEquals(Style.indexed(4), Style.background(erased));
            assertEquals(Style.COLOR_DEFAULT, Style.foreground(erased));
            assertFalse(Style.bold(erased));
            assertTrue(t.e.line(0).isEmpty(5));
        }

        @Test
        void eraseLineClearsTheWrappedFlag() {
            Term t = term(3, 3).feed("abcdef" + C + "1;1H" + C + "K");
            assertFalse(t.e.line(0).isWrapped());
        }

        @Test
        void insertDeleteAndEraseCharacters() {
            assertEquals("ab  cdef", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "2@").row(0));
            assertEquals("abefgh", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "2P").row(0));
            assertEquals("ab   fgh", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "3X").row(0));
            assertEquals("ab", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "99P").row(0));
        }

        @Test
        void deleteCharactersSplittingAWideCharacter() {
            Term t = term(8, 2).feed("a中b" + C + "1;3H" + C + "P");
            assertEquals("a b", t.row(0));
            assertFalse(t.e.line(0).isWideTail(1));
        }

        @Test
        void insertAndDeleteLinesInsideTheRegion() {
            Term t = term(3, 5).feed("1\r\n2\r\n3\r\n4\r\n5" + C + "2;4r" + C + "3;2H" + C + "L");
            assertEquals(List.of("1", "2", "", "3", "5"), rows(t));
            t.cursor(2, 0);
            t.feed(C + "2;1H" + C + "2M");
            assertEquals(List.of("1", "3", "", "", "5"), rows(t));
            t.feed(C + "5;1H" + C + "L"); // outside the region: nothing
            assertEquals(List.of("1", "3", "", "", "5"), rows(t));
        }

        @Test
        void alignmentTest() {
            Term t = term(3, 2).feed(C + "2;2r" + C + "2;2H" + E + "#8");
            assertEquals(List.of("EEE", "EEE"), rows(t));
            t.cursor(0, 0);
            assertEquals(1, t.e.scrollBottom());
        }
    }

    @Nested
    class Scrolling {
        @Test
        void historyIsBoundedAndKeepsTheNewestLines() {
            Term t = new Term(10, 2, 3);
            for (int i = 0; i < 10; i++) {
                t.feed("l" + i + "\r\n");
            }
            assertEquals(3, t.e.historySize());
            assertEquals("l6", t.e.line(-3).toString().strip());
            assertEquals("l8", t.e.line(-1).toString().strip());
            assertEquals("l9", t.row(0));
        }

        @Test
        void noHistoryWhenMaxIsZero() {
            Term t = new Term(10, 2, 0).feed("a\r\nb\r\nc");
            assertEquals(0, t.e.historySize());
            assertEquals(List.of("b", "c"), rows(t));
        }

        @Test
        void regionScrollingKeepsLinesOutsideAndAddsNoHistory() {
            Term t = term(3, 4).feed("A\r\nB\r\nC\r\nD" + C + "2;3r" + C + "3;1H\nx\ny");
            assertEquals(List.of("A", "x", " y", "D"), rows(t));
            assertEquals(0, t.e.historySize());
        }

        @Test
        void topAnchoredRegionScrollsIntoHistory() {
            // ratatui's inline viewport: region 1..n above the viewport, lines pushed into history.
            Term t = term(10, 4).feed("h1\r\nh2\r\nh3\r\nview" + C + "1;3r" + C + "3;1H\nnew" + C + "r");
            assertEquals(1, t.e.historySize());
            assertEquals("h1", t.e.line(-1).toString().strip());
            assertEquals(List.of("h2", "h3", "new", "view"), rows(t));
        }

        @Test
        void scrollUpAndDown() {
            Term t = term(3, 3).feed("1\r\n2\r\n3" + C + "S");
            assertEquals(List.of("2", "3", ""), rows(t));
            assertEquals(1, t.e.historySize());
            t.feed(C + "2T");
            assertEquals(List.of("", "", "2"), rows(t));
        }

        @Test
        void indexReverseIndexAndNextLine() {
            Term t = term(3, 3).feed("1\r\n2\r\n3" + C + "1;2H" + E + "M");
            assertEquals(List.of("", "1", "2"), rows(t));
            t.feed(C + "3;2H" + E + "D");
            assertEquals(List.of("1", "2", ""), rows(t));
            t.feed(C + "2;3H" + E + "E").cursor(2, 0);
        }

        @Test
        void scrolledInLinesTakeTheBackground() {
            Term t = term(3, 2).feed(C + "41m\r\n\r\n");
            assertEquals(Style.indexed(1), Style.background(t.style(1, 0)));
        }

        @Test
        void lineFeedModeAddsACarriageReturn() {
            term(10, 3).feed(C + "20habc\n").cursor(1, 0);
        }

        @Test
        void invalidRegionIsIgnored() {
            Term t = term(10, 6).feed(C + "2;5r" + C + "4;4r" + C + "5;2r");
            assertEquals(1, t.e.scrollTop());
            assertEquals(4, t.e.scrollBottom());
            t.feed(C + "r");
            assertEquals(5, t.e.scrollBottom());
        }
    }

    @Nested
    class Screens {
        @Test
        void mode1049SavesClearsAndRestores() {
            Term t = term(10, 3).feed("main" + C + "2;3H" + C + "?1049h");
            assertTrue(t.e.alternateScreen());
            assertEquals("", t.row(0));
            assertEquals(0, t.e.historySize());
            t.feed("alt\r\n\r\n\r\n\r\n" + C + "?1049l");
            assertFalse(t.e.alternateScreen());
            assertEquals("main", t.row(0));
            t.cursor(1, 2);
            assertEquals(0, t.e.historySize(), "the alternate screen has no history");
        }

        @Test
        void mode47KeepsTheAlternateContent() {
            Term t = term(10, 3).feed(C + "?47hone" + C + "?47l" + C + "?47h");
            assertEquals("one", t.row(0));
        }

        @Test
        void mode1047ClearsOnLeaving() {
            Term t = term(10, 3).feed(C + "?1047hone" + C + "?1047l" + C + "?1047h");
            assertEquals("", t.row(0));
        }

        @Test
        void mode1048SavesTheCursor() {
            term(10, 3).feed(C + "2;2H" + C + "?1048h" + C + "H" + C + "?1048l").cursor(1, 1);
        }

        @Test
        void savedCursorPerScreen() {
            Term t = term(10, 5).feed(C + "2;3H" + C + "?1049h" + C + "4;4H" + E + "7" + C + "H" + E + "8");
            t.cursor(3, 3);
            t.feed(C + "?1049l").cursor(1, 2);
            assertEquals(3, t.e.savedCursor(true).row());
        }

        @Test
        void fullReset() {
            Term t = term(10, 3).feed(E + "]2;keep\u0007text" + C + "1;31m" + C + "?1049h" + C + "?2004h" + C + "2;3r"
                    + E + "7" + E + "c");
            assertFalse(t.e.alternateScreen());
            assertEquals("", t.row(0));
            assertEquals(Style.DEFAULT, t.e.pen());
            assertFalse(t.e.bracketedPaste());
            assertEquals(2, t.e.scrollBottom());
            assertNull(t.e.savedCursor(false));
            assertEquals("keep", t.e.title());
        }

        @Test
        void softReset() {
            Term t = term(10, 3).feed(C + "2;3H" + C + "1m" + C + "?6h" + C + "4h" + C + "?25l" + C + "!p");
            assertEquals(Style.DEFAULT, t.e.pen());
            assertFalse(t.e.originMode());
            assertFalse(t.e.insertMode());
            assertTrue(t.e.cursorVisible());
        }
    }

    @Nested
    class Sgr {
        @Test
        void attributesSetAndReset() {
            Term t = term(20, 2).feed(C + "1;2;3;5;7;8;9;53mA" + C + "22;23;25;27;28;29;55mB" + C + "6mC" + C + "21mD"
                    + C + "4:3mE" + C + "4:0mF" + C + "4mG" + C + "24mH" + C + "mI");
            long a = t.style(0, 0);
            assertTrue(Style.bold(a) && Style.dim(a) && Style.italic(a) && Style.blink(a) && Style.inverse(a)
                    && Style.invisible(a) && Style.strikethrough(a) && Style.overline(a));
            assertEquals(Style.DEFAULT, t.style(0, 1));
            assertTrue(Style.rapidBlink(t.style(0, 2)));
            assertEquals(Style.UNDERLINE_DOUBLE, Style.underline(t.style(0, 3)));
            assertEquals(Style.UNDERLINE_CURLY, Style.underline(t.style(0, 4)));
            assertEquals(Style.UNDERLINE_NONE, Style.underline(t.style(0, 5)));
            assertEquals(Style.UNDERLINE_SINGLE, Style.underline(t.style(0, 6)));
            assertEquals(Style.UNDERLINE_NONE, Style.underline(t.style(0, 7)));
            assertEquals(Style.DEFAULT, t.style(0, 8));
        }

        @Test
        void colours() {
            Term t = term(20, 2).feed(C + "31;42mA" + C + "97;104mB" + C + "38;5;208;48;5;17mC"
                    + C + "38;2;1;2;3;48;2;250;251;252mD" + C + "38:2::9:8:7;48:5:99mE" + C + "38:2:4:5:6mF"
                    + C + "39;49mG");
            assertEquals(Style.indexed(1), Style.foreground(t.style(0, 0)));
            assertEquals(Style.indexed(2), Style.background(t.style(0, 0)));
            assertEquals(Style.indexed(15), Style.foreground(t.style(0, 1)));
            assertEquals(Style.indexed(12), Style.background(t.style(0, 1)));
            assertEquals(Style.indexed(208), Style.foreground(t.style(0, 2)));
            assertEquals(Style.indexed(17), Style.background(t.style(0, 2)));
            assertEquals(Style.rgb(1, 2, 3), Style.foreground(t.style(0, 3)));
            assertEquals(Style.rgb(250, 251, 252), Style.background(t.style(0, 3)));
            assertEquals(Style.rgb(9, 8, 7), Style.foreground(t.style(0, 4)));
            assertEquals(Style.indexed(99), Style.background(t.style(0, 4)));
            assertEquals(Style.rgb(4, 5, 6), Style.foreground(t.style(0, 5)));
            assertEquals(Style.DEFAULT, t.style(0, 6));
        }

        @Test
        void underlineColourIsParsedAndIgnored() {
            Term t = term(20, 2).feed(C + "58;2;1;2;3;1mA" + C + "0;58:5:9;3mB");
            assertEquals(Style.with(Style.DEFAULT, Style.BOLD, true), t.style(0, 0));
            assertEquals(Style.with(Style.DEFAULT, Style.ITALIC, true), t.style(0, 1));
        }

        @Test
        void invalidColoursLeaveThePenAlone() {
            Term t = term(20, 2).feed(C + "31m" + C + "38;5;300mA" + C + "38;2;1;2;999mB" + C + "38;7mC");
            for (int x = 0; x < 3; x++) {
                assertEquals(Style.indexed(1), Style.foreground(t.style(0, x)));
            }
        }

        @Test
        void styleColourHelpers() {
            assertTrue(Style.isIndexed(Style.indexed(0)));
            assertEquals(0, Style.index(Style.indexed(0)));
            assertTrue(Style.isRgb(Style.rgb(0, 0, 0)));
            assertEquals(0x010203, Style.rgbValue(Style.rgb(1, 2, 3)));
            assertFalse(Style.isIndexed(Style.COLOR_DEFAULT) || Style.isRgb(Style.COLOR_DEFAULT));
            assertEquals(0x000000, Style.xterm256Rgb(16));
            assertEquals(0xff8700, Style.xterm256Rgb(208));
            assertEquals(0x080808, Style.xterm256Rgb(232));
            assertEquals(0xeeeeee, Style.xterm256Rgb(255));
            assertEquals(-1, Style.xterm256Rgb(7));
        }
    }

    @Nested
    class Modes {
        @Test
        void privateModes() {
            Term t = term(10, 2).feed(C + "?1;5;12;25l" + C + "?1;5;12;2004;1004;2026h" + C + "?25l" + E + "=");
            assertTrue(t.e.applicationCursorKeys() && t.e.reverseVideo() && t.e.cursorBlink() && t.e.bracketedPaste()
                    && t.e.focusReporting() && t.e.synchronizedOutput() && t.e.applicationKeypad());
            assertFalse(t.e.cursorVisible());
            t.feed(C + "?1;5;12;2004;1004;2026l" + C + "?25h" + E + ">");
            assertFalse(t.e.applicationCursorKeys() || t.e.reverseVideo() || t.e.cursorBlink() || t.e.bracketedPaste()
                    || t.e.focusReporting() || t.e.synchronizedOutput() || t.e.applicationKeypad());
            assertTrue(t.e.cursorVisible());
        }

        @Test
        void mouseModes() {
            Term t = term(10, 2).feed(C + "?1000h");
            assertEquals(TerminalEmulator.MouseTracking.NORMAL, t.e.mouseTracking());
            t.feed(C + "?1002h");
            assertEquals(TerminalEmulator.MouseTracking.BUTTON_MOTION, t.e.mouseTracking());
            t.feed(C + "?1003h" + C + "?1006h");
            assertEquals(TerminalEmulator.MouseTracking.ANY_MOTION, t.e.mouseTracking());
            assertEquals(TerminalEmulator.MouseEncoding.SGR, t.e.mouseEncoding());
            t.feed(C + "?1015h");
            assertEquals(TerminalEmulator.MouseEncoding.URXVT, t.e.mouseEncoding());
            t.feed(C + "?1005h" + C + "?9h");
            assertEquals(TerminalEmulator.MouseEncoding.UTF8, t.e.mouseEncoding());
            assertEquals(TerminalEmulator.MouseTracking.X10, t.e.mouseTracking());
            t.feed(C + "?1005l" + C + "?1000l");
            assertEquals(TerminalEmulator.MouseEncoding.DEFAULT, t.e.mouseEncoding());
            assertEquals(TerminalEmulator.MouseTracking.NONE, t.e.mouseTracking());
        }

        @Test
        void cursorShape() {
            Term t = term(10, 2);
            assertEquals(0, t.e.cursorShape());
            t.feed(C + "4 q");
            assertEquals(4, t.e.cursorShape());
            t.feed(C + " q");
            assertEquals(1, t.e.cursorShape());
            t.feed(C + "9 q");
            assertEquals(1, t.e.cursorShape());
        }

        @Test
        void kittyKeyboardFlags() {
            Term t = term(10, 2).feed(C + ">1u" + C + ">3u");
            assertEquals(3, t.e.kittyKeyboardFlags());
            t.feed(C + "=4;2u");
            assertEquals(7, t.e.kittyKeyboardFlags());
            t.feed(C + "=2;3u");
            assertEquals(5, t.e.kittyKeyboardFlags());
            t.feed(C + "?u");
            assertEquals(C + "?5u", t.replies.getLast());
            t.feed(C + "<u");
            assertEquals(1, t.e.kittyKeyboardFlags());
            t.feed(C + "<9u");
            assertEquals(0, t.e.kittyKeyboardFlags());
        }

        @Test
        void titlesAndTheTitleStack() {
            Term t = term(10, 2).feed(E + "]0;one\u0007");
            assertEquals("one", t.e.title());
            t.feed(E + "]2;two" + E + "\\");
            assertEquals("two", t.e.title());
            t.feed(E + "]1;icon\u0007");
            assertEquals("icon", t.e.title());
            t.feed(C + "22;0t" + E + "]2;pushed\u0007" + C + "23;0t");
            assertEquals("icon", t.e.title());
            t.feed(E + "]2;télé\u0007");
            assertEquals("télé", t.e.title());
            t.feed(E + "]7;file://h/tmp\u0007" + E + "]x;y\u0007" + E + "]2\u0007");
            assertEquals("télé", t.e.title());
        }

        @Test
        void windowResizeRequestsAreIgnored() {
            Term t = term(10, 2).feed(C + "8;40;120t");
            assertEquals(10, t.e.columns());
            assertEquals(2, t.e.rows());
        }
    }

    @Nested
    class Replies {
        @Test
        void basicScopeAnswersWhatQueryFilterStrips() {
            List<String> replies = new ArrayList<>();
            TerminalEmulator e = new TerminalEmulator(10, 3, 0);
            e.setReplies(b -> replies.add(new String(b, StandardCharsets.UTF_8)), TerminalEmulator.ReplyScope.BASIC);
            String[] queries = {C + "c", C + "0c", C + "=c", C + ">c", C + ">0c", C + "5n", C + "6n",
                    C + ">1c", C + "?6n", C + "?996n", C + "?1$p", C + "4$p", C + ">q", C + "?u", E + "]11;?\u0007",
                    E + "P+q544e" + E + "\\"};
            for (String q : queries) {
                replies.clear();
                e.feed(q.getBytes(StandardCharsets.UTF_8));
                VtToken token = new VtTokenizer().feed(q.getBytes(StandardCharsets.UTF_8)).tokens().getFirst();
                boolean stripped = QueryFilter.isServerAnswered(token);
                boolean xtgettcap = q.startsWith(E + "P");
                assertEquals(stripped || xtgettcap, !replies.isEmpty(), FuzzTest.visible(q));
            }
        }

        @Test
        void deviceAttributesAndStatus() {
            Term t = term(10, 3).feed(C + "c" + C + ">c" + C + "5n" + C + "2;4H" + C + "6n" + C + "?6n");
            assertEquals(List.of(C + "?62;22c", C + ">0;10;0c", C + "0n", C + "2;4R", C + "?2;4;1R"), t.replies);
        }

        @Test
        void cursorReportAtAPendingWrapUsesTheLastColumn() {
            Term t = term(5, 3).feed("abcde" + C + "6n");
            assertEquals(C + "1;5R", t.replies.getLast());
        }

        @Test
        void decrqmAndXtversion() {
            Term t = term(10, 3).feed(C + "?2004h" + C + "?2004$p" + C + "?1$p" + C + "?9999$p" + C + "4$p" + C + ">q");
            assertEquals(List.of(C + "?2004;1$y", C + "?1;2$y", C + "?9999;0$y", C + "4;2$y",
                    E + "P>|microhm-vt" + E + "\\"), t.replies);
        }

        @Test
        void colourSchemeQueryIsNotAnswered() {
            assertTrue(term(10, 3).feed(C + "?996n").replies.isEmpty());
        }

        @Test
        void colourSchemeQueryIsAnsweredOnceASchemeIsSet() {
            Term t = term(10, 3);
            t.e.setColorScheme(TerminalEmulator.ColorScheme.DARK);
            t.feed(C + "?996n");
            t.e.setColorScheme(TerminalEmulator.ColorScheme.LIGHT);
            t.feed(C + "?996n");
            assertEquals(List.of(C + "?997;1n", C + "?997;2n"), t.replies);
            t.e.setColorScheme(null);
            t.feed(C + "?996n");
            assertEquals(2, t.replies.size());
        }

        @Test
        void clientScopeAnswersOnlyTheColourScheme() {
            List<String> replies = new ArrayList<>();
            TerminalEmulator e = new TerminalEmulator(10, 3, 0);
            e.setReplies(b -> replies.add(new String(b, StandardCharsets.UTF_8)), TerminalEmulator.ReplyScope.CLIENT);
            e.setColorScheme(TerminalEmulator.ColorScheme.LIGHT);
            String all = C + "c" + C + ">c" + C + "5n" + C + "6n" + C + "?6n" + C + "?1$p" + C + ">q" + C + "?u"
                    + E + "P+q544e" + E + "\\" + C + "?996n";
            e.feed(all.getBytes(StandardCharsets.UTF_8));
            assertEquals(List.of(C + "?997;2n"), replies);
        }

        @Test
        void schemeChangesAreReportedWhileMode2031IsOn() {
            Term t = term(10, 3);
            t.e.setColorScheme(TerminalEmulator.ColorScheme.DARK);
            t.e.setColorScheme(TerminalEmulator.ColorScheme.LIGHT); // 2031 off: silent
            assertTrue(t.replies.isEmpty());
            t.feed(C + "?2031h");
            assertTrue(t.e.colorSchemeUpdates());
            t.e.setColorScheme(TerminalEmulator.ColorScheme.LIGHT); // unchanged: silent
            t.e.setColorScheme(TerminalEmulator.ColorScheme.DARK);
            assertEquals(List.of(C + "?997;1n"), t.replies);
            t.feed(C + "?2031l");
            t.e.setColorScheme(TerminalEmulator.ColorScheme.LIGHT);
            assertEquals(1, t.replies.size());
        }

        @Test
        void historyLinesAddedKeepsCountingOnceTheHistoryIsFull() {
            TerminalEmulator e = new TerminalEmulator(5, 2, 3);
            e.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6".getBytes(StandardCharsets.UTF_8));
            assertEquals(3, e.historySize());
            assertEquals(4, e.historyLinesAdded());
            e.feed((C + "3J").getBytes(StandardCharsets.UTF_8));
            assertEquals(0, e.historySize());
            assertEquals(4, e.historyLinesAdded());
            TerminalEmulator alt = new TerminalEmulator(5, 2, 3);
            alt.feed((C + "?1049h" + "1\r\n2\r\n3").getBytes(StandardCharsets.UTF_8));
            assertEquals(0, alt.historyLinesAdded());
        }

        @Test
        void noSinkNoReplies() {
            TerminalEmulator e = new TerminalEmulator(10, 3, 0);
            e.feed((C + "c" + C + "6n").getBytes(StandardCharsets.UTF_8));
            assertEquals(0, e.cursorRow());
        }
    }

    @Nested
    class Resize {
        @Test
        void shrinkingRowsPushesTopLinesIntoHistoryToKeepTheCursor() {
            Term t = term(10, 5).feed("1\r\n2\r\n3\r\n4\r\n5");
            t.e.resize(10, 3);
            assertEquals(List.of("3", "4", "5"), rows(t));
            assertEquals(2, t.e.historySize());
            t.cursor(2, 1);
        }

        @Test
        void shrinkingRowsDropsBlankRowsBelowTheCursorFirst() {
            Term t = term(10, 5).feed("1\r\n2");
            t.e.resize(10, 3);
            assertEquals(List.of("1", "2", ""), rows(t));
            assertEquals(0, t.e.historySize());
        }

        @Test
        void growingRowsAddsBlankRowsAndColumnsTruncateAndPad() {
            Term t = term(6, 2).feed("abcdef\r\nxy");
            t.e.resize(4, 4);
            assertEquals(List.of("abcd", "xy", "", ""), rows(t));
            t.e.resize(8, 4);
            assertEquals("abcd", t.row(0));
            assertEquals(8, t.e.line(0).columns());
            t.feed(C + "1;8Hz");
            assertEquals("abcd   z", t.row(0));
        }

        @Test
        void resizeResetsTheRegionAndClampsTheCursor() {
            Term t = term(10, 10).feed(C + "2;8r" + C + "9;10H");
            t.e.resize(5, 10);
            assertEquals(0, t.e.scrollTop());
            assertEquals(9, t.e.scrollBottom());
            t.cursor(8, 4);
            assertFalse(t.e.cursorPendingWrap());
        }

        @Test
        void bothScreensResize() {
            Term t = term(10, 4).feed("main\r\n\r\n\r\nlast" + C + "?1049h" + C + "Halt");
            t.e.resize(6, 2);
            assertEquals("alt", t.row(0), "blank alternate rows below the cursor go first");
            t.feed(C + "?1049l");
            assertEquals(6, t.e.line(0).columns());
            assertEquals("last", t.row(1), "the main screen kept the row of its saved cursor");
            t.cursor(1, 4);
            assertEquals(2, t.e.historySize());
        }

        @Test
        void wideCharacterCutByTheNewWidthIsBlanked() {
            Term t = term(6, 2).feed("abcd中");
            t.e.resize(5, 2);
            assertEquals("abcd", t.row(0));
            assertFalse(t.e.line(0).isWideTail(4));
        }

        @Test
        void historyLinesKeepTheirWidth() {
            Term t = term(6, 2).feed("abcdef\r\n\r\n\r\n");
            t.e.resize(3, 2);
            assertEquals("abcdef", t.e.line(-2).toString());
            assertEquals(6, t.e.line(-2).columns());
        }
    }

    @Nested
    class Notifications {
        @Test
        void listenerGetsChangesBellsAndTitles() {
            List<String> events = new ArrayList<>();
            TerminalEmulator e = new TerminalEmulator(10, 2, 0);
            e.setListener(new TerminalListener() {
                @Override
                public void contentChanged() {
                    assertFalse(e.lock().isHeldByCurrentThread(), "called outside the lock");
                    events.add("changed");
                }

                @Override
                public void bell(int count) {
                    events.add("bell " + count);
                }

                @Override
                public void titleChanged(String title) {
                    events.add("title " + title);
                }
            });
            long before = e.changeCount();
            e.feed(("a\u0007\u0007" + E + "]2;t\u0007").getBytes(StandardCharsets.UTF_8));
            assertEquals(List.of("title t", "bell 2", "changed"), events);
            assertTrue(e.changeCount() > before);
            e.resize(12, 3);
            assertEquals("changed", events.getLast());
        }

        @Test
        void repliesAreSentOutsideTheLock() {
            TerminalEmulator e = new TerminalEmulator(10, 2, 0);
            List<Boolean> held = new ArrayList<>();
            e.setReplies(b -> held.add(e.lock().isHeldByCurrentThread()), TerminalEmulator.ReplyScope.BASIC);
            e.feed((C + "c").getBytes(StandardCharsets.UTF_8));
            assertEquals(List.of(false), held);
        }
    }

    private static List<String> rows(Term t) {
        List<String> out = new ArrayList<>();
        for (int y = 0; y < t.e.rows(); y++) {
            out.add(t.row(y));
        }
        return out;
    }

    @Nested
    class LineVersions {
        /** Each sequence must change the version of the line at row 0 (cursor at 0,2). */
        @Test
        void everyRowMutationBumpsTheVersion() {
            String[] mutations = {"x", "\u00e9", "\u4e2d", "e\u0301", C + "K", C + "1K", C + "2K", C + "@",
                    C + "P", C + "X", C + "4hz", C + "J", C + "1J", C + "2J", E + "#8"};
            for (String m : mutations) {
                Term t = term(6, 3).feed("abcdef" + C + "1;3H");
                Line line = t.e.line(0);
                long before = line.version();
                t.feed(m);
                // Either the same line object changed, or a different (cleared/recycled) one is there.
                Line after = t.e.line(0);
                assertTrue(after != line || line.version() != before, FuzzTest.visible(m));
            }
        }

        @Test
        void softWrapAndUntouchedRows() {
            Term t = term(4, 3).feed("ab");
            Line row1 = t.e.line(1);
            long v1 = row1.version();
            Line row0 = t.e.line(0);
            long v0 = row0.version();
            t.feed("cd");
            assertTrue(row0.version() != v0);
            assertEquals(v1, row1.version(), "a row nothing wrote to keeps its version");
            v0 = row0.version();
            t.feed("e"); // the deferred wrap marks row 0 wrapped
            assertTrue(row0.isWrapped());
            assertTrue(row0.version() != v0);
        }

        @Test
        void scrollRecyclesALineWithANewVersion() {
            Term t = new Term(4, 2, 0).feed("ab\r\ncd");
            Line top = t.e.line(0);
            long v = top.version();
            t.feed("\r\n"); // row 0 is recycled as the new, cleared bottom row
            assertTrue(t.e.line(1) != top || top.version() != v);
        }
    }
}
