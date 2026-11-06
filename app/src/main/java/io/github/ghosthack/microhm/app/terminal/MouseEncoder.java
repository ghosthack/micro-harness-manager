package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.TerminalEmulator.MouseEncoding;
import io.github.ghosthack.microhm.vt.TerminalEmulator.MouseTracking;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Mouse events → xterm mouse reports, per the program's tracking mode and encoding. Pure.
 *
 * <p>Buttons: 0 left, 1 middle, 2 right, {@link #WHEEL_UP} 64 / {@link #WHEEL_DOWN} 65. Which
 * events are reported: X10 (9) presses only, without modifiers; NORMAL (1000) presses and
 * releases; BUTTON_MOTION (1002) also motion with a button held; ANY_MOTION (1003) all motion.
 * Wheel notches are presses with no release. Motion adds 32 to the button code (button 3
 * when none is held); modifiers add Shift 4, Alt/Meta 8, Ctrl 16.
 *
 * <p>Encodings: DEFAULT {@code CSI M Cb Cx Cy} as single bytes offset by 32, coordinates
 * clamped to 223; UTF8 (1005) the same values as UTF-8 characters, clamped to 2015; SGR
 * (1006) {@code CSI < b ; x ; y M}, or {@code m} for a release, which keeps the button;
 * URXVT (1015) {@code CSI b+32 ; x ; y M}. Releases in every encoding but SGR are button 3.
 */
final class MouseEncoder {

    static final int LEFT = 0;
    static final int MIDDLE = 1;
    static final int RIGHT = 2;
    static final int WHEEL_UP = 64;
    static final int WHEEL_DOWN = 65;
    /** Motion with no button held. */
    static final int NONE = 3;

    enum Action { PRESS, RELEASE, DRAG, MOVE }

    /** Modifier bits. */
    static final int SHIFT = 4;
    static final int META = 8;
    static final int CTRL = 16;

    /**
     * The report for one event, or null when the mode does not report it.
     *
     * @param column 0-based cell column
     * @param row    0-based cell row
     * @param mods   {@link #SHIFT} | {@link #META} | {@link #CTRL}
     */
    static byte[] encode(MouseTracking tracking, MouseEncoding encoding, Action action, int button,
                         int column, int row, int mods) {
        boolean wheel = button >= WHEEL_UP;
        boolean reported = switch (tracking) {
            case NONE -> false;
            case X10 -> action == Action.PRESS;
            case NORMAL -> action == Action.PRESS || (action == Action.RELEASE && !wheel);
            case BUTTON_MOTION -> action != Action.MOVE && !(action == Action.RELEASE && wheel);
            case ANY_MOTION -> !(action == Action.RELEASE && wheel);
        };
        if (!reported) {
            return null;
        }
        int code = switch (action) {
            case PRESS -> button;
            case RELEASE -> encoding == MouseEncoding.SGR ? button : 3;
            case DRAG -> button + 32;
            case MOVE -> NONE + 32;
        };
        if (tracking != MouseTracking.X10) {
            code |= mods & (SHIFT | META | CTRL);
        }
        int x = Math.max(0, column) + 1;
        int y = Math.max(0, row) + 1;
        return switch (encoding) {
            case SGR -> ("\u001b[<" + code + ";" + x + ";" + y + (action == Action.RELEASE ? "m" : "M"))
                    .getBytes(StandardCharsets.US_ASCII);
            case URXVT -> ("\u001b[" + (code + 32) + ";" + x + ";" + y + "M")
                    .getBytes(StandardCharsets.US_ASCII);
            case DEFAULT -> new byte[]{0x1b, '[', 'M', (byte) (code + 32),
                    (byte) (Math.min(x, 223) + 32), (byte) (Math.min(y, 223) + 32)};
            case UTF8 -> {
                ByteArrayOutputStream out = new ByteArrayOutputStream(9);
                out.writeBytes(new byte[]{0x1b, '[', 'M'});
                utf8(out, code + 32);
                utf8(out, Math.min(x, 2015) + 32);
                utf8(out, Math.min(y, 2015) + 32);
                yield out.toByteArray();
            }
        };
    }

    /** Modifier bits from {@link java.awt.event.InputEvent#getModifiersEx()}. */
    static int modifiers(int modifiersEx) {
        int mods = 0;
        if ((modifiersEx & java.awt.event.InputEvent.SHIFT_DOWN_MASK) != 0) {
            mods |= SHIFT;
        }
        if ((modifiersEx & java.awt.event.InputEvent.ALT_DOWN_MASK) != 0) {
            mods |= META;
        }
        if ((modifiersEx & java.awt.event.InputEvent.CTRL_DOWN_MASK) != 0) {
            mods |= CTRL;
        }
        return mods;
    }

    private static void utf8(ByteArrayOutputStream out, int value) {
        if (value < 0x80) {
            out.write(value);
        } else {
            out.write(0xC0 | (value >> 6));
            out.write(0x80 | (value & 0x3F));
        }
    }

    private MouseEncoder() {
    }
}
