package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.app.settings.AppSettings;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import javax.swing.SwingUtilities;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import static io.github.ghosthack.microhm.app.terminal.TerminalViewTest.edt;
import static io.github.ghosthack.microhm.app.terminal.TerminalViewTest.edtRun;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SessionTerminalTest {

    private final FakeConnection connection = new FakeConnection();
    private SessionTerminal terminal;

    private SessionTerminal open() throws Exception {
        terminal = edt(() -> SessionTerminal.create(connection, new SessionTerminal.Config(null, false,
                AnsiPalettes.forSetting(AppSettings.TerminalPalette.MACOS_TERMINAL), false, false, "Monospaced", 12)));
        return terminal;
    }

    @AfterEach
    void tearDown() throws Exception {
        if (terminal != null) {
            edtRun(terminal::detach);
        }
    }

    private static void await(String what, java.util.concurrent.Callable<Boolean> condition) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (!condition.call()) {
            if (System.nanoTime() > deadline) {
                throw new AssertionError("timed out waiting for " + what);
            }
            Thread.sleep(5);
        }
    }

    @Test
    void outputReachesTheModelAndSchedulesAFrame() throws Exception {
        open();
        long frames = edt(() -> terminal.view().frames());
        connection.push("hello \u001b[1mworld\u001b[0m");
        await("model", () -> edt(() -> terminal.view().emulator().line(0).toString().startsWith("hello world")));
        await("frame", () -> edt(() -> terminal.view().frames()) > frames);
        assertTrue(edt(terminal::isAlive));
    }

    @Test
    void endOfStreamEndsTheTerminal() throws Exception {
        open();
        connection.push("bye");
        connection.end();
        await("ended", () -> edt(() -> terminal.view().ended()));
        terminal.readerThread().join(5000);
        assertFalse(terminal.readerThread().isAlive());
        assertFalse(edt(terminal::isAlive));
    }

    @Test
    void detachClosesTheConnectionOnceAndStopsTheReader() throws Exception {
        open();
        edtRun(terminal::detach);
        edtRun(terminal::detach);
        assertEquals(1, connection.closes.get());
        terminal.readerThread().join(5000);
        assertFalse(terminal.readerThread().isAlive());
    }

    @Test
    void inputAndResizesGoToTheConnectionInOrder() throws Exception {
        open();
        edtRun(() -> {
            terminal.view().pasteText("one");
            terminal.view().pasteText("two");
        });
        assertEquals("onetwo", connection.awaitWritten("onetwo"));
        edtRun(() -> {
            terminal.view().setSize(50 * terminal.view().cellWidth(), 7 * terminal.view().cellHeight());
            terminal.view().applyResize();
        });
        await("resize", () -> connection.resizes.contains("50x7"));
    }

    @Test
    void colourSchemeQueryIsAnsweredThroughTheConnection() throws Exception {
        open();
        connection.push("\u001b[?996n");
        assertEquals("\u001b[?997;1n", connection.awaitWritten("997"));
        edtRun(() -> terminal.applyBackground(Color.WHITE, true));
        connection.push("\u001b[?996n");
        assertTrue(connection.awaitWritten("997;2n").endsWith("\u001b[?997;2n"));
    }

    /** A 10 MB burst must not starve the EDT: frames are coalesced and painting only waits
     * for one chunk's worth of emulation. */
    @Test
    void largeOutputKeepsTheEdtResponsive() throws Exception {
        open();
        edtRun(() -> terminal.view().setSize(120 * terminal.view().cellWidth(), 32 * terminal.view().cellHeight()));
        byte[] chunk = ("\u001b[32mgreen\u001b[0m some ordinary build output with \u001b[1mbold\u001b[0m words 0123456789\r\n")
                .repeat(800).getBytes(StandardCharsets.UTF_8);
        int total = 0;
        while (total < 10 * 1024 * 1024) {
            connection.push(chunk);
            total += chunk.length;
        }
        connection.push("DONE-MARKER");
        BufferedImage image = new BufferedImage(1200, 600, BufferedImage.TYPE_INT_RGB);
        AtomicLong worst = new AtomicLong();
        long start = System.nanoTime();
        boolean done = false;
        while (!done) {
            long posted = System.nanoTime();
            done = edt(() -> {
                Graphics2D g = image.createGraphics();
                g.setClip(0, 0, 1200, 600);
                terminal.view().paint(g);
                g.dispose();
                return terminal.view().emulator().line(terminal.view().emulator().cursorRow()).toString()
                        .startsWith("DONE-MARKER");
            });
            worst.accumulateAndGet(System.nanoTime() - posted, Math::max);
            assertTrue(System.nanoTime() - start < TimeUnit.SECONDS.toNanos(60), "finished");
            Thread.sleep(5);
        }
        long worstMs = TimeUnit.NANOSECONDS.toMillis(worst.get());
        assertTrue(worstMs < 500, "worst EDT round trip " + worstMs + " ms");
        long frames = edt(() -> terminal.view().frames());
        assertTrue(frames < 2000, "frames coalesced: " + frames);
        SwingUtilities.invokeAndWait(() -> { });
    }
}
