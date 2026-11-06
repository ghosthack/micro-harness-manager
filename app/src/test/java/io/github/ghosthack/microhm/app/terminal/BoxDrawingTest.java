package io.github.ghosthack.microhm.app.terminal;

import org.junit.jupiter.api.Test;

import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BoxDrawingTest {

    private static final int W = 9;
    private static final int H = 18;

    /** Renders {@code text} one character per cell and returns the image. */
    private static BufferedImage render(String text, int rows) {
        int columns = text.length() / rows;
        BufferedImage image = new BufferedImage(columns * W, rows * H, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = image.createGraphics();
        for (int i = 0; i < text.length(); i++) {
            int cp = text.charAt(i);
            assertTrue(BoxDrawing.draw(g, cp, (i % columns) * W, (i / columns) * H, W, H, Color.WHITE));
        }
        g.dispose();
        return image;
    }

    /** Centres of the lit blobs along one pixel row or column, as the midpoints of runs. */
    private static List<Integer> runCentres(BufferedImage image, boolean horizontal, int at) {
        List<Integer> centres = new ArrayList<>();
        int length = horizontal ? image.getWidth() : image.getHeight();
        int start = -1;
        for (int i = 0; i <= length; i++) {
            boolean lit = i < length && (image.getRGB(horizontal ? i : at, horizontal ? at : i) & 0xFF) > 128;
            if (lit && start < 0) {
                start = i;
            } else if (!lit && start >= 0) {
                centres.add((start + i - 1) / 2);
                start = -1;
            }
        }
        return centres;
    }

    @Test
    void brailleIsDrawnForTheWholeBlock() {
        assertTrue(BoxDrawing.handles(0x2800));
        assertTrue(BoxDrawing.handles(0x28FF));
        assertFalse(BoxDrawing.handles(0x2900));
    }

    @Test
    void theBlankPatternDrawsNothing() {
        BufferedImage image = render("⠀", 1);
        for (int x = 0; x < W; x++) {
            for (int y = 0; y < H; y++) {
                assertEquals(0, image.getRGB(x, y) & 0xFFFFFF);
            }
        }
    }

    /** Three full cells (⣿) side by side and two rows high: the dots form one even grid,
     * so the gap between cells equals the gap inside a cell, both ways. */
    @Test
    void fullCellsTileIntoOneEvenGrid() {
        BufferedImage image = render("⣿⣿⣿⣿⣿⣿", 2);
        int dotRow = Math.round(H / 8f);
        List<Integer> xs = runCentres(image, true, dotRow);
        assertEquals(6, xs.size(), "two dots per cell across three cells: " + xs);
        List<Integer> ys = runCentres(image, false, Math.round(W / 4f));
        assertEquals(8, ys.size(), "four dots per cell down two rows: " + ys);
        for (int i = 1; i < xs.size(); i++) {
            assertTrue(Math.abs(xs.get(i) - xs.get(i - 1) - W / 2.0) <= 1, "horizontal pitch: " + xs);
        }
        for (int i = 1; i < ys.size(); i++) {
            assertTrue(Math.abs(ys.get(i) - ys.get(i - 1) - H / 4.0) <= 1, "vertical pitch: " + ys);
        }
    }

    /** Brightness-weighted centres of the blobs along a band of pixel rows (horizontal) or
     * columns (vertical) — sub-pixel positions of antialiased dots. */
    private static List<Double> centroids(BufferedImage image, boolean horizontal, int from, int to) {
        int length = horizontal ? image.getWidth() : image.getHeight();
        double[] profile = new double[length + 1];
        for (int i = 0; i < length; i++) {
            for (int k = from; k < to; k++) {
                profile[i] += image.getRGB(horizontal ? i : k, horizontal ? k : i) & 0xFF;
            }
        }
        List<Double> centres = new ArrayList<>();
        double sum = 0;
        double weighted = 0;
        for (int i = 0; i <= length; i++) {
            if (profile[i] > 0) {
                sum += profile[i];
                weighted += profile[i] * i;
            } else if (sum > 0) {
                centres.add(weighted / sum);
                sum = 0;
                weighted = 0;
            }
        }
        return centres;
    }

    /** At the 2× cell of Menlo 14 (17 × 33 device pixels; dot pitch 8.5 × 8.25) the dots
     * are evenly spaced to a fraction of a pixel, inside cells and across their edges.
     * Whole-pixel dots alternated 8- and 9-pixel gaps here. */
    @Test
    void retinaCellsKeepAnEvenPitch() {
        int w = 17;
        int h = 33;
        BufferedImage image = new BufferedImage(3 * w, 2 * h, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = image.createGraphics();
        for (int i = 0; i < 6; i++) {
            BoxDrawing.draw(g, 0x28FF, (i % 3) * w, (i / 3) * h, w, h, Color.WHITE);
        }
        g.dispose();
        List<Double> xs = centroids(image, true, 0, (int) (h / 4.0)); // the first dot row
        List<Double> ys = centroids(image, false, 0, (int) (w / 2.0)); // the first dot column
        assertEquals(6, xs.size(), String.valueOf(xs));
        assertEquals(8, ys.size(), String.valueOf(ys));
        for (int i = 1; i < xs.size(); i++) {
            assertEquals(w / 2.0, xs.get(i) - xs.get(i - 1), 0.15, "horizontal pitch: " + xs);
        }
        for (int i = 1; i < ys.size(); i++) {
            assertEquals(h / 4.0, ys.get(i) - ys.get(i - 1), 0.15, "vertical pitch: " + ys);
        }
    }

    /** Dots 1–8 map to the standard positions: 1 2 3 7 down the left, 4 5 6 8 the right. */
    @Test
    void dotNumberingFollowsTheStandard() {
        int[][] expected = {{0x01, 0, 0}, {0x02, 0, 1}, {0x04, 0, 2}, {0x40, 0, 3},
                {0x08, 1, 0}, {0x10, 1, 1}, {0x20, 1, 2}, {0x80, 1, 3}};
        for (int[] e : expected) {
            BufferedImage image = render(String.valueOf((char) (0x2800 + e[0])), 1);
            int cx = Math.round((2 * e[1] + 1) * W / 4f);
            int cy = Math.round((2 * e[2] + 1) * H / 8f);
            assertTrue((image.getRGB(cx, cy) & 0xFF) > 128, "dot bit " + Integer.toHexString(e[0]));
            int other = Math.round((2 * (1 - e[1]) + 1) * W / 4f);
            assertEquals(0, image.getRGB(other, cy) & 0xFFFFFF, "only that column, bit " + Integer.toHexString(e[0]));
        }
    }

    // --- block mosaics -------------------------------------------------------------------

    private static long matching(String regex) {
        return BoxDrawing.MOSAICS.keySet().stream().filter(cp -> Character.getName(cp).matches(regex)).count();
    }

    private static long count(String prefix) {
        return BoxDrawing.MOSAICS.keySet().stream().filter(cp -> Character.getName(cp).startsWith(prefix)).count();
    }

    @Test
    void everySextantOctantAndEighthBarIsDrawn() {
        assertEquals(60, count("BLOCK SEXTANT-"));
        assertEquals(230, count("BLOCK OCTANT-"));
        assertEquals(6, count("VERTICAL ONE EIGHTH BLOCK-"));
        assertEquals(7, count("HORIZONTAL ONE EIGHTH BLOCK-"));
        assertEquals(16, matching(".* ONE SIXTEENTH BLOCK"));
        assertEquals(16, matching(".* (HALF|THREE QUARTERS) .* ONE QUARTER BLOCK"));
        assertEquals(10, matching("(UPPER|RIGHT) (ONE QUARTER|THREE EIGHTHS|FIVE EIGHTHS|THREE QUARTERS|SEVEN EIGHTHS) BLOCK"));
        assertEquals(5, matching(".* AND .* ONE EIGHTH BLOCK"));
        assertEquals(2, matching("LEFT .* THIRDS? BLOCK"));
        assertEquals(4, matching("(UPPER|LOWER) CENTRE ONE QUARTER BLOCK|MIDDLE (LEFT|RIGHT) ONE QUARTER BLOCK"));
        assertEquals(60 + 230 + 6 + 7 + 16 + 16 + 10 + 5 + 2 + 4, BoxDrawing.MOSAICS.size(), "nothing else");
        for (int cp : new int[]{0x1FB00, 0x1FB3B, 0x1CD00, 0x1CDE5, 0x1FB70, 0x1FB82, 0x1FB8B, 0x23BA}) {
            assertTrue(BoxDrawing.handles(cp), Integer.toHexString(cp));
            assertEquals(1, io.github.ghosthack.microhm.vt.CharWidth.of(cp), "one cell: " + Integer.toHexString(cp));
        }
        assertFalse(BoxDrawing.handles(0x1FB3C), "the wedges are not mosaics");
    }

    @Test
    void mosaicsFollowTheirNames() {
        assertEquals(new BoxDrawing.Mosaic(2, 3, 0b000001), BoxDrawing.mosaic("BLOCK SEXTANT-1"));
        assertEquals(new BoxDrawing.Mosaic(2, 3, 0b111101), BoxDrawing.mosaic("BLOCK SEXTANT-13456"));
        assertEquals(new BoxDrawing.Mosaic(2, 4, 0b00000110), BoxDrawing.mosaic("BLOCK OCTANT-23"));
        assertEquals(new BoxDrawing.Mosaic(8, 1, 0b100), BoxDrawing.mosaic("VERTICAL ONE EIGHTH BLOCK-3"));
        assertEquals(new BoxDrawing.Mosaic(1, 8, 0b10010101), BoxDrawing.mosaic("HORIZONTAL ONE EIGHTH BLOCK-1358"));
        assertEquals(new BoxDrawing.Mosaic(1, 8, 0b11), BoxDrawing.mosaic("UPPER ONE QUARTER BLOCK"));
        assertEquals(new BoxDrawing.Mosaic(8, 1, 0b11100000), BoxDrawing.mosaic("RIGHT THREE EIGHTHS BLOCK"));
        assertEquals(new BoxDrawing.Mosaic(3, 1, 0b11), BoxDrawing.mosaic("LEFT TWO THIRDS BLOCK"));
        // 4 × 4, bit row * 4 + column
        assertEquals(new BoxDrawing.Mosaic(4, 4, 1L << 6), BoxDrawing.mosaic("UPPER MIDDLE CENTRE RIGHT ONE SIXTEENTH BLOCK"));
        assertEquals(new BoxDrawing.Mosaic(4, 4, (1L << 14) | (1L << 15)), BoxDrawing.mosaic("RIGHT HALF LOWER ONE QUARTER BLOCK"));
        assertEquals(new BoxDrawing.Mosaic(4, 4, 0b0011), BoxDrawing.mosaic("LEFT HALF UPPER ONE QUARTER BLOCK"));
        assertEquals(new BoxDrawing.Mosaic(4, 4, (1L << 4) | (1L << 8) | (1L << 12)),
                BoxDrawing.mosaic("LOWER THREE QUARTERS LEFT ONE QUARTER BLOCK"));
        assertEquals(new BoxDrawing.Mosaic(4, 4, 0x0066L), BoxDrawing.mosaic("UPPER CENTRE ONE QUARTER BLOCK"));
        assertTrue(BoxDrawing.tiles(0x1FB3C) && BoxDrawing.tiles(0x1CCA6) && !BoxDrawing.tiles(0x2800));
        BoxDrawing.Mosaic corner = BoxDrawing.mosaic("LEFT AND LOWER ONE EIGHTH BLOCK");
        assertTrue((corner.mask() & 1L) != 0 && (corner.mask() & (1L << 63)) != 0 && (corner.mask() & 2L) == 0);
    }

    /** Sextant 1 (top left) in every cell of a 3 × 3 block, at a cell height not divisible
     * by three: the lit parts form an exact lattice — same size everywhere, nothing touching
     * across a cell edge — and full sextant rows join their neighbours without a gap. */
    @Test
    void mosaicsTileWithoutGapsOrSteps() {
        int h = 17;
        BufferedImage image = new BufferedImage(3 * W, 3 * h, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = image.createGraphics();
        for (int r = 0; r < 3; r++) {
            for (int c = 0; c < 3; c++) {
                // full top third (1 + 2), so each row of cells must be one unbroken band
                BoxDrawing.draw(g, 0x1FB02, c * W, r * h, W, h, Color.WHITE);
            }
        }
        g.dispose();
        for (int r = 0; r < 3; r++) {
            int band = r * h + 1;
            for (int x = 0; x < 3 * W; x++) {
                assertTrue((image.getRGB(x, band) & 0xFF) > 0, "band row " + r + " gap at x=" + x);
            }
            int bandHeight = 0;
            for (int y = r * h; y < (r + 1) * h; y++) {
                bandHeight += (image.getRGB(W, y) & 0xFF) > 0 ? 1 : 0;
            }
            assertEquals(Math.round(h / 3f), bandHeight, "a third of the cell, row " + r);
        }
    }

    @Test
    void scanLinesStepDownTheCell() {
        int previous = -1;
        for (int cp = 0x23BA; cp <= 0x23BD; cp++) {
            BufferedImage image = render(String.valueOf((char) cp), 1);
            int lit = -1;
            for (int y = 0; y < H && lit < 0; y++) {
                if ((image.getRGB(W / 2, y) & 0xFF) > 0) {
                    lit = y;
                }
            }
            assertTrue(lit > previous, "scan line " + Integer.toHexString(cp) + " at " + lit);
            previous = lit;
        }
    }

    /** Every non-empty pattern of a 2 × 4 grid (what an octant-resolution picture needs) is
     * drawn exactly by some character micro draws as geometry, whichever block Unicode put
     * it in (octants, quadrants, halves, quarter strips, eighths). */
    @Test
    void everyTwoByFourPatternHasAGeometricCharacter() {
        java.util.Set<Integer> patterns = new java.util.HashSet<>();
        java.util.List<Integer> candidates = new java.util.ArrayList<>(BoxDrawing.MOSAICS.keySet());
        for (int cp = 0x2580; cp <= 0x259F; cp++) {
            candidates.add(cp);
        }
        for (int cp : candidates) {
            BufferedImage image = new BufferedImage(8, 8, BufferedImage.TYPE_INT_RGB);
            Graphics2D g = image.createGraphics();
            BoxDrawing.draw(g, cp, 0, 0, 8, 8, Color.WHITE);
            g.dispose();
            int pattern = 0;
            boolean exact = true;
            for (int row = 0; row < 4 && exact; row++) {
                for (int column = 0; column < 2 && exact; column++) {
                    int lit = 0;
                    for (int y = row * 2; y < row * 2 + 2; y++) {
                        for (int x = column * 4; x < column * 4 + 4; x++) {
                            lit += (image.getRGB(x, y) & 0xFFFFFF) == 0xFFFFFF ? 1 : 0;
                        }
                    }
                    if (lit == 8) {
                        pattern |= 1 << (row * 2 + column);
                    } else if (lit != 0) {
                        exact = false;
                    }
                }
            }
            if (exact && pattern != 0) {
                patterns.add(pattern);
            }
        }
        java.util.List<String> missing = new java.util.ArrayList<>();
        for (int pattern = 1; pattern < 256; pattern++) {
            if (!patterns.contains(pattern)) {
                missing.add(Integer.toBinaryString(pattern));
            }
        }
        assertTrue(missing.isEmpty(), "2 × 4 patterns with no geometric character: " + missing);
    }
}
