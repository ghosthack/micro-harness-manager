package io.github.ghosthack.microhm.app.ui;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class MacPermissionsDialogTest {

    @Test
    void screenRecordingKeepsTheSonomaNameThroughMacOS14() {
        MacPermissionsDialog.Pane screen = MacPermissionsDialog.Pane.SCREEN_RECORDING;
        assertEquals("Privacy & Security › Screen Recording", screen.settingsPath(14));
        assertEquals("Privacy & Security › Screen & System Audio Recording", screen.settingsPath(15));
    }
}
