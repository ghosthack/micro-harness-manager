package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.Line;
import io.github.ghosthack.microhm.vt.Style;
import io.github.ghosthack.microhm.vt.TerminalEmulator;
import io.github.ghosthack.microhm.vt.TerminalEmulator.MouseTracking;
import io.github.ghosthack.microhm.vt.TerminalListener;

import javax.swing.BoundedRangeModel;
import javax.swing.DefaultBoundedRangeModel;
import javax.swing.JComponent;
import javax.swing.JMenuItem;
import javax.swing.JPopupMenu;
import javax.swing.KeyStroke;
import javax.swing.SwingUtilities;
import javax.swing.Timer;
import java.awt.AWTEvent;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.Font;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.Insets;
import java.awt.Point;
import java.awt.Rectangle;
import java.awt.RenderingHints;
import java.awt.Toolkit;
import java.awt.datatransfer.DataFlavor;
import java.awt.datatransfer.StringSelection;
import java.awt.event.FocusEvent;
import java.awt.event.InputMethodEvent;
import java.awt.event.InputMethodListener;
import java.awt.event.KeyEvent;
import java.awt.event.MouseEvent;
import java.awt.event.MouseWheelEvent;
import java.awt.font.TextHitInfo;
import java.awt.geom.Path2D;
import java.awt.im.InputMethodRequests;
import java.nio.charset.StandardCharsets;
import java.text.AttributedCharacterIterator;
import java.text.AttributedString;
import java.text.CharacterIterator;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * A Swing terminal over a {@link TerminalEmulator}: paints its cells, turns keyboard, mouse,
 * paste and input-method events into program input, and keeps the local view state — the
 * scrollback offset, the selection, the cursor blink. Nothing here knows about sessions or
 * settings; {@link SessionTerminal} feeds the emulator from a connection and maps the app's
 * settings onto the setters.
 *
 * <h2>Threading</h2>
 * The emulator is fed on a reader thread; it calls {@link TerminalListener#contentChanged()}
 * there, which only queues one frame on the EDT (an atomic flag, so a burst of output is one
 * pending frame). The frame is rate-limited to ~60 fps, held while the program is mid
 * synchronized update (DECSET 2026, capped at 150 ms so a stuck program still paints), and
 * then adjusts the scrollback anchor and the scrollbar and repaints what changed (see
 * Damage below). Painting holds the emulator lock for the duration of one frame. Everything
 * else here is EDT-only. While the view is not showing (a hidden card) frames are skipped
 * entirely — the pending one is left queued, so output costs the EDT nothing — and one
 * catch-up frame with a full repaint runs when it shows again.
 *
 * <h2>Damage</h2>
 * Each frame remembers, per visible row, the {@link Line} object it showed and that line's
 * {@link Line#version() version}; the next frame repaints only the rows whose line or version
 * differ (one union rectangle, a row of margin either side for glyphs that overflow their
 * cell) plus the old and new cursor rows. Anything global — the grid size, the scroll
 * position or history growth, reverse video, the alternate screen, the cursor's mode, the
 * selection, focus, the component's size, fonts or colours — makes the frame repaint
 * everything. Other changes (selection, theme, scrolling by the user) repaint everything
 * themselves, as before.
 *
 * <h2>Painting</h2>
 * Per row in the clip: background runs (merged per resolved colour), then text runs —
 * consecutive single-width cells of one colour/style drawn with one call when the font's
 * advances match the cell width exactly — with wide characters, combining sequences,
 * fallback-font characters and box drawing ({@link BoxDrawing}) drawn per cell; decorations
 * (underline styles, strikethrough, overline) on top; then the cursor and any input-method
 * composition at the cursor.
 */
public final class TerminalView extends JComponent implements TerminalListener {

    /** Where the view sends program input. Called on the EDT. */
    public interface Output {
        void write(byte[] bytes);

        /** The grid changed to {@code columns} × {@code rows} (debounced). */
        void resize(int columns, int rows);
    }

    static final int MIN_COLUMNS = 2;
    static final int MIN_ROWS = 2;
    private static final long FRAME_NANOS = 16_000_000L;
    private static final long SYNC_HOLD_NANOS = 150_000_000L;
    private static final int BLINK_MS = 530;
    private static final int WHEEL_LINES = 3;
    private static final boolean MAC = System.getProperty("os.name", "")
            .toLowerCase(Locale.ROOT).startsWith("mac");

    private final TerminalEmulator emulator;
    private final Output output;
    private final TerminalColors colors;
    private TerminalFonts fonts;
    private boolean mouseWheelDisabled;
    private volatile Consumer<String> titleListener;

    // Frames.
    private final AtomicBoolean frameQueued = new AtomicBoolean();
    private final Timer frameTimer;
    private long lastFrameNanos;
    private long syncSinceNanos;
    private long frames;

    // Damage tracking: what the last frame asked to be painted (see the class comment).
    private FrameKey paintedKey;
    private Line[] paintedLines = new Line[0];
    private long[] paintedVersions = new long[0];
    private int paintedCursorRow = -1;
    /** Bumped by changes that repaint everything on their own (fonts, colours, scale), so
     * the next frame also treats its snapshot as stale. */
    private int viewStamp;
    /** Output arrived while the view was not showing; a catch-up frame is owed. */
    private boolean catchUpPending;
    /** Tests: stands in for {@link #isShowing()} (headless components never show). */
    private Boolean showingOverride;
    private long fullFrames;

    // Scrollback: lines back from the live screen (0 = live).
    private int scrollOffset;
    private long lastHistoryAdded;
    private final DefaultBoundedRangeModel scrollModel = new DefaultBoundedRangeModel(0, 1, 0, 1);
    private boolean updatingScrollModel;

    // Size.
    private final Timer resizeTimer;

    // Selection, in absolute rows (historyLinesAdded + index) and caret columns.
    private enum SelectMode { CHAR, WORD, LINE }

    private boolean selecting;
    private boolean selectionActive;
    private SelectMode selectMode = SelectMode.CHAR;
    private long anchorRow;
    private int anchorColumn;
    private long anchorEndRow;
    private int anchorEndColumn;
    private long selStartRow;
    private int selStartColumn;
    private long selEndRow;
    private int selEndColumn;

    // Mouse reporting.
    private int reportedButton = -1;
    private int lastMotionColumn = -1;
    private int lastMotionRow = -1;
    private double wheelRemainder;

    // Keyboard.
    private boolean pressSent;
    private char pendingHighSurrogate;
    private String composedText = "";
    /** An Option+dead-key chord was sent as Meta; see {@link #onInputMethodText}. */
    private boolean deadKeyMeta;
    /** macOS: Option+letter/digit is Meta (true) or composes (false). */
    private volatile boolean optionAsMeta = true;

    // Cursor blink and bell.
    private final Timer blinkTimer;
    private boolean blinkOn = true;
    private long bellUntilNanos;
    private long lastBellNanos;
    private final Timer bellTimer;
    private boolean ended;

    // Device pixels per point: 2 on a Retina display. The cell grid, the fonts and all
    // painting are in device pixels; Swing coordinates (layout, mouse, the IME caret) are in
    // points and converted at those edges, so cells can be a half point wide on a 2× screen.
    private double scale = 1;
    private boolean scaleForced;
    private String fontFamily;
    private int fontSize;

    // Paint scratch, reused across frames.
    private char[] runChars = new char[256];
    private final char[] oneChar = new char[2];

    public TerminalView(int columns, int rows, int maxHistory, Output output, int[] palette,
                        Integer background, boolean light, String fontFamily, int fontSize) {
        this.emulator = new TerminalEmulator(columns, rows, maxHistory);
        this.output = output;
        this.colors = new TerminalColors(palette, light);
        colors.setTheme(background, light);
        this.fontFamily = fontFamily;
        this.fontSize = fontSize;
        this.fonts = new TerminalFonts(fontFamily, fontSize, scale);
        emulator.setReplies(this::sendReply, TerminalEmulator.ReplyScope.CLIENT);
        emulator.setColorScheme(light ? TerminalEmulator.ColorScheme.LIGHT : TerminalEmulator.ColorScheme.DARK);
        emulator.setListener(this);

        frameTimer = new Timer(0, e -> frameDue());
        frameTimer.setRepeats(false);
        resizeTimer = new Timer(40, e -> applyResize());
        resizeTimer.setRepeats(false);
        blinkTimer = new Timer(BLINK_MS, e -> {
            blinkOn = !blinkOn;
            repaintCursor();
        });
        bellTimer = new Timer(130, e -> repaint());
        bellTimer.setRepeats(false);
        scrollModel.addChangeListener(e -> {
            if (!updatingScrollModel) {
                setScrollOffset(-scrollModel.getValue());
            }
        });

        setOpaque(true);
        setFocusable(true);
        setFocusTraversalKeysEnabled(false);
        enableEvents(AWTEvent.KEY_EVENT_MASK | AWTEvent.MOUSE_EVENT_MASK
                | AWTEvent.MOUSE_MOTION_EVENT_MASK | AWTEvent.MOUSE_WHEEL_EVENT_MASK
                | AWTEvent.FOCUS_EVENT_MASK | AWTEvent.COMPONENT_EVENT_MASK
                | AWTEvent.INPUT_METHOD_EVENT_MASK);
        enableInputMethods(true);
        addInputMethodListener(new InputMethodListener() {
            @Override
            public void inputMethodTextChanged(InputMethodEvent event) {
                onInputMethodText(event);
            }

            @Override
            public void caretPositionChanged(InputMethodEvent event) {
                event.consume();
            }
        });
        addHierarchyListener(e -> {
            if ((e.getChangeFlags() & java.awt.event.HierarchyEvent.SHOWING_CHANGED) != 0) {
                showingChanged();
            }
        });
        addComponentListener(new java.awt.event.ComponentAdapter() {
            @Override
            public void componentResized(java.awt.event.ComponentEvent e) {
                scheduleResize();
            }
        });
        updateBackground();
    }

    // =====================================================================================
    // Public surface (EDT)
    // =====================================================================================

    public TerminalEmulator emulator() {
        return emulator;
    }

    /** Feeds program output (any thread; the reader thread in practice). */
    public void feed(byte[] data, int off, int len) {
        emulator.feed(data, off, len);
    }

    /** The program's output ended: the view stops blinking and paints once more. */
    public void markEnded() {
        ended = true;
        blinkTimer.stop();
        repaint();
    }

    public boolean ended() {
        return ended;
    }

    public void setTitleListener(Consumer<String> listener) {
        this.titleListener = listener;
    }

    /** The scrollbar model: value {@code -offset} in {@code [-historySize, 0]}, extent = rows. */
    public BoundedRangeModel scrollModel() {
        return scrollModel;
    }

    public void setMouseWheelDisabled(boolean disabled) {
        this.mouseWheelDisabled = disabled;
    }

    /** macOS: whether Option+letter/digit is Meta or composes (accents, dead keys). */
    public void setOptionAsMeta(boolean on) {
        this.optionAsMeta = on;
    }

    /** Recolours the default foreground/background (null background: the palette's) and
     * reports light/dark to the program. Explicit colours keep theirs. */
    public void setTheme(Integer background, boolean light) {
        colors.setTheme(background, light);
        emulator.setColorScheme(light ? TerminalEmulator.ColorScheme.LIGHT : TerminalEmulator.ColorScheme.DARK);
        updateBackground();
        viewStamp++;
        repaint();
    }

    public void setPalette(int[] palette) {
        colors.setPalette(palette);
        updateBackground();
        viewStamp++;
        repaint();
    }

    public Color defaultBackground() {
        return colors.color(colors.defaultBackground());
    }

    /** New font: re-measures the cell and reflows the grid to the component's size. */
    public void setTerminalFont(String family, int size) {
        fontFamily = family;
        fontSize = size;
        fonts = new TerminalFonts(family, size, scale);
        viewStamp++;
        revalidate();
        scheduleResize();
        repaint();
    }

    /** Cell width in device pixels. */
    public int cellWidth() {
        return fonts.cellWidth();
    }

    /** Cell height in device pixels. */
    public int cellHeight() {
        return fonts.cellHeight();
    }

    /** Device pixels per point the view currently paints at. */
    double deviceScale() {
        return scale;
    }

    /** Paints at {@code scale} regardless of the screen (offscreen rendering, tests). */
    void setDeviceScale(double scale) {
        scaleForced = true;
        applyScale(scale);
    }

    @Override
    public void addNotify() {
        super.addNotify();
        applyScale(screenScale());
        paintedKey = null; // (re)attached: whatever was painted before is gone
        showingChanged();
    }

    /** The scale of the screen the view is on; 1 when not on one (headless, not shown). */
    private double screenScale() {
        java.awt.GraphicsConfiguration gc = getGraphicsConfiguration();
        if (gc == null) {
            return scale;
        }
        double s = gc.getDefaultTransform().getScaleX();
        return s > 0 ? s : 1;
    }

    /** Re-measures the cell for a new scale (the window moved to a screen of another density). */
    private void applyScale(double newScale) {
        if (newScale == scale || newScale <= 0) {
            return;
        }
        scale = newScale;
        fonts = new TerminalFonts(fontFamily, fontSize, scale);
        viewStamp++;
        revalidate();
        scheduleResize();
        repaint();
    }

    /** Device pixels from points. */
    private int device(int points) {
        return (int) Math.round(points * scale);
    }

    /** Points covering {@code devicePixels} (rounded up). */
    private int pointsCeil(double devicePixels) {
        return (int) Math.ceil(devicePixels / scale - 1e-9);
    }

    /** Repaints a rectangle given in device pixels. */
    private void repaintDevice(int x, int y, int width, int height) {
        int left = (int) Math.floor(x / scale);
        int top = (int) Math.floor(y / scale);
        repaint(left, top, pointsCeil(x + width) - left + 1, pointsCeil(y + height) - top + 1);
    }

    /** Copy, Paste, Select All, then Page Up / Page Down through the scrollback. Built fresh
     * each time so Copy is enabled only with a selection. */
    JPopupMenu contextMenu() {
        int chord = MAC ? java.awt.event.InputEvent.META_DOWN_MASK
                : java.awt.event.InputEvent.CTRL_DOWN_MASK | java.awt.event.InputEvent.SHIFT_DOWN_MASK;
        JPopupMenu menu = new JPopupMenu();
        JMenuItem copy = menuItem("Copy", KeyStroke.getKeyStroke(KeyEvent.VK_C, chord), this::copySelection);
        copy.setEnabled(hasSelection());
        menu.add(copy);
        menu.add(menuItem("Paste", KeyStroke.getKeyStroke(KeyEvent.VK_V, chord), this::paste));
        menu.add(menuItem("Select All", KeyStroke.getKeyStroke(KeyEvent.VK_A, chord), this::selectAll));
        menu.addSeparator();
        int history;
        emulator.lock().lock();
        try {
            history = emulator.historySize();
        } finally {
            emulator.lock().unlock();
        }
        JMenuItem up = menuItem("Page Up", null, this::pageUp);
        up.setEnabled(scrollOffset < history);
        menu.add(up);
        JMenuItem down = menuItem("Page Down", null, this::pageDown);
        down.setEnabled(scrollOffset > 0);
        menu.add(down);
        return menu;
    }

    private static JMenuItem menuItem(String label, KeyStroke shown, Runnable action) {
        JMenuItem item = new JMenuItem(label);
        if (shown != null) {
            item.setAccelerator(shown); // shown only: the key handler owns these chords
        }
        item.addActionListener(e -> action.run());
        return item;
    }

    public void pageUp() {
        setScrollOffset(scrollOffset + emulator.rows());
    }

    public void pageDown() {
        setScrollOffset(scrollOffset - emulator.rows());
    }

    public boolean alternateScreen() {
        emulator.lock().lock();
        try {
            return emulator.alternateScreen();
        } finally {
            emulator.lock().unlock();
        }
    }

    public void scrollToTop() {
        setScrollOffset(Integer.MAX_VALUE);
    }

    public void scrollToBottom() {
        setScrollOffset(0);
    }

    int scrollOffset() {
        return scrollOffset;
    }

    long frames() {
        return frames;
    }

    /** Frames that repainted everything (tests). */
    long fullFrames() {
        return fullFrames;
    }

    /** Tests: pretend the view is (or is not) showing, as a card switch would. */
    void setShowingForTest(boolean showing) {
        showingOverride = showing;
        showingChanged();
    }

    private boolean viewShowing() {
        Boolean override = showingOverride;
        return override != null ? override : isShowing();
    }

    /** Shown or hidden (a card switch, a window opened or closed): runs the catch-up frame
     * owed for output that arrived while hidden, and starts or stops the cursor blink. */
    private void showingChanged() {
        if (viewShowing() && catchUpPending) {
            catchUpPending = false;
            paintedKey = null; // the catch-up frame repaints everything
            frameDue();
        }
        updateBlinkTimer();
    }

    private void setScrollOffset(int offset) {
        int history;
        emulator.lock().lock();
        try {
            history = emulator.historySize();
        } finally {
            emulator.lock().unlock();
        }
        int clamped = Math.max(0, Math.min(offset, history));
        if (clamped != scrollOffset) {
            scrollOffset = clamped;
            repaint();
        }
        updateScrollModel(history);
    }

    private void updateScrollModel(int history) {
        updatingScrollModel = true;
        try {
            int rows = emulator.rows();
            scrollModel.setRangeProperties(-scrollOffset, rows, -history, rows, false);
        } finally {
            updatingScrollModel = false;
        }
    }

    private void updateBackground() {
        setBackground(colors.color(colors.defaultBackground()));
        setForeground(colors.color(colors.defaultForeground()));
    }

    // =====================================================================================
    // Emulator callbacks (reader thread)
    // =====================================================================================

    @Override
    public void contentChanged() {
        if (frameQueued.compareAndSet(false, true)) {
            SwingUtilities.invokeLater(this::frameDue);
        }
    }

    @Override
    public void bell(int count) {
        SwingUtilities.invokeLater(this::flashBell);
    }

    @Override
    public void titleChanged(String title) {
        Consumer<String> l = titleListener;
        if (l != null) {
            SwingUtilities.invokeLater(() -> l.accept(title));
        }
    }

    private void sendReply(byte[] reply) {
        output.write(reply);
    }

    // =====================================================================================
    // Frames (EDT)
    // =====================================================================================

    private void frameDue() {
        if (!viewShowing()) {
            // Hidden: leave the frame queued (so further output doesn't post more) and catch
            // up in one frame when the view shows again.
            catchUpPending = true;
            frameTimer.stop();
            return;
        }
        long now = System.nanoTime();
        long wait = lastFrameNanos + FRAME_NANOS - now;
        if (emulator.synchronizedOutput()) {
            if (syncSinceNanos == 0) {
                syncSinceNanos = now;
            }
            if (now - syncSinceNanos < SYNC_HOLD_NANOS) {
                wait = Math.max(wait, 8_000_000L);
            }
        } else {
            syncSinceNanos = 0;
        }
        if (wait > 0) {
            frameTimer.setInitialDelay((int) Math.max(1, wait / 1_000_000L));
            frameTimer.restart();
            return;
        }
        frameQueued.set(false); // output arriving from here on queues the next frame
        lastFrameNanos = now;
        syncSinceNanos = 0;
        frames++;
        int history;
        int[] damage;
        emulator.lock().lock();
        try {
            history = emulator.historySize();
            long added = emulator.historyLinesAdded();
            long grown = added - lastHistoryAdded;
            lastHistoryAdded = added;
            if (scrollOffset > 0) {
                // keep a scrolled-back view on the same lines while output arrives
                scrollOffset = (int) Math.min(history, scrollOffset + grown);
            }
            damage = collectDamage(history, added);
        } finally {
            emulator.lock().unlock();
        }
        updateScrollModel(history);
        blinkOn = true;
        if (blinkTimer.isRunning()) {
            blinkTimer.restart();
        }
        updateBlinkTimer();
        if (damage == null) {
            fullFrames++;
            repaint();
        } else if (damage[0] <= damage[1]) {
            Insets in = getInsets();
            int ch = fonts.cellHeight();
            repaintDevice(0, device(in.top) + damage[0] * ch, device(getWidth()), (damage[1] - damage[0] + 1) * ch);
        }
    }

    /** Everything outside the rows' own content that changes what a frame paints. */
    private record FrameKey(int rows, int columns, int offset, int history, long added, boolean reverse,
                            boolean alternate, boolean cursorVisible, int cursorShape, boolean cursorBlink,
                            int width, int height, Insets insets, TerminalFonts fonts, double scale,
                            int viewStamp, boolean focused, boolean ended, boolean selectionActive,
                            long selStartRow, int selStartColumn, long selEndRow, int selEndColumn,
                            String composed) {
    }

    /**
     * Compares the visible rows with what the last frame painted and records them as
     * painted. Returns null when everything must be repainted, else the first and last view
     * rows to repaint (first > last: none). Lock held.
     */
    private int[] collectDamage(int history, long added) {
        int rows = emulator.rows();
        int offset = Math.min(scrollOffset, history);
        FrameKey key = new FrameKey(rows, emulator.columns(), offset, history, added, emulator.reverseVideo(),
                emulator.alternateScreen(), emulator.cursorVisible(), emulator.cursorShape(), emulator.cursorBlink(),
                getWidth(), getHeight(), getInsets(), fonts, scale, viewStamp, hasFocus(), ended, selectionActive,
                selStartRow, selStartColumn, selEndRow, selEndColumn, composedText);
        boolean full = !key.equals(paintedKey) || paintedLines.length != rows;
        paintedKey = key;
        if (full) {
            paintedLines = new Line[rows];
            paintedVersions = new long[rows];
        }
        int first = Integer.MAX_VALUE;
        int last = -1;
        for (int r = 0; r < rows; r++) {
            Line line = emulator.line(r - offset);
            long version = line.version();
            if (paintedLines[r] != line || paintedVersions[r] != version) {
                paintedLines[r] = line;
                paintedVersions[r] = version;
                first = Math.min(first, r);
                last = r;
            }
        }
        int cursorRow = emulator.cursorRow() + offset;
        for (int r : new int[]{paintedCursorRow, cursorRow}) {
            if (r >= 0 && r < rows) {
                first = Math.min(first, r);
                last = Math.max(last, r);
            }
        }
        paintedCursorRow = cursorRow;
        if (full) {
            return null;
        }
        // a row of margin either side: a glyph may overflow its cell into a neighbour
        return new int[]{Math.max(0, first - 1), Math.min(rows - 1, last + 1)};
    }

    private void flashBell() {
        long now = System.nanoTime();
        if (now - lastBellNanos < 200_000_000L) {
            return; // a bell storm is one flash
        }
        lastBellNanos = now;
        bellUntilNanos = now + 120_000_000L;
        repaint();
        bellTimer.restart();
    }

    private void updateBlinkTimer() {
        boolean blinking;
        emulator.lock().lock();
        try {
            blinking = cursorBlinks();
        } finally {
            emulator.lock().unlock();
        }
        boolean run = blinking && hasFocus() && !ended && viewShowing();
        if (run && !blinkTimer.isRunning()) {
            blinkOn = true;
            blinkTimer.start();
        } else if (!run && blinkTimer.isRunning()) {
            blinkTimer.stop();
            blinkOn = true;
        }
    }

    /** Lock held. */
    private boolean cursorBlinks() {
        int shape = emulator.cursorShape();
        return shape == 0 ? emulator.cursorBlink() : (shape & 1) == 1;
    }

    private void repaintCursor() {
        int row;
        int column;
        emulator.lock().lock();
        try {
            row = emulator.cursorRow() + scrollOffset;
            column = emulator.cursorColumn();
        } finally {
            emulator.lock().unlock();
        }
        Insets in = getInsets();
        int cw = fonts.cellWidth();
        int ch = fonts.cellHeight();
        repaintDevice(device(in.left) + column * cw - 1, device(in.top) + row * ch, cw * 2 + 2, ch);
    }

    // =====================================================================================
    // Size
    // =====================================================================================

    /** Columns and rows that fit {@code width} × {@code height} pixels, at least 2 × 2. */
    static Dimension gridSize(int width, int height, int cellWidth, int cellHeight) {
        return new Dimension(Math.max(MIN_COLUMNS, width / Math.max(1, cellWidth)),
                Math.max(MIN_ROWS, height / Math.max(1, cellHeight)));
    }

    @Override
    public Dimension getPreferredSize() {
        if (isPreferredSizeSet()) {
            return super.getPreferredSize();
        }
        Insets in = getInsets();
        return new Dimension(pointsCeil(emulator.columns() * (double) fonts.cellWidth()) + in.left + in.right,
                pointsCeil(emulator.rows() * (double) fonts.cellHeight()) + in.top + in.bottom);
    }

    @Override
    public Dimension getMinimumSize() {
        return new Dimension(pointsCeil(MIN_COLUMNS * (double) fonts.cellWidth()),
                pointsCeil(MIN_ROWS * (double) fonts.cellHeight()));
    }

    /** Debounces a burst of layout changes (a window drag) into one resize. */
    private void scheduleResize() {
        resizeTimer.restart();
    }

    /** Fits the grid to the current size now (the debounce timer; tests). Before the first
     * layout (no size yet) the attach size stays. */
    void applyResize() {
        resizeTimer.stop();
        Insets in = getInsets();
        int w = getWidth() - in.left - in.right;
        int h = getHeight() - in.top - in.bottom;
        if (w <= 0 || h <= 0) {
            return;
        }
        // whole device pixels inside the points Swing gave us
        Dimension grid = gridSize((int) Math.floor(w * scale + 1e-9), (int) Math.floor(h * scale + 1e-9),
                fonts.cellWidth(), fonts.cellHeight());
        if (grid.width == emulator.columns() && grid.height == emulator.rows()) {
            return;
        }
        emulator.resize(grid.width, grid.height);
        output.resize(grid.width, grid.height);
        setScrollOffset(scrollOffset);
        repaint();
    }

    // =====================================================================================
    // Painting
    // =====================================================================================

    @Override
    protected void paintComponent(Graphics graphics) {
        if (catchUpPending && viewShowing()) {
            SwingUtilities.invokeLater(this::showingChanged); // a missed showing change
        }
        if (!scaleForced) {
            applyScale(screenScale());
        }
        Graphics2D g = (Graphics2D) graphics.create();
        try {
            if (scale != 1) {
                g.scale(1 / scale, 1 / scale); // paint in device pixels
            }
            paintDevice(g);
        } finally {
            g.dispose();
        }
    }

    /** {@link #paintComponent} in device-pixel coordinates. */
    private void paintDevice(Graphics2D g) {
        applyRenderingHints(g);
        int width = device(getWidth());
        Rectangle clip = g.getClipBounds();
        if (clip == null) {
            clip = new Rectangle(0, 0, width, device(getHeight()));
        }
        Insets points = getInsets();
        Insets in = new Insets(device(points.top), device(points.left), device(points.bottom), device(points.right));
        int cw = fonts.cellWidth();
        int ch = fonts.cellHeight();
        emulator.lock().lock();
        try {
            boolean reverse = emulator.reverseVideo();
            int defaultBg = reverse ? colors.defaultForeground() : colors.defaultBackground();
            g.setColor(colors.color(defaultBg));
            g.fillRect(clip.x, clip.y, clip.width, clip.height);
            int rows = emulator.rows();
            int history = emulator.historySize();
            int offset = Math.min(scrollOffset, history);
            long added = emulator.historyLinesAdded();
            // one row beyond the clip either way, so a neighbour's glyph overflowing into the
            // clip is redrawn (the graphics clip keeps everything else untouched)
            int firstRow = Math.max(0, Math.floorDiv(clip.y - in.top, ch) - 1);
            int lastRow = Math.min(rows - 1, Math.floorDiv(clip.y + clip.height - in.top - 1, ch) + 1);
            int columns = Math.min(emulator.columns(), (width - in.left + cw - 1) / cw);
            for (int r = firstRow; r <= lastRow; r++) {
                int index = r - offset;
                Line line = emulator.line(index);
                paintRow(g, line, in.left, in.top + r * ch, Math.min(columns, line.columns()),
                        added + index, reverse, defaultBg);
            }
            int cursorViewRow = emulator.cursorRow() + offset;
            if (cursorViewRow >= 0 && cursorViewRow < rows) {
                paintCursor(g, in.left, in.top + cursorViewRow * ch, emulator.line(emulator.cursorRow()),
                        emulator.cursorColumn(), reverse);
            }
        } finally {
            emulator.lock().unlock();
        }
        if (System.nanoTime() < bellUntilNanos) {
            Color fg = colors.color(colors.defaultForeground());
            g.setColor(new Color(fg.getRed(), fg.getGreen(), fg.getBlue(), 40));
            g.fillRect(clip.x, clip.y, clip.width, clip.height);
        }
    }

    private static void applyRenderingHints(Graphics2D g) {
        Object desktop = Toolkit.getDefaultToolkit().getDesktopProperty("awt.font.desktophints");
        if (desktop instanceof Map<?, ?> hints) {
            g.addRenderingHints(hints);
        } else {
            g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        }
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_OFF);
    }

    private boolean selected(long absRow, int column) {
        if (!selectionActive) {
            return false;
        }
        if (absRow < selStartRow || absRow > selEndRow) {
            return false;
        }
        if (absRow == selStartRow && column < selStartColumn) {
            return false;
        }
        return absRow != selEndRow || column < selEndColumn;
    }

    /** Effective background rgb of a cell (inverse, reverse video and selection applied). */
    private int cellBackground(long style, boolean reverse, boolean selected) {
        if (selected) {
            return colors.selection();
        }
        boolean inverse = Style.inverse(style) ^ reverse;
        return inverse ? colors.rgb(Style.foreground(style), true) : colors.rgb(Style.background(style), false);
    }

    private int cellForeground(long style, boolean reverse, int background) {
        boolean inverse = Style.inverse(style) ^ reverse;
        int fg = inverse ? colors.rgb(Style.background(style), false) : colors.rgb(Style.foreground(style), true);
        if (Style.dim(style)) {
            fg = TerminalColors.blend(fg, background, 0.5f);
        }
        return fg;
    }

    private void paintRow(Graphics2D g, Line line, int left, int top, int columns, long absRow,
                          boolean reverse, int defaultBg) {
        int cw = fonts.cellWidth();
        int ch = fonts.cellHeight();
        // backgrounds, merged into runs of one colour
        int runStart = 0;
        int runColor = defaultBg;
        for (int x = 0; x <= columns; x++) {
            int bg = x < columns ? cellBackground(line.style(x), reverse, selected(absRow, x)) : -1;
            if (bg != runColor) {
                if (runColor != defaultBg && x > runStart) {
                    g.setColor(colors.color(runColor));
                    g.fillRect(left + runStart * cw, top, (x - runStart) * cw, ch);
                }
                runStart = x;
                runColor = bg;
            }
        }
        // text
        int baseline = top + fonts.baseline();
        boolean exact = fonts.exactAdvance();
        int runLength = 0;
        int runX = 0;
        int runFg = 0;
        int runFont = 0;
        long runDecor = 0;
        for (int x = 0; x < columns; x++) {
            if (line.isWideTail(x)) {
                continue;
            }
            long style = line.style(x);
            int cp = line.codePoint(x);
            boolean blank = line.isEmpty(x) || cp == ' ' || cp == 0;
            long decor = decorations(style);
            if (blank && decor == 0) {
                if (runLength > 0) {
                    flushRun(g, runX, runLength, runFg, runFont, runDecor, left, top, baseline);
                    runLength = 0;
                }
                continue;
            }
            boolean sel = selected(absRow, x);
            int bg = cellBackground(style, reverse, sel);
            int fg = cellForeground(style, reverse, bg);
            boolean invisible = Style.invisible(style);
            int fontStyle = (Style.bold(style) ? TerminalFonts.BOLD : 0) | (Style.italic(style) ? TerminalFonts.ITALIC : 0);
            int width = line.width(x);
            boolean simple = exact && width == 1 && !line.hasExtras(x) && !BoxDrawing.handles(cp)
                    && cp < 0x10000 && (cp < 0x80 || fonts.fontFor(cp, fontStyle) == fonts.font(fontStyle));
            if (simple) {
                if (runLength > 0 && (fg != runFg || fontStyle != runFont || decor != runDecor
                        || runX + runLength != x)) {
                    flushRun(g, runX, runLength, runFg, runFont, runDecor, left, top, baseline);
                    runLength = 0;
                }
                if (runLength == 0) {
                    runX = x;
                    runFg = fg;
                    runFont = fontStyle;
                    runDecor = decor;
                }
                if (runLength == runChars.length) {
                    runChars = java.util.Arrays.copyOf(runChars, runChars.length * 2);
                }
                runChars[runLength++] = invisible || blank ? ' ' : (char) cp;
                continue;
            }
            if (runLength > 0) {
                flushRun(g, runX, runLength, runFg, runFont, runDecor, left, top, baseline);
                runLength = 0;
            }
            int cellX = left + x * cw;
            int cellW = Math.max(1, width) * cw;
            if (!invisible && !blank) {
                Color color = colors.color(fg);
                if (!BoxDrawing.draw(g, cp, cellX, top, cw, ch, color)) {
                    drawGlyph(g, line, x, cp, fontStyle, color, cellX, cellW, baseline);
                }
            }
            if (decor != 0) {
                drawDecorations(g, decor, colors.color(fg), cellX, cellW, top);
            }
        }
        if (runLength > 0) {
            flushRun(g, runX, runLength, runFg, runFont, runDecor, left, top, baseline);
        }
    }

    /** Underline style, strikethrough and overline packed for run comparison; 0 = none. */
    private static long decorations(long style) {
        return Style.underline(style) | (Style.strikethrough(style) ? 8 : 0) | (Style.overline(style) ? 16 : 0);
    }

    private void flushRun(Graphics2D g, int x, int length, int fg, int fontStyle, long decor,
                          int left, int top, int baseline) {
        Color color = colors.color(fg);
        int cw = fonts.cellWidth();
        g.setColor(color);
        g.setFont(fonts.font(fontStyle));
        g.drawChars(runChars, 0, length, left + x * cw, baseline);
        if (decor != 0) {
            drawDecorations(g, decor, color, left + x * cw, length * cw, top);
        }
    }

    private void drawGlyph(Graphics2D g, Line line, int x, int cp, int fontStyle, Color color,
                           int cellX, int cellW, int baseline) {
        Font font = fonts.fontFor(cp, fontStyle);
        g.setColor(color);
        g.setFont(font);
        int advance;
        if (line.hasExtras(x)) {
            String text = line.text(x);
            advance = g.getFontMetrics(font).stringWidth(text);
            g.drawString(text, cellX + Math.max(0, (cellW - advance) / 2), baseline);
            return;
        }
        int n = Character.toChars(cp, oneChar, 0);
        if (BoxDrawing.tiles(cp) && font != fonts.font(fontStyle)) {
            drawStretched(g, font, n, cellX, cellW, baseline);
            return;
        }
        advance = g.getFontMetrics(font).charsWidth(oneChar, 0, n);
        int dx = advance < cellW ? (cellW - advance) / 2 : 0;
        if (advance > cellW + 1) {
            // a glyph wider than its cells (a fallback font's metrics): squeeze, don't overlap
            Graphics2D scaled = (Graphics2D) g.create();
            scaled.translate(cellX, 0);
            scaled.scale(cellW / (double) advance, 1);
            scaled.drawChars(oneChar, 0, n, 0, baseline);
            scaled.dispose();
            return;
        }
        g.drawChars(oneChar, 0, n, cellX + dx, baseline);
    }

    /** A tile-designed glyph from a fallback font: its line box (ascent + descent) and its
     * advance scaled to the cell, so it touches the cell's edges as its font meant. */
    private void drawStretched(Graphics2D g, Font font, int n, int cellX, int cellW, int baseline) {
        java.awt.font.LineMetrics lm = font.getLineMetrics(new String(oneChar, 0, n), TerminalFonts.FRC);
        double lineHeight = lm.getAscent() + lm.getDescent();
        double advance = g.getFontMetrics(font).charsWidth(oneChar, 0, n);
        if (lineHeight <= 0 || advance <= 0) {
            return;
        }
        int cellTop = baseline - fonts.baseline();
        Graphics2D scaled = (Graphics2D) g.create();
        scaled.translate(cellX, cellTop);
        scaled.scale(cellW / advance, fonts.cellHeight() / lineHeight);
        scaled.drawChars(oneChar, 0, n, 0, (int) Math.round(lm.getAscent()));
        scaled.dispose();
    }

    private void drawDecorations(Graphics2D g, long decor, Color color, int x, int width, int top) {
        g.setColor(color);
        int ch = fonts.cellHeight();
        int t = Math.max(1, Math.round(fonts.lineThickness()));
        int underline = (int) (decor & 7);
        int uy = Math.min(top + ch - t, top + fonts.baseline() + Math.max(1, (ch - fonts.baseline()) / 3));
        switch (underline) {
            case Style.UNDERLINE_SINGLE -> g.fillRect(x, uy, width, t);
            case Style.UNDERLINE_DOUBLE -> {
                int y2 = Math.min(top + ch - t, uy + 2 * t);
                int y1 = Math.max(top, y2 - 2 * t);
                g.fillRect(x, y1, width, t);
                g.fillRect(x, y2, width, t);
            }
            case Style.UNDERLINE_CURLY -> {
                Path2D.Float wave = new Path2D.Float();
                float amplitude = Math.max(1f, t);
                float mid = Math.min(top + ch - amplitude - t, uy);
                float period = Math.max(4, fonts.cellWidth() / 2f);
                wave.moveTo(x, mid);
                for (float px = x; px < x + width; px += period) {
                    wave.quadTo(px + period / 4, mid - amplitude, px + period / 2, mid);
                    wave.quadTo(px + 3 * period / 4, mid + amplitude, px + period, mid);
                }
                Graphics2D wg = (Graphics2D) g.create(x, top, width, ch);
                wg.translate(-x, -top);
                wg.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
                wg.setStroke(new java.awt.BasicStroke(t));
                wg.draw(wave);
                wg.dispose();
            }
            case Style.UNDERLINE_DOTTED -> {
                for (int px = x; px < x + width; px += 2 * t) {
                    g.fillRect(px, uy, t, t);
                }
            }
            case Style.UNDERLINE_DASHED -> {
                int dash = Math.max(2, fonts.cellWidth() / 2);
                for (int px = x; px < x + width; px += dash * 2) {
                    g.fillRect(px, uy, Math.min(dash, x + width - px), t);
                }
            }
            default -> {
            }
        }
        if ((decor & 8) != 0) {
            g.fillRect(x, top + fonts.baseline() - Math.round(fonts.baseline() * 0.3f), width, t);
        }
        if ((decor & 16) != 0) {
            g.fillRect(x, top, width, t);
        }
    }

    /** Lock held. */
    private void paintCursor(Graphics2D g, int left, int top, Line line, int column, boolean reverse) {
        if (ended || !emulator.cursorVisible() || column >= line.columns()) {
            return;
        }
        if (column > 0 && line.isWideTail(column)) {
            column--;
        }
        boolean focused = hasFocus();
        boolean blinking = cursorBlinks();
        if (focused && blinking && !blinkOn && composedText.isEmpty()) {
            return;
        }
        int cw = fonts.cellWidth();
        int ch = fonts.cellHeight();
        int x = left + column * cw;
        int width = Math.max(1, line.width(column)) * cw;
        long style = line.style(column);
        int bg = cellBackground(style, reverse, false);
        int fg = cellForeground(style, reverse, bg);
        if (!composedText.isEmpty()) {
            paintComposition(g, x, top, fg, bg);
            return;
        }
        Color cursorColor = colors.color(fg == bg ? colors.defaultForeground() : fg);
        g.setColor(cursorColor);
        int shape = emulator.cursorShape();
        if (!focused) {
            g.drawRect(x, top, width - 1, ch - 1);
            return;
        }
        if (shape == 3 || shape == 4) {
            int t = Math.max(2, Math.round(ch / 10f));
            g.fillRect(x, top + ch - t, width, t);
        } else if (shape == 5 || shape == 6) {
            g.fillRect(x, top, Math.max(2, Math.round(cw / 6f)), ch);
        } else {
            g.fillRect(x, top, width, ch);
            int cp = line.codePoint(column);
            if (cp != 0 && cp != ' ' && !Style.invisible(style)) {
                Graphics2D cg = (Graphics2D) g.create(x, top, width, ch);
                cg.translate(-x, -top);
                int fontStyle = (Style.bold(style) ? TerminalFonts.BOLD : 0) | (Style.italic(style) ? TerminalFonts.ITALIC : 0);
                Color glyphColor = colors.color(bg);
                if (!BoxDrawing.draw(cg, cp, x, top, cw, ch, glyphColor)) {
                    drawGlyph(cg, line, column, cp, fontStyle, glyphColor, x, width, top + fonts.baseline());
                }
                cg.dispose();
            }
        }
    }

    private void paintComposition(Graphics2D g, int x, int top, int fg, int bg) {
        Font font = fonts.font(TerminalFonts.PLAIN);
        int width = g.getFontMetrics(font).stringWidth(composedText);
        g.setColor(colors.color(bg));
        g.fillRect(x, top, width, fonts.cellHeight());
        g.setColor(colors.color(fg));
        g.setFont(font);
        g.drawString(composedText, x, top + fonts.baseline());
        g.fillRect(x, top + fonts.cellHeight() - 1, width, 1);
    }

    // =====================================================================================
    // Keyboard
    // =====================================================================================

    private KeyEncoder.Modes keyModes() {
        emulator.lock().lock();
        try {
            return new KeyEncoder.Modes(emulator.applicationCursorKeys(), emulator.applicationKeypad(),
                    emulator.newLineMode(), MAC, optionAsMeta);
        } finally {
            emulator.lock().unlock();
        }
    }

    /**
     * The terminal sees keys before key bindings do — an ancestor's binding (a split pane's
     * F6/F8, say) must not take a key the program is owed. Whatever the terminal leaves
     * unconsumed (Cmd chords, lone modifiers) carries on to listeners and bindings.
     */
    @Override
    protected void processKeyEvent(KeyEvent e) {
        switch (e.getID()) {
            case KeyEvent.KEY_PRESSED -> keyPressed(e);
            case KeyEvent.KEY_TYPED -> keyTyped(e);
            default -> {
            }
        }
        if (!e.isConsumed()) {
            super.processKeyEvent(e);
        }
    }

    private void keyPressed(KeyEvent e) {
        pressSent = false;
        int mods = e.getModifiersEx();
        if (clipboardShortcut(e.getKeyCode(), mods)) {
            pressSent = true;
            e.consume();
            return;
        }
        byte[] bytes = KeyEncoder.pressed(e.getKeyCode(), e.getKeyLocation(), e.getKeyChar(), mods, keyModes());
        if (bytes != null) {
            pressSent = true;
            deadKeyMeta = MAC && (mods & KeyEvent.ALT_DOWN_MASK) != 0 && e.getKeyChar() == KeyEvent.CHAR_UNDEFINED;
            typeInput(bytes);
            e.consume();
        }
    }

    private void keyTyped(KeyEvent e) {
        deadKeyMeta = false; // a plain typed key: no composition is pending
        if (pressSent) {
            e.consume();
            return;
        }
        char c = e.getKeyChar();
        if (Character.isHighSurrogate(c)) {
            pendingHighSurrogate = c;
            e.consume();
            return;
        }
        byte[] bytes;
        if (Character.isLowSurrogate(c) && pendingHighSurrogate != 0) {
            bytes = new String(new char[]{pendingHighSurrogate, c}).getBytes(StandardCharsets.UTF_8);
        } else {
            bytes = KeyEncoder.typed(c, e.getModifiersEx());
        }
        pendingHighSurrogate = 0;
        if (bytes != null) {
            typeInput(bytes);
            e.consume();
        }
    }

    /** Copy, paste and select-all: Cmd+C/V/A on macOS, Ctrl+Shift+C/V/A (and Shift+Insert)
     * elsewhere, so Ctrl+C stays an interrupt. Never sent to the program. */
    private boolean clipboardShortcut(int keyCode, int mods) {
        int chord = MAC ? KeyEvent.META_DOWN_MASK : KeyEvent.CTRL_DOWN_MASK | KeyEvent.SHIFT_DOWN_MASK;
        int relevant = mods & (KeyEvent.META_DOWN_MASK | KeyEvent.CTRL_DOWN_MASK
                | KeyEvent.SHIFT_DOWN_MASK | KeyEvent.ALT_DOWN_MASK);
        if (!MAC && keyCode == KeyEvent.VK_INSERT && relevant == KeyEvent.SHIFT_DOWN_MASK) {
            paste();
            return true;
        }
        if (relevant != chord) {
            return false;
        }
        switch (keyCode) {
            case KeyEvent.VK_C -> copySelection();
            case KeyEvent.VK_V -> paste();
            case KeyEvent.VK_A -> selectAll();
            default -> {
                return false;
            }
        }
        return true;
    }

    /** Keyboard input: back to the live screen, selection dropped, then sent. */
    private void typeInput(byte[] bytes) {
        clearSelection();
        scrollToBottom();
        blinkOn = true;
        output.write(bytes);
    }

    // =====================================================================================
    // Clipboard
    // =====================================================================================

    public void paste() {
        String text;
        try {
            Object data = Toolkit.getDefaultToolkit().getSystemClipboard().getData(DataFlavor.stringFlavor);
            text = data instanceof String s ? s : null;
        } catch (Exception | Error unavailable) {
            text = null;
        }
        if (text != null && !text.isEmpty()) {
            pasteText(text);
        }
    }

    void pasteText(String text) {
        boolean bracketed;
        emulator.lock().lock();
        try {
            bracketed = emulator.bracketedPaste();
        } finally {
            emulator.lock().unlock();
        }
        typeInput(PasteEncoder.encode(text, bracketed));
    }

    public void copySelection() {
        String text = selectedText();
        if (text != null && !text.isEmpty()) {
            try {
                StringSelection selection = new StringSelection(text);
                Toolkit.getDefaultToolkit().getSystemClipboard().setContents(selection, selection);
            } catch (IllegalStateException | java.awt.HeadlessException unavailable) {
                // clipboard busy or absent: nothing to copy into
            }
        }
    }

    /** The selected text, or null without a selection. */
    String selectedText() {
        if (!selectionActive) {
            return null;
        }
        emulator.lock().lock();
        try {
            long added = emulator.historyLinesAdded();
            long first = added - emulator.historySize();
            long startRow = Math.max(selStartRow, first);
            int startColumn = startRow == selStartRow ? selStartColumn : 0;
            return SelectionText.extract(emulator, (int) (startRow - added), startColumn,
                    (int) (selEndRow - added), selEndColumn);
        } finally {
            emulator.lock().unlock();
        }
    }

    public void selectAll() {
        emulator.lock().lock();
        try {
            long added = emulator.historyLinesAdded();
            selStartRow = added - emulator.historySize();
            selStartColumn = 0;
            selEndRow = added + emulator.rows() - 1;
            selEndColumn = emulator.columns();
        } finally {
            emulator.lock().unlock();
        }
        selectionActive = true;
        repaint();
    }

    void clearSelection() {
        if (selectionActive || selecting) {
            selectionActive = false;
            selecting = false;
            repaint();
        }
    }

    boolean hasSelection() {
        return selectionActive;
    }

    // =====================================================================================
    // Mouse
    // =====================================================================================

    /** Cell column (0-based, clamped) under a point. */
    private int columnAt(int px) {
        int column = (int) Math.floor((px - getInsets().left) * scale / fonts.cellWidth());
        return Math.max(0, Math.min(emulator.columns() - 1, column));
    }

    /** Caret column (between cells, 0..columns) nearest to a point. */
    private int caretAt(int px) {
        int cw = fonts.cellWidth();
        int caret = (int) Math.floor(((px - getInsets().left) * scale + cw / 2.0) / cw);
        return Math.max(0, Math.min(emulator.columns(), caret));
    }

    private int viewRowAt(int py) {
        int row = (int) Math.floor((py - getInsets().top) * scale / fonts.cellHeight());
        return Math.max(0, Math.min(emulator.rows() - 1, row));
    }

    /** Absolute row (historyLinesAdded + index) of a view row. Lock held. */
    private long absRow(int viewRow) {
        return emulator.historyLinesAdded() + viewRow - Math.min(scrollOffset, emulator.historySize());
    }

    private boolean programTracksMouse(MouseEvent e) {
        emulator.lock().lock();
        try {
            return emulator.mouseTracking() != MouseTracking.NONE && !e.isShiftDown();
        } finally {
            emulator.lock().unlock();
        }
    }

    @Override
    protected void processMouseEvent(MouseEvent e) {
        super.processMouseEvent(e);
        // Right-click (Ctrl+click on macOS) opens the context menu unless the program tracks
        // the mouse; Shift+right-click opens it even then, as Shift+drag still selects.
        if (e.isPopupTrigger() && !programTracksMouse(e)) {
            requestFocusInWindow();
            contextMenu().show(this, e.getX(), e.getY());
            e.consume();
            return;
        }
        switch (e.getID()) {
            case MouseEvent.MOUSE_PRESSED -> mousePressed(e);
            case MouseEvent.MOUSE_RELEASED -> mouseReleased(e);
            default -> {
            }
        }
    }

    @Override
    protected void processMouseMotionEvent(MouseEvent e) {
        super.processMouseMotionEvent(e);
        if (e.getID() == MouseEvent.MOUSE_DRAGGED) {
            mouseDragged(e);
        } else if (e.getID() == MouseEvent.MOUSE_MOVED) {
            mouseMoved(e);
        }
    }

    private static int button(MouseEvent e) {
        return switch (e.getButton()) {
            case MouseEvent.BUTTON1 -> MouseEncoder.LEFT;
            case MouseEvent.BUTTON2 -> MouseEncoder.MIDDLE;
            case MouseEvent.BUTTON3 -> MouseEncoder.RIGHT;
            default -> -1;
        };
    }

    private void mousePressed(MouseEvent e) {
        requestFocusInWindow();
        if (programTracksMouse(e)) {
            int button = button(e);
            if (button >= 0 && sendMouse(MouseEncoder.Action.PRESS, button, e)) {
                reportedButton = button;
                clearSelection();
                return;
            }
        }
        if (e.getButton() != MouseEvent.BUTTON1) {
            return;
        }
        int clicks = e.getClickCount();
        emulator.lock().lock();
        try {
            int viewRow = viewRowAt(e.getY());
            long row = absRow(viewRow);
            if (e.isShiftDown() && selectionActive && clicks == 1) {
                extendSelectionTo(row, caretAt(e.getX()));
                selecting = true;
                repaint();
                return;
            }
            int index = viewRow - Math.min(scrollOffset, emulator.historySize());
            if (clicks >= 3) {
                selectMode = SelectMode.LINE;
                int[] rows = SelectionText.logicalLine(emulator, index);
                long base = row - index;
                anchorRow = base + rows[0];
                anchorColumn = 0;
                anchorEndRow = base + rows[1];
                anchorEndColumn = emulator.columns();
                setSelection(anchorRow, anchorColumn, anchorEndRow, anchorEndColumn);
            } else if (clicks == 2) {
                selectMode = SelectMode.WORD;
                int[] word = SelectionText.word(emulator.line(index), columnAt(e.getX()));
                anchorRow = row;
                anchorColumn = word[0];
                anchorEndRow = row;
                anchorEndColumn = word[1];
                setSelection(anchorRow, anchorColumn, anchorEndRow, anchorEndColumn);
            } else {
                selectMode = SelectMode.CHAR;
                anchorRow = row;
                anchorColumn = caretAt(e.getX());
                anchorEndRow = row;
                anchorEndColumn = anchorColumn;
                selectionActive = false;
            }
            selecting = true;
        } finally {
            emulator.lock().unlock();
        }
        repaint();
    }

    private void setSelection(long startRow, int startColumn, long endRow, int endColumn) {
        selStartRow = startRow;
        selStartColumn = startColumn;
        selEndRow = endRow;
        selEndColumn = endColumn;
        selectionActive = startRow != endRow || startColumn != endColumn;
    }

    /** Extends from the anchor to a point, in the current selection mode. Lock held. */
    private void extendSelectionTo(long row, int caret) {
        long headStartRow = row;
        int headStart = caret;
        long headEndRow = row;
        int headEnd = caret;
        int index = (int) (row - emulator.historyLinesAdded());
        if (index >= -emulator.historySize() && index < emulator.rows()) {
            if (selectMode == SelectMode.WORD) {
                int[] word = SelectionText.word(emulator.line(index), Math.min(caret, emulator.columns() - 1));
                headStart = word[0];
                headEnd = word[1];
            } else if (selectMode == SelectMode.LINE) {
                int[] rows = SelectionText.logicalLine(emulator, index);
                headStartRow = row - index + rows[0];
                headStart = 0;
                headEndRow = row - index + rows[1];
                headEnd = emulator.columns();
            }
        }
        if (headStartRow < anchorRow || (headStartRow == anchorRow && headStart < anchorColumn)) {
            setSelection(headStartRow, headStart, anchorEndRow, anchorEndColumn);
        } else {
            setSelection(anchorRow, anchorColumn, headEndRow, headEnd);
        }
    }

    private void mouseDragged(MouseEvent e) {
        if (reportedButton >= 0) {
            sendMouseMotion(MouseEncoder.Action.DRAG, reportedButton, e);
            return;
        }
        if (!selecting) {
            return;
        }
        if (e.getY() < 0) {
            setScrollOffset(scrollOffset + 1); // dragging above the top scrolls back
        } else if (getHeight() > 0 && e.getY() >= getHeight()) {
            setScrollOffset(scrollOffset - 1);
        }
        emulator.lock().lock();
        try {
            extendSelectionTo(absRow(viewRowAt(e.getY())), caretAt(e.getX()));
        } finally {
            emulator.lock().unlock();
        }
        repaint();
    }

    private void mouseMoved(MouseEvent e) {
        boolean anyMotion;
        emulator.lock().lock();
        try {
            anyMotion = emulator.mouseTracking() == MouseTracking.ANY_MOTION;
        } finally {
            emulator.lock().unlock();
        }
        if (anyMotion) {
            sendMouseMotion(MouseEncoder.Action.MOVE, MouseEncoder.NONE, e);
        }
    }

    private void mouseReleased(MouseEvent e) {
        if (reportedButton >= 0) {
            int button = reportedButton;
            reportedButton = -1;
            sendMouse(MouseEncoder.Action.RELEASE, button, e);
            return;
        }
        selecting = false;
    }

    /** Motion is reported once per cell, not per pixel. */
    private void sendMouseMotion(MouseEncoder.Action action, int button, MouseEvent e) {
        int column = columnAt(e.getX());
        int row = viewRowAt(e.getY());
        if (column == lastMotionColumn && row == lastMotionRow) {
            return;
        }
        lastMotionColumn = column;
        lastMotionRow = row;
        sendMouse(action, button, e);
    }

    private boolean sendMouse(MouseEncoder.Action action, int button, MouseEvent e) {
        byte[] report;
        emulator.lock().lock();
        try {
            report = MouseEncoder.encode(emulator.mouseTracking(), emulator.mouseEncoding(), action, button,
                    columnAt(e.getX()), viewRowAt(e.getY()), MouseEncoder.modifiers(e.getModifiersEx()));
        } finally {
            emulator.lock().unlock();
        }
        if (report == null) {
            return false;
        }
        lastMotionColumn = columnAt(e.getX());
        lastMotionRow = viewRowAt(e.getY());
        output.write(report);
        return true;
    }

    /** Where a wheel event goes. */
    enum WheelRoute { SWALLOW, MOUSE_REPORT, ARROW_KEYS, SCROLLBACK }

    static WheelRoute wheelRoute(boolean disabled, MouseTracking tracking, boolean alternateScreen) {
        if (disabled) {
            return WheelRoute.SWALLOW;
        }
        if (tracking != MouseTracking.NONE) {
            return WheelRoute.MOUSE_REPORT;
        }
        return alternateScreen ? WheelRoute.ARROW_KEYS : WheelRoute.SCROLLBACK;
    }

    @Override
    protected void processMouseWheelEvent(MouseWheelEvent e) {
        e.consume(); // never bubbles to an enclosing scroll pane
        WheelRoute route;
        boolean appCursor;
        emulator.lock().lock();
        try {
            route = wheelRoute(mouseWheelDisabled, emulator.mouseTracking(), emulator.alternateScreen());
            appCursor = emulator.applicationCursorKeys();
        } finally {
            emulator.lock().unlock();
        }
        if (route == WheelRoute.SWALLOW) {
            wheelRemainder = 0;
            return;
        }
        if (route == WheelRoute.MOUSE_REPORT && e.isShiftDown()) {
            route = WheelRoute.SCROLLBACK; // Shift+wheel stays local, like Shift+drag
        }
        wheelRemainder += e.getPreciseWheelRotation();
        int notches = (int) wheelRemainder;
        if (notches == 0) {
            return;
        }
        wheelRemainder -= notches;
        boolean up = notches < 0;
        int count = Math.abs(notches);
        switch (route) {
            case MOUSE_REPORT -> {
                for (int i = 0; i < count; i++) {
                    sendMouse(MouseEncoder.Action.PRESS, up ? MouseEncoder.WHEEL_UP : MouseEncoder.WHEEL_DOWN, e);
                }
            }
            case ARROW_KEYS -> {
                String key = (appCursor ? "\u001bO" : "\u001b[") + (up ? 'A' : 'B');
                output.write(key.repeat(count * WHEEL_LINES).getBytes(StandardCharsets.US_ASCII));
            }
            case SCROLLBACK -> setScrollOffset(scrollOffset + (up ? 1 : -1) * count * WHEEL_LINES);
            default -> {
            }
        }
    }

    // =====================================================================================
    // Focus
    // =====================================================================================

    @Override
    protected void processFocusEvent(FocusEvent e) {
        super.processFocusEvent(e);
        boolean reporting;
        emulator.lock().lock();
        try {
            reporting = emulator.focusReporting();
        } finally {
            emulator.lock().unlock();
        }
        if (e.getID() == FocusEvent.FOCUS_LOST) {
            deadKeyMeta = false;
        }
        if (reporting && !ended) {
            output.write((e.getID() == FocusEvent.FOCUS_GAINED ? "\u001b[I" : "\u001b[O")
                    .getBytes(StandardCharsets.US_ASCII));
        }
        blinkOn = true;
        updateBlinkTimer();
        repaintCursor();
    }

    @Override
    public void removeNotify() {
        super.removeNotify();
        blinkTimer.stop();
    }

    // =====================================================================================
    // Input methods
    // =====================================================================================

    /**
     * Input-method text: committed characters go to the program, the uncommitted rest is
     * shown at the cursor. On macOS an Option+dead-key chord (Option+e, u, i, n, `), which
     * the key handler already sent as Meta, also opens a native accent composition; its
     * marked text is hidden and the one commit that closes it loses the accent ("á" → "a",
     * a lone accent → the space that produced it), so the key after the chord types as
     * itself.
     */
    private void onInputMethodText(InputMethodEvent event) {
        AttributedCharacterIterator text = event.getText();
        StringBuilder committed = new StringBuilder();
        StringBuilder composed = new StringBuilder();
        if (text != null) {
            int count = event.getCommittedCharacterCount();
            for (char c = text.first(); c != CharacterIterator.DONE; c = text.next()) {
                (count-- > 0 ? committed : composed).append(c);
            }
        }
        String commit = committed.toString();
        if (deadKeyMeta) {
            if (!commit.isEmpty()) {
                deadKeyMeta = false;
                commit = stripDeadKeyAccent(commit);
            }
            composed.setLength(0);
        }
        if (!commit.isEmpty()) {
            typeInput(commit.getBytes(StandardCharsets.UTF_8));
        }
        composedText = composed.toString();
        repaintCursor();
        repaint();
        event.consume();
    }

    /** See {@link #onInputMethodText}: the text a dead-key composition commits, minus the
     * accent the Meta chord left behind. */
    static String stripDeadKeyAccent(String committed) {
        String bare = java.text.Normalizer.normalize(committed, java.text.Normalizer.Form.NFD)
                .replaceAll("\\p{M}", "")
                .replaceAll("[\u00b4\u02c6\u02dc\u00a8\u0060\u02c7\u02d8]", "");
        return bare.isEmpty() ? " " : java.text.Normalizer.normalize(bare, java.text.Normalizer.Form.NFC);
    }

    @Override
    public InputMethodRequests getInputMethodRequests() {
        return imRequests;
    }

    private final InputMethodRequests imRequests = new InputMethodRequests() {
        @Override
        public Rectangle getTextLocation(TextHitInfo offset) {
            int row;
            int column;
            emulator.lock().lock();
            try {
                row = emulator.cursorRow() + Math.min(scrollOffset, emulator.historySize());
                column = emulator.cursorColumn();
            } finally {
                emulator.lock().unlock();
            }
            Insets in = getInsets();
            Rectangle r = new Rectangle(in.left + (int) Math.floor(column * fonts.cellWidth() / scale),
                    in.top + (int) Math.floor(row * fonts.cellHeight() / scale), 0, pointsCeil(fonts.cellHeight()));
            if (isShowing()) {
                Point p = getLocationOnScreen();
                r.translate(p.x, p.y);
            }
            return r;
        }

        @Override
        public TextHitInfo getLocationOffset(int x, int y) {
            return null;
        }

        @Override
        public int getInsertPositionOffset() {
            return 0;
        }

        @Override
        public AttributedCharacterIterator getCommittedText(int beginIndex, int endIndex,
                                                            AttributedCharacterIterator.Attribute[] attributes) {
            return new AttributedString("").getIterator();
        }

        @Override
        public int getCommittedTextLength() {
            return 0;
        }

        @Override
        public AttributedCharacterIterator cancelLatestCommittedText(
                AttributedCharacterIterator.Attribute[] attributes) {
            return null;
        }

        @Override
        public AttributedCharacterIterator getSelectedText(AttributedCharacterIterator.Attribute[] attributes) {
            return new AttributedString("").getIterator();
        }
    };
}
