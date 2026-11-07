package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.vt.TerminalEmulator.MouseTracking;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import javax.swing.SwingUtilities;
import java.awt.Dimension;
import java.awt.Graphics2D;
import java.awt.event.FocusEvent;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.awt.event.MouseEvent;
import java.awt.event.MouseWheelEvent;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TerminalViewTest {

    private static final String E = "\u001b";
    private static final String C = E + "[";
    private static final int[] PALETTE = AnsiPalettes.forSetting(AppSettings.TerminalPalette.MACOS_TERMINAL);
    private static final int BACKGROUND = 0x101010;

    private final ByteArrayOutputStream written = new ByteArrayOutputStream();
    private final List<String> resizes = new ArrayList<>();
    private TerminalView view;

    @BeforeEach
    void setUp() throws Exception {
        view = edt(() -> new TerminalView(20, 5, 100, new TerminalView.Output() {
            @Override
            public void write(byte[] bytes) {
                written.writeBytes(bytes);
            }

            @Override
            public void resize(int columns, int rows) {
                resizes.add(columns + "x" + rows);
            }
        }, PALETTE, BACKGROUND, false, "Monospaced", 12));
        edtRun(() -> {
            view.setSize(20 * view.cellWidth(), 5 * view.cellHeight());
            view.setShowingForTest(true); // headless components never show
        });
    }

    static <T> T edt(Callable<T> task) throws Exception {
        AtomicReference<T> result = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        SwingUtilities.invokeAndWait(() -> {
            try {
                result.set(task.call());
            } catch (Exception e) {
                failure.set(e);
            }
        });
        if (failure.get() != null) {
            throw failure.get();
        }
        return result.get();
    }

    static void edtRun(Runnable task) throws Exception {
        SwingUtilities.invokeAndWait(task);
    }

    /** Feeds and waits for the frame it queues to run. */
    private void feed(String s) throws Exception {
        long before = edt(view::frames);
        view.feed(s.getBytes(StandardCharsets.UTF_8), 0, s.getBytes(StandardCharsets.UTF_8).length);
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (edt(view::frames) == before && System.nanoTime() < deadline) {
            Thread.sleep(2);
        }
        assertTrue(edt(view::frames) > before, "a frame ran");
    }

    private String takeWritten() {
        String s = written.toString(StandardCharsets.UTF_8);
        written.reset();
        return s;
    }

    private String row(int y) throws Exception {
        return edt(() -> view.emulator().line(y).toString().stripTrailing());
    }

    // --- size ---------------------------------------------------------------------------

    @Test
    void gridSizeFromPixels() {
        assertEquals(new Dimension(100, 32), TerminalView.gridSize(800, 512, 8, 16));
        assertEquals(new Dimension(99, 31), TerminalView.gridSize(799, 511, 8, 16));
        assertEquals(new Dimension(2, 2), TerminalView.gridSize(5, 5, 8, 16));
        assertEquals(new Dimension(2, 2), TerminalView.gridSize(0, 0, 8, 16));
    }

    @Test
    void preferredSizeIsTheInitialGrid() throws Exception {
        Dimension d = edt(view::getPreferredSize);
        assertEquals(20 * view.cellWidth(), d.width);
        assertEquals(5 * view.cellHeight(), d.height);
    }

    @Test
    void layoutResizesTheEmulatorAndTheConnection() throws Exception {
        edtRun(() -> {
            view.setSize(30 * view.cellWidth() + 3, 10 * view.cellHeight() + 1);
            view.applyResize();
        });
        assertEquals(List.of("30x10"), resizes);
        assertEquals(30, (int) edt(() -> view.emulator().columns()));
        assertEquals(10, (int) edt(() -> view.emulator().rows()));
        edtRun(() -> {
            view.setSize(30 * view.cellWidth(), 10 * view.cellHeight());
            view.applyResize(); // same grid: no second resize
        });
        assertEquals(1, resizes.size());
    }

    // --- device scale (Retina) ------------------------------------------------------------

    /** At 2× the cell is measured in device pixels, so rounding costs half a point instead
     * of a point: Menlo 14 keeps its own proportions (8.5 × 16.5 points) where whole points
     * gave 8 × 17, lines about 6% too far apart. */
    @Test
    void retinaCellsKeepTheFontsProportions() {
        org.junit.jupiter.api.Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"), "needs Menlo");
        java.awt.Font menlo = new java.awt.Font("Menlo", java.awt.Font.PLAIN, 14);
        // the font's design proportions: unhinted (fractional) advance
        java.awt.font.FontRenderContext design = new java.awt.font.FontRenderContext(null, true, true);
        java.awt.font.LineMetrics lm = menlo.getLineMetrics("Wg", design);
        double natural = (lm.getAscent() + lm.getDescent() + lm.getLeading())
                / menlo.getStringBounds("W", design).getWidth();
        TerminalFonts points = new TerminalFonts("Menlo", 14, 1);
        TerminalFonts retina = new TerminalFonts("Menlo", 14, 2);
        double atPoints = points.cellHeight() / (double) points.cellWidth();
        double atRetina = retina.cellHeight() / (double) retina.cellWidth();
        assertTrue(Math.abs(atRetina - natural) < Math.abs(atPoints - natural),
                "2x " + retina.cellWidth() + "x" + retina.cellHeight() + " vs 1x "
                        + points.cellWidth() + "x" + points.cellHeight() + ", natural " + natural);
        assertTrue(Math.abs(atRetina / natural - 1) < 0.03, "within 3% of the font: " + atRetina + " / " + natural);
    }

    /** Swing sizes are in points and the grid in device pixels: the preferred size covers
     * the grid, a point size maps to the grid that fits it, and the mouse hits the cell
     * under it. */
    @Test
    void atTwoXTheViewConvertsBetweenPointsAndDevicePixels() throws Exception {
        edtRun(() -> view.setDeviceScale(2));
        int cw = edt(view::cellWidth);
        int ch = edt(view::cellHeight);
        Dimension preferred = edt(view::getPreferredSize);
        assertEquals((int) Math.ceil(20 * cw / 2.0), preferred.width);
        assertEquals((int) Math.ceil(5 * ch / 2.0), preferred.height);
        resizes.clear();
        edtRun(() -> {
            view.setSize((int) Math.ceil(33 * cw / 2.0), (int) Math.ceil(9 * ch / 2.0));
            view.applyResize();
        });
        assertEquals(List.of("33x9"), resizes);
        feed(E + "[?1000h" + E + "[?1006h");
        takeWritten();
        // the centre of cell (column 7, row 3), in points
        int x = (int) Math.floor((7 * cw + cw / 2.0) / 2);
        int y = (int) Math.floor((3 * ch + ch / 2.0) / 2);
        edtRun(() -> view.processMouseEvent(new MouseEvent(view, MouseEvent.MOUSE_PRESSED, 0,
                InputEvent.BUTTON1_DOWN_MASK, x, y, 1, false, MouseEvent.BUTTON1)));
        assertEquals(E + "[<0;8;4M", takeWritten());
    }

    @Test
    void fontChangeReflowsTheGrid() throws Exception {
        edtRun(() -> {
            view.setSize(400, 200);
            view.applyResize();
        });
        String first = resizes.getLast();
        edtRun(() -> {
            view.setTerminalFont("Monospaced", 24);
            view.applyResize();
        });
        assertFalse(first.equals(resizes.getLast()), resizes.toString());
        assertEquals(TerminalView.gridSize(400, 200, view.cellWidth(), view.cellHeight()).width,
                (int) edt(() -> view.emulator().columns()));
    }

    // --- scrollback ---------------------------------------------------------------------

    private void lines(int from, int to) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (int i = from; i < to; i++) {
            sb.append("line").append(i).append("\r\n");
        }
        feed(sb.toString());
    }

    @Test
    void scrolledBackViewStaysAnchoredWhileOutputArrives() throws Exception {
        lines(0, 50);
        edtRun(view::pageUp);
        assertEquals(5, (int) edt(view::scrollOffset));
        lines(50, 60);
        assertEquals(15, (int) edt(view::scrollOffset), "anchored on the same lines");
        assertEquals(-15, (int) edt(() -> view.scrollModel().getValue()));
        edtRun(view::scrollToBottom);
        lines(60, 70);
        assertEquals(0, (int) edt(view::scrollOffset), "live view follows");
    }

    @Test
    void pagingIsClampedToTheHistory() throws Exception {
        lines(0, 12);
        edtRun(view::scrollToTop);
        int history = edt(() -> view.emulator().historySize());
        assertEquals(history, (int) edt(view::scrollOffset));
        edtRun(view::pageUp);
        assertEquals(history, (int) edt(view::scrollOffset));
        edtRun(view::pageDown);
        assertEquals(history - 5, (int) edt(view::scrollOffset));
        edtRun(() -> view.scrollModel().setValue(-2)); // the scrollbar drives the offset
        assertEquals(2, (int) edt(view::scrollOffset));
    }

    @Test
    void typingReturnsToTheLiveScreen() throws Exception {
        lines(0, 30);
        edtRun(view::pageUp);
        edtRun(() -> key(KeyEvent.VK_A, 'a', 0));
        assertEquals(0, (int) edt(view::scrollOffset));
        assertEquals("a", takeWritten());
    }

    // --- wheel --------------------------------------------------------------------------

    @Test
    void wheelRouting() {
        assertEquals(TerminalView.WheelRoute.SWALLOW, TerminalView.wheelRoute(true, MouseTracking.NORMAL, true));
        assertEquals(TerminalView.WheelRoute.SWALLOW, TerminalView.wheelRoute(true, MouseTracking.NONE, false));
        assertEquals(TerminalView.WheelRoute.MOUSE_REPORT, TerminalView.wheelRoute(false, MouseTracking.X10, false));
        assertEquals(TerminalView.WheelRoute.MOUSE_REPORT, TerminalView.wheelRoute(false, MouseTracking.ANY_MOTION, true));
        assertEquals(TerminalView.WheelRoute.ARROW_KEYS, TerminalView.wheelRoute(false, MouseTracking.NONE, true));
        assertEquals(TerminalView.WheelRoute.SCROLLBACK, TerminalView.wheelRoute(false, MouseTracking.NONE, false));
    }

    private void wheel(int rotation, int modifiers) {
        view.processMouseWheelEvent(new MouseWheelEvent(view, MouseEvent.MOUSE_WHEEL, 0, modifiers,
                view.cellWidth() * 2 + 1, 1, 0, false, MouseWheelEvent.WHEEL_UNIT_SCROLL, 3, rotation));
    }

    @Test
    void wheelScrollsLocalHistory() throws Exception {
        lines(0, 30);
        edtRun(() -> wheel(-1, 0));
        assertEquals(3, (int) edt(view::scrollOffset));
        edtRun(() -> wheel(1, 0));
        assertEquals(0, (int) edt(view::scrollOffset));
        assertEquals("", takeWritten());
    }

    @Test
    void disabledWheelIsSwallowed() throws Exception {
        lines(0, 30);
        feed(C + "?1000h" + C + "?1006h");
        edtRun(() -> {
            view.setMouseWheelDisabled(true);
            wheel(-1, 0);
        });
        assertEquals(0, (int) edt(view::scrollOffset));
        assertEquals("", takeWritten());
    }

    @Test
    void wheelIsReportedWhenTheProgramTracksTheMouse() throws Exception {
        feed(C + "?1000h" + C + "?1006h");
        edtRun(() -> wheel(-1, 0));
        assertEquals(C + "<64;3;1M", takeWritten());
        edtRun(() -> wheel(2, InputEvent.CTRL_DOWN_MASK));
        assertEquals(C + "<81;3;1M" + C + "<81;3;1M", takeWritten());
    }

    @Test
    void wheelOnTheAlternateScreenSendsArrows() throws Exception {
        feed(C + "?1049h");
        edtRun(() -> wheel(-1, 0));
        assertEquals((C + "A").repeat(3), takeWritten());
        feed(C + "?1h");
        edtRun(() -> wheel(1, 0));
        assertEquals((E + "OB").repeat(3), takeWritten());
    }

    // --- replies ------------------------------------------------------------------------

    @Test
    void answersOnlyTheColourSchemeQuery() throws Exception {
        feed(C + "?996n");
        assertEquals(C + "?997;1n", takeWritten());
        edtRun(() -> view.setTheme(null, true));
        feed(C + "?996n" + C + "?6n" + C + "?u" + C + ">q" + C + "?2004$p" + C + "c" + C + "5n");
        assertEquals(C + "?997;2n", takeWritten());
    }

    // --- keyboard -----------------------------------------------------------------------

    private void key(int keyCode, char keyChar, int modifiers) {
        KeyEvent press = new KeyEvent(view, KeyEvent.KEY_PRESSED, 0, modifiers, keyCode,
                keyChar == 0 ? KeyEvent.CHAR_UNDEFINED : keyChar);
        view.processKeyEvent(press);
        if (keyChar != 0) {
            view.processKeyEvent(new KeyEvent(view, KeyEvent.KEY_TYPED, 0, modifiers, KeyEvent.VK_UNDEFINED, keyChar));
        }
    }

    @Test
    void typedAndPressedKeysAreSentOnce() throws Exception {
        edtRun(() -> {
            key(KeyEvent.VK_H, 'h', 0);
            key(KeyEvent.VK_I, 'i', 0);
            key(KeyEvent.VK_ENTER, '\n', 0);
            key(KeyEvent.VK_BACK_SPACE, '\b', 0);
            key(KeyEvent.VK_TAB, '\t', 0);
            key(KeyEvent.VK_C, (char) 3, InputEvent.CTRL_DOWN_MASK);
            key(KeyEvent.VK_UP, (char) 0, 0);
        });
        assertEquals("hi\r\u007f\t\u0003" + C + "A", takeWritten());
        feed(C + "?1h");
        edtRun(() -> key(KeyEvent.VK_UP, (char) 0, 0));
        assertEquals(E + "OA", takeWritten());
    }

    @Test
    void commandChordsAreNotSentAndNotConsumed() throws Exception {
        boolean consumed = edt(() -> {
            KeyEvent press = new KeyEvent(view, KeyEvent.KEY_PRESSED, 0, InputEvent.META_DOWN_MASK, KeyEvent.VK_T, 't');
            view.processKeyEvent(press);
            view.processKeyEvent(new KeyEvent(view, KeyEvent.KEY_TYPED, 0, InputEvent.META_DOWN_MASK,
                    KeyEvent.VK_UNDEFINED, 't'));
            return press.isConsumed();
        });
        assertFalse(consumed, "left for the window's shortcuts");
        assertEquals("", takeWritten());
    }

    @Test
    void focusIsReportedWhenAsked() throws Exception {
        edtRun(() -> view.processFocusEvent(new FocusEvent(view, FocusEvent.FOCUS_GAINED)));
        assertEquals("", takeWritten());
        feed(C + "?1004h");
        edtRun(() -> {
            view.processFocusEvent(new FocusEvent(view, FocusEvent.FOCUS_GAINED));
            view.processFocusEvent(new FocusEvent(view, FocusEvent.FOCUS_LOST));
        });
        assertEquals(C + "I" + C + "O", takeWritten());
    }

    @Test
    void pasteIsNormalisedAndBracketed() throws Exception {
        edtRun(() -> view.pasteText("a\nb"));
        assertEquals("a\rb", takeWritten());
        feed(C + "?2004h");
        edtRun(() -> view.pasteText("x" + C + "201~y\r\n"));
        assertEquals(C + "200~xy\r" + C + "201~", takeWritten());
    }

    // --- input methods ------------------------------------------------------------------

    private void inputMethod(String text, int committed) {
        java.text.AttributedString s = new java.text.AttributedString(text);
        view.dispatchEvent(new java.awt.event.InputMethodEvent(view,
                java.awt.event.InputMethodEvent.INPUT_METHOD_TEXT_CHANGED,
                text.isEmpty() ? null : s.getIterator(), committed, null, null));
    }

    @Test
    void inputMethodCommitsAreSentAndCompositionIsHeldBack() throws Exception {
        edtRun(() -> inputMethod("にほ", 0));
        assertEquals("", takeWritten());
        edtRun(() -> inputMethod("日本語", 3));
        assertEquals("日本語", takeWritten());
        edtRun(() -> inputMethod("é", 1)); // a dead-key composition committed normally
        assertEquals("é", takeWritten());
    }

    @Test
    void optionDeadKeyIsMetaAndTheFollowingKeyLosesTheAccent() throws Exception {
        org.junit.jupiter.api.Assumptions.assumeTrue(System.getProperty("os.name").startsWith("Mac"));
        edtRun(() -> {
            view.processKeyEvent(new KeyEvent(view, KeyEvent.KEY_PRESSED, 0, InputEvent.ALT_DOWN_MASK,
                    KeyEvent.VK_E, KeyEvent.CHAR_UNDEFINED));
            inputMethod("\u00b4", 0); // the marked accent: hidden
            inputMethod("\u00e1", 1); // the next key, 'a', commits á
        });
        assertEquals(E + "ea", takeWritten());
        assertEquals("a", TerminalView.stripDeadKeyAccent("\u00e1"));
        assertEquals(" ", TerminalView.stripDeadKeyAccent("\u00b4"));
        assertEquals("x", TerminalView.stripDeadKeyAccent("\u00b4x"));
        assertEquals("n", TerminalView.stripDeadKeyAccent("\u00f1"));
    }

    // --- context menu -------------------------------------------------------------------

    private static java.util.List<String> labels(javax.swing.JPopupMenu menu) {
        java.util.List<String> out = new java.util.ArrayList<>();
        for (java.awt.Component c : menu.getComponents()) {
            out.add(c instanceof javax.swing.JMenuItem item ? item.getText() + (item.isEnabled() ? "" : " (off)") : "-");
        }
        return out;
    }

    @Test
    void contextMenuEnablesCopyOnlyWithASelectionAndPagingOnlyWithHistory() throws Exception {
        feed("hello");
        edtRun(() -> assertEquals(java.util.List.of("Copy (off)", "Paste", "Select All", "-",
                "Page Up (off)", "Page Down (off)"), labels(view.contextMenu())));
        lines(0, 60);
        edtRun(() -> {
            view.selectAll();
            assertEquals(java.util.List.of("Copy", "Paste", "Select All", "-", "Page Up", "Page Down (off)"),
                    labels(view.contextMenu()));
            ((javax.swing.JMenuItem) view.contextMenu().getComponent(4)).doClick();
            assertTrue(view.scrollOffset() > 0);
            assertEquals("Page Down", labels(view.contextMenu()).get(5));
        });
    }

    @Test
    void rightClickGoesToAProgramThatTracksTheMouse() throws Exception {
        feed(E + "[?1000h");
        takeWritten();
        edtRun(() -> view.processMouseEvent(new MouseEvent(view, MouseEvent.MOUSE_PRESSED, 0,
                InputEvent.BUTTON3_DOWN_MASK, 1, 1, 1, true, MouseEvent.BUTTON3)));
        assertTrue(takeWritten().startsWith(E + "[M"), "reported to the program, no menu");
    }

    // --- selection ----------------------------------------------------------------------

    private MouseEvent mouse(int id, int column, int row, int modifiers, int clicks) {
        int x = column * view.cellWidth() + 1;
        int y = row * view.cellHeight() + 1;
        return new MouseEvent(view, id, 0, modifiers, x, y, clicks, false, MouseEvent.BUTTON1);
    }

    private void drag(int c0, int r0, int c1, int r1, int modifiers) {
        int button = InputEvent.BUTTON1_DOWN_MASK;
        view.processMouseEvent(mouse(MouseEvent.MOUSE_PRESSED, c0, r0, modifiers | button, 1));
        view.processMouseMotionEvent(mouse(MouseEvent.MOUSE_DRAGGED, c1, r1, modifiers | button, 0));
        view.processMouseEvent(mouse(MouseEvent.MOUSE_RELEASED, c1, r1, modifiers, 1));
    }

    @Test
    void dragSelectsCharacters() throws Exception {
        feed("hello world\r\nsecond line");
        edtRun(() -> drag(6, 0, 6, 1, 0));
        assertEquals("world\nsecond", edt(view::selectedText));
        edtRun(() -> view.processMouseEvent(mouse(MouseEvent.MOUSE_PRESSED, 3, 1, InputEvent.BUTTON1_DOWN_MASK, 2)));
        assertEquals("second", edt(view::selectedText));
        edtRun(() -> view.processMouseEvent(mouse(MouseEvent.MOUSE_PRESSED, 3, 0, InputEvent.BUTTON1_DOWN_MASK, 3)));
        assertEquals("hello world", edt(view::selectedText));
        edtRun(() -> key(KeyEvent.VK_X, 'x', 0));
        assertNull(edt(view::selectedText), "typing clears the selection");
    }

    @Test
    void shiftClickExtends() throws Exception {
        feed("abcdefghij");
        edtRun(() -> {
            drag(1, 0, 3, 0, 0);
            view.processMouseEvent(mouse(MouseEvent.MOUSE_PRESSED, 6, 0, InputEvent.SHIFT_DOWN_MASK | InputEvent.BUTTON1_DOWN_MASK, 1));
            view.processMouseEvent(mouse(MouseEvent.MOUSE_RELEASED, 6, 0, InputEvent.SHIFT_DOWN_MASK, 1));
        });
        assertEquals("bcdef", edt(view::selectedText));
    }

    @Test
    void selectionWorksInScrollbackAndSurvivesNewOutput() throws Exception {
        lines(0, 20);
        edtRun(view::pageUp);
        String top = row(-edt(view::scrollOffset));
        edtRun(() -> drag(0, 0, 6, 0, 0));
        assertEquals(top.substring(0, 6), edt(view::selectedText));
        lines(20, 23);
        assertEquals(top.substring(0, 6), edt(view::selectedText), "anchored to its lines");
        edtRun(view::selectAll);
        assertTrue(edt(view::selectedText).startsWith("line0\nline1\n"));
    }

    @Test
    void mouseTrackingTakesPlainClicksAndShiftStillSelects() throws Exception {
        feed("hello world");
        feed(C + "?1002h" + C + "?1006h");
        edtRun(() -> drag(0, 0, 4, 0, 0));
        assertEquals(C + "<0;1;1M" + C + "<32;5;1M" + C + "<0;5;1m", takeWritten());
        assertNull(edt(view::selectedText));
        edtRun(() -> drag(0, 0, 5, 0, InputEvent.SHIFT_DOWN_MASK));
        assertEquals("", takeWritten());
        assertEquals("hello", edt(view::selectedText));
    }

    // --- painting -----------------------------------------------------------------------

    private BufferedImage paint() throws Exception {
        return edt(() -> {
            view.setSize(20 * view.cellWidth(), 5 * view.cellHeight());
            BufferedImage image = new BufferedImage(view.getWidth(), view.getHeight(), BufferedImage.TYPE_INT_RGB);
            Graphics2D g = image.createGraphics();
            g.setClip(0, 0, view.getWidth(), view.getHeight());
            view.paint(g);
            g.dispose();
            return image;
        });
    }

    private int pixel(BufferedImage image, int column, int row, int dx, int dy) {
        return image.getRGB(column * view.cellWidth() + dx, row * view.cellHeight() + dy) & 0xFFFFFF;
    }

    @Test
    void paintsBackgroundsInverseBoxDrawingAndTheCursor() throws Exception {
        feed(C + "41m  " + C + "0m " + C + "7m " + C + "0m\r\n"
                + "─────\r\n"
                + C + "48;2;1;2;3m " + C + "0m\r\n"
                + C + "4;3H");
        BufferedImage image = paint();
        int cw = view.cellWidth();
        int ch = view.cellHeight();
        assertEquals(BACKGROUND, pixel(image, 10, 0, cw / 2, ch / 2), "default background");
        assertEquals(PALETTE[1], pixel(image, 0, 0, cw / 2, ch / 2), "explicit red background");
        assertEquals(PALETTE[1], pixel(image, 1, 0, 0, 0), "merged run");
        assertEquals(PALETTE[15], pixel(image, 3, 0, cw / 2, ch / 2), "inverse: default fg behind");
        assertEquals(0x010203, pixel(image, 0, 2, cw / 2, ch / 2), "truecolor background");
        int t = Math.max(1, Math.round(cw / 8f));
        assertEquals(PALETTE[15], pixel(image, 2, 1, cw / 2, (ch - t) / 2), "box line through the cell");
        assertEquals(PALETTE[15], pixel(image, 2, 1, 0, (ch - t) / 2), "reaches the cell edge");
        assertEquals(BACKGROUND, pixel(image, 2, 1, cw / 2, 1), "only the line");
        // unfocused cursor at row 3, column 2: a hollow block
        assertEquals(PALETTE[15], pixel(image, 2, 3, 0, 0), "cursor outline");
        assertEquals(BACKGROUND, pixel(image, 2, 3, cw / 2, ch / 2), "hollow inside");
        feed(C + "?25l");
        assertEquals(BACKGROUND, pixel(paint(), 2, 3, 0, 0), "hidden cursor");
    }

    @Test
    void reverseVideoSwapsTheDefaults() throws Exception {
        feed(C + "?5h");
        assertEquals(PALETTE[15], pixel(paint(), 10, 2, 3, 3));
    }

    @Test
    void themeAndPaletteRecolourLive() throws Exception {
        feed(C + "41m " + C + "0m");
        edtRun(() -> {
            view.setTheme(null, true);
            view.setPalette(AnsiPalettes.forSetting(AppSettings.TerminalPalette.XTERM));
        });
        BufferedImage image = paint();
        assertEquals(0xFFFFFF, pixel(image, 10, 2, 3, 3), "light default background from the palette");
        assertEquals(0xCD0000, pixel(image, 0, 0, 3, 3), "existing cell repainted in the new palette");
    }

    @Test
    void selectionIsHighlighted() throws Exception {
        feed("abc");
        edtRun(() -> drag(0, 0, 2, 0, 0));
        BufferedImage image = paint();
        assertEquals(0x264F78, pixel(image, 0, 0, 0, 0));
        assertEquals(BACKGROUND, pixel(image, 2, 0, 0, 0));
    }

    // --- damage -------------------------------------------------------------------------

    /** Records the view's repaint requests (dirty regions, in points). */
    private static final class Recorder extends javax.swing.RepaintManager {
        final javax.swing.JComponent target;
        final List<java.awt.Rectangle> rects = java.util.Collections.synchronizedList(new ArrayList<>());

        Recorder(javax.swing.JComponent target) {
            this.target = target;
        }

        @Override
        public void addDirtyRegion(javax.swing.JComponent c, int x, int y, int w, int h) {
            if (c == target) {
                rects.add(new java.awt.Rectangle(x, y, w, h));
            }
            super.addDirtyRegion(c, x, y, w, h);
        }
    }

    /** Runs {@code action} with a recording repaint manager and returns what it asked for. */
    private List<java.awt.Rectangle> recordRepaints(ThrowingRunnable action) throws Exception {
        javax.swing.RepaintManager previous = edt(() -> javax.swing.RepaintManager.currentManager(view));
        Recorder recorder = new Recorder(view);
        edtRun(() -> javax.swing.RepaintManager.setCurrentManager(recorder));
        try {
            action.run();
            edtRun(() -> { }); // anything queued on the EDT has run
            return new ArrayList<>(recorder.rects);
        } finally {
            edtRun(() -> javax.swing.RepaintManager.setCurrentManager(previous));
        }
    }

    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    private void tallView() throws Exception {
        edtRun(() -> {
            view.setSize(20 * view.cellWidth(), 12 * view.cellHeight());
            view.applyResize();
        });
        feed(C + "6;4H"); // the cursor parks on row 5 (0-based)
    }

    @Test
    void writingOneCellRepaintsOnlyItsRow() throws Exception {
        tallView();
        long full = edt(view::fullFrames);
        int ch = view.cellHeight();
        List<java.awt.Rectangle> rects = recordRepaints(() -> feed("x"));
        assertEquals(full, (long) edt(view::fullFrames), "no full repaint");
        assertFalse(rects.isEmpty(), "the changed row is repainted");
        java.awt.Rectangle union = rects.getFirst();
        for (java.awt.Rectangle r : rects) {
            union = union.union(r);
        }
        // row 5 plus a row of margin either side (and a pixel of rounding)
        assertTrue(union.y >= 4 * ch - 1 && union.y + union.height <= 7 * ch + 2, union + " vs cell height " + ch);
        assertTrue(union.y <= 5 * ch && union.y + union.height >= 6 * ch, "covers the row: " + union);
        assertTrue(row(5).endsWith("x"));
    }

    @Test
    void aSpinnerElsewhereRepaintsItsRowAndTheCursorRow() throws Exception {
        tallView();
        int ch = view.cellHeight();
        // save cursor, write on row 1, restore: rows 0..2 change, the cursor row 5 is damaged too
        List<java.awt.Rectangle> rects = recordRepaints(() -> feed(E + "7" + C + "2;1H|" + E + "8"));
        java.awt.Rectangle union = rects.getFirst();
        for (java.awt.Rectangle r : rects) {
            union = union.union(r);
        }
        assertTrue(union.y + union.height <= 7 * ch + 2, "nothing below the cursor row: " + union);
        assertTrue(union.height < 12 * ch, "not the whole view: " + union);
    }

    @Test
    void scrollingRepaintsEverything() throws Exception {
        tallView();
        long full = edt(view::fullFrames);
        List<java.awt.Rectangle> rects = recordRepaints(() -> lines(0, 20));
        assertTrue(edt(view::fullFrames) > full, "output that scrolled the screen repaints it all");
        assertTrue(rects.stream().anyMatch(r -> r.y <= 0 && r.height >= view.getHeight()), rects.toString());
        full = edt(view::fullFrames);
        edtRun(view::pageUp);
        feed("y"); // the view is scrolled back: the next frame repaints everything
        assertTrue(edt(view::fullFrames) > full);
    }

    @Test
    void modeChangesRepaintEverything() throws Exception {
        tallView();
        long full = edt(view::fullFrames);
        feed(C + "?5h");
        assertEquals(full + 1, (long) edt(view::fullFrames), "reverse video");
        feed(C + "?1049h");
        assertEquals(full + 2, (long) edt(view::fullFrames), "alternate screen");
        feed(C + "?25l");
        assertEquals(full + 3, (long) edt(view::fullFrames), "cursor hidden");
        edtRun(view::selectAll);
        feed("z");
        assertEquals(full + 4, (long) edt(view::fullFrames), "selection");
    }

    @Test
    void hiddenViewDoesNoFrameWorkAndCatchesUpWhenShown() throws Exception {
        lines(0, 30);
        edtRun(view::pageUp);
        int offset = edt(view::scrollOffset);
        edtRun(() -> view.setShowingForTest(false));
        long frames = edt(view::frames);
        long full = edt(view::fullFrames);
        List<java.awt.Rectangle> rects = recordRepaints(() -> {
            for (int i = 0; i < 5; i++) {
                String s = "hidden" + i + "\r\n";
                view.feed(s.getBytes(StandardCharsets.UTF_8), 0, s.length());
                Thread.sleep(30);
            }
        });
        assertEquals(frames, (long) edt(view::frames), "no frames while hidden");
        assertTrue(rects.isEmpty(), rects.toString());
        assertEquals(offset, (int) edt(view::scrollOffset), "not re-anchored yet");
        edtRun(() -> view.setShowingForTest(true));
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (edt(view::frames) == frames && System.nanoTime() < deadline) {
            Thread.sleep(2);
        }
        assertEquals(frames + 1, (long) edt(view::frames), "one catch-up frame");
        assertEquals(full + 1, (long) edt(view::fullFrames), "a full repaint");
        assertEquals(offset + 5, (int) edt(view::scrollOffset), "anchored over everything that arrived");
        feed("more"); // frames run normally again
    }

    @Test
    void partialRepaintPaintsTheSameAsAFullOne() throws Exception {
        feed(C + "41mab" + C + "0m\r\n" + C + "4mcd" + C + "0m\r\n─┼─");
        BufferedImage full = paint();
        BufferedImage partial = edt(() -> {
            BufferedImage image = new BufferedImage(view.getWidth(), view.getHeight(), BufferedImage.TYPE_INT_RGB);
            Graphics2D g = image.createGraphics();
            int ch = view.cellHeight();
            for (int r = 0; r < 5; r++) {
                Graphics2D rg = (Graphics2D) g.create();
                rg.setClip(0, r * ch, view.getWidth(), ch); // one row at a time
                view.paint(rg);
                rg.dispose();
            }
            g.dispose();
            return image;
        });
        for (int y = 0; y < full.getHeight(); y++) {
            for (int x = 0; x < full.getWidth(); x++) {
                assertEquals(full.getRGB(x, y), partial.getRGB(x, y), "pixel " + x + "," + y);
            }
        }
    }
}
