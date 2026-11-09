package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.List;
import java.util.stream.LongStream;

import static org.junit.jupiter.api.Assertions.fail;

/**
 * Seeded random streams from {@link VtFuzz}: (1) in its common mode, the state after every
 * operation against a golden digest chain (see {@link Golden}: frozen from a commit where
 * jediterm-core agreed after every operation); (2) the serializer round trip, unrestricted,
 * every few operations.
 */
class FuzzTest {

    private static final int OPS = 1500;

    static LongStream seeds() {
        return LongStream.rangeClosed(1, 40);
    }

    private static int[] size(long seed) {
        int[][] sizes = {{80, 24}, {20, 8}, {13, 5}, {40, 12}, {132, 6}};
        return sizes[(int) (seed % sizes.length)];
    }

    @ParameterizedTest
    @MethodSource("seeds")
    void serializerRoundTrips(long seed) {
        int[] size = size(seed);
        TerminalEmulator e = new TerminalEmulator(size[0], size[1], 100);
        VtFuzz fuzz = new VtFuzz(seed, e, VtFuzz.Mode.ANY);
        Deque<String> recent = new ArrayDeque<>();
        for (int i = 0; i < OPS; i++) {
            String op = fuzz.next();
            remember(recent, op);
            e.feed(op.getBytes(StandardCharsets.UTF_8));
            if (i % 25 == 24) {
                try {
                    ModelAssert.roundTrip(e, 100);
                } catch (AssertionError err) {
                    fail("seed " + seed + " op " + i + " after:\n"
                            + String.join("\n", recent.stream().map(FuzzTest::visible).toList()) + "\n" + err.getMessage());
                }
            }
        }
    }

    /** {@link TerminalEmulator#feed} and {@link TerminalEmulator#apply} of the same
     * tokens agree on unrestricted random streams, fed in random pieces (ops split mid
     * sequence and mid character). */
    @ParameterizedTest
    @MethodSource("seeds")
    void feedingMatchesApplyingTokens(long seed) {
        int[] size = size(seed);
        TerminalEmulator fed = new TerminalEmulator(size[0], size[1], 100);
        TerminalEmulator applied = new TerminalEmulator(size[0], size[1], 100);
        VtTokenizer tokenizer = new VtTokenizer();
        VtFuzz fuzz = new VtFuzz(seed, fed, VtFuzz.Mode.ANY);
        java.util.Random rnd = new java.util.Random(seed);
        java.io.ByteArrayOutputStream stream = new java.io.ByteArrayOutputStream();
        for (int i = 0; i < OPS; i++) {
            stream.writeBytes(fuzz.next().getBytes(StandardCharsets.UTF_8));
        }
        byte[] bytes = stream.toByteArray();
        for (int off = 0; off < bytes.length; ) {
            int n = Math.min(1 + rnd.nextInt(40), bytes.length - off);
            fed.feed(bytes, off, n);
            applied.apply(tokenizer.feed(bytes, off, n).tokens());
            off += n;
        }
        ModelAssert.assertSameState(fed, applied, 100);
    }

    private static void remember(Deque<String> recent, String op) {
        recent.addLast(op);
        if (recent.size() > 12) {
            recent.removeFirst();
        }
    }

    static String visible(String s) {
        return s.replace("\u001b", "ESC").replace("\r", "\\r").replace("\n", "\\n").replace("\u0007", "BEL")
                .replace("\b", "\\b").replace("\t", "\\t");
    }

    /** The state after every operation, chained into a digest recorded every 100 operations,
     * then the final state in full. */
    @ParameterizedTest
    @MethodSource("seeds")
    void matchesGolden(long seed) {
        int[] size = size(seed);
        Subject s = new Subject(size[0], size[1], 200);
        VtFuzz fuzz = new VtFuzz(seed, s.emulator(), VtFuzz.Mode.COMMON);
        Snapshot.Chain chain = new Snapshot.Chain();
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < OPS; i++) {
            s.feed(fuzz.next());
            chain.add(s.snapshot());
            if (i % 100 == 99) {
                out.append("after op ").append(i + 1).append(' ').append(chain.value()).append('\n');
            }
        }
        out.append(s.snapshot());
        Golden.check(String.format("fuzz/seed-%02d.txt", seed), out.toString());
    }
}
