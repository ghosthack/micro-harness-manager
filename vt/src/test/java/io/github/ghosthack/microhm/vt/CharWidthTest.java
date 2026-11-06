package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** The generated width table, spot-checked and against its golden wide set. */
class CharWidthTest {

    @Test
    void spotChecks() {
        assertEquals(1, CharWidth.of('a'));
        assertEquals(1, CharWidth.of(0xE9));     // é
        assertEquals(1, CharWidth.of(0x2500));   // ─ (ambiguous: narrow)
        assertEquals(1, CharWidth.of(0x00A1));   // ¡ (ambiguous)
        assertEquals(2, CharWidth.of(0x4E2D));   // 中
        assertEquals(2, CharWidth.of(0xAC00));   // 가
        assertEquals(2, CharWidth.of(0xFF21));   // Ａ fullwidth
        assertEquals(2, CharWidth.of(0x231A));   // ⌚ emoji presentation
        assertEquals(2, CharWidth.of(0x1F680));  // 🚀
        assertEquals(2, CharWidth.of(0x1F1FA));  // regional indicator
        assertEquals(2, CharWidth.of(0x20000));  // CJK extension B
        assertEquals(1, CharWidth.of(0x2764));   // ❤ text presentation
        assertEquals(1, CharWidth.of(0x1D400));  // 𝐀
        assertEquals(0, CharWidth.of(0x0301));   // combining acute
        assertEquals(0, CharWidth.of(0x200D));   // ZWJ
        assertEquals(0, CharWidth.of(0xFE0F));   // VS16
        assertEquals(2, CharWidth.of(0x1F3FB));  // skin tone modifier: wide on its own, joins an emoji
        assertEquals(0, CharWidth.of(0x1160));   // Hangul jungseong filler
        assertEquals(1, CharWidth.of(0x00AD));   // soft hyphen
        assertEquals(0, CharWidth.of(0xE0100));  // variation selector supplement
        assertEquals(0, CharWidth.of(0x85));     // C1
    }

    /** The BMP code points from U+00A1 that are two cells wide, as ranges. When frozen, this
     * matched jediterm-core's widecharwidth table (the same Unicode version) everywhere but
     * U+302E..U+302F, Hangul tone marks: spacing marks with East_Asian_Width W, which
     * widecharwidth files as combining. */
    @Test
    void wideBmpSetMatchesGolden() {
        StringBuilder out = new StringBuilder();
        int start = -1;
        for (int c = 0xA1; c <= 0x10000; c++) {
            boolean wide = c < 0x10000 && !Character.isSurrogate((char) c) && CharWidth.of(c) == 2;
            if (wide && start < 0) {
                start = c;
            } else if (!wide && start >= 0) {
                out.append(String.format("%04X..%04X%n", start, c - 1));
                start = -1;
            }
        }
        Golden.check("wide-bmp.txt", out.toString());
    }
}
