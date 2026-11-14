package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.perf.AotCache;
import io.github.ghosthack.microhm.app.perf.PerfStats;

import javax.swing.JButton;
import javax.swing.JLabel;
import javax.swing.JPanel;
import java.awt.FlowLayout;
import java.awt.Toolkit;
import java.awt.datatransfer.StringSelection;
import java.awt.event.HierarchyEvent;
import java.util.ArrayList;
import java.util.List;

/**
 * The Performance section of Settings: read-only figures about this run of the app (see
 * {@link PerfStats}), read afresh each time the section is shown and on Refresh, with Copy
 * for bug reports. Nothing here is a setting, so Save has nothing to apply from it.
 */
final class PerformancePage {

    static DialogChrome.Form form() {
        DialogChrome.Form form = DialogChrome.form();
        List<JLabel> values = new ArrayList<>();
        for (PerfStats.Row row : PerfStats.snapshot()) {
            JLabel value = new JLabel(row.value());
            values.add(value);
            form.addRow(row.label() + ":", value);
        }
        AotCache.current().path().ifPresent(path -> values.get(1).setToolTipText(path.toString()));

        Runnable refresh = () -> {
            List<PerfStats.Row> fresh = PerfStats.snapshot();
            for (int i = 0; i < Math.min(fresh.size(), values.size()); i++) {
                values.get(i).setText(fresh.get(i).value());
            }
        };
        JButton refreshButton = new JButton("Refresh");
        refreshButton.addActionListener(e -> refresh.run());
        JButton copy = new JButton("Copy");
        copy.setToolTipText("Copy these figures as text, for a bug report");
        copy.addActionListener(e -> Toolkit.getDefaultToolkit().getSystemClipboard()
                .setContents(new StringSelection(PerfStats.asText(PerfStats.snapshot())), null));
        // the buttons keep their own width, under the values
        JPanel buttons = new JPanel(new FlowLayout(FlowLayout.LEFT, 0, 0));
        buttons.setOpaque(false);
        buttons.add(refreshButton);
        buttons.add(javax.swing.Box.createHorizontalStrut(8));
        buttons.add(copy);
        form.addRow("", SettingsDialog.note("Figures for this run of the app. Nothing here is a setting."));
        form.addRow("", buttons);

        // the figures move: show current ones whenever the section comes up
        form.panel.addHierarchyListener(e -> {
            if ((e.getChangeFlags() & HierarchyEvent.SHOWING_CHANGED) != 0 && form.panel.isShowing()) {
                refresh.run();
            }
        });
        return form;
    }

    private PerformancePage() {
    }
}
