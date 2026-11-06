package io.github.ghosthack.microhm.app.terminal;

import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.geom.Line2D;
import java.awt.geom.Path2D;

/**
 * The characters made to tile — to touch the cell's edges and join their neighbours into
 * lines and pictures — drawn as geometry fitted to the cell, since no font's glyph box is
 * the cell (and a fallback font's, used where the terminal font has no glyph, is smaller
 * and sits on its own baseline, leaving gaps and steps between cells):
 * <ul>
 *   <li>box drawing (U+2500–257F) and block elements (U+2580–259F);</li>
 *   <li>braille patterns (U+2800–28FF): dots on one even 2 × 4 grid across cells, so
 *       braille "pixel art" lines up;</li>
 *   <li>block mosaics from Symbols for Legacy Computing and its Supplement: the sextants
 *       (2 × 3), octants (2 × 4), one-eighth bars and partial blocks, read from the
 *       characters' Unicode names (so the table cannot drift from the standard): see
 *       {@link #MOSAICS};</li>
 *   <li>the horizontal scan lines (U+23BA–23BD) and the Powerline separators
 *       (U+E0B0–E0B3).</li>
 * </ul>
 * Glyphs that are not made to tile (letters, symbols, emoji) are left to the font: on its
 * baseline they line up with the text around them. Lines are integer rectangles
 * (crisp at any scale); arcs and diagonals are antialiased strokes.
 *
 * <p>Each line character is four arms — up, right, down, left — of weight 0 none, 1 light,
 * 2 heavy or 3 double. Light is about an eighth of the cell width, heavy twice that, and a
 * double line is two light strokes a light width apart.
 */
final class BoxDrawing {

    /** URDL weights for U+2500–U+254B ('d' marks the dashed lines, drawn separately). */
    private static final String[] LINES_1 = {
            "0101", "0202", "1010", "2020", "d", "d", "d", "d", "d", "d", "d", "d",
            "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022",
            "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002",
            "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
            "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022",
            "0111", "0112", "0211", "0212", "0121", "0122", "0221", "0222",
            "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
            "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112",
            "2211", "1122", "1221", "2212", "1222", "2122", "2221", "2222"};

    /** URDL weights for U+2550–U+256C (3 = double). */
    private static final String[] LINES_2 = {
            "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033",
            "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
            "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303",
            "3101", "3303", "1313", "3131", "3333"};

    /** URDL weights for U+2574–U+257F. */
    private static final String[] LINES_3 = {
            "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020",
            "0201", "1020", "0102", "2010"};

    static boolean handles(int cp) {
        return (cp >= 0x2500 && cp <= 0x259F) || (cp >= 0x2800 && cp <= 0x28FF) || (cp >= 0xE0B0 && cp <= 0xE0B3)
                || (cp >= 0x23BA && cp <= 0x23BD) || MOSAICS.containsKey(cp);
    }

    /** A cell divided into {@code columns} × {@code rows} equal parts; {@code mask} bit
     * {@code row * columns + column} set where the part is filled. */
    record Mosaic(int columns, int rows, long mask) {
    }

    /** Partial-block fractions in eighths (declared before {@link #MOSAICS}, which reads it). */
    private static final java.util.Map<String, Integer> EIGHTHS = java.util.Map.of(
            "ONE QUARTER", 2, "THREE EIGHTHS", 3, "FIVE EIGHTHS", 5, "THREE QUARTERS", 6, "SEVEN EIGHTHS", 7);

    /** Block mosaics by code point, built from the Unicode character names. */
    static final java.util.Map<Integer, Mosaic> MOSAICS = mosaics();

    private static java.util.Map<Integer, Mosaic> mosaics() {
        java.util.Map<Integer, Mosaic> out = new java.util.HashMap<>();
        int[][] ranges = {{0x1FB00, 0x1FBFF}, {0x1CC00, 0x1CEBF}};
        for (int[] range : ranges) {
            for (int cp = range[0]; cp <= range[1]; cp++) {
                String name = Character.getName(cp);
                Mosaic m = name == null ? null : mosaic(name);
                if (m != null) {
                    out.put(cp, m);
                }
            }
        }
        return java.util.Map.copyOf(out);
    }

