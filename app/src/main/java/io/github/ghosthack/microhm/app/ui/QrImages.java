package io.github.ghosthack.microhm.app.ui;

import io.nayuki.qrcodegen.QrCode;

import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;

/** QR codes as images, for a phone camera to read off the screen. */
final class QrImages {

    /** Quiet zone around the code, in modules: the standard's minimum. */
    static final int BORDER = 4;

    /**
     * {@code text} as a QR code, {@code scale} pixels per module, black on white whatever
     * the theme: cameras need the contrast and the light border.
     */
    static BufferedImage of(String text, int scale) {
        QrCode qr = QrCode.encodeText(text, QrCode.Ecc.MEDIUM);
        int size = (qr.size + BORDER * 2) * scale;
        BufferedImage image = new BufferedImage(size, size, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = image.createGraphics();
        try {
            g.setColor(Color.WHITE);
            g.fillRect(0, 0, size, size);
            g.setColor(Color.BLACK);
            for (int y = 0; y < qr.size; y++) {
                for (int x = 0; x < qr.size; x++) {
                    if (qr.getModule(x, y)) {
                        g.fillRect((x + BORDER) * scale, (y + BORDER) * scale, scale, scale);
                    }
                }
            }
        } finally {
            g.dispose();
        }
        return image;
    }

    private QrImages() {
    }
}
