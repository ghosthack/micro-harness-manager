package io.github.ghosthack.microhm.app.phone;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.github.ghosthack.microhm.vt.HeadlessTerminal;
import io.github.ghosthack.microhm.vt.Line;
import io.github.ghosthack.microhm.vt.Style;
import io.github.ghosthack.microhm.vt.TerminalEmulator;
import io.github.ghosthack.microhm.vt.VtTokenizer;

import java.nio.charset.StandardCharsets;
import java.util.Objects;

/**
 * A session's screen with its colours, for the phone page: the daemon's styled capture
 * (the attach redraw stream) replayed into the project's own emulator, then each row as runs
 * of text sharing a style. Colours resolve through the app's ANSI palette on a dark terminal,
 * as the window draws them; the defaults come separately, so the page paints its background
 * to match.
 *
 * <p>Wire shape: {@code {fg, bg, rows: [[run…]…]}}; a run is {@code {t, f?, b?, s?}}: its
 * text, its colours as {@code #rrggbb} (absent: the defaults) and its style bits
 * ({@link #BOLD}, {@link #DIM}, {@link #ITALIC}, {@link #UNDERLINE}, {@link #STRIKE}). Inverse
 * and invisible are resolved here. Trailing blank cells on the default background are left out.
 */
public final class StyledScreen {

    static final int BOLD = 1;
    static final int DIM = 2;
    static final int ITALIC = 4;
    static final int UNDERLINE = 8;
    static final int STRIKE = 16;

    private static final int[] CUBE = new int[256];

    static {
        for (int i = 16; i < 256; i++) {
            CUBE[i] = Style.xterm256Rgb(i);
        }
    }

    private final int[] ansi;
    private final int defaultForeground;
    private final int defaultBackground;

    /** @param palette the 16 ANSI colours as {@code 0xRRGGBB} */
    public StyledScreen(int[] palette) {
        Objects.requireNonNull(palette, "palette");
        if (palette.length < 16) {
            throw new IllegalArgumentException("16 colours expected");
        }
        this.ansi = palette.clone();
        this.defaultBackground = ansi[0];
        this.defaultForeground = ansi[15];
    }

    /** {@code redraw} (a styled capture) drawn on a {@code columns}×{@code rows} screen. */
    public ObjectNode render(String redraw, int columns, int rows) {
        JsonNodeFactory f = JsonNodeFactory.instance;
        ObjectNode out = f.objectNode().put("fg", hex(defaultForeground)).put("bg", hex(defaultBackground));
        ArrayNode lines = out.putArray("rows");
        try (HeadlessTerminal terminal = new HeadlessTerminal(Math.max(1, columns), Math.max(1, rows), 0, bytes -> { })) {
            byte[] bytes = redraw.getBytes(StandardCharsets.UTF_8);
            VtTokenizer tokenizer = new VtTokenizer();
            terminal.apply(tokenizer.feed(bytes, 0, bytes.length).tokens());
            terminal.apply(tokenizer.flush().tokens());
            TerminalEmulator emulator = terminal.emulator();
            emulator.lock().lock();
            try {
                for (int y = 0; y < emulator.rows(); y++) {
                    lines.add(row(emulator.line(y), f));
                }
            } finally {
                emulator.lock().unlock();
            }
        }
        return out;
    }

    private ArrayNode row(Line line, JsonNodeFactory f) {
        ArrayNode runs = f.arrayNode();
        int end = line.columns();
        // leave out trailing blanks on the default background
        while (end > 0 && (line.isEmpty(end - 1) || line.codePoint(end - 1) == ' ')
                && Style.background(line.style(end - 1)) == Style.COLOR_DEFAULT
                && !Style.inverse(line.style(end - 1))) {
            end--;
        }
        StringBuilder text = new StringBuilder();
        String runFg = null;
        String runBg = null;
        int runStyle = 0;
        boolean open = false;
        for (int x = 0; x < end; x++) {
            if (line.isWideTail(x)) {
                continue;
            }
            long style = line.style(x);
            int fg = rgb(Style.foreground(style), true);
            int bg = rgb(Style.background(style), false);
            boolean defaultFg = Style.foreground(style) == Style.COLOR_DEFAULT;
            boolean defaultBg = Style.background(style) == Style.COLOR_DEFAULT;
            if (Style.inverse(style)) {
                int swap = fg;
                fg = bg;
                bg = swap;
                boolean swapDefault = defaultFg;
                defaultFg = defaultBg;
                defaultBg = swapDefault;
            }
            if (Style.invisible(style)) {
                fg = bg;
                defaultFg = defaultBg && defaultFg;
            }
            String cellFg = defaultFg && !Style.inverse(style) ? null : hex(fg);
            String cellBg = defaultBg && !Style.inverse(style) ? null : hex(bg);
            int bits = (Style.bold(style) ? BOLD : 0) | (Style.dim(style) ? DIM : 0)
                    | (Style.italic(style) ? ITALIC : 0)
                    | (Style.underline(style) != Style.UNDERLINE_NONE ? UNDERLINE : 0)
                    | (Style.strikethrough(style) ? STRIKE : 0);
            if (open && (!Objects.equals(cellFg, runFg) || !Objects.equals(cellBg, runBg) || bits != runStyle)) {
                runs.add(run(f, text, runFg, runBg, runStyle));
                text.setLength(0);
            }
            runFg = cellFg;
            runBg = cellBg;
            runStyle = bits;
            open = true;
            if (line.isEmpty(x)) {
                text.append(' ');
            } else {
                line.appendText(x, text);
            }
        }
        if (open) {
            runs.add(run(f, text, runFg, runBg, runStyle));
        }
        return runs;
    }

    private static ObjectNode run(JsonNodeFactory f, CharSequence text, String fg, String bg, int style) {
        ObjectNode run = f.objectNode().put("t", text.toString());
        if (fg != null) {
            run.put("f", fg);
        }
        if (bg != null) {
            run.put("b", bg);
        }
        if (style != 0) {
            run.put("s", style);
        }
        return run;
    }

    /** {@code 0xRRGGBB} of an emulator colour, as the window resolves it on a dark terminal. */
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

    static String hex(int rgb) {
        return String.format("#%06x", rgb & 0xFFFFFF);
    }
}
