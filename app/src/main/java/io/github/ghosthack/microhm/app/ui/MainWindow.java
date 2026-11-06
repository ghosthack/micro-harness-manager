package io.github.ghosthack.microhm.app.ui;

import com.formdev.flatlaf.FlatLaf;
import com.formdev.flatlaf.FlatClientProperties;
import com.formdev.flatlaf.themes.FlatMacDarkLaf;
import com.formdev.flatlaf.themes.FlatMacLightLaf;
import io.github.ghosthack.microhm.app.harness.HarnessPlugin;
import io.github.ghosthack.microhm.app.harness.HarnessPlugins;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.SessionConnection;
import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.host.SessionHostException;
import io.github.ghosthack.microhm.app.registry.ReconciliationResult;
import io.github.ghosthack.microhm.app.registry.Reconciler;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.session.SessionLauncher;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.state.SessionState;
import io.github.ghosthack.microhm.app.status.GracefulCloser;
import io.github.ghosthack.microhm.app.status.SessionStatusPoller;
import io.github.ghosthack.microhm.app.terminal.SessionTerminal;
import io.github.ghosthack.microhm.app.usage.HarnessUsageService;

import io.github.ghosthack.microhm.app.settings.AppSettings;

import javax.swing.BorderFactory;
import javax.swing.Box;
import javax.swing.BoxLayout;
import javax.swing.ButtonGroup;
import javax.swing.JCheckBoxMenuItem;
import javax.swing.DefaultListModel;
import javax.swing.Icon;
import javax.swing.JButton;
import javax.swing.JDialog;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JLayeredPane;
import javax.swing.JList;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JPopupMenu;
import javax.swing.JRadioButtonMenuItem;
import javax.swing.JScrollPane;
import javax.swing.JSeparator;
import javax.swing.JSplitPane;
import javax.swing.JTextField;
import javax.swing.ListSelectionModel;
import javax.swing.SwingConstants;
import javax.swing.SwingUtilities;
import javax.swing.Timer;
import javax.swing.ToolTipManager;
import javax.swing.UIManager;
import java.awt.BorderLayout;
import java.awt.CardLayout;
import java.awt.Color;
import java.awt.Component;
import java.awt.Container;
import java.awt.Dimension;
import java.awt.Cursor;
import java.awt.FlowLayout;
import java.awt.GridBagLayout;
import java.awt.Font;
import java.awt.Insets;
import java.awt.KeyEventDispatcher;
import java.awt.KeyboardFocusManager;
import java.awt.Toolkit;
import java.awt.datatransfer.StringSelection;
import java.awt.event.KeyEvent;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The main window: sidebar of sessions on the left, a {@link CardLayout} of attached
 * terminals on the right; see {@link io.github.ghosthack.microhm.app.MicroHarnessManagerApp}.
 */
public final class MainWindow extends JFrame {

    /** App name shown as the base window title; the selected session is prefixed to it. */
    public static final String APP_NAME = "micro-harness-manager";

    private static final String PLACEHOLDER_CARD = "__placeholder__";
    private static final String DEFAULT_CARD = "__default__";

    /** Frame interval for the working dot's pulse — ~25fps, smooth without spamming
     * the EDT for what is a slow breathing motion. */
    private static final int PULSE_FRAME_MS = 40;

    /** The sidebar's starting width, and the width it reopens to after a collapse
     * unless the user dragged the divider somewhere else first. */
    private static final int SIDEBAR_WIDTH = 280;

    /** Retains the sidebar's neutral one-pixel boundary while suppressing FlatLaf's
     * wider blue focus ring and focused-border recoloring. */
    private static final String SIDEBAR_NO_FOCUS_BORDER_STYLE =
            "focusWidth: 0; focusedBorderColor: $Component.borderColor";

    /** Keep the session portion of the native window title useful without letting a
     * prompt-derived Codex preview crowd out the project and application names. */
    private static final int WINDOW_TITLE_SESSION_MAX_CHARS = 64;

    private final SessionRegistry registry;
    private final SessionHost host;

    private final DefaultListModel<SidebarEntry> listModel = new DefaultListModel<>();
    /** Complete reconciled set. {@link #listModel} is only its sorted/filtered view. */
    private final List<SidebarEntry> allSidebarEntries = new ArrayList<>();
    private final JList<SidebarEntry> sidebarList = new JList<>(listModel) {
        @Override
        public String getToolTipText(MouseEvent event) {
            // locationToIndex returns the closest row for any point — without the
            // bounds check, hovering blank space shows the last row's tooltip
            int index = locationToIndex(event.getPoint());
            if (index < 0 || !getCellBounds(index, index).contains(event.getPoint())) {
                return null;
            }
            return getModel().getElementAt(index).tooltipText();
        }
    };
    private final JScrollPane sidebarScrollPane = new JScrollPane(sidebarList);
    private final JPanel toolBar = new JPanel();
    private JPanel sidebarControlsPanel;
    private final CardLayout cardLayout = new CardLayout();
    private final JPanel cards = new JPanel(cardLayout);
    private final JLabel placeholderLabel = new JLabel("", SwingConstants.CENTER);
    private final JLabel deadSessionLabel = new JLabel();

    /** Transient banner overlaid above whichever card is showing (placeholder or an
     * attached terminal) — e.g. to explain that a session was just created but is
     * hidden by the active sidebar filter. Auto-hides via {@link #statusBannerTimer}. */
    private final JLabel statusBanner = new JLabel("", SwingConstants.CENTER);
    private final Timer statusBannerTimer = new Timer(4000, e -> statusBanner.setVisible(false));

    /** Live terminal attachments, keyed by session name. Survive sidebar rebuilds. */
    private final Map<String, SessionTerminal> attached = new LinkedHashMap<>();

    /**
     * Attaches in flight, keyed by session name — never two for the same session — each
     * mapped to its generation ticket. {@code host.attach} may block (daemon connect), so
     * the connection is opened off the EDT and lands via {@link #landAttach}; the ticket
     * lets any later {@link #removeAttachment} (detach, kill, close, resume, the eviction
     * loop) invalidate a result that hasn't landed yet, with no per-caller code: a
     * superseded connection is closed on arrival, never shown.
     */
    private final Map<String, Integer> attaching = new HashMap<>();
    private final Map<String, Integer> attachGeneration = new HashMap<>();

    /**
     * Sessions in the order they were first attached this run — the Ctrl+Tab cycling
     * order (see {@link #cycleAttached}). Not MRU: re-selecting a session doesn't move
     * it, matching Chrome's tab strip (fixed position, not recency).
     */
    private final List<String> attachOrder = new ArrayList<>();

    /** Runs every blocking daemon round trip — status captures, reconciliation, session
     * create/kill — so the EDT only ever paints and reacts. */
    private final ExecutorService backgroundExecutor = Executors.newVirtualThreadPerTaskExecutor();
    /** Serializes settings rewrites so rapid UI changes cannot land out of order. */
    private final ExecutorService settingsExecutor = Executors.newSingleThreadExecutor();
    private final SessionStatusPoller statusPoller;

    /** Set by {@link #shutdown}; late events from other threads are then ignored. */
    private volatile boolean disposed;
    /** Creates and resumes sessions off the EDT; shared with the MCP controller. */
    private final SessionLauncher launcher;
    /** The MCP server's lifecycle — Settings starts/stops it, shutdown stops it. */
    private final McpService mcpService;
    /** Applies Settings' MCP changes to {@link #mcpService}, one at a time, in order. */
    private final McpApplier mcpApplier;
    /** Sessions created or killed outside this window (MCP), fired from any thread. */
    private final SessionEvents sessionEvents;
    private final SessionEvents.SessionsChangedListener sessionsChangedListener =
            created -> SwingUtilities.invokeLater(() -> {
                if (!disposed) {
                    refreshSidebar(null); // never reselect: an agent's spawn must not steal focus
                }
            });
    private final SessionEvents.SessionKilledListener sessionKilledListener = this::sessionKilledExternally;

    /** The context menu's "Close" and Cmd/Ctrl+W's polite session close. Quit timeout
     * is generous — a harness flushing
     * its transcript on exit can take a few seconds; exit timeout is a bare shell
     * dying, which is quick or wedged. */
    private final GracefulCloser gracefulCloser;
    private final Timer statusPollTimer;

    /** SCHEDULED {@link AppSettings.ActiveTabPollMode}'s tick: re-polls only the
     * session in {@link #sidebarList}'s current selection, run/stopped by
     * {@link #applyActiveTabPollTimerState()}. */
    private final Timer activeTabPollTimer;

    /** Drives the attached working dots' pulse by repainting just those rows. Self-
     * stopping: a tick that finds nothing pulsing stops the timer, and
     * {@link #ensurePulsing()} restarts it wherever states or attachment change. */
    private final Timer pulseTimer = new Timer(PULSE_FRAME_MS, e -> repaintPulsingDots());
    private final KeyEventDispatcher keyEventDispatcher = this::handleGlobalKeyEvent;
    private final JButton sidebarButton = new JButton();
    private final JButton openButton = new JButton("Open…");
    private final JButton openHereButton = new JButton();
    private final JButton shellHereButton = new JButton();
    private final JButton duplicateButton = new JButton();
    private final JPanel pageButtonsGroup = new JPanel();
    private final JButton pageUpButton = new JButton();
    private final JButton pageDownButton = new JButton();
    private final JPanel stopLadderGroup = new JPanel();
    private final JButton detachButton = new JButton();
    private final JButton closeButton = new JButton();
    private final JButton killButton = new JButton();
    private final JButton shutdownButton = new JButton();
    private final JPanel batchActionsGroup = new JPanel();
    private final JButton batchCloseButton = new JButton();
    private final JButton removeDeadButton = new JButton();
    private final JButton themeButton = new JButton();
    private final JButton usageButton = new JButton();
    private final JButton settingsButton = new JButton();
    private final JButton sortButton = new JButton();
    private final JButton filterButton = new JButton();
    private final JButton harnessFilterButton = new JButton();
    private final HarnessBudgetPanel harnessBudgetPanel = new HarnessBudgetPanel();
    private final HarnessUsageService harnessUsageService = new HarnessUsageService();
    private final AtomicInteger budgetRefreshSeq = new AtomicInteger();
    private boolean budgetsLoaded;

    private SidebarView.SortMode sidebarSort = SidebarView.SortMode.SESSION_NAME;
    private boolean sidebarSortDescending;
    private final EnumSet<SidebarView.FilterStatus> visibleStatuses =
            EnumSet.allOf(SidebarView.FilterStatus.class);
    private final EnumSet<SidebarView.HarnessFamily> visibleHarnessFamilies =
            EnumSet.allOf(SidebarView.HarnessFamily.class);
    private boolean rebuildingSidebar;
    private String lastSelectedSessionName;

    /** The active look; the toolbar sun/moon toggles it. Seeded from settings, which is
     * also what {@code MicroHarnessManagerApp} set up the initial LaF from. */
    private AppSettings.UiTheme uiTheme = AppSettings.uiTheme();

    /** Whether toolbar buttons carry text next to their glyph (the settings dialog's
     * toggle); tooltips carry the long form either way. */
    private boolean toolbarLabels = AppSettings.toolbarLabels();

    /** Whether the two page buttons (and their leading separator) are visible. */
    private boolean toolbarPageButtons = AppSettings.toolbarPageButtons();

    /** Whether the stop-ladder buttons (detach/close/kill/shutdown) are visible. */
    private boolean toolbarStopLadder = AppSettings.toolbarStopLadder();

    /** Whether the batch-action buttons (Batch close, Remove dead sessions) are visible. */
    private boolean toolbarBatchActions = AppSettings.toolbarBatchActions();

    /** Bare Page Up/Down and Home/End page the terminal's scrollback when on. */
    private boolean pageKeys = AppSettings.pageKeys();

    /** Sidebar background choice, re-applied when the app theme changes. */
    private AppSettings.SidebarBackground sidebarBackground = AppSettings.sidebarBackground();
    private boolean rightPaneMatchesSidebar = AppSettings.rightPaneMatchesSidebar();
    private boolean toolbarMatchesSidebar = AppSettings.toolbarMatchesSidebar();
    private boolean sidebarSectionsMatchBackground = AppSettings.sidebarSectionsMatchBackground();
    private Optional<AppSettings.TerminalBackground> terminalBackgroundOverride =
            AppSettings.terminalBackgroundOverride();

    /** Whether the sidebar scroll pane omits FlatLaf's blue keyboard-focus border. */
    private boolean sidebarFocusBorderHidden = AppSettings.sidebarFocusBorderHidden();

    /** Whether unattached/dead session tabs use the screen-door dither. */
    private boolean sidebarReticule = AppSettings.sidebarReticule();
    private final SidebarCellRenderer sidebarCellRenderer = new SidebarCellRenderer(sidebarReticule);

    /** Whether same-folder sessions collapse into one headed group. Only the folder
     * sort can honour it — see {@link #applySidebarFolderGrouping()}. */
    private boolean sidebarFolderGroups = AppSettings.sidebarFolderGroups();

    /** App-wide terminal font. Every live card is updated together. */
    private String terminalFontFamily = AppSettings.terminalFontFamily();
    private int terminalFontSize = AppSettings.terminalFontSize();

    /** How often live sessions are polled for their status badge; applies live via
     * {@code statusPollTimer.setDelay(...)} when changed in the settings dialog. */
    private int statusPollIntervalMs = AppSettings.statusPollIntervalMs();

    /** Whether {@link #statusPollTimer} is allowed to run at all. Off freezes the
     * sidebar's working/idle/waiting badge and pane title at their last known value;
     * attached terminals and session-death detection do not depend on this loop. Close
     * and Reload fall back to their own bounded catch-up poll (see
     * {@link #catchUpConfirmedState}) rather than refusing forever on a session
     * this timer never got to. */
    private boolean statusPollingEnabled = AppSettings.statusPollingEnabled();

    /** How the active tab is kept fresh while {@link #statusPollingEnabled} is off;
     * see {@link #activateSelected()} (ONCE) and {@link #activeTabPollTimer}
     * (SCHEDULED). Ignored while the periodic timer is on. */
    private AppSettings.ActiveTabPollMode activeTabPollMode = AppSettings.activeTabPollMode();

    /** Per-session cooldown for ONCE mode's catch-up, keyed by session name, so
     * sidebar rebuilds that merely reselect the same tab (see rebuildVisibleSidebar)
     * don't refire it many times a second — see {@link #maybeCatchUpActiveTab}. */
    private final Map<String, Long> activeTabCatchUpAtMs = new HashMap<>();

    /** The sidebar/terminal split, kept for the toolbar's collapse toggle. */
    private final JSplitPane split;

    /** Where the divider sat before the last collapse, restored on expand. */
    private int sidebarWidth = SIDEBAR_WIDTH;

    /** The divider's natural thickness, remembered across the collapsed (0-width) span. */
    private int dividerSize;

    private boolean sidebarCollapsed;

    /** Refresh tickets: reconciliation runs off the EDT, so a slow older refresh must
     * not overwrite the sidebar state of a newer one — nor may a newer reselect-nothing
     * refresh drop an older one's reselect target. */
    private final SidebarRefreshTickets refreshTickets = new SidebarRefreshTickets();

