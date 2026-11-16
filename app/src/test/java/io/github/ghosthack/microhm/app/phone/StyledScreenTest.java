package io.github.ghosthack.microhm.app.phone;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

final class StyledScreenTest {

    /** Slot i is 0x0000ii, so a colour names its slot; 0 is black, 15 white. */
    private static final int[] PALETTE = new int[16];

    static {
        for (int i = 0; i < 16; i++) {
            PALETTE[i] = i;
        }
        PALETTE[15] = 0xFFFFFF;
    }

    private final StyledScreen screen = new StyledScreen(PALETTE);

    @Test
    void runsCarryColoursAndStylesAndInverseSwaps() {
        JsonNode out = screen.render("\u001b[1;31mred\u001b[0m plain \u001b[7minv\u001b[0m", 30, 2);
        assertEquals("#ffffff", out.path("fg").asText());
        assertEquals("#000000", out.path("bg").asText());
        JsonNode row = out.path("rows").path(0);
        assertEquals(3, row.size(), row.toString());
        assertEquals("red", row.path(0).path("t").asText());
        assertEquals("#000001", row.path(0).path("f").asText());
        assertEquals(StyledScreen.BOLD, row.path(0).path("s").asInt());
        assertEquals(" plain ", row.path(1).path("t").asText());
        assertFalse(row.path(1).has("f"), "default colours are left to the page");
        assertEquals("inv", row.path(2).path("t").asText());
        assertEquals("#000000", row.path(2).path("f").asText());
        assertEquals("#ffffff", row.path(2).path("b").asText());
    }

    @Test
    void keepsBlockArtAndTrueColourAndDropsTrailingBlanks() {
        JsonNode out = screen.render("\u001b[38;2;215;119;87m▐▛███▜▌\u001b[0m   ", 20, 1);
        JsonNode row = out.path("rows").path(0);
        assertEquals(1, row.size(), row.toString());
        assertEquals("▐▛███▜▌", row.path(0).path("t").asText());
        assertEquals("#d77757", row.path(0).path("f").asText());
    }

    @Test
    void aBackgroundRunKeepsItsSpaces() {
        JsonNode row = screen.render("\u001b[44m  \u001b[0m", 10, 1).path("rows").path(0);
        assertEquals("  ", row.path(0).path("t").asText());
        assertEquals("#000004", row.path(0).path("b").asText());
    }

    @Test
    void underlinesCarryTheirKind() {
        JsonNode row = screen.render("\u001b[4ma\u001b[21mb\u001b[4:3mc\u001b[4:4md\u001b[4:5me", 10, 1)
                .path("rows").path(0);
        assertEquals(StyledScreen.UNDERLINE, row.path(0).path("s").asInt());
        assertEquals(StyledScreen.UNDERLINE | StyledScreen.DOUBLE, row.path(1).path("s").asInt());
        assertEquals(StyledScreen.UNDERLINE | StyledScreen.CURLY, row.path(2).path("s").asInt());
        assertEquals(StyledScreen.UNDERLINE | StyledScreen.DOTTED, row.path(3).path("s").asInt());
        assertEquals(StyledScreen.UNDERLINE | StyledScreen.DASHED, row.path(4).path("s").asInt());
    }
}
