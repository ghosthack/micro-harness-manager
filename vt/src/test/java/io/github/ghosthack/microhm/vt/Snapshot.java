package io.github.ghosthack.microhm.vt;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;

/**
 * The emulator's observable state as stable text, for golden files: everything {@link
 * ModelAssert#describeState} covers (cursor, pen, modes, margins, tab stops, charsets,
 * title), the daemon-side {@link HeadlessTerminal.Modes}, the replies sent so far, the
 * history size, and every visible row (text, wrapped flag, style runs). Control and other
 * invisible characters are escaped and a wide character's tail cell is left out (it is the
 * character's second column), so a row reads as the screen does.
 */
final class Snapshot {

    private Snapshot() {
    }

    static String of(HeadlessTerminal terminal, List<String> replies) {
        TerminalEmulator e = terminal.emulator();
        StringBuilder sb = new StringBuilder();
        e.lock().lock();
        try {
            sb.append("size ").append(e.columns()).append('x').append(e.rows())
                    .append(" history ").append(e.historySize()).append('\n');
            sb.append("state ").append(escape(ModelAssert.describeState(e))).append('\n');
            sb.append("modes ").append(escape(terminal.modes().toString())).append('\n');
            for (String reply : replies) {
                sb.append("reply ").append(escape(reply)).append('\n');
            }
            for (int y = 0; y < e.rows(); y++) {
                Line line = e.line(y);
                sb.append(String.format("%3d%s|", y, line.isWrapped() ? "+" : " "));
                for (int x = 0; x < e.columns(); x++) {
                    if (line.isWideTail(x)) {
                        continue;
                    }
                    String text = line.text(x);
                    sb.append(text.isEmpty() ? " " : escape(text));
                }
                sb.append("|\n");
                appendStyles(sb, line, e.columns());
            }
        } finally {
            e.lock().unlock();
        }
        return sb.toString();
    }

    /** Runs of non-default style: {@code   cols A-B <style>}. */
    private static void appendStyles(StringBuilder sb, Line line, int width) {
        int x = 0;
        while (x < width) {
            long style = line.style(x);
            int end = x;
            while (end + 1 < width && line.style(end + 1) == style) {
                end++;
            }
            if (style != Style.DEFAULT) {
                sb.append("    cols ").append(x).append('-').append(end).append(' ')
                        .append(Style.describe(style)).append('\n');
            }
            x = end + 1;
        }
    }

    /** Printable as is; C0, DEL, C1, backslash and format characters as {@code \\u{..}}. */
    static String escape(String s) {
        StringBuilder sb = new StringBuilder();
        s.codePoints().forEach(cp -> {
            int type = Character.getType(cp);
            if (cp == '\\' || cp < 0x20 || (cp >= 0x7F && cp < 0xA0) || type == Character.FORMAT
                    || type == Character.UNASSIGNED || type == Character.PRIVATE_USE
                    || type == Character.SURROGATE) {
                sb.append("\\u{").append(Integer.toHexString(cp)).append('}');
            } else {
                sb.appendCodePoint(cp);
            }
        });
        return sb.toString();
    }

    /** A running SHA-256 over successive snapshots, for streams checked after every step. */
    static final class Chain {
        private final MessageDigest digest;

        Chain() {
            try {
                digest = MessageDigest.getInstance("SHA-256");
            } catch (NoSuchAlgorithmException e) {
                throw new AssertionError(e);
            }
        }

        void add(String snapshot) {
            digest.update(snapshot.getBytes(StandardCharsets.UTF_8));
            digest.update((byte) 0);
        }

        /** The digest so far (the chain continues). */
        String value() {
            try {
                return HexFormat.of().formatHex(((MessageDigest) digest.clone()).digest()).substring(0, 16);
            } catch (CloneNotSupportedException e) {
                throw new AssertionError(e);
            }
        }
    }
}