    /**
     * The app's window. {@code launcher} creates and resumes sessions (shared with the
     * MCP session controller), {@code mcpService} is started/stopped/restarted from
     * Settings and stopped on shutdown, and {@code sessionEvents} carries sessions
     * created or killed outside this window into its sidebar.
     */
    public MainWindow(SessionRegistry registry, SessionHost host, SessionLauncher launcher,
                      McpService mcpService, SessionEvents sessionEvents) {
        super(APP_NAME);
        AppIcon.applyTo(this);
        this.registry = registry;
        this.host = host;
        this.launcher = launcher;
        this.mcpService = mcpService;
        this.mcpApplier = new McpApplier(mcpService::start, mcpService::stop, AppSettings::mcpToken,
                AppSettings::regenerateMcpToken, (port, e) -> SwingUtilities.invokeLater(() -> {
                    if (!disposed) {
                        JOptionPane.showMessageDialog(this,
                                "The MCP server could not start on port " + port + ": " + e.getMessage()
                                        + "\nPick another port in Settings.",
                                "MCP server", JOptionPane.ERROR_MESSAGE);
                    }
                }));
        this.sessionEvents = sessionEvents;
        restoreSidebarViewSettings();
        applySidebarFolderGrouping();

        setDefaultCloseOperation(JFrame.DO_NOTHING_ON_CLOSE);
        addWindowListener(new WindowAdapter() {
            @Override
            public void windowClosing(WindowEvent e) {
                shutdown();
                System.exit(0);
            }
        });

        cards.add(defaultPanel(), DEFAULT_CARD);
        cards.add(placeholderPanel(), PLACEHOLDER_CARD);
        cards.add(deadSessionPanel(), "dead-session");

        sidebarList.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        sidebarList.setCellRenderer(sidebarCellRenderer);
        applySidebarFocusBorder();
        sidebarList.addListSelectionListener(e -> {
            if (!e.getValueIsAdjusting() && !rebuildingSidebar) {
                activateSelected();
            }
        });
        ToolTipManager.sharedInstance().registerComponent(sidebarList);
        MouseAdapter hoverTracker = new MouseAdapter() {
            @Override
            public void mouseMoved(MouseEvent e) {
                int index = sidebarList.locationToIndex(e.getPoint());
                if (index >= 0 && !sidebarList.getCellBounds(index, index).contains(e.getPoint())) {
                    index = -1;
                }
                setSidebarHover(index);
            }

            @Override
            public void mouseDragged(MouseEvent e) {
                mouseMoved(e);
            }

            @Override
            public void mouseExited(MouseEvent e) {
                setSidebarHover(-1);
            }
        };
        sidebarList.addMouseMotionListener(hoverTracker);
        sidebarList.addMouseListener(hoverTracker);
        sidebarList.addMouseListener(new MouseAdapter() {
            @Override
            public void mousePressed(MouseEvent e) {
                maybeShowPopup(e);
            }

            @Override
            public void mouseReleased(MouseEvent e) {
                maybeShowPopup(e);
            }
        });

        toolBar.setLayout(new BoxLayout(toolBar, BoxLayout.X_AXIS));
        toolBar.setBorder(BorderFactory.createEmptyBorder(5, 5, 5, 5));
        for (JButton button : List.of(sidebarButton, openButton, openHereButton, shellHereButton,
                duplicateButton, pageUpButton, pageDownButton,
                detachButton, closeButton, killButton, shutdownButton, batchCloseButton, removeDeadButton,
                usageButton, settingsButton, themeButton)) {
            configureControlButton(button);
        }

        sidebarButton.addActionListener(e -> toggleSidebar());
        addControlButton(toolBar, sidebarButton);
        // the sidebar toggle shapes the window; everything after acts on sessions
        addControlSeparator(toolBar);
        openButton.setIcon(LucidIcon.folderPlus(16));
        openButton.setToolTipText("Start a new session…");
        openButton.addActionListener(e -> openSession());
        addControlButton(toolBar, openButton);
        openHereButton.setIcon(LucidIcon.folderOpen(16));
        openHereButton.setToolTipText("New session where the selected session is");
        openHereButton.addActionListener(e -> openSessionAtSelection());
        addControlButton(toolBar, openHereButton);
        shellHereButton.setIcon(HarnessIcons.forType(HarnessType.SHELL));
        shellHereButton.setToolTipText("New shell at the selected session's path (Cmd/Ctrl+T)");
        shellHereButton.addActionListener(e -> openShellAtSelection());
        addControlButton(toolBar, shellHereButton);
        duplicateButton.setIcon(LucidIcon.duplicate(16));
        duplicateButton.setToolTipText("Duplicate the selected session (Cmd/Ctrl+D)");
        duplicateButton.addActionListener(e -> duplicateSelected());
        addControlButton(toolBar, duplicateButton);

        // Navigation through the session's history is one hideable group so
        // disabling it cannot strand a separator or spacer in the row.
        pageButtonsGroup.setOpaque(false);
        pageButtonsGroup.setLayout(new BoxLayout(pageButtonsGroup, BoxLayout.X_AXIS));
        addControlSeparator(pageButtonsGroup);
        pageUpButton.setIcon(LucidIcon.pageUp(16));
        pageUpButton.setToolTipText("Scroll the selected session one page up");
        pageUpButton.addActionListener(e -> scrollPage(true));
        addControlButton(pageButtonsGroup, pageUpButton);
        pageDownButton.setIcon(LucidIcon.pageDown(16));
        pageDownButton.setToolTipText("Scroll the selected session one page down");
        pageDownButton.addActionListener(e -> scrollPage(false));
        addControlButton(pageButtonsGroup, pageDownButton);
        toolBar.add(pageButtonsGroup);

        // The stop ladder (detach/close/kill/shutdown) is one hideable group,
        // gentlest first, fenced off from the create buttons — so disabling it cannot
        // strand a separator in the row.
        stopLadderGroup.setOpaque(false);
        stopLadderGroup.setLayout(new BoxLayout(stopLadderGroup, BoxLayout.X_AXIS));
        addControlSeparator(stopLadderGroup);
        detachButton.setIcon(LucidIcon.detach(16));
        detachButton.setToolTipText("Detach the selected session (keeps it running)");
        detachButton.addActionListener(e -> detachSelected());
        addControlButton(stopLadderGroup, detachButton);
        closeButton.setIcon(LucidIcon.x(16));
        closeButton.setToolTipText("Close the selected session gracefully (Cmd/Ctrl+W)");
        closeButton.addActionListener(e -> closeSelectedGracefully());
        addControlButton(stopLadderGroup, closeButton);
        killButton.setIcon(LucidIcon.zap(16));
        killButton.setToolTipText("Kill the selected session…");
        killButton.addActionListener(e -> killSelected());
        addControlButton(stopLadderGroup, killButton);
        // wider blast radius than the per-session ladder — fenced off on its own
        addControlSeparator(stopLadderGroup);
        shutdownButton.setIcon(LucidIcon.power(16));
        shutdownButton.setToolTipText("Gracefully close all live sessions");
        shutdownButton.addActionListener(e -> shutdownAll());
        addControlButton(stopLadderGroup, shutdownButton);
        toolBar.add(stopLadderGroup);

        // The batch actions (Batch close, Remove dead sessions) are their own hideable
        // group, fenced off from the per-session stop ladder — so disabling it cannot
        // strand a separator in the row.
        batchActionsGroup.setOpaque(false);
        batchActionsGroup.setLayout(new BoxLayout(batchActionsGroup, BoxLayout.X_AXIS));
        addControlSeparator(batchActionsGroup);
        batchCloseButton.setIcon(LucidIcon.listChecks(16));
        batchCloseButton.setToolTipText("Close a chosen batch of live sessions…");
        batchCloseButton.addActionListener(e -> openBatchCloseDialog());
        addControlButton(batchActionsGroup, batchCloseButton);
        removeDeadButton.setIcon(LucidIcon.trash(16));
        removeDeadButton.setToolTipText("Remove a chosen batch of dead sessions from the registry…");
        removeDeadButton.addActionListener(e -> openBatchRemoveDeadDialog());
        addControlButton(batchActionsGroup, removeDeadButton);
        toolBar.add(batchActionsGroup);
        updateSelectionButtons(); // nothing is selected yet — start the row disabled
        toolBar.add(Box.createHorizontalGlue());
        usageButton.setIcon(LucidIcon.usage(16));
        usageButton.setToolTipText("Show harness usage and limits");
        usageButton.addActionListener(e -> openUsageLimitsDialog());
        addControlButton(toolBar, usageButton);
        settingsButton.setIcon(LucidIcon.settings(16));
        settingsButton.setToolTipText("Settings");
        settingsButton.addActionListener(e -> openSettingsDialog());
        addControlButton(toolBar, settingsButton);
        themeButton.addActionListener(e -> toggleTheme());
        addControlButton(toolBar, themeButton);
        applyToolbarLabels(); // sets every button's text (or none) + the stateful faces

        statusBannerTimer.setRepeats(false);
        statusBanner.setOpaque(true);
        statusBanner.setVisible(false);
        statusBanner.setBackground(UIManager.getColor("ToolTip.background"));
        statusBanner.setForeground(UIManager.getColor("ToolTip.foreground"));
        Color statusBannerBorderColor = UIManager.getColor("ToolTip.borderColor");
        statusBanner.setBorder(BorderFactory.createCompoundBorder(
                BorderFactory.createLineBorder(
                        statusBannerBorderColor != null ? statusBannerBorderColor : statusBanner.getForeground()),
                BorderFactory.createEmptyBorder(6, 12, 6, 12)));
        JLayeredPane cardsLayer = new JLayeredPane() {
            @Override
            public void doLayout() {
                cards.setBounds(0, 0, getWidth(), getHeight());
                Dimension preferred = statusBanner.getPreferredSize();
                int width = Math.min(preferred.width, Math.max(getWidth() - 16, 0));
                statusBanner.setBounds((getWidth() - width) / 2, 8, width, preferred.height);
            }
        };
        cardsLayer.add(cards, JLayeredPane.DEFAULT_LAYER);
        cardsLayer.add(statusBanner, JLayeredPane.PALETTE_LAYER);

        JPanel sidebar = new JPanel(new BorderLayout());
        sidebarControlsPanel = sidebarControls();
        sidebar.add(sidebarControlsPanel, BorderLayout.NORTH);
        sidebar.add(sidebarScrollPane, BorderLayout.CENTER);
        sidebar.add(harnessBudgetPanel, BorderLayout.SOUTH);
        split = new JSplitPane(JSplitPane.HORIZONTAL_SPLIT, sidebar, cardsLayer);
        split.setDividerLocation(SIDEBAR_WIDTH);
        dividerSize = split.getDividerSize();
        applySidebarBackground();

        setLayout(new BorderLayout());
        add(toolBar, BorderLayout.NORTH);
        add(split, BorderLayout.CENTER);
        setSize(1100, 700);
        setLocationByPlatform(true);


        // Step 4: status badges. Blocking daemon capture calls run on the virtual-thread
        // executor; results are published back via SwingUtilities.invokeLater, never inline.
        this.statusPoller = new SessionStatusPoller(host, backgroundExecutor, SwingUtilities::invokeLater,
                Clock.systemUTC());
        this.gracefulCloser = new GracefulCloser(host, Duration.ofMillis(250),
                Duration.ofSeconds(10), Duration.ofSeconds(5));
        this.statusPollTimer = new Timer(statusPollIntervalMs, e -> pollLiveSessions());
        statusPollTimer.setInitialDelay(500);
        if (statusPollingEnabled) {
            statusPollTimer.start();
        }
        this.activeTabPollTimer = new Timer(statusPollIntervalMs, e -> pollActiveTabOnly());
        activeTabPollTimer.setInitialDelay(500);
        applyActiveTabPollTimerState();
        harnessBudgetPanel.setRefreshAction(this::refreshHarnessBudgets);

        // Step 5: Ctrl+Tab / Ctrl+1..9 cycling, Cmd/Ctrl+T shell-here, Cmd/Ctrl+W
        // graceful close. Registered on the KeyboardFocusManager, not
        // as a component-level binding, because a focused terminal consumes key
        // events before they'd ever reach a JComponent InputMap.
        KeyboardFocusManager.getCurrentKeyboardFocusManager().addKeyEventDispatcher(keyEventDispatcher);

        sessionEvents.addSessionsChangedListener(sessionsChangedListener);
        sessionEvents.addSessionKilledListener(sessionKilledListener);

        refreshSidebar(null);
    }

    /**
     * Thread-safe hook for a session killed by something other than this window's Kill
     * (today: an agent's MCP {@code kill}): drops its terminal, poller state and
     * registry row on the EDT, exactly as a successful Kill does, then reconciles the
     * sidebar. Also reached through {@link SessionEvents#fireSessionKilled}.
     */
    public void sessionKilledExternally(String session) {
        SwingUtilities.invokeLater(() -> {
            if (disposed) {
                return;
            }
            dropSessionArtifacts(session);
            refreshSidebar(null);
        });
    }

    /** Applies {@code mcp.server}/{@code mcp.port} to {@link #mcpService} off the EDT
     * (binding is quick, but the token's first read may write settings), serialized so
     * the latest apply wins, and reports a bind failure in a dialog. A regenerated token
     * is saved first; a running server then restarts with it. */
    private void applyMcpServer(boolean enabled, int port, boolean regenerateToken) {
        mcpApplier.apply(enabled, AppSettings.clampMcpPort(port), regenerateToken);
    }

