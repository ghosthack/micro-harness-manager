package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.TerminalEmulator;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

class SelectionTextTest {

    private static TerminalEmulator term(int columns, int rows, String content) {
        TerminalEmulator e = new TerminalEmulator(columns, rows, 100);
        e.feed(content.getBytes(StandardCharsets.UTF_8));
        return e;
    }

    @Test
    void trimsTrailingBlanksOfHardLines() {
        TerminalEmulator e = term(10, 3, "ab   \r\ncd\r\nef");
        assertEquals("ab\ncd\nef", SelectionText.extract(e, 0, 0, 2, 10));
    }

    @Test
    void partialFirstAndLastLines() {
        TerminalEmulator e = term(10, 3, "hello\r\nworld");
        assertEquals("llo\nwor", SelectionText.extract(e, 0, 2, 1, 3));
        assertEquals("ell", SelectionText.extract(e, 0, 1, 0, 4));
    }

    @Test
    void softWrapsJoinWithoutANewline() {
        TerminalEmulator e = term(5, 3, "abcdefgh\r\nz");
        assertEquals("abcdefgh\nz", SelectionText.extract(e, 0, 0, 2, 5));
    }

    @Test
    void interiorEmptyCellsAreSpaces() {
        TerminalEmulator e = term(10, 2, "a\u001b[5Gb");
        assertEquals("a   b", SelectionText.extract(e, 0, 0, 0, 10));
    }

    @Test
    void wideCharactersAreCopiedOnce() {
        TerminalEmulator e = term(10, 2, "x中文y");
        assertEquals("x中文y", SelectionText.extract(e, 0, 0, 0, 10));
        // starting on the tail of 中 takes the whole character
        assertEquals("中文", SelectionText.extract(e, 0, 2, 0, 5));
    }

    @Test
    void wideCharacterThatDidNotFitLeavesNoGapAcrossTheWrap() {
        TerminalEmulator e = term(4, 3, "abc中");
        assertEquals("abc中", SelectionText.extract(e, 0, 0, 1, 4));
    }

    @Test
    void combiningMarksStayWithTheirCell() {
        TerminalEmulator e = term(10, 2, "éä!");
        assertEquals("éä!", SelectionText.extract(e, 0, 0, 0, 10));
        assertEquals("ä", SelectionText.extract(e, 0, 1, 0, 2));
    }

    @Test
    void reachesIntoHistory() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 6; i++) {
            sb.append("line").append(i).append("\r\n");
        }
        TerminalEmulator e = term(10, 3, sb.toString());
        assertEquals(4, e.historySize());
        assertEquals("line2\nline3\nline4", SelectionText.extract(e, -2, 0, 0, 10));
        // a start older than the history is clamped to its first line
        assertEquals("line0\nline1", SelectionText.extract(e, -10, 0, -3, 10));
    }

    @Test
    void wordBoundaries() {
        TerminalEmulator e = term(40, 2, "cat /usr/local/bin  foo(bar) x中文y");
        assertArrayEquals(new int[]{4, 18}, SelectionText.word(e.line(0), 8));
        assertArrayEquals(new int[]{18, 20}, SelectionText.word(e.line(0), 18)); // the blank run
        assertArrayEquals(new int[]{20, 23}, SelectionText.word(e.line(0), 21));
        assertArrayEquals(new int[]{23, 24}, SelectionText.word(e.line(0), 23)); // '(' alone
        assertArrayEquals(new int[]{29, 35}, SelectionText.word(e.line(0), 31)); // wide chars, from a tail
    }

    @Test
    void logicalLineSpansSoftWraps() {
        TerminalEmulator e = term(5, 5, "ab\r\nabcdefghijk\r\nz");
        assertArrayEquals(new int[]{1, 3}, SelectionText.logicalLine(e, 2));
        assertArrayEquals(new int[]{0, 0}, SelectionText.logicalLine(e, 0));
    }
}
