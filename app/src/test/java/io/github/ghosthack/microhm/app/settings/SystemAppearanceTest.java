package io.github.ghosthack.microhm.app.settings;

import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class SystemAppearanceTest {

    @Test
    void macReportsDarkOnlyWhenTheKeySaysSo() {
        assertEquals(AppSettings.UiTheme.DARK, SystemAppearance.parseMac(0, "Dark\n"));
        assertEquals(AppSettings.UiTheme.LIGHT, SystemAppearance.parseMac(1,
                "The domain/default pair of (kCFPreferencesAnyApplication, AppleInterfaceStyle) does not exist\n"));
    }

    @Test
    void gnomeCountsOnlyAnExplicitPreference() {
        assertEquals(Optional.of(AppSettings.UiTheme.DARK), SystemAppearance.parseGnome("'prefer-dark'\n"));
        assertEquals(Optional.of(AppSettings.UiTheme.LIGHT), SystemAppearance.parseGnome("'prefer-light'"));
        assertEquals(Optional.empty(), SystemAppearance.parseGnome("'default'"));
    }

    @Test
    void unknownPlatformsHaveNoDetector() {
        assertEquals(Optional.empty(), SystemAppearance.detect("Windows 11"));
    }
}
