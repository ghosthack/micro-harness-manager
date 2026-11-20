import Foundation
import MicrohmCore

/// One row in the sidebar: a registered `SessionEntry`, live or dead (Java's `SidebarEntry`).
/// A class, not a struct: the status poller updates a row's state in place and the outline
/// view keeps object identity across reloads of a single row.
final class SidebarEntry {

    enum Status { case live, dead }

    let status: Status
    let sessionEntry: SessionEntry
    var sessionName: String { sessionEntry.sessionName }
    var harnessType: HarnessType { sessionEntry.harnessType }
    var isAttached = false

    /// Latest status-poll result. Nil until the first poll tick lands (or always, for
    /// dead entries — those are never polled).
    private(set) var state: SessionState?
    /// Reason paired with `state`; nil exactly when the state is.
    private(set) var stateReason: String?

    /// Latest pane title the harness set via OSC (e.g. Claude Code's /rename); empty
    /// until a poll reports one. Kept even when a later poll reports none — a harness
    /// mid-redraw must not make the name flicker off.
    private(set) var paneTitle = ""

    private init(_ status: Status, _ entry: SessionEntry) {
        self.status = status
        self.sessionEntry = entry
    }

    static func live(_ entry: SessionEntry) -> SidebarEntry { SidebarEntry(.live, entry) }
    static func dead(_ entry: SessionEntry) -> SidebarEntry { SidebarEntry(.dead, entry) }

    func setState(_ state: SessionState?, _ reason: String?) {
        self.state = state
        self.stateReason = reason
    }

    func setPaneTitle(_ title: String?) {
        let name = SidebarEntry.withoutStatusGlyph(title ?? "")
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paneTitle = name
        }
    }

    private static let statusGlyph = try? NSRegularExpression(
        pattern: "^\\s*[\\x{2800}-\\x{28FF}\\x{2722}-\\x{273D}\\x{00B7}\\x{2022}\\x{25CF}]+(\\s+|$)")

    /// Harnesses prefix their terminal title with a live status mark: Claude Code's `✳`
    /// when idle, a braille spinner frame while working. The row already shows status in
    /// its badge, and a mark that changes every frame would make the name (and a name
    /// sort) flicker, so it is dropped from the name.
    static func withoutStatusGlyph(_ title: String) -> String {
        guard let regex = statusGlyph else { return title.trimmingCharacters(in: .whitespaces) }
        let range = NSRange(title.startIndex..., in: title)
        let stripped = regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The session's name as shown to the user: an explicit persisted rename, then the
    /// harness-set OSC title (e.g. Claude Code's /rename), then the session name.
    var displayName: String {
        if let name = sessionEntry.displayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return detectedName
    }

    /// Best name supplied by the harness/provider, before any persisted sidebar override.
    var detectedName: String { paneTitle.isEmpty ? sessionName : paneTitle }

    /// Project path with the home directory abbreviated to `~`.
    var abbreviatedPath: String { SidebarEntry.abbreviate(sessionEntry.projectPath) }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The sidebar row's tooltip: name, session key, harness and latest status reason.
    var tooltipText: String {
        var lines = [displayName]
        if displayName != sessionName {
            lines.append(sessionName)
        }
        lines.append(harnessType.id)
        switch status {
        case .live:
            if let state {
                lines.append("\(state.rawValue) — \(stateReason ?? "")")
            } else {
                lines.append("status pending first poll…")
            }
        case .dead:
            // dead isn't gone — Resume… brings it back
            lines.append("dead — right-click to resume")
        }
        return lines.joined(separator: "\n")
    }

    /// Human status for pre-flight reviews and batch checklists.
    var statusPhrase: String {
        if status == .dead { return "already stopped" }
        guard let state else { return "live; status pending" }
        switch state {
        case .working: return "working"
        case .waitingForInput: return "waiting for input"
        case .idle: return "idle"
        }
    }
}

/// Sorting and filtering vocabulary for the sidebar session list (Java's `SidebarView`).
enum SidebarView {

    enum SortMode: String, CaseIterable {
        case sessionName = "session"
        case directoryName = "folder"
        case status = "status"

        var key: String { rawValue }

        var label: String {
            switch self {
            case .sessionName: return "Session"
            case .directoryName: return "Folder"
            case .status: return "Status"
            }
        }

        static func fromKey(_ key: String) -> SortMode {
            allCases.first { $0.key.caseInsensitiveCompare(key) == .orderedSame } ?? .sessionName
        }
    }

    /// Every state a row can visibly occupy, including rows not covered by polling. The
    /// order is the status sort's: attention first, then active/quiet, then lifecycle.
    enum FilterStatus: Int, CaseIterable {
        case waitingForInput, working, idle, statusPending, dead

        var key: String {
            switch self {
            case .waitingForInput: return "waiting"
            case .working: return "working"
            case .idle: return "idle"
            case .statusPending: return "pending"
            case .dead: return "dead"
            }
        }

        var label: String {
            switch self {
            case .waitingForInput: return "Waiting for input"
            case .working: return "Working"
            case .idle: return "Idle"
            case .statusPending: return "Status pending"
            case .dead: return "Dead"
            }
        }
    }

