package io.github.ghosthack.microhm.app.mcphost;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.imageio.ImageIO;
import java.awt.AWTException;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.EventQueue;
import java.awt.Graphics2D;
import java.awt.GraphicsEnvironment;
import java.awt.Image;
import java.awt.MenuItem;
import java.awt.PopupMenu;
import java.awt.RenderingHints;
import java.awt.SystemTray;
import java.awt.TrayIcon;
import java.awt.geom.Path2D;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.io.InputStream;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

/**
 * The background host's menu-bar (macOS) or system-tray (Windows, Linux) icon: while the
 * app is closed it shows that sessions are running, whether MCP is serving, and offers to
 * open the app or hide itself. Ending sessions stays in the app, whose close flow asks
 * each harness to quit and shows what blocks it. Absent where the platform has no tray
 * (a headless JVM, or a Linux desktop without one).
 */
final class StatusIcon {

    private static final Logger LOG = LoggerFactory.getLogger(StatusIcon.class);

    static final String APP_NAME = "micro-harness-manager";
    private static final String APP_ICON = "/io/github/ghosthack/microhm/app/ui/app-icon.png";

    /** What the menu does; called on the AWT event thread. */
    interface Actions {
        void open();

        void hide();
    }

    private final SystemTray tray;
    private final TrayIcon icon;
    private final MenuItem sessionsItem;
    private final MenuItem mcpItem;
    private final boolean mac;
    private boolean dark;
    private int sessions = -1;
    private int mcpPort = -1;

    private StatusIcon(SystemTray tray, TrayIcon icon, MenuItem sessionsItem, MenuItem mcpItem, boolean mac,
                       boolean dark) {
        this.tray = tray;
        this.icon = icon;
        this.sessionsItem = sessionsItem;
        this.mcpItem = mcpItem;
        this.mac = mac;
        this.dark = dark;
    }

    /** Adds the icon; empty when there is no tray to add it to. */
    static Optional<StatusIcon> show(Actions actions) {
        if (GraphicsEnvironment.isHeadless() || !SystemTray.isSupported()) {
            return Optional.empty();
        }
        try {
            return Optional.of(onEventThread(() -> create(actions)));
        } catch (RuntimeException e) {
            LOG.warn("could not add the tray icon: {}", e.toString());
            return Optional.empty();
        }
    }

    private static StatusIcon create(Actions actions) {
        SystemTray tray = SystemTray.getSystemTray();
        boolean mac = isMac();
        boolean dark = mac && macDarkMenuBar();
        PopupMenu menu = new PopupMenu();
        MenuItem sessionsItem = new MenuItem("");
        sessionsItem.setEnabled(false);
        MenuItem mcpItem = new MenuItem("");
        mcpItem.setEnabled(false);
        MenuItem open = new MenuItem("Open " + APP_NAME);
        open.addActionListener(e -> actions.open());
        MenuItem hide = new MenuItem("Hide This Icon");
        hide.addActionListener(e -> actions.hide());
        menu.add(sessionsItem);
        menu.add(mcpItem);
        menu.addSeparator();
        menu.add(open);
        menu.addSeparator();
        menu.add(hide);

        TrayIcon icon = new TrayIcon(image(mac, dark, tray.getTrayIconSize().height), APP_NAME, menu);
        icon.setImageAutoSize(true);
        icon.addActionListener(e -> actions.open()); // double-click on Windows
        try {
            tray.add(icon);
        } catch (AWTException e) {
            throw new IllegalStateException(e);
        }
        return new StatusIcon(tray, icon, sessionsItem, mcpItem, mac, dark);
    }

    /** Refreshes the menu, the tooltip and (on macOS, after an appearance change) the glyph. */
    void update(int liveSessions, int servingPort, boolean recheckAppearance) {
        boolean nowDark = mac && recheckAppearance ? macDarkMenuBar() : dark;
        EventQueue.invokeLater(() -> {
            if (nowDark != dark) {
                dark = nowDark;
                icon.setImage(image(true, dark, tray.getTrayIconSize().height));
            }
            if (liveSessions != sessions || servingPort != mcpPort) {
                sessions = liveSessions;
                mcpPort = servingPort;
                sessionsItem.setLabel(sessionsLabel(liveSessions));
                mcpItem.setLabel(mcpLabel(servingPort));
                icon.setToolTip(tooltip(liveSessions, servingPort));
            }
        });
    }