    /** The mosaic a character name describes, or null. Dots and eighths are numbered from
     * the top left, row by row (sextant 1 2 / 3 4 / 5 6; octant 1 2 / … / 7 8). */
    static Mosaic mosaic(String name) {
        java.util.regex.Matcher m;
        if ((m = java.util.regex.Pattern.compile("BLOCK SEXTANT-(\\d+)").matcher(name)).matches()) {
            return new Mosaic(2, 3, digits(m.group(1)));
        }
        if ((m = java.util.regex.Pattern.compile("BLOCK OCTANT-(\\d+)").matcher(name)).matches()) {
            return new Mosaic(2, 4, digits(m.group(1)));
        }
        if ((m = java.util.regex.Pattern.compile("VERTICAL ONE EIGHTH BLOCK-(\\d+)").matcher(name)).matches()) {
            return new Mosaic(8, 1, digits(m.group(1)));
        }
        if ((m = java.util.regex.Pattern.compile("HORIZONTAL ONE EIGHTH BLOCK-(\\d+)").matcher(name)).matches()) {
            return new Mosaic(1, 8, digits(m.group(1)));
        }
        if ((m = java.util.regex.Pattern.compile("(LEFT|RIGHT|UPPER|LOWER) AND (LEFT|RIGHT|UPPER|LOWER) ONE EIGHTH BLOCK")
                .matcher(name)).matches()) {
            return new Mosaic(8, 8, edge(m.group(1)) | edge(m.group(2)));
        }
        if ((m = java.util.regex.Pattern.compile("(UPPER|RIGHT) (ONE QUARTER|THREE EIGHTHS|FIVE EIGHTHS|THREE QUARTERS"
                + "|SEVEN EIGHTHS) BLOCK").matcher(name)).matches()) {
            int n = EIGHTHS.get(m.group(2));
            long mask = 0;
            for (int i = 0; i < n; i++) {
                mask |= 1L << (m.group(1).equals("UPPER") ? i : 7 - i);
            }
            return m.group(1).equals("UPPER") ? new Mosaic(1, 8, mask) : new Mosaic(8, 1, mask);
        }
        if ((m = java.util.regex.Pattern.compile("LEFT (ONE THIRD|TWO THIRDS) BLOCK").matcher(name)).matches()) {
            return new Mosaic(3, 1, m.group(1).startsWith("ONE") ? 0b1 : 0b11);
        }
        // a 4 × 4 grid: rows UPPER, UPPER MIDDLE, LOWER MIDDLE, LOWER; columns LEFT,
        // CENTRE LEFT, CENTRE RIGHT, RIGHT
        if ((m = java.util.regex.Pattern.compile("(UPPER|UPPER MIDDLE|LOWER MIDDLE|LOWER) (LEFT|CENTRE LEFT|CENTRE RIGHT"
                + "|RIGHT) ONE SIXTEENTH BLOCK").matcher(name)).matches()) {
            int row = java.util.List.of("UPPER", "UPPER MIDDLE", "LOWER MIDDLE", "LOWER").indexOf(m.group(1));
            int column = java.util.List.of("LEFT", "CENTRE LEFT", "CENTRE RIGHT", "RIGHT").indexOf(m.group(2));
            return new Mosaic(4, 4, 1L << (row * 4 + column));
        }
        if ((m = java.util.regex.Pattern.compile("(UPPER|LOWER) CENTRE ONE QUARTER BLOCK").matcher(name)).matches()) {
            return new Mosaic(4, 4, m.group(1).equals("UPPER") ? 0x0066L : 0x6600L);
        }
        if ((m = java.util.regex.Pattern.compile("MIDDLE (LEFT|RIGHT) ONE QUARTER BLOCK").matcher(name)).matches()) {
            return new Mosaic(4, 4, m.group(1).equals("LEFT") ? 0x0330L : 0x0CC0L);
        }
        // "RIGHT HALF LOWER ONE QUARTER BLOCK": the quarter-wide strip along the lower edge,
        // over the right half of it
        if ((m = java.util.regex.Pattern.compile("(LEFT|RIGHT|UPPER|LOWER) (HALF|THREE QUARTERS) (UPPER|LOWER|LEFT|RIGHT)"
                + " ONE QUARTER BLOCK").matcher(name)).matches()) {
            String from = m.group(1);
            int extent = m.group(2).equals("HALF") ? 2 : 3;
            String side = m.group(3);
            long mask = 0;
            for (int i = 0; i < 4; i++) {
                boolean horizontalStrip = side.equals("UPPER") || side.equals("LOWER");
                int along = from.equals("LEFT") || from.equals("UPPER") ? i : 3 - i;
                if (i >= extent) {
                    continue;
                }
                int row = horizontalStrip ? (side.equals("UPPER") ? 0 : 3) : along;
                int column = horizontalStrip ? along : (side.equals("LEFT") ? 0 : 3);
                mask |= 1L << (row * 4 + column);
            }
            return new Mosaic(4, 4, mask);
        }
        return null;
    }

