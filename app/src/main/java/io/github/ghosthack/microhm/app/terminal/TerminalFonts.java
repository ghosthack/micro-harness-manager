package io.github.ghosthack.microhm.app.terminal;

import java.awt.Font;
import java.awt.GraphicsEnvironment;
import java.awt.font.FontRenderContext;
import java.awt.font.LineMetrics;
import java.awt.geom.Rectangle2D;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * The terminal font in its four styles, the cell metrics derived from it, and the fallback
 * fonts for code points it cannot display. Everything here is in <em>device</em> pixels: the
 * font is sized {@code size × scale} (Menlo 28 for Menlo 14 on a 2× Retina display), and the
 * view paints in device space. Cell width is the advance of 'W' (or 'M' if wider), cell
 * height ascent + descent + leading, both rounded up to whole device pixels so every cell
 * starts on a pixel boundary; at 2× that is half a point, so the rounding barely changes the
 * font's own proportions (Menlo 14: 8.5 × 16.5 points, where whole points gave 8 × 17).
 * Metrics are taken with antialiasing on and fractional metrics off, the same as painting.
 *
 * <p>Fallback: the first of a list of likely system fonts (emoji, CJK, symbols) that can
 * display the code point, then any installed font that can; cached per code point and style
 * in a small open-addressing map, so painting does not box or search.
 */
final class TerminalFonts {

    static final int PLAIN = 0;
    static final int BOLD = 1;
    static final int ITALIC = 2;

    static final FontRenderContext FRC = new FontRenderContext(null, true, false);

    private static final List<String> PREFERRED_FALLBACKS = List.of(
            "Apple Color Emoji", "Menlo", "SF Mono", "PingFang SC", "Hiragino Sans",
            "Apple SD Gothic Neo", "Apple Symbols", "Symbols Nerd Font", "Segoe UI Emoji",
            "Segoe UI Symbol", "Microsoft YaHei", "Yu Gothic", "Malgun Gothic", "Noto Color Emoji",
            "Noto Sans CJK SC", "Noto Sans Symbols 2", "Noto Sans Symbols", "DejaVu Sans Mono",
            "DejaVu Sans", Font.DIALOG);

    private final Font[] fonts = new Font[4];
    private final int cellWidth;
    private final int cellHeight;
    private final int baseline;
    private final float lineThickness;
    private final boolean exactAdvance;
    /** Families tried as fallbacks, resolved lazily (the installed-font list is slow). */
    private List<String> fallbackFamilies;
    private final FontCache fallback = new FontCache();

    /** {@code size} in points, {@code scale} device pixels per point (1 when unknown). */
    TerminalFonts(String family, int size, double scale) {
        Font plain = new Font(family, Font.PLAIN, size).deriveFont((float) (size * scale));
        fonts[PLAIN] = plain;
        fonts[BOLD] = plain.deriveFont(Font.BOLD);
        fonts[ITALIC] = plain.deriveFont(Font.ITALIC);
        fonts[BOLD | ITALIC] = plain.deriveFont(Font.BOLD | Font.ITALIC);
        double w = Math.max(advance(plain, "W"), advance(plain, "M"));
        LineMetrics lm = plain.getLineMetrics("Wg", FRC);
        cellWidth = Math.max(1, (int) Math.ceil(w - 0.01));
        double height = lm.getAscent() + lm.getDescent() + lm.getLeading();
        cellHeight = Math.max(1, (int) Math.ceil(height - 0.01));
        // centre the glyph box in the rounded-up cell
        baseline = (int) Math.round(lm.getAscent() + (cellHeight - height) / 2 + lm.getLeading() / 2);
        lineThickness = Math.max(1f, Math.round(lm.getUnderlineThickness()));
        exactAdvance = checkAdvances();
    }

    private static double advance(Font font, String s) {
        return font.getStringBounds(s, FRC).getWidth();
    }

