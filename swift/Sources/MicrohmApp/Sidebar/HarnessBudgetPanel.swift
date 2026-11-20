import AppKit
import MicrohmCore

/// Harness-level provider quota summary shown below the session list (Java's
/// `HarnessBudgetPanel`): for each harness with a live session, how much of its session
/// and weekly budget is left, and how long until each resets.
final class HarnessBudgetPanel: NSView {

    struct Budget: Equatable {
        let availablePercent: Int
        let description: String
        let resetsAt: Date?
    }

    struct Summary: Equatable {
        let session: Budget?
        let week: Budget?
        let fable: Budget?
        let credits: Budget?
    }

    struct Reset: Equatable {
        let value: String
        let remainingPercent: Int
        let tooltip: String
    }

    private static let weekSeconds: Double = 7 * 86_400
    private static let sessionSeconds: Double = 5 * 3600

    var onRefresh: (() -> Void)?

    private let content = NSStackView()
    private let headingButton = NSButton()
    /// One line of what is left, shown in the header while the panel is collapsed.
    private let collapsedSummary = NSTextField(labelWithString: "")
    private static let collapsedKey = "MicrohmBudgetsCollapsed"
    private var collapsed = UserDefaults.standard.bool(forKey: HarnessBudgetPanel.collapsedKey) {
        didSet { UserDefaults.standard.set(collapsed, forKey: HarnessBudgetPanel.collapsedKey) }
    }
    private let refreshButton = NSButton()
    private var active: [HarnessType] = []
    private var snapshots: [HarnessType: UsageSnapshot] = [:]
    private var errors: [HarnessType: String] = [:]
    private var loading: Set<HarnessType> = []
    var now: () -> Date = Date.init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // the heading folds the panel away, for short windows and long session lists
        headingButton.isBordered = false
        headingButton.imagePosition = .imageTrailing
        headingButton.imageHugsTitle = true
        headingButton.target = self
        headingButton.action = #selector(toggleCollapsed(_:))
        headingButton.setButtonType(.momentaryChange)
        collapsedSummary.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        collapsedSummary.textColor = .tertiaryLabelColor
        collapsedSummary.lineBreakMode = .byTruncatingTail
        collapsedSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.showsBorderOnlyWhileMouseInside = true
        refreshButton.controlSize = .small
        refreshButton.image = HarnessIcons.symbol("arrow.clockwise", "Update budgets", pointSize: 10)
        refreshButton.imagePosition = .imageOnly
        refreshButton.toolTip = "Update budgets"
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        let header = NSStackView(views: [headingButton, collapsedSummary, NSView(), refreshButton])
        header.orientation = .horizontal

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8

        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 18, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    @objc func toggleCollapsed(_ sender: Any?) {
        collapsed.toggle()
        render()
    }