    /**
     * Whether {@code cp} is in a block whose characters are made to tile (Symbols for
     * Legacy Computing and its Supplement): those this class cannot draw — pictograph
     * pieces, wedges — are drawn by a font, stretched to fill the cell exactly, so that
     * whatever font has them they still meet their neighbours.
     */
    static boolean tiles(int cp) {
        return (cp >= 0x1FB00 && cp <= 0x1FBFF) || (cp >= 0x1CC00 && cp <= 0x1CEBF);
    }

    /** Parts numbered from 1 in the name → bits from 0. */
    private static long digits(String parts) {
        long mask = 0;
        for (char c : parts.toCharArray()) {
            mask |= 1L << (c - '1');
        }
        return mask;
    }

    /** One edge eighth of an 8 × 8 grid. */
    private static long edge(String side) {
        long mask = 0;
        for (int i = 0; i < 8; i++) {
            mask |= 1L << switch (side) {
                case "LEFT" -> i * 8;
                case "RIGHT" -> i * 8 + 7;
                case "UPPER" -> i;
                default -> 56 + i;
            };
        }
        return mask;
    }

    /** Fills the mosaic's parts, part edges rounded the same way in every cell so
     * neighbouring cells meet without gaps or overlaps. */
    static void mosaic(Graphics2D g, Mosaic m, int x, int y, int w, int h) {
        for (int row = 0; row < m.rows(); row++) {
            int top = y + Math.round(row * h / (float) m.rows());
            int bottom = y + Math.round((row + 1) * h / (float) m.rows());
            for (int column = 0; column < m.columns(); column++) {
                if ((m.mask() & (1L << (row * m.columns() + column))) == 0) {
                    continue;
                }
                int left = x + Math.round(column * w / (float) m.columns());
                int right = x + Math.round((column + 1) * w / (float) m.columns());
                g.fillRect(left, top, right - left, bottom - top);
            }
        }
    }

    /**
     * Draws {@code cp} into the cell at {@code (x, y)} of {@code w} × {@code h} in
     * {@code color}. Returns false for a character in the range it leaves to the font.
     */
    static boolean draw(Graphics2D g, int cp, int x, int y, int w, int h, Color color) {
        if (!handles(cp)) {
            return false;
        }
        g.setColor(color);
        if (cp >= 0x2800 && cp <= 0x28FF) {
            braille(g, cp - 0x2800, x, y, w, h);
            return true;
        }
        Mosaic mosaic = MOSAICS.get(cp);
        if (mosaic != null) {
            mosaic(g, mosaic, x, y, w, h);
            return true;
        }
        int light = Math.max(1, Math.round(w / 8f));
        if (cp >= 0x23BA && cp <= 0x23BD) {
            // scan lines 1, 3, 7, 9 of nine; 5 would be the box-drawing horizontal
            int line = new int[]{1, 3, 7, 9}[cp - 0x23BA];
            int centre = y + Math.round((line - 0.5f) * h / 9f);
            g.fillRect(x, Math.max(y, centre - light / 2), w, light);
            return true;
        }
        int heavy = Math.max(light + 1, light * 2);
        if (cp >= 0x2580) {
            return cp >= 0xE0B0 ? powerline(g, cp, x, y, w, h, light) : block(g, cp, x, y, w, h, color);
        }
        String arms = null;
        if (cp <= 0x254B) {
            arms = LINES_1[cp - 0x2500];
        } else if (cp >= 0x2550 && cp <= 0x256C) {
            arms = LINES_2[cp - 0x2550];
        } else if (cp >= 0x2574) {
            arms = LINES_3[cp - 0x2574];
        }
        if (arms != null && !arms.equals("d")) {
            int u = arms.charAt(0) - '0';
            int r = arms.charAt(1) - '0';
            int d = arms.charAt(2) - '0';
            int l = arms.charAt(3) - '0';
            if (u == 3 || r == 3 || d == 3 || l == 3) {
                doubleLines(g, x, y, w, h, light, u, r, d, l);
            } else {
                lines(g, x, y, w, h, light, heavy, u, r, d, l);
            }
            return true;
        }
        return switch (cp) {
            case 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D -> {
                int n = cp >= 0x254C ? 2 : cp >= 0x2508 ? 4 : 3;
                int t = (cp & 1) == 0 ? light : heavy;
                dashes(g, x, y, w, h, t, n, true);
                yield true;
            }
            case 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F -> {
                int n = cp >= 0x254C ? 2 : cp >= 0x2508 ? 4 : 3;
                int t = (cp & 1) == 0 ? light : heavy;
                dashes(g, x, y, w, h, t, n, false);
                yield true;
            }
            case 0x256D, 0x256E, 0x256F, 0x2570 -> {
                arc(g, cp, x, y, w, h, light);
                yield true;
            }
            case 0x2571, 0x2572, 0x2573 -> {
                diagonal(g, cp, x, y, w, h, light);
                yield true;
            }
            default -> false;
        };
    }

