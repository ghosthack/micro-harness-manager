package io.github.ghosthack.microhm.vt;

import java.util.Random;

/**
 * Seeded generator of mixed text / CSI / SGR / scroll-region / alternate-screen operations
 * for the golden and round-trip fuzz tests. It reads the in-house emulator's state between
 * operations so that, in {@link Mode#COMMON} mode, it avoids exactly the situations where
 * jediterm-core (the reference the goldens were checked against) behaves differently (each listed in {@link KnownDifferencesTest}):
 * relative moves, line feeds and erases while a wrap is pending; ESC 8 / CSI ?1049 l to a
 * cursor outside the region in origin mode; CUU/CUD with margins outside
 * origin mode; VPA, CHA, HPA, CNL and CPL in origin mode; ED 1; IND/RI leaving the screen outside the region; text past
 * the margin with autowrap off; SO; ESC 7/8 on the alternate screen; ED 3; DECALN; REP, CHT,
 * CBT, CSI s/u, IRM; a tab over blank cells with a background; ICH/DCH/EL/ED with a
 * coloured pen; ESC 8, a tab or bracketed paste after RIS without re-syncing them; combining marks and supplementary characters. {@link Mode#ANY} drops those restrictions (for the round trip,
 * where only the emulator is involved).
 */
final class VtFuzz {

    enum Mode { COMMON, ANY }

    private static final String ESC = "\u001b";
    private static final String CSI = ESC + "[";
    private static final String NARROW =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:-+=*/#!?()[]{}<>|'\"%&@$^~`";
    private static final String[] EXTRA_NARROW = {"é", "ü", "ñ", "ß", "─", "│", "┌", "λ", "Ж", "€", "«", "»"};
    private static final String[] WIDE = {"中", "文", "字", "日", "本", "語", "한", "가", "Ｗ", "⌚"};
    private static final String[] SUPPLEMENTARY = {"🛑", "🚀", "😀", "👍🏽", "🇺🇸", "👩\u200d💻", "𝐀"};
    private static final String[] COMBINING = {"e\u0301", "a\u0308", "n\u0303", "x\u0301\u0302", "\u200d", "\ufe0f"};

    private final Random rnd;
    private final TerminalEmulator state;
    private final Mode mode;

    VtFuzz(long seed, TerminalEmulator state, Mode mode) {
        this.rnd = new Random(seed);
        this.state = state;
        this.mode = mode;
    }

    /** The next operation's bytes, chosen for the emulator's current state. */
    String next() {
        while (true) {
            String op = tryNext();
            if (op != null) {
                return op;
            }
        }
    }

    private boolean common() {
        return mode == Mode.COMMON;
    }

    private boolean regionActive() {
        return state.scrollTop() != 0 || state.scrollBottom() != state.rows() - 1;
    }

    /** "\r" when a wrap is pending and the next operation is one jediterm treats differently. */
    private String settle() {
        return common() && state.cursorPendingWrap() ? "\r" : "";
    }

