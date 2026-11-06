package io.github.ghosthack.microhm.vt;

/**
 * A cell's graphic rendition packed into one {@code long}, so a screen line stores its styles
 * in a plain {@code long[]} and nothing is allocated per cell. This class holds only static
 * helpers; {@link #DEFAULT} ({@code 0L}) is the default style (default colours, no attributes).
 *
 * <p>Layout: bits 0–25 foreground colour, 26–51 background colour, 52–63 attributes.
 *
 * <p>A <b>colour</b> is a 26-bit {@code int}: {@link #COLOR_DEFAULT} ({@code 0}) means the
 * renderer's default foreground/background; {@link #indexed(int)} is a palette index 0–255
 * (0–7 the ANSI colours set by SGR 30–37/40–47, 8–15 their bright variants from SGR 90–97/100–107,
 * 16–255 the xterm 256-colour cube and grey ramp, see {@link #xterm256Rgb(int)}); {@link #rgb(int,
 * int, int)} is a 24-bit direct colour. Inspect one with {@link #isIndexed(int)}, {@link
 * #index(int)}, {@link #isRgb(int)} and {@link #rgbValue(int)}.
 *
 * <p>Attributes: {@link #bold}, {@link #dim}, {@link #italic}, {@link #underline} (a style
 * number, see {@link #UNDERLINE_SINGLE} etc.), {@link #blink} (SGR 5), {@link #rapidBlink}
 * (SGR 6), {@link #inverse}, {@link #invisible}, {@link #strikethrough} and {@link #overline}.
 * Inverse is <em>not</em> applied to the colours here; a renderer swaps them itself.
 */
public final class Style {

    /** The default style: default colours, no attributes. */
    public static final long DEFAULT = 0L;

    /** The renderer's default foreground or background colour. */
    public static final int COLOR_DEFAULT = 0;

    /** No underline. */
    public static final int UNDERLINE_NONE = 0;
    /** SGR 4 / 4:1. */
    public static final int UNDERLINE_SINGLE = 1;
    /** SGR 21 / 4:2. */
    public static final int UNDERLINE_DOUBLE = 2;
    /** SGR 4:3. */
    public static final int UNDERLINE_CURLY = 3;
    /** SGR 4:4. */
    public static final int UNDERLINE_DOTTED = 4;
    /** SGR 4:5. */
    public static final int UNDERLINE_DASHED = 5;

    private static final int COLOR_BITS = 26;
    private static final long COLOR_MASK = (1L << COLOR_BITS) - 1;
    private static final int KIND_INDEXED = 1 << 24;
    private static final int KIND_RGB = 2 << 24;
    private static final int BG_SHIFT = COLOR_BITS;

    static final long BOLD = 1L << 52;
    static final long DIM = 1L << 53;
    private static final int UNDERLINE_SHIFT = 54;
    private static final long UNDERLINE_MASK = 7L << UNDERLINE_SHIFT;
    static final long ITALIC = 1L << 57;
    static final long BLINK = 1L << 58;
    static final long INVERSE = 1L << 59;
    static final long INVISIBLE = 1L << 60;
    static final long STRIKETHROUGH = 1L << 61;
    static final long OVERLINE = 1L << 62;
    static final long RAPID_BLINK = 1L << 63;

    private static final long FG_MASK = COLOR_MASK;
    private static final long BG_MASK = COLOR_MASK << BG_SHIFT;

    // --- colours ---------------------------------------------------------------------

    /** Palette colour {@code index} (0–255). */
    public static int indexed(int index) {
        return KIND_INDEXED | (index & 0xFF);
    }

    /** 24-bit direct colour. */
    public static int rgb(int r, int g, int b) {
        return KIND_RGB | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
    }

    /** True for a palette colour. */
    public static boolean isIndexed(int color) {
        return (color & ~0xFFFFFF) == KIND_INDEXED;
    }

    /** The palette index of an {@link #isIndexed} colour. */
    public static int index(int color) {
        return color & 0xFF;
    }

    /** True for a 24-bit direct colour. */
    public static boolean isRgb(int color) {
        return (color & ~0xFFFFFF) == KIND_RGB;
    }

