package io.github.ghosthack.microhm.vt;

import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.locks.ReentrantLock;

/**
 * An xterm-compatible terminal emulator: the screen model (main screen with scrollback,
 * alternate screen, cursor, modes) plus the interpreter that applies {@link VtToken}s to it.
 * Plain Java, no dependencies. It has two consumers: {@link HeadlessTerminal} on the session
 * daemon, and a renderer on the client, which feeds raw bytes with {@link #feed} and paints
 * from the read API below.
 *
 * <h2>Threading</h2>
 * The model is guarded by {@link #lock()}. {@link #apply}, {@link #feed} and {@link #resize}
 * take it themselves. Every other getter reads unsynchronised state: hold the lock around a
 * group of reads that must be consistent (a frame), e.g.
 * <pre>{@code
 * emulator.lock().lock();
 * try {
 *     for (int y = 0; y < emulator.rows(); y++) paint(emulator.line(y));
 *     paintCursor(emulator.cursorRow(), emulator.cursorColumn());
 * } finally {
 *     emulator.lock().unlock();
 * }
 * }</pre>
 * {@link #changeCount()} is safe without the lock. {@link TerminalListener} callbacks and
 * replies are delivered after the lock is released, on the feeding thread.
 *
 * <h2>Coordinates</h2>
 * Rows and columns are 0-based. {@link #line(int)} takes {@code -historySize()..-1} for the
 * scrollback (−1 is the newest history line) and {@code 0..rows()-1} for the screen. After a
 * character is written in the last column the cursor stays on that column with
 * {@link #cursorPendingWrap()} set; the next printable character wraps first (DEC/xterm
 * deferred wrap).
 *
 * <h2>Replies</h2>
 * Queries are answered through the {@link ReplySink} given to {@link #setReplies}. In the
 * {@link ReplyScope#BASIC basic} scope only DA1 ({@code CSI c}, any parameters without a
 * {@code >} prefix), DA2 ({@code CSI > c} / {@code CSI > 0 c}) and DSR 5/6 are answered — the
 * set {@link QueryFilter} strips from the stream clients see, so the two stay in lock-step —
 * plus XTGETTCAP ({@code DCS + q}), answered "invalid" as jediterm did.
 * {@link ReplyScope#FULL} adds DECXCPR ({@code CSI ? 6 n}), DECRQM, XTVERSION and the kitty
 * keyboard query ({@code CSI ? u}); use it only for a standalone terminal whose key encoder
 * implements what it then advertises. {@link ReplyScope#CLIENT} answers none of those: it is
 * for a renderer attached through the daemon, which answers the basic set itself and forwards
 * the rest unanswered on purpose.
 *
 * <p>The colour-scheme query {@code CSI ? 996 n} is answered ({@code CSI ? 997 ; 1 n} dark,
 * {@code ; 2 n} light) in every scope, but only once {@link #setColorScheme} has been given a
 * scheme — only a client knows its theme, so the daemon never sets one. While the program has
 * DECSET 2031 on, a scheme change is also reported unsolicited. Nothing answers OSC colour
 * queries.
 */
public final class TerminalEmulator {

    /** Where replies to queries go (e.g. the PTY writer). */
    public interface ReplySink {
        void send(byte[] bytes);
    }

    /** Which queries are answered; see the class documentation. */
    public enum ReplyScope {
        BASIC, FULL,
        /** Nothing but the colour-scheme report (see {@link #setColorScheme}). */
        CLIENT
    }

    /** The light/dark preference reported for {@code CSI ? 996 n}. */
    public enum ColorScheme {
        DARK(1), LIGHT(2);

        /** The {@code CSI ? 997 ; n n} report value. */
        public final int report;

        ColorScheme(int report) {
            this.report = report;
        }
    }

    /** Mouse reporting requested by the program (DECSET 9/1000/1002/1003). */
    public enum MouseTracking {
        NONE(0), X10(9), NORMAL(1000), BUTTON_MOTION(1002), ANY_MOTION(1003);

        /** The DECSET number, 0 for none. */
        public final int mode;

        MouseTracking(int mode) {
            this.mode = mode;
        }
    }

    /** How mouse reports are encoded (DECSET 1005/1006/1015; default is X10 bytes). */
    public enum MouseEncoding {
        DEFAULT, UTF8, SGR, URXVT
    }

    /**
     * A saved cursor (DECSC, {@code CSI s}, {@code CSI ?1048 h}, {@code CSI ?1049 h}).
     * {@code charsets} packs the G0–G3 designations (2 bits each, {@link #CHARSET_ASCII},
     * {@link #CHARSET_DEC_GRAPHICS}, {@link #CHARSET_UK}) and the GL shift (bits 8–9).
     */
    public record SavedCursor(int column, int row, boolean pendingWrap, long style, boolean autoWrap,
                              boolean originMode, int charsets) {
    }

    /** Charset designation: US ASCII ({@code ESC ( B} and anything unsupported). */
    public static final int CHARSET_ASCII = 0;
    /** Charset designation: DEC special graphics, line drawing ({@code ESC ( 0}). */
    public static final int CHARSET_DEC_GRAPHICS = 1;
    /** Charset designation: United Kingdom, {@code #} is {@code £} ({@code ESC ( A}). */
    public static final int CHARSET_UK = 2;

