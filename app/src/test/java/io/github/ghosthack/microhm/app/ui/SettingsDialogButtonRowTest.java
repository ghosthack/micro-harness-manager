package io.github.ghosthack.microhm.app.ui;

import org.junit.jupiter.api.Test;

import javax.swing.JButton;
import javax.swing.JPanel;
import java.awt.BorderLayout;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** A button row in a form keeps its buttons at their own width, at the left, however wide
 * the field column is (a lone button used to stretch across it: "Regenerate token"). */
final class SettingsDialogButtonRowTest {

    @Test
    void aLoneButtonKeepsItsWidthInTheSettingsForm() {
        JButton bare = new JButton("Regenerate token");
        JButton inRow = new JButton("Regenerate token");
        DialogChrome.Form form = DialogChrome.form();
        form.addRow("Bare:", bare);
        form.addRow("MCP token:", SettingsDialog.buttonRow(inRow));
        form.panel.setSize(900, 120);
        layOut(form.panel);
        assertTrue(bare.getWidth() > 2 * bare.getPreferredSize().width, "the form stretches a bare button");
        assertEquals(inRow.getPreferredSize().width, inRow.getWidth());
        assertEquals(0, inRow.getX());
    }

    @Test
    void buttonsSitSideBySideEightPixelsApart() {
        JButton first = new JButton("Copy phone link");
        JButton second = new JButton("Show QR code");
        JPanel field = new JPanel(new BorderLayout());
        field.add(SettingsDialog.buttonRow(first, second));
        field.setSize(900, 40);
        layOut(field);
        assertEquals(first.getPreferredSize().width, first.getWidth());
        assertEquals(second.getPreferredSize().width, second.getWidth());
        assertEquals(first.getX() + first.getWidth() + 8, second.getX());
    }

    private static void layOut(java.awt.Container container) {
        container.doLayout();
        for (java.awt.Component child : container.getComponents()) {
            if (child instanceof java.awt.Container c) {
                layOut(c);
            }
        }
    }
}
