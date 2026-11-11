package io.github.ghosthack.microhm.vt;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Boundary-preserving splitter for a terminal output byte stream. Feed arbitrary chunks; get back the complete tokens they finish,
 * in order, plus the fragment of any string body still open — so clients can be streamed
 * immediately while the emulator only ever sees complete sequences.
 *
 * <p>Invariants:
 * <ul>
 *   <li>Every byte ≥ 0x80 is text. No 8-bit C1 recognition.</li>
 *   <li>Sequences start only with ESC. {@code ESC [} → CSI (parameters 0x30–0x3F,
 *       intermediates 0x20–0x2F, final 0x40–0x7E); {@code ESC ]} → OSC; {@code ESC P},
 *       {@code ESC _}, {@code ESC ^}, {@code ESC X} → STRING; both terminated by BEL or
 *       {@code ESC \} (an ESC inside a body not followed by {@code \} stays in the body);
 *       {@code ESC} + intermediate(s) 0x20–0x2F + final 0x30–0x7E, or {@code ESC} + one
 *       final 0x30–0x7E → ESCAPE. An ESC followed by a byte that fits none of those (CAN,
 *       SUB, a C0, another ESC) ends the aborted sequence as an ESCAPE token and the new
 *       byte is processed fresh.</li>
 *   <li>A C0 control other than ESC (and DEL) is its own CONTROL token, even mid-text.</li>
 *   <li>Held back until complete: a lone trailing ESC, a partial CSI, a partial ESC-
 *       intermediate sequence, a partial UTF-8 code point. A CSI longer than 64 bytes
 *       without a final byte is flushed as TEXT and the parser resets.</li>
 *   <li>String bodies are <em>not</em> held back from clients: the bytes of an open
 *       OSC/STRING that arrived in this chunk are returned as {@link Batch#openStringFragment}
 *       to be broadcast now; when the terminator arrives the whole token is returned with
 *       {@link VtToken#alreadyForwarded()} set to the number of bytes already streamed.
 *       A string that outgrows 64 KiB is never returned as an OSC/STRING token: from that
 *       byte on (the same byte however the input is chunked) the body is skipped up to its
 *       terminator, still streamed to clients as fragments, the last piece as a
 *       {@link VtToken.Kind#DISCARDED} token. The parser does not go back to text
 *       mid-body, which would print the rest of a large image or clipboard payload.</li>
 *   <li>Concatenating, for each batch, every token's {@code bytesToForward()} followed by
 *       {@code openStringFragment}, reproduces the input byte-for-byte, minus tokens the
 *       caller chooses to drop and minus any still-held partial CSI/ESC/UTF-8 tail.</li>
 * </ul>
 */
public final class VtTokenizer {

    public static final int MAX_CSI_LENGTH = 64;
    public static final int MAX_STRING_LENGTH = 64 * 1024;

    private static final int ESC = 0x1B;
    private static final int BEL = 0x07;

    private enum State {
        /** Between tokens; {@link #text} may hold a run of printable bytes. */
        GROUND,
        /** Saw ESC; deciding what kind of sequence follows. {@link #seq} = {ESC}. */
        AFTER_ESC,
        /** In a CSI ({@code ESC [ ...}); {@link #seq} accumulates through the final byte. */
        IN_CSI,
        /** In an {@code ESC} + intermediate(s) sequence; {@link #seq} accumulates. */
        IN_ESC_INTER,
        /** In an OSC/DCS/APC/PM/SOS body; {@link #stringBuf} accumulates (already forwarded). */
        IN_STRING,
        /** In a string that outgrew {@link #MAX_STRING_LENGTH}, skipping to its terminator;
         * {@link #stringBuf} holds only the bytes not yet forwarded. */
        DISCARD_STRING,
    }

    /** What one {@link #feed} produced: the tokens completed by the chunk, in order, and
     * the bytes of a still-open string body that arrived in this chunk (after the last
     * token; empty when no string is open). */
    public record Batch(List<VtToken> tokens, byte[] openStringFragment) {
    }

    /**
     * Receives tokens as they complete, without a {@link VtToken} or a copy per token: the
     * client emulator's path. {@code b[off, off + len)} holds the token's exact bytes and is
     * valid only during the call (it is the caller's chunk or the tokenizer's own buffer).
     * A CONTROL token is its one byte.
     */
    @FunctionalInterface
    public interface Sink {
        void token(VtToken.Kind kind, byte[] b, int off, int len);
    }

    private static final byte[] EMPTY = new byte[0];

    private State state = State.GROUND;

    /** One shared token per C0 control and DEL: they carry no state, and token bytes are
     * never written to, so a CR or LF costs no allocation. */
    private static final VtToken[] CONTROLS = new VtToken[0x80];

    static {
        for (int c = 0; c < 0x20; c++) {
            CONTROLS[c] = new VtToken(VtToken.Kind.CONTROL, new byte[]{(byte) c});
        }
        CONTROLS[0x7F] = new VtToken(VtToken.Kind.CONTROL, new byte[]{0x7F});
    }

    /** Printable bytes accumulated in GROUND, flushed as a TEXT token at the next boundary. */
    private final Bytes text = new Bytes(256);
    /** The bytes of the escape/CSI sequence being parsed (starts with ESC). */
    private final Bytes seq = new Bytes(MAX_CSI_LENGTH + 1);
    /** The bytes of the open string (introducer included). */
    private final Bytes stringBuf = new Bytes(256);
    /** OSC vs generic STRING, decided by the introducer byte. */
    private boolean stringIsOsc;
    /** Bytes of {@link #stringBuf} already returned to clients via openStringFragment. */
    private int stringForwarded;
    /** True when the previous string byte was ESC (a potential {@code ESC \} terminator). */
    private boolean stringSawEsc;

    public Batch feed(byte[] chunk, int off, int len) {
        Collector out = new Collector();
        run(chunk, off, len, out);
        return new Batch(out.tokens, endOfFeed(true));
    }

    /**
     * Feeds a chunk, handing each completed token to {@code sink} in order. Same parsing as
     * {@link #feed(byte[], int, int)}, but nothing is collected or copied, and no open-string
     * fragment is computed (a client has no one to forward it to).
     */
    public void feed(byte[] chunk, int off, int len, Sink sink) {
        run(chunk, off, len, sink);
        endOfFeed(false);
    }

    private void run(byte[] chunk, int off, int len, Sink out) {
        int end = off + len;
        for (int i = off; i < end; i++) {
            int b = chunk[i] & 0xFF;
            switch (state) {
                case GROUND -> {
                    if (b == ESC) {
                        flushText(out);
                        seq.reset();
                        seq.write(ESC);
                        state = State.AFTER_ESC;
                    } else if (b < 0x20 || b == 0x7F) {
                        // C0 control (other than ESC, handled above) or DEL: its own token.
                        flushText(out);
                        out.token(VtToken.Kind.CONTROL, chunk, i, 1);
                    } else {
                        // A run of printable bytes (every byte >= 0x80 is text). It ends at a
                        // boundary or at the end of the chunk, where the text is flushed
                        // anyway, so flush it now: straight from the chunk when nothing is
                        // held (the usual case), holding back an incomplete UTF-8 tail.
                        int runEnd = i + 1;
                        while (runEnd < end && isPrintable(chunk[runEnd])) {
                            runEnd++;
                        }
                        if (text.size() == 0) {
                            int tail = incompleteUtf8TailLength(chunk, i, runEnd);
                            if (runEnd - tail > i) {
                                out.token(VtToken.Kind.TEXT, chunk, i, runEnd - tail - i);
                            }
                            if (tail > 0) {
                                text.write(chunk, runEnd - tail, tail);
                            }
                        } else {
                            text.write(chunk, i, runEnd - i);
                            flushText(out);
                        }
                        i = runEnd - 1;
                    }
                }
                case AFTER_ESC -> {
                    if (b == '[') {
                        seq.write(b);
                        state = State.IN_CSI;
                    } else if (b == ']' || b == 'P' || b == '_' || b == '^' || b == 'X') {
                        // OSC (]) / DCS (P) / APC (_) / PM (^) / SOS (X).
                        stringBuf.reset();
                        stringBuf.write(ESC);
                        stringBuf.write(b);
                        stringIsOsc = (b == ']');
                        stringForwarded = 0;
                        stringSawEsc = false;
                        state = State.IN_STRING;
                    } else if (b >= 0x20 && b <= 0x2F) {
                        seq.write(b);
                        state = State.IN_ESC_INTER;
                    } else if (b >= 0x30 && b <= 0x7E) {
                        seq.write(b);
                        out.token(VtToken.Kind.ESCAPE, seq.array(), 0, seq.size());
                        state = State.GROUND;
                    } else {
                        // Aborted: emit the lone ESC as ESCAPE and reprocess this byte fresh.
                        out.token(VtToken.Kind.ESCAPE, seq.array(), 0, seq.size());
                        state = State.GROUND;
                        i--; // reprocess b in GROUND
                    }
                }
                case IN_CSI -> {
                    if (b >= 0x40 && b <= 0x7E) {
                        seq.write(b);
                        out.token(VtToken.Kind.CSI, seq.array(), 0, seq.size());
                        state = State.GROUND;
                    } else if (seq.size() >= MAX_CSI_LENGTH) {
                        // Overlong CSI without a final byte: flush as TEXT, reprocess b fresh.
                        appendSeqAsText();
                        state = State.GROUND;
                        i--;
                    } else if (b >= 0x20 && b <= 0x3F) {
                        seq.write(b); // parameter (0x30-0x3F) or intermediate (0x20-0x2F)
                    } else {
                        // Unexpected byte inside CSI: abort to TEXT, reprocess b fresh.
                        appendSeqAsText();
                        state = State.GROUND;
                        i--;
                    }
                }
                case IN_ESC_INTER -> {
                    if (b >= 0x20 && b <= 0x2F) {
                        seq.write(b); // another intermediate
                    } else if (b >= 0x30 && b <= 0x7E) {
                        seq.write(b);
                        out.token(VtToken.Kind.ESCAPE, seq.array(), 0, seq.size());
                        state = State.GROUND;
                    } else {
                        // Aborted intermediate sequence: emit what we have, reprocess b fresh.
                        out.token(VtToken.Kind.ESCAPE, seq.array(), 0, seq.size());
                        state = State.GROUND;
                        i--;
                    }
                }
                case IN_STRING -> {
                    stringBuf.write(b);
                    if (b == BEL) {
                        emitString(out);
                        state = State.GROUND;
                    } else if (stringSawEsc) {
                        stringSawEsc = false;
                        if (b == '\\') { // ESC \ = ST terminator
                            emitString(out);
                            state = State.GROUND;
                        } else if (b == ESC) {
                            stringSawEsc = true; // the previous ESC stays in the body
                        }
                    } else if (b == ESC) {
                        stringSawEsc = true;
                    }
                    if (state == State.IN_STRING && stringBuf.size() > MAX_STRING_LENGTH) {
                        // Checked per byte, so where the body is given up does not depend on
                        // how the input was chunked: daemon and clients agree.
                        stringBuf.keepTail(stringBuf.size() - stringForwarded);
                        stringForwarded = 0;
                        state = State.DISCARD_STRING;
                    }
                }
                case DISCARD_STRING -> {
                    // The same terminators as IN_STRING: a client that attached mid-string
                    // is still in that state, and must leave the string on the same byte.
                    stringBuf.write(b);
                    boolean terminated = b == BEL || (stringSawEsc && b == '\\');
                    stringSawEsc = b == ESC;
                    if (terminated) {
                        emitDiscarded(out);
                        state = State.GROUND;
                    }
                }
            }
        }

        if (state == State.GROUND) {
            // Emit the completed text of this feed, holding back an incomplete UTF-8 tail.
            flushText(out);
        }
    }

    /** After a chunk: the bytes of a still-open string that arrived in it (when
     * {@code wantFragment}), and the reset of an overlong one. */
    private byte[] endOfFeed(boolean wantFragment) {
        byte[] fragment = EMPTY;
        if (state == State.IN_STRING || state == State.DISCARD_STRING) {
            int size = stringBuf.size();
            if (wantFragment && size > stringForwarded) {
                fragment = stringBuf.copy(stringForwarded, size);
            }
            stringForwarded = size;
            if (state == State.DISCARD_STRING) {
                // Nothing will ask for these bytes again: keep the buffer at one chunk.
                stringBuf.reset();
                stringForwarded = 0;
            }
        }
        return fragment;
    }

    public Batch feed(byte[] chunk) {
        return feed(chunk, 0, chunk.length);
    }

    /** The whole body of the currently open OSC/STRING (introducer included), or empty:
     * attach sends this to a new client after the snapshot so it gets the sequence the
     * other clients are mid-way through. */
    public byte[] openStringBytes() {
        if (state == State.DISCARD_STRING) {
            // The body is gone; an SOS introducer makes the new client skip the rest of it
            // as a string too (plus the ESC that may be half of the terminator).
            return stringSawEsc ? new byte[]{ESC, 'X', ESC} : new byte[]{ESC, 'X'};
        }
        return state == State.IN_STRING ? stringBuf.toByteArray() : EMPTY;
    }

    /** Bytes held back as an incomplete ESC/CSI/UTF-8 tail (never a string body); empty
     * at a boundary. For diagnostics and {@link #flush}. */
    public byte[] pending() {
        return switch (state) {
            case AFTER_ESC, IN_CSI, IN_ESC_INTER -> seq.toByteArray();
            case GROUND -> incompleteUtf8Tail();
            case IN_STRING, DISCARD_STRING -> EMPTY;
        };
    }

    /** End of stream: emits the held tail as ESCAPE/TEXT and any open string body as a
     * STRING/OSC token (with {@code alreadyForwarded} set), resetting the parser. */
    public Batch flush() {
        Collector out = new Collector();
        switch (state) {
            case GROUND -> flushText(out);
            case AFTER_ESC, IN_ESC_INTER -> out.token(VtToken.Kind.ESCAPE, seq.array(), 0, seq.size());
            case IN_CSI -> out.token(VtToken.Kind.TEXT, seq.array(), 0, seq.size());
            case IN_STRING -> emitString(out);
            case DISCARD_STRING -> emitDiscarded(out);
        }
        state = State.GROUND;
        text.reset();
        seq.reset();
        stringBuf.reset();
        stringForwarded = 0;
        stringSawEsc = false;
        return new Batch(out.tokens, EMPTY);
    }

    /** Flush {@link #text} as one or more TEXT tokens, holding back an incomplete trailing
     * UTF-8 code point for the next feed. */
    private void flushText(Sink out) {
        int size = text.size();
        if (size == 0) {
            return;
        }
        int tail = incompleteUtf8TailLength(text.array(), size);
        if (size - tail > 0) {
            out.token(VtToken.Kind.TEXT, text.array(), 0, size - tail);
        }
        // Re-hold an incomplete code point at the front so the next feed can complete it.
        text.keepTail(tail);
    }

    private void appendSeqAsText() {
        // Prepend the aborted sequence to any pending text so byte order is preserved.
        text.prepend(seq.array(), seq.size());
    }

    private void emitString(Sink out) {
        VtToken.Kind kind = stringIsOsc ? VtToken.Kind.OSC : VtToken.Kind.STRING;
        out.token(kind, stringBuf.array(), 0, stringBuf.size()); // the Collector reads stringForwarded
        stringBuf.reset();
        stringForwarded = 0;
        stringSawEsc = false;
    }

    /** The end of a skipped string: its bytes not yet streamed go out as a DISCARDED token,
     * in order before whatever follows. A {@link #feed(byte[], int, int, Sink) sink} has no
     * one to forward to and gets nothing. */
    private void emitDiscarded(Sink out) {
        if (out instanceof Collector && stringBuf.size() > stringForwarded) {
            out.token(VtToken.Kind.DISCARDED, stringBuf.array(), stringForwarded, stringBuf.size() - stringForwarded);
        }
        stringBuf.reset();
        stringForwarded = 0;
        stringSawEsc = false;
    }

    /** The trailing bytes of {@link #text} that form an incomplete (completable) UTF-8
     * code point, as a fresh array; empty when the buffer ends on a boundary. */
    private byte[] incompleteUtf8Tail() {
        int size = text.size();
        int tail = incompleteUtf8TailLength(text.array(), size);
        return tail == 0 ? EMPTY : text.copy(size - tail, size);
    }

    /** Text in GROUND: anything but a C0 control, ESC or DEL (bytes >= 0x80 included). */
    private static boolean isPrintable(byte b) {
        return b < 0 || (b >= 0x20 && b != 0x7F);
    }

    /**
     * Number of trailing bytes of {@code b[0..len)} that form an incomplete but still
     * completable UTF-8 sequence (a lead byte with fewer continuation bytes than it needs).
     * Stray continuation bytes with no lead, and already-complete sequences, are not held.
     */
    static int incompleteUtf8TailLength(byte[] b, int len) {
        return incompleteUtf8TailLength(b, 0, len);
    }

    /** {@link #incompleteUtf8TailLength(byte[], int)} over {@code b[from, to)}. */
    static int incompleteUtf8TailLength(byte[] b, int from, int to) {
        int i = to - 1;
        int cont = 0;
        while (i >= from && (b[i] & 0xC0) == 0x80 && cont < 3) {
            i--;
            cont++;
        }
        if (i < from) {
            return 0; // only continuation bytes in view: not completable
        }
        int lead = b[i] & 0xFF;
        int need;
        if (lead < 0x80) {
            return 0; // ASCII lead, the trailing continuations are stray
        } else if ((lead & 0xE0) == 0xC0) {
            need = 1;
        } else if ((lead & 0xF0) == 0xE0) {
            need = 2;
        } else if ((lead & 0xF8) == 0xF0) {
            need = 3;
        } else {
            return 0; // stray continuation acting as lead, or invalid 0xF8+ byte
        }
        if (cont >= need) {
            return 0; // complete (or overlong) sequence: nothing to hold
        }
        return cont + 1; // lead byte plus the continuations seen so far
    }

    /** The {@link Batch} path: each token as a {@link VtToken} with its own bytes. */
    private final class Collector implements Sink {
        final List<VtToken> tokens = new ArrayList<>();

        @Override
        public void token(VtToken.Kind kind, byte[] b, int off, int len) {
            tokens.add(switch (kind) {
                case CONTROL -> CONTROLS[b[off] & 0xFF];
                case OSC, STRING -> new VtToken(kind, Arrays.copyOfRange(b, off, off + len), stringForwarded);
                default -> new VtToken(kind, Arrays.copyOfRange(b, off, off + len));
            });
        }
    }

    /** A growable byte buffer without {@link java.io.ByteArrayOutputStream}'s locking:
     * the tokenizer is single-threaded and writes to these on every byte. */
    private static final class Bytes {
        private byte[] buf;
        private int size;

        Bytes(int capacity) {
            buf = new byte[capacity];
        }

        int size() {
            return size;
        }

        /** The backing array; only {@code [0, size())} is meaningful. */
        byte[] array() {
            return buf;
        }

        void reset() {
            size = 0;
        }

        void write(int b) {
            if (size == buf.length) {
                grow(size + 1);
            }
            buf[size++] = (byte) b;
        }

        void write(byte[] src, int off, int len) {
            if (size + len > buf.length) {
                grow(size + len);
            }
            System.arraycopy(src, off, buf, size, len);
            size += len;
        }

        /** Inserts {@code src[0, len)} before the current contents. */
        void prepend(byte[] src, int len) {
            if (size + len > buf.length) {
                grow(size + len);
            }
            System.arraycopy(buf, 0, buf, len, size);
            System.arraycopy(src, 0, buf, 0, len);
            size += len;
        }

        /** Keeps only the last {@code tail} bytes, moved to the front. */
        void keepTail(int tail) {
            System.arraycopy(buf, size - tail, buf, 0, tail);
            size = tail;
        }

        byte[] copy(int from, int to) {
            return Arrays.copyOfRange(buf, from, to);
        }

        byte[] toByteArray() {
            return Arrays.copyOf(buf, size);
        }

        private void grow(int min) {
            buf = Arrays.copyOf(buf, Math.max(min, buf.length * 2));
        }
    }
}