    /** The {@code 0xRRGGBB} value of an {@link #isRgb} colour. */
    public static int rgbValue(int color) {
        return color & 0xFFFFFF;
    }

    /**
     * The {@code 0xRRGGBB} of xterm's default palette entry {@code index} for 16–255 (the
     * 6×6×6 cube, then the 24-step grey ramp). Entries 0–15 are theme colours, so this
     * returns -1 for them.
     */
    public static int xterm256Rgb(int index) {
        if (index < 16 || index > 255) {
            return -1;
        }
        if (index < 232) {
            int i = index - 16;
            return (cube(i / 36) << 16) | (cube((i / 6) % 6) << 8) | cube(i % 6);
        }
        int grey = 8 + 10 * (index - 232);
        return (grey << 16) | (grey << 8) | grey;
    }

    private static int cube(int level) {
        return level == 0 ? 0 : 55 + 40 * level;
    }

    // --- reading a style -------------------------------------------------------------

    /** The foreground colour. */
    public static int foreground(long style) {
        return (int) (style & FG_MASK);
    }

    /** The background colour. */
    public static int background(long style) {
        return (int) ((style & BG_MASK) >>> BG_SHIFT);
    }

    public static boolean bold(long style) {
        return (style & BOLD) != 0;
    }

    public static boolean dim(long style) {
        return (style & DIM) != 0;
    }

    public static boolean italic(long style) {
        return (style & ITALIC) != 0;
    }

    /** The underline style, {@link #UNDERLINE_NONE} … {@link #UNDERLINE_DASHED}. */
    public static int underline(long style) {
        return (int) ((style & UNDERLINE_MASK) >>> UNDERLINE_SHIFT);
    }

    /** SGR 5, slow blink. */
    public static boolean blink(long style) {
        return (style & BLINK) != 0;
    }

    /** SGR 6, rapid blink. */
    public static boolean rapidBlink(long style) {
        return (style & RAPID_BLINK) != 0;
    }

    public static boolean inverse(long style) {
        return (style & INVERSE) != 0;
    }

    /** SGR 8, concealed. */
    public static boolean invisible(long style) {
        return (style & INVISIBLE) != 0;
    }

    public static boolean strikethrough(long style) {
        return (style & STRIKETHROUGH) != 0;
    }

    /** SGR 53. */
    public static boolean overline(long style) {
        return (style & OVERLINE) != 0;
    }

    // --- building a style (package-private: only the emulator writes styles) ---------

    static long withForeground(long style, int color) {
        return (style & ~FG_MASK) | (color & COLOR_MASK);
    }

    static long withBackground(long style, int color) {
        return (style & ~BG_MASK) | ((color & COLOR_MASK) << BG_SHIFT);
    }

    static long withUnderline(long style, int underline) {
        return (style & ~UNDERLINE_MASK) | (((long) underline << UNDERLINE_SHIFT) & UNDERLINE_MASK);
    }

    static long with(long style, long flag, boolean on) {
        return on ? style | flag : style & ~flag;
    }

    /** The style an erase leaves behind: only the background survives (xterm's BCE). */
    static long eraseStyle(long pen) {
        return pen & BG_MASK;
    }

    /** A readable form for test failure messages, e.g. {@code fg=idx1 bg=#0a0b0c bold}. */
    public static String describe(long style) {
        StringBuilder sb = new StringBuilder();
        sb.append("fg=").append(describeColor(foreground(style)));
        sb.append(" bg=").append(describeColor(background(style)));
        if (bold(style)) sb.append(" bold");
        if (dim(style)) sb.append(" dim");
        if (italic(style)) sb.append(" italic");
        if (underline(style) != 0) sb.append(" underline=").append(underline(style));
        if (blink(style)) sb.append(" blink");
        if (rapidBlink(style)) sb.append(" rapidBlink");
        if (inverse(style)) sb.append(" inverse");
        if (invisible(style)) sb.append(" invisible");
        if (strikethrough(style)) sb.append(" strike");
        if (overline(style)) sb.append(" overline");
        return sb.toString();
    }

    private static String describeColor(int color) {
        if (isIndexed(color)) {
            return "idx" + index(color);
        }
        if (isRgb(color)) {
            return String.format("#%06x", rgbValue(color));
        }
        return "default";
    }

    private Style() {
    }
}
