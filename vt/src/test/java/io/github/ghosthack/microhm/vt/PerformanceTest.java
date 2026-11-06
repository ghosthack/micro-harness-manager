package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Random;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Throughput: 20 MB of mixed text and SGR (with some wide characters and cursor work),
 * fed in pty-sized chunks through the daemon path (tokenizer, normaliser, emulator). */
class PerformanceTest {

    private static final int SIZE = 20 * 1024 * 1024;

    @Test
    @Timeout(value = 30, unit = TimeUnit.SECONDS)
    void twentyMegabytesOfMixedOutput() {
        byte[] data = stream();
        HeadlessTerminal term = new HeadlessTerminal(160, 50, 10_000, b -> {
        });
        VtTokenizer tokenizer = new VtTokenizer();
        long start = System.nanoTime();
        for (int off = 0; off < data.length; off += 65536) {
            VtTokenizer.Batch batch = tokenizer.feed(data, off, Math.min(65536, data.length - off));
            term.apply(batch.tokens().stream().map(SgrNormalizer::normalize).toList());
        }
        long millis = (System.nanoTime() - start) / 1_000_000;
        System.out.printf("PerformanceTest: %d MB in %d ms (%.0f MB/s)%n", data.length >> 20, millis,
                data.length / 1048576.0 / Math.max(1, millis) * 1000);
        assertTrue(millis < 10_000, "took " + millis + " ms");
        assertTrue(term.emulator().historySize() > 0);
    }

    private static byte[] stream() {
        Random rnd = new Random(7);
        ByteArrayOutputStream out = new ByteArrayOutputStream(SIZE + 1024);
        String[] words = {"lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed",
                "do", "eiusmod", "tempor", "中文", "café", "───", "x"};
        StringBuilder line = new StringBuilder();
        while (out.size() < SIZE) {
            line.setLength(0);
            int n = 5 + rnd.nextInt(15);
            for (int i = 0; i < n; i++) {
                if (rnd.nextInt(3) == 0) {
                    line.append("\u001b[").append(rnd.nextInt(2)).append(';').append(30 + rnd.nextInt(8)).append('m');
                }
                if (rnd.nextInt(20) == 0) {
                    line.append("\u001b[38;2;").append(rnd.nextInt(256)).append(";9;99m");
                }
                line.append(words[rnd.nextInt(words.length)]).append(' ');
            }
            line.append("\u001b[0m");
            if (rnd.nextInt(50) == 0) {
                line.append("\u001b[K\u001b[2A\u001b[5G");
            }
            line.append("\r\n");
            byte[] bytes = line.toString().getBytes(StandardCharsets.UTF_8);
            out.write(bytes, 0, bytes.length);
        }
        return out.toByteArray();
    }
}
