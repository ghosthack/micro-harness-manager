package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.Line;
import io.github.ghosthack.microhm.vt.TerminalEmulator;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Web links in the terminal's text, for ⌘-click; the phone page finds them the same way
 * (findLinks in app.js). A long link may run on over several rows: where the terminal
 * soft-wrapped it, and where the program broke it at the right edge itself (Claude Code
 * does), going on in the next row at the same indent.
 */
final class Links {

    private static final Pattern URL = Pattern.compile("https?://[^\\s<>\"'`]+");
    private static final Pattern URL_CHARS = Pattern.compile("[^\\s<>\"'`]+");
    /** Rows looked at above and below the clicked one: a link longer than this is unlikely. */
    private static final int REACH = 8;

    /** A piece of a link: on {@code row} (an index into the rows given), columns
     * {@code [from, to)}. */
    record Span(int row, int from, int to, String url) {
    }

    /** The web link covering cell {@code (row, column)} (an emulator line index), or null.
     * The caller holds the emulator's lock. */
    static String urlAt(TerminalEmulator emulator, int row, int column) {
        int first = Math.max(-emulator.historySize(), row - REACH);
        int last = Math.min(emulator.rows() - 1, row + REACH);
        List<String> rows = new ArrayList<>();
        List<Boolean> wrapped = new ArrayList<>();
        for (int r = first; r <= last; r++) {
            Line line = emulator.line(r);
            rows.add(cells(line));
            wrapped.add(line.isWrapped());
        }
        for (Span span : find(rows, wrapped, emulator.columns())) {
            if (span.row() == row - first && column >= span.from() && column < span.to()) {
                return span.url();
            }
        }
        return null;
    }

    /** A row as one character per column: a wide character's tail, and a cell whose text is
     * not one character (an emoji, a combining mark), never belong to a link. */
    private static String cells(Line line) {
        StringBuilder sb = new StringBuilder(line.columns());
        StringBuilder cell = new StringBuilder();
        for (int x = 0; x < line.columns(); x++) {
            if (line.isEmpty(x) || line.isWideTail(x)) {
                sb.append(' ');
                continue;
            }
            cell.setLength(0);
            line.appendText(x, cell);
            sb.append(cell.length() == 1 ? cell.charAt(0) : ' ');
        }
        return sb.toString();
    }

    /** The links in {@code rows} as spans, every piece of a link carrying the whole link.
     * {@code wrapped.get(i)}: row i soft-wraps into the next. */
    static List<Span> find(List<String> rows, List<Boolean> wrapped, int columns) {
        List<Span> spans = new ArrayList<>();
        int[] taken = new int[rows.size()]; // columns already part of a link from above
        for (int i = 0; i < rows.size(); i++) {
            String text = rows.get(i);
            Matcher m = URL.matcher(text);
            while (m.find()) {
                if (m.start() < taken[i]) {
                    continue;
                }
                List<Span> pieces = new ArrayList<>();
                pieces.add(new Span(i, m.start(), m.end(), null));
                StringBuilder raw = new StringBuilder(m.group());
                int row = i;
                int end = m.end();
                int base = indent(text);
                while (row + 1 < rows.size() && runsOn(rows.get(row), end, columns)) {
                    String next = rows.get(row + 1);
                    int at = wrapped.get(row) ? 0 : indent(next);
                    if (!wrapped.get(row) && at != base) {
                        break;
                    }
                    Matcher piece = URL_CHARS.matcher(next).region(at, next.length());
                    if (!piece.lookingAt()) {
                        break;
                    }
                    row++;
                    end = piece.end();
                    taken[row] = end;
                    pieces.add(new Span(row, at, end, null));
                    raw.append(piece.group());
                }
                String url = trim(raw.toString());
                int cut = raw.length() - url.length();
                for (int p = pieces.size() - 1; p >= 0 && cut > 0; p--) {
                    Span s = pieces.get(p);
                    int drop = Math.min(cut, s.to() - s.from());
                    cut -= drop;
                    pieces.set(p, new Span(s.row(), s.from(), s.to() - drop, null));
                }
                for (Span s : pieces) {
                    if (s.to() > s.from()) {
                        spans.add(new Span(s.row(), s.from(), s.to(), url));
                    }
                }
            }
        }
        return spans;
    }

    /** A link ending at {@code end} goes on in the next row: nothing follows it on its row,
     * and it reaches the right edge (a program leaves a column or two free there). */
    private static boolean runsOn(String row, int end, int columns) {
        return row.substring(end).isBlank() && end >= columns - 2;
    }

    private static int indent(String row) {
        int n = 0;
        while (n < row.length() && row.charAt(n) == ' ') {
            n++;
        }
        return n;
    }

    /** Drops what usually ends the sentence around a link rather than the link: trailing
     * punctuation, and a closing bracket the link did not open. */
    static String trim(String url) {
        int end = url.length();
        while (end > 0) {
            char c = url.charAt(end - 1);
            if (".,;:!?".indexOf(c) >= 0) {
                end--;
            } else if (c == ')' && count(url, '(', end) < count(url, ')', end)
                    || c == ']' && count(url, '[', end) < count(url, ']', end)
                    || c == '}' && count(url, '{', end) < count(url, '}', end)) {
                end--;
            } else {
                break;
            }
        }
        return url.substring(0, end);
    }

    private static int count(String s, char c, int end) {
        int n = 0;
        for (int i = 0; i < end; i++) {
            if (s.charAt(i) == c) {
                n++;
            }
        }
        return n;
    }

    private Links() {
    }
}
