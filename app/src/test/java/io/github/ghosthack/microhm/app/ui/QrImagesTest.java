package io.github.ghosthack.microhm.app.ui;

import io.nayuki.qrcodegen.QrCode;
import org.junit.jupiter.api.Test;

import java.awt.image.BufferedImage;

import static org.junit.jupiter.api.Assertions.assertEquals;

class QrImagesTest {

    @Test
    void drawsEachModuleScaledInsideAWhiteBorder() {
        String link = "http://192.168.1.2:7393/#k=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG";
        QrCode qr = QrCode.encodeText(link, QrCode.Ecc.MEDIUM);
        BufferedImage image = QrImages.of(link, 3);
        assertEquals((qr.size + 2 * QrImages.BORDER) * 3, image.getWidth());
        assertEquals(0xFFFFFF, image.getRGB(1, 1) & 0xFFFFFF, "border is white");
        for (int y = 0; y < qr.size; y++) {
            for (int x = 0; x < qr.size; x++) {
                int rgb = image.getRGB((x + QrImages.BORDER) * 3 + 1, (y + QrImages.BORDER) * 3 + 1) & 0xFFFFFF;
                assertEquals(qr.getModule(x, y) ? 0x000000 : 0xFFFFFF, rgb, "module " + x + "," + y);
            }
        }
    }
}
