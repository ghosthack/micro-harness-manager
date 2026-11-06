package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.TerminalEmulator.MouseEncoding;
import io.github.ghosthack.microhm.vt.TerminalEmulator.MouseTracking;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static io.github.ghosthack.microhm.app.terminal.MouseEncoder.Action.DRAG;
import static io.github.ghosthack.microhm.app.terminal.MouseEncoder.Action.MOVE;
import static io.github.ghosthack.microhm.app.terminal.MouseEncoder.Action.PRESS;
import static io.github.ghosthack.microhm.app.terminal.MouseEncoder.Action.RELEASE;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

class MouseEncoderTest {

    private static String sgr(MouseTracking t, MouseEncoder.Action a, int button, int col, int row, int mods) {
        byte[] b = MouseEncoder.encode(t, MouseEncoding.SGR, a, button, col, row, mods);
        return b == null ? null : new String(b, StandardCharsets.US_ASCII).replace("\u001b", "^[");
    }

    @Test
    void whichEventsEachModeReports() {
        MouseEncoder.Action[] actions = {PRESS, RELEASE, DRAG, MOVE};
        boolean[][] expected = {
                {false, false, false, false}, // NONE
                {true, false, false, false},  // X10
                {true, true, false, false},   // NORMAL
                {true, true, true, false},    // BUTTON_MOTION
                {true, true, true, true},     // ANY_MOTION
        };
        MouseTracking[] modes = MouseTracking.values();
        for (int m = 0; m < modes.length; m++) {
            for (int a = 0; a < actions.length; a++) {
                for (MouseEncoding enc : MouseEncoding.values()) {
                    int button = actions[a] == MOVE ? MouseEncoder.NONE : MouseEncoder.LEFT;
                    byte[] r = MouseEncoder.encode(modes[m], enc, actions[a], button, 0, 0, 0);
                    assertEquals(expected[m][a], r != null, modes[m] + " " + actions[a] + " " + enc);
                }
            }
        }
    }

    @Test
    void sgrPressReleaseDragMoveWheel() {
        assertEquals("^[[<0;1;1M", sgr(MouseTracking.NORMAL, PRESS, MouseEncoder.LEFT, 0, 0, 0));
        assertEquals("^[[<2;10;5m", sgr(MouseTracking.NORMAL, RELEASE, MouseEncoder.RIGHT, 9, 4, 0));
        assertEquals("^[[<32;3;4M", sgr(MouseTracking.BUTTON_MOTION, DRAG, MouseEncoder.LEFT, 2, 3, 0));
        assertEquals("^[[<35;3;4M", sgr(MouseTracking.ANY_MOTION, MOVE, MouseEncoder.NONE, 2, 3, 0));
        assertEquals("^[[<64;1;1M", sgr(MouseTracking.NORMAL, PRESS, MouseEncoder.WHEEL_UP, 0, 0, 0));
        assertEquals("^[[<65;1;1M", sgr(MouseTracking.NORMAL, PRESS, MouseEncoder.WHEEL_DOWN, 0, 0, 0));
        assertNull(sgr(MouseTracking.NORMAL, RELEASE, MouseEncoder.WHEEL_UP, 0, 0, 0));
        assertEquals("^[[<1;500;300M", sgr(MouseTracking.NORMAL, PRESS, MouseEncoder.MIDDLE, 499, 299, 0));
    }

    @Test
    void modifierBits() {
        assertEquals("^[[<4;1;1M", sgr(MouseTracking.NORMAL, PRESS, 0, 0, 0, MouseEncoder.SHIFT));
        assertEquals("^[[<8;1;1M", sgr(MouseTracking.NORMAL, PRESS, 0, 0, 0, MouseEncoder.META));
        assertEquals("^[[<16;1;1M", sgr(MouseTracking.NORMAL, PRESS, 0, 0, 0, MouseEncoder.CTRL));
        assertEquals("^[[<88;1;1M", sgr(MouseTracking.NORMAL, PRESS, MouseEncoder.WHEEL_UP, 0, 0,
                MouseEncoder.CTRL | MouseEncoder.META));
        // X10 reports no modifiers
        assertEquals("^[[<0;1;1M", sgr(MouseTracking.X10, PRESS, 0, 0, 0, MouseEncoder.CTRL));
        assertEquals(MouseEncoder.SHIFT | MouseEncoder.CTRL,
                MouseEncoder.modifiers(java.awt.event.InputEvent.SHIFT_DOWN_MASK | java.awt.event.InputEvent.CTRL_DOWN_MASK));
    }

    @Test
    void defaultEncodingIsOffsetBytesClampedAt223() {
        assertArrayEquals(new byte[]{0x1b, '[', 'M', 32, 33, 33},
                MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.DEFAULT, PRESS, 0, 0, 0, 0));
        assertArrayEquals(new byte[]{0x1b, '[', 'M', 35, 42, 37},
                MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.DEFAULT, RELEASE, 2, 9, 4, 0));
        byte[] far = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.DEFAULT, PRESS, 0, 400, 300, 0);
        assertEquals(255, far[4] & 0xFF);
        assertEquals(255, far[5] & 0xFF);
        byte[] wheel = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.DEFAULT, PRESS, MouseEncoder.WHEEL_DOWN, 0, 0,
                MouseEncoder.SHIFT);
        assertEquals(32 + 65 + 4, wheel[3] & 0xFF);
    }

    @Test
    void utf8EncodingWidensCoordinates() {
        byte[] small = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.UTF8, PRESS, 0, 0, 0, 0);
        assertArrayEquals(new byte[]{0x1b, '[', 'M', 32, 33, 33}, small);
        byte[] wide = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.UTF8, PRESS, 0, 299, 0, 0);
        String decoded = new String(wide, 3, wide.length - 3, StandardCharsets.UTF_8);
        assertEquals(300 + 32, decoded.charAt(1));
        byte[] clamped = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.UTF8, PRESS, 0, 5000, 0, 0);
        assertEquals(2015 + 32, new String(clamped, 3, clamped.length - 3, StandardCharsets.UTF_8).charAt(1));
    }

    @Test
    void urxvtEncodingIsDecimal() {
        byte[] b = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.URXVT, PRESS, 0, 299, 9, MouseEncoder.CTRL);
        assertEquals("\u001b[48;300;10M", new String(b, StandardCharsets.US_ASCII));
        byte[] release = MouseEncoder.encode(MouseTracking.NORMAL, MouseEncoding.URXVT, RELEASE, 0, 0, 0, 0);
        assertEquals("\u001b[35;1;1M", new String(release, StandardCharsets.US_ASCII));
        assertNotNull(MouseEncoder.encode(MouseTracking.X10, MouseEncoding.URXVT, PRESS, MouseEncoder.WHEEL_UP, 0, 0, 0));
    }
}
