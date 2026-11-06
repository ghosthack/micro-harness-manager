package io.github.ghosthack.microhm.app.terminal;

import java.awt.event.KeyEvent;
import java.nio.charset.StandardCharsets;

/**
 * Key presses → the bytes xterm sends for them. Pure (no AWT state beyond the constants),
 * so the whole table is unit-tested. {@link #pressed} handles every key that does not
 * produce a plain character — and the Ctrl/Alt chords that would otherwise type one — and
 * returns null for the rest, which then arrive as typed characters ({@link #typed}).
 *
 * <ul>
 *   <li>Enter → CR (CR LF in newline mode, LNM); Backspace → DEL, Ctrl+Backspace → BS;
 *       Tab, Shift+Tab → {@code CSI Z}; Esc.</li>
 *   <li>Arrows, Home, End: {@code CSI X}, or SS3 in application cursor mode (DECCKM);
 *       with modifiers always {@code CSI 1 ; m X} (m = 1 + Shift 1 + Alt 2 + Ctrl 4).</li>
 *   <li>Insert/Delete/PageUp/PageDown: {@code CSI n ~} / {@code CSI n ; m ~}.</li>
 *   <li>F1–F4: SS3 P–S ({@code CSI 1 ; m P–S} with modifiers); F5–F12: {@code CSI 15~}
 *       … {@code CSI 24~}.</li>
 *   <li>Ctrl+letter → C0; Ctrl+Space/@/2 → NUL; Ctrl+[ \ ] ^ _ (and Ctrl+6, Ctrl+-,
 *       Ctrl+/) → ESC, FS, GS, RS, US.</li>
 *   <li>Alt as Meta: an ESC prefix on the key's own encoding. On macOS Option normally
 *       composes characters (Option+e is a dead acute, Option+a "å"); here Option+letter
 *       and Option+digit are Meta instead — the chords agents and shells bind (word
 *       motion, Option+Enter for a newline) — <em>unless</em> the keyboard layout composes
 *       a plain ASCII character on that chord (Option+L is "@" on German layouts), which
 *       is typed as usual. Option with punctuation still composes. Option+Left/Right send
 *       {@code ESC b} / {@code ESC f} (word motion), as Terminal.app and iTerm2 do. The
 *       trade-off: an Option+dead-key chord (Option+e, u, i, n, `) is Meta, so it cannot
 *       also start an accent. With Option-as-Meta off ({@link Modes#optionAsMeta}) every
 *       Option+character chord composes natively instead; Option with Enter, Backspace,
 *       Tab, Escape and the arrows keeps its encoding either way.</li>
 *   <li>Keypad digits and operators send SS3 codes in application keypad mode (DECKPAM).</li>
 * </ul>
 *
 * The Cmd (meta) key never reaches the program: chords with it return null so the window's
 * shortcuts see them. Shift+Enter is plain CR (Option+Enter, {@code ESC CR}, is the chord
 * agents such as Claude Code take as "insert newline").
 */
final class KeyEncoder {

    /** Terminal modes the encoding depends on. {@code optionAsMeta} (macOS only) chooses
     * whether Option+letter/digit is Meta or composes; see the class documentation. */
    record Modes(boolean applicationCursorKeys, boolean applicationKeypad, boolean newLineMode,
                 boolean mac, boolean optionAsMeta) {

        Modes(boolean applicationCursorKeys, boolean applicationKeypad, boolean newLineMode,
              boolean mac) {
            this(applicationCursorKeys, applicationKeypad, newLineMode, mac, true);
        }
    }

    private static final String ESC = "\u001b";
    private static final String CSI = ESC + "[";
    private static final String SS3 = ESC + "O";

    /**
     * The bytes for a key press, or null when the press sends nothing by itself (a plain
     * character — see {@link #typed} — a lone modifier, or a Cmd chord).
     *
     * @param keyCode   {@link KeyEvent#getKeyCode()}
     * @param location  {@link KeyEvent#getKeyLocation()}
     * @param keyChar   {@link KeyEvent#getKeyChar()} of the press (what the layout composes)
     * @param modifiers {@link KeyEvent#getModifiersEx()}
     */
    static byte[] pressed(int keyCode, int location, char keyChar, int modifiers, Modes modes) {
        String s = pressedString(keyCode, location, keyChar, modifiers, modes);
        return s == null ? null : s.getBytes(StandardCharsets.UTF_8);
    }

