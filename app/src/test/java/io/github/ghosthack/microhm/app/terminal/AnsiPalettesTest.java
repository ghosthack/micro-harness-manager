package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.app.settings.AppSettings;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AnsiPalettesTest {

    @Test
    void everySettingHasSixteenSlots() {
        for (AppSettings.TerminalPalette p : AppSettings.TerminalPalette.values()) {
            assertEquals(16, AnsiPalettes.forSetting(p).length, p.name());
        }
        assertEquals(0xCD0000, AnsiPalettes.forSetting(AppSettings.TerminalPalette.XTERM)[1]);
        assertEquals(0xC23621, AnsiPalettes.forSetting(AppSettings.TerminalPalette.MACOS_TERMINAL)[1]);
        assertEquals(0xFFFFFF, AnsiPalettes.forSetting(AppSettings.TerminalPalette.ITERM2)[15]);
    }

    @Test
    void returnsACopy() {
        AnsiPalettes.forSetting(AppSettings.TerminalPalette.XTERM)[0] = 1;
        assertEquals(0, AnsiPalettes.forSetting(AppSettings.TerminalPalette.XTERM)[0]);
    }

    @Test
    void defaultsFollowThePaletteAndTheme() {
        int[] palette = AnsiPalettes.forSetting(AppSettings.TerminalPalette.MACOS_TERMINAL);
        TerminalColors dark = new TerminalColors(palette, false);
        assertEquals(0x000000, dark.defaultBackground());
        assertEquals(0xE9EBEB, dark.defaultForeground());
        TerminalColors light = new TerminalColors(palette, true);
        assertEquals(0xE9EBEB, light.defaultBackground());
        assertEquals(0x000000, light.defaultForeground());
        light.setTheme(0x123456, true);
        assertEquals(0x123456, light.defaultBackground());
        assertEquals(0x000000, light.defaultForeground());
        assertEquals(0xC23621, dark.rgb(io.github.ghosthack.microhm.vt.Style.indexed(1), true));
        assertEquals(0xFFFFFF, dark.rgb(io.github.ghosthack.microhm.vt.Style.indexed(231), true));
        assertEquals(0x0A0B0C, dark.rgb(io.github.ghosthack.microhm.vt.Style.rgb(10, 11, 12), false));
    }
}