    private String tryNext() {
        int rows = state.rows();
        int cols = state.columns();
        int pick = rnd.nextInt(100);
        if (pick < 30) {
            return text();
        }
        if (pick < 38) {
            return sgr();
        }
        if (pick < 44) {
            return rnd.nextBoolean() ? "\r\n" : settle() + "\n";
        }
        if (pick < 50) {
            return CSI + (1 + rnd.nextInt(rows + 2)) + ";" + (1 + rnd.nextInt(cols + 2)) + "H";
        }
        if (pick < 54) {
            if (common() && state.originMode()) {
                return null; // jediterm's CHA re-applies the origin offset to the row
            }
            return CSI + (1 + rnd.nextInt(cols)) + (rnd.nextBoolean() ? "G" : "`");
        }
        if (pick < 58) {
            if (common() && state.originMode()) {
                return null;
            }
            return settle() + CSI + (1 + rnd.nextInt(rows)) + "d";
        }
        if (pick < 62) {
            String f = "ABCDEF".substring(rnd.nextInt(6)).substring(0, 1);
            boolean vertical = !f.equals("C") && !f.equals("D");
            if (common() && vertical && regionActive() && !state.originMode()) {
                return null;
            }
            if (common() && (f.equals("E") || f.equals("F")) && state.originMode()) {
                return null; // CNL/CPL end in jediterm's CHA, which re-applies the origin offset
            }
            return settle() + CSI + (rnd.nextInt(4) == 0 ? "" : String.valueOf(rnd.nextInt(cols))) + f;
        }
        if (pick < 64) {
            if (common() && (state.cursorPendingWrap() || state.cursorColumn() == 0)) {
                return null;
            }
            return "\b";
        }
        if (pick < 66) {
            if (common() && colouredBlankBeforeTab()) {
                return null; // jediterm's tab overwrites blank cells with spaces in the pen
            }
            return settle() + (common() ? CSI + "0m" : "") + "\t";
        }
        if (pick < 70) {
            return settle() + plainBackground() + CSI + rnd.nextInt(3) + "K";
        }
        if (pick < 72) {
            // ED 1: jediterm also clears the rest of the cursor row (an off-by-one).
            return settle() + plainBackground() + CSI + (common() ? 2 * rnd.nextInt(2) : rnd.nextInt(3)) + "J";
        }
        if (pick < 75) {
            String f = "@PX".substring(rnd.nextInt(3)).substring(0, 1);
            // jediterm fills ICH/DCH blanks at the end of the written text, not the margin.
            String pen = common() && !f.equals("X") ? CSI + "49m" : "";
            return settle() + pen + CSI + (1 + rnd.nextInt(cols / 2)) + f;
        }
        if (pick < 78) {
            int y = state.cursorRow();
            if (common() && (y < state.scrollTop() || y > state.scrollBottom())) {
                return null;
            }
            return CSI + (1 + rnd.nextInt(3)) + (rnd.nextBoolean() ? "L" : "M") + "\r";
        }
        if (pick < 80) {
            return CSI + (1 + rnd.nextInt(3)) + (rnd.nextBoolean() ? "S" : "T");
        }
        if (pick < 83) {
            if (rnd.nextInt(3) == 0) {
                return CSI + "r";
            }
            int top = 1 + rnd.nextInt(rows - 1);
            int bottom = top + 1 + rnd.nextInt(rows - top);
            return CSI + top + ";" + bottom + "r";
        }
        if (pick < 86) {
            int y = state.cursorRow();
            return switch (rnd.nextInt(3)) {
                case 0 -> common() && y == rows - 1 && state.scrollBottom() != rows - 1 ? null : settle() + ESC + "D";
                case 1 -> common() && y == rows - 1 && state.scrollBottom() != rows - 1 ? null : settle() + ESC + "E";
                default -> common() && y == 0 && state.scrollTop() != 0 ? null : settle() + ESC + "M";
            };
        }
        if (pick < 88) {
            if (common() && state.alternateScreen()) {
                return null;
            }
            if (rnd.nextBoolean()) {
                return ESC + "7";
            }
            return restoreDiffers() ? null : ESC + "8";
        }
        if (pick < 90) {
            if (state.alternateScreen()) {
                return restoreDiffers() ? null : CSI + "?1049l";
            }
            return common() ? CSI + "?1049h" : CSI + "?" + (rnd.nextBoolean() ? "1049" : "47") + "h";
        }
        if (pick < 95) {
            return mode();
        }
        if (pick < 97) {
            return switch (rnd.nextInt(4)) {
                case 0 -> ESC + "]2;title " + rnd.nextInt(100) + "\u0007";
                case 1 -> ESC + "]0;icon+title\u001b\\";
                case 2 -> ESC + "]8;;https://example.test/" + rnd.nextInt(9) + "\u001b\\" + fitting("link")
                        + ESC + "]8;;\u001b\\";
                default -> ESC + "P1$r0m" + ESC + "\\";
            };
        }
        if (pick < 98) {
            return rnd.nextBoolean() ? ESC + "(0" + fitting("lqqkxjmn") + ESC + "(B" : ESC + "H";
        }
        if (pick < 99) {
            return CSI + (rnd.nextBoolean() ? "0" : "3") + "g";
        }
        if (rnd.nextInt(4) == 0) {
            // jediterm's RIS keeps its DECSC slot, its tab stops and bracketed paste; re-sync.
            return ESC + "c" + (common() ? ESC + "7" + CSI + "?2004l" + defaultTabStops() : "");
        }
        return CSI + rnd.nextInt(7) + " q";
    }

    /** Whether restoring the main screen's saved cursor (ESC 8, CSI ?1049 l) would clamp it
     * into the region: xterm confines it in origin mode, jediterm does not. */
    private boolean restoreDiffers() {
        TerminalEmulator.SavedCursor saved = state.savedCursor(false);
        return common() && saved != null && saved.originMode()
                && (saved.row() < state.scrollTop() || saved.row() > state.scrollBottom());
    }

    /** ASCII {@code text} written where jediterm agrees: with autowrap off it must fit
     * before the margin (jediterm wraps to column 0 of the same row instead). */
    private String fitting(String text) {
        if (common() && !state.autoWrap()
                && (state.cursorPendingWrap() || state.cursorColumn() + text.length() > state.columns())) {
            return "\r" + text.substring(0, Math.min(text.length(), state.columns()));
        }
        return text;
    }

    private String defaultTabStops() {
        StringBuilder sb = new StringBuilder(CSI + "3g");
        for (int x = 8; x < state.columns(); x += 8) {
            sb.append(CSI).append("1;").append(x + 1).append('H').append(ESC).append('H');
        }
        return sb.append(CSI).append('H').toString();
    }