    private static final int MIN_COLUMNS = 2;
    private static final int MAX_PARAMS = 32;
    private static final int MAX_TITLE_STACK = 10;
    private static final int MAX_KITTY_STACK = 16;
    private static final int MAX_TITLE_LENGTH = 4096;
    private static final byte[] DA1_REPLY = "\u001b[?62;22c".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] DA2_REPLY = "\u001b[>0;10;0c".getBytes(StandardCharsets.US_ASCII);
    private static final String XTVERSION = "microhm-vt";
    private static final byte[] XTGETTCAP_INVALID = "\u001bP0+r\u001b\\".getBytes(StandardCharsets.US_ASCII);

    /** DEC special graphics for 0x5F..0x7E. */
    private static final char[] DEC_GRAPHICS = (
            "\u00a0\u25c6\u2592\u2409\u240c\u240d\u240a\u00b0\u00b1\u2424\u240b\u2518\u2510\u250c"
                    + "\u2514\u253c\u23ba\u23bb\u2500\u23bc\u23bd\u251c\u2524\u2534\u252c\u2502\u2264"
                    + "\u2265\u03c0\u2260\u00a3\u00b7").toCharArray();

    private final ReentrantLock lock = new ReentrantLock();
    private final VtTokenizer tokenizer = new VtTokenizer();
    /** {@link #feed}'s path: tokens straight from the tokenizer, no copies. Under the lock. */
    private final VtTokenizer.Sink tokenSink = this::applyFed;
    /** Tokens {@link #applyFed} applied in the current {@link #feed}. */
    private int tokensApplied;

    private int columns;
    private int rows;
    private final ScreenBuffer main;
    private final ScreenBuffer alt;
    private ScreenBuffer screen;

    // Cursor and pen.
    private int cx;
    private int cy;
    private boolean pendingWrap;
    private long pen;
    private SavedCursor savedMain;
    private SavedCursor savedAlt;
    private int lastPrinted;

    // Margins (0-based, inclusive).
    private int scrollTop;
    private int scrollBottom;
    private boolean[] tabStops;

    // Charsets.
    private final int[] charsets = new int[4];
    private int gl;
    private int singleShift = -1;

    // Modes.
    private boolean autoWrap;
    private boolean originMode;
    private boolean insertMode;
    private boolean newLineMode;
    private boolean applicationCursorKeys;
    private boolean applicationKeypad;
    private boolean cursorVisible;
    private boolean cursorBlink;
    private int cursorShape;
    private boolean reverseVideo;
    private boolean bracketedPaste;
    private boolean focusReporting;
    private boolean synchronizedOutput;
    private boolean colorSchemeUpdates;
    private ColorScheme colorScheme;
    private MouseTracking mouseTracking = MouseTracking.NONE;
    private MouseEncoding mouseEncoding = MouseEncoding.DEFAULT;
    private final ArrayDeque<Integer> kittyFlags = new ArrayDeque<>();

    private String title = "";
    private final ArrayDeque<String> titleStack = new ArrayDeque<>();

    // UTF-8 decoder state, carried across TEXT tokens.
    private int utf8Need;
    private int utf8Code;
    private int utf8Min;

    // Parsed CSI parameters (reused).
    private final int[] params = new int[MAX_PARAMS];
    private final boolean[] subParam = new boolean[MAX_PARAMS];
    private int paramCount;

    // Outputs of the batch being applied, delivered after unlocking.
    private ReplySink replySink;
    private ReplyScope replyScope = ReplyScope.BASIC;
    private final List<byte[]> pendingReplies = new ArrayList<>();
    private int pendingBells;
    private boolean titleDirty;
    private volatile TerminalListener listener;
    private volatile long changeCount;

    /** A {@code columns} × {@code rows} terminal keeping up to {@code maxHistoryLines} lines of
     * main-screen scrollback. Columns below 2 and rows below 1 are raised to those minimums. */
    public TerminalEmulator(int columns, int rows, int maxHistoryLines) {
        this.columns = Math.max(MIN_COLUMNS, columns);
        this.rows = Math.max(1, rows);
        this.main = new ScreenBuffer(this.columns, this.rows, maxHistoryLines);
        this.alt = new ScreenBuffer(this.columns, this.rows, 0);
        this.screen = main;
        this.tabStops = defaultTabStops(this.columns);
        resetState();
    }

    // =====================================================================================
    // Input
    // =====================================================================================

    /** Routes replies to {@code sink} (null drops them) answering queries in {@code scope}. */
    public void setReplies(ReplySink sink, ReplyScope scope) {
        lock.lock();
        try {
            this.replySink = sink;
            this.replyScope = scope;
        } finally {
            lock.unlock();
        }
    }

    /**
     * The scheme {@code CSI ? 996 n} is answered with; null (the default) leaves it unanswered.
     * When the scheme changes while the program has DECSET 2031 on, the new report is sent
     * at once (on the calling thread, outside the lock).
     */
    public void setColorScheme(ColorScheme scheme) {
        ReplySink sink;
        lock.lock();
        try {
            boolean notify = colorSchemeUpdates && scheme != null && scheme != colorScheme;
            colorScheme = scheme;
            sink = notify ? replySink : null;
        } finally {
            lock.unlock();
        }
        if (sink != null) {
            sink.send(colorSchemeReport(scheme));
        }
    }

    /** The scheme given to {@link #setColorScheme}, or null. */
    public ColorScheme colorScheme() {
        return colorScheme;
    }

    private static byte[] colorSchemeReport(ColorScheme scheme) {
        return ("\u001b[?997;" + scheme.report + "n").getBytes(StandardCharsets.US_ASCII);
    }

    /** Sets the (single) listener; null removes it. */
    public void setListener(TerminalListener listener) {
        this.listener = listener;
    }

    /** The lock guarding the model; see the class documentation. */
    public ReentrantLock lock() {
        return lock;
    }

    /** Incremented by every {@link #apply}, {@link #feed} and {@link #resize} that may have
     * changed what a renderer shows. Safe to read without the lock. */
    public long changeCount() {
        return changeCount;
    }

    /**
     * Feeds raw program output (any chunking): runs it through this emulator's own
     * {@link VtTokenizer} and applies the completed tokens. For the client side; the daemon
     * tokenizes itself and calls {@link #apply}.
     */
    public void feed(byte[] data, int off, int len) {
        Outcome outcome;
        lock.lock();
        try {
            tokensApplied = 0;
            tokenizer.feed(data, off, len, tokenSink);
            if (tokensApplied == 0) {
                return;
            }
            outcome = endBatch();
        } finally {
            lock.unlock();
        }
        deliver(outcome);
    }

    /** {@link #feed(byte[], int, int)} for a whole array. */
    public void feed(byte[] data) {
        feed(data, 0, data.length);
    }

    /** Applies complete tokens in order (as produced by {@link VtTokenizer}). */
    public void apply(List<VtToken> tokens) {
        if (tokens.isEmpty()) {
            return;
        }
        Outcome outcome;
        lock.lock();
        try {
            for (VtToken token : tokens) {
                byte[] b = token.bytes();
                applyToken(token.kind(), b, 0, b.length);
            }
            outcome = endBatch();
        } finally {
            lock.unlock();
        }
        deliver(outcome);
    }

    /** What a batch of tokens left to do outside the lock. */
    private record Outcome(List<byte[]> replies, ReplySink sink, int bells, String newTitle) {
    }

    /** Under the lock, after a batch: counts the change and takes its pending effects. */
    private Outcome endBatch() {
        changeCount++;
        List<byte[]> replies = pendingReplies.isEmpty() ? List.of() : new ArrayList<>(pendingReplies);
        pendingReplies.clear();
        int bells = pendingBells;
        pendingBells = 0;
        String newTitle = titleDirty ? title : null;
        titleDirty = false;
        return new Outcome(replies, replySink, bells, newTitle);
    }

    /** Outside the lock: sends the replies and tells the listener. */
    private void deliver(Outcome outcome) {
        if (outcome.sink() != null) {
            for (byte[] reply : outcome.replies()) {
                outcome.sink().send(reply);
            }
        }
        TerminalListener l = listener;
        if (l != null) {
            if (outcome.newTitle() != null) {
                l.titleChanged(outcome.newTitle());
            }
            if (outcome.bells() > 0) {
                l.bell(outcome.bells());
            }
            l.contentChanged();
        }
    }

    /**
     * Resizes both screens without reflow: lines are truncated or padded; when the screen
     * loses rows, blank rows below the cursor go first, then rows are pushed off the top
     * (into history on the main screen) so the cursor row stays visible. The scroll region is
     * reset to the full screen and the cursor is kept inside it.
     */
    public void resize(int newColumns, int newRows) {
        newColumns = Math.max(MIN_COLUMNS, newColumns);
        newRows = Math.max(1, newRows);
        lock.lock();
        try {
            if (newColumns == columns && newRows == rows) {
                return;
            }
            boolean onAlt = screen == alt;
            int activePush = rowsToPush(screen, cy, newRows);
            SavedCursor otherSaved = onAlt ? savedMain : savedAlt;
            ScreenBuffer other = onAlt ? main : alt;
            int otherCursor = otherSaved != null ? otherSaved.row() : lastNonBlankRow(other);
            int otherPush = rowsToPush(other, otherCursor, newRows);
            screen.resize(newColumns, newRows, activePush);
            other.resize(newColumns, newRows, otherPush);
            cy = clamp(cy - activePush, 0, newRows - 1);
            cx = Math.min(cx, newColumns - 1);
            pendingWrap = false;
            savedMain = shiftSaved(savedMain, onAlt ? otherPush : activePush, newColumns, newRows);
            savedAlt = shiftSaved(savedAlt, onAlt ? activePush : otherPush, newColumns, newRows);
            boolean[] stops = defaultTabStops(newColumns);
            System.arraycopy(tabStops, 0, stops, 0, Math.min(tabStops.length, newColumns));
            tabStops = stops;
            columns = newColumns;
            rows = newRows;
            scrollTop = 0;
            scrollBottom = newRows - 1;
            changeCount++;
        } finally {
            lock.unlock();
        }
        TerminalListener l = listener;
        if (l != null) {
            l.contentChanged();
        }
    }

    private int rowsToPush(ScreenBuffer buffer, int cursorRow, int newRows) {
        int lose = rows - newRows;
        if (lose <= 0) {
            return 0;
        }
        int blankBelow = 0;
        for (int y = rows - 1; y > cursorRow && blankBelow < lose; y--) {
            if (!isBlankLine(buffer.row(y))) {
                break;
            }
            blankBelow++;
        }
        return lose - blankBelow;
    }

    private int lastNonBlankRow(ScreenBuffer buffer) {
        for (int y = rows - 1; y >= 0; y--) {
            if (!isBlankLine(buffer.row(y))) {
                return y;
            }
        }
        return 0;
    }

    private static SavedCursor shiftSaved(SavedCursor saved, int pushed, int newColumns, int newRows) {
        if (saved == null) {
            return null;
        }
        return new SavedCursor(Math.min(saved.column(), newColumns - 1),
                clamp(saved.row() - pushed, 0, newRows - 1), false, saved.style(),
                saved.autoWrap(), saved.originMode(), saved.charsets());
    }

    private static boolean isBlankLine(Line line) {
        for (int x = 0; x < line.columns(); x++) {
            if (line.codePoints[x] != 0 || line.styles[x] != Style.DEFAULT) {
                return false;
            }
        }
        return true;
    }

    // =====================================================================================
    // Read API (hold lock())
    // =====================================================================================

    public int columns() {
        return columns;
    }

    public int rows() {
        return rows;
    }

    /** Lines of main-screen scrollback currently held (0 while the alternate screen is shown). */
    public int historySize() {
        return screen.history();
    }

    /**
     * Lines ever moved into the main screen's scrollback: monotonic, not reduced when the
     * oldest lines fall out of a full history or the history is cleared. A renderer keeps a
     * scrolled-back view (or a selection) anchored by adding the growth since its last frame,
     * which {@link #historySize()} alone cannot show once the history is full.
     */
    public long historyLinesAdded() {
        return main.linesAdded();
    }

    /** History line ({@code -historySize()..-1}) or screen row ({@code 0..rows()-1}). */
    public Line line(int index) {
        if (index < -screen.history() || index >= rows) {
            throw new IndexOutOfBoundsException("line " + index);
        }
        return screen.line(index);
    }

    /** Main-screen line by the same indexing, even while the alternate screen is shown
     * (for the serializer). */
    Line mainLine(int index) {
        return main.line(index);
    }

    int mainHistorySize() {
        return main.history();
    }

    public int cursorRow() {
        return cy;
    }

    public int cursorColumn() {
        return cx;
    }

    /** True when the last column was just written and the next printable character wraps. */
    public boolean cursorPendingWrap() {
        return pendingWrap;
    }

    /** DECTCEM ({@code CSI ?25 h/l}). */
    public boolean cursorVisible() {
        return cursorVisible;
    }

    /** DECSCUSR: 0 never set (the renderer's default), 1/2 blinking/steady block, 3/4
     * underline, 5/6 bar ({@code CSI 0 SP q} reads as 1). */
    public int cursorShape() {
        return cursorShape;
    }

    /** att610 cursor blinking ({@code CSI ?12 h/l}). */
    public boolean cursorBlink() {
        return cursorBlink;
    }

    /** The current pen: the {@link Style} the next character is written with. */
    public long pen() {
        return pen;
    }

    public boolean alternateScreen() {
        return screen == alt;
    }

    public boolean bracketedPaste() {
        return bracketedPaste;
    }

    /** DECCKM: arrow keys send SS3 sequences. */
    public boolean applicationCursorKeys() {
        return applicationCursorKeys;
    }

    /** DECKPAM / DECKPNM. */
    public boolean applicationKeypad() {
        return applicationKeypad;
    }

    public MouseTracking mouseTracking() {
        return mouseTracking;
    }

    public MouseEncoding mouseEncoding() {
        return mouseEncoding;
    }

    /** DECSET 1004: send focus in/out. */
    public boolean focusReporting() {
        return focusReporting;
    }

    /** DECSET 2031: the program asked to be told when the colour scheme changes. */
    public boolean colorSchemeUpdates() {
        return colorSchemeUpdates;
    }

    /** DECSET 2026: the program is mid-frame; a renderer may hold painting until it ends
     * (with a timeout of its own). */
    public boolean synchronizedOutput() {
        return synchronizedOutput;
    }

    /** DECSCNM: the whole screen is shown in reverse video. */
    public boolean reverseVideo() {
        return reverseVideo;
    }

    /** DECAWM. */
    public boolean autoWrap() {
        return autoWrap;
    }

    /** DECOM. */
    public boolean originMode() {
        return originMode;
    }

    /** IRM ({@code CSI 4 h}). */
    public boolean insertMode() {
        return insertMode;
    }

    /** LNM ({@code CSI 20 h}): LF also returns the carriage, Enter should send CR LF. */
    public boolean newLineMode() {
        return newLineMode;
    }

    /** Top margin of the scroll region, 0-based inclusive. */
    public int scrollTop() {
        return scrollTop;
    }

    /** Bottom margin of the scroll region, 0-based inclusive. */
    public int scrollBottom() {
        return scrollBottom;
    }

    /** The kitty keyboard protocol flags the program last pushed or set (0 = legacy keys).
     * Tracked only; key encoding is the renderer's business. */
    public int kittyKeyboardFlags() {
        Integer top = kittyFlags.peek();
        return top == null ? 0 : top;
    }

    /** The window title (OSC 0/1/2), "" if never set. */
    public String title() {
        return title;
    }

    /** Whether column {@code x} is a tab stop. */
    public boolean isTabStop(int x) {
        return x >= 0 && x < tabStops.length && tabStops[x];
    }

    /** True when the tab stops are the power-on ones (every 8 columns). */
    boolean defaultTabs() {
        for (int x = 0; x < tabStops.length; x++) {
            if (tabStops[x] != (x > 0 && x % 8 == 0)) {
                return false;
            }
        }
        return true;
    }

    /** The cursor saved on the main ({@code alternate == false}) or alternate screen, or
     * null when nothing was saved there. */
    public SavedCursor savedCursor(boolean alternate) {
        return alternate ? savedAlt : savedMain;
    }

    /** The packed charset state (as in {@link SavedCursor#charsets()}). */
    public int charsetState() {
        return packCharsets();
    }

    // =====================================================================================
    // Token dispatch
    // =====================================================================================

    private void applyFed(VtToken.Kind kind, byte[] b, int off, int len) {
        tokensApplied++;
        applyToken(kind, b, off, len);
    }

    /** Applies one token, {@code b[off, off + len)}. Sequences are parsed in place, so
     * {@code b} may be a buffer the tokenizer reuses. */
    private void applyToken(VtToken.Kind kind, byte[] b, int off, int len) {
        if (kind == VtToken.Kind.TEXT) {
            printUtf8(b, off, off + len);
            return;
        }
        flushUtf8();
        if (kind == VtToken.Kind.CONTROL) {
            control(b[off] & 0xFF);
            return;
        }
        if (off != 0) {
            // Sequence handlers index from 0; the tokenizer hands them over from its own
            // buffers, which start there. Never taken in practice.
            b = java.util.Arrays.copyOfRange(b, off, off + len);
        }
        switch (kind) {
            case CSI -> csi(b, len);
            case ESCAPE -> escape(b, len);
            case OSC -> osc(b, len);
            case STRING -> deviceControlString(b, len);
            default -> {
            }
        }
    }

    private void control(int c) {
        switch (c) {
            case 0x07 -> pendingBells++;
            case 0x08 -> backspace();
            case 0x09 -> tabForward(1);
            case 0x0A, 0x0B, 0x0C -> {
                index();
                if (newLineMode) {
                    cx = 0;
                }
            }
            case 0x0D -> {
                cx = 0;
                pendingWrap = false;
            }
            case 0x0E -> gl = 1; // SO: G1 into GL
            case 0x0F -> gl = 0; // SI: G0 into GL
            default -> {
                // NUL, ENQ, DEL and the rest: ignored.
            }
        }
    }

    // --- printing ---------------------------------------------------------------------

    private void printUtf8(byte[] b, int from, int n) {
        int i = from;
        while (i < n) {
            int c = b[i] & 0xFF;
            if (utf8Need == 0 && c < 0x80) {
                if (c < 0x20 || c == 0x7F) {
                    i++; // never produced by the tokenizer; ignore defensively
                    continue;
                }
                int end = i + 1;
                while (end < n && b[end] >= 0x20 && b[end] != 0x7F) { // signed: stops at >= 0x80
                    end++;
                }
                if (singleShift < 0 && charsets[gl] == CHARSET_ASCII && !insertMode) {
                    printAscii(b, i, end);
                } else {
                    for (int k = i; k < end; k++) {
                        print(b[k]);
                    }
                }
                i = end;
                continue;
            }
            decodeByte(c);
            i++;
        }
    }

    /** One byte of a multi-byte UTF-8 sequence (or a stray continuation/invalid byte). */
    private void decodeByte(int c) {
        if (utf8Need > 0) {
            if ((c & 0xC0) == 0x80) {
                utf8Code = (utf8Code << 6) | (c & 0x3F);
                if (--utf8Need == 0) {
                    int cp = utf8Code;
                    if (cp < utf8Min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
                        cp = 0xFFFD;
                    }
                    print(cp);
                }
                return;
            }
            // Truncated sequence: replace it and reprocess this byte.
            utf8Need = 0;
            print(0xFFFD);
            if (c < 0x80) {
                if (c >= 0x20 && c != 0x7F) {
                    print(c);
                }
                return;
            }
        }
        if (c >= 0xC2 && c <= 0xDF) {
            utf8Need = 1;
            utf8Code = c & 0x1F;
            utf8Min = 0x80;
        } else if (c >= 0xE0 && c <= 0xEF) {
            utf8Need = 2;
            utf8Code = c & 0x0F;
            utf8Min = 0x800;
        } else if (c >= 0xF0 && c <= 0xF4) {
            utf8Need = 3;
            utf8Code = c & 0x07;
            utf8Min = 0x10000;
        } else {
            print(0xFFFD);
        }
    }

    /** A control or sequence interrupted a partial UTF-8 character. */
    private void flushUtf8() {
        if (utf8Need > 0) {
            utf8Need = 0;
            print(0xFFFD);
        }
    }

    /** Fast path: printable ASCII with GL = ASCII and replace mode. */
    private void printAscii(byte[] b, int from, int to) {
        int i = from;
        while (i < to) {
            if (pendingWrap) {
                pendingWrap = false;
                if (autoWrap) {
                    wrapLine();
                }
            }
            Line line = screen.row(cy);
            int n = Math.min(columns - cx, to - i);
            line.breakWide(cx, cx + n);
            line.touch();
            int[] cps = line.codePoints;
            long[] styles = line.styles;
            String[] extras = line.extras;
            long p = pen;
            for (int k = 0; k < n; k++) {
                cps[cx + k] = b[i + k];
                styles[cx + k] = p;
                if (extras != null) {
                    extras[cx + k] = null;
                }
            }
            lastPrinted = b[i + n - 1];
            cx += n;
            i += n;
            if (cx >= columns) {
                cx = columns - 1;
                pendingWrap = true;
            }
        }
    }

    private void print(int cp) {
        if (cp < 0x80) {
            cp = mapCharset(cp);
        } else if (cp < 0xA0) {
            return; // C1 controls as UTF-8: not printable, not interpreted
        }
        singleShift = -1;
        int width = CharWidth.of(cp);
        if (width == 0 || joinsPrevious(cp)) {
            attach(cp);
            return;
        }
        if (pendingWrap) {
            pendingWrap = false;
            if (autoWrap) {
                wrapLine();
            }
        }
        if (width == 2 && cx == columns - 1) {
            if (!autoWrap) {
                return; // a wide character cannot be shown in the last column
            }
            // It does not fit: leave the last cell empty and wrap.
            screen.row(cy).erase(cx, cx + 1, Style.eraseStyle(pen));
            wrapLine();
        }
        Line line = screen.row(cy);
        if (insertMode) {
            line.insertCells(cx, width, Style.DEFAULT);
        }
        line.breakWide(cx, cx + width);
        if (width == 2) {
            line.setWide(cx, cp, pen);
        } else {
            line.set(cx, cp, pen);
        }
        lastPrinted = cp;
        cx += width;
        if (cx >= columns) {
            cx = columns - 1;
            pendingWrap = true;
        }
    }

    private int mapCharset(int cp) {
        int set = charsets[singleShift >= 0 ? singleShift : gl];
        if (set == CHARSET_DEC_GRAPHICS && cp >= 0x5F && cp <= 0x7E) {
            return DEC_GRAPHICS[cp - 0x5F];
        }
        if (set == CHARSET_UK && cp == '#') {
            return 0xA3;
        }
        return cp;
    }

    /** The cell a zero-width code point attaches to: the last one written before the
     * cursor (the lead of a wide character), or -1. */
    private int attachTarget() {
        int x = pendingWrap ? cx : cx - 1;
        if (x < 0) {
            return -1;
        }
        return screen.row(cy).isWideTail(x) ? x - 1 : x;
    }

    /** Code points that have a width but join the previous cell's grapheme: anything but
     * ASCII after a ZWJ, the second regional indicator of a flag, and emoji skin-tone
     * modifiers. (ASCII never joins, so the ASCII fast path needs no check.) */
    private boolean joinsPrevious(int cp) {
        if (cp < 0x80) {
            return false;
        }
        int x = attachTarget();
        if (x < 0) {
            return false;
        }
        Line line = screen.row(cy);
        if (line.lastExtra(x) == 0x200D) {
            return true;
        }
        if (isRegionalIndicator(cp)) {
            return isRegionalIndicator(line.codePoint(x)) && !line.hasExtras(x);
        }
        return cp >= 0x1F3FB && cp <= 0x1F3FF && line.width(x) == 2;
    }

    private static boolean isRegionalIndicator(int cp) {
        return cp >= 0x1F1E6 && cp <= 0x1F1FF;
    }

    private void attach(int cp) {
        int x = attachTarget();
        if (x < 0) {
            return;
        }
        Line line = screen.row(cy);
        if (line.codePoint(x) != 0) {
            line.attach(x, cp);
        }
    }

    /** The deferred wrap: mark the row soft-wrapped and move to the next line. */
    private void wrapLine() {
        screen.row(cy).setWrapped(true);
        cx = 0;
        index();
    }

    private void repeatLast(int count) {
        if (lastPrinted <= 0) {
            return;
        }
        int cp = lastPrinted;
        count = Math.min(count, columns * rows);
        for (int i = 0; i < count; i++) {
            print(cp);
        }
    }

    // --- cursor movement --------------------------------------------------------------

    /** LF/IND: down one row, scrolling the region when on its bottom margin. */
    private void index() {
        pendingWrap = false;
        if (cy == scrollBottom) {
            scrollUp(1);
        } else if (cy < rows - 1) {
            cy++;
        }
    }

    /** RI: up one row, scrolling the region down when on its top margin. */
    private void reverseIndex() {
        pendingWrap = false;
        if (cy == scrollTop) {
            screen.scrollDown(scrollTop, scrollBottom, 1, Style.eraseStyle(pen));
        } else if (cy > 0) {
            cy--;
        }
    }

    private void scrollUp(int n) {
        boolean toHistory = screen == main && scrollTop == 0;
        screen.scrollUp(scrollTop, scrollBottom, n, Style.eraseStyle(pen), toHistory);
    }

    private void backspace() {
        pendingWrap = false;
        if (cx > 0) {
            cx--;
        }
    }

    private void tabForward(int n) {
        pendingWrap = false;
        for (int i = 0; i < n && cx < columns - 1; i++) {
            do {
                cx++;
            } while (cx < columns - 1 && !tabStops[cx]);
        }
    }

    private void tabBackward(int n) {
        pendingWrap = false;
        for (int i = 0; i < n && cx > 0; i++) {
            do {
                cx--;
            } while (cx > 0 && !tabStops[cx]);
        }
    }

    private void cursorUp(int n) {
        pendingWrap = false;
        int limit = cy >= scrollTop ? scrollTop : 0;
        cy = Math.max(limit, cy - n);
    }

    private void cursorDown(int n) {
        pendingWrap = false;
        int limit = cy <= scrollBottom ? scrollBottom : rows - 1;
        cy = Math.min(limit, cy + n);
    }

    private void setColumn(int x) {
        pendingWrap = false;
        cx = clamp(x, 0, columns - 1);
    }

    /** Moves to row {@code y} (0-based), relative to the region in origin mode. */
    private void setRow(int y) {
        pendingWrap = false;
        if (originMode) {
            cy = clamp(scrollTop + y, scrollTop, scrollBottom);
        } else {
            cy = clamp(y, 0, rows - 1);
        }
    }

    private void home() {
        setRow(0);
        setColumn(0);
    }

    // --- saved cursor -----------------------------------------------------------------

    private void saveCursor() {
        SavedCursor saved = new SavedCursor(cx, cy, pendingWrap, pen, autoWrap, originMode, packCharsets());
        if (screen == alt) {
            savedAlt = saved;
        } else {
            savedMain = saved;
        }
    }

    private void restoreCursor() {
        SavedCursor saved = screen == alt ? savedAlt : savedMain;
        if (saved == null) {
            // Nothing saved: home, default pen, origin off, default charsets.
            originMode = false;
            pen = Style.DEFAULT;
            resetCharsets();
            cx = 0;
            cy = 0;
            pendingWrap = false;
            return;
        }
        cx = Math.min(saved.column(), columns - 1);
        cy = Math.min(saved.row(), rows - 1);
        pendingWrap = saved.pendingWrap() && cx == columns - 1;
        pen = saved.style();
        autoWrap = saved.autoWrap();
        originMode = saved.originMode();
        if (originMode && (cy < scrollTop || cy > scrollBottom)) {
            // As xterm's CursorRestore: in origin mode the cursor is confined to the region.
            cy = clamp(cy, scrollTop, scrollBottom);
            pendingWrap = false;
        }
        unpackCharsets(saved.charsets());
    }

    private int packCharsets() {
        return charsets[0] | charsets[1] << 2 | charsets[2] << 4 | charsets[3] << 6 | gl << 8;
    }

    private void unpackCharsets(int packed) {
        for (int i = 0; i < 4; i++) {
            charsets[i] = (packed >> (2 * i)) & 3;
        }
        gl = (packed >> 8) & 3;
        singleShift = -1;
    }

    private void resetCharsets() {
        java.util.Arrays.fill(charsets, CHARSET_ASCII);
        gl = 0;
        singleShift = -1;
    }

    // --- screens ----------------------------------------------------------------------

    private void enterAlternate(boolean clear) {
        if (screen != alt) {
            screen = alt;
        }
        if (clear) {
            clearScreen(alt, Style.DEFAULT);
        }
    }

    private void leaveAlternate(boolean clear) {
        if (screen == alt) {
            if (clear) {
                clearScreen(alt, Style.DEFAULT);
            }
            screen = main;
        }
    }

    private void clearScreen(ScreenBuffer buffer, long fill) {
        for (int y = 0; y < rows; y++) {
            buffer.row(y).clear(fill);
        }
    }

    // --- erase ------------------------------------------------------------------------

    private void eraseInDisplay(int mode) {
        long fill = Style.eraseStyle(pen);
        pendingWrap = false;
        switch (mode) {
            case 0 -> {
                Line line = screen.row(cy);
                line.erase(cx, columns, fill);
                line.setWrapped(false);
                for (int y = cy + 1; y < rows; y++) {
                    screen.row(y).clear(fill);
                }
            }
            case 1 -> {
                for (int y = 0; y < cy; y++) {
                    screen.row(y).clear(fill);
                }
                screen.row(cy).erase(0, cx + 1, fill);
            }
            case 2 -> {
                if (screen == main) {
                    // As VTE and jediterm do: the screen's content goes to the scrollback
                    // instead of being lost (the region is irrelevant here).
                    int last = lastNonBlankRow(main);
                    if (last > 0 || !isBlankLine(main.row(0))) {
                        main.scrollUp(0, rows - 1, last + 1, Style.DEFAULT, true);
                    }
                }
                clearScreen(screen, fill);
            }
            case 3 -> screen.clearHistory();
            default -> {
            }
        }
    }

    private void eraseInLine(int mode) {
        long fill = Style.eraseStyle(pen);
        pendingWrap = false;
        Line line = screen.row(cy);
        switch (mode) {
            case 0 -> {
                line.erase(cx, columns, fill);
                line.setWrapped(false);
            }
            case 1 -> line.erase(0, cx + 1, fill);
            case 2 -> {
                line.erase(0, columns, fill);
                line.setWrapped(false);
            }
            default -> {
            }
        }
    }

    private void insertLines(int n) {
        if (cy < scrollTop || cy > scrollBottom) {
            return;
        }
        screen.scrollDown(cy, scrollBottom, n, Style.eraseStyle(pen));
        cx = 0;
        pendingWrap = false;
    }

    private void deleteLines(int n) {
        if (cy < scrollTop || cy > scrollBottom) {
            return;
        }
        screen.scrollUp(cy, scrollBottom, n, Style.eraseStyle(pen), false);
        cx = 0;
        pendingWrap = false;
    }

    // --- reset ------------------------------------------------------------------------

    /** Power-on state of everything but the screens' contents and the title. */
    private void resetState() {
        cx = 0;
        cy = 0;
        pendingWrap = false;
        pen = Style.DEFAULT;
        savedMain = null;
        savedAlt = null;
        lastPrinted = 0;
        scrollTop = 0;
        scrollBottom = rows - 1;
        tabStops = defaultTabStops(columns);
        resetCharsets();
        autoWrap = true;
        originMode = false;
        insertMode = false;
        newLineMode = false;
        applicationCursorKeys = false;
        applicationKeypad = false;
        cursorVisible = true;
        cursorBlink = false;
        cursorShape = 0;
        reverseVideo = false;
        bracketedPaste = false;
        focusReporting = false;
        synchronizedOutput = false;
        colorSchemeUpdates = false;
        mouseTracking = MouseTracking.NONE;
        mouseEncoding = MouseEncoding.DEFAULT;
        kittyFlags.clear();
        titleStack.clear();
    }

    /** RIS: everything back to power-on, both screens and the history cleared. The title is
     * kept (it is the window's, as in jediterm and {@link ModeTracker}). */
    private void fullReset() {
        screen = main;
        clearScreen(main, Style.DEFAULT);
        clearScreen(alt, Style.DEFAULT);
        main.clearHistory();
        resetState();
    }

    /** DECSTR. */
    private void softReset() {
        cursorVisible = true;
        insertMode = false;
        originMode = false;
        autoWrap = true;
        applicationKeypad = false;
        applicationCursorKeys = false;
        scrollTop = 0;
        scrollBottom = rows - 1;
        pen = Style.DEFAULT;
        resetCharsets();
        if (screen == alt) {
            savedAlt = null;
        } else {
            savedMain = null;
        }
    }

    private static boolean[] defaultTabStops(int columns) {
        boolean[] stops = new boolean[columns];
        for (int x = 8; x < columns; x += 8) {
            stops[x] = true;
        }
        return stops;
    }

    // =====================================================================================
    // ESC
    // =====================================================================================

    private void escape(byte[] b, int len) {
        if (len == 2) {
            switch (b[1]) {
                case '7' -> saveCursor();
                case '8' -> restoreCursor();
                case 'D' -> index();
                case 'E' -> {
                    index();
                    cx = 0;
                }
                case 'M' -> reverseIndex();
                case 'H' -> tabStops[cx] = true;
                case 'c' -> fullReset();
                case '=' -> applicationKeypad = true;
                case '>' -> applicationKeypad = false;
                case 'N' -> singleShift = 2;
                case 'O' -> singleShift = 3;
                case 'n' -> gl = 2;
                case 'o' -> gl = 3;
                default -> {
                    // ESC \ (a lone ST), ESC F and others: ignored.
                }
            }
            return;
        }
        if (len == 3) {
            int set = switch (b[2]) {
                case '0' -> CHARSET_DEC_GRAPHICS;
                case 'A' -> CHARSET_UK;
                default -> CHARSET_ASCII;
            };
            switch (b[1]) {
                case '(' -> charsets[0] = set;
                case ')', '-' -> charsets[1] = set;
                case '*', '.' -> charsets[2] = set;
                case '+', '/' -> charsets[3] = set;
                case '#' -> {
                    if (b[2] == '8') {
                        alignmentTest();
                    }
                }
                default -> {
                }
            }
        }
    }

    /** DECALN: margins reset, cursor home, the screen filled with 'E'. */
    private void alignmentTest() {
        scrollTop = 0;
        scrollBottom = rows - 1;
        originMode = false;
        for (int y = 0; y < rows; y++) {
            Line line = screen.row(y);
            line.clear(Style.DEFAULT);
            java.util.Arrays.fill(line.codePoints, 'E');
            line.touch();
        }
        home();
    }

    // =====================================================================================
    // CSI
    // =====================================================================================

    /** Parses {@code ESC [ prefix? params intermediates final} into {@link #params}; returns
     * {@code prefix << 16 | intermediate << 8 | final}, or -1 for a malformed sequence. */
    private int parseCsi(byte[] b, int len) {
        int end = len - 1;
        int i = 2;
        int prefix = 0;
        if (i < end && b[i] >= '<' && b[i] <= '?') {
            prefix = b[i++];
        }
        paramCount = 0;
        int current = -1;
        boolean nextIsSub = false;
        boolean any = false;
        int intermediate = 0;
        for (; i < end; i++) {
            int c = b[i];
            if (c >= '0' && c <= '9') {
                if (intermediate != 0) {
                    return -1;
                }
                current = current < 0 ? c - '0' : Math.min(current * 10 + (c - '0'), 0xFFFF);
                any = true;
            } else if (c == ';' || c == ':') {
                if (intermediate != 0) {
                    return -1;
                }
                pushParam(current, nextIsSub);
                current = -1;
                nextIsSub = c == ':';
                any = true;
            } else if (c >= 0x20 && c <= 0x2F) {
                intermediate = c;
            } else {
                return -1; // a private marker in the middle, etc.
            }
        }
        if (any) {
            pushParam(current, nextIsSub);
        }
        return prefix << 16 | intermediate << 8 | (b[end] & 0xFF);
    }

    private void pushParam(int value, boolean sub) {
        if (paramCount < MAX_PARAMS) {
            params[paramCount] = value;
            subParam[paramCount] = sub;
            paramCount++;
        }
    }

    /** Parameter {@code k}, or {@code def} when absent. */
    private int arg(int k, int def) {
        return k < paramCount && params[k] >= 0 ? params[k] : def;
    }

    /** Parameter {@code k} where 0 and absent both mean 1 (counts). */
    private int count(int k) {
        int v = arg(k, 1);
        return v == 0 ? 1 : v;
    }

    private boolean hasSubParams() {
        for (int k = 0; k < paramCount; k++) {
            if (subParam[k]) {
                return true;
            }
        }
        return false;
    }

    private void csi(byte[] b, int len) {
        int key = parseCsi(b, len);
        if (key < 0) {
            return;
        }
        int fin = key & 0xFF;
        int intermediate = (key >> 8) & 0xFF;
        int prefix = key >> 16;
        if (fin == 'm' && prefix == 0 && intermediate == 0) {
            sgr();
            return;
        }
        if (hasSubParams()) {
            return;
        }
        if (fin == 'c' && prefix != '>') {
            // DA1. QueryFilter strips every CSI … c without a '>' prefix, so answer them all.
            reply(DA1_REPLY);
            return;
        }
        switch (prefix) {
            case 0 -> {
                if (intermediate == 0) {
                    csiPlain(fin);
                } else {
                    csiIntermediate(intermediate, fin);
                }
            }
            case '?' -> {
                if (intermediate == 0) {
                    csiPrivate(fin);
                } else if (intermediate == '$' && fin == 'p') {
                    requestMode(true);
                }
            }
            case '>' -> csiGreater(fin);
            case '<' -> {
                if (fin == 'u' && intermediate == 0) {
                    for (int i = Math.min(count(0), kittyFlags.size()); i > 0; i--) {
                        kittyFlags.pop();
                    }
                }
            }
            case '=' -> {
                if (fin == 'u' && intermediate == 0) {
                    setKittyFlags(arg(0, 0), arg(1, 1));
                }
            }
            default -> {
            }
        }
    }

    private void csiPlain(int fin) {
        switch (fin) {
            case '@' -> {
                pendingWrap = false;
                screen.row(cy).insertCells(cx, count(0), Style.eraseStyle(pen));
            }
            case 'A' -> cursorUp(count(0));
            case 'B', 'e' -> cursorDown(count(0));
            case 'C', 'a' -> setColumn(cx + count(0));
            case 'D' -> setColumn(cx - count(0));
            case 'E' -> {
                cursorDown(count(0));
                cx = 0;
            }
            case 'F' -> {
                cursorUp(count(0));
                cx = 0;
            }
            case 'G', '`' -> setColumn(count(0) - 1);
            case 'H', 'f' -> {
                setRow(count(0) - 1);
                setColumn(count(1) - 1);
            }
            case 'I' -> tabForward(count(0));
            case 'J' -> eraseInDisplay(arg(0, 0));
            case 'K' -> eraseInLine(arg(0, 0));
            case 'L' -> insertLines(count(0));
            case 'M' -> deleteLines(count(0));
            case 'P' -> {
                pendingWrap = false;
                screen.row(cy).deleteCells(cx, count(0), Style.eraseStyle(pen));
            }
            case 'S' -> scrollUp(count(0));
            case 'T' -> {
                if (paramCount <= 1) { // more parameters: xterm's mouse highlight tracking
                    screen.scrollDown(scrollTop, scrollBottom, count(0), Style.eraseStyle(pen));
                }
            }
            case 'X' -> {
                pendingWrap = false;
                screen.row(cy).erase(cx, cx + count(0), Style.eraseStyle(pen));
            }
            case 'Z' -> tabBackward(count(0));
            case 'b' -> repeatLast(count(0));
            case 'd' -> setRow(count(0) - 1);
            case 'g' -> {
                int mode = arg(0, 0);
                if (mode == 0) {
                    tabStops[cx] = false;
                } else if (mode == 3) {
                    java.util.Arrays.fill(tabStops, false);
                }
            }
            case 'h', 'l' -> {
                boolean set = fin == 'h';
                for (int k = 0; k < paramCount; k++) {
                    switch (params[k]) {
                        case 4 -> insertMode = set;
                        case 20 -> newLineMode = set;
                        default -> {
                        }
                    }
                }
            }
            case 'n' -> deviceStatus(arg(0, 0));
            case 'r' -> setScrollRegion(arg(0, 1), arg(1, rows));
            case 's' -> saveCursor();
            case 't' -> windowOps();
            case 'u' -> {
                if (paramCount == 0) {
                    restoreCursor();
                }
            }
            default -> {
            }
        }
    }

    private void csiIntermediate(int intermediate, int fin) {
        if (intermediate == ' ' && fin == 'q') {
            int ps = arg(0, 0);
            if (ps <= 6) {
                cursorShape = ps == 0 ? 1 : ps; // 0 and 1 both mean a blinking block
            }
        } else if (intermediate == '!' && fin == 'p') {
            softReset();
        } else if (intermediate == '$' && fin == 'p') {
            requestMode(false);
        }
    }

    private void csiPrivate(int fin) {
        switch (fin) {
            case 'h', 'l' -> {
                boolean set = fin == 'h';
                for (int k = 0; k < paramCount; k++) {
                    decPrivateMode(params[k], set);
                }
            }
            case 'J' -> eraseInDisplay(arg(0, 0)); // DECSED: no protected cells, so plain ED
            case 'K' -> eraseInLine(arg(0, 0));    // DECSEL
            case 'n' -> {
                if (arg(0, 0) == 6 && replyScope == ReplyScope.FULL) {
                    reply("\u001b[?" + reportRow() + ";" + (cx + 1) + ";1R");
                } else if (arg(0, 0) == 996 && colorScheme != null && replySink != null) {
                    // Any scope: only a client sets a scheme (the daemon never knows its theme).
                    pendingReplies.add(colorSchemeReport(colorScheme));
                }
            }
            case 'u' -> {
                if (replyScope == ReplyScope.FULL) {
                    reply("\u001b[?" + kittyKeyboardFlags() + "u");
                }
            }
            default -> {
            }
        }
    }

    private void csiGreater(int fin) {
        switch (fin) {
            case 'c' -> {
                if (arg(0, 0) == 0) {
                    reply(DA2_REPLY);
                }
            }
            case 'q' -> {
                if (replyScope == ReplyScope.FULL) {
                    reply("\u001bP>|" + XTVERSION + "\u001b\\");
                }
            }
            case 'u' -> {
                if (kittyFlags.size() >= MAX_KITTY_STACK) {
                    kittyFlags.removeLast();
                }
                kittyFlags.push(arg(0, 0));
            }
            default -> {
                // CSI > Ps m (modifyOtherKeys) and friends: ignored.
            }
        }
    }

    private void setKittyFlags(int flags, int mode) {
        int current = kittyKeyboardFlags();
        int next = switch (mode) {
            case 2 -> current | flags;
            case 3 -> current & ~flags;
            default -> flags;
        };
        if (!kittyFlags.isEmpty()) {
            kittyFlags.pop();
        }
        kittyFlags.push(next);
    }

    private void decPrivateMode(int mode, boolean set) {
        switch (mode) {
            case 1 -> applicationCursorKeys = set;
            case 5 -> reverseVideo = set;
            case 6 -> {
                originMode = set;
                home();
            }
            case 7 -> autoWrap = set;
            case 9 -> mouseTracking = set ? MouseTracking.X10 : MouseTracking.NONE;
            case 12 -> cursorBlink = set;
            case 25 -> cursorVisible = set;
            case 47 -> {
                if (set) {
                    enterAlternate(false);
                } else {
                    leaveAlternate(false);
                }
            }
            case 1047 -> {
                if (set) {
                    enterAlternate(false);
                } else {
                    leaveAlternate(true);
                }
            }
            case 1048 -> {
                if (set) {
                    saveCursor();
                } else {
                    restoreCursor();
                }
            }
            case 1049 -> {
                if (set) {
                    saveCursor();
                    enterAlternate(true);
                } else {
                    leaveAlternate(false);
                    restoreCursor();
                }
            }
            case 1000 -> mouseTracking = set ? MouseTracking.NORMAL : MouseTracking.NONE;
            case 1002 -> mouseTracking = set ? MouseTracking.BUTTON_MOTION : MouseTracking.NONE;
            case 1003 -> mouseTracking = set ? MouseTracking.ANY_MOTION : MouseTracking.NONE;
            case 1004 -> focusReporting = set;
            case 1005 -> mouseEncoding = set ? MouseEncoding.UTF8 : MouseEncoding.DEFAULT;
            case 1006 -> mouseEncoding = set ? MouseEncoding.SGR : MouseEncoding.DEFAULT;
            case 1015 -> mouseEncoding = set ? MouseEncoding.URXVT : MouseEncoding.DEFAULT;
            case 2004 -> bracketedPaste = set;
            case 2026 -> synchronizedOutput = set;
            case 2031 -> colorSchemeUpdates = set;
            default -> {
                // 3 (DECCOLM: no 80/132 resize), 4, 8, 45, 1001, 1007, 1034, 1039, 9001, …
            }
        }
    }

    /** DECRQM reply (FULL scope): 1 set, 2 reset, 0 not recognised. */
    private void requestMode(boolean dec) {
        if (replyScope != ReplyScope.FULL) {
            return;
        }
        int mode = arg(0, 0);
        int value = dec ? decModeValue(mode) : switch (mode) {
            case 4 -> insertMode ? 1 : 2;
            case 20 -> newLineMode ? 1 : 2;
            default -> 0;
        };
        reply("\u001b[" + (dec ? "?" : "") + mode + ";" + value + "$y");
    }

    private int decModeValue(int mode) {
        Boolean on = switch (mode) {
            case 1 -> applicationCursorKeys;
            case 5 -> reverseVideo;
            case 6 -> originMode;
            case 7 -> autoWrap;
            case 9 -> mouseTracking == MouseTracking.X10;
            case 12 -> cursorBlink;
            case 25 -> cursorVisible;
            case 47, 1047, 1049 -> screen == alt;
            case 1000 -> mouseTracking == MouseTracking.NORMAL;
            case 1002 -> mouseTracking == MouseTracking.BUTTON_MOTION;
            case 1003 -> mouseTracking == MouseTracking.ANY_MOTION;
            case 1004 -> focusReporting;
            case 1005 -> mouseEncoding == MouseEncoding.UTF8;
            case 1006 -> mouseEncoding == MouseEncoding.SGR;
            case 1015 -> mouseEncoding == MouseEncoding.URXVT;
            case 2004 -> bracketedPaste;
            case 2026 -> synchronizedOutput;
            default -> null;
        };
        return on == null ? 0 : on ? 1 : 2;
    }

    private void deviceStatus(int code) {
        if (code == 5) {
            reply("\u001b[0n");
        } else if (code == 6) {
            reply("\u001b[" + reportRow() + ";" + (cx + 1) + "R");
        }
    }

    /** The cursor row for a position report: 1-based, relative to the region in DECOM. */
    private int reportRow() {
        return (originMode ? cy - scrollTop : cy) + 1;
    }

    private void setScrollRegion(int top, int bottom) {
        if (top == 0) {
            top = 1;
        }
        if (bottom == 0 || bottom > rows) {
            bottom = rows;
        }
        if (top >= bottom) {
            return; // xterm ignores a region of fewer than two lines
        }
        scrollTop = top - 1;
        scrollBottom = bottom - 1;
        home();
    }

    /** XTWINOPS: only the title stack (22/23); resizes and reports are ignored. */
    private void windowOps() {
        int op = arg(0, 0);
        int which = arg(1, 0);
        if (which != 0 && which != 2) {
            return;
        }
        if (op == 22) {
            if (titleStack.size() >= MAX_TITLE_STACK) {
                titleStack.removeLast();
            }
            titleStack.push(title);
        } else if (op == 23 && !titleStack.isEmpty()) {
            setTitle(titleStack.pop());
        }
    }

    // --- SGR --------------------------------------------------------------------------

    private void sgr() {
        if (paramCount == 0) {
            pen = Style.DEFAULT;
            return;
        }
        long s = pen;
        for (int k = 0; k < paramCount; k++) {
            int end = k + 1;
            while (end < paramCount && subParam[end]) {
                end++;
            }
            int subCount = end - k - 1;
            int a = Math.max(0, params[k]);
            switch (a) {
                case 0 -> s = Style.DEFAULT;
                case 1 -> s |= Style.BOLD;
                case 2 -> s |= Style.DIM;
                case 3 -> s |= Style.ITALIC;
                case 4 -> s = Style.withUnderline(s, subCount > 0 ? Math.min(Math.max(0, params[k + 1]), 5)
                        : Style.UNDERLINE_SINGLE);
                case 5 -> s = (s | Style.BLINK) & ~Style.RAPID_BLINK;
                case 6 -> s = (s | Style.RAPID_BLINK) & ~Style.BLINK;
                case 7 -> s |= Style.INVERSE;
                case 8 -> s |= Style.INVISIBLE;
                case 9 -> s |= Style.STRIKETHROUGH;
                case 21 -> s = Style.withUnderline(s, Style.UNDERLINE_DOUBLE);
                case 22 -> s &= ~(Style.BOLD | Style.DIM);
                case 23 -> s &= ~Style.ITALIC;
                case 24 -> s = Style.withUnderline(s, Style.UNDERLINE_NONE);
                case 25 -> s &= ~(Style.BLINK | Style.RAPID_BLINK);
                case 27 -> s &= ~Style.INVERSE;
                case 28 -> s &= ~Style.INVISIBLE;
                case 29 -> s &= ~Style.STRIKETHROUGH;
                case 30, 31, 32, 33, 34, 35, 36, 37 -> s = Style.withForeground(s, Style.indexed(a - 30));
                case 39 -> s = Style.withForeground(s, Style.COLOR_DEFAULT);
                case 40, 41, 42, 43, 44, 45, 46, 47 -> s = Style.withBackground(s, Style.indexed(a - 40));
                case 49 -> s = Style.withBackground(s, Style.COLOR_DEFAULT);
                case 53 -> s |= Style.OVERLINE;
                case 55 -> s &= ~Style.OVERLINE;
                case 90, 91, 92, 93, 94, 95, 96, 97 -> s = Style.withForeground(s, Style.indexed(a - 90 + 8));
                case 100, 101, 102, 103, 104, 105, 106, 107 ->
                        s = Style.withBackground(s, Style.indexed(a - 100 + 8));
                case 38, 48, 58 -> {
                    int color;
                    if (subCount > 0) {
                        color = colonColor(k + 1, subCount);
                    } else {
                        color = semicolonColor(k + 1);
                        end = Math.min(paramCount, k + 1 + semicolonColorLength(k + 1));
                    }
                    if (color >= 0) {
                        if (a == 38) {
                            s = Style.withForeground(s, color);
                        } else if (a == 48) {
                            s = Style.withBackground(s, color);
                        } // 58: underline colour, parsed and ignored
                    }
                }
                default -> {
                    // 10–20 fonts, 26, 50–52, 54, 59, 60–65 ideograms, 73–75: ignored.
                }
            }
            k = end - 1;
        }
        pen = s;
    }

    /** {@code 38:5:n} / {@code 38:2:[cs]:r:g:b} with sub-parameters starting at {@code k}. */
    private int colonColor(int k, int subCount) {
        int space = params[k];
        if (space == 5 && subCount >= 2) {
            int n = params[k + 1];
            return n >= 0 && n <= 255 ? Style.indexed(n) : -1;
        }
        if (space == 2) {
            int first = subCount >= 5 ? k + 2 : k + 1; // with or without the colour-space id
            if (first + 2 < k + subCount + 1) {
                return rgbOrInvalid(params[first], params[first + 1], params[first + 2]);
            }
        }
        return -1;
    }

    /** {@code 38;5;n} / {@code 38;2;r;g;b} with the selector at {@code k}. */
    private int semicolonColor(int k) {
        int space = arg(k, -1);
        if (space == 5) {
            int n = arg(k + 1, 0);
            return n <= 255 ? Style.indexed(n) : -1;
        }
        if (space == 2) {
            return rgbOrInvalid(arg(k + 1, 0), arg(k + 2, 0), arg(k + 3, 0));
        }
        return -1;
    }

    private int semicolonColorLength(int k) {
        return switch (arg(k, -1)) {
            case 5 -> 2;
            case 2 -> 4;
            default -> 0;
        };
    }

    private static int rgbOrInvalid(int r, int g, int b) {
        r = Math.max(0, r);
        g = Math.max(0, g);
        b = Math.max(0, b);
        return r <= 255 && g <= 255 && b <= 255 ? Style.rgb(r, g, b) : -1;
    }

    /**
     * DCS/APC/PM/SOS are consumed and ignored, except XTGETTCAP ({@code DCS + q … ST}), which
     * is answered "invalid request" ({@code DCS 0 + r ST}) so a prober moves on at once
     * instead of waiting for its timeout (as the daemon's jediterm did).
     */
    private void deviceControlString(byte[] b, int len) {
        if (len >= 4 && b[1] == 'P' && b[2] == '+' && b[3] == 'q') {
            reply(XTGETTCAP_INVALID);
        }
    }

    // =====================================================================================
    // OSC
    // =====================================================================================

    private void osc(byte[] b, int len) {
        int end = len;
        if (end > 2 && b[end - 1] == 0x07) {
            end--;
        } else if (end > 3 && b[end - 1] == '\\' && b[end - 2] == 0x1B) {
            end -= 2;
        }
        int i = 2;
        int ps = 0;
        boolean digits = false;
        while (i < end && b[i] >= '0' && b[i] <= '9') {
            ps = Math.min(ps * 10 + (b[i] - '0'), 100_000);
            digits = true;
            i++;
        }
        if (!digits || (i < end && b[i] != ';')) {
            return;
        }
        if (ps <= 2 && i < end) {
            String text = new String(b, i + 1, end - i - 1, StandardCharsets.UTF_8);
            setTitle(text.length() > MAX_TITLE_LENGTH ? text.substring(0, MAX_TITLE_LENGTH) : text);
        }
        // 4, 7, 8, 10–12, 52, 104, 110–112, 133, …: parsed and ignored here (the session
        // tracks OSC 7 through ModeTracker; nothing is answered).
    }

    private void setTitle(String newTitle) {
        if (!newTitle.equals(title)) {
            title = newTitle;
            titleDirty = true;
        }
    }

    // =====================================================================================
    // helpers
    // =====================================================================================

    private void reply(String s) {
        reply(s.getBytes(StandardCharsets.US_ASCII));
    }

    private void reply(byte[] bytes) {
        if (replySink != null && replyScope != ReplyScope.CLIENT) {
            pendingReplies.add(bytes);
        }
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }
}