    private static int thickness(int weight, int light, int heavy) {
        return weight == 2 ? heavy : weight == 0 ? 0 : light;
    }

    /** Light and heavy arms: each reaches past the centre by the perpendicular strokes'
     * half width, so corners and junctions are filled. */
    private static void lines(Graphics2D g, int x, int y, int w, int h, int light, int heavy,
                              int u, int r, int d, int l) {
        int tu = thickness(u, light, heavy);
        int tr = thickness(r, light, heavy);
        int td = thickness(d, light, heavy);
        int tl = thickness(l, light, heavy);
        int vertical = Math.max(tu, td);
        int horizontal = Math.max(tl, tr);
        if (tu > 0) {
            int band = horizontal > 0 ? horizontal : tu;
            int end = y + (h - band) / 2 + band;
            g.fillRect(x + (w - tu) / 2, y, tu, end - y);
        }
        if (td > 0) {
            int band = horizontal > 0 ? horizontal : td;
            int start = y + (h - band) / 2;
            g.fillRect(x + (w - td) / 2, start, td, y + h - start);
        }
        if (tl > 0) {
            int band = vertical > 0 ? vertical : tl;
            int end = x + (w - band) / 2 + band;
            g.fillRect(x, y + (h - tl) / 2, end - x, tl);
        }
        if (tr > 0) {
            int band = vertical > 0 ? vertical : tr;
            int start = x + (w - band) / 2;
            g.fillRect(start, y + (h - tr) / 2, x + w - start, tr);
        }
    }

    /**
     * Lines with a double arm. A double arm is two light strokes at ±t from the single
     * stroke's position; where it meets a perpendicular arm, its outer stroke runs to the far
     * stroke of that arm and its inner stroke stops at the near one, which draws ╔ ╦ ╬ and
     * the mixed single/double forms.
     */
    private static void doubleLines(Graphics2D g, int x, int y, int w, int h, int t,
                                    int u, int r, int d, int l) {
        boolean up = u > 0;
        boolean right = r > 0;
        boolean down = d > 0;
        boolean left = l > 0;
        int vx = x + (w - t) / 2;
        int hy = y + (h - t) / 2;
        boolean vDouble = u == 3 || d == 3;
        boolean hDouble = l == 3 || r == 3;
        int xa = vDouble ? vx - t : vx;
        int xb = vDouble ? vx + t : vx;
        int ya = hDouble ? hy - t : hy;
        int yb = hDouble ? hy + t : hy;
        int bottom = y + h;
        int far = x + w;
        if (up) {
            if (u == 3) {
                vRect(g, xa, y, (left ? ya : yb) + t, t);
                vRect(g, xb, y, (right ? ya : yb) + t, t);
            } else {
                int end = left && right ? (down ? yb : ya) + t : yb + t;
                vRect(g, vx, y, end, t);
            }
        }
        if (down) {
            if (d == 3) {
                vRect(g, xa, left ? yb : ya, bottom, t);
                vRect(g, xb, right ? yb : ya, bottom, t);
            } else {
                int start = left && right ? (up ? ya : yb) : ya;
                vRect(g, vx, start, bottom, t);
            }
        }
        if (left) {
            if (l == 3) {
                hRect(g, ya, x, (up ? xa : xb) + t, t);
                hRect(g, yb, x, (down ? xa : xb) + t, t);
            } else {
                int end = up && down ? (right ? xb : xa) + t : xb + t;
                hRect(g, hy, x, end, t);
            }
        }
        if (right) {
            if (r == 3) {
                hRect(g, ya, up ? xb : xa, far, t);
                hRect(g, yb, down ? xb : xa, far, t);
            } else {
                int start = up && down ? (left ? xa : xb) : xa;
                hRect(g, hy, start, far, t);
            }
        }
    }