    private func updateHeading() {
        let title = NSAttributedString(string: "Budgets", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        headingButton.attributedTitle = title
        headingButton.image = HarnessIcons.symbol(collapsed ? "chevron.right" : "chevron.down",
                                                  collapsed ? "Show budgets" : "Hide budgets", pointSize: 8, weight: .semibold)
        headingButton.contentTintColor = .tertiaryLabelColor
        headingButton.toolTip = collapsed ? "Show budgets" : "Hide budgets"
        collapsedSummary.isHidden = !collapsed
        // collapsed: each harness's session budget (else its week) in one line
        collapsedSummary.stringValue = active.compactMap { harness -> String? in
            guard let snapshot = snapshots[harness] else { return nil }
            let summary = HarnessBudgetPanel.summarize(snapshot)
            guard let budget = summary.session ?? summary.week else { return nil }
            return "\(SidebarView.label(harness)) \(budget.availablePercent)%"
        }.joined(separator: " · ")
    }

    @objc private func refresh(_ sender: Any?) {
        onRefresh?()
    }

    /// Every harness except the plain shell has a provider budget.
    static func budgetedHarnesses(_ harnesses: [HarnessType]) -> [HarnessType] {
        harnesses.filter { $0 != .shell }
    }

    func showLoading(_ harnesses: [HarnessType]) {
        active = HarnessBudgetPanel.budgetedHarnesses(harnesses)
        let keep = Set(active)
        snapshots = snapshots.filter { keep.contains($0.key) }
        errors = errors.filter { keep.contains($0.key) }
        loading = keep
        refreshButton.isEnabled = active.isEmpty
        render()
    }

    func showSnapshot(_ harness: HarnessType, _ snapshot: UsageSnapshot) {
        guard active.contains(harness) else { return }
        snapshots[harness] = snapshot
        errors[harness] = nil
        loading.remove(harness)
        refreshButton.isEnabled = loading.isEmpty
        render()
    }

    func showError(_ harness: HarnessType, _ error: Error) {
        guard active.contains(harness) else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        // a failed refresh keeps the last figures on screen, marked as stale
        errors[harness] = message.isEmpty ? "Usage unavailable" : message
        loading.remove(harness)
        refreshButton.isEnabled = loading.isEmpty
        render()
    }

    private func render() {
        updateHeading()
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // emptied rather than hidden: a hidden arranged view loses its width constraint
        if collapsed { return }
        if active.isEmpty {
            content.addArrangedSubview(muted("No budgets available."))
            return
        }
        for harness in active {
            let row = harnessRow(harness)
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func harnessRow(_ harness: HarnessType) -> NSView {
        let icon = NSImageView(image: HarnessIcons.image(harness, size: 13))
        icon.contentTintColor = .labelColor
        let name = NSTextField(labelWithString: SidebarView.label(harness))
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let title = NSStackView(views: [icon, name])
        title.spacing = 5
        if snapshots[harness] != nil, let error = errors[harness] {
            // the last refresh failed; the figures below are from the one before
            let stale = NSImageView(image: HarnessIcons.symbol("exclamationmark.triangle", "Stale", pointSize: 10))
            stale.contentTintColor = .tertiaryLabelColor
            let tip = "Last refresh failed: \(error). Showing the earlier figures."
            stale.toolTip = tip
            name.toolTip = tip
            title.addArrangedSubview(stale)
        }
        let rows = NSStackView(views: [title])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        rows.translatesAutoresizingMaskIntoConstraints = false

        if loading.contains(harness), snapshots[harness] == nil {
            rows.addArrangedSubview(muted("Loading usage…"))
            return rows
        }
        if snapshots[harness] == nil, let error = errors[harness] {
            let label = muted("Usage unavailable")
            label.toolTip = error
            rows.addArrangedSubview(label)
            return rows
        }
        guard let snapshot = snapshots[harness], !snapshot.limits.isEmpty else {
            let label = muted("Provider limits unavailable")
            label.toolTip = snapshots[harness]?.note
            rows.addArrangedSubview(label)
            return rows
        }
        let summary = HarnessBudgetPanel.summarize(snapshot)
        let clock = now()
        // one line per budget: what is left, and how long until it refills
        if let session = summary.session {
            let reset = HarnessBudgetPanel.sessionReset(session.resetsAt, clock)
            addFull(rows, budgetRow(session, "Session", reset.map { "\($0.value) left" }, reset?.tooltip))
        }
        if let week = summary.week {
            let reset = HarnessBudgetPanel.weeklyReset(week.resetsAt, clock)
            addFull(rows, budgetRow(week, "Week", reset.map { HarnessBudgetPanel.days($0.value) }, reset?.tooltip))
        }
        if let fable = summary.fable {
            addFull(rows, budgetRow(fable, "Fable", nil, nil))
        }
        if let credits = summary.credits {
            let reset = HarnessBudgetPanel.monthlyReset(clock)
            addFull(rows, budgetRow(credits, "Credits", HarnessBudgetPanel.days(reset.value), reset.tooltip))
        }
        return rows
    }

    private func addFull(_ rows: NSStackView, _ row: NSView) {
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private static func days(_ value: String) -> String {
        value == "1" ? "1 day" : "\(value) days"
    }

    private func budgetRow(_ budget: Budget, _ metric: String, _ reset: String?, _ resetTip: String?) -> NSView {
        let metricField = NSTextField(labelWithString: metric)
        metricField.font = .systemFont(ofSize: 11)
        metricField.textColor = .secondaryLabelColor
        metricField.translatesAutoresizingMaskIntoConstraints = false
        metricField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = Double(max(0, min(100, budget.availablePercent)))
        bar.setAccessibilityLabel("\(metric) budget available")
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let valueField = NSTextField(labelWithString: "\(budget.availablePercent)%")
        valueField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueField.alignment = .right
        valueField.textColor = budget.availablePercent <= 10 ? .systemRed : (budget.availablePercent <= 25 ? .systemOrange : .labelColor)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let resetField = NSTextField(labelWithString: reset ?? "")
        resetField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        resetField.textColor = .tertiaryLabelColor
        resetField.alignment = .right
        resetField.translatesAutoresizingMaskIntoConstraints = false
        resetField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [metricField, bar, valueField, resetField])
        row.spacing = 6
        let tooltip = "\(budget.description) · \(budget.availablePercent)% available" + (resetTip.map { " · \($0)" } ?? "")
        row.toolTip = tooltip
        for view in row.arrangedSubviews { view.toolTip = tooltip }
        return row
    }

    private func muted(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    // MARK: - summary (ported as is)

    static func summarize(_ snapshot: UsageSnapshot) -> Summary {
        let limits = snapshot.limits
        let rateLimits = limits.filter { !isFable($0.label) && !isCredits($0.label) }
        var session: Budget?
        var week: Budget?
        if !rateLimits.isEmpty {
            let shortest = rateLimits.first { isShortWindow($0.label) }
                ?? rateLimits.min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
            session = shortest.map(availableBudget)
            let longest = rateLimits.first { isAllModelsWeek($0.label) }
                ?? rateLimits.first { isLongWindow($0.label) }
                ?? rateLimits.max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
            week = longest.map(availableBudget)
        }
        let fable = limits.first { isFable($0.label) }.map(availableBudget)
        let credits = limits.first { isCredits($0.label) }.map(availableBudget)
        return Summary(session: session, week: week, fable: fable, credits: credits)
    }

    private static func availableBudget(_ limit: UsageSnapshot.Limit) -> Budget {
        Budget(availablePercent: 100 - limit.usedPercent, description: limit.label, resetsAt: limit.resetsAt)
    }

    private static func clampPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }

    static func weeklyReset(_ reset: Date?, _ now: Date) -> Reset? {
        guard let reset else { return nil }
        let seconds = reset.timeIntervalSince(now).rounded(.down)
        if seconds <= 0 {
            return Reset(value: "0", remainingPercent: 0, tooltip: "Weekly reset due")
        }
        let days = max(1, Int((seconds + 86_399) / 86_400))
        return Reset(value: String(days), remainingPercent: clampPercent(seconds * 100 / weekSeconds),
                     tooltip: "\(days) \(days == 1 ? "day" : "days") until weekly reset")
    }

    /// Anthropic's extra_usage credit window carries no reset timestamp, so this assumes
    /// a calendar-month cycle (observed empirically: the account resets on the 1st).
    static func monthlyReset(_ now: Date) -> Reset {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? now.addingTimeInterval(30 * 86_400)
        let seconds = max(0, nextMonth.timeIntervalSince(now))
        let days = max(1, Int((seconds + 86_399) / 86_400))
        let monthDays = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        return Reset(value: String(days), remainingPercent: clampPercent(seconds * 100 / Double(monthDays * 86_400)),
                     tooltip: "\(days) \(days == 1 ? "day" : "days") until monthly reset")
    }

    static func sessionReset(_ reset: Date?, _ now: Date) -> Reset? {
        guard let reset else { return nil }
        let seconds = max(0, reset.timeIntervalSince(now).rounded(.down))
        let totalMinutes = Int(seconds) / 60
        // a day or more reads as days and hours, so a long window fits the column
        let remaining = totalMinutes >= 24 * 60
            ? "\(totalMinutes / (24 * 60))d \((totalMinutes / 60) % 24)h"
            : "\(totalMinutes / 60)h" + String(format: "%02d", totalMinutes % 60) + "m"
        return Reset(value: remaining, remainingPercent: clampPercent(seconds * 100 / sessionSeconds),
                     tooltip: seconds == 0 ? "Session reset due" : "\(remaining) left in session")
    }

    private static func isShortWindow(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("session") || l.contains("hour") || l.contains("minute")
    }

    private static func isLongWindow(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("week") || l.contains("month") || l.contains("day")
    }

    private static func isAllModelsWeek(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("all models")
            || (isLongWindow(label) && !isFable(label) && !l.contains("opus") && !l.contains("sonnet"))
    }

    private static func isFable(_ label: String) -> Bool { label.lowercased().contains("fable") }
    private static func isCredits(_ label: String) -> Bool { label.lowercased().contains("credit") }
}