    /** True when every printable ASCII character of every style advances exactly one cell,
     * so a run of them can be drawn with one call. */
    private boolean checkAdvances() {
        char[] chars = new char[95];
        for (int i = 0; i < chars.length; i++) {
            chars[i] = (char) (32 + i);
        }
        for (Font font : fonts) {
            for (char c : chars) {
                Rectangle2D b = font.getStringBounds(String.valueOf(c), FRC);
                if (Math.abs(b.getWidth() - cellWidth) > 0.001) {
                    return false;
                }
            }
        }
        return true;
    }

    int cellWidth() {
        return cellWidth;
    }

    int cellHeight() {
        return cellHeight;
    }

    /** Baseline offset from the top of a cell. */
    int baseline() {
        return baseline;
    }

    /** Underline/strike stroke thickness. */
    float lineThickness() {
        return lineThickness;
    }

    boolean exactAdvance() {
        return exactAdvance;
    }

    Font font(int style) {
        return fonts[style];
    }

    /** The font to draw {@code cp} in {@code style}: the terminal font when it can, else a
     * cached fallback (the terminal font if nothing can, for its missing-glyph box). */
    Font fontFor(int cp, int style) {
        Font primary = fonts[style];
        if (cp < 0x80 || primary.canDisplay(cp)) {
            return primary;
        }
        int key = cp * 4 + style;
        Font cached = fallback.get(key);
        if (cached != null) {
            return cached;
        }
        Font found = findFallback(cp, style);
        fallback.put(key, found);
        return found;
    }

    private Font findFallback(int cp, int style) {
        Font primary = fonts[style];
        for (String family : fallbackFamilies()) {
            Font candidate = new Font(family, primary.getStyle(), 1).deriveFont(primary.getSize2D());
            if (candidate.canDisplay(cp)) {
                return candidate;
            }
        }
        return primary;
    }

    private List<String> fallbackFamilies() {
        if (fallbackFamilies == null) {
            String[] installed = GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames();
            Set<String> lower = new java.util.HashSet<>();
            for (String name : installed) {
                lower.add(name.toLowerCase(Locale.ROOT));
            }
            List<String> families = new ArrayList<>();
            for (String name : PREFERRED_FALLBACKS) {
                if (name.equals(Font.DIALOG) || lower.contains(name.toLowerCase(Locale.ROOT))) {
                    families.add(name);
                }
            }
            for (String name : installed) {
                if (!families.contains(name) && !name.startsWith(".")) {
                    families.add(name);
                }
            }
            fallbackFamilies = families;
        }
        return fallbackFamilies;
    }

    /** int → Font, open addressing, grows at half load. */
    private static final class FontCache {
        private int[] keys = new int[64];
        private Font[] values = new Font[64];
        private int size;

        FontCache() {
            Arrays.fill(keys, -1);
        }

        Font get(int key) {
            int mask = keys.length - 1;
            for (int i = mix(key) & mask; ; i = (i + 1) & mask) {
                if (keys[i] == key) {
                    return values[i];
                }
                if (keys[i] == -1) {
                    return null;
                }
            }
        }

        void put(int key, Font value) {
            if ((size + 1) * 2 > keys.length) {
                int[] oldKeys = keys;
                Font[] oldValues = values;
                keys = new int[oldKeys.length * 2];
                values = new Font[oldKeys.length * 2];
                Arrays.fill(keys, -1);
                size = 0;
                for (int i = 0; i < oldKeys.length; i++) {
                    if (oldKeys[i] != -1) {
                        put(oldKeys[i], oldValues[i]);
                    }
                }
            }
            int mask = keys.length - 1;
            int i = mix(key) & mask;
            while (keys[i] != -1 && keys[i] != key) {
                i = (i + 1) & mask;
            }
            if (keys[i] == -1) {
                size++;
            }
            keys[i] = key;
            values[i] = value;
        }

        private static int mix(int key) {
            int h = key * 0x9E3779B9;
            return h ^ (h >>> 16);
        }
    }
}
