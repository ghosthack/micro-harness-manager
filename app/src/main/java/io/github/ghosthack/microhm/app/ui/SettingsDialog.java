package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.session.SessionShell;
import io.github.ghosthack.microhm.app.settings.AppSettings;

import javax.swing.BorderFactory;
import javax.swing.DefaultListCellRenderer;
import javax.swing.JButton;
import javax.swing.JComponent;
import javax.swing.JCheckBox;
import javax.swing.JComboBox;
import javax.swing.JDialog;
import javax.swing.JFileChooser;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.ListSelectionModel;
import javax.swing.JSpinner;
import javax.swing.SpinnerNumberModel;
import javax.swing.UIManager;
import java.awt.BorderLayout;
import java.awt.CardLayout;
import java.awt.Component;
import java.awt.Dimension;
import java.awt.GraphicsEnvironment;
import java.awt.Window;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Edits the {@code settings.properties} keys that have no dedicated control of their
 * own (the theme has the toolbar toggle). Seeded from the file on open; returns the
 * user's choices on Save and lets {@link MainWindow} persist and apply them — the
 * dialog itself never touches disk or a session.
 */
final class SettingsDialog {

    record Result(Optional<AppSettings.TerminalBackground> backgroundOverride,
                  AppSettings.TerminalPalette palette,
                  boolean scrollbarHidden,
                  boolean codexMouseWheelDisabled,
                  boolean optionAsMeta,
                  boolean pageKeys,
                  boolean toolbarLabels,
                  boolean toolbarPageButtons,
                  boolean toolbarStopLadder,
                  boolean toolbarBatchActions,
                  AppSettings.SidebarBackground sidebarBackground,
                  boolean rightPaneMatchesSidebar,
                  boolean toolbarMatchesSidebar,
                  boolean sidebarSectionsMatchBackground,
                  boolean sidebarFocusBorderHidden,
                  boolean sidebarReticule,
                  boolean sidebarFolderGroups,
                  String fontFamily,
                  int fontSize,
                  boolean statusPollingEnabled,
                  int statusPollIntervalMs,
                  AppSettings.ActiveTabPollMode activeTabPollMode,
                  boolean mcpServerEnabled,
                  int mcpPort,
                  boolean mcpTokenRegenerated,
                  boolean mcpChanged,
                  boolean trayIcon,
                  String sessionShell,
                  boolean directLaunch,
                  boolean mcpSessionLogs) {
    }

    /**
     * Whether Save must re-apply the MCP server: switched on or off, a new port while it
     * stays on, or a regenerated token (the running server must restart with it). An
     * unrelated change never restarts a running server; see {@link #mcpNeedsApply} for
     * the retry of one that failed to start.
     */
    static boolean mcpChanged(boolean wasEnabled, int wasPort, boolean enabled, int port,
                              boolean tokenRegenerated) {
        return enabled != wasEnabled || (enabled && port != wasPort) || tokenRegenerated;
    }

    /**
     * Whether a Save applies the MCP server: an MCP change ({@link #mcpChanged}), or the
     * server is meant to be on but is not running — a bind that failed earlier (port
     * taken at startup or on a previous Save) is retried by any Save, without having to
     * toggle the switch.
     */
    static boolean mcpNeedsApply(boolean mcpChanged, boolean enabled, boolean running) {
        return mcpChanged || (enabled && !running);
    }

    /** Combo items pair a label with the value the choice stands for. */
    private record Choice<T>(String label, T value) {
        @Override
        public String toString() {
            return label;
        }
    }

