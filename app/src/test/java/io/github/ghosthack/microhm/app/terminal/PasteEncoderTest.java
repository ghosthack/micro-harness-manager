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

    @Test
    void droppedPosixPathsStayBareWhenSafeAndAreSingleQuotedOtherwise() {
        assertEquals("/Users/me/a.png ", PasteEncoder.droppedPaths(java.util.List.of("/Users/me/a.png"), false));
        assertEquals("'/tmp/My File.txt' '/tmp/it'\\''s' ",
                PasteEncoder.droppedPaths(java.util.List.of("/tmp/My File.txt", "/tmp/it's"), false));
        assertEquals("'/tmp/$(rm -rf ~)' ", PasteEncoder.droppedPaths(java.util.List.of("/tmp/$(rm -rf ~)"), false));
        assertEquals("", PasteEncoder.droppedPaths(java.util.List.of(), false));
    }

    @Test
    void droppedWindowsPathsAreDoubleQuotedWhenTheyNeedIt() {
        assertEquals("C:\\work\\a.png ", PasteEncoder.droppedPaths(java.util.List.of("C:\\work\\a.png"), true));
        assertEquals("\"C:\\My Files\\a b.txt\" ",
                PasteEncoder.droppedPaths(java.util.List.of("C:\\My Files\\a b.txt"), true));
    }

    @Test
    void aDroppedFileListTypesItsPathsAndDroppedTextPastesAsIs() {
        java.awt.datatransfer.Transferable files = new java.awt.datatransfer.Transferable() {
            public java.awt.datatransfer.DataFlavor[] getTransferDataFlavors() {
                return new java.awt.datatransfer.DataFlavor[]{java.awt.datatransfer.DataFlavor.javaFileListFlavor};
            }
            public boolean isDataFlavorSupported(java.awt.datatransfer.DataFlavor flavor) {
                return flavor.equals(java.awt.datatransfer.DataFlavor.javaFileListFlavor);
            }
            public Object getTransferData(java.awt.datatransfer.DataFlavor flavor) {
                return java.util.List.of(new java.io.File("/tmp/shot 1.png"));
            }
        };
        String expected = System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT).startsWith("windows")
                ? null : "'/tmp/shot 1.png' ";
        if (expected != null) {
            assertEquals(expected, TerminalView.droppedText(files));
        }
        assertEquals("hello", TerminalView.droppedText(new java.awt.datatransfer.StringSelection("hello")));
    }
}