    /// The harness identities a row can carry.
    enum HarnessFamily: CaseIterable {
        case claudeCode, codex, cursorAgent, grok, opencode, pi, muse, shell

        var harnessType: HarnessType {
            switch self {
            case .claudeCode: return .claudeCode
            case .codex: return .codex
            case .cursorAgent: return .cursorAgent
            case .grok: return .grok
            case .opencode: return .opencode
            case .pi: return .pi
            case .muse: return .muse
            case .shell: return .shell
            }
        }

        var key: String {
            switch self {
            case .claudeCode: return "claude"
            case .codex: return "codex"
            case .cursorAgent: return "cursor"
            case .grok: return "grok"
            case .opencode: return "opencode"
            case .pi: return "pi"
            case .muse: return "muse"
            case .shell: return "shell"
            }
        }

        var label: String { SidebarView.label(harnessType) }

        static func of(_ type: HarnessType) -> HarnessFamily {
            allCases.first { $0.harnessType == type } ?? .shell
        }
    }

    /// The short provider name people know a harness by.
    static func label(_ type: HarnessType) -> String {
        switch type {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .cursorAgent: return "Cursor"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .muse: return "Muse"
        case .shell: return "Shell"
        }
    }

    static func filterStatus(_ entry: SidebarEntry) -> FilterStatus {
        if entry.status == .dead { return .dead }
        switch entry.state {
        case .working?: return .working
        case .waitingForInput?: return .waitingForInput
        case .idle?: return .idle
        case nil: return .statusPending
        }
    }

    static func isVisible(_ entry: SidebarEntry, _ statuses: Set<FilterStatus>,
                          _ families: Set<HarnessFamily>) -> Bool {
        statuses.contains(filterStatus(entry)) && families.contains(HarnessFamily.of(entry.harnessType))
    }

    /// Case-insensitive first, then exact, like Java's `CASE_INSENSITIVE_ORDER.thenComparing(naturalOrder())`.
    static func textOrder(_ a: String, _ b: String) -> ComparisonResult {
        let folded = a.compare(b, options: [.caseInsensitive])
        if folded != .orderedSame { return folded }
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    /// The sort's comparison, with the session key as the final tie-break so the order is
    /// total and stable across rebuilds.
    static func compare(_ a: SidebarEntry, _ b: SidebarEntry, _ mode: SortMode) -> ComparisonResult {
        var primary: ComparisonResult
        switch mode {
        case .sessionName:
            primary = textOrder(a.displayName, b.displayName)
        case .directoryName:
            primary = textOrder(directoryName(a), directoryName(b))
            if primary == .orderedSame {
                // Full path outranks the session name so two folders sharing a basename
                // cannot interleave — folder groups need each folder's rows contiguous.
                primary = textOrder(folderGroupKey(a), folderGroupKey(b))
            }
        case .status:
            let x = filterStatus(a).rawValue, y = filterStatus(b).rawValue
            primary = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        return primary != .orderedSame ? primary : textOrder(a.sessionName, b.sessionName)
    }

    static func sorted(_ entries: [SidebarEntry], _ mode: SortMode, descending: Bool) -> [SidebarEntry] {
        entries.sorted { a, b in
            let order = compare(a, b, mode)
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    /// Unique harnesses which currently have at least one live session, in enum order.
    static func activeHarnesses(_ entries: [SidebarEntry]) -> [HarnessType] {
        let live = Set(entries.filter { $0.status == .live }.map(\.harnessType))
        return HarnessType.allCases.filter { live.contains($0) }
    }

    /// What makes two adjacent rows part of the same folder group: their full project path.
    static func folderGroupKey(_ entry: SidebarEntry) -> String {
        entry.sessionEntry.projectPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : entry.sessionEntry.projectPath
    }

    static func directoryName(_ entry: SidebarEntry) -> String {
        let path = entry.sessionEntry.projectPath
        if path.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// A run of same-folder rows in the outline, headed once by the folder.
final class FolderGroup {
    let key: String
    let path: String
    var entries: [SidebarEntry]

    init(key: String, path: String, entries: [SidebarEntry]) {
        self.key = key
        self.path = path
        self.entries = entries
    }

    var folderName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == path ? "" : parent
    }
}

/// Refresh tickets: reconciliation runs off the main thread, so a slow older refresh must
/// not overwrite the sidebar state of a newer one — nor may a newer reselect-nothing
/// refresh drop an older one's reselect target (Java's `SidebarRefreshTickets`).
final class SidebarRefreshTickets {
    private var issued: Int64 = 0
    private var pendingReselect: String?
    private var pendingReselectSeq: Int64 = 0

    func issue(_ reselect: String?) -> Int64 {
        issued += 1
        if let reselect {
            pendingReselect = reselect
            pendingReselectSeq = issued
        }
        return issued
    }

    func isCurrent(_ seq: Int64) -> Bool { seq == issued }

    func failed(_ seq: Int64) {
        if pendingReselect != nil, pendingReselectSeq <= seq {
            pendingReselect = nil
        }
    }

    func takeReselect() -> String? {
        defer { pendingReselect = nil }
        return pendingReselect
    }
}
