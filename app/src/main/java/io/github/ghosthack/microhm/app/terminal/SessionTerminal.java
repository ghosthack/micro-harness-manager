package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.app.host.SessionConnection;
import io.github.ghosthack.microhm.app.settings.AppSettings;

import javax.swing.JComponent;
import javax.swing.JPanel;
import javax.swing.JScrollBar;
import javax.swing.SwingUtilities;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

/**
 * The embedded terminal over an already-open {@link SessionConnection} (a daemon attach
 * stream). One of these is created per session, lazily, once its connection lands, and
 * then kept alive for the app's lifetime — switching sessions only changes which
 * component's card is visible. Opening the connection (which may block) happens on the
 * host, off the EDT; this class only builds Swing state and is EDT-only.
 *
 * <p>It adapts the app's settings to a {@link TerminalView} and pumps the connection:
 * <ul>
 *   <li>a platform daemon <b>reader</b> thread reads the connection into the view's emulator
 *       until the stream ends ({@code -1} or an error), then marks the view ended (the window
 *       polls {@link #isAlive()} to drop it);</li>
 *   <li>a single <b>writer</b> thread sends input, replies and resizes in order, so a large
 *       paste or a slow daemon never blocks the EDT.</li>
 * </ul>
 */
public final class SessionTerminal {

    public static final int COLUMNS = 120;
    public static final int ROWS = 32;
    /** Lines of local scrollback per terminal. */
    static final int HISTORY_LINES = 5000;

    private final SessionConnection connection;
    private final TerminalView view;
    private final JPanel panel;
    private final JScrollBar scrollBar;
    private final ExecutorService writer;
    private final Thread reader;
    private boolean detached;

    /** The settings a terminal is built with. */
    record Config(Color background, boolean light, int[] palette, boolean scrollbarHidden,
                  boolean mouseWheelDisabled, String fontFamily, int fontSize) {
    }

    private SessionTerminal(SessionConnection connection, Config config) {
        this.connection = connection;
        String name = connection.name();
        this.writer = Executors.newSingleThreadExecutor(runnable -> {
            Thread t = new Thread(runnable, "microhm-terminal-writer-" + name);
            t.setDaemon(true);
            return t;
        });
        this.view = new TerminalView(COLUMNS, ROWS, HISTORY_LINES, new TerminalView.Output() {
            @Override
            public void write(byte[] bytes) {
                send(() -> connection.write(bytes));
            }

            @Override
            public void resize(int columns, int rows) {
                send(() -> connection.resize(columns, rows));
            }
        }, config.palette(), config.background() == null ? null : config.background().getRGB() & 0xFFFFFF,
                config.light(), config.fontFamily(), AppSettings.clampTerminalFontSize(config.fontSize()));
        view.setMouseWheelDisabled(config.mouseWheelDisabled());

        panel = new JPanel(new BorderLayout());
        panel.add(view, BorderLayout.CENTER);
        scrollBar = new JScrollBar(JScrollBar.VERTICAL);
        scrollBar.setModel(view.scrollModel());
        scrollBar.setFocusable(false);
        if (config.scrollbarHidden()) {
            scrollBar.setPreferredSize(new Dimension(0, 0));
            scrollBar.setVisible(false);
        }
        panel.add(scrollBar, BorderLayout.EAST);
        syncChrome();

        this.reader = new Thread(this::pump, "microhm-terminal-reader-" + name);
        reader.setDaemon(true);
        reader.start();
    }

    /**
     * Builds the terminal over {@code connection} and starts reading from it. The
     * connection was opened at {@link #COLUMNS}x{@link #ROWS}; the view's first real
     * layout resizes it. {@code mouseWheelDisabled} swallows every wheel event (Codex
     * navigates on wheel gestures). Call on the EDT.
     */
    public static SessionTerminal open(SessionConnection connection, boolean mouseWheelDisabled,
                                       String fontFamily, int fontSize) {
        AppSettings.TerminalBackground background = AppSettings.terminalBackground();
        SessionTerminal terminal = create(connection, new Config(null,
                background == AppSettings.TerminalBackground.WHITE,
                AnsiPalettes.forSetting(AppSettings.terminalPalette()), AppSettings.terminalScrollbarHidden(),
                mouseWheelDisabled, fontFamily, fontSize));
        terminal.applyOptionAsMeta(AppSettings.optionAsMeta());
        return terminal;
    }

