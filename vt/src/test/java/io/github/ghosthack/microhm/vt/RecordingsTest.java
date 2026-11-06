package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Random;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Real program output recorded with {@code vt/scripts/record.py} (see the file names for the
 * program and the terminal size): checked against golden state at checkpoints along the
 * stream (see {@link Golden}), run through the serializer round trip, and fed in random
 * chunks. When the goldens were frozen, jediterm-core agreed at every checkpoint except
 * where xterm and jediterm differ by design: grapheme widths in {@code unicode} (jediterm
 * gives every supplementary code point two cells and a cell to each uncomposed combining
 * mark) and the cursor in {@code curses} (xterm keeps one saved cursor per screen).
 */
class RecordingsTest {

    /** Compare after every this many bytes (a pty read's worth). */
    private static final int CHECKPOINT = 256;

    /** A recording and its size. */
    record Recording(String file, int columns, int rows) {
        @Override
        public String toString() {
            return file;
        }

        byte[] bytes() {
            try (InputStream in = RecordingsTest.class.getResourceAsStream("/recordings/" + file)) {
                return in.readAllBytes();
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }
    }

    static Stream<Recording> recordings() {
        return Stream.of("ls-color.80x24.bin", "ls-narrow.20x10.bin", "vim.80x24.bin", "less.80x24.bin",
                "man.80x24.bin", "git-log-graph.100x30.bin", "zsh.80x24.bin", "bash.80x24.bin",
                "unicode.40x16.bin", "curses.80x24.bin", "inline-viewport.80x24.bin").map(f -> {
                    String[] size = f.split("\\.")[1].split("x");
                    return new Recording(f, Integer.parseInt(size[0]), Integer.parseInt(size[1]));
                });
    }

    @ParameterizedTest
    @MethodSource("recordings")
    void serializerRoundTripsAlongTheStream(Recording r) {
        byte[] bytes = r.bytes();
        TerminalEmulator e = new TerminalEmulator(r.columns(), r.rows(), 1000);
        int step = Math.max(64, bytes.length / 20);
        for (int off = 0; off < bytes.length; off += step) {
            e.feed(bytes, off, Math.min(step, bytes.length - off));
            ModelAssert.roundTrip(e, 1000);
        }
    }

    @ParameterizedTest
    @MethodSource("recordings")
    void chunkingDoesNotMatter(Recording r) {
        byte[] bytes = r.bytes();
        TerminalEmulator whole = new TerminalEmulator(r.columns(), r.rows(), 1000);
        whole.feed(bytes);
        TerminalEmulator pieces = new TerminalEmulator(r.columns(), r.rows(), 1000);
        Random rnd = new Random(bytes.length);
        for (int off = 0; off < bytes.length; ) {
            int n = Math.min(1 + rnd.nextInt(17), bytes.length - off);
            pieces.feed(bytes, off, n);
            off += n;
        }
        assertArrayEquals(ScreenSerializer.serialize(whole, 1000), ScreenSerializer.serialize(pieces, 1000));
        assertEquals(whole.title(), pieces.title());
    }

    /** The state at every checkpoint, chained into a digest recorded at each one, then the
     * final state in full. */
    @ParameterizedTest
    @MethodSource("recordings")
    void matchesGolden(Recording r) {
        Subject s = new Subject(r.columns(), r.rows(), 1000);
        Snapshot.Chain chain = new Snapshot.Chain();
        StringBuilder out = new StringBuilder();
        byte[] bytes = r.bytes();
        for (int off = 0; off < bytes.length; off += CHECKPOINT) {
            int n = Math.min(CHECKPOINT, bytes.length - off);
            s.feed(java.util.Arrays.copyOfRange(bytes, off, off + n));
            chain.add(s.snapshot());
            out.append("byte ").append(off + n).append(' ').append(chain.value()).append('\n');
        }
        out.append(s.snapshot());
        Golden.check("recordings/" + r.file().replace(".bin", ".txt"), out.toString());
    }
}