    static Optional<Result> show(Window parent, String currentFontFamily, int currentFontSize) {
        JDialog dialog = DialogChrome.newDialog(parent, "Settings");
        DialogChrome.Form sidebar = DialogChrome.form();
        DialogChrome.Form toolbar = DialogChrome.form();
        DialogChrome.Form terminal = DialogChrome.form();
        DialogChrome.Form input = DialogChrome.form();
        DialogChrome.Form sessions = DialogChrome.form();
        DialogChrome.Form agents = DialogChrome.form();

        JComboBox<Choice<Optional<AppSettings.TerminalBackground>>> backgroundCombo =
                combo(AppSettings.terminalBackgroundOverride(),
                        new Choice<>("Follow theme", Optional.empty()),
                        new Choice<>("Black", Optional.of(AppSettings.TerminalBackground.BLACK)),
                        new Choice<>("White", Optional.of(AppSettings.TerminalBackground.WHITE)));

        JComboBox<Choice<AppSettings.TerminalPalette>> paletteCombo =
                combo(AppSettings.terminalPalette(),
                        new Choice<>("macOS Terminal", AppSettings.TerminalPalette.MACOS_TERMINAL),
                        new Choice<>("iTerm2", AppSettings.TerminalPalette.ITERM2),
                        new Choice<>("xterm", AppSettings.TerminalPalette.XTERM));

        JComboBox<String> fontFamilyCombo = fontFamilyCombo(currentFontFamily);
        JSpinner fontSizeSpinner = new JSpinner(new SpinnerNumberModel(
                AppSettings.clampTerminalFontSize(currentFontSize),
                AppSettings.MIN_TERMINAL_FONT_SIZE,
                AppSettings.MAX_TERMINAL_FONT_SIZE, 1));

        JCheckBox scrollbarBox = new JCheckBox("Hide",
                AppSettings.terminalScrollbarHidden());

        JCheckBox codexMouseWheelBox = new JCheckBox("Disable mouse wheel events",
                AppSettings.codexMouseWheelDisabled());

        JCheckBox optionAsMetaBox = new JCheckBox("Use Option as Meta",
                AppSettings.optionAsMeta());

        JCheckBox pageKeysBox = new JCheckBox("Map Page Up/Down and Home/End to the scrollback",
                AppSettings.pageKeys());

        JCheckBox toolbarLabelsBox = new JCheckBox("Show text labels next to the icons",
                AppSettings.toolbarLabels());

        JCheckBox toolbarPageButtonsBox = new JCheckBox("Show Page Up/Down controls",
                AppSettings.toolbarPageButtons());

        JCheckBox toolbarStopLadderBox = new JCheckBox(
                "Show detach/close/kill/shutdown controls",
                AppSettings.toolbarStopLadder());

        JCheckBox toolbarBatchActionsBox = new JCheckBox(
                "Show batch close/remove dead controls",
                AppSettings.toolbarBatchActions());

        JComboBox<Choice<AppSettings.SidebarBackground>> sidebarBackgroundCombo =
                combo(AppSettings.sidebarBackground(),
                        new Choice<>("Gray", AppSettings.SidebarBackground.DEFAULT),
                        new Choice<>("UI gray (darker in dark mode)", AppSettings.SidebarBackground.UI_GRAY),
                        new Choice<>("Black / white (follow theme)", AppSettings.SidebarBackground.TERMINAL));

        JCheckBox matchRightPaneBox = new JCheckBox("Match right pane to sidebar background",
                AppSettings.rightPaneMatchesSidebar());
        backgroundCombo.setEnabled(!matchRightPaneBox.isSelected());
        matchRightPaneBox.addItemListener(event -> backgroundCombo.setEnabled(!matchRightPaneBox.isSelected()));

        JCheckBox matchToolbarBox = new JCheckBox("Match toolbar and buttons to sidebar background",
                AppSettings.toolbarMatchesSidebar());

        JCheckBox matchSidebarSectionsBox = new JCheckBox("Match Sessions and Budgets to sidebar background",
                AppSettings.sidebarSectionsMatchBackground());

        JCheckBox sidebarFocusBorderBox = new JCheckBox("Hide blue focus border decoration",
                AppSettings.sidebarFocusBorderHidden());

        JCheckBox sidebarReticuleBox = new JCheckBox("Dither unattached and dead session tabs",
                AppSettings.sidebarReticule());

        JCheckBox sidebarFolderGroupsBox = new JCheckBox("Group same-folder sessions under one heading",
                AppSettings.sidebarFolderGroups());

        JCheckBox statusPollEnabledBox = new JCheckBox("Poll sessions for their status badge",
                AppSettings.statusPollingEnabled());
        JSpinner statusPollIntervalSpinner = new JSpinner(new SpinnerNumberModel(
                AppSettings.clampStatusPollIntervalMs(AppSettings.statusPollIntervalMs()),
                AppSettings.MIN_STATUS_POLL_INTERVAL_MS,
                AppSettings.MAX_STATUS_POLL_INTERVAL_MS, 500));
        JComboBox<Choice<AppSettings.ActiveTabPollMode>> activeTabPollModeCombo =
                combo(AppSettings.activeTabPollMode(),
                        new Choice<>("Off", AppSettings.ActiveTabPollMode.OFF),
                        new Choice<>("Once, on select", AppSettings.ActiveTabPollMode.ONCE),
                        new Choice<>("Scheduled while selected", AppSettings.ActiveTabPollMode.SCHEDULED));

        boolean macOs = MacWindowAppearance.isMac(System.getProperty("os.name", ""));
        JCheckBox trayIconBox = new JCheckBox(macOs
                ? "Show a menu-bar icon while sessions run with the app closed"
                : "Show a system-tray icon while sessions run with the app closed",
                AppSettings.trayIconEnabled());

        JComboBox<Choice<String>> shellCombo = shellCombo(AppSettings.sessionShell(), parent);
        JCheckBox directLaunchBox = new JCheckBox("Start agents in one step (zsh, bash, sh, fish)",
                AppSettings.directLaunch());

        boolean mcpWasEnabled = AppSettings.mcpServerEnabled();
        int mcpWasPort = AppSettings.mcpPort();
        JCheckBox mcpServerBox = new JCheckBox(
                "Let agents in its sessions list, read and drive other sessions",
                mcpWasEnabled);
        JSpinner mcpPortSpinner = new JSpinner(new SpinnerNumberModel(
                mcpWasPort, AppSettings.MIN_MCP_PORT, AppSettings.MAX_MCP_PORT, 1));
        // a port is an identifier, not a quantity: no "7,392"
        mcpPortSpinner.setEditor(new JSpinner.NumberEditor(mcpPortSpinner, "#"));
        mcpPortSpinner.setEnabled(mcpServerBox.isSelected());
        JCheckBox mcpSessionLogsBox = new JCheckBox(
                "Keep a log of each session an agent reads, in that agent's project",
                AppSettings.mcpSessionLogs());
        mcpSessionLogsBox.setEnabled(mcpServerBox.isSelected());
        mcpServerBox.addItemListener(e -> {
            mcpPortSpinner.setEnabled(mcpServerBox.isSelected());
            mcpSessionLogsBox.setEnabled(mcpServerBox.isSelected());
        });
        // regenerated on Save, not on click, so Cancel really cancels
        AtomicBoolean regenerateMcpToken = new AtomicBoolean();
        JButton regenerateMcpTokenButton = new JButton("Regenerate token");
        regenerateMcpTokenButton.addActionListener(e -> {
            regenerateMcpToken.set(true);
            regenerateMcpTokenButton.setText("Token regenerates on Save");
            regenerateMcpTokenButton.setEnabled(false);
        });

        Runnable updatePollControlsEnabled = () -> {
            boolean pollingOn = statusPollEnabledBox.isSelected();
            boolean scheduledActiveTab = selected(activeTabPollModeCombo)
                    == AppSettings.ActiveTabPollMode.SCHEDULED;
            statusPollIntervalSpinner.setEnabled(pollingOn || scheduledActiveTab);
            activeTabPollModeCombo.setEnabled(!pollingOn);
        };
        updatePollControlsEnabled.run();
        statusPollEnabledBox.addItemListener(e -> updatePollControlsEnabled.run());
        activeTabPollModeCombo.addItemListener(e -> updatePollControlsEnabled.run());

        sidebar.addRow("Background:", sidebarBackgroundCombo);
        sidebar.addRow("Right pane:", matchRightPaneBox);
        sidebar.addRow("Toolbar and buttons:", matchToolbarBox);
        sidebar.addRow("Sessions and Budgets:", matchSidebarSectionsBox);
        sidebar.addRow("Focus border:", sidebarFocusBorderBox);
        sidebar.addRow("Reticule:", sidebarReticuleBox);
        sidebar.addRow("Folder groups:", sidebarFolderGroupsBox);
        sidebar.addRow("", note("On by default. Applies while Sort is Folder."));

        toolbar.addRow("Labels:", toolbarLabelsBox);
        toolbar.addRow("Paging:", toolbarPageButtonsBox);
        toolbar.addRow("Stop ladder:", toolbarStopLadderBox);
        toolbar.addRow("Batch actions:", toolbarBatchActionsBox);
        toolbar.addRow("", note("Batch actions are on by default."));

        terminal.addRow("Background:", backgroundCombo);
        terminal.addRow("Font:", fontFamilyCombo);
        terminal.addRow("Font size:", fontSizeSpinner);
        terminal.addRow("", note("Global; applies live. Use Cmd/Ctrl + or - to resize."));
        terminal.addRow("ANSI palette:", paletteCombo);
        terminal.addRow("", note("The 16 base colors. Applies live, to open terminals too."));
        terminal.addRow("Scrollbar:", scrollbarBox);
        terminal.addRow("", note("Applies to terminals attached from now on."));

        input.addRow("Codex mouse wheel:", codexMouseWheelBox);
        input.addRow("", note("On by default. Applies live to Codex sessions."));
        if (MacWindowAppearance.isMac(System.getProperty("os.name", ""))) {
            input.addRow("Option key:", optionAsMetaBox);
            input.addRow("", note("On by default: Option+letter is Meta (word motion, shortcuts)."));
            input.addRow("", note("Off types accents and symbols (Option+e, e = é). Applies live."));
        }
        input.addRow("Paging keys:", pageKeysBox);
        input.addRow("", note("Off passes all four keys through to the program."));

        sessions.addRow("Status polling:", statusPollEnabledBox);
        sessions.addRow("Poll interval:", statusPollIntervalSpinner);
        sessions.addRow("", note("Milliseconds between status polls. Applies live."));
        sessions.addRow("", note("Off freezes status badges and pane titles."));
        sessions.addRow("Active tab, if polling off:", activeTabPollModeCombo);
        sessions.addRow("", note("Keeps the selected tab's badge fresh even with polling off."));
        sessions.addRow("Shell:", shellCombo);
        sessions.addRow("", note("For new sessions. Your default is your login shell; others read their own setup files."));
        sessions.addRow("Agent start:", directLaunchBox);
        sessions.addRow("", note("On by default: the shell starts the agent itself, so nothing is typed during startup."));
        sessions.addRow("", note("Off types the agent's command once the shell is up. Other shells always type it."));
        sessions.addRow("Background icon:", trayIconBox);
        sessions.addRow("", note("On by default. Opens the app; takes effect next time you quit."));

        agents.addRow("MCP server:", mcpServerBox);
        agents.addRow("MCP port:", mcpPortSpinner);
        agents.addRow("MCP token:", regenerateMcpTokenButton);
        agents.addRow("", note("A new token restarts the server."));
        agents.addRow("", note("Earlier sessions reconnect after Resume."));
        agents.addRow("", note("Off by default. Loopback only, token-protected; applies live."));
        agents.addRow("", note("New Claude Code and Codex sessions connect automatically."));
        agents.addRow("Session logs:", mcpSessionLogsBox);
        agents.addRow("", note("Off by default. Copies the sessions an agent reads into .microhm-sessions/"));
        agents.addRow("", note("in its project, as plain text: for agents that cannot read outside it."));

        AtomicReference<Optional<Result>> resultHolder = new AtomicReference<>(Optional.empty());
        JButton save = new JButton("Save");
        JButton cancel = new JButton("Cancel");
        save.addActionListener(e -> {
            resultHolder.set(Optional.of(new Result(
                    selected(backgroundCombo),
                    selected(paletteCombo),
                    scrollbarBox.isSelected(),
                    codexMouseWheelBox.isSelected(),
                    optionAsMetaBox.isSelected(),
                    pageKeysBox.isSelected(),
                    toolbarLabelsBox.isSelected(),
                    toolbarPageButtonsBox.isSelected(),
                    toolbarStopLadderBox.isSelected(),
                    toolbarBatchActionsBox.isSelected(),
                    selected(sidebarBackgroundCombo),
                    matchRightPaneBox.isSelected(),
                    matchToolbarBox.isSelected(),
                    matchSidebarSectionsBox.isSelected(),
                    sidebarFocusBorderBox.isSelected(),
                    sidebarReticuleBox.isSelected(),
                    sidebarFolderGroupsBox.isSelected(),
                    (String) fontFamilyCombo.getSelectedItem(),
                    (Integer) fontSizeSpinner.getValue(),
                    statusPollEnabledBox.isSelected(),
                    (Integer) statusPollIntervalSpinner.getValue(),
                    selected(activeTabPollModeCombo),
                    mcpServerBox.isSelected(),
                    (Integer) mcpPortSpinner.getValue(),
                    regenerateMcpToken.get(),
                    mcpChanged(mcpWasEnabled, mcpWasPort, mcpServerBox.isSelected(),
                            (Integer) mcpPortSpinner.getValue(), regenerateMcpToken.get()),
                    trayIconBox.isSelected(),
                    selected(shellCombo),
                    directLaunchBox.isSelected(),
                    mcpSessionLogsBox.isSelected())));
            dialog.dispose();
        });
        cancel.addActionListener(e -> dialog.dispose());

        JPanel sections = sections(
                new String[]{"Sidebar", "Toolbar", "Terminal", "Input", "Sessions", "Agent control"},
                sidebar, toolbar, terminal, input, sessions, agents);
        JPanel footer = new JPanel(new BorderLayout());
        JLabel saveHint = note("Save applies changes from every section.");
        saveHint.setBorder(BorderFactory.createEmptyBorder(0, 16, 12, 12));
        saveHint.setToolTipText(AppSettings.settingsFile().toString());
        JButton performance = new JButton("Performance…");
        performance.setToolTipText("Startup time, startup cache, memory and other figures for this run");
        performance.addActionListener(e -> PerformanceDialog.show(dialog));
        JPanel footerLeft = new JPanel(new BorderLayout());
        JPanel performanceRow = new JPanel(new java.awt.FlowLayout(java.awt.FlowLayout.LEFT, 0, 0));
        performanceRow.setBorder(BorderFactory.createEmptyBorder(0, 12, 6, 12));
        performanceRow.add(performance);
        footerLeft.add(performanceRow, BorderLayout.NORTH);
        footerLeft.add(saveHint, BorderLayout.SOUTH);
        footer.add(footerLeft, BorderLayout.WEST);
        footer.add(DialogChrome.buttons(save, cancel), BorderLayout.EAST);
        DialogChrome.layout(dialog, sections, footer);
        DialogChrome.show(dialog, parent, save, cancel);
        return resultHolder.get();
    }

