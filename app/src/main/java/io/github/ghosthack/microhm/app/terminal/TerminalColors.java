package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.vt.Style;

import java.awt.Color;

/**
 * Resolves the emulator's colours ({@link Style} colour ints) to {@code 0xRRGGBB}: the 16
 * ANSI slots from the palette, 16-255 from the xterm cube and grey ramp, truecolor as is,
 * and {@link Style#COLOR_DEFAULT} to the theme's default foreground/background. Mutable, EDT
 * only: the theme and palette switch live, and every paint resolves through here, so cells
 * already on screen recolour too.
 *
 * <p>Defaults follow the palette like the earlier widget did: on a dark terminal the
 * background is slot 0 and text slot 15, on a light one the reverse; a custom background
 * (matching a UI surface) replaces only the background.
 */
final class TerminalColors {

    private static final int[] CUBE = new int[256];

    static {
        for (int i = 16; i < 256; i++) {
            CUBE[i] = Style.xterm256Rgb(i);
        }
    }

    private final int[] ansi = new int[16];
    private boolean light;
    private Integer customBackground;
    private int defaultForeground;
    private int defaultBackground;
    /** Direct-mapped cache so painting does not allocate a {@link Color} per run. */
    private final Color[] cache = new Color[1024];

    TerminalColors(int[] palette, boolean light) {
        setPalette(palette);
        setTheme(null, light);
    }

    void setPalette(int[] palette) {
        System.arraycopy(palette, 0, ansi, 0, 16);
        recompute();
    }

    /** {@code background} null: the palette's black (dark) or white (light) slot. */
    void setTheme(Integer background, boolean light) {
        this.customBackground = background;
        this.light = light;
        recompute();
    }

    private void recompute() {
        defaultBackground = customBackground != null ? customBackground : (light ? ansi[15] : ansi[0]);
        defaultForeground = light ? ansi[0] : ansi[15];
    }

    boolean light() {
        return light;
    }

    int defaultForeground() {
        return defaultForeground;
    }

    int defaultBackground() {
        return defaultBackground;
    }

    /** The selection highlight behind selected cells. */
    int selection() {
        return light ? 0xB4D5FE : 0x264F78;
    }

    /** {@code 0xRRGGBB} of an emulator colour used as a foreground or a background. */
    int rgb(int color, boolean foreground) {
        if (color == Style.COLOR_DEFAULT) {
            return foreground ? defaultForeground : defaultBackground;
        }
        if (Style.isIndexed(color)) {
            int index = Style.index(color);
            return index < 16 ? ansi[index] : CUBE[index];
        }
        return Style.rgbValue(color);
    }

    /** A cached opaque {@link Color} for {@code rgb}. */
    Color color(int rgb) {
        rgb &= 0xFFFFFF;
        int slot = (rgb ^ (rgb >>> 10) ^ (rgb >>> 20)) & (cache.length - 1);
        Color c = cache[slot];
        if (c == null || (c.getRGB() & 0xFFFFFF) != rgb) {
            c = new Color(rgb);
            cache[slot] = c;
        }
        return c;
    }

    /** {@code a} moved {@code amount} (0..1) of the way to {@code b}, per channel. */
    static int blend(int a, int b, float amount) {
        int r = mix((a >> 16) & 0xFF, (b >> 16) & 0xFF, amount);
        int g = mix((a >> 8) & 0xFF, (b >> 8) & 0xFF, amount);
        int bl = mix(a & 0xFF, b & 0xFF, amount);
        return (r << 16) | (g << 8) | bl;
    }

    private static int mix(int a, int b, float amount) {
        return Math.round(a + (b - a) * amount);
    }
}