    void remove() {
        EventQueue.invokeLater(() -> tray.remove(icon));
    }

    static String sessionsLabel(int sessions) {
        return sessions == 1 ? "1 session running" : sessions + " sessions running";
    }

    static String mcpLabel(int port) {
        return port > 0 ? "MCP serving on 127.0.0.1:" + port : "MCP server off";
    }

    static String tooltip(int sessions, int port) {
        return APP_NAME + " — " + sessionsLabel(sessions) + (port > 0 ? " · MCP :" + port : "");
    }

    /**
     * The icon at {@code size} points: on macOS a monochrome resistor glyph in the menu
     * bar's text colour (AWT cannot mark an image as a template), elsewhere the app icon.
     * Drawn at twice the size for Retina and HiDPI trays; the tray scales it.
     */
    static BufferedImage image(boolean mac, boolean dark, int size) {
        int px = Math.max(16, size) * 2;
        if (!mac) {
            BufferedImage appIcon = appIcon();
            if (appIcon != null) {
                return scaled(appIcon, px);
            }
        }
        return glyph(px, mac && !dark ? Color.BLACK : Color.WHITE);
    }

    /** A schematic resistor on the diagonal: two leads and a zigzag body. */
    static BufferedImage glyph(int px, Color color) {
        BufferedImage image = new BufferedImage(px, px, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        try {
            g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
            g.setColor(color);
            g.setStroke(new BasicStroke(px / 11f, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND));
            double s = px;
            g.rotate(-Math.PI / 4, s / 2, s / 2);
            double y = s / 2;
            double amplitude = s * 0.17;
            double left = s * 0.08;
            double right = s * 0.92;
            double bodyLeft = s * 0.27;
            double bodyRight = s * 0.73;
            Path2D path = new Path2D.Double();
            path.moveTo(left, y);
            path.lineTo(bodyLeft, y);
            int teeth = 6;
            double step = (bodyRight - bodyLeft) / teeth;
            for (int i = 0; i < teeth; i++) {
                double x = bodyLeft + step * (i + 0.5);
                path.lineTo(x, y + (i % 2 == 0 ? -amplitude : amplitude));
            }
            path.lineTo(bodyRight, y);
            path.lineTo(right, y);
            g.draw(path);
        } finally {
            g.dispose();
        }
        return image;
    }

    private static BufferedImage appIcon() {
        try (InputStream in = StatusIcon.class.getResourceAsStream(APP_ICON)) {
            return in == null ? null : ImageIO.read(in);
        } catch (IOException e) {
            return null;
        }
    }

    private static BufferedImage scaled(BufferedImage source, int px) {
        BufferedImage out = new BufferedImage(px, px, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = out.createGraphics();
        try {
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BICUBIC);
            g.drawImage(source.getScaledInstance(px, px, Image.SCALE_SMOOTH), 0, 0, null);
        } finally {
            g.dispose();
        }
        return out;
    }

    private static boolean isMac() {
        return System.getProperty("os.name", "").toLowerCase().startsWith("mac");
    }

    /** {@code defaults read -g AppleInterfaceStyle} prints "Dark" in dark mode and fails in
     * light mode. Asked at start and about once a minute, not per refresh. */
    static boolean macDarkMenuBar() {
        try {
            Process p = new ProcessBuilder("defaults", "read", "-g", "AppleInterfaceStyle")
                    .redirectErrorStream(true).start();
            String out = new String(p.getInputStream().readAllBytes()).trim();
            if (!p.waitFor(2, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                return true;
            }
            return out.equalsIgnoreCase("Dark");
        } catch (IOException e) {
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return true;
        }
    }

    private static <T> T onEventThread(java.util.concurrent.Callable<T> task) {
        if (EventQueue.isDispatchThread()) {
            try {
                return task.call();
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }
        java.util.concurrent.FutureTask<T> future = new java.util.concurrent.FutureTask<>(task);
        EventQueue.invokeLater(future);
        try {
            return future.get();
        } catch (java.util.concurrent.ExecutionException e) {
            throw e.getCause() instanceof RuntimeException r ? r : new IllegalStateException(e.getCause());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(e);
        }
    }
}
