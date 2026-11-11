package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The tokenizer contract ({@link VtTokenizer}). */
class VtTokenizerTest {

    private static byte[] bytes(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    /** All tokens completed by feeding {@code data} in one chunk. */
    private static List<VtToken> tokens(String data) {
        return new VtTokenizer().feed(bytes(data)).tokens();
    }

    @Test
    void curlyQuotesAndEmojiAreOneTextToken() {
        List<VtToken> t = tokens("“hi” 🛑"); // “hi” 🛑
        assertEquals(1, t.size());
        assertEquals(VtToken.Kind.TEXT, t.get(0).kind());
        assertEquals("“hi” 🛑", t.get(0).asString());
    }

    @Test
    void bytesAbove0x80AreNeverC1() {
        // 0x9B is the 8-bit CSI introducer; here it is the 2nd byte of U+201C and must stay text.
        byte[] in = bytes("“"); // E2 80 9C
        VtTokenizer.Batch b = new VtTokenizer().feed(in);
        assertEquals(1, b.tokens().size());
        assertEquals(VtToken.Kind.TEXT, b.tokens().get(0).kind());
        assertArrayEquals(in, b.tokens().get(0).bytes());
    }

    @Test
    void csiSplitAcrossReads() {
        VtTokenizer tok = new VtTokenizer();
        assertTrue(tok.feed(bytes("[")).tokens().isEmpty());
        assertTrue(tok.feed(bytes("31")).tokens().isEmpty());
        assertArrayEquals(bytes("[31"), tok.pending());
        VtTokenizer.Batch b = tok.feed(bytes("m"));
        assertEquals(1, b.tokens().size());
        VtToken t = b.tokens().get(0);
        assertEquals(VtToken.Kind.CSI, t.kind());
        assertEquals("31", t.csiBody());
        assertEquals('m', t.csiFinal());
    }

    @Test
    void loneEscThenCsiInNextRead() {
        VtTokenizer tok = new VtTokenizer();
        VtTokenizer.Batch first = tok.feed(bytes(""));
        assertTrue(first.tokens().isEmpty());
        assertArrayEquals(bytes(""), tok.pending());
        VtTokenizer.Batch second = tok.feed(bytes("[6n"));
        assertEquals(1, second.tokens().size());
        VtToken t = second.tokens().get(0);
        assertEquals(VtToken.Kind.CSI, t.kind());
        assertEquals("6", t.csiBody());
        assertEquals('n', t.csiFinal());
    }

    @Test
    void oscTerminatedByBel() {
        List<VtToken> t = tokens("]0;title");
        assertEquals(1, t.size());
        assertEquals(VtToken.Kind.OSC, t.get(0).kind());
        assertEquals("]0;title", t.get(0).asString());
    }

    @Test
    void oscTerminatedBySt() {
        List<VtToken> t = tokens("]0;title\\");
        assertEquals(1, t.size());
        assertEquals(VtToken.Kind.OSC, t.get(0).kind());
        assertEquals("]0;title\\", t.get(0).asString());
    }

    @Test
    void oscBodyIsForwardedBeforeTermination() {
        VtTokenizer tok = new VtTokenizer();
        VtTokenizer.Batch open = tok.feed(bytes("]0;par"));
        assertTrue(open.tokens().isEmpty());
        // The introducer + partial body were streamed immediately.
        assertEquals("]0;par", new String(open.openStringFragment(), StandardCharsets.UTF_8));
        assertArrayEquals(bytes("]0;par"), tok.openStringBytes());
        // pending() never reports a string body.
        assertEquals(0, tok.pending().length);

        VtTokenizer.Batch more = tok.feed(bytes("tial"));
        assertEquals("tial", new String(more.openStringFragment(), StandardCharsets.UTF_8));

        VtTokenizer.Batch done = tok.feed(bytes(""));
        assertEquals(1, done.tokens().size());
        VtToken t = done.tokens().get(0);
        assertEquals(VtToken.Kind.OSC, t.kind());
        assertEquals("]0;partial", t.asString());
        // Only the not-yet-streamed tail (the BEL terminator) is forwarded with the token.
        assertEquals("", new String(t.bytesToForward(), StandardCharsets.UTF_8));
        assertEquals(0, done.openStringFragment().length);
    }

    @Test
    void unterminatedOscThenHugeTextStreamsWithoutStalling() {
        VtTokenizer tok = new VtTokenizer();
        long forwarded = 0;
        forwarded += tok.feed(bytes("]1337;File=")).openStringFragment().length;
        // 100 KiB of "text" that is actually still OSC body (never terminated).
        byte[] big = new byte[100 * 1024];
        java.util.Arrays.fill(big, (byte) 'A');
        VtTokenizer.Batch b = tok.feed(big);
        forwarded += b.openStringFragment().length;
        // Nothing was held from clients: everything fed so far was forwarded as fragments.
        assertTrue(forwarded >= 100 * 1024);
        // Over the 64 KiB cap the body is given up, but the string is still open: what
        // follows is skipped (and streamed), not tokenized as text.
        assertArrayEquals(bytes("\u001bX"), tok.openStringBytes());
        VtTokenizer.Batch still = tok.feed(bytes("hi"));
        assertTrue(still.tokens().isEmpty());
        assertEquals("hi", new String(still.openStringFragment(), StandardCharsets.UTF_8));
        // The terminator ends it: its unstreamed bytes come as a DISCARDED token, in order.
        VtTokenizer.Batch after = tok.feed(bytes("x\u0007hi"));
        assertEquals(List.of(VtToken.Kind.DISCARDED, VtToken.Kind.TEXT),
                after.tokens().stream().map(VtToken::kind).toList());
        assertEquals("x\u0007", after.tokens().get(0).asString());
        assertEquals("hi", after.tokens().get(1).asString());
        assertEquals(0, tok.openStringBytes().length);
    }

    /** The tokens and forwarded bytes of {@code data} fed in pieces of {@code chunk} bytes. */
    private static String fedInChunks(byte[] data, int chunk, ByteArrayOutputStream forwarded) {
        VtTokenizer tok = new VtTokenizer();
        StringBuilder kinds = new StringBuilder();
        for (int off = 0; off < data.length; off += chunk) {
            VtTokenizer.Batch b = tok.feed(data, off, Math.min(chunk, data.length - off));
            for (VtToken t : b.tokens()) {
                // Text may be split differently; what matters is which sequences are seen.
                if (t.kind() != VtToken.Kind.TEXT && t.kind() != VtToken.Kind.DISCARDED) {
                    kinds.append(t.kind()).append(t.bytes().length).append(' ');
                } else if (t.kind() == VtToken.Kind.TEXT) {
                    kinds.append(t.asString());
                }
                forwarded.writeBytes(t.bytesToForward());
            }
            forwarded.writeBytes(b.openStringFragment());
        }
        return kinds.toString();
    }

    @Test
    void anOverlongStringIsSkippedTheSameHoweverItIsChunked() {
        for (String terminator : List.of("\u0007", "\u001b\\")) {
            ByteArrayOutputStream in = new ByteArrayOutputStream();
            in.writeBytes(bytes("a\u001bPq"));
            byte[] body = new byte[70_000];
            java.util.Arrays.fill(body, (byte) '~');
            body[69_000] = 0x1B; // an ESC in the body that is not a terminator
            in.writeBytes(body);
            in.writeBytes(bytes(terminator + "b\u001b[1mc"));
            byte[] data = in.toByteArray();
            String expected = "ab" + VtToken.Kind.CSI + "4 c";
            for (int chunk : new int[]{data.length, 1, 7, 4096, VtTokenizer.MAX_STRING_LENGTH}) {
                ByteArrayOutputStream forwarded = new ByteArrayOutputStream();
                assertEquals(expected, fedInChunks(data, chunk, forwarded), "chunk " + chunk);
                // Clients get every byte, in order: their tokenizers skip the same string.
                assertArrayEquals(data, forwarded.toByteArray(), "chunk " + chunk);
            }
        }
    }

    @Test
    void aStringAtTheCapIsStillAToken() {
        byte[] data = new byte[VtTokenizer.MAX_STRING_LENGTH + 1];
        java.util.Arrays.fill(data, (byte) 'x');
        data[0] = 0x1B;
        data[1] = ']';
        data[data.length - 1] = 0x07; // the terminator is the byte past the cap
        for (int chunk : new int[]{data.length, 1000}) {
            assertEquals(VtToken.Kind.OSC + "" + data.length + " ", fedInChunks(data, chunk, new ByteArrayOutputStream()));
        }
    }

    @Test
    void attachingDuringASkippedStringGetsAnIntroducerThatSkipsTheRest() {
        VtTokenizer tok = new VtTokenizer();
        byte[] big = new byte[70_000];
        java.util.Arrays.fill(big, (byte) 'A');
        tok.feed(bytes("\u001b]52;c;"));
        tok.feed(big);
        tok.feed(bytes("\u001b")); // half of the ESC \ terminator
        VtTokenizer client = new VtTokenizer();
        assertTrue(client.feed(tok.openStringBytes()).tokens().isEmpty());
        List<VtToken> rest = client.feed(bytes("\\ok")).tokens();
        assertEquals("ok", rest.getLast().asString());
        assertEquals(VtToken.Kind.TEXT, rest.getLast().kind());
        assertEquals(2, rest.size());
    }

    @Test
    void endOfStreamInASkippedStringFlushesWhatWasNotStreamed() {
        VtTokenizer tok = new VtTokenizer();
        byte[] big = new byte[70_000];
        java.util.Arrays.fill(big, (byte) 'A');
        big[0] = 0x1B;
        big[1] = 'P';
        assertEquals(70_000, tok.feed(big).openStringFragment().length);
        assertTrue(tok.flush().tokens().isEmpty());
        assertEquals("z", tok.feed(bytes("z")).tokens().getFirst().asString());
    }

    @Test
    void dcsWithEmbeddedEscEscBracketStaysIntact() {
        // ESC P ... ESC ESC [ ... ESC \  — the inner "ESC ESC [" is tmux-style passthrough.
        String dcs = "Pq[2;3m data \\";
        List<VtToken> t = tokens(dcs);
        assertEquals(1, t.size());
        assertEquals(VtToken.Kind.STRING, t.get(0).kind());
        assertEquals(dcs, t.get(0).asString());
    }

    @Test
    void utf8CodePointSplitAcrossReads() {
        byte[] emoji = bytes("🛑"); // 🛑 = F0 9F 9B 91
        VtTokenizer tok = new VtTokenizer();
        VtTokenizer.Batch first = tok.feed(emoji, 0, 2); // F0 9F
        assertTrue(first.tokens().isEmpty());
        assertArrayEquals(new byte[]{emoji[0], emoji[1]}, tok.pending());
        VtTokenizer.Batch second = tok.feed(emoji, 2, 2); // 9B 91
        assertEquals(1, second.tokens().size());
        assertArrayEquals(emoji, second.tokens().get(0).bytes());
        assertEquals("🛑", second.tokens().get(0).asString());
    }

    @Test
    void overlongCsiWithoutFinalIsFlushedAsText() {
        StringBuilder sb = new StringBuilder("[");
        sb.append("1;".repeat(40)); // > 64 bytes, still no final byte
        List<VtToken> t = tokens(sb.toString());
        assertFalse(t.isEmpty());
        assertEquals(VtToken.Kind.TEXT, t.get(0).kind());
        // The bytes are preserved (nothing is lost when the cap trips).
        assertArrayEquals(bytes(sb.toString()), concat(t));
    }

    @Test
    void c0ControlsAreTheirOwnTokensEvenMidText() {
        List<VtToken> t = tokens("abcd");
        assertEquals(3, t.size());
        assertEquals(VtToken.Kind.TEXT, t.get(0).kind());
        assertEquals("ab", t.get(0).asString());
        assertEquals(VtToken.Kind.CONTROL, t.get(1).kind());
        assertArrayEquals(new byte[]{0x07}, t.get(1).bytes());
        assertEquals("cd", t.get(2).asString());
    }

    @Test
    void reassemblyIsByteExactAcrossChunkSizes() {
        String input = "plain [1;31mred[m “q” 🛑 "
                + "]0;t Px\\ done[6n";
        byte[] in = bytes(input);
        for (int chunk = 1; chunk <= in.length; chunk++) {
            VtTokenizer tok = new VtTokenizer();
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            for (int off = 0; off < in.length; off += chunk) {
                VtTokenizer.Batch b = tok.feed(in, off, Math.min(chunk, in.length - off));
                for (VtToken t : b.tokens()) {
                    byte[] f = t.bytesToForward();
                    out.write(f, 0, f.length);
                }
                out.write(b.openStringFragment(), 0, b.openStringFragment().length);
            }
            // The input ends on a complete CSI, so nothing is held back.
            assertArrayEquals(in, out.toByteArray(), "chunk size " + chunk);
        }
    }

    private static byte[] concat(List<VtToken> tokens) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (VtToken t : tokens) {
            out.write(t.bytes(), 0, t.bytes().length);
        }
        return out.toByteArray();
    }
}
