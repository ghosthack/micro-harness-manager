package io.github.ghosthack.microhm.app.terminal;

import java.nio.charset.StandardCharsets;

/**
 * Clipboard text → the bytes a paste sends. Line breaks become CR (what Enter sends), so a
 * multi-line paste into a shell or agent behaves like typing. With bracketed paste (DECSET
 * 2004) the text is wrapped in {@code ESC [200~ … ESC [201~}, and anything inside that could
 * end the bracket early or smuggle a control sequence — an embedded {@code ESC [201~}, any
 * other ESC, a C1 CSI — is removed first, so pasted text can never act as keystrokes.
 */
final class PasteEncoder {

    static final String START = "\u001b[200~";
    static final String END = "\u001b[201~";

    static String normalize(String text) {
        return text.replace("\r\n", "\r").replace('\n', '\r');
    }

    static String sanitize(String text) {
        String s = text;
        String previous;
        do { // removing one marker may join the halves of another
            previous = s;
            s = s.replace(END, "").replace(START, "");
        } while (!s.equals(previous));
        return s.replace("\u001b", "").replace("\u009b", "");
    }

    static byte[] encode(String text, boolean bracketed) {
        String normalized = normalize(text);
        String out = bracketed ? START + sanitize(normalized) + END : normalized;
        return out.getBytes(StandardCharsets.UTF_8);
    }

    private PasteEncoder() {
    }

    /**
     * Dropped files → what a drop types: each path quoted for the shell, separated by
     * spaces, with a trailing space so the next word starts clean. POSIX paths of only safe
     * characters stay bare and the rest take single quotes (as Terminal.app does); on
     * Windows a path with a space or shell metacharacter takes double quotes.
     */
    static String droppedPaths(java.util.List<String> paths, boolean windows) {
        if (paths.isEmpty()) return "";
        StringBuilder out = new StringBuilder();
        for (String path : paths) {
            out.append(windows ? windowsQuote(path) : shellQuote(path)).append(' ');
        }
        return out.toString();
    }

    private static final java.util.regex.Pattern SAFE_POSIX =
            java.util.regex.Pattern.compile("[A-Za-z0-9_./+,:@%=-]+");

    static String shellQuote(String path) {
        if (SAFE_POSIX.matcher(path).matches()) return path;
        return "'" + path.replace("'", "'\\''") + "'";
    }

    static String windowsQuote(String path) {
        if (!path.isEmpty() && path.chars().noneMatch(c -> " &()[]{}^=;!'+,`~%$\"".indexOf(c) >= 0)) {
            return path;
        }
        // a double quote cannot appear in a Windows path, so wrapping is enough
        return "\"" + path + "\"";
    }
}
