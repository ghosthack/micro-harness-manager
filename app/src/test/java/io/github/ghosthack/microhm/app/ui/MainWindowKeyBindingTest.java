package io.github.ghosthack.microhm.app.ui;

import org.junit.jupiter.api.Test;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class MainWindowKeyBindingTest {

    @Test
    void terminalZoomAcceptsPlatformEqualsPlusAndMinusChords() {
        int command = InputEvent.META_DOWN_MASK;
        int control = InputEvent.CTRL_DOWN_MASK;

        assertEquals(1, MainWindow.terminalFontDelta(KeyEvent.VK_EQUALS, command, command));
        assertEquals(1, MainWindow.terminalFontDelta(KeyEvent.VK_EQUALS,
                command | InputEvent.SHIFT_DOWN_MASK, command));
        assertEquals(1, MainWindow.terminalFontDelta(KeyEvent.VK_PLUS, command, command));
        assertEquals(1, MainWindow.terminalFontDelta(KeyEvent.VK_ADD, control, control));
        assertEquals(-1, MainWindow.terminalFontDelta(KeyEvent.VK_MINUS, command, command));
        assertEquals(-1, MainWindow.terminalFontDelta(KeyEvent.VK_SUBTRACT, control, control));
    }

    /** Off macOS the session shortcuts need Shift as well: plain Ctrl+D, Ctrl+W and
     * Ctrl+T are the shell's (end of file, delete word, transpose). */
    @Test
    void sessionShortcutsLeavePlainControlKeysToTheTerminal() {
        int command = InputEvent.META_DOWN_MASK;
        int control = InputEvent.CTRL_DOWN_MASK;
        int shift = InputEvent.SHIFT_DOWN_MASK;
        assertEquals(false, MainWindow.isSessionChord(control, control));
        assertEquals(true, MainWindow.isSessionChord(control | shift, control));
        assertEquals(true, MainWindow.isSessionChord(command, command));
        assertEquals(false, MainWindow.isSessionChord(control, command));
        assertEquals(false, MainWindow.isSessionChord(0, control));
    }

    @Test
    void terminalZoomRequiresThePlatformShortcutModifier() {
        int command = InputEvent.META_DOWN_MASK;
        assertEquals(0, MainWindow.terminalFontDelta(KeyEvent.VK_EQUALS, 0, command));
        assertEquals(0, MainWindow.terminalFontDelta(KeyEvent.VK_MINUS,
                InputEvent.CTRL_DOWN_MASK, command));
        assertEquals(0, MainWindow.terminalFontDelta(KeyEvent.VK_0, command, command));
    }
}
