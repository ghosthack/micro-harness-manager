package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** {@link HeadlessTerminal}'s own surface: replies, stored cursor, cwd, close, threading. */
class HeadlessTerminalTest {

    private static List<VtToken> tokens(String s) {
        List<VtToken> out = new ArrayList<>();
        for (VtToken t : new VtTokenizer().feed(s.getBytes(StandardCharsets.UTF_8)).tokens()) {
            out.add(SgrNormalizer.normalize(t));
        }
        return out;
    }

    @Test
    void repliesGoToTheSessionAndTheColourSchemeQueryIsDropped() {
        List<String> replies = new ArrayList<>();
        HeadlessTerminal term = new HeadlessTerminal(20, 5, 0, b -> replies.add(new String(b, StandardCharsets.UTF_8)));
        term.apply(tokens("\u001b[c\u001b[?996n\u001b[2;3H\u001b[6n\u001b[8;50;200t"));
        assertEquals(List.of("\u001b[?62;22c", "\u001b[2;3R"), replies);
        assertEquals(20, term.columns());
        assertEquals(5, term.rows());
    }

    @Test
    void storedCursorAndCwd() {
        HeadlessTerminal term = new HeadlessTerminal(20, 5, 0, b -> {
        });
        assertNull(term.storedCursor());
        term.apply(tokens("\u001b[3;4H\u001b[1m\u001b7\u001b]7;file://host/tmp/a%20b\u0007"));
        HeadlessTerminal.StoredCursor stored = term.storedCursor();
        assertEquals(3, stored.cursorX());
        assertEquals(2, stored.cursorY());
        assertTrue(Style.bold(stored.style()));
        assertEquals("/tmp/a b", term.reportedCwd());
    }

    @Test
    void closedTerminalIgnoresInput() {
        HeadlessTerminal term = new HeadlessTerminal(20, 5, 0, b -> {
        });
        term.close();
        term.close();
        term.apply(tokens("text"));
        term.resize(30, 6);
        assertEquals("\n\n\n\n\n", term.screenText());
        assertEquals(20, term.columns());
    }

    @Test
    void gettersAreSafeWhileThePumpApplies() throws Exception {
        HeadlessTerminal term = new HeadlessTerminal(40, 10, 100, b -> {
        });
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread reader = new Thread(() -> {
            try {
                for (int i = 0; i < 2000; i++) {
                    String text = term.screenText();
                    assertTrue(text.endsWith("\n"));
                    term.annotatedText();
                    term.modes();
                    term.serialize(10);
                }
            } catch (Throwable t) {
                failure.set(t);
            }
        });
        reader.start();
        for (int i = 0; i < 2000; i++) {
            term.apply(tokens("\u001b[3" + (i % 8) + "mline " + i + " 中文\r\n"));
            if (i % 500 == 0) {
                term.resize(30 + i % 20, 8 + i % 5);
            }
        }
        reader.join();
        if (failure.get() != null) {
            throw new AssertionError(failure.get());
        }
    }
}
