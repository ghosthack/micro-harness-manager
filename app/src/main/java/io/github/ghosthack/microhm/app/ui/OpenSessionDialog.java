package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.harness.HarnessType;

import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JDialog;
import javax.swing.JFileChooser;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.JTextField;
import javax.swing.SwingConstants;
import java.awt.Window;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;

/**
 * "Open…" dialog: project path (with Browse…), harness dropdown, optional harness
 * session id (blank = start fresh).
 */
final class OpenSessionDialog {

    record Result(Path projectPath, HarnessType harnessType, Optional<String> harnessSessionId) {
    }

    static Optional<Result> show(Window parent) {
        return show(parent, null, null);
    }

    /**
     * As {@link #show(Window)}, but seeded: a non-null {@code prefillPath}
     * replaces the home-directory default, and a non-null {@code prefillHarness}
     * preselects the dropdown — the toolbar's open-here button hands over the selected
     * session's pair.
     */
    static Optional<Result> show(Window parent, String prefillPath, HarnessType prefillHarness) {
        JDialog dialog = DialogChrome.newDialog(parent, "New session");
        DialogChrome.Form form = DialogChrome.form();

        Path defaultFolder = Path.of(System.getProperty("user.home"));
        JTextField pathField = new JTextField(
                prefillPath != null ? prefillPath : defaultFolder.toString(), 30);
        JButton browse = new JButton("Browse…");
        browse.addActionListener(e -> {
            JFileChooser chooser = new JFileChooser(
                    pathField.getText().isBlank() ? defaultFolder.toFile()
                            : UserPath.expand(pathField.getText()).toFile());
            chooser.setFileSelectionMode(JFileChooser.DIRECTORIES_ONLY);
            if (chooser.showOpenDialog(dialog) == JFileChooser.APPROVE_OPTION) {
                pathField.setText(chooser.getSelectedFile().getAbsolutePath());
            }
        });

        JComboBox<HarnessType> harnessCombo = new JComboBox<>(HarnessType.values());
        harnessCombo.setRenderer(HarnessIcons.comboRenderer());
        if (prefillHarness != null) {
            harnessCombo.setSelectedItem(prefillHarness);
        }

        JTextField sessionIdField = new JTextField(20);

        form.addRow("Project path:", pathField, browse);
        form.addRow("Harness:", harnessCombo);
        form.addRow("Resume session id (optional):", sessionIdField);

        JLabel hint = new JLabel(
                "Blank session id starts a fresh harness conversation; 'shell' is just your default shell.");
        hint.setHorizontalAlignment(SwingConstants.LEFT);
        form.constraints.gridx = 0;
        form.constraints.gridy = form.reserveRow();
        form.constraints.gridwidth = 3;
        form.panel.add(hint, form.constraints);

        AtomicReference<Optional<Result>> resultHolder = new AtomicReference<>(Optional.empty());
        JButton ok = new JButton("New");
        ok.setIcon(LucidIcon.folderPlus(16));
        JButton cancel = new JButton("Cancel");
        ok.addActionListener(e -> {
            String text = pathField.getText().strip();
            if (text.isEmpty()) {
                JOptionPane.showMessageDialog(dialog, "Project path is required.",
                        "Missing path", JOptionPane.WARNING_MESSAGE);
                return;
            }
            Path path = UserPath.expand(text);
            if (!Files.isDirectory(path)) {
                JOptionPane.showMessageDialog(dialog, "'" + path + "' is not a directory.",
                        "Invalid path", JOptionPane.WARNING_MESSAGE);
                return;
            }
            HarnessType type = (HarnessType) harnessCombo.getSelectedItem();
            String id = sessionIdField.getText().strip();
            resultHolder.set(Optional.of(new Result(path, type,
                    id.isEmpty() ? Optional.empty() : Optional.of(id))));
            dialog.dispose();
        });
        cancel.addActionListener(e -> dialog.dispose());

        DialogChrome.layout(dialog, form.panel, DialogChrome.buttons(ok, cancel));
        DialogChrome.show(dialog, parent, ok, cancel);
        return resultHolder.get();
    }

    private OpenSessionDialog() {
    }
}