    /** Left-side section navigation; cards keep unsaved fields intact between selections. */
    private static JPanel sections(String[] names, DialogChrome.Form... forms) {
        CardLayout layout = new CardLayout();
        JPanel cards = new JPanel(layout);
        for (int index = 0; index < names.length; index++) {
            JPanel page = new JPanel(new BorderLayout());
            JLabel heading = new JLabel(names[index]);
            heading.setFont(heading.getFont().deriveFont(java.awt.Font.BOLD,
                    heading.getFont().getSize2D() + 3f));
            heading.setBorder(BorderFactory.createEmptyBorder(16, 16, 0, 16));
            page.add(heading, BorderLayout.NORTH);
            JPanel body = new JPanel(new BorderLayout());
            body.add(forms[index].panel, BorderLayout.NORTH);
            JScrollPane scroll = new JScrollPane(body);
            scroll.setBorder(BorderFactory.createEmptyBorder());
            scroll.getVerticalScrollBar().setUnitIncrement(16);
            page.add(scroll, BorderLayout.CENTER);
            cards.add(page, names[index]);
        }

        JList<String> navigation = new JList<>(names);
        navigation.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        navigation.setFixedCellHeight(38);
        navigation.setBorder(BorderFactory.createEmptyBorder(12, 8, 12, 8));
        navigation.getAccessibleContext().setAccessibleName("Settings sections");
        navigation.setCellRenderer(new DefaultListCellRenderer() {
            @Override
            public Component getListCellRendererComponent(JList<?> list, Object value,
                    int index, boolean selected, boolean focused) {
                JComponent row = (JComponent) super.getListCellRendererComponent(
                        list, value, index, selected, focused);
                row.setBorder(BorderFactory.createEmptyBorder(0, 12, 0, 12));
                return row;
            }
        });
        navigation.addListSelectionListener(event -> {
            if (!event.getValueIsAdjusting() && navigation.getSelectedValue() != null) {
                layout.show(cards, navigation.getSelectedValue());
            }
        });
        navigation.setSelectedIndex(0);
        JPanel panel = new JPanel(new BorderLayout());
        panel.add(navigation, BorderLayout.WEST);
        panel.add(cards, BorderLayout.CENTER);
        panel.setPreferredSize(new Dimension(900, 440));
        return panel;
    }