    /** {@link #open} without reading the settings (tests). */
    static SessionTerminal create(SessionConnection connection, Config config) {
        return new SessionTerminal(connection, config);
    }

    private interface IoAction {
        void run() throws IOException;
    }

    private void send(IoAction action) {
        try {
            writer.execute(() -> {
                try {
                    action.run();
                } catch (IOException | RuntimeException lost) {
                    // the connection is going away; the reader notices and ends the view
                }
            });
        } catch (RejectedExecutionException detachedAlready) {
            // input after detach goes nowhere
        }
    }

    private void pump() {
        byte[] buffer = new byte[64 * 1024];
        try {
            while (true) {
                int n = connection.read(buffer, 0, buffer.length);
                if (n < 0) {
                    break;
                }
                if (n > 0) {
                    view.feed(buffer, 0, n);
                }
            }
        } catch (IOException | RuntimeException ended) {
            // a closed or broken stream ends the terminal like EOF does
        }
        SwingUtilities.invokeLater(view::markEnded);
    }

    /** The Swing component to show as the session's card. */
    public JComponent component() {
        return panel;
    }

    TerminalView view() {
        return view;
    }

    Thread readerThread() {
        return reader;
    }

    /** Gives the terminal keyboard focus, so typing goes to the session. */
    public void focus() {
        view.requestFocusInWindow();
    }

    /**
     * Recolors this live terminal's default fg/bg pair (theme toggle). Only the
     * defaults flip — cells a program painted with explicit ANSI/256 colors keep them.
     * Also reports light/dark to programs that ask ({@code CSI ?996n}). Call on the EDT.
     */
    public void applyBackground(AppSettings.TerminalBackground background) {
        view.setTheme(null, background == AppSettings.TerminalBackground.WHITE);
        syncChrome();
    }

    /** Matches a UI surface while preserving explicit ANSI colors and reporting its theme. */
    public void applyBackground(Color background, boolean light) {
        view.setTheme(background.getRGB() & 0xFFFFFF, light);
        syncChrome();
    }

    /**
     * Swaps this live terminal's 16-slot ANSI palette. Cells hold color indexes resolved
     * on every paint, so already painted output recolors too. Call on the EDT.
     */
    public void applyPalette(AppSettings.TerminalPalette palette) {
        view.setPalette(AnsiPalettes.forSetting(palette));
        syncChrome();
    }

    /** Changes the font and reflows this live connection to its new row/column dimensions. */
    public void applyFont(String family, int size) {
        view.setTerminalFont(family, AppSettings.clampTerminalFontSize(size));
        panel.revalidate();
    }

    /** macOS: Option+letter/digit as Meta, or composing characters. Applies live. */
    public void applyOptionAsMeta(boolean on) {
        view.setOptionAsMeta(on);
    }

    /** Enables or disables the wheel-event filter immediately. Call on the EDT. */
    public void applyMouseWheelDisabled(boolean disabled) {
        view.setMouseWheelDisabled(disabled);
    }

    public boolean isAlive() {
        return connection.isAlive();
    }

    /** Detaches: stops the reader and writer and closes the connection. The session itself
     * keeps running. Idempotent. */
    public void detach() {
        if (detached) {
            return;
        }
        detached = true;
        writer.shutdown();
        connection.close(); // unblocks the reader, which then ends
        reader.interrupt();
        view.markEnded();
    }

    /** Local scrollback paging — the daemon keeps no server-side history to navigate. */
    public void pageUp() {
        view.pageUp();
    }

    public void pageDown() {
        view.pageDown();
    }

    public void scrollToTop() {
        view.scrollToTop();
    }

    public void scrollToBottom() {
        view.scrollToBottom();
    }

    /** The panel and the scrollbar track take the terminal's background. */
    private void syncChrome() {
        Color background = view.defaultBackground();
        panel.setBackground(background);
        scrollBar.setBackground(background);
    }
}
