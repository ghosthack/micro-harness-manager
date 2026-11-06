package io.github.ghosthack.microhm.app.terminal;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.awt.event.KeyEvent;
import java.nio.charset.StandardCharsets;

import static java.awt.event.KeyEvent.ALT_DOWN_MASK;
import static java.awt.event.KeyEvent.ALT_GRAPH_DOWN_MASK;
import static java.awt.event.KeyEvent.CHAR_UNDEFINED;
import static java.awt.event.KeyEvent.CTRL_DOWN_MASK;
import static java.awt.event.KeyEvent.KEY_LOCATION_NUMPAD;
import static java.awt.event.KeyEvent.KEY_LOCATION_STANDARD;
import static java.awt.event.KeyEvent.META_DOWN_MASK;
import static java.awt.event.KeyEvent.SHIFT_DOWN_MASK;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class KeyEncoderTest {

    private static final KeyEncoder.Modes NORMAL = new KeyEncoder.Modes(false, false, false, true);
    private static final KeyEncoder.Modes APP = new KeyEncoder.Modes(true, true, false, true);
    private static final KeyEncoder.Modes LINUX = new KeyEncoder.Modes(false, false, false, false);

    private static String press(int keyCode, int mods, KeyEncoder.Modes modes) {
        return press(keyCode, CHAR_UNDEFINED, mods, modes);
    }

    private static String press(int keyCode, char keyChar, int mods, KeyEncoder.Modes modes) {
        byte[] b = KeyEncoder.pressed(keyCode, KEY_LOCATION_STANDARD, keyChar, mods, modes);
        return b == null ? null : visible(new String(b, StandardCharsets.UTF_8));
    }

    /** ESC as "^[", other C0 as ^X, so failures read. */
    static String visible(String s) {
        StringBuilder sb = new StringBuilder();
        for (char c : s.toCharArray()) {
            if (c == 0x1b) {
                sb.append("^[");
            } else if (c < 0x20) {
                sb.append('^').append((char) (c + '@'));
            } else if (c == 0x7f) {
                sb.append("^?");
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    @ParameterizedTest(name = "{0} mods={1} → {2} / app {3}")
    @CsvSource(delimiter = '|', value = {
            // key            | mods | normal       | application cursor keys
            "UP               | 0    | ^[[A         | ^[OA",
            "DOWN             | 0    | ^[[B         | ^[OB",
            "RIGHT            | 0    | ^[[C         | ^[OC",
            "LEFT             | 0    | ^[[D         | ^[OD",
            "HOME             | 0    | ^[[H         | ^[OH",
            "END              | 0    | ^[[F         | ^[OF",
            "UP               | 1    | ^[[1;2A      | ^[[1;2A",
            "DOWN             | 4    | ^[[1;5B      | ^[[1;5B",
            "RIGHT            | 5    | ^[[1;6C      | ^[[1;6C",
            "LEFT             | 6    | ^[[1;7D      | ^[[1;7D",
            "HOME             | 1    | ^[[1;2H      | ^[[1;2H",
            "END              | 4    | ^[[1;5F      | ^[[1;5F",
            "UP               | 2    | ^[[1;3A      | ^[[1;3A",
            "INSERT           | 0    | ^[[2~        | ^[[2~",
            "DELETE           | 0    | ^[[3~        | ^[[3~",
            "PAGE_UP          | 0    | ^[[5~        | ^[[5~",
            "PAGE_DOWN        | 0    | ^[[6~        | ^[[6~",
            "DELETE           | 4    | ^[[3;5~      | ^[[3;5~",
            "PAGE_UP          | 1    | ^[[5;2~      | ^[[5;2~",
            "F1               | 0    | ^[OP         | ^[OP",
            "F2               | 0    | ^[OQ         | ^[OQ",
            "F3               | 0    | ^[OR         | ^[OR",
            "F4               | 0    | ^[OS         | ^[OS",
            "F1               | 1    | ^[[1;2P      | ^[[1;2P",
            "F4               | 4    | ^[[1;5S      | ^[[1;5S",
            "F5               | 0    | ^[[15~       | ^[[15~",
            "F6               | 0    | ^[[17~       | ^[[17~",
            "F7               | 0    | ^[[18~       | ^[[18~",
            "F8               | 0    | ^[[19~       | ^[[19~",
            "F9               | 0    | ^[[20~       | ^[[20~",
            "F10              | 0    | ^[[21~       | ^[[21~",
            "F11              | 0    | ^[[23~       | ^[[23~",
            "F12              | 0    | ^[[24~       | ^[[24~",
            "F5               | 1    | ^[[15;2~     | ^[[15;2~",
            "F12              | 4    | ^[[24;5~     | ^[[24;5~",
            "ENTER            | 0    | ^M           | ^M",
            "ENTER            | 1    | ^M           | ^M",
            "ENTER            | 2    | ^[^M         | ^[^M",
            "BACK_SPACE       | 0    | ^?           | ^?",
            "BACK_SPACE       | 4    | ^H           | ^H",
            "BACK_SPACE       | 2    | ^[^?         | ^[^?",
            "TAB              | 0    | ^I           | ^I",
            "TAB              | 1    | ^[[Z         | ^[[Z",
            "ESCAPE           | 0    | ^[           | ^[",
            "ESCAPE           | 2    | ^[^[         | ^[^[",
    })
    void specialKeys(String key, int mods, String normal, String application) {
        int code = keyCode(key);
        int ex = ex(mods);
        assertEquals(normal, press(code, ex, NORMAL));
        assertEquals(application, press(code, ex, APP));
    }

    /** 1 shift, 2 alt, 4 ctrl → modifiersEx. */
    private static int ex(int mods) {
        return ((mods & 1) != 0 ? SHIFT_DOWN_MASK : 0) | ((mods & 2) != 0 ? ALT_DOWN_MASK : 0)
                | ((mods & 4) != 0 ? CTRL_DOWN_MASK : 0);
    }

    private static int keyCode(String name) {
        try {
            return KeyEvent.class.getField("VK_" + name).getInt(null);
        } catch (ReflectiveOperationException e) {
            throw new IllegalArgumentException(name, e);
        }
    }

    @Test
    void enterSendsCrLfInNewLineMode() {
        assertEquals("^M^J", press(KeyEvent.VK_ENTER, 0, new KeyEncoder.Modes(false, false, true, true)));
    }

    @Test
    void ctrlLettersAndPunctuationAreC0() {
        for (int k = KeyEvent.VK_A; k <= KeyEvent.VK_Z; k++) {
            String expected = "^" + (char) ('A' + k - KeyEvent.VK_A);
            if (k == KeyEvent.VK_I) {
                expected = "^I";
            }
            assertEquals(expected, press(k, CTRL_DOWN_MASK, NORMAL));
            assertEquals(expected, press(k, CTRL_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
        }
        assertEquals("^@", press(KeyEvent.VK_SPACE, CTRL_DOWN_MASK, NORMAL));
        assertEquals("^@", press(KeyEvent.VK_2, CTRL_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
        assertEquals("^[", press(KeyEvent.VK_OPEN_BRACKET, CTRL_DOWN_MASK, NORMAL));
        assertEquals("^\\", press(KeyEvent.VK_BACK_SLASH, CTRL_DOWN_MASK, NORMAL));
        assertEquals("^]", press(KeyEvent.VK_CLOSE_BRACKET, CTRL_DOWN_MASK, NORMAL));
        assertEquals("^^", press(KeyEvent.VK_6, CTRL_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
        assertEquals("^_", press(KeyEvent.VK_MINUS, CTRL_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
        assertEquals("^_", press(KeyEvent.VK_SLASH, CTRL_DOWN_MASK, NORMAL));
        assertNull(press(KeyEvent.VK_PERIOD, CTRL_DOWN_MASK, NORMAL));
    }

    @Test
    void ctrlAltLetterIsEscPrefixedC0() {
        assertEquals("^[^X", press(KeyEvent.VK_X, CTRL_DOWN_MASK | ALT_DOWN_MASK, NORMAL));
    }

    @Test
    void macOptionLettersAndDigitsAreMeta() {
        assertEquals("^[b", press(KeyEvent.VK_B, '∫', ALT_DOWN_MASK, NORMAL));
        assertEquals("^[f", press(KeyEvent.VK_F, 'ƒ', ALT_DOWN_MASK, NORMAL));
        assertEquals("^[e", press(KeyEvent.VK_E, CHAR_UNDEFINED, ALT_DOWN_MASK, NORMAL)); // dead acute
        assertEquals("^[B", press(KeyEvent.VK_B, 'ı', ALT_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
        assertEquals("^[a", press(KeyEvent.VK_A, 'a', ALT_DOWN_MASK, NORMAL));
        assertEquals("^[1", press(KeyEvent.VK_1, '¡', ALT_DOWN_MASK, NORMAL));
    }

    @Test
    void macOptionKeepsLayoutAsciiAndPunctuationComposing() {
        assertNull(press(KeyEvent.VK_L, '@', ALT_DOWN_MASK, NORMAL)); // German Option+L
        assertNull(press(KeyEvent.VK_5, '[', ALT_DOWN_MASK, NORMAL));
        assertNull(press(KeyEvent.VK_OPEN_BRACKET, '“', ALT_DOWN_MASK, NORMAL));
        assertNull(press(KeyEvent.VK_1, '⁄', ALT_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
    }

    @Test
    void macOptionArrowsAreWordMotion() {
        assertEquals("^[b", press(KeyEvent.VK_LEFT, ALT_DOWN_MASK, NORMAL));
        assertEquals("^[f", press(KeyEvent.VK_RIGHT, ALT_DOWN_MASK, NORMAL));
        assertEquals("^[[1;3D", press(KeyEvent.VK_LEFT, ALT_DOWN_MASK, LINUX));
    }

    @Test
    void optionComposesWhenOptionAsMetaIsOff() {
        KeyEncoder.Modes composing = new KeyEncoder.Modes(false, false, false, true, false);
        // letters, digits and dead keys go to the input method / KEY_TYPED instead
        assertNull(press(KeyEvent.VK_E, CHAR_UNDEFINED, ALT_DOWN_MASK, composing)); // dead acute
        assertNull(press(KeyEvent.VK_A, 'å', ALT_DOWN_MASK, composing));
        assertNull(press(KeyEvent.VK_G, '©', ALT_DOWN_MASK, composing));
        assertNull(press(KeyEvent.VK_1, '¡', ALT_DOWN_MASK, composing));
        // named keys keep their encodings
        assertEquals("^[b", press(KeyEvent.VK_LEFT, ALT_DOWN_MASK, composing));
        assertEquals("^[^M", press(KeyEvent.VK_ENTER, ALT_DOWN_MASK, composing));
        assertEquals("^[^?", press(KeyEvent.VK_BACK_SPACE, ALT_DOWN_MASK, composing));
        // the setting is macOS-only: Linux Alt stays Meta
        KeyEncoder.Modes linuxOff = new KeyEncoder.Modes(false, false, false, false, false);
        assertEquals("^[x", press(KeyEvent.VK_X, 'x', ALT_DOWN_MASK, linuxOff));
    }

    @Test
    void altElsewhereIsMetaForAnyPrintable() {
        assertEquals("^[.", press(KeyEvent.VK_PERIOD, '.', ALT_DOWN_MASK, LINUX));
        assertEquals("^[x", press(KeyEvent.VK_X, 'x', ALT_DOWN_MASK, LINUX));
        assertEquals("^[X", press(KeyEvent.VK_X, CHAR_UNDEFINED, ALT_DOWN_MASK | SHIFT_DOWN_MASK, LINUX));
    }

    @Test
    void altGraphIsNotMeta() {
        assertNull(press(KeyEvent.VK_Q, '@', ALT_GRAPH_DOWN_MASK | CTRL_DOWN_MASK | ALT_DOWN_MASK, LINUX));
    }

    @Test
    void cmdChordsAreNeverSent() {
        for (int k : new int[]{KeyEvent.VK_C, KeyEvent.VK_V, KeyEvent.VK_T, KeyEvent.VK_W, KeyEvent.VK_1,
                KeyEvent.VK_UP, KeyEvent.VK_ENTER, KeyEvent.VK_BACK_SPACE}) {
            assertNull(press(k, META_DOWN_MASK, NORMAL));
            assertNull(press(k, META_DOWN_MASK | SHIFT_DOWN_MASK, NORMAL));
        }
        assertNull(KeyEncoder.typed('c', META_DOWN_MASK));
    }

    @Test
    void plainCharactersAreLeftToTyped() {
        assertNull(press(KeyEvent.VK_A, 'a', 0, NORMAL));
        assertNull(press(KeyEvent.VK_A, 'A', SHIFT_DOWN_MASK, NORMAL));
        assertNull(press(KeyEvent.VK_SPACE, ' ', 0, NORMAL));
        assertNull(press(KeyEvent.VK_SHIFT, 0, NORMAL));
        assertEquals("a", new String(KeyEncoder.typed('a', 0), StandardCharsets.UTF_8));
        assertEquals("é", new String(KeyEncoder.typed('é', ALT_DOWN_MASK), StandardCharsets.UTF_8));
        assertEquals(2, KeyEncoder.typed('é', 0).length);
    }

    @Test
    void typedControlsOnlyWithCtrl() {
        assertNull(KeyEncoder.typed('\n', 0));
        assertNull(KeyEncoder.typed('\b', 0));
        assertNull(KeyEncoder.typed((char) 0x7f, 0));
        assertNull(KeyEncoder.typed(CHAR_UNDEFINED, 0));
        assertEquals(3, KeyEncoder.typed((char) 3, CTRL_DOWN_MASK)[0]);
    }

    @Test
    void keypadInApplicationMode() {
        byte[] five = KeyEncoder.pressed(KeyEvent.VK_NUMPAD5, KEY_LOCATION_NUMPAD, '5', 0, APP);
        assertEquals("^[Ou", visible(new String(five, StandardCharsets.UTF_8)));
        byte[] enter = KeyEncoder.pressed(KeyEvent.VK_ENTER, KEY_LOCATION_NUMPAD, '\n', 0, APP);
        assertEquals("^[OM", visible(new String(enter, StandardCharsets.UTF_8)));
        assertNull(KeyEncoder.pressed(KeyEvent.VK_NUMPAD5, KEY_LOCATION_NUMPAD, '5', 0, NORMAL));
    }
}