    private static void vRect(Graphics2D g, int x, int y0, int y1, int t) {
        if (y1 > y0) {
            g.fillRect(x, y0, t, y1 - y0);
        }
    }

    private static void hRect(Graphics2D g, int y, int x0, int x1, int t) {
        if (x1 > x0) {
            g.fillRect(x0, y, x1 - x0, t);
        }
    }

    private static void dashes(Graphics2D g, int x, int y, int w, int h, int t, int n,
                               boolean horizontal) {
        int length = horizontal ? w : h;
        float slot = length / (float) n;
        int gap = Math.max(1, Math.round(slot / 3));
        for (int i = 0; i < n; i++) {
            int a = Math.round(i * slot + gap / 2f);
            int b = Math.round((i + 1) * slot - gap / 2f);
            if (b <= a) {
                continue;
            }
            if (horizontal) {
                g.fillRect(x + a, y + (h - t) / 2, b - a, t);
            } else {
                g.fillRect(x + (w - t) / 2, y + a, t, b - a);
            }
        }
    }

    /** ╭ ╮ ╯ ╰: straight to the cell edges, rounded through the centre. */
    private static void arc(Graphics2D g, int cp, int x, int y, int w, int h, int t) {
        float cx = x + (w - t) / 2 + t / 2f;
        float cy = y + (h - t) / 2 + t / 2f;
        float radius = Math.min(w, h) / 2f;
        boolean toRight = cp == 0x256D || cp == 0x2570;
        boolean toBottom = cp == 0x256D || cp == 0x256E;
        float ex = toRight ? x + w : x;
        float ey = toBottom ? y + h : y;
        float sx = toRight ? Math.min(cx + radius, ex) : Math.max(cx - radius, ex);
        float sy = toBottom ? Math.min(cy + radius, ey) : Math.max(cy - radius, ey);
        Path2D.Float path = new Path2D.Float();
        path.moveTo(cx, ey);
        path.lineTo(cx, sy);
        path.quadTo(cx, cy, sx, cy);
        path.lineTo(ex, cy);
        stroke(g, path, t);
    }

    private static void diagonal(Graphics2D g, int cp, int x, int y, int w, int h, int t) {
        if (cp != 0x2572) {
            stroke(g, new Line2D.Float(x + w, y, x, y + h), t);
        }
        if (cp != 0x2571) {
            stroke(g, new Line2D.Float(x, y, x + w, y + h), t);
        }
    }