    /** Everything the window does on close short of exiting the JVM: stops the timers
     * and executors, detaches every terminal (kills nothing) and disposes. Separate
     * from the window listener so a test can tear a window down in-process. */
    void shutdown() {
        disposed = true;
        sessionEvents.removeSessionsChangedListener(sessionsChangedListener);
        sessionEvents.removeSessionKilledListener(sessionKilledListener);
        mcpApplier.close(); // a queued start must not undo the stop
        mcpService.stop();
        statusPollTimer.stop();
        activeTabPollTimer.stop();
        pulseTimer.stop();
        KeyboardFocusManager.getCurrentKeyboardFocusManager().removeKeyEventDispatcher(keyEventDispatcher);
        backgroundExecutor.shutdownNow();
        settingsExecutor.shutdown();
        try {
            if (!settingsExecutor.awaitTermination(1, TimeUnit.SECONDS)) {
                settingsExecutor.shutdownNow();
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            settingsExecutor.shutdownNow();
        }
        // Detach everything (tidy connections); kill nothing.
        for (SessionTerminal terminal : attached.values()) {
            terminal.detach();
        }
        dispose();
    }

    /** The empty selection offers the toolbar's New dialog directly in its message. */
    private JPanel defaultPanel() {
        JButton create = messageLink("New…", "New session");
        create.addActionListener(event -> openSession());
        FlowLayout messageLayout = new FlowLayout(FlowLayout.CENTER, 0, 0);
        messageLayout.setAlignOnBaseline(true);
        JPanel message = new JPanel(messageLayout);
        message.add(new JLabel("Select a session, or click "));
        message.add(create);
        message.add(new JLabel(" to start one."));
        JPanel panel = new JPanel(new GridBagLayout());
        panel.add(message);
        return panel;
    }

    private static JButton messageLink(String text, String accessibleName) {
        JButton link = new JButton("<html><u>" + text + "</u></html>");
        link.setFont(UIManager.getFont("Label.font").deriveFont(Font.BOLD));
        link.setContentAreaFilled(false);
        link.setBorder(BorderFactory.createEmptyBorder(0, 2, 0, 2));
        link.setCursor(Cursor.getPredefinedCursor(Cursor.HAND_CURSOR));
        link.getAccessibleContext().setAccessibleName(accessibleName);
        return link;
    }

    private JPanel placeholderPanel() {
        JPanel panel = new JPanel(new BorderLayout());
        panel.add(placeholderLabel, BorderLayout.CENTER);
        return panel;
    }

    /** The closed-session message offers the same Resume action as the context menu. */
    private JPanel deadSessionPanel() {
        JButton resume = messageLink("Resume…", "Resume session");
        resume.addActionListener(event -> {
            SidebarEntry selected = sidebarList.getSelectedValue();
            if (selected != null && selected.status() == SidebarEntry.Status.DEAD
                    && selected.sessionEntry() != null) {
                resumeSession(selected);
            }
        });
        FlowLayout messageLayout = new FlowLayout(FlowLayout.CENTER, 0, 0);
        messageLayout.setAlignOnBaseline(true);
        JPanel message = new JPanel(messageLayout);
        message.add(deadSessionLabel);
        message.add(resume);
        message.add(new JLabel(" or right-click to remove it from the registry."));
        JPanel panel = new JPanel(new GridBagLayout());
        panel.add(message);
        return panel;
    }

    /** Shared button chrome for the main control row and the sidebar view controls. */
    private static void configureControlButton(JButton button) {
        button.setFocusable(false);
        button.setIconTextGap(5);
        button.setMargin(new Insets(3, 8, 3, 8));
    }

    /** Transparent at rest, with FlatLaf's normal hover/pressed feedback intact. */
    static void configureSidebarControlButton(JButton button) {
        configureControlButton(button);
        button.putClientProperty(FlatClientProperties.BUTTON_TYPE,
                FlatClientProperties.BUTTON_TYPE_TOOLBAR_BUTTON);
    }

    /** Adds a compact button with the same five-pixel rhythm used throughout both rows. */
    private static void addControlButton(JPanel row, JButton button) {
        if (row.getComponentCount() > 0) {
            row.add(Box.createHorizontalStrut(5));
        }
        row.add(button);
    }

    /**
     * Lets a labeled control compress narrower than its rendered text once the sidebar is
     * dragged in — Swing's default minimum size equals preferred size, and a BoxLayout row
     * sums its children's minimums, so long button text (e.g. "Sort: Session name") would
     * otherwise floor how far the split pane divider can be dragged.
     */
    private static void zeroMinimumWidth(Component component) {
        component.setMinimumSize(new Dimension(0, component.getPreferredSize().height));
    }

    /** A vertical group divider with balanced breathing room on either side. */
    private static void addControlSeparator(JPanel row) {
        row.add(Box.createHorizontalStrut(8));
        JSeparator separator = new JSeparator(SwingConstants.VERTICAL);
        separator.setPreferredSize(new Dimension(1, 20));
        separator.setMaximumSize(new Dimension(1, Integer.MAX_VALUE));
        row.add(separator);
        row.add(Box.createHorizontalStrut(3));
    }

    private void restoreSidebarViewSettings() {
        AppSettings.SidebarViewSettings saved = AppSettings.sidebarViewSettings();
        sidebarSort = SidebarView.SortMode.fromKey(saved.sort());
        sidebarSortDescending = saved.descending();
        for (SidebarView.FilterStatus status : SidebarView.FilterStatus.values()) {
            if (saved.hiddenStatuses().contains(status.key())) {
                visibleStatuses.remove(status);
            }
        }
        for (SidebarView.HarnessFamily family : SidebarView.HarnessFamily.values()) {
            if (saved.hiddenHarnessFamilies().contains(family.key())) {
                visibleHarnessFamilies.remove(family);
            }
        }
    }

    /**
     * Only the folder sort keeps a folder's sessions adjacent, so grouping follows the
     * setting and the current sort together; every other sort draws the plain rows.
     */
    private void applySidebarFolderGrouping() {
        sidebarCellRenderer.setFolderGrouping(
                sidebarFolderGroups && sidebarSort == SidebarView.SortMode.DIRECTORY_NAME);
    }

    /** Applies one menu change immediately, then queues its immutable settings snapshot. */
    private void applySidebarViewChange() {
        updateSidebarControlLabels();
        applySidebarFolderGrouping();
        rebuildVisibleSidebar(lastSelectedSessionName, false);

        Set<String> hiddenStatuses = new HashSet<>();
        for (SidebarView.FilterStatus status : SidebarView.FilterStatus.values()) {
            if (!visibleStatuses.contains(status)) {
                hiddenStatuses.add(status.key());
            }
        }
        Set<String> hiddenHarnesses = new HashSet<>();
        for (SidebarView.HarnessFamily family : SidebarView.HarnessFamily.values()) {
            if (!visibleHarnessFamilies.contains(family)) {
                hiddenHarnesses.add(family.key());
            }
        }
        String sort = sidebarSort.key();
        boolean descending = sidebarSortDescending;
        Set<String> statusesSnapshot = Set.copyOf(hiddenStatuses);
        Set<String> harnessesSnapshot = Set.copyOf(hiddenHarnesses);
        settingsExecutor.execute(() -> AppSettings.saveSidebarViewSettings(
                sort, descending, statusesSnapshot, harnessesSnapshot));
    }

    /** Compact view controls which belong to the sidebar rather than the app toolbar. */
    private JPanel sidebarControls() {
        configureSidebarControlButton(sortButton);
        sortButton.setIcon(LucidIcon.sort(14));
        sortButton.setToolTipText("Choose how sessions are sorted");
        sortButton.addActionListener(e -> showSortMenu());

        configureSidebarControlButton(filterButton);
        filterButton.setIcon(LucidIcon.funnel(14));
        filterButton.setToolTipText("Choose which session statuses are visible");
        filterButton.addActionListener(e -> showFilterMenu());

        configureSidebarControlButton(harnessFilterButton);
        harnessFilterButton.setIcon(LucidIcon.shell(14));
        harnessFilterButton.setToolTipText("Choose which harness families are visible");
        harnessFilterButton.addActionListener(e -> showHarnessFilterMenu());
        updateSidebarControlLabels();
        zeroMinimumWidth(sortButton);
        zeroMinimumWidth(filterButton);
        zeroMinimumWidth(harnessFilterButton);

        JPanel controls = new JPanel();
        controls.setLayout(new BoxLayout(controls, BoxLayout.X_AXIS));
        controls.setBorder(BorderFactory.createEmptyBorder(5, 5, 5, 5));
        JLabel heading = new JLabel("Sessions");
        heading.setFont(heading.getFont().deriveFont(Font.BOLD));
        heading.setBorder(BorderFactory.createEmptyBorder(3, 8, 3, 8));
        zeroMinimumWidth(heading);
        controls.add(heading);
        controls.add(Box.createHorizontalGlue());
        addControlButton(controls, sortButton);
        addControlButton(controls, filterButton);
        addControlButton(controls, harnessFilterButton);
        return controls;
    }

    private void showSortMenu() {
        JPopupMenu menu = new JPopupMenu();
        ButtonGroup group = new ButtonGroup();
        for (SidebarView.SortMode mode : SidebarView.SortMode.values()) {
            JRadioButtonMenuItem item = new JRadioButtonMenuItem(mode.label(), mode == sidebarSort);
            group.add(item);
            item.addActionListener(e -> {
                sidebarSort = mode;
                applySidebarViewChange();
            });
            menu.add(item);
        }
        menu.addSeparator();
        JCheckBoxMenuItem descending = new JCheckBoxMenuItem("Descending", sidebarSortDescending);
        descending.addActionListener(e -> {
            sidebarSortDescending = descending.isSelected();
            applySidebarViewChange();
        });
        menu.add(descending);
        menu.show(sortButton, 0, sortButton.getHeight());
    }

    private void showFilterMenu() {
        JPopupMenu menu = new JPopupMenu();
        for (SidebarView.FilterStatus status : SidebarView.FilterStatus.values()) {
            JCheckBoxMenuItem item = new JCheckBoxMenuItem(status.label(), visibleStatuses.contains(status));
            item.addActionListener(e -> {
                if (item.isSelected()) {
                    visibleStatuses.add(status);
                } else {
                    visibleStatuses.remove(status);
                }
                applySidebarViewChange();
            });
            menu.add(item);
        }
        menu.addSeparator();
        var showAll = menu.add("Show all statuses");
        showAll.setEnabled(visibleStatuses.size() != SidebarView.FilterStatus.values().length);
        showAll.addActionListener(e -> {
            visibleStatuses.addAll(EnumSet.allOf(SidebarView.FilterStatus.class));
            applySidebarViewChange();
        });
        var hideAll = menu.add("Hide all statuses");
        hideAll.setEnabled(!visibleStatuses.isEmpty());
        hideAll.addActionListener(e -> {
            visibleStatuses.clear();
            applySidebarViewChange();
        });
        menu.show(filterButton, 0, filterButton.getHeight());
    }

    private void showHarnessFilterMenu() {
        JPopupMenu menu = new JPopupMenu();
        for (SidebarView.HarnessFamily family : SidebarView.HarnessFamily.values()) {
            JCheckBoxMenuItem item = new JCheckBoxMenuItem(
                    family.label(), visibleHarnessFamilies.contains(family));
            if (family.harnessType() != null) {
                item.setIcon(HarnessIcons.forType(family.harnessType()));
            }
            item.addActionListener(e -> {
                if (item.isSelected()) {
                    visibleHarnessFamilies.add(family);
                } else {
                    visibleHarnessFamilies.remove(family);
                }
                applySidebarViewChange();
            });
            menu.add(item);
        }
        menu.addSeparator();
        var showAll = menu.add("Show all harnesses");
        showAll.setEnabled(visibleHarnessFamilies.size() != SidebarView.HarnessFamily.values().length);
        showAll.addActionListener(e -> {
            visibleHarnessFamilies.addAll(EnumSet.allOf(SidebarView.HarnessFamily.class));
            applySidebarViewChange();
        });
        var hideAll = menu.add("Hide all harnesses");
        hideAll.setEnabled(!visibleHarnessFamilies.isEmpty());
        hideAll.addActionListener(e -> {
            visibleHarnessFamilies.clear();
            applySidebarViewChange();
        });
        menu.show(harnessFilterButton, 0, harnessFilterButton.getHeight());
    }

    private void updateSidebarControlLabels() {
        int visible = visibleStatuses.size();
        int total = SidebarView.FilterStatus.values().length;
        int visibleHarnesses = visibleHarnessFamilies.size();
        int totalHarnesses = SidebarView.HarnessFamily.values().length;
        String sortSummary = "Sort: " + sidebarSort.label();
        String filterSummary = visible == total ? "Filter: All" : "Filter: " + visible + "/" + total;
        String harnessSummary = visibleHarnesses == totalHarnesses
                ? "Harness: All" : "Harness: " + visibleHarnesses + "/" + totalHarnesses;
        sortButton.setText(toolbarLabels ? sortSummary : null);
        filterButton.setText(toolbarLabels ? filterSummary : null);
        harnessFilterButton.setText(toolbarLabels ? harnessSummary : null);
        // Icon-only mode still exposes the current choices without spending sidebar width.
        sortButton.setToolTipText(sortSummary + " ("
                + (sidebarSortDescending ? "descending" : "ascending")
                + ") — choose how sessions are sorted");
        filterButton.setToolTipText(filterSummary + " — choose which statuses are visible");
        harnessFilterButton.setToolTipText(harnessSummary + " — choose which harness families are visible");
    }

    // ------------------------------------------------------------------
    // Sidebar refresh / reconciliation
    // ------------------------------------------------------------------

    /**
     * Reconciles the registry against the daemon off the EDT — listing is a socket
     * round trip, and a wedged daemon must never freeze painting — then
     * applies the result back on it. Out-of-order completion of rapid successive
     * refreshes is resolved by {@link #refreshTickets}: only the newest applies, and it
     * reselects the latest still-pending {@code reselect} target — so an MCP-triggered
     * refresh landing while the user's just-created session is being listed does not
     * cancel its selection.
     */
    private void refreshSidebar(String reselect) {
        long seq = refreshTickets.issue(reselect);
        backgroundExecutor.execute(() -> {
            ReconciliationResult result;
            try {
                result = Reconciler.reconcile(registry.sessions(), host.listSessions());
            } catch (SessionHostException e) {
                // its reselect target must not be applied by some later, unrelated refresh
                refreshTickets.failed(seq);
                SwingUtilities.invokeLater(() -> JOptionPane.showMessageDialog(this,
                        "The session daemon is unreachable: " + e.getMessage(), "Refresh failed",
                        JOptionPane.ERROR_MESSAGE));
                return;
            }
            SwingUtilities.invokeLater(() -> {
                if (refreshTickets.isCurrent(seq)) {
                    applySidebar(result, refreshTickets.takeReselect());
                }
            });
        });
    }

    /** EDT half of {@link #refreshSidebar}. */
    private void applySidebar(ReconciliationResult result, String reselect) {
        String toReselect = reselect != null ? reselect
                : sidebarList.getSelectedValue() != null ? sidebarList.getSelectedValue().sessionName() : null;

        // Carry each live row's last poll result across the rebuild: the no-dot state
        // means "no result yet", and acting on one session must not blank every other
        // session's badge until the next tick.
        Map<String, SidebarEntry> previousLive = new HashMap<>();
        for (SidebarEntry entry : allSidebarEntries) {
            if (entry.status() == SidebarEntry.Status.LIVE) {
                previousLive.put(entry.sessionName(), entry);
            }
        }

        // Sessions that left the daemon (killed externally, shell exited) leave a dead
        // connection/widget behind; evict it so reattach and Resume start clean, and so
        // Ctrl+Tab stops cycling onto ghosts.
        Set<String> live = new HashSet<>();
        for (SessionEntry entry : result.liveManaged()) {
            live.add(entry.sessionName());
        }
        Set<String> toEvict = new HashSet<>(attached.keySet());
        toEvict.addAll(attaching.keySet()); // an attach still in flight for a gone session lands closed
        toEvict.removeAll(live);
        for (String name : toEvict) {
            removeAttachment(name);
            statusPoller.forget(name);
        }
        allSidebarEntries.clear();
        for (SessionEntry entry : result.liveManaged()) {
            SidebarEntry sidebarEntry = SidebarEntry.live(entry);
            sidebarEntry.setAttached(attached.containsKey(entry.sessionName()));
            SidebarEntry previous = previousLive.get(entry.sessionName());
            if (previous != null) {
                if (previous.state() != null) {
                    sidebarEntry.setState(previous.state(), previous.stateReason());
                }
                sidebarEntry.setPaneTitle(previous.paneTitle());
            }
            allSidebarEntries.add(sidebarEntry);
        }
        for (SessionEntry entry : result.deadRegistered()) {
            allSidebarEntries.add(SidebarEntry.dead(entry));
        }
        ensurePulsing(); // carried-over WORKING states may need their dots breathing
        if (reselect != null) {
            lastSelectedSessionName = reselect;
        }
        rebuildVisibleSidebar(toReselect, toReselect != null);
        if (!budgetsLoaded) {
            budgetsLoaded = true;
            refreshHarnessBudgets();
        }
    }

    /** Rebuilds the visible projection without disturbing cached terminal attachments. */
    private void rebuildVisibleSidebar(String reselect, boolean activateReselected) {
        List<SidebarEntry> visible = allSidebarEntries.stream()
                .filter(entry -> SidebarView.isVisible(entry, visibleStatuses, visibleHarnessFamilies))
                .sorted(SidebarView.comparator(sidebarSort, sidebarSortDescending))
                .toList();

        SidebarEntry previouslySelected = sidebarList.getSelectedValue();

        rebuildingSidebar = true;
        try {
            listModel.clear();
            for (SidebarEntry entry : visible) {
                listModel.addElement(entry);
            }
            int selectedIndex = reselect == null ? -1 : indexOfSessionName(reselect);
            boolean reselectHiddenByFilter = reselect != null && selectedIndex < 0;
            if (selectedIndex < 0 && previouslySelected != null) {
                // The reselect target (e.g. a session just created by Cmd/Ctrl+T) may not
                // be visible under the current filters yet, or ever — don't drop the
                // user's still-live prior selection just because we can't find it.
                selectedIndex = indexOfSessionName(previouslySelected.sessionName());
            }
            if (selectedIndex >= 0) {
                sidebarList.setSelectedIndex(selectedIndex);
                sidebarList.ensureIndexIsVisible(selectedIndex);
            } else {
                sidebarList.clearSelection();
            }
            if (reselectHiddenByFilter) {
                showStatusBanner("'" + reselect + "' was created but is hidden by your current filter.");
            }
        } finally {
            rebuildingSidebar = false;
        }

        if (sidebarList.getSelectedValue() != null && activateReselected) {
            activateSelected();
        } else {
            SidebarEntry selected = sidebarList.getSelectedValue();
            updateWindowTitle(selected);
            updateSelectionButtons();
            if (selected == null) {
                cardLayout.show(cards, DEFAULT_CARD);
            }
        }
    }

    /** Shows {@link #statusBanner} over whichever card is currently displayed and
     * (re)starts its auto-hide timer. Safe to call repeatedly — a fresh message just
     * restarts the clock. */
    private void showStatusBanner(String text) {
        statusBanner.setText(text);
        statusBanner.setVisible(true);
        statusBanner.getParent().revalidate();
        statusBanner.getParent().repaint();
        statusBannerTimer.restart();
    }

    // ------------------------------------------------------------------
    // Selection -> lazy attach
    // ------------------------------------------------------------------

    /**
     * Reflects the current sidebar selection in the card area, attaching lazily if
     * needed. Called both by the selection listener (on an actual change) and directly
     * by the keyboard-cycling handlers below (which must re-focus the terminal even
     * when the selection index doesn't change, e.g. cycling with only one attached
     * session).
     */
    private void activateSelected() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        updateWindowTitle(entry);
        if (entry == null) {
            updateSelectionButtons();
            cardLayout.show(cards, DEFAULT_CARD);
            return;
        }
        lastSelectedSessionName = entry.sessionName();
        switch (entry.status()) {
            case LIVE -> {
                attachAndShow(entry);
                maybeCatchUpActiveTab(entry);
            }
            case DEAD -> {
                deadSessionLabel.setText("'" + entry.sessionName() + "' is dead — ");
                cardLayout.show(cards, "dead-session");
            }
        }
        // after attachAndShow, so the detach button sees the row's final attached state
        updateSelectionButtons();
    }

