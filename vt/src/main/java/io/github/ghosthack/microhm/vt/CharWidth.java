package io.github.ghosthack.microhm.vt;

/**
 * How many terminal columns a code point occupies: 0 (it attaches to the previous cell —
 * combining marks, format characters such as ZWJ, variation selectors), 1, or 2 (East Asian
 * Wide/Fullwidth and emoji presentation). East Asian Ambiguous characters are 1. The data is
 * the generated {@link WidthTable} (Unicode 17.0.0, the same version jediterm-core's
 * widecharwidth table uses); the Basic Multilingual Plane is expanded into a 64 KiB lookup
 * at class load, so the common case is one array read.
 *
 * <p>C0/C1 controls and DEL never reach this (the tokenizer and emulator handle them); they
 * report 0.
 */
public final class CharWidth {

    private static final byte[] BMP = new byte[0x10000];

    static {
        java.util.Arrays.fill(BMP, (byte) 1);
        fill(WidthTable.WIDE, (byte) 2);
        fill(WidthTable.ZERO, (byte) 0);
        for (int c = 0; c < 0x20; c++) {
            BMP[c] = 0;
        }
        for (int c = 0x7F; c < 0xA0; c++) {
            BMP[c] = 0;
        }
    }

    private static void fill(int[] ranges, byte width) {
        for (int i = 0; i < ranges.length; i += 2) {
            int lo = ranges[i];
            if (lo > 0xFFFF) {
                break;
            }
            int hi = Math.min(ranges[i + 1], 0xFFFF);
            java.util.Arrays.fill(BMP, lo, hi + 1, width);
        }
    }

    /** The column width of {@code codePoint}: 0, 1 or 2. */
    public static int of(int codePoint) {
        if (codePoint < 0x10000) {
            return codePoint < 0 ? 0 : BMP[codePoint];
        }
        if (contains(WidthTable.ZERO, codePoint)) {
            return 0;
        }
        return contains(WidthTable.WIDE, codePoint) ? 2 : 1;
    }

    private static boolean contains(int[] ranges, int cp) {
        int lo = 0;
        int hi = ranges.length / 2 - 1;
        while (lo <= hi) {
            int mid = (lo + hi) >>> 1;
            if (cp < ranges[2 * mid]) {
                hi = mid - 1;
            } else if (cp > ranges[2 * mid + 1]) {
                lo = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    private CharWidth() {
    }
}