    /** The bytes for a typed character the press did not already send, or null. */
    static byte[] typed(char c, int modifiers) {
        if (c == KeyEvent.CHAR_UNDEFINED || (modifiers & KeyEvent.META_DOWN_MASK) != 0) {
            return null;
        }
        if (c < 0x20 || c == 0x7F) {
            // Control characters the press handler did not map (e.g. Ctrl+letter on a
            // layout whose key codes are not Latin) still reach the program as typed.
            return (modifiers & KeyEvent.CTRL_DOWN_MASK) != 0 ? new byte[]{(byte) c} : null;
        }
        return String.valueOf(c).getBytes(StandardCharsets.UTF_8);
    }

    private static String pressedString(int keyCode, int location, char keyChar, int modifiers,
                                        Modes modes) {
        if ((modifiers & KeyEvent.META_DOWN_MASK) != 0) {
            return null;
        }
        boolean shift = (modifiers & KeyEvent.SHIFT_DOWN_MASK) != 0;
        boolean altGraph = (modifiers & KeyEvent.ALT_GRAPH_DOWN_MASK) != 0;
        boolean alt = (modifiers & KeyEvent.ALT_DOWN_MASK) != 0 && !altGraph;
        boolean ctrl = (modifiers & KeyEvent.CTRL_DOWN_MASK) != 0 && !altGraph;
        int mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
        String meta = alt ? ESC : "";

        if (location == KeyEvent.KEY_LOCATION_NUMPAD && modes.applicationKeypad() && mod == 1) {
            String keypad = keypad(keyCode);
            if (keypad != null) {
                return SS3 + keypad;
            }
        }
        switch (keyCode) {
            case KeyEvent.VK_ENTER:
                return meta + (modes.newLineMode() ? "\r\n" : "\r");
            case KeyEvent.VK_BACK_SPACE:
                return meta + (ctrl ? "\b" : "\u007f");
            case KeyEvent.VK_TAB:
                return shift ? CSI + "Z" : meta + "\t";
            case KeyEvent.VK_ESCAPE:
                return meta + ESC;
            case KeyEvent.VK_UP, KeyEvent.VK_KP_UP:
                return cursor('A', mod, modes);
            case KeyEvent.VK_DOWN, KeyEvent.VK_KP_DOWN:
                return cursor('B', mod, modes);
            case KeyEvent.VK_RIGHT, KeyEvent.VK_KP_RIGHT:
                if (modes.mac() && mod == 3) {
                    return ESC + "f";
                }
                return cursor('C', mod, modes);
            case KeyEvent.VK_LEFT, KeyEvent.VK_KP_LEFT:
                if (modes.mac() && mod == 3) {
                    return ESC + "b";
                }
                return cursor('D', mod, modes);
            case KeyEvent.VK_HOME:
                return cursor('H', mod, modes);
            case KeyEvent.VK_END:
                return cursor('F', mod, modes);
            case KeyEvent.VK_INSERT:
                return tilde(2, mod);
            case KeyEvent.VK_DELETE:
                return tilde(3, mod);
            case KeyEvent.VK_PAGE_UP:
                return tilde(5, mod);
            case KeyEvent.VK_PAGE_DOWN:
                return tilde(6, mod);
            case KeyEvent.VK_F1, KeyEvent.VK_F2, KeyEvent.VK_F3, KeyEvent.VK_F4: {
                char fin = (char) ('P' + keyCode - KeyEvent.VK_F1);
                return mod == 1 ? SS3 + fin : CSI + "1;" + mod + fin;
            }
            case KeyEvent.VK_F5:
                return tilde(15, mod);
            case KeyEvent.VK_F6:
                return tilde(17, mod);
            case KeyEvent.VK_F7:
                return tilde(18, mod);
            case KeyEvent.VK_F8:
                return tilde(19, mod);
            case KeyEvent.VK_F9:
                return tilde(20, mod);
            case KeyEvent.VK_F10:
                return tilde(21, mod);
            case KeyEvent.VK_F11:
                return tilde(23, mod);
            case KeyEvent.VK_F12:
                return tilde(24, mod);
            default:
                break;
        }
        if (ctrl) {
            String control = control(keyCode);
            return control == null ? null : meta + control;
        }
        if (alt) {
            return altChord(keyCode, keyChar, shift, modes.mac(), modes.optionAsMeta());
        }
        return null;
    }