    /** A combo over {@code choices} with the one matching {@code current} preselected. */
    @SafeVarargs
    private static <T> JComboBox<Choice<T>> combo(T current, Choice<T>... choices) {
        JComboBox<Choice<T>> combo = new JComboBox<>(choices);
        for (Choice<T> choice : choices) {
            if (choice.value().equals(current)) {
                combo.setSelectedItem(choice);
            }
        }
        return combo;
    }

    /** Your default, then the shells installed here, then any custom path in use, then
     * "Other…", which picks a program and adds it. */
    private static JComboBox<Choice<String>> shellCombo(String current, Window parent) {
        SessionShell shells = SessionShell.system();
        JComboBox<Choice<String>> combo = new JComboBox<>();
        combo.addItem(new Choice<>(shells.describe(SessionShell.DEFAULT), SessionShell.DEFAULT));
        for (String name : shells.installedNames()) {
            combo.addItem(new Choice<>(shells.displayName(name), name));
        }
        boolean listed = false;
        for (int i = 0; i < combo.getItemCount(); i++) {
            if (combo.getItemAt(i).value().equals(current)) {
                combo.setSelectedIndex(i);
                listed = true;
            }
        }
        if (!listed) {
            Choice<String> custom = new Choice<>(shells.describe(current), current);
            combo.addItem(custom);
            combo.setSelectedItem(custom);
        }
        Choice<String> other = new Choice<>("Other…", null);
        combo.addItem(other);
        int[] previous = {combo.getSelectedIndex()};
        combo.addActionListener(e -> {
            if (combo.getSelectedItem() != other) {
                previous[0] = combo.getSelectedIndex();
                return;
            }
            JFileChooser chooser = new JFileChooser("/bin");
            chooser.setDialogTitle("Choose a shell");
            if (chooser.showOpenDialog(parent) == JFileChooser.APPROVE_OPTION) {
                String path = chooser.getSelectedFile().getAbsolutePath();
                Choice<String> picked = new Choice<>(shells.describe(path), path);
                combo.insertItemAt(picked, combo.getItemCount() - 1);
                combo.setSelectedItem(picked);
            } else {
                combo.setSelectedIndex(previous[0]);
            }
        });
        return combo;
    }

    private static <T> T selected(JComboBox<Choice<T>> combo) {
        return combo.getItemAt(combo.getSelectedIndex()).value();
    }

    private static JComboBox<String> fontFamilyCombo(String current) {
        String[] installed = GraphicsEnvironment.getLocalGraphicsEnvironment()
                .getAvailableFontFamilyNames();
        JComboBox<String> combo = new JComboBox<>(installed);
        combo.setMaximumRowCount(18);
        // Preserve a family from a hand-edited settings file even if it is no longer
        // installed; saving another setting should not silently replace it.
        boolean found = false;
        for (String family : installed) {
            if (family.equals(current)) {
                found = true;
                break;
            }
        }
        if (!found) {
            combo.addItem(current);
        }
        combo.setSelectedItem(current);
        return combo;
    }

    private static JLabel note(String text) {
        JLabel label = new JLabel(text);
        label.setFont(label.getFont().deriveFont(label.getFont().getSize2D() - 2f));
        label.setForeground(UIManager.getColor("Label.disabledForeground"));
        return label;
    }

    private SettingsDialog() {
    }
}
