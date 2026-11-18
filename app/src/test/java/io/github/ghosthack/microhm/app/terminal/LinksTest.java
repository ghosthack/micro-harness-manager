package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.TerminalEmulator;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class LinksTest {

    private static TerminalEmulator term(int columns, int rows, String content) {
        TerminalEmulator e = new TerminalEmulator(columns, rows, 100);
        e.feed(content.getBytes(StandardCharsets.UTF_8));
        return e;
    }

    @Test
    void findsTheLinkUnderACell() {
        TerminalEmulator e = term(40, 2, "see https://a.example/x now");
        assertEquals("https://a.example/x", Links.urlAt(e, 0, 4));
        assertEquals("https://a.example/x", Links.urlAt(e, 0, 22));
        assertNull(Links.urlAt(e, 0, 3));
        assertNull(Links.urlAt(e, 0, 23));
        assertNull(Links.urlAt(e, 1, 4));
    }

    @Test
    void followsALinkAcrossSoftWraps() {
        TerminalEmulator e = term(12, 4, "go https://claude.ai/code/s\r\nnext");
        String url = "https://claude.ai/code/s";
        assertEquals(url, Links.urlAt(e, 0, 5));
        assertEquals(url, Links.urlAt(e, 2, 0));
        assertNull(Links.urlAt(e, 3, 0));
    }

    @Test
    void followsALinkTheProgramBrokeAtTheEdge() {
        // Claude Code's /rc at 30 columns: it breaks the link itself, indenting the rest
        TerminalEmulator e = term(30, 4,
                "  phone, or at https://claude\r\n  .ai/code/session_01Vwo\r\n  more text here");
        String url = "https://claude.ai/code/session_01Vwo";
        assertEquals(url, Links.urlAt(e, 0, 20));
        assertEquals(url, Links.urlAt(e, 1, 2));
        assertEquals(url, Links.urlAt(e, 1, 23));
        assertNull(Links.urlAt(e, 1, 24));
        assertNull(Links.urlAt(e, 2, 3));
    }

    @Test
    void aLinkShortOfTheEdgeEndsWithItsRow() {
        TerminalEmulator e = term(40, 2, "  - https://a.example/x\r\n  - next item");
        assertEquals("https://a.example/x", Links.urlAt(e, 0, 5));
        assertNull(Links.urlAt(e, 1, 4));
    }

    @Test
    void aBreakAtADifferentIndentIsNotTheLink() {
        TerminalEmulator e = term(20, 2, "  https://a.example/\r\n    word");
        assertEquals("https://a.example/", Links.urlAt(e, 0, 5));
        assertNull(Links.urlAt(e, 1, 5));
    }

    @Test
    void leavesOutTheSentenceAroundIt() {
        assertEquals("https://a.example/x", Links.trim("https://a.example/x."));
        assertEquals("https://a.example/x", Links.trim("https://a.example/x),"));
        assertEquals("https://en.example/A_(b)", Links.trim("https://en.example/A_(b)"));
        TerminalEmulator e = term(40, 1, "(at https://a.example/x).");
        assertEquals("https://a.example/x", Links.urlAt(e, 0, 10));
        assertNull(Links.urlAt(e, 0, 23));
    }

    @Test
    void onlyWebLinks() {
        assertNull(Links.urlAt(term(40, 1, "file:///etc/hosts ftp://x"), 0, 3));
        assertEquals("http://h:7393/#k=1", Links.urlAt(term(40, 1, "http://h:7393/#k=1"), 0, 0));
    }
}
