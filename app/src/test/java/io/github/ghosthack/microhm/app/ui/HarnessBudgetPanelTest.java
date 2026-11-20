package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.usage.UsageSnapshot;
import org.junit.jupiter.api.Test;

import javax.swing.JProgressBar;
import java.awt.Component;
import java.awt.Container;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class HarnessBudgetPanelTest {

    @Test
    void excludesShellBecauseItHasNoProviderBudget() {
        assertEquals(Set.of(HarnessType.CLAUDE_CODE, HarnessType.CODEX),
                HarnessBudgetPanel.budgetedHarnesses(Set.of(
                        HarnessType.CLAUDE_CODE, HarnessType.CODEX, HarnessType.SHELL)));
    }

    @Test
    void selectsShortSessionAndLongTotalWindows() {
        UsageSnapshot snapshot = new UsageSnapshot("Codex", "test", List.of(
                limit("Codex · 1 week", 41, "2026-08-29T00:00:00Z"),
                limit("Codex · 5 hours", 12, "2026-08-22T05:00:00Z")),
                List.of(), Optional.empty());

        HarnessBudgetPanel.Summary summary = HarnessBudgetPanel.summarize(snapshot);

        assertEquals(88, summary.session().orElseThrow().availablePercent());
        assertEquals("Codex · 5 hours", summary.session().orElseThrow().description());
        assertEquals(59, summary.week().orElseThrow().availablePercent());
        assertEquals("Codex · 1 week", summary.week().orElseThrow().description());
        assertEquals(Instant.parse("2026-08-29T00:00:00Z"),
                summary.week().orElseThrow().resetsAt().orElseThrow());
        assertEquals(Optional.empty(), summary.fable());
        assertEquals(Optional.empty(), summary.credits());
    }

    @Test
    void turnsTimeUntilWeeklyResetIntoDaysAndBarProgress() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);

        assertEquals(new HarnessBudgetPanel.WeeklyReset(
                        3, 29, "3 days until weekly reset"),
                HarnessBudgetPanel.weeklyReset(
                        Optional.of(Instant.parse("2026-08-24T00:00:01Z")), clock).orElseThrow());
        assertEquals(new HarnessBudgetPanel.WeeklyReset(
                        1, 2, "1 day until weekly reset"),
                HarnessBudgetPanel.weeklyReset(
                        Optional.of(Instant.parse("2026-08-22T04:00:00Z")), clock).orElseThrow());
    }

    @Test
    void weeklyResetBarIsFullAtSevenDaysAndEmptyWhenDue() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);

        assertEquals(100, HarnessBudgetPanel.weeklyReset(
                Optional.of(Instant.parse("2026-08-29T00:00:00Z")), clock)
                .orElseThrow().remainingPercent());
        assertEquals(new HarnessBudgetPanel.WeeklyReset(0, 0, "Weekly reset due"),
                HarnessBudgetPanel.weeklyReset(
                        Optional.of(Instant.parse("2026-08-21T00:00:00Z")), clock).orElseThrow());
    }

    @Test
    void oneProviderWindowCanSupplyBothAvailableNumbers() {
        UsageSnapshot snapshot = new UsageSnapshot("Codex", "test", List.of(
                limit("Codex", 25, "2026-08-23T00:00:00Z")), List.of(), Optional.empty());

        HarnessBudgetPanel.Summary summary = HarnessBudgetPanel.summarize(snapshot);

        assertEquals(75, summary.session().orElseThrow().availablePercent());
        assertEquals(75, summary.week().orElseThrow().availablePercent());
    }

    @Test
    void preservesClaudeFableAsItsOwnBudget() {
        UsageSnapshot snapshot = new UsageSnapshot("Claude", "test", List.of(
                limit("Current session (5 hours)", 12, "2026-08-22T05:00:00Z"),
                limit("Current week (all models)", 41, "2026-08-29T00:00:00Z"),
                limit("Current week (Fable)", 63, "2026-08-29T00:00:00Z")),
                List.of(), Optional.empty());

        HarnessBudgetPanel.Summary summary = HarnessBudgetPanel.summarize(snapshot);

        assertEquals(59, summary.week().orElseThrow().availablePercent());
        assertEquals(37, summary.fable().orElseThrow().availablePercent());
        assertEquals("Current week (Fable)", summary.fable().orElseThrow().description());
    }

    @Test
    void creditMeteredAccountsWithNoRateLimitWindowsGetTheirOwnBudget() {
        UsageSnapshot snapshot = new UsageSnapshot("Claude", "test", List.of(
                limit("Monthly credits", 50)), List.of(), Optional.empty());

        HarnessBudgetPanel.Summary summary = HarnessBudgetPanel.summarize(snapshot);

        assertEquals(Optional.empty(), summary.session());
        assertEquals(Optional.empty(), summary.week());
        assertEquals(Optional.empty(), summary.fable());
        assertEquals(50, summary.credits().orElseThrow().availablePercent());
        assertEquals("Monthly credits", summary.credits().orElseThrow().description());
    }

    @Test
    void rendersACreditsBarWithADaysUntilMonthlyResetBar() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);
        HarnessBudgetPanel panel = new HarnessBudgetPanel(clock);
        UsageSnapshot snapshot = new UsageSnapshot("Claude", "test", List.of(
                limit("Monthly credits", 50)), List.of(), Optional.empty());

        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        panel.showSnapshot(HarnessType.CLAUDE_CODE, snapshot);

        assertEquals(List.of(50, 32), progressValues(panel));
    }

    @Test
    void turnsTimeUntilMonthlyResetIntoDaysAndBarProgress() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);

        assertEquals(new HarnessBudgetPanel.MonthlyReset(10, 32, "10 days until monthly reset"),
                HarnessBudgetPanel.monthlyReset(clock));
    }

    @Test
    void rendersNativeBarsForSessionWeekFableAndDays() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);
        HarnessBudgetPanel panel = new HarnessBudgetPanel(clock);
        UsageSnapshot snapshot = new UsageSnapshot("Claude", "test", List.of(
                limit("Current session (5 hours)", 12, "2026-08-22T05:00:00Z"),
                limit("Current week (all models)", 41, "2026-08-29T00:00:00Z"),
                limit("Current week (Fable)", 63, "2026-08-29T00:00:00Z")),
                List.of(), Optional.empty());

        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        panel.showSnapshot(HarnessType.CLAUDE_CODE, snapshot);

        assertEquals(List.of(88, 100, 59, 37, 100), progressValues(panel));
    }

    @Test
    void turnsTimeUntilSessionResetIntoHoursMinutesAndBarProgress() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);

        assertEquals(new HarnessBudgetPanel.SessionReset("4h35m", 92, "4h35m left in session"),
                HarnessBudgetPanel.sessionReset(
                        Optional.of(Instant.parse("2026-08-22T04:35:00Z")), clock).orElseThrow());
    }

    @Test
    void sessionResetBarIsFullAtFiveHoursAndEmptyWhenDue() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);

        assertEquals(100, HarnessBudgetPanel.sessionReset(
                Optional.of(Instant.parse("2026-08-22T05:00:00Z")), clock)
                .orElseThrow().remainingPercent());
        assertEquals(new HarnessBudgetPanel.SessionReset("0h00m", 0, "Session reset due"),
                HarnessBudgetPanel.sessionReset(
                        Optional.of(Instant.parse("2026-08-21T00:00:00Z")), clock).orElseThrow());
    }

    @Test
    void sessionResetOfADayOrMoreReadsAsDaysAndHours() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);

        assertEquals("4d 17h", HarnessBudgetPanel.sessionReset(
                Optional.of(Instant.parse("2026-08-26T17:13:00Z")), clock).orElseThrow().remaining());
        assertEquals("1d 0h", HarnessBudgetPanel.sessionReset(
                Optional.of(Instant.parse("2026-08-23T00:00:00Z")), clock).orElseThrow().remaining());
        assertEquals("23h59m", HarnessBudgetPanel.sessionReset(
                Optional.of(Instant.parse("2026-08-22T23:59:00Z")), clock).orElseThrow().remaining());
    }

    @Test
    void aFailedRefreshKeepsTheEarlierFigures() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);
        HarnessBudgetPanel panel = new HarnessBudgetPanel(clock);
        UsageSnapshot snapshot = new UsageSnapshot("Claude", "test", List.of(
                limit("Monthly credits", 50)), List.of(), Optional.empty());
        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        panel.showSnapshot(HarnessType.CLAUDE_CODE, snapshot);

        // the next refresh shows the old bars while it loads, and after it fails
        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        assertEquals(List.of(50, 32), progressValues(panel));
        panel.showError(HarnessType.CLAUDE_CODE, new java.io.IOException("HTTP 429"));
        assertEquals(List.of(50, 32), progressValues(panel));
        assertEquals(true, labelTexts(panel).contains("Not updated — showing earlier figures"));

        // a later success clears the stale note
        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        panel.showSnapshot(HarnessType.CLAUDE_CODE, snapshot);
        assertEquals(false, labelTexts(panel).contains("Not updated — showing earlier figures"));
    }

    @Test
    void aFailureWithNoEarlierFiguresSaysUnavailable() {
        HarnessBudgetPanel panel = new HarnessBudgetPanel(Clock.systemUTC());
        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        panel.showError(HarnessType.CLAUDE_CODE, new java.io.IOException("boom"));
        assertEquals(List.of(), progressValues(panel));
        assertEquals(true, labelTexts(panel).contains("Usage unavailable"));
    }

    @Test
    void foldingHidesTheBarsBehindAOneLineSummaryAndReportsIt() {
        Clock clock = Clock.fixed(Instant.parse("2026-08-22T00:00:00Z"), ZoneOffset.UTC);
        List<Boolean> saved = new ArrayList<>();
        HarnessBudgetPanel panel = new HarnessBudgetPanel(clock, false, saved::add);
        panel.showLoading(Set.of(HarnessType.CLAUDE_CODE));
        panel.showSnapshot(HarnessType.CLAUDE_CODE, new UsageSnapshot("Claude", "test", List.of(
                limit("Current session (5 hours)", 12, "2026-08-22T05:00:00Z")), List.of(), Optional.empty()));

        panel.setCollapsed(true);
        assertEquals(List.of(true), saved);
        assertEquals("Claude 88%", panel.collapsedSummaryText());
        assertEquals(true, labelTexts(panel).contains("Claude 88%"));

        panel.setCollapsed(false);
        assertEquals(List.of(true, false), saved);
    }

    private static List<String> labelTexts(Container root) {
        List<String> texts = new ArrayList<>();
        for (Component component : root.getComponents()) {
            if (component instanceof javax.swing.JLabel label && label.isVisible() && label.getText() != null) {
                texts.add(label.getText());
            }
            if (component instanceof Container child) {
                texts.addAll(labelTexts(child));
            }
        }
        return texts;
    }

    private static List<Integer> progressValues(Container root) {
        List<Integer> values = new ArrayList<>();
        for (Component component : root.getComponents()) {
            if (component instanceof JProgressBar bar) {
                values.add(bar.getValue());
            }
            if (component instanceof Container container) {
                values.addAll(progressValues(container));
            }
        }
        return values;
    }

    private static UsageSnapshot.Limit limit(String label, int used, String reset) {
        return new UsageSnapshot.Limit(label, used, Optional.of(Instant.parse(reset)), Optional.empty());
    }

    private static UsageSnapshot.Limit limit(String label, int used) {
        return new UsageSnapshot.Limit(label, used, Optional.empty(), Optional.empty());
    }
}
