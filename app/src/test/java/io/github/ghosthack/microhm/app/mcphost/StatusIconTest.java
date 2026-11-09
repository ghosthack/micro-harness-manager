package io.github.ghosthack.microhm.app.mcphost;

import org.junit.jupiter.api.Test;

import java.awt.Color;
import java.awt.image.BufferedImage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class StatusIconTest {

    @Test
    void theMenuSaysHowManySessionsRunAndWhereMcpServes() {
        assertEquals("1 session running", StatusIcon.sessionsLabel(1));
        assertEquals("3 sessions running", StatusIcon.sessionsLabel(3));
        assertEquals("MCP serving on 127.0.0.1:47123", StatusIcon.mcpLabel(47123));
        assertEquals("MCP server off", StatusIcon.mcpLabel(-1));
        assertEquals("Microhm — 2 sessions running · MCP :47123", StatusIcon.tooltip(2, 47123));
        assertEquals("Microhm — 1 session running", StatusIcon.tooltip(1, -1));
    }

    @Test
    void theMacGlyphIsDrawnInTheMenuBarTextColourAtDoubleSize() {
        for (Color colour : new Color[]{Color.BLACK, Color.WHITE}) {
            BufferedImage glyph = StatusIcon.image(true, colour == Color.WHITE, 22);
            assertEquals(44, glyph.getWidth());
            int ink = 0;
            for (int y = 0; y < glyph.getHeight(); y++) {
                for (int x = 0; x < glyph.getWidth(); x++) {
                    int argb = glyph.getRGB(x, y);
                    if ((argb >>> 24) > 200) {
                        ink++;
                        assertEquals(colour.getRGB() & 0xFFFFFF, argb & 0xFFFFFF, "monochrome only");
                    }
                }
            }
            assertTrue(ink > 40, "the glyph draws something");
            assertEquals(0, glyph.getRGB(0, 0) >>> 24, "the corners stay transparent");
        }
    }

    @Test
    void otherPlatformsShowTheColourAppIcon() {
        BufferedImage icon = StatusIcon.image(false, false, 16);
        assertEquals(32, icon.getWidth());
        boolean colourful = false;
        for (int y = 0; y < icon.getHeight() && !colourful; y++) {
            for (int x = 0; x < icon.getWidth() && !colourful; x++) {
                int argb = icon.getRGB(x, y);
                int r = (argb >> 16) & 0xFF;
                int g = (argb >> 8) & 0xFF;
                int b = argb & 0xFF;
                colourful = (argb >>> 24) > 200 && Math.max(r, Math.max(g, b)) - Math.min(r, Math.min(g, b)) > 60;
            }
        }
        assertTrue(colourful, "the resistor's tan body and bands, not a monochrome glyph");
        assertFalse(icon.getWidth() < 32);
    }
}
