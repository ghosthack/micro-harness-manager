package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.perf.AotCache;
import io.github.ghosthack.microhm.app.perf.PerfStats;

import javax.swing.JButton;
import javax.swing.JDialog;
import javax.swing.JLabel;
import javax.swing.JPanel;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.datatransfer.StringSelection;
import java.util.List;

/** Read-only figures about this run of the app (see {@link PerfStats}), from Settings. */
final class PerformanceDialog {

    static void show(Window parent) {
        JDialog dialog = DialogChrome.newDialog(parent, "Performance");
        DialogChrome.Form form = DialogChrome.form();
        List<JLabel> values = new java.util.ArrayList<>();
        List<PerfStats.Row> rows = PerfStats.snapshot();
        for (PerfStats.Row row : rows) {
            JLabel value = new JLabel(row.value());
            values.add(value);
            form.addRow(row.label() + ":", value);
        }
        AotCache.current().path().ifPresent(path -> values.get(1).setToolTipText(path.toString()));

        JButton refresh = new JButton("Refresh");
        JButton copy = new JButton("Copy");
        JButton close = new JButton("Close");
        refresh.addActionListener(e -> {
            List<PerfStats.Row> fresh = PerfStats.snapshot();
            for (int i = 0; i < Math.min(fresh.size(), values.size()); i++) {
                values.get(i).setText(fresh.get(i).value());
            }
            dialog.pack();
        });
        copy.addActionListener(e -> Toolkit.getDefaultToolkit().getSystemClipboard()
                .setContents(new StringSelection(PerfStats.asText(PerfStats.snapshot())), null));
        close.addActionListener(e -> dialog.dispose());
        JPanel buttons = DialogChrome.buttons(refresh, copy, close);
        DialogChrome.layout(dialog, form.panel, buttons);
        DialogChrome.show(dialog, parent, close, close);
    }

    private PerformanceDialog() {
    }
}