    private static void stroke(Graphics2D g, java.awt.Shape shape, int t) {
        Object aa = g.getRenderingHint(RenderingHints.KEY_ANTIALIASING);
        java.awt.Stroke old = g.getStroke();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setStroke(new BasicStroke(t, BasicStroke.CAP_BUTT, BasicStroke.JOIN_ROUND));
        g.draw(shape);
        g.setStroke(old);
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, aa);
    }

    private static boolean block(Graphics2D g, int cp, int x, int y, int w, int h, Color color) {
        switch (cp) {
            case 0x2580 -> g.fillRect(x, y, w, h / 2);
            case 0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 -> {
                int eighths = cp - 0x2580;
                int top = y + h - Math.round(h * eighths / 8f);
                g.fillRect(x, top, w, y + h - top);
            }
            case 0x2589, 0x258A, 0x258B, 0x258C, 0x258D, 0x258E, 0x258F -> {
                int eighths = 8 - (cp - 0x2588);
                g.fillRect(x, y, Math.round(w * eighths / 8f), h);
            }
            case 0x2590 -> g.fillRect(x + w / 2, y, w - w / 2, h);
            case 0x2591, 0x2592, 0x2593 -> {
                int alpha = (cp - 0x2590) * 64;
                g.setColor(new Color(color.getRed(), color.getGreen(), color.getBlue(), alpha));
                g.fillRect(x, y, w, h);
                g.setColor(color);
            }
            case 0x2594 -> g.fillRect(x, y, w, Math.max(1, Math.round(h / 8f)));
            case 0x2595 -> {
                int bw = Math.max(1, Math.round(w / 8f));
                g.fillRect(x + w - bw, y, bw, h);
            }
            default -> quadrants(g, cp, x, y, w, h);
        }
        return true;
    }

    /** U+2596–259F: bit 1 upper left, 2 upper right, 4 lower left, 8 lower right. */
    private static final int[] QUADRANTS = {4, 8, 1, 1 | 4 | 8, 1 | 8, 1 | 2 | 4, 1 | 2 | 8, 2, 2 | 4, 2 | 4 | 8};

    private static void quadrants(Graphics2D g, int cp, int x, int y, int w, int h) {
        int bits = QUADRANTS[cp - 0x2596];
        int hw = w / 2;
        int hh = h / 2;
        if ((bits & 1) != 0) {
            g.fillRect(x, y, hw, hh);
        }
        if ((bits & 2) != 0) {
            g.fillRect(x + hw, y, w - hw, hh);
        }
        if ((bits & 4) != 0) {
            g.fillRect(x, y + hh, hw, h - hh);
        }
        if ((bits & 8) != 0) {
            g.fillRect(x + hw, y + hh, w - hw, h - hh);
        }
    }

    /** Powerline: E0B0 solid right-pointing triangle, E0B1 its outline chevron, E0B2/E0B3
     * the left-pointing pair. */
    private static boolean powerline(Graphics2D g, int cp, int x, int y, int w, int h, int t) {
        boolean pointsRight = cp <= 0xE0B1;
        Path2D.Float path = new Path2D.Float();
        float tipX = pointsRight ? x + w : x;
        float baseX = pointsRight ? x : x + w;
        path.moveTo(baseX, y);
        path.lineTo(tipX, y + h / 2f);
        path.lineTo(baseX, y + h);
        if (cp == 0xE0B0 || cp == 0xE0B2) {
            path.closePath();
            Object aa = g.getRenderingHint(RenderingHints.KEY_ANTIALIASING);
            g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g.fill(path);
            g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, aa);
        } else {
            stroke(g, path, t);
        }
        return true;
    }

    private BoxDrawing() {
    }

    /** Braille dot bits (dots 1–8) by column and row: dots 1-2-3-7 down the left, 4-5-6-8
     * down the right. */
    private static final int[][] BRAILLE_BIT = {{0x01, 0x02, 0x04, 0x40}, {0x08, 0x10, 0x20, 0x80}};

    /**
     * The cell as a 2 × 4 grid of equal sub-cells, a round dot centred in each set one.
     * Centres are at exactly a quarter and three quarters of the width and at odd eighths
     * of the height — fractional positions, antialiased — so the dot pitch is the same
     * inside a cell and across its edges. Snapping dots to whole pixels cannot do that
     * when the cell is not a multiple of 2 × 4 pixels (a 17 × 33 device-pixel cell has a
     * pitch of 8.5 × 8.25: gaps would alternate 8 and 9).
     */
    static void braille(Graphics2D g, int dots, int x, int y, int w, int h) {
        if (dots == 0) {
            return;
        }
        double d = Math.max(1, Math.min(w / 2.0, h / 4.0) * 0.7);
        Object aa = g.getRenderingHint(RenderingHints.KEY_ANTIALIASING);
        Object stroke = g.getRenderingHint(RenderingHints.KEY_STROKE_CONTROL);
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
        java.awt.geom.Ellipse2D.Double dot = new java.awt.geom.Ellipse2D.Double();
        for (int column = 0; column < 2; column++) {
            double cx = x + (2 * column + 1) * w / 4.0;
            for (int row = 0; row < 4; row++) {
                if ((dots & BRAILLE_BIT[column][row]) == 0) {
                    continue;
                }
                double cy = y + (2 * row + 1) * h / 8.0;
                dot.setFrame(cx - d / 2, cy - d / 2, d, d);
                g.fill(dot);
            }
        }
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, aa == null ? RenderingHints.VALUE_ANTIALIAS_DEFAULT : aa);
        g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, stroke == null ? RenderingHints.VALUE_STROKE_DEFAULT : stroke);
    }
}