    /**
     * ONCE {@link AppSettings.ActiveTabPollMode}: catches up the moment a different
     * live session becomes the active tab, so its badge isn't stuck at a stale (or
     * never-known) value just because the periodic timer is off. Also refires for a
     * session whose last known state is {@code WORKING}/{@code WAITING_FOR_INPUT} — a
     * reading that was accurate once but, with the periodic timer off, nothing else
     * would ever re-check; without this, a session that finished and went idle would
     * look permanently busy and refuse to close. Hands off to
     * {@link #catchUpConfirmedState} on {@link #backgroundExecutor} — its bounded retry
     * loop blocks its calling thread, so it must not run here on the EDT. A no-op
     * whenever the periodic timer is already running (every live session is covered
     * every interval then) or the mode isn't ONCE. Rate-limited per session via
     * {@link #activeTabCatchUpAtMs} to {@link #statusPollIntervalMs} so a sidebar
     * rebuild that merely reselects the same still-busy tab (see
     * {@link #rebuildVisibleSidebar}) doesn't refire it many times a second.
     */
    private void maybeCatchUpActiveTab(SidebarEntry entry) {
        if (statusPollingEnabled || activeTabPollMode != AppSettings.ActiveTabPollMode.ONCE) {
            return;
        }
        SessionState lastPolled = entry.state();
        boolean staleOrUnknown = lastPolled == null
                || lastPolled == SessionState.WORKING
                || lastPolled == SessionState.WAITING_FOR_INPUT;
        if (!staleOrUnknown) {
            return;
        }
        String session = entry.sessionName();
        long now = System.currentTimeMillis();
        Long firedAt = activeTabCatchUpAtMs.get(session);
        if (firedAt != null && now - firedAt < statusPollIntervalMs) {
            return;
        }
        activeTabCatchUpAtMs.put(session, now);
        SessionEntry sessionEntry = entry.sessionEntry();
        if (sessionEntry != null) {
            backgroundExecutor.execute(() -> catchUpConfirmedState(sessionEntry, lastPolled));
        }
    }

    /** Window title: "<session name> — <project path> — micro-harness-manager" for the
     * selected session (path omitted when unknown), or just the app name when nothing
     * is selected. */
    private void updateWindowTitle(SidebarEntry entry) {
        if (entry == null) {
            setTitle(APP_NAME);
            return;
        }
        String path = entry.abbreviatedPath();
        String sessionName = ellipsizeRight(entry.displayName(), WINDOW_TITLE_SESSION_MAX_CHARS);
        setTitle(sessionName + (path.isEmpty() ? "" : " — " + path) + " — " + APP_NAME);
    }

    /** Unicode-safe right ellipsis used where Swing cannot expose the native title
     * bar's available pixel width. Sidebar rows use pixel-aware JLabel clipping. */
    static String ellipsizeRight(String text, int maxCodePoints) {
        int length = text.codePointCount(0, text.length());
        if (length <= maxCodePoints) {
            return text;
        }
        if (maxCodePoints <= 1) {
            return "…";
        }
        int end = text.offsetByCodePoints(0, maxCodePoints - 1);
        return text.substring(0, end).stripTrailing() + "…";
    }

    /**
     * Attaches lazily on first selection only; re-selecting an already-attached session
     * just swaps the visible card — the connection and widget are untouched. A cached
     * terminal whose connection died (session killed externally, shell exited) is
     * evicted and replaced with a fresh attach instead of being shown as a frozen corpse.
     *
     * <p>The attach itself is asynchronous: {@code host.attach} may block on a daemon
     * connect, so the connection is opened on the background
     * executor and the card lands via {@link #landAttach}. Meanwhile the card area shows
     * an "Attaching…" placeholder, and re-selecting the row never starts a second attach
     * for the same session.
     */
    private void attachAndShow(SidebarEntry entry) {
        String name = entry.sessionName();
        SessionTerminal terminal = attached.get(name);
        if (terminal != null && !terminal.isAlive()) {
            removeAttachment(name);
            statusPoller.forget(name); // a dead connection means that session lifecycle ended
            terminal = null;
        }
        if (terminal != null) {
            cardLayout.show(cards, name);
            terminal.focus();
            return;
        }
        if (!attaching.containsKey(name)) {
            int generation = bumpAttachGeneration(name);
            attaching.put(name, generation);
            boolean disableMouseWheel = entry.harnessType() == HarnessType.CODEX
                    && AppSettings.codexMouseWheelDisabled();
            backgroundExecutor.execute(() -> {
                SessionConnection connection;
                try {
                    connection = host.attach(name, SessionTerminal.COLUMNS, SessionTerminal.ROWS);
                } catch (SessionHostException e) {
                    SwingUtilities.invokeLater(() -> failAttach(name, generation, e.getMessage()));
                    return;
                }
                SwingUtilities.invokeLater(() -> landAttach(name, generation, connection, disableMouseWheel));
            });
        }
        // landAttach re-dispatches for a row that may no longer be selected: the
        // placeholder must not cover whichever other session's terminal is showing
        if (isSelected(name)) {
            placeholderLabel.setText("<html>Attaching to '" + name + "'…</html>");
            cardLayout.show(cards, PLACEHOLDER_CARD);
        }
    }

    /** Bumps the session's attach generation so any attach in flight for it is stale. */
    private int bumpAttachGeneration(String name) {
        return attachGeneration.merge(name, 1, Integer::sum);
    }

    private boolean isCurrentAttach(String name, int generation) {
        return attachGeneration.getOrDefault(name, 0) == generation;
    }

    /** Drops the in-flight record for {@code generation} — and only that one, so a
     * newer attach dispatched in the meantime keeps its own entry. */
    private void settleInFlight(String name, int generation) {
        Integer ticket = attaching.get(name);
        if (ticket != null && ticket == generation) {
            attaching.remove(name);
        }
    }

    /**
     * EDT half of {@link #attachAndShow}. A superseded result (the generation moved on:
     * detach, kill, close, resume, an eviction) is closed and dropped. Otherwise the
     * terminal is built and cached regardless of the current
     * selection — this keeps the kept-alive model that Ctrl+Tab cycling, the detach
     * button and the attached dot rely on — and shown only if its row is still selected.
     */
    private void landAttach(String name, int generation, SessionConnection connection,
                            boolean disableMouseWheel) {
        settleInFlight(name, generation);
        if (!isCurrentAttach(name, generation)) {
            connection.close();
            return;
        }
        SidebarEntry row = findSidebarEntry(name);
        SessionTerminal terminal = SessionTerminal.open(connection, disableMouseWheel,
                terminalFontFamily, terminalFontSize);
        applyTerminalBackground(terminal);
        attached.put(name, terminal);
        if (!attachOrder.contains(name)) {
            attachOrder.add(name);
        }
        cards.add(terminal.component(), name);
        if (row != null) {
            row.setAttached(true); // never the entry captured at dispatch — applySidebar rebuilds entries
        }
        sidebarList.repaint();
        ensurePulsing(); // attaching unveils the row — its working dot starts breathing
        updateSelectionButtons();
        if (isSelected(name)) {
            cardLayout.show(cards, name);
            terminal.focus();
        }
    }

    /** EDT half of a failed attach: shown in the card area only while the row is still
     * selected, so the previously visible session's terminal (and its keyboard focus)
     * never sits under a new selection — keystrokes must never land in the wrong harness. */
    private void failAttach(String name, int generation, String message) {
        settleInFlight(name, generation);
        if (isCurrentAttach(name, generation) && isSelected(name)) {
            placeholderLabel.setText("<html>Failed to attach to '" + name + "': " + message + "</html>");
            cardLayout.show(cards, PLACEHOLDER_CARD);
        }
    }

    private boolean isSelected(String name) {
        SidebarEntry selected = sidebarList.getSelectedValue();
        return selected != null && selected.sessionName().equals(name);
    }

    /** The current reconciled row for {@code name}, or null once it has left the sidebar. */
    private SidebarEntry findSidebarEntry(String name) {
        for (SidebarEntry entry : allSidebarEntries) {
            if (entry.sessionName().equals(name)) {
                return entry;
            }
        }
        return null;
    }

    // ---- test seams: sidebar selection, the card area and attach bookkeeping

    /** Selects {@code name}'s sidebar row exactly as a click would (the selection
     * listener attaches lazily); false if the row is not in the visible list. EDT only. */
    boolean selectSidebarRowForTesting(String name) {
        int index = indexOfSessionName(name);
        if (index < 0) {
            return false;
        }
        sidebarList.setSelectedIndex(index);
        return true;
    }

    /** The card currently showing in the card area. EDT only. */
    Component visibleCardForTesting() {
        for (Component card : cards.getComponents()) {
            if (card.isVisible()) {
                return card;
            }
        }
        return null;
    }

    /** The widget of {@code name}'s landed terminal, or null while it has none. EDT only. */
    Component terminalCardForTesting(String name) {
        SessionTerminal terminal = attached.get(name);
        return terminal != null ? terminal.component() : null;
    }

    /** Whether {@code name} has an attach in flight or landed. EDT only. */
    boolean hasAttachmentForTesting(String name) {
        return attaching.containsKey(name) || attached.containsKey(name);
    }

    /** Drops one terminal card, and invalidates any attach still in flight for the
     * session, without touching the host. */
    private void removeAttachment(String name) {
        bumpAttachGeneration(name);
        attaching.remove(name);
        SessionTerminal terminal = attached.remove(name);
        if (terminal != null) {
            terminal.detach();
            cards.remove(terminal.component());
        }
        attachOrder.remove(name);
    }

    // ------------------------------------------------------------------
    // Step 4: status polling
    // ------------------------------------------------------------------

    /** Polls every currently-live sidebar entry; dead entries are skipped entirely
     * (there's nothing meaningful for the poller to capture). */
    private void pollLiveSessions() {
        List<SessionEntry> live = new ArrayList<>();
        for (SidebarEntry entry : allSidebarEntries) {
            if (entry.status() == SidebarEntry.Status.LIVE) {
                live.add(entry.sessionEntry());
            }
        }
        if (!live.isEmpty()) {
            statusPoller.pollAll(live, this::onStatusResult);
        }
    }

