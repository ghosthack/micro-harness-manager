package io.github.ghosthack.microhm.app.ui;

import javax.swing.BorderFactory;
import javax.swing.JButton;
import javax.swing.JDialog;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.SwingUtilities;
import java.awt.GridBagConstraints;
import java.awt.Window;
import java.io.IOException;
import java.util.concurrent.TimeUnit;

/** Shortcuts to the macOS settings that affect sessions and the Phone page. */
final class MacPermissionsDialog {

    private static final String SETTINGS_SCHEME = "x-apple.systempreferences:";
    private static final String PRIVACY_SETTINGS = "com.apple.settings.PrivacySecurity.extension";
    private static final String NETWORK_SETTINGS = "com.apple.Network-Settings.extension";
    private static final String LEGACY_SECURITY = "com.apple.preference.security";

    private enum Pane {
        FILES("Files & Folders", "Use projects in protected folders such as Desktop or Documents.",
                "Privacy_FilesAndFolders"),
        DISK("Full Disk Access", "Add the app if your workflow needs broader access to protected files.",
                "Privacy_AllFiles"),
        LOCAL_NETWORK("Local Network", "Let a session connect to devices on your local network.",
                "Privacy_LocalNetwork"),
        FIREWALL("Firewall", "Allow incoming connections for the Phone page if the firewall blocks them.",
                "Firewall"),
        AUTOMATION("Automation", "Allow a tool in a session to control specific apps through Apple Events.",
                "Privacy_Automation"),
        ACCESSIBILITY("Accessibility", "Let a UI automation tool interact with other apps.",
                "Privacy_Accessibility"),
        SCREEN_RECORDING("Screen & System Audio Recording", "Allow a tool to capture the Mac screen or system audio.",
                "Privacy_ScreenCapture");

        private final String title;
        private final String description;
        private final String anchor;

        Pane(String title, String description, String anchor) {
            this.title = title;
            this.description = description;
            this.anchor = anchor;
        }

        String title(int macVersion) {
            return this == SCREEN_RECORDING && macVersion < 14 ? "Screen Recording" : title;
        }

        String settingsUrl(int macVersion) {
            String section = macVersion < 13 ? LEGACY_SECURITY
                    : this == FIREWALL ? NETWORK_SETTINGS : PRIVACY_SETTINGS;
            return SETTINGS_SCHEME + section + "?" + anchor;
        }

        String settingsPath(int macVersion) {
            if (this == FIREWALL) {
                return macVersion < 13 ? "Security & Privacy › Firewall › Firewall Options"
                        : "Network › Firewall › Options";
            }
            String section = macVersion < 13 ? "Security & Privacy › Privacy" : "Privacy & Security";
            return section + " › " + title(macVersion);
        }
    }

    /** Returns true only when the user marks this version's review done. */
    static boolean show(Window parent, boolean reviewPending) {
        int macVersion = macMajorVersion();
        String settingsName = macVersion < 13 ? "System Preferences" : "System Settings";
        JDialog dialog = DialogChrome.newDialog(parent, "macOS Permissions");
        DialogChrome.Form form = DialogChrome.form();
        JLabel guidance = new JLabel(html(450, "Grant the access your workflow needs in " + settingsName
                + ". Some entries appear after you use a feature that requests access. "
                + "Use the app named in the macOS prompt."));
        guidance.setBorder(BorderFactory.createEmptyBorder(0, 0, 8, 0));
        addFullWidth(form, guidance);
        JLabel path = new JLabel(html(450, "Some changes take effect after you quit and reopen the app."));
        for (Pane pane : Pane.values()) {
            if (pane == Pane.LOCAL_NETWORK && macVersion < 15) {
                continue;
            }
            String title = pane.title(macVersion);
            JLabel details = new JLabel(html(325, "<b>" + title.replace("&", "&amp;") + "</b><br>" + pane.description));
            JButton open = new JButton("Open Settings");
            open.getAccessibleContext().setAccessibleName("Open " + title + " settings");
            String settingsPath = pane.settingsPath(macVersion);
            open.setToolTipText(settingsPath);
            open.addActionListener(e -> {
                path.setText(html(450, "If needed, choose " + settingsPath.replace("&", "&amp;") + "."));
                openSettings(dialog, pane.settingsUrl(macVersion), settingsName, settingsPath);
            });
            int row = form.reserveRow();
            form.constraints.gridy = row;
            form.constraints.gridx = 0;
            form.constraints.gridwidth = 1;
            form.constraints.weightx = 1;
            form.panel.add(details, form.constraints);
            form.constraints.gridx = 1;
            form.constraints.weightx = 0;
            form.panel.add(open, form.constraints);
        }
        path.setBorder(BorderFactory.createEmptyBorder(7, 0, 0, 0));
        addFullWidth(form, path);

        boolean[] reviewed = {false};
        JButton close = new JButton(reviewPending ? "Later" : "Close");
        close.addActionListener(e -> dialog.dispose());
        JButton done = new JButton("Done");
        done.addActionListener(e -> {
            reviewed[0] = true;
            dialog.dispose();
        });
        DialogChrome.layout(dialog, form.panel,
                reviewPending ? DialogChrome.buttons(close, done) : DialogChrome.buttons(close));
        DialogChrome.show(dialog, parent, reviewPending ? done : close, close);
        return reviewed[0];
    }

    private static void addFullWidth(DialogChrome.Form form, JLabel label) {
        GridBagConstraints constraints = form.constraints;
        constraints.gridy = form.reserveRow();
        constraints.gridx = 0;
        constraints.gridwidth = 2;
        constraints.weightx = 1;
        form.panel.add(label, constraints);
    }

    private static String html(int width, String text) {
        return "<html><body style='width:" + width + "px'>" + text + "</body></html>";
    }

    private static int macMajorVersion() {
        try {
            return Integer.parseInt(System.getProperty("os.version", "").split("\\.", 2)[0]);
        } catch (NumberFormatException e) {
            return Integer.MAX_VALUE; // use current System Settings paths if the version is unavailable
        }
    }

    private static void openSettings(JDialog dialog, String url, String settingsName, String settingsPath) {
        Thread.startVirtualThread(() -> {
            try {
                if (open(url) || open("-b", "com.apple.systempreferences")) {
                    return;
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
            SwingUtilities.invokeLater(() -> {
                if (dialog.isShowing()) {
                    JOptionPane.showMessageDialog(dialog,
                            "Open " + settingsName + " and choose " + settingsPath + ".",
                            "Could not open " + settingsName, JOptionPane.WARNING_MESSAGE);
                }
            });
        });
    }

    private static boolean open(String... arguments) throws InterruptedException {
        String[] command = new String[arguments.length + 1];
        command[0] = "/usr/bin/open";
        System.arraycopy(arguments, 0, command, 1, arguments.length);
        Process process;
        try {
            process = new ProcessBuilder(command)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start();
        } catch (IOException e) {
            return false;
        }
        try {
            return process.waitFor(3, TimeUnit.SECONDS) && process.exitValue() == 0;
        } finally {
            if (process.isAlive()) {
                process.destroyForcibly();
            }
        }
    }

    private MacPermissionsDialog() {
    }
}