    private static String cursor(char fin, int mod, Modes modes) {
        if (mod > 1) {
            return CSI + "1;" + mod + fin;
        }
        return (modes.applicationCursorKeys() ? SS3 : CSI) + fin;
    }

    private static String tilde(int code, int mod) {
        return mod > 1 ? CSI + code + ";" + mod + "~" : CSI + code + "~";
    }

    /** Ctrl+key → its C0 control, or null for a key with none. */
    private static String control(int keyCode) {
        if (keyCode >= KeyEvent.VK_A && keyCode <= KeyEvent.VK_Z) {
            return String.valueOf((char) (keyCode - KeyEvent.VK_A + 1));
        }
        return switch (keyCode) {
            case KeyEvent.VK_SPACE, KeyEvent.VK_2, KeyEvent.VK_AT -> "\0";
            case KeyEvent.VK_OPEN_BRACKET -> ESC;
            case KeyEvent.VK_BACK_SLASH -> "\u001c";
            case KeyEvent.VK_CLOSE_BRACKET -> "\u001d";
            case KeyEvent.VK_6, KeyEvent.VK_CIRCUMFLEX -> "\u001e";
            case KeyEvent.VK_MINUS, KeyEvent.VK_UNDERSCORE, KeyEvent.VK_SLASH -> "\u001f";
            default -> null;
        };
    }

    /**
     * Alt (Option) without Ctrl: ESC + the key's character. On macOS only letters and digits
     * are Meta, and only when the layout does not compose a plain ASCII character on the
     * chord (see the class documentation); elsewhere any printable character is.
     */
    private static String altChord(int keyCode, char keyChar, boolean shift, boolean mac,
                                   boolean optionAsMeta) {
        boolean letter = keyCode >= KeyEvent.VK_A && keyCode <= KeyEvent.VK_Z;
        boolean digit = keyCode >= KeyEvent.VK_0 && keyCode <= KeyEvent.VK_9;
        if (mac) {
            if (!optionAsMeta) {
                return null; // Option composes everything (é, å, ©), as macOS does natively
            }
            if (!letter && !digit) {
                return null; // Option+punctuation composes (typed)
            }
            char base = letter
                    ? (char) ((shift ? 'A' : 'a') + keyCode - KeyEvent.VK_A)
                    : (char) ('0' + keyCode - KeyEvent.VK_0);
            boolean composesAscii = keyChar >= 0x20 && keyChar < 0x7F
                    && Character.toLowerCase(keyChar) != Character.toLowerCase(base);
            if (composesAscii || (digit && shift)) {
                return null; // a layout character (German Option+L = '@'), typed as usual
            }
            return ESC + base;
        }
        if (keyChar >= 0x20 && keyChar != 0x7F && keyChar != KeyEvent.CHAR_UNDEFINED) {
            return ESC + keyChar;
        }
        if (letter) {
            return ESC + (char) ((shift ? 'A' : 'a') + keyCode - KeyEvent.VK_A);
        }
        return null;
    }

    /** DECKPAM keypad: the SS3 final for a keypad key, or null. */
    private static String keypad(int keyCode) {
        if (keyCode >= KeyEvent.VK_NUMPAD0 && keyCode <= KeyEvent.VK_NUMPAD9) {
            return String.valueOf((char) ('p' + keyCode - KeyEvent.VK_NUMPAD0));
        }
        return switch (keyCode) {
            case KeyEvent.VK_ENTER -> "M";
            case KeyEvent.VK_MULTIPLY -> "j";
            case KeyEvent.VK_ADD -> "k";
            case KeyEvent.VK_SEPARATOR -> "l";
            case KeyEvent.VK_SUBTRACT -> "m";
            case KeyEvent.VK_DECIMAL -> "n";
            case KeyEvent.VK_DIVIDE -> "o";
            default -> null;
        };
    }

    private KeyEncoder() {
    }
}