    /** Whether a blank cell with a background lies between the cursor and the next tab stop. */
    private boolean colouredBlankBeforeTab() {
        Line line = state.line(state.cursorRow());
        for (int x = state.cursorColumn(); x < state.columns(); x++) {
            if (x > state.cursorColumn() && state.isTabStop(x)) {
                break;
            }
            if (Style.background(line.style(x)) != Style.COLOR_DEFAULT) {
                return true;
            }
        }
        return false;
    }

    /** jediterm's EL erases only up to the written text, so a coloured erase would differ
     * past it (and a later tab would then write default spaces there). */
    private String plainBackground() {
        return common() ? CSI + "49m" : "";
    }

    private String mode() {
        int[] modes = {1, 6, 7, 25, 1000, 1002, 1003, 1004, 1006, 2004};
        int m = modes[rnd.nextInt(modes.length)];
        boolean set = rnd.nextBoolean();
        String s = CSI + "?" + m + (set ? "h" : "l");
        if (m == 6 && common()) {
            s += CSI + "H"; // jediterm does not home on DECOM
        }
        if (rnd.nextInt(5) == 0) {
            s += rnd.nextBoolean() ? ESC + "=" : ESC + ">";
        }
        if (!common() && rnd.nextInt(4) == 0) {
            s += switch (rnd.nextInt(5)) {
                case 0 -> CSI + "4" + (set ? "h" : "l");
                case 1 -> CSI + "3b";
                case 2 -> CSI + "2I" + CSI + "Z";
                case 3 -> CSI + "s" + CSI + "u";
                default -> "\u000e" + ESC + ")0" + "q" + "\u000f";
            };
        }
        return s;
    }

    private String sgr() {
        StringBuilder sb = new StringBuilder(CSI);
        int n = 1 + rnd.nextInt(3);
        for (int i = 0; i < n; i++) {
            if (i > 0) {
                sb.append(';');
            }
            switch (rnd.nextInt(10)) {
                case 0 -> sb.append("38;5;").append(rnd.nextInt(256));
                case 1 -> sb.append("48;5;").append(rnd.nextInt(256));
                case 2 -> sb.append("38;2;").append(rnd.nextInt(256)).append(';').append(rnd.nextInt(256))
                        .append(';').append(rnd.nextInt(256));
                case 3 -> sb.append(rnd.nextBoolean() ? "48:2::" : "38:2::").append(rnd.nextInt(256)).append(':')
                        .append(rnd.nextInt(256)).append(':').append(rnd.nextInt(256));
                case 4 -> sb.append(30 + rnd.nextInt(8));
                case 5 -> sb.append(40 + rnd.nextInt(8));
                case 6 -> sb.append(rnd.nextBoolean() ? 90 + rnd.nextInt(8) : 100 + rnd.nextInt(8));
                case 7 -> {
                    int[] attrs = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 22, 23, 24, 25, 27, 28, 29, 39, 49, 53};
                    sb.append(attrs[rnd.nextInt(attrs.length)]);
                }
                case 8 -> sb.append("4:").append(rnd.nextInt(6));
                default -> sb.append('0');
            }
        }
        return sb.append('m').toString();
    }

    private String text() {
        int cols = state.columns();
        StringBuilder sb = new StringBuilder();
        int x = state.cursorColumn();
        boolean pending = state.cursorPendingWrap();
        int limit = Integer.MAX_VALUE;
        if (common() && !state.autoWrap()) {
            if (pending) {
                sb.append('\r');
                x = 0;
                pending = false;
            }
            limit = cols - x;
        }
        int len = 1 + rnd.nextInt(rnd.nextInt(10) == 0 ? 3 * cols : 24);
        int used = 0;
        for (int i = 0; i < len; i++) {
            String piece;
            int width;
            int r = rnd.nextInt(100);
            if (r < 80) {
                piece = String.valueOf(NARROW.charAt(rnd.nextInt(NARROW.length())));
                width = 1;
            } else if (r < 88) {
                piece = EXTRA_NARROW[rnd.nextInt(EXTRA_NARROW.length)];
                width = 1;
            } else if (r < 96) {
                piece = WIDE[rnd.nextInt(WIDE.length)];
                width = 2;
            } else if (!common()) {
                piece = r < 98 ? SUPPLEMENTARY[rnd.nextInt(SUPPLEMENTARY.length)] : COMBINING[rnd.nextInt(COMBINING.length)];
                width = 2;
            } else {
                piece = String.valueOf(NARROW.charAt(rnd.nextInt(NARROW.length())));
                width = 1;
            }
            if (used + width > limit) {
                break;
            }
            sb.append(piece);
            used += width;
            x = pending ? width : x + width;
            pending = false;
            if (x >= cols) {
                x = cols - 1;
                pending = true;
            }
        }
        return sb.toString();
    }
}