    /** {@link #activeTabPollTimer}'s tick: re-polls only whatever is currently
     * selected, so the active tab's badge stays live without a capture for every
     * background one — {@link AppSettings.ActiveTabPollMode#SCHEDULED}. */
    private void pollActiveTabOnly() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry == null || entry.status() != SidebarEntry.Status.LIVE || entry.sessionEntry() == null) {
            return;
        }
        statusPoller.pollAll(List.of(entry.sessionEntry()), this::onStatusResult);
    }

    /** Starts or stops {@link #activeTabPollTimer} to match the current settings:
     * it only ever runs while the periodic {@link #statusPollTimer} is off and
     * {@link #activeTabPollMode} is {@code SCHEDULED} — otherwise every live session
     * is already covered, or nothing extra was asked for. Safe to call repeatedly;
     * {@code Timer.start()}/{@code stop()} are no-ops when already in that state. */
    private void applyActiveTabPollTimerState() {
        if (!statusPollingEnabled && activeTabPollMode == AppSettings.ActiveTabPollMode.SCHEDULED) {
            activeTabPollTimer.start();
        } else {
            activeTabPollTimer.stop();
        }
    }

    /** Loads one provider-level quota snapshot for every harness with a live session. */
    private void refreshHarnessBudgets() {
        int sequence = budgetRefreshSeq.incrementAndGet();
        EnumSet<HarnessType> activeHarnesses = HarnessBudgetPanel.budgetedHarnesses(
                SidebarView.activeHarnesses(allSidebarEntries));
        harnessBudgetPanel.showLoading(activeHarnesses);
        for (HarnessType harness : activeHarnesses) {
            backgroundExecutor.execute(() -> {
                try {
                    var snapshot = harnessUsageService.load(harness);
                    SwingUtilities.invokeLater(() -> {
                        if (sequence == budgetRefreshSeq.get()) {
                            harnessBudgetPanel.showSnapshot(harness, snapshot);
                        }
                    });
                } catch (Exception failure) {
                    SwingUtilities.invokeLater(() -> {
                        if (sequence == budgetRefreshSeq.get()) {
                            harnessBudgetPanel.showError(harness, failure);
                        }
                    });
                }
            });
        }
    }

    /** Always invoked on the EDT (see the {@code SwingUtilities::invokeLater} dispatcher
     * wired in the constructor) — safe to touch the list model and repaint directly. */
    private void onStatusResult(String sessionName, SessionStatusPoller.PollResult result) {
        for (SidebarEntry entry : allSidebarEntries) {
            if (entry.status() == SidebarEntry.Status.LIVE && entry.sessionName().equals(sessionName)) {
                SidebarView.FilterStatus oldStatus = SidebarView.filterStatus(entry);
                String oldDisplayName = entry.displayName();
                if (result.stateConfirmed()) {
                    entry.setState(result.classification().state(), result.classification().reason());
                }
                entry.setPaneTitle(result.paneTitle());
                SidebarView.FilterStatus newStatus = SidebarView.filterStatus(entry);
                boolean filterMembershipMayChange = oldStatus != newStatus
                        && visibleStatuses.size() != SidebarView.FilterStatus.values().length;
                boolean orderMayChange = sidebarSort == SidebarView.SortMode.STATUS && oldStatus != newStatus
                        || sidebarSort == SidebarView.SortMode.SESSION_NAME
                        && !oldDisplayName.equals(entry.displayName());
                if (filterMembershipMayChange || orderMayChange) {
                    rebuildVisibleSidebar(lastSelectedSessionName, false);
                } else {
                    int index = indexOfSessionName(sessionName);
                    if (index >= 0) {
                        sidebarList.repaint(sidebarList.getCellBounds(index, index));
                    }
                }
                ensurePulsing();
                if (entry.equals(sidebarList.getSelectedValue())) {
                    updateWindowTitle(entry); // a /rename must reach the window title too
                }
                return;
            }
        }
        // the session went dead/was removed between the poll firing and this result
        // landing — nothing to update, and the next refreshSidebar() already dropped it
    }

    /** Moves the sidebar's hover highlight to {@code index} (-1 for none), repainting
     * only the two rows involved. */
    private void setSidebarHover(int index) {
        Object previous = sidebarList.getClientProperty(SidebarCellRenderer.HOVER_INDEX);
        int old = previous instanceof Integer i ? i : -1;
        if (old == index) {
            return;
        }
        sidebarList.putClientProperty(SidebarCellRenderer.HOVER_INDEX, index < 0 ? null : index);
        for (int row : new int[]{old, index}) {
            if (row >= 0 && row < listModel.size()) {
                sidebarList.repaint(sidebarList.getCellBounds(row, row));
            }
        }
    }

    /** One pulse frame: repaint every pulsing row; none left means the animation is
     * over and the timer stops itself. */
    private void repaintPulsingDots() {
        boolean any = false;
        for (int i = 0; i < listModel.size(); i++) {
            if (isPulsing(listModel.get(i))) {
                any = true;
                sidebarList.repaint(sidebarList.getCellBounds(i, i));
            }
        }
        if (!any) {
            pulseTimer.stop();
        }
    }

    /** Only the attached working dot breathes — a veiled (not-attached) row keeps its
     * dot still, so the reticule reads as the row's own quiet. */
    private static boolean isPulsing(SidebarEntry entry) {
        return entry.status() == SidebarEntry.Status.LIVE && entry.isAttached()
                && entry.state() == SessionState.WORKING;
    }

    /** Cheap to call on any state/attachment change: a spurious start is undone by the
     * next tick's self-stop. */
    private void ensurePulsing() {
        if (!pulseTimer.isRunning()) {
            pulseTimer.start();
        }
    }

    // ------------------------------------------------------------------
    // Step 5: Chrome-style keyboard cycling
    // ------------------------------------------------------------------

    /**
     * Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+1..9, plus Cmd/Ctrl+T (new shell at the selected
     * session's path), Cmd/Ctrl+W (graceful close), Cmd/Ctrl+D (duplicate the selected
     * session), Cmd/Ctrl +/- (global terminal zoom), and the
     * optional bare Page Up/Down and Home/End mapping to the terminal's scrollback,
     * dispatched globally because a focused terminal consumes key events before
     * a component-level InputMap binding would ever see them. Only acts while this
     * window is the focused window (so a modal dialog on top, or focus on some other
     * app, leaves these keys alone), and always consumes the keys it handles so they
     * never reach the terminal.
     *
     * <p>The T and W bindings use the platform menu-shortcut modifier — Cmd on macOS,
     * Ctrl elsewhere — deliberately: binding the Ctrl chords on macOS too would steal
     * readline's transpose-chars (Ctrl+T) and unix-word-rubout (Ctrl+W) from every
     * shell pane, while the Cmd chords are the platform's own tab gestures and reach no
     * terminal anyway. D carries no such readline binding, so it uses the same platform
     * mask for consistency with the other session-management shortcuts.
     */
    private boolean handleGlobalKeyEvent(KeyEvent e) {
        if (e.getID() != KeyEvent.KEY_PRESSED || !isFocused()) {
            return false;
        }
        if (pageKeys && e.getModifiersEx() == 0 && canScrollSelectedTerminal()) {
            boolean handled = switch (e.getKeyCode()) {
                case KeyEvent.VK_PAGE_UP -> {
                    scrollPage(true);
                    yield true;
                }
                case KeyEvent.VK_PAGE_DOWN -> {
                    scrollPage(false);
                    yield true;
                }
                case KeyEvent.VK_HOME -> {
                    jumpHistory(true);
                    yield true;
                }
                case KeyEvent.VK_END -> {
                    jumpHistory(false);
                    yield true;
                }
                default -> false;
            };
            if (handled) {
                e.consume();
                return true;
            }
        }
        int menuMask = Toolkit.getDefaultToolkit().getMenuShortcutKeyMaskEx();
        int fontDelta = terminalFontDelta(
                e.getKeyCode(), e.getModifiersEx(), menuMask);
        if (fontDelta != 0) {
            adjustTerminalFontSize(fontDelta);
            e.consume();
            return true;
        }
        if (e.getKeyCode() == KeyEvent.VK_T && (e.getModifiersEx() & menuMask) == menuMask) {
            openShellAtSelection();
            e.consume();
            return true;
        }
        if (e.getKeyCode() == KeyEvent.VK_W && (e.getModifiersEx() & menuMask) == menuMask) {
            closeSelectedGracefully();
            e.consume();
            return true;
        }
        if (e.getKeyCode() == KeyEvent.VK_D && (e.getModifiersEx() & menuMask) == menuMask) {
            duplicateSelected();
            e.consume();
            return true;
        }
        if (e.getKeyCode() == KeyEvent.VK_COMMA && (e.getModifiersEx() & menuMask) == menuMask) {
            openSettingsDialog();
            e.consume();
            return true;
        }
        if ((e.getKeyCode() == KeyEvent.VK_DELETE || e.getKeyCode() == KeyEvent.VK_BACK_SPACE)
                && (e.getModifiersEx() & menuMask) == menuMask) {
            removeSelectedFromRegistry();
            e.consume();
            return true;
        }
        if ((e.getModifiersEx() & KeyEvent.CTRL_DOWN_MASK) == 0) {
            return false;
        }
        boolean shift = (e.getModifiersEx() & KeyEvent.SHIFT_DOWN_MASK) != 0;
        if (e.getKeyCode() == KeyEvent.VK_TAB) {
            cycleAttached(shift ? -1 : 1);
            e.consume();
            return true;
        }
        if (e.getKeyCode() >= KeyEvent.VK_1 && e.getKeyCode() <= KeyEvent.VK_9) {
            jumpToNthSidebarEntry(e.getKeyCode() - KeyEvent.VK_0);
            e.consume();
            return true;
        }
        return false;
    }

    /** Returns the global zoom step for a platform shortcut, or zero for any other key. */
    static int terminalFontDelta(int keyCode, int modifiers, int menuMask) {
        if ((modifiers & menuMask) != menuMask) {
            return 0;
        }
        return switch (keyCode) {
            case KeyEvent.VK_EQUALS, KeyEvent.VK_PLUS, KeyEvent.VK_ADD -> 1;
            case KeyEvent.VK_MINUS, KeyEvent.VK_SUBTRACT -> -1;
            default -> 0;
        };
    }

    /** Applies one Cmd/Ctrl +/- zoom step globally and persists the new point size. */
    private void adjustTerminalFontSize(int delta) {
        int adjusted = AppSettings.clampTerminalFontSize(terminalFontSize + delta);
        if (adjusted == terminalFontSize) {
            return;
        }
        terminalFontSize = adjusted;
        for (SessionTerminal terminal : attached.values()) {
            terminal.applyFont(terminalFontFamily, terminalFontSize);
        }
        String familyToSave = terminalFontFamily;
        int sizeToSave = terminalFontSize;
        settingsExecutor.execute(() -> AppSettings.saveTerminalFont(familyToSave, sizeToSave));
    }

    /**
     * Cycles forward/backward through {@link #attachOrder} — the order sessions were
     * first attached this run, i.e. Chrome's tab-strip order (fixed position), not MRU
     * (re-selecting a session never reorders it). Wraps at both ends. A no-op with zero
     * or one attached sessions.
     */
    private void cycleAttached(int direction) {
        // attachOrder is pruned on every sidebar refresh, but a session can die between
        // refreshes — cycle only over names that are attached right now and still have a
        // sidebar row, so Ctrl+Tab can neither land on a ghost nor wedge on one.
        List<String> cycle = new ArrayList<>();
        for (String name : attachOrder) {
            if (attached.containsKey(name) && indexOfSessionName(name) >= 0) {
                cycle.add(name);
            }
        }
        if (cycle.isEmpty()) {
            return;
        }
        SidebarEntry selected = sidebarList.getSelectedValue();
        String current = selected != null ? selected.sessionName() : null;
        int index = cycle.indexOf(current);
        int next = index < 0
                ? (direction > 0 ? 0 : cycle.size() - 1)
                : Math.floorMod(index + direction, cycle.size());
        selectBySessionName(cycle.get(next));
    }

    /**
     * Chrome semantics: Ctrl+1..8 jump to the nth visible sidebar entry (1-indexed);
     * Ctrl+9 always jumps to the <em>last</em> entry, regardless of how many there are.
     * Dead entries count towards the position the same as live ones — this
     * jumps to whatever row is visibly there, same as clicking it.
     */
    private void jumpToNthSidebarEntry(int n) {
        int size = listModel.size();
        if (size == 0) {
            return;
        }
        int index = (n == 9) ? size - 1 : n - 1;
        if (index < 0 || index >= size) {
            return;
        }
        sidebarList.setSelectedIndex(index);
        sidebarList.ensureIndexIsVisible(index);
        activateSelected();
    }

    private void selectBySessionName(String sessionName) {
        int index = indexOfSessionName(sessionName);
        if (index >= 0) {
            sidebarList.setSelectedIndex(index);
            sidebarList.ensureIndexIsVisible(index);
            activateSelected();
        }
    }

    private int indexOfSessionName(String sessionName) {
        for (int i = 0; i < listModel.size(); i++) {
            if (listModel.get(i).sessionName().equals(sessionName)) {
                return i;
            }
        }
        return -1;
    }

    // ------------------------------------------------------------------
    // Toolbar buttons acting on the selection
    // ------------------------------------------------------------------

    /**
     * Enables each selection-dependent toolbar button exactly when its action would do
     * something, mirroring the context menu's per-status offerings: shell-here needs any
     * row (a path to inherit), duplicate a registered one, detach or close a live one,
     * kill a live one; shutdown any live managed session at all, selected or not. Called
     * wherever the selection, a row's attachment, or the sidebar's contents change.
     */
    private void updateSelectionButtons() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        shellHereButton.setEnabled(entry != null);
        duplicateButton.setEnabled(entry != null && entry.sessionEntry() != null);
        boolean scrollable = canScrollSelectedTerminal();
        pageUpButton.setEnabled(scrollable);
        pageDownButton.setEnabled(scrollable);
        detachButton.setEnabled(entry != null && entry.status() == SidebarEntry.Status.LIVE
                && entry.isAttached());
        closeButton.setEnabled(entry != null && entry.status() == SidebarEntry.Status.LIVE);
        killButton.setEnabled(entry != null && entry.status() == SidebarEntry.Status.LIVE);
        shutdownButton.setEnabled(!liveManagedEntries().isEmpty());
        batchCloseButton.setEnabled(!liveManagedEntries().isEmpty());
        removeDeadButton.setEnabled(!deadEntries().isEmpty());
    }

    /** The same eligibility shared by the toolbar controls and their optional key mapping. */
    private boolean canScrollSelectedTerminal() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        return entry != null && entry.status() == SidebarEntry.Status.LIVE
                && attached.containsKey(entry.sessionName());
    }

    /** The selected session's landed terminal, or null when there is none. */
    private SessionTerminal selectedTerminal() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        return entry == null ? null : attached.get(entry.sessionName());
    }

    /** Moves the terminal's scrollback one page without sending a key into the harness:
     * the daemon has no server-side history, so the widget pages its own. */
    private void scrollPage(boolean up) {
        SessionTerminal terminal = selectedTerminal();
        if (terminal == null) {
            return;
        }
        if (up) {
            terminal.pageUp();
        } else {
            terminal.pageDown();
        }
    }

    /** Home jumps to the oldest scrollback; End returns to live output. */
    private void jumpHistory(boolean top) {
        SessionTerminal terminal = selectedTerminal();
        if (terminal == null) {
            return;
        }
        if (top) {
            terminal.scrollToTop();
        } else {
            terminal.scrollToBottom();
        }
    }

    /** Every sidebar row that is a live, registered session — shutdown's working set. */
    private List<SidebarEntry> liveManagedEntries() {
        List<SidebarEntry> live = new ArrayList<>();
        for (SidebarEntry entry : allSidebarEntries) {
            if (entry.status() == SidebarEntry.Status.LIVE && entry.sessionEntry() != null) {
                live.add(entry);
            }
        }
        return live;
    }

    /** Every sidebar row for a stopped, registered session — Remove dead sessions' working
     * set, and {@link BatchRemoveDeadDialog}'s default "select everything". */
    private List<SidebarEntry> deadEntries() {
        List<SidebarEntry> dead = new ArrayList<>();
        for (SidebarEntry entry : allSidebarEntries) {
            if (entry.status() == SidebarEntry.Status.DEAD) {
                dead.add(entry);
            }
        }
        return dead;
    }

    /** Snapshot the user-visible identity and latest known state for a pre-flight. */
    private PreflightDialog.Session preflightSession(SidebarEntry entry) {
        String status;
        if (entry.status() == SidebarEntry.Status.DEAD) {
            status = "already stopped";
        } else if (entry.state() == null) {
            status = "live; status pending";
        } else {
            status = switch (entry.state()) {
                case WORKING -> "working";
                case WAITING_FOR_INPUT -> "waiting for input";
                case IDLE -> "idle";
            };
        }
        return new PreflightDialog.Session(entry.displayName(), entry.sessionName(), status);
    }

    /**
     * The toolbar's Shutdown: gracefully closes every live managed session, each through
     * the same ladder as Close — refuse while busy, ask the harness to quit itself, wait
     * for the shell to exit. Sessions that refuse or time out are left running and
     * reported together in one dialog at the end, not one popup per session. Dead rows
     * have nothing left to close.
     */
    private void shutdownAll() {
        List<SidebarEntry> live = liveManagedEntries();
        if (live.isEmpty()) {
            return;
        }
        List<PreflightDialog.Session> sessions = live.stream()
                .map(this::preflightSession)
                .toList();
        if (!PreflightDialog.show(this, PreflightDialog.closeAll(sessions))) {
            return;
        }
        record Target(SessionEntry entry, SessionState lastPolled) {
        }
        List<Target> targets = new ArrayList<>();
        for (SidebarEntry entry : live) {
            targets.add(new Target(entry.sessionEntry(), entry.state()));
        }
        backgroundExecutor.execute(() -> {
            List<String> closed = new ArrayList<>();
            List<String> leftRunning = new ArrayList<>();
            for (Target target : targets) {
                String name = target.entry().sessionName();
                try {
                    GracefulCloser.Result result = gracefulCloser.close(name,
                            HarnessPlugins.of(target.entry().harnessType()), target.lastPolled());
                    result.harnessSessionIdOpt()
                            .ifPresent(id -> registry.recordHarnessSessionId(name, id));
                    switch (result.outcome()) {
                        case CLOSED, ALREADY_GONE -> closed.add(name);
                        case BUSY_STATE -> leftRunning.add(name + " — " + result.detail());
                        case BUSY_FOREGROUND -> leftRunning.add(name + " — '" + result.detail()
                                + "' is still running in its pane");
                        case NO_QUIT_SYNTAX -> leftRunning.add(name + " — no verified graceful-quit syntax");
                        case QUIT_TIMEOUT, EXIT_TIMEOUT -> leftRunning.add(name + " — didn't exit in time");
                    }
                } catch (SessionHostException e) {
                    leftRunning.add(name + " — " + e.getMessage());
                }
            }
            SwingUtilities.invokeLater(() -> {
                for (String name : closed) {
                    dropRuntimeArtifacts(name);
                }
                if (!leftRunning.isEmpty()) {
                    JOptionPane.showMessageDialog(this,
                            "Left running:\n" + String.join("\n", leftRunning),
                            "Shutdown incomplete", JOptionPane.INFORMATION_MESSAGE);
                }
                refreshSidebar(null);
            });
        });
    }

    /**
     * The toolbar's Batch close…: lets the user hand-pick which live sessions to close —
     * grouped and pre-checked by folder, idle sessions selected by default — then runs
     * them through the same graceful-close ladder as Close/Shutdown while showing live
     * progress and a final summary of whatever couldn't be closed.
     */
    private void openBatchCloseDialog() {
        List<SidebarEntry> live = liveManagedEntries();
        if (live.isEmpty()) {
            return;
        }
        BatchCloseDialog.show(this, live, gracefulCloser, registry, backgroundExecutor,
                this::dropRuntimeArtifacts, () -> refreshSidebar(null));
    }

    /**
     * The toolbar's Remove dead sessions…: lets the user hand-pick which stopped sessions
     * to forget from the registry — the batch twin of the context menu's per-row "Remove
     * from registry". Every dead session is pre-selected; unchecking a folder or session
     * keeps it around as a resumable dead row.
     */
    private void openBatchRemoveDeadDialog() {
        List<SidebarEntry> dead = deadEntries();
        if (dead.isEmpty()) {
            return;
        }
        BatchRemoveDeadDialog.show(this, dead, registry, statusPoller, backgroundExecutor,
                () -> refreshSidebar(null));
    }

    /** The toolbar's Duplicate — the context menu item's twin, on the selection. */
    private void duplicateSelected() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry != null && entry.sessionEntry() != null) {
            createSession(Path.of(entry.sessionEntry().projectPath()), entry.harnessType(), Optional.empty());
        }
    }

    /** Forgets a dead session: the context menu's "Remove from registry" action. */
    private void removeFromRegistry(SidebarEntry entry) {
        registry.remove(entry.sessionName());
        discardMcpConfig(entry.sessionName());
        statusPoller.forget(entry.sessionName());
        refreshSidebar(null);
    }

    /** Cmd/Ctrl+Delete's twin of {@link #removeFromRegistry}, on the selection. */
    private void removeSelectedFromRegistry() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry != null && entry.status() == SidebarEntry.Status.DEAD) {
            removeFromRegistry(entry);
        }
    }

    private void detachSelected() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry != null && entry.status() == SidebarEntry.Status.LIVE && entry.isAttached()) {
            detachSession(entry);
        }
    }

    private void killSelected() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry != null && entry.status() == SidebarEntry.Status.LIVE) {
            killSession(entry);
        }
    }

    // ------------------------------------------------------------------
    // Context menu
    // ------------------------------------------------------------------

    private void maybeShowPopup(MouseEvent e) {
        if (!e.isPopupTrigger()) {
            return;
        }
        // locationToIndex returns the *closest* row for any point, so a click in the
        // blank area below the list would otherwise select — and, via the selection
        // listener, attach — the last session and offer to kill it.
        int index = sidebarList.locationToIndex(e.getPoint());
        if (index < 0 || !sidebarList.getCellBounds(index, index).contains(e.getPoint())) {
            return;
        }
        sidebarList.setSelectedIndex(index);
        SidebarEntry entry = listModel.get(index);
        JPopupMenu menu = buildContextMenu(entry);
        menu.show(sidebarList, e.getX(), e.getY());
    }

    private JPopupMenu buildContextMenu(SidebarEntry entry) {
        JPopupMenu menu = new JPopupMenu();
        if (entry.sessionEntry() != null) {
            var rename = menu.add("Rename…");
            rename.addActionListener(e -> renameSession(entry));
            menu.addSeparator();
        }
        switch (entry.status()) {
            case LIVE -> {
                // the stop ladder, gentlest first: Detach keeps everything running,
                // Close asks the harness to quit itself, Kill SIGHUPs the session
                var detach = menu.add("Detach");
                detach.setIcon(LucidIcon.detach(16));
                detach.setEnabled(entry.isAttached());
                detach.addActionListener(e -> detachSession(entry));
                var close = menu.add("Close");
                close.setIcon(LucidIcon.x(16));
                close.addActionListener(e -> closeGracefully(entry));
                var reload = menu.add("Reload");
                reload.setIcon(LucidIcon.refresh(16));
                reload.addActionListener(e -> reloadSession(entry));
                var kill = menu.add("Kill session…");
                kill.setIcon(LucidIcon.zap(16));
                kill.addActionListener(e -> killSession(entry));
            }
            case DEAD -> {
                var resume = menu.add("Resume…");
                resume.addActionListener(e -> resumeSession(entry));
                var forget = menu.add("Remove from registry");
                forget.addActionListener(e -> removeFromRegistry(entry));
            }
        }
        menu.addSeparator();
        // the popup already selected this row (see maybeShowPopup), so the Cmd/Ctrl+T
        // handler's "at the selection" is exactly "at the clicked row"
        var newHere = menu.add("New here…");
        newHere.setIcon(LucidIcon.folderOpen(16));
        newHere.addActionListener(e -> openSessionAtSelection());
        var shellHere = menu.add("New shell here");
        shellHere.setIcon(LucidIcon.shellPlus(16));
        shellHere.addActionListener(e -> openShellAtSelection());
        if (entry.sessionEntry() != null) {
            // a fresh session of the same harness in the same project — no resume id,
            // so a dead row duplicates to a new life rather than resuming the old one
            var duplicate = menu.add("Duplicate");
            duplicate.setIcon(LucidIcon.duplicate(16));
            duplicate.addActionListener(e -> createSession(
                    Path.of(entry.sessionEntry().projectPath()), entry.harnessType(), Optional.empty()));
            var copyPath = menu.add("Copy path");
            copyPath.addActionListener(e -> Toolkit.getDefaultToolkit().getSystemClipboard()
                    .setContents(new StringSelection(entry.sessionEntry().projectPath()), null));
        }
        return menu;
    }

    /** Changes only the stable, user-facing sidebar name. The session key stays
     * untouched so live terminal cards, status polling, and harness resume ids remain
     * associated with the same session. Clear removes the override explicitly. */
    private void renameSession(SidebarEntry entry) {
        SessionEntry current = registry.find(entry.sessionName()).orElse(null);
        if (current == null) {
            return;
        }
        // The field represents only the persisted override. Repopulating it from the
        // detected name after Clear makes the override look uncleared when reopened.
        String initial = current.displayName() == null ? "" : current.displayName();
        JTextField nameField = new JTextField(initial, 28);

        JButton rename = new JButton("Rename");
        JButton clear = new JButton("Clear");
        JButton cancel = new JButton("Cancel");

        JPanel content = new JPanel();
        content.setLayout(new BoxLayout(content, BoxLayout.Y_AXIS));
        content.setBorder(BorderFactory.createEmptyBorder(8, 4, 8, 4));
        JLabel label = new JLabel("Custom sidebar name:");
        label.setAlignmentX(0f);
        nameField.setAlignmentX(0f);
        JLabel hint = new JLabel("Inherited from harness: " + entry.detectedName());
        hint.setAlignmentX(0f);
        content.add(label);
        content.add(Box.createVerticalStrut(6));
        content.add(nameField);
        content.add(Box.createVerticalStrut(8));
        content.add(hint);

        JOptionPane pane = new JOptionPane(
                content,
                JOptionPane.PLAIN_MESSAGE, JOptionPane.DEFAULT_OPTION, null,
                new Object[]{rename, clear, cancel}, rename);
        JDialog dialog = pane.createDialog(this, "Rename session");
        int[] choice = {-1};
        rename.addActionListener(e -> {
            choice[0] = 0;
            dialog.dispose();
        });
        clear.addActionListener(e -> {
            choice[0] = 1;
            dialog.dispose();
        });
        cancel.addActionListener(e -> dialog.dispose());
        DialogKeys.bindEscapeTo(dialog.getRootPane(), cancel);

        // Focus and select the editable label as soon as the modal dialog opens. Enter
        // in the field explicitly clicks Rename; the root default covers Enter from
        // elsewhere in the dialog as well.
        nameField.addActionListener(e -> rename.doClick());
        dialog.getRootPane().setDefaultButton(rename);
        SwingUtilities.invokeLater(() -> {
            nameField.requestFocusInWindow();
            nameField.selectAll();
        });
        dialog.setVisible(true);

        if (choice[0] != 0 && choice[0] != 1) {
            return;
        }
        registry.put(current.withDisplayName(choice[0] == 1 ? null : nameField.getText()));
        refreshSidebar(entry.sessionName());
    }

    /** Detach only: close the connection/widget, the session keeps running. */
    private void detachSession(SidebarEntry entry) {
        String name = entry.sessionName();
        removeAttachment(name);
        entry.setAttached(false);
        updateSelectionButtons(); // the detach button just disabled itself
        sidebarList.repaint();
        cardLayout.show(cards, PLACEHOLDER_CARD);
        placeholderLabel.setText("<html>'" + name + "' is detached (still running) — select it again to reattach.</html>");
    }

    private void killSession(SidebarEntry entry) {
        String name = entry.sessionName();
        if (!PreflightDialog.show(this, PreflightDialog.kill(preflightSession(entry)))) {
            return;
        }
        backgroundExecutor.execute(() -> {
            // Cleanup is conditional on the session actually being gone: a failed kill
            // must not orphan a still-running harness by deleting its registry entry
            // (the resume id in there is not recoverable from the daemon).
            boolean gone;
            String error = null;
            try {
                host.killSession(name);
                gone = true;
            } catch (SessionHostException e) {
                error = e.getMessage();
                boolean stillThere;
                try {
                    stillThere = host.hasSession(name);
                } catch (SessionHostException unknowable) {
                    stillThere = true; // can't tell — assume it survived, keep everything
                }
                gone = !stillThere;
            }
            boolean sessionGone = gone;
            String killError = error;
            SwingUtilities.invokeLater(() -> {
                if (sessionGone) {
                    dropSessionArtifacts(name);
                } else {
                    JOptionPane.showMessageDialog(this,
                            "Kill failed: " + killError
                                    + "\nThe session is still running; its registry entry is kept.",
                            "Kill failed", JOptionPane.ERROR_MESSAGE);
                }
                refreshSidebar(null);
            });
        });
    }

    /** Runtime state for a session lifecycle that has ended. The saved session stays in the
     * registry so reconciliation presents it as stopped and resumable. EDT only. */
    private void dropRuntimeArtifacts(String name) {
        removeAttachment(name);
        statusPoller.forget(name);
    }

    /** Runtime state plus the saved session. Reserved for explicit destructive actions
     * such as Kill and Remove from registry. EDT only. */
    private void dropSessionArtifacts(String name) {
        dropRuntimeArtifacts(name);
        registry.remove(name);
        discardMcpConfig(name);
    }

    /** Deletes a gone session's MCP config file (its copy of the token), off the EDT. */
    private void discardMcpConfig(String name) {
        backgroundExecutor.execute(() -> launcher.discardMcpConfig(name));
    }

    /**
     * Cmd/Ctrl+W: gracefully ends a selected live session via {@link #closeGracefully}.
     * Dead rows are left alone; forgetting a stopped session is available
     * only through the explicitly named "Remove from registry" action.
     */
    private void closeSelectedGracefully() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry == null) {
            return;
        }
        closeGracefully(entry);
    }

    /**
     * The context menu's "Close" (and Cmd/Ctrl+W's live-row half): gracefully ends the
     * session — the harness quits itself and the shell under it exits. The registry
     * entry remains as a stopped/resumable row. Refuses (with an explanation, via
     * {@link GracefulCloser}) while anything is in progress: a working agent, a pending
     * approval, or a foreground program like caffeinate.
     */
    private void closeGracefully(SidebarEntry entry) {
        if (entry.status() != SidebarEntry.Status.LIVE || entry.sessionEntry() == null) {
            return;
        }
        SessionEntry sessionEntry = entry.sessionEntry();
        SessionState lastPolled = entry.state();
        String name = sessionEntry.sessionName();
        HarnessPlugin plugin = HarnessPlugins.of(sessionEntry.harnessType());
        PreflightDialog.Session dialogSession = preflightSession(entry);
        backgroundExecutor.execute(() -> {
            try {
                SessionState resolved = catchUpConfirmedState(sessionEntry, lastPolled);
                Optional<GracefulCloser.Result> blocker = gracefulCloser.preflight(
                        name, plugin, resolved);
                SwingUtilities.invokeLater(() -> {
                    if (blocker.isPresent()) {
                        handleGracefulCloseResult(name, blocker.orElseThrow());
                    } else if (PreflightDialog.show(this, PreflightDialog.close(dialogSession))) {
                        executeGracefulClose(sessionEntry, plugin, resolved);
                    }
                });
            } catch (SessionHostException e) {
                SwingUtilities.invokeLater(() -> JOptionPane.showMessageDialog(this,
                        "Could not check whether '" + name + "' can close safely: " + e.getMessage(),
                        "Close pre-flight failed", JOptionPane.ERROR_MESSAGE));
            }
        });
    }

    /**
     * When the periodic status timer is off ({@link #statusPollingEnabled}), a session
     * that was never polled has no confirmed state — used both to unblock Close/Reload
     * (whose {@link GracefulCloser} safety check would otherwise refuse forever with no
     * history to say whether the harness is busy) and to back the ONCE active-tab
     * catch-up ({@link #maybeCatchUpActiveTab}). Runs a short, bounded catch-up here
     * instead — MUST be called off the EDT (it blocks the calling thread; every caller
     * hands it to {@code backgroundExecutor}) — by driving {@link #statusPoller}
     * directly until it produces a confirmed classification (or a few seconds pass).
     * {@link io.github.ghosthack.microhm.app.harness.StateDetector} needs at least two
     * samples to confirm anything — a single poll is never enough for a session that has
     * never been captured before — so this loops rather than trying once.
     *
     * <p>Re-verifies rather than trusting a stale {@code lastPolled} whenever it is
     * {@code WORKING} or {@code WAITING_FOR_INPUT}: with the periodic timer off, nothing
     * else would ever notice that harness went idle afterward, and Close/Reload would
     * refuse forever on a reading that was accurate once but has long since gone stale.
     * A confirmed {@code IDLE} is trusted as-is (no busy refusal depends on it being
     * fresh). A no-op (returns immediately) whenever the periodic timer is on — it is
     * already keeping every live session's reading current.
     */
    private SessionState catchUpConfirmedState(SessionEntry sessionEntry, SessionState lastPolled) {
        boolean staleOrUnknown = lastPolled == null
                || lastPolled == SessionState.WORKING
                || lastPolled == SessionState.WAITING_FOR_INPUT;
        if (!staleOrUnknown || statusPollingEnabled) {
            return lastPolled;
        }
        long deadline = System.nanoTime() + Duration.ofSeconds(7).toNanos();
        SessionState confirmed = null;
        while (confirmed == null && System.nanoTime() < deadline) {
            confirmed = pollOnceForConfirmedState(sessionEntry);
            if (confirmed == null) {
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
        return confirmed;
    }

    /** One on-demand capture through the same poller/detector the timer would use, so a
     * later real poll continues its quiescence timing rather than starting over. */
    private SessionState pollOnceForConfirmedState(SessionEntry sessionEntry) {
        CompletableFuture<SessionState> future = new CompletableFuture<>();
        statusPoller.pollAll(List.of(sessionEntry), (name, result) -> {
            onStatusResult(name, result);
            future.complete(result.stateConfirmed() ? result.classification().state() : null);
        });
        try {
            return future.get(3, TimeUnit.SECONDS);
        } catch (Exception e) {
            return null;
        }
    }

    /** Runs only after the read-only pre-flight found no blocker and the user confirmed. */
    private void executeGracefulClose(SessionEntry sessionEntry, HarnessPlugin plugin,
                                      SessionState lastPolled) {
        executeGracefulClose(sessionEntry, plugin, lastPolled, false);
    }

    /**
     * Same as above, but when {@code reloadAfter} is set and the close actually
     * succeeds, immediately relaunches the harness instead of leaving the row dead —
     * this is Reload's "quit, then reopen via the breadcrumb" in one action.
     */
    private void executeGracefulClose(SessionEntry sessionEntry, HarnessPlugin plugin,
                                      SessionState lastPolled, boolean reloadAfter) {
        String name = sessionEntry.sessionName();
        backgroundExecutor.execute(() -> {
            try {
                GracefulCloser.Result result = gracefulCloser.close(
                        name, plugin, lastPolled);
                // Persist the provider's exit receipt before the EDT drops terminal
                // artifacts. The registry row survives close and now knows exactly
                // which conversation Resume… (or Reload) must reopen.
                result.harnessSessionIdOpt()
                        .ifPresent(id -> registry.recordHarnessSessionId(name, id));
                boolean closedOk = result.outcome() == GracefulCloser.Outcome.CLOSED
                        || result.outcome() == GracefulCloser.Outcome.ALREADY_GONE;
                SwingUtilities.invokeLater(() -> {
                    if (reloadAfter && closedOk) {
                        dropRuntimeArtifacts(name);
                        SessionEntry reopened = registry.find(name).orElse(sessionEntry);
                        resumeSession(SidebarEntry.dead(reopened));
                    } else {
                        handleGracefulCloseResult(name, result);
                    }
                });
            } catch (SessionHostException e) {
                SwingUtilities.invokeLater(() -> JOptionPane.showMessageDialog(this,
                        "Graceful close of '" + name + "' failed: " + e.getMessage(),
                        "Close failed", JOptionPane.ERROR_MESSAGE));
            }
        });
    }

    /** EDT half of {@link #closeGracefully}: cleanup on success, an explanation
     * on refusal. Refusals leave the session fully intact — that's their point. */
    private void handleGracefulCloseResult(String name, GracefulCloser.Result result) {
        switch (result.outcome()) {
            case CLOSED, ALREADY_GONE -> {
                dropRuntimeArtifacts(name);
                refreshSidebar(null);
            }
            case BUSY_STATE -> JOptionPane.showMessageDialog(this,
                    "'" + name + "' is not closed: " + result.detail() + ".",
                    "Session busy", JOptionPane.INFORMATION_MESSAGE);
            case BUSY_FOREGROUND -> JOptionPane.showMessageDialog(this,
                    "'" + name + "' is not closed: '" + result.detail()
                            + "' is still running in its pane.",
                    "Session busy", JOptionPane.INFORMATION_MESSAGE);
            case NO_QUIT_SYNTAX -> JOptionPane.showMessageDialog(this,
                    "'" + result.detail() + "' has no verified graceful-quit syntax — use "
                            + "Kill session… to force it.",
                    "No quit syntax", JOptionPane.WARNING_MESSAGE);
            case QUIT_TIMEOUT -> {
                JOptionPane.showMessageDialog(this,
                        "Sent '" + result.detail() + "' but the harness in '" + name
                                + "' didn't exit in time — leaving the session as it is.",
                        "Close timed out", JOptionPane.WARNING_MESSAGE);
                refreshSidebar(null); // the quit may still land late; repaint whatever is true now
            }
            case EXIT_TIMEOUT -> {
                JOptionPane.showMessageDialog(this,
                        "Sent 'exit' but the shell in '" + name
                                + "' didn't end in time — something may still be running in it.",
                        "Close timed out", JOptionPane.WARNING_MESSAGE);
                refreshSidebar(null);
            }
        }
    }

    /**
     * The context menu's "Reload": gracefully ends the session exactly like Close, then
     * immediately relaunches the harness using the resume breadcrumb {@link
     * #executeGracefulClose} just captured — one action for "the harness auto-updated
     * and needs a restart" rather than a manual Close followed by Resume…. Same
     * busy/refusal handling as Close via {@link GracefulCloser}.
     */
    private void reloadSession(SidebarEntry entry) {
        if (entry.status() != SidebarEntry.Status.LIVE || entry.sessionEntry() == null) {
            return;
        }
        SessionEntry sessionEntry = entry.sessionEntry();
        SessionState lastPolled = entry.state();
        String name = sessionEntry.sessionName();
        HarnessPlugin plugin = HarnessPlugins.of(sessionEntry.harnessType());
        PreflightDialog.Session dialogSession = preflightSession(entry);
        backgroundExecutor.execute(() -> {
            try {
                SessionState resolved = catchUpConfirmedState(sessionEntry, lastPolled);
                Optional<GracefulCloser.Result> blocker = gracefulCloser.preflight(
                        name, plugin, resolved);
                SwingUtilities.invokeLater(() -> {
                    if (blocker.isPresent()) {
                        handleGracefulCloseResult(name, blocker.orElseThrow());
                    } else if (PreflightDialog.show(this, PreflightDialog.reload(dialogSession))) {
                        executeGracefulClose(sessionEntry, plugin, resolved, true);
                    }
                });
            } catch (SessionHostException e) {
                SwingUtilities.invokeLater(() -> JOptionPane.showMessageDialog(this,
                        "Could not check whether '" + name + "' can reload safely: " + e.getMessage(),
                        "Reload pre-flight failed", JOptionPane.ERROR_MESSAGE));
            }
        });
    }

    private void resumeSession(SidebarEntry entry) {
        SessionEntry sessionEntry = entry.sessionEntry();
        String name = sessionEntry.sessionName();
        // A fresh session lifecycle under the same name: reset quiescence timing,
        // and evict any terminal left over from the dead lifecycle — reusing its widget
        // would leave the resumed harness running headless behind a frozen display.
        statusPoller.forget(name);
        removeAttachment(name);
        backgroundExecutor.execute(() -> {
            try {
                launcher.resume(sessionEntry, () -> warnNoResumeSyntax(sessionEntry.harnessType()));
            } catch (SessionHostException e) {
                SwingUtilities.invokeLater(() -> {
                    JOptionPane.showMessageDialog(this, "Failed to resume '" + name + "': " + e.getMessage(),
                            "Resume failed", JOptionPane.ERROR_MESSAGE);
                    refreshSidebar(null); // reflect whatever half-state the failure left
                });
                return;
            }
            SwingUtilities.invokeLater(() -> refreshSidebar(name));
        });
    }

    // ------------------------------------------------------------------
    // Settings dialog
    // ------------------------------------------------------------------

    /**
     * Opens the settings dialog and, on Save, persists the choices (off the EDT — see
     * {@link #toggleTheme}) and applies what can be applied immediately: attached
     * terminals recolor to the new effective background and ANSI palette. The scrollbar
     * choice only reaches terminals attached from now on — it is baked in at attach
     * time, as the dialog says.
     */
    private void openSettingsDialog() {
        SettingsDialog.show(this, terminalFontFamily, terminalFontSize).ifPresent(result -> {
            pageKeys = result.pageKeys();
            toolbarPageButtons = result.toolbarPageButtons();
            toolbarStopLadder = result.toolbarStopLadder();
            toolbarBatchActions = result.toolbarBatchActions();
            sidebarBackground = result.sidebarBackground();
            rightPaneMatchesSidebar = result.rightPaneMatchesSidebar();
            toolbarMatchesSidebar = result.toolbarMatchesSidebar();
            sidebarSectionsMatchBackground = result.sidebarSectionsMatchBackground();
            terminalBackgroundOverride = result.backgroundOverride();
            applySidebarBackground();
            sidebarFocusBorderHidden = result.sidebarFocusBorderHidden();
            applySidebarFocusBorder();
            sidebarReticule = result.sidebarReticule();
            sidebarCellRenderer.setReticuleEnabled(sidebarReticule);
            sidebarFolderGroups = result.sidebarFolderGroups();
            applySidebarFolderGrouping();
            // Grouping changes row heights, which only a model rebuild makes the list
            // re-measure; a repaint alone would leave the old cell bounds in place.
            rebuildVisibleSidebar(lastSelectedSessionName, false);
            terminalFontFamily = result.fontFamily();
            terminalFontSize = AppSettings.clampTerminalFontSize(result.fontSize());
            statusPollIntervalMs = AppSettings.clampStatusPollIntervalMs(result.statusPollIntervalMs());
            statusPollTimer.setDelay(statusPollIntervalMs);
            activeTabPollTimer.setDelay(statusPollIntervalMs);
            statusPollingEnabled = result.statusPollingEnabled();
            if (statusPollingEnabled) {
                statusPollTimer.start();
            } else {
                statusPollTimer.stop();
            }
            activeTabPollMode = result.activeTabPollMode();
            applyActiveTabPollTimerState();
            settingsExecutor.execute(() -> {
                AppSettings.saveTerminalBackgroundOverride(result.backgroundOverride());
                AppSettings.saveTerminalPalette(result.palette());
                AppSettings.saveTerminalScrollbarHidden(result.scrollbarHidden());
                AppSettings.saveCodexMouseWheelDisabled(result.codexMouseWheelDisabled());
                AppSettings.saveOptionAsMeta(result.optionAsMeta());
                AppSettings.savePageKeys(result.pageKeys());
                AppSettings.saveToolbarLabels(result.toolbarLabels());
                AppSettings.saveToolbarPageButtons(result.toolbarPageButtons());
                AppSettings.saveToolbarStopLadder(result.toolbarStopLadder());
                AppSettings.saveToolbarBatchActions(result.toolbarBatchActions());
                AppSettings.saveSidebarBackground(result.sidebarBackground());
                AppSettings.saveRightPaneMatchesSidebar(result.rightPaneMatchesSidebar());
                AppSettings.saveToolbarMatchesSidebar(result.toolbarMatchesSidebar());
                AppSettings.saveSidebarSectionsMatchBackground(result.sidebarSectionsMatchBackground());
                AppSettings.saveSidebarFocusBorderHidden(result.sidebarFocusBorderHidden());
                AppSettings.saveSidebarReticule(result.sidebarReticule());
                AppSettings.saveSidebarFolderGroups(result.sidebarFolderGroups());
                AppSettings.saveTerminalFont(result.fontFamily(), result.fontSize());
                AppSettings.saveStatusPollIntervalMs(result.statusPollIntervalMs());
                AppSettings.saveStatusPollingEnabled(result.statusPollingEnabled());
                AppSettings.saveActiveTabPollMode(result.activeTabPollMode());
                AppSettings.saveMcpServerEnabled(result.mcpServerEnabled());
                AppSettings.saveMcpPort(result.mcpPort());
            });
            if (SettingsDialog.mcpNeedsApply(result.mcpChanged(), result.mcpServerEnabled(),
                    mcpService.isRunning())) {
                applyMcpServer(result.mcpServerEnabled(), result.mcpPort(), result.mcpTokenRegenerated());
            }
            toolbarLabels = result.toolbarLabels();
            applyToolbarLabels();
            for (SessionTerminal terminal : attached.values()) {
                terminal.applyPalette(result.palette());
                terminal.applyFont(terminalFontFamily, terminalFontSize);
                terminal.applyOptionAsMeta(result.optionAsMeta());
            }
            for (SidebarEntry entry : allSidebarEntries) {
                SessionTerminal terminal = attached.get(entry.sessionName());
                if (terminal != null) {
                    terminal.applyMouseWheelDisabled(result.codexMouseWheelDisabled()
                            && entry.harnessType() == HarnessType.CODEX);
                }
            }
        });
    }

    /** Opens provider-account usage, initially scoped to the selected session's harness. */
    private void openUsageLimitsDialog() {
        SidebarEntry selected = sidebarList.getSelectedValue();
        HarnessType initial = selected == null ? HarnessType.CLAUDE_CODE : selected.harnessType();
        UsageLimitsDialog.show(this, backgroundExecutor, initial);
    }

    /** Re-resolves theme colors on startup, Settings Save and every theme switch. */
    private void applySidebarBackground() {
        Color panelBackground = UIManager.getColor("Panel.background");
        Color background = switch (sidebarBackground) {
            case DEFAULT -> UIManager.getColor("List.background");
            case UI_GRAY -> panelBackground;
            case TERMINAL -> uiTheme == AppSettings.UiTheme.LIGHT ? Color.WHITE : Color.BLACK;
        };
        sidebarList.setBackground(background);
        sidebarScrollPane.setBackground(background);
        sidebarScrollPane.getViewport().setBackground(background);
        applySidebarPanelBackground((Container) split.getLeftComponent(),
                sidebarSectionsMatchBackground ? background : panelBackground);
        // Continue the list's neutral edge through both surrounding sidebar sections.
        Color edge = UIManager.getColor("Component.borderColor");
        sidebarControlsPanel.setBorder(BorderFactory.createCompoundBorder(
                BorderFactory.createMatteBorder(0, 0, 0, 1, edge),
                BorderFactory.createEmptyBorder(5, 5, 5, 5)));
        harnessBudgetPanel.setBorder(BorderFactory.createCompoundBorder(
                BorderFactory.createMatteBorder(0, 0, 0, 1, edge),
                BorderFactory.createEmptyBorder(0, 0, 3, 0)));
        sidebarList.repaint();
        applyRightPaneBackground();
        applyToolbarBackground();
    }

    private void applyToolbarBackground() {
        Color background = toolbarMatchesSidebar
                ? sidebarList.getBackground() : UIManager.getColor("Panel.background");
        applySidebarPanelBackground(toolBar, background);
        applyToolbarButtonBackground(toolBar, true);
        applyToolbarButtonBackground((Container) split.getLeftComponent(), false);
        toolBar.repaint();
    }

    /** Use supported FlatLaf properties so button outlines survive every surface choice. */
    private void applyToolbarButtonBackground(Container container, boolean outline) {
        for (Component child : container.getComponents()) {
            if (child instanceof JButton button) {
                Color background = toolbarMatchesSidebar
                        ? sidebarList.getBackground() : UIManager.getColor("Button.background");
                Map<String, Object> style = new LinkedHashMap<>();
                if (outline || toolbarMatchesSidebar) {
                    Color border = toolbarBorderColor(background);
                    style.put("borderWidth", 1f);
                    style.put("borderColor", border);
                    style.put("disabledBorderColor", border);
                    style.put("focusedBorderColor", border);
                    style.put("hoverBorderColor", border);
                    style.put("pressedBorderColor", border);
                }
                if (toolbarMatchesSidebar) {
                    style.put("disabledBackground", background);
                }
                button.putClientProperty(FlatClientProperties.STYLE, style.isEmpty() ? null : style);
                button.setBackground(background);
            } else if (child instanceof Container nested) {
                applyToolbarButtonBackground(nested, outline);
            }
        }
    }

    /** Blend toward the contrasting pole using the actual fill, not just the app theme. */
    private static Color toolbarBorderColor(Color background) {
        double brightness = 0.2126 * background.getRed() + 0.7152 * background.getGreen()
                + 0.0722 * background.getBlue();
        int target = brightness < 128 ? 255 : 0;
        double blend = brightness < 128 ? 0.35 : 0.22;
        return new Color(
                (int) Math.round(background.getRed() * (1 - blend) + target * blend),
                (int) Math.round(background.getGreen() * (1 - blend) + target * blend),
                (int) Math.round(background.getBlue() * (1 - blend) + target * blend));
    }

    /** Placeholder cards and terminal defaults follow the sidebar only while linked. */
    private void applyRightPaneBackground() {
        Color background = rightPaneMatchesSidebar
                ? sidebarList.getBackground() : UIManager.getColor("Panel.background");
        cards.setBackground(background);
        for (Component card : cards.getComponents()) {
            if (card instanceof Container container
                    && attached.values().stream().noneMatch(terminal -> terminal.component() == card)) {
                applySidebarPanelBackground(container, background);
            }
        }
        for (SessionTerminal terminal : attached.values()) {
            applyTerminalBackground(terminal);
        }
        cards.repaint();
    }

    private void applyTerminalBackground(SessionTerminal terminal) {
        if (rightPaneMatchesSidebar) {
            terminal.applyBackground(sidebarList.getBackground(), uiTheme == AppSettings.UiTheme.LIGHT);
        } else {
            terminal.applyBackground(terminalBackgroundOverride
                    .orElseGet(() -> AppSettings.TerminalBackground.forTheme(uiTheme)));
        }
    }

    private static void applySidebarPanelBackground(Container container, Color background) {
        if (container instanceof JPanel panel) {
            panel.setBackground(background);
        }
        for (Component child : container.getComponents()) {
            if (child instanceof Container nested) {
                applySidebarPanelBackground(nested, background);
            }
        }
    }

    /** Applies the sidebar-only focus treatment live without changing row selection paint. */
    private void applySidebarFocusBorder() {
        sidebarScrollPane.putClientProperty(FlatClientProperties.STYLE,
                sidebarFocusBorderHidden ? SIDEBAR_NO_FOCUS_BORDER_STYLE : null);
    }

    // ------------------------------------------------------------------
    // Sidebar collapse/expand
    // ------------------------------------------------------------------

    /**
     * Collapses the sidebar to nothing (the terminal takes the full width) or brings it
     * back at whatever width the divider last sat. Hiding the left component rather
     * than pinning the divider at 0 is what actually removes it — a JSplitPane keeps
     * its component's minimum size otherwise — and zeroing the divider size while
     * collapsed stops a stray drag from reopening a phantom split.
     */
    private void toggleSidebar() {
        if (sidebarCollapsed) {
            split.getLeftComponent().setVisible(true);
            split.setDividerSize(dividerSize);
            split.setDividerLocation(sidebarWidth);
        } else {
            sidebarWidth = Math.max(split.getDividerLocation(), 1); // a 0-width reopen would look stuck shut
            split.getLeftComponent().setVisible(false);
            split.setDividerSize(0);
        }
        sidebarCollapsed = !sidebarCollapsed;
        applySidebarButtonFace();
    }

    /** Like the theme button, the icon shows what a click does: the panel-left glyph
     * with its chevron tucking in while the sidebar is open, pointing back out while
     * it's collapsed. */
    private void applySidebarButtonFace() {
        // icon-only regardless of the labels setting: the glyph is the whole message
        sidebarButton.setIcon(sidebarCollapsed ? LucidIcon.panelLeftOpen(16) : LucidIcon.panelLeftClose(16));
        sidebarButton.setToolTipText(sidebarCollapsed ? "Show sidebar" : "Hide sidebar");
    }

    /**
     * Puts each icon-bearing control's text label on or takes it off, per the settings
     * toggle. Stateful controls route through their own appliers so their current
     * selection is also hidden in icon-only mode.
     */
    private void applyToolbarLabels() {
        openButton.setText(toolbarLabels ? "New…" : null);
        openHereButton.setText(toolbarLabels ? "New here" : null);
        shellHereButton.setText(toolbarLabels ? "Shell here" : null);
        duplicateButton.setText(toolbarLabels ? "Duplicate" : null);
        pageUpButton.setText(toolbarLabels ? "Page up" : null);
        pageDownButton.setText(toolbarLabels ? "Page down" : null);
        detachButton.setText(toolbarLabels ? "Detach" : null);
        closeButton.setText(toolbarLabels ? "Close" : null);
        killButton.setText(toolbarLabels ? "Kill" : null);
        shutdownButton.setText(toolbarLabels ? "Shutdown" : null);
        batchCloseButton.setText(toolbarLabels ? "Batch close…" : null);
        removeDeadButton.setText(toolbarLabels ? "Remove dead…" : null);
        usageButton.setText(toolbarLabels ? "Usage" : null);
        settingsButton.setText(toolbarLabels ? "Settings" : null);
        applyPageButtonsVisibility();
        applyStopLadderVisibility();
        applyBatchActionsVisibility();
        updateSidebarControlLabels();
        applySidebarButtonFace();
        applyThemeButtonFace();
    }

    /** Hides the optional page-button group cleanly, without leaving two separators. */
    private void applyPageButtonsVisibility() {
        pageButtonsGroup.setVisible(toolbarPageButtons);
    }

    /** Hides the stop-ladder group cleanly, without leaving orphan separators. */
    private void applyStopLadderVisibility() {
        stopLadderGroup.setVisible(toolbarStopLadder);
    }

    /** Hides the batch-actions group cleanly, without leaving an orphan separator. */
    private void applyBatchActionsVisibility() {
        batchActionsGroup.setVisible(toolbarBatchActions);
    }

    // ------------------------------------------------------------------
    // Theme toggle
    // ------------------------------------------------------------------

    /**
     * Switches the whole window between the FlatLaf mac dark and light looks, live.
     * Attached terminals follow: their default fg/bg pair flips with the theme
     * (explicit ANSI/256 colors programs painted with are untouched) — unless
     * {@code terminal.background} pins them to one background, in which case the
     * toggle leaves every terminal alone. New attaches pick the same choice up via
     * {@link AppSettings#terminalBackground()}. The native macOS title bar follows too,
     * via {@link MacWindowAppearance}.
     */
    private void toggleTheme() {
        uiTheme = uiTheme == AppSettings.UiTheme.DARK
                ? AppSettings.UiTheme.LIGHT
                : AppSettings.UiTheme.DARK;
        if (uiTheme == AppSettings.UiTheme.LIGHT) {
            FlatMacLightLaf.setup();
        } else {
            FlatMacDarkLaf.setup();
        }
        FlatLaf.updateUI();
        applySidebarBackground();
        MacWindowAppearance.apply(uiTheme);
        applyThemeButtonFace();
        // settings.properties is tiny, but it's still disk I/O — keep it off the EDT
        AppSettings.UiTheme toSave = uiTheme;
        settingsExecutor.execute(() -> AppSettings.saveUiTheme(toSave));
    }

    /** The button shows the look a click switches <em>to</em>: sun while dark, moon
     * while light. Icons are stroked in the button's own foreground, so they recolor
     * with the LaF on their own. */
    private void applyThemeButtonFace() {
        boolean dark = uiTheme == AppSettings.UiTheme.DARK;
        themeButton.setIcon(dark ? LucidIcon.sun(16) : LucidIcon.moon(16));
        themeButton.setText(!toolbarLabels ? null : dark ? "Light" : "Dark");
        themeButton.setToolTipText(dark ? "Switch to light theme" : "Switch to dark theme");
    }

    // ------------------------------------------------------------------
    // Open…
    // ------------------------------------------------------------------

    private void openSession() {
        showOpenDialog(null, null);
    }

    /**
     * The toolbar's open-here button: the "Open…" dialog, seeded with the selected
     * session's project path and harness — "another one of these, right there". A dead
     * row seeds the same way (its path and harness are registered); no selection just
     * opens the plain dialog.
     */
    private void openSessionAtSelection() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry == null) {
            openSession();
            return;
        }
        showOpenDialog(entry.sessionEntry().projectPath(), entry.harnessType());
    }

    /** Shows the (possibly seeded) "Open…" dialog and creates whatever it confirms. */
    private void showOpenDialog(String prefillPath, HarnessType prefillHarness) {
        Optional<OpenSessionDialog.Result> result = OpenSessionDialog.show(this, prefillPath, prefillHarness);
        if (result.isEmpty()) {
            return;
        }
        OpenSessionDialog.Result r = result.get();
        createSession(r.projectPath(), r.harnessType(), r.harnessSessionId());
    }

    /**
     * Creates and registers a new session running the given harness — shared by the
     * "Open…" dialog, the Duplicate action, and the Cmd/Ctrl+T shell shortcut. Must be
     * called on the EDT.
     */
    private void createSession(Path projectPath, HarnessType harnessType, Optional<String> harnessSessionId) {
        if (!openButton.isEnabled()) {
            return; // a create is already in flight — the same reentry guard as the button
        }
        if (!Files.isDirectory(projectPath)) {
            JOptionPane.showMessageDialog(this, "'" + projectPath + "' is not a directory.",
                    "Invalid path", JOptionPane.WARNING_MESSAGE);
            return;
        }
        // The create sequence makes several daemon round trips and sendKeys deliberately
        // sleeps 400ms — run it off the EDT; the disabled button doubles as reentry protection.
        openButton.setEnabled(false);
        backgroundExecutor.execute(() -> {
            try {
                String createdName = launcher.create(projectPath, harnessType, harnessSessionId,
                        Optional.empty(), Map.of(), () -> warnNoResumeSyntax(harnessType));
                SwingUtilities.invokeLater(() -> {
                    openButton.setEnabled(true);
                    refreshSidebar(createdName);
                });
            } catch (RuntimeException e) {
                // broader than SessionHostException on purpose: any escape here would leave the
                // Open button disabled for the rest of the run with no explanation
                SwingUtilities.invokeLater(() -> {
                    openButton.setEnabled(true);
                    JOptionPane.showMessageDialog(this, "Failed to create session: " + e.getMessage(),
                            "Open failed", JOptionPane.ERROR_MESSAGE);
                    refreshSidebar(null); // reflect whatever half-state the failure left
                });
            }
        });
    }

    /**
     * Cmd/Ctrl+T: a new shell session in the selected session's project directory —
     * "give me a terminal next to what I'm working on". Rows (live or dead) hand over
     * their registered project path. No selection is a silent no-op: there is nowhere to
     * inherit a path from.
     */
    private void openShellAtSelection() {
        SidebarEntry entry = sidebarList.getSelectedValue();
        if (entry == null) {
            return;
        }
        createSession(Path.of(entry.sessionEntry().projectPath()), HarnessType.SHELL, Optional.empty());
    }

    /** The launcher falls back to a fresh launch when a resume id is given but the
     * harness has no verified resume syntax — see {@link HarnessPlugin#resumeCommand};
     * this is its warning. Called from the background executor, so the dialog is
     * dispatched to the EDT. */
    private void warnNoResumeSyntax(HarnessType harnessType) {
        SwingUtilities.invokeLater(() -> JOptionPane.showMessageDialog(this,
                "'" + harnessType.id() + "' has no known resume syntax — starting a fresh session instead.",
                "No resume syntax", JOptionPane.WARNING_MESSAGE));
    }
}
