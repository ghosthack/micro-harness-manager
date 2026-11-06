package io.github.ghosthack.microhm.app.terminal;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;

class PasteEncoderTest {

    private static String paste(String text, boolean bracketed) {
        return new String(PasteEncoder.encode(text, bracketed), StandardCharsets.UTF_8);
    }

    @Test
    void lineBreaksBecomeCarriageReturns() {
        assertEquals("a\rb\rc\r", paste("a\r\nb\nc\r", false));
        assertEquals("a\r\rb", paste("a\n\nb", false));
    }

    @Test
    void unbracketedKeepsTextAsIs() {
        assertEquals("x\u001b[201~y", paste("x\u001b[201~y", false));
        assertEquals("héllo ✓", paste("héllo ✓", false));
    }

    @Test
    void bracketedWrapsAndStripsEscapes() {
        assertEquals("\u001b[200~one\rtwo\u001b[201~", paste("one\ntwo", true));
        assertEquals("\u001b[200~xy\u001b[201~", paste("x\u001b[201~y", true));
        assertEquals("\u001b[200~ab[31mc\u001b[201~", paste("a\u001bb\u001b[31mc", true));
        // removing one end marker must not leave another behind
        assertEquals("\u001b[200~\u001b[201~", paste("\u001b[20\u001b[201~1~", true));
        assertEquals("\u001b[200~ab\u001b[201~", paste("a\u009bb", true));
    }
}
