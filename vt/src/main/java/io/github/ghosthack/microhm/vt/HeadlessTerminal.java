package io.github.ghosthack.microhm.vt;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The session daemon's view of a terminal: a {@link TerminalEmulator} with no display, fed
 * <em>synchronously</em> by the session's pump thread through {@link #apply(List)}. It is the
 * server's source of truth for {@link #screenText()} (capture), {@link #serialize(int)}
 * (redraw on attach), the pane title and the input modes ({@link #modes()}).
 *
 * <p>Threading: {@code apply}, {@code resize} and {@code serialize} are called by the session
 * under its lock; the getters may be called from any thread. Everything takes the emulator's
 * own {@link TerminalEmulator#lock() lock}.
 *
 * <p>Replies (DA1, DA2, DSR 5/6) go to {@link Replies#send(byte[])} — the session's PTY
 * writer queue — in the emulator's {@link TerminalEmulator.ReplyScope#BASIC basic} scope,
 * which answers exactly the queries {@link QueryFilter} strips from the client stream. The
 * colour-scheme report {@code CSI ?997;…n} is never produced (only a client knows its theme),
 * and XTWINOPS resize requests from the program ({@code CSI 8;h;w t}) are ignored. A
 * {@link ModeTracker} sees every token too, for the OSC 7 / OSC 9;9 working directory.
 */
public final class HeadlessTerminal implements AutoCloseable {

    /** Where the emulator's own replies (DA, DSR, CPR) go: the session's PTY writer queue. */
    public interface Replies {
        void send(byte[] bytes);
    }

    /** The input and display modes a client or the session needs (see {@link #modes()}). */
    public record Modes(boolean cursorVisible, int cursorShape /* DECSCUSR 0..6, 0 = default */,
                        boolean bracketedPaste, boolean applicationCursorKeys, boolean applicationKeypad,
                        int mouseTrackingMode /* 1000/1002/1003, 0 = none */, boolean mouseSgr,
                        boolean focusReporting, boolean alternateScreen, boolean autoWrap,
                        boolean originMode, int scrollTop /* 1-based */, int scrollBottom /* 1-based */,
                        String title) {
    }

    /** What {@code ESC 7} / {@code CSI ?1049 h} saved on the main screen — the cursor
     * {@code CSI ?1049 l} restores; null when nothing was saved since the last RIS.
     * {@code cursorX} and {@code cursorY} are 0-based; {@code style} is a packed {@link Style}. */
    public record StoredCursor(int cursorX, int cursorY, long style, boolean autoWrap,
                               boolean originMode) {
    }

    /** Prefix of a row {@link #annotatedText()} considers selected. */
    public static final String SELECTION_MARKER = "\u25b6 ";
    /** Inserted by {@link #annotatedText()} where the visible cursor is. */
    public static final String CURSOR_MARKER = "\u25ae";

    private final TerminalEmulator emulator;
    private final ModeTracker modeTracker;
    private volatile boolean closed;

    public HeadlessTerminal(int columns, int rows, int maxHistoryLines, Replies replies) {
        this.emulator = new TerminalEmulator(columns, rows, maxHistoryLines);
        this.emulator.setReplies(replies::send, TerminalEmulator.ReplyScope.BASIC);
        this.modeTracker = new ModeTracker(rows);
    }

    /** Applies a batch of complete tokens to the emulator and the mode tracker, in order.
     * Returns when every token has been applied. Called under the session lock only. */
    public void apply(List<VtToken> tokens) {
        if (closed || tokens.isEmpty()) {
            return;
        }
        emulator.apply(tokens);
        emulator.lock().lock();
        try {
            for (VtToken token : tokens) {
                modeTracker.observe(token);
            }
        } finally {
            emulator.lock().unlock();
        }
    }

    /** Resizes both screens (see {@link TerminalEmulator#resize}); the scroll region resets. */
    public void resize(int columns, int rows) {
        if (closed) {
            return;
        }
        emulator.resize(columns, rows);
        emulator.lock().lock();
        try {
            modeTracker.resized(emulator.rows());
        } finally {
            emulator.lock().unlock();
        }
    }

    public int columns() {
        emulator.lock().lock();
        try {
            return emulator.columns();
        } finally {
            emulator.lock().unlock();
        }
    }

    public int rows() {
        emulator.lock().lock();
        try {
            return emulator.rows();
        } finally {
            emulator.lock().unlock();
        }
    }

    /** The visible screen: one string per row, trailing whitespace trimmed, wide-character
     * placeholder cells removed; lines joined with {@code \n}, and the result ends with
     * {@code \n} (tmux {@code capture-pane -p} shape). */
    public String screenText() {
        emulator.lock().lock();
        try {
            StringBuilder sb = new StringBuilder();
            for (int y = 0; y < emulator.rows(); y++) {
                sb.append(trimTrailing(emulator.line(y).toString())).append('\n');
            }
            return sb.toString();
        } finally {
            emulator.lock().unlock();
        }
    }

    /** The newest {@code maxLines} scrollback lines above the screen (fewer when the history
     * holds fewer), oldest first, in {@link #screenText()}'s shape: one row per line,
     * trailing whitespace trimmed, each ending with {@code \n}. Empty while the alternate
     * screen is shown: a full-screen program keeps no scrollback. */
    public String historyText(int maxLines) {
        emulator.lock().lock();
        try {
            int n = Math.min(Math.max(0, maxLines), emulator.historySize());
            StringBuilder sb = new StringBuilder();
            for (int i = -n; i < 0; i++) {
                sb.append(trimTrailing(emulator.line(i).toString())).append('\n');
            }
            return sb.toString();
        } finally {
            emulator.lock().unlock();
        }
    }

    /** Lines of scrollback currently held above the screen (0 on the alternate screen). */
    public int historySize() {
        emulator.lock().lock();
        try {
            return emulator.historySize();
        } finally {
            emulator.lock().unlock();
        }
    }

    /**
     * {@link #screenText()} with two hints a reader of plain text would otherwise lose:
     * <ul>
     *   <li><b>Selection</b>: a row with a non-blank cell drawn in reverse video, or on a
     *       background other than the screen's dominant one (the most frequent background
     *       of the non-blank cells, default included), is prefixed {@link #SELECTION_MARKER}.
     *       When more than a third of the non-blank rows qualify the colours are a theme,
     *       not a selection, and no row is marked.</li>
     *   <li><b>Cursor</b>: when the cursor is visible, {@link #CURSOR_MARKER} is inserted
     *       (not substituted) at its column in its row, padding with spaces past the text.</li>
     * </ul>
     * A blank cell is a space or an empty cell with the default background and no reverse
     * video.
     */
    public String annotatedText() {
        emulator.lock().lock();
        try {
            int height = emulator.rows();
            int width = emulator.columns();
            Line[] lines = new Line[height];
            Map<Integer, Integer> backgrounds = new HashMap<>();
            for (int y = 0; y < height; y++) {
                lines[y] = emulator.line(y);
                for (int x = 0; x < width; x++) {
                    if (!isBlank(lines[y], x)) {
                        backgrounds.merge(Style.background(lines[y].style(x)), 1, Integer::sum);
                    }
                }
            }
            int dominant = Style.COLOR_DEFAULT;
            int best = -1;
            for (Map.Entry<Integer, Integer> entry : backgrounds.entrySet()) {
                if (entry.getValue() > best) {
                    best = entry.getValue();
                    dominant = entry.getKey();
                }
            }
            boolean[] highlighted = new boolean[height];
            int contentRows = 0;
            int highlightedRows = 0;
            for (int y = 0; y < height; y++) {
                boolean content = false;
                for (int x = 0; x < width; x++) {
                    if (isBlank(lines[y], x)) {
                        continue;
                    }
                    content = true;
                    long style = lines[y].style(x);
                    if (Style.inverse(style) || Style.background(style) != dominant) {
                        highlighted[y] = true;
                        break;
                    }
                }
                if (content) {
                    contentRows++;
                }
                if (highlighted[y]) {
                    highlightedRows++;
                }
            }
            boolean selection = highlightedRows > 0 && highlightedRows * 3 <= contentRows;
            int cursorRow = emulator.cursorVisible() ? emulator.cursorRow() : -1;
            StringBuilder sb = new StringBuilder();
            for (int y = 0; y < height; y++) {
                String text = trimTrailing(lines[y].toString());
                if (y == cursorRow) {
                    int index = textIndex(lines[y], emulator.cursorColumn());
                    StringBuilder row = new StringBuilder(text);
                    while (row.length() < index) {
                        row.append(' ');
                    }
                    row.insert(index, CURSOR_MARKER);
                    text = row.toString();
                }
                if (selection && highlighted[y]) {
                    sb.append(SELECTION_MARKER);
                }
                sb.append(text).append('\n');
            }
            return sb.toString();
        } finally {
            emulator.lock().unlock();
        }
    }

    /** The last OSC 0/1/2 title, or "" if never set. */
    public String title() {
        emulator.lock().lock();
        try {
            return emulator.title();
        } finally {
            emulator.lock().unlock();
        }
    }

    /** The last OSC 7 / OSC 9;9 working directory the shell reported, or null. */
    public String reportedCwd() {
        emulator.lock().lock();
        try {
            return modeTracker.reportedCwd();
        } finally {
            emulator.lock().unlock();
        }
    }

    public Modes modes() {
        emulator.lock().lock();
        try {
            return modesLocked();
        } finally {
            emulator.lock().unlock();
        }
    }

    public StoredCursor storedCursor() {
        emulator.lock().lock();
        try {
            TerminalEmulator.SavedCursor saved = emulator.savedCursor(false);
            return saved == null ? null : new StoredCursor(saved.column(), saved.row(), saved.style(),
                    saved.autoWrap(), saved.originMode());
        } finally {
            emulator.lock().unlock();
        }
    }

    /** The redraw stream for a freshly attached client at the current size: see
     * {@link ScreenSerializer}. Includes up to
     * {@code historyLines} history lines before the screen. */
    public byte[] serialize(int historyLines) {
        emulator.lock().lock();
        try {
            return ScreenSerializer.serialize(emulator, historyLines);
        } finally {
            emulator.lock().unlock();
        }
    }

    /** Test/diagnostic access: the screen rows as plain text, untrimmed. */
    public List<String> screenLines() {
        emulator.lock().lock();
        try {
            List<String> lines = new ArrayList<>(emulator.rows());
            for (int y = 0; y < emulator.rows(); y++) {
                lines.add(emulator.line(y).toString());
            }
            return lines;
        } finally {
            emulator.lock().unlock();
        }
    }

    /** The underlying emulator, for reads beyond this class's (take its {@link
     * TerminalEmulator#lock() lock}). Do not feed it directly: go through {@link #apply}. */
    public TerminalEmulator emulator() {
        return emulator;
    }

    /** Releases nothing OS-level (there is no thread); marks the instance closed so a late
     * {@code apply} is a no-op. Idempotent. */
    @Override
    public void close() {
        closed = true;
    }

    // --- internals -------------------------------------------------------------------

    private Modes modesLocked() {
        TerminalEmulator e = emulator;
        int mouse = switch (e.mouseTracking()) {
            case NORMAL, BUTTON_MOTION, ANY_MOTION -> e.mouseTracking().mode;
            case NONE, X10 -> 0;
        };
        return new Modes(e.cursorVisible(), e.cursorShape(), e.bracketedPaste(),
                e.applicationCursorKeys(), e.applicationKeypad(), mouse,
                e.mouseEncoding() == TerminalEmulator.MouseEncoding.SGR, e.focusReporting(),
                e.alternateScreen(), e.autoWrap(), e.originMode(), e.scrollTop() + 1,
                e.scrollBottom() + 1, e.title());
    }

    /** The index in the row's text of column {@code column}: wide tails take a column but
     * no text, attached code points add text, and columns past the end count as spaces. */
    private static int textIndex(Line line, int column) {
        int index = 0;
        int end = Math.min(column, line.columns());
        for (int x = 0; x < end; x++) {
            if (line.isWideTail(x)) {
                continue;
            }
            int cp = line.codePoint(x);
            index += cp == 0 ? 1 : Character.charCount(cp);
            if (line.hasExtras(x)) {
                index += line.text(x).length() - Character.charCount(cp);
            }
        }
        return index + Math.max(0, column - line.columns());
    }

    private static boolean isBlank(Line line, int x) {
        int cp = line.codePoint(x);
        long style = line.style(x);
        return (cp == ' ' || cp == 0) && !line.isWideTail(x)
                && Style.background(style) == Style.COLOR_DEFAULT && !Style.inverse(style);
    }

    private static String trimTrailing(String s) {
        int end = s.length();
        while (end > 0) {
            char c = s.charAt(end - 1);
            if (c == ' ' || c == '\t' || c == '\0') {
                end--;
            } else {
                break;
            }
        }
        return s.substring(0, end);
    }
}
