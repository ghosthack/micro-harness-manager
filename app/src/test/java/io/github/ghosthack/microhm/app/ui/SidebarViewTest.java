package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.state.SessionState;
import org.junit.jupiter.api.Test;

import javax.swing.DefaultListModel;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JPanel;
import java.awt.BorderLayout;
import java.awt.Component;
import java.awt.Container;
import java.time.Instant;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SidebarViewTest {

    @Test
    void persistedSortKeysRoundTripAndUnknownKeysFallBackToSession() {
        for (SidebarView.SortMode mode : SidebarView.SortMode.values()) {
            assertEquals(mode, SidebarView.SortMode.fromKey(mode.key()));
        }
        assertEquals(SidebarView.SortMode.SESSION_NAME,
                SidebarView.SortMode.fromKey("from-a-future-version"));
    }

    @Test
    void classifiesEveryVisibleStatusIncludingPendingAndLifecycleRows() {
        SidebarEntry working = live("mhm-working", "/work/working");
        working.setState(SessionState.WORKING, "test");
        SidebarEntry waiting = live("mhm-waiting", "/work/waiting");
        waiting.setState(SessionState.WAITING_FOR_INPUT, "test");
        SidebarEntry idle = live("mhm-idle", "/work/idle");
        idle.setState(SessionState.IDLE, "test");

        assertEquals(SidebarView.FilterStatus.WORKING, SidebarView.filterStatus(working));
        assertEquals(SidebarView.FilterStatus.WAITING_FOR_INPUT, SidebarView.filterStatus(waiting));
        assertEquals(SidebarView.FilterStatus.IDLE, SidebarView.filterStatus(idle));
        assertEquals(SidebarView.FilterStatus.STATUS_PENDING,
                SidebarView.filterStatus(live("mhm-pending", "/work/pending")));
        assertEquals(SidebarView.FilterStatus.DEAD,
                SidebarView.filterStatus(SidebarEntry.dead(session("mhm-dead", "/work/dead"))));
    }

    @Test
    void pendingLiveRowsShowAnHourglassTheSizeOfTheStatusDot() {
        SidebarEntry pending = live("mhm-pending", "/work/pending");
        var pendingIcon = SidebarCellRenderer.statusIcon(pending);
        assertNotNull(pendingIcon);
        pending.setState(SessionState.WORKING, "confirmed");
        var workingIcon = SidebarCellRenderer.statusIcon(pending);
        assertNotSame(pendingIcon, workingIcon);
        assertEquals(pendingIcon.getIconWidth(), workingIcon.getIconWidth());
    }

    @Test
    void deadSessionIconIsOnlyReticulatedWhenTheSettingIsEnabled() {
        SidebarEntry dead = SidebarEntry.dead(session("mhm-dead", "/work/dead"));

        assertNotSame(SidebarCellRenderer.statusIcon(dead, false),
                SidebarCellRenderer.statusIcon(dead, true));
    }

    @Test
    void classifiesEveryHarnessFamilyAndIntersectsItWithStatusFiltering() {
        for (HarnessType type : HarnessType.values()) {
            SidebarEntry entry = SidebarEntry.live(session("mhm-" + type.id(), "/work/" + type.id(), type));
            SidebarView.HarnessFamily expected = switch (type) {
                case CLAUDE_CODE -> SidebarView.HarnessFamily.CLAUDE_CODE;
                case CODEX -> SidebarView.HarnessFamily.CODEX;
                case CURSOR_AGENT -> SidebarView.HarnessFamily.CURSOR_AGENT;
                case GROK -> SidebarView.HarnessFamily.GROK;
                case OPENCODE -> SidebarView.HarnessFamily.OPENCODE;
                case PI -> SidebarView.HarnessFamily.PI;
                case MUSE -> SidebarView.HarnessFamily.MUSE;
                case SHELL -> SidebarView.HarnessFamily.SHELL;
            };
            assertEquals(expected, SidebarView.harnessFamily(entry));
        }

        SidebarEntry shell = live("mhm-shell", "/work/shell");
        assertFalse(SidebarView.isVisible(shell,
                EnumSet.allOf(SidebarView.FilterStatus.class),
                EnumSet.of(SidebarView.HarnessFamily.CODEX)));
        assertFalse(SidebarView.isVisible(shell,
                EnumSet.of(SidebarView.FilterStatus.DEAD),
                EnumSet.of(SidebarView.HarnessFamily.SHELL)));
        assertTrue(SidebarView.isVisible(shell,
                EnumSet.of(SidebarView.FilterStatus.STATUS_PENDING),
                EnumSet.of(SidebarView.HarnessFamily.SHELL)));
    }

    @Test
    void sortsByDisplayNameDirectoryBasenameAndStatus() {
        SidebarEntry alpha = live("mhm-z", "/work/alpha");
        alpha.setPaneTitle("Alpha title");
        alpha.setState(SessionState.IDLE, "test");
        SidebarEntry beta = live("mhm-a", "/work/beta");
        beta.setState(SessionState.WAITING_FOR_INPUT, "test");
        SidebarEntry dead = SidebarEntry.dead(session("mhm-dead", "/work/charlie"));
        List<SidebarEntry> entries = List.of(dead, beta, alpha);

        assertOrder(entries, SidebarView.SortMode.SESSION_NAME,
                "mhm-z", "mhm-a", "mhm-dead");
        assertOrder(entries, SidebarView.SortMode.DIRECTORY_NAME,
                "mhm-z", "mhm-a", "mhm-dead");
        assertOrder(entries, SidebarView.SortMode.STATUS,
                "mhm-a", "mhm-z", "mhm-dead");

        List<SidebarEntry> descending = new ArrayList<>(entries);
        descending.sort(SidebarView.comparator(SidebarView.SortMode.STATUS, true));
        assertEquals(List.of("mhm-dead", "mhm-z", "mhm-a"),
                descending.stream().map(SidebarEntry::sessionName).toList());
    }

    @Test
    void folderSortKeepsEachFolderContiguousEvenWhenBasenamesCollide() {
        List<SidebarEntry> entries = new ArrayList<>(List.of(
                live("mhm-a", "/work/one/project"),
                live("mhm-b", "/work/two/project"),
                live("mhm-c", "/work/one/project")));

        entries.sort(SidebarView.comparator(SidebarView.SortMode.DIRECTORY_NAME));

        assertEquals(List.of("mhm-a", "mhm-c", "mhm-b"),
                entries.stream().map(SidebarEntry::sessionName).toList());
        assertEquals("/work/one/project", SidebarView.folderGroupKey(entries.get(0)));
    }

    @Test
    void folderGroupingHeadsEachRunOnceAndDropsTheRepeatedPathBelow() {
        DefaultListModel<SidebarEntry> model = new DefaultListModel<>();
        model.addElement(live("mhm-a", "/work/project"));
        model.addElement(live("mhm-b", "/work/project"));
        model.addElement(live("mhm-c", "/work/other"));
        JList<SidebarEntry> list = new JList<>(model);
        SidebarCellRenderer renderer = new SidebarCellRenderer();
        renderer.setFolderGrouping(true);

        JLabel header = groupHeader(render(renderer, list, 0));
        assertTrue(header.isVisible());
        assertEquals("/work/project", header.getText());
        assertFalse(detail(render(renderer, list, 0)).isVisible());

        assertFalse(groupHeader(render(renderer, list, 1)).isVisible());
        assertFalse(detail(render(renderer, list, 1)).isVisible());

        // the next folder starts its own run under its own heading
        assertTrue(groupHeader(render(renderer, list, 2)).isVisible());
        assertEquals("/work/other", groupHeader(render(renderer, list, 2)).getText());
        assertFalse(detail(render(renderer, list, 2)).isVisible());

        renderer.setFolderGrouping(false);
        assertFalse(groupHeader(render(renderer, list, 0)).isVisible());
        assertTrue(detail(render(renderer, list, 0)).isVisible());
    }

    @Test
    void persistedRenameOverridesPaneTitleAndAppliesToDeadRows() {
        SessionEntry renamed = session("mhm-original", "/work/project").withDisplayName("My session");
        SidebarEntry live = SidebarEntry.live(renamed);
        live.setPaneTitle("Harness title");

        assertEquals("My session", live.displayName());
        assertEquals("Harness title", live.detectedName());
        assertEquals("My session", live.nameText());
        assertEquals("My session", SidebarEntry.dead(renamed).nameText());
    }

    @Test
    void activeHarnessesAreDeduplicatedAndIgnoreDeadSessions() {
        SidebarEntry codexOne = SidebarEntry.live(session("mhm-codex-1", "/work/a", HarnessType.CODEX));
        SidebarEntry codexTwo = SidebarEntry.live(session("mhm-codex-2", "/work/b", HarnessType.CODEX));
        SidebarEntry claude = SidebarEntry.live(session("mhm-claude", "/work/c", HarnessType.CLAUDE_CODE));
        SidebarEntry deadShell = SidebarEntry.dead(session("mhm-shell", "/work/d", HarnessType.SHELL));

        assertEquals(EnumSet.of(HarnessType.CODEX, HarnessType.CLAUDE_CODE),
                SidebarView.activeHarnesses(List.of(
                        codexOne, codexTwo, claude, deadShell)));
    }

    @Test
    void tooltipKeepsFullDisplayNameWhileWindowTitleEllipsisIsUnicodeSafe() {
        SidebarEntry entry = live("mhm-original", "/work/project");
        entry.setPaneTitle("A very long & detailed <Codex> session name");

        assertTrue(entry.tooltipText().contains(
                "A very long &amp; detailed &lt;Codex&gt; session name"));
        assertTrue(entry.tooltipText().contains("<br>mhm-original<br>shell"));
        assertEquals("A very lo…", MainWindow.ellipsizeRight(entry.displayName(), 10));
        assertEquals("😀a…", MainWindow.ellipsizeRight("😀abc", 3));
    }

    @Test
    void tooltipOfANeverRenamedSessionDoesNotRepeatItsName() {
        SidebarEntry entry = live("mhm-plain", "/work/project");

        assertTrue(entry.tooltipText().startsWith("<html><b>mhm-plain</b><br>shell"), entry.tooltipText());
    }

    @Test
    void harnessStatusGlyphsAreDroppedFromPaneTitleNames() {
        SidebarEntry entry = live("mhm-glyph", "/work/project");
        entry.setPaneTitle("✳ Refactor auth middleware");
        assertEquals("Refactor auth middleware", entry.displayName());
        entry.setPaneTitle("⠼ Refactor auth middleware");
        assertEquals("Refactor auth middleware", entry.displayName());
        // a bare mark carries no name: the previous one stays rather than blanking
        entry.setPaneTitle("✳");
        assertEquals("Refactor auth middleware", entry.displayName());
        // only a leading mark followed by a space is a status mark
        entry.setPaneTitle("v2 · draft");
        assertEquals("v2 · draft", entry.displayName());
    }

    @Test
    void onlyAWaitingRowCarriesTheAttentionPill() {
        DefaultListModel<SidebarEntry> model = new DefaultListModel<>();
        SidebarEntry waiting = live("mhm-waiting", "/work/a");
        waiting.setState(SessionState.WAITING_FOR_INPUT, "test");
        SidebarEntry working = live("mhm-working", "/work/b");
        working.setState(SessionState.WORKING, "test");
        model.addElement(waiting);
        model.addElement(working);
        model.addElement(SidebarEntry.dead(session("mhm-dead", "/work/c")));
        JList<SidebarEntry> list = new JList<>(model);
        SidebarCellRenderer renderer = new SidebarCellRenderer();

        assertTrue(pill(render(renderer, list, 0)).isVisible());
        assertFalse(pill(render(renderer, list, 1)).isVisible());
        assertFalse(pill(render(renderer, list, 2)).isVisible());
    }

    private static Component pill(JPanel cell) {
        return ((BorderLayout) cell.getLayout()).getLayoutComponent(BorderLayout.EAST);
    }

    private static JPanel render(SidebarCellRenderer renderer,
                                 JList<SidebarEntry> list, int index) {
        return (JPanel) renderer.getListCellRendererComponent(
                list, list.getModel().getElementAt(index), index, false, false);
    }

    private static JLabel groupHeader(JPanel cell) {
        return (JLabel) ((BorderLayout) cell.getLayout()).getLayoutComponent(BorderLayout.NORTH);
    }

    /** The row's muted path line: the second of the two stacked labels in the center
     * (the column also holds the glue that centers them vertically). */
    private static JLabel detail(JPanel cell) {
        Container lines = (Container) ((BorderLayout) cell.getLayout())
                .getLayoutComponent(BorderLayout.CENTER);
        return java.util.Arrays.stream(lines.getComponents())
                .filter(JLabel.class::isInstance).map(JLabel.class::cast)
                .skip(1).findFirst().orElseThrow();
    }

    private static void assertOrder(List<SidebarEntry> source, SidebarView.SortMode mode,
                                    String... expectedNames) {
        List<SidebarEntry> sorted = new ArrayList<>(source);
        sorted.sort(SidebarView.comparator(mode));
        assertEquals(List.of(expectedNames), sorted.stream().map(SidebarEntry::sessionName).toList());
    }

    private static SidebarEntry live(String name, String projectPath) {
        return SidebarEntry.live(session(name, projectPath));
    }

    private static SessionEntry session(String name, String projectPath) {
        return session(name, projectPath, HarnessType.SHELL);
    }

    private static SessionEntry session(String name, String projectPath, HarnessType harnessType) {
        return new SessionEntry(name, projectPath, harnessType, null, Instant.EPOCH);
    }
}
