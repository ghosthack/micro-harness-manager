package io.github.ghosthack.microhm.vt;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** A {@link HeadlessTerminal} fed the way the daemon feeds one (tokenised, SGR-normalised),
 * collecting its replies; {@link #snapshot} is what the golden files hold. */
final class Subject {

    final HeadlessTerminal terminal;
    final List<String> replies = new ArrayList<>();
    private final VtTokenizer tokenizer = new VtTokenizer();

    Subject(int columns, int rows, int history) {
        terminal = new HeadlessTerminal(columns, rows, history,
                b -> replies.add(new String(b, StandardCharsets.UTF_8)));
    }

    void feed(byte[] bytes) {
        List<VtToken> tokens = new ArrayList<>();
        for (VtToken t : tokenizer.feed(bytes).tokens()) {
            tokens.add(SgrNormalizer.normalize(t));
        }
        terminal.apply(tokens);
    }

    void feed(String s) {
        feed(s.getBytes(StandardCharsets.UTF_8));
    }

    TerminalEmulator emulator() {
        return terminal.emulator();
    }

    String snapshot() {
        return Snapshot.of(terminal, replies);
    }
}
