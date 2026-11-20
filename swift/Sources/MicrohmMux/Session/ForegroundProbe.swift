import Darwin
import Foundation

/// The session's foreground command, as tmux's `pane_current_command` reports it.
///
/// The foreground process is the one among the shell and its descendants whose `pid`
/// equals the shell's `tpgid` (the leader of the terminal's foreground process group),
/// falling back to the shell itself when none matches (the leader already exited, or the
/// shell has no controlling terminal). It is read with
/// `ps -o pid=,pgid=,tpgid=,comm= -p <shell + descendants>` — `ps` reports the name a
/// program gives itself (a node CLI's process title), which the kernel's short name does
/// not — so it forks, and a session probes through a `Memo` that reuses the last answer
/// while the terminal's foreground group (`tcgetpgrp`, no fork) is unchanged and the
/// session has been quiet.
///
/// When `ps` is unavailable: walk from the shell down the chain formed by taking the newest
/// live child at each level, skipping processes whose name cannot be read, and report the
/// first remaining process; else the shell. Never the leaf: tool children and MCP servers
/// under a harness are newer leaves and would flip the name mid-turn. The walk is written
/// over `ProcessNode` so it can be exercised with synthetic trees.
///
/// Every reported name is the basename, lower-cased, with a trailing `.exe` and a
/// login-shell `-` prefix removed.
public enum ForegroundProbe {

    /// Foreground pid and normalized command name; `command` is "" when unknown.
    public struct Foreground: Equatable, Sendable {
        public let pid: Int64
        public let command: String
        public init(pid: Int64, command: String) {
            self.pid = pid
            self.command = command
        }
    }

    /// A process-tree node: the live process table in production, a synthetic tree in tests.
    protocol ProcessNode {
        var pid: Int64 { get }
        /// The raw executable name or path ("" when unreadable); normalized by the probe.
        var command: String { get }
        var isAlive: Bool { get }
        /// Launch time, used to pick the newest child; 0 when unknown.
        var startTime: TimeInterval { get }
        var children: [ProcessNode] { get }
    }

    /// Processes the fallback walk looks through rather than at (an npm shim's cmd.exe).
    static let TRANSPARENT: Set<String> = ["cmd", "conhost"]

    /// The foreground of the session whose shell is `shellPid`. When the shell is gone the
    /// command is "" and the pid is the shell's.
    public static func probe(_ shellPid: Int64) -> Foreground {
        guard ProcessTable.entry(of: Int32(shellPid)) != nil else {
            return Foreground(pid: shellPid, command: "")
        }
        if let viaPs = viaPs(Int32(shellPid)) {
            return viaPs
        }
        return walk(TableNode(pid: Int32(shellPid), table: ProcessTable.all()))
    }

    /// Whether `probe` forks (so a `Memo` is worth keeping).
    static func forks() -> Bool { true }

    private static func viaPs(_ shellPid: Int32) -> Foreground? {
        let pids = ([shellPid] + ProcessTable.descendants(of: shellPid).map(\.pid)).map(String.init)
        guard let out = ProbeCommand.output(["ps", "-o", "pid=,pgid=,tpgid=,comm=", "-p", pids.joined(separator: ",")])
        else { return nil }
        return parsePs(out, Int64(shellPid))
    }

    /// The `pid == tpgid` rule over canned or live `ps` output; nil when the shell's own row
    /// is missing (then the caller falls back to the tree walk).
    static func parsePs(_ psOutput: String, _ shellPid: Int64) -> Foreground? {
        struct Row { let pid: Int64; let tpgid: Int64; let comm: String }
        let pattern = try! Regex(#"^\s*(\d+)\s+(\d+)\s+(-?\d+)\s+(.*?)\s*$"#, as: (Substring, Substring, Substring, Substring, Substring).self)
        var rows: [Row] = []
        for line in psOutput.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let m = String(line).wholeMatch(of: pattern), let pid = Int64(m.1), let tpgid = Int64(m.3) {
                rows.append(Row(pid: pid, tpgid: tpgid, comm: String(m.4)))
            }
        }
        guard let shell = rows.first(where: { $0.pid == shellPid }) else { return nil }
        let foreground = rows.first(where: { $0.pid == shell.tpgid }) ?? shell
        return Foreground(pid: foreground.pid, command: normalize(foreground.comm))
    }

    /// The tree-walk heuristic over any `ProcessNode` tree.
    static func walk(_ shell: ProcessNode) -> Foreground {
        var node = shell
        while true {
            guard let child = newestLiveChild(node) else {
                return Foreground(pid: shell.pid, command: normalize(shell.command))
            }
            let name = normalize(child.command)
            if !name.isEmpty && !TRANSPARENT.contains(name) {
                return Foreground(pid: child.pid, command: name)
            }
            node = child
        }
    }

    private static func newestLiveChild(_ node: ProcessNode) -> ProcessNode? {
        node.children.filter(\.isAlive).max { a, b in
            a.startTime != b.startTime ? a.startTime < b.startTime : a.pid < b.pid
        }
    }

    /// Basename, without a login-shell `-` prefix, lower-cased, without `.exe`.
    static func normalize(_ command: String?) -> String {
        guard let command else { return "" }
        var name = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: cut)...])
        }
        if name.hasPrefix("-") {
            name.removeFirst()
        }
        name = name.lowercased()
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        return name
    }

    /// A session's probe: the last answer is reused while the terminal's foreground process
    /// group is unchanged (read with `tcgetpgrp` on the master, no fork) and it is either
    /// younger than `FRESH` or the session produced no output since, for up to `IDLE`. A new
    /// foreground group (a command started or ended) or output re-probes. Where the probe
    /// does not fork, or the group is unknown, every call probes.
    final class Memo: @unchecked Sendable {

        static let FRESH: UInt64 = 1_000_000_000      // 1 s in nanoseconds
        static let IDLE: UInt64 = 30_000_000_000      // 30 s

        private struct Entry {
            let shellPid: Int64
            let group: Int64
            let outputBytes: Int64
            let atNanos: UInt64
            let foreground: Foreground
        }

        private let enabled: Bool
        private let foregroundGroup: () -> Int64
        private let probeFunction: (Int64) -> Foreground
        private let clock: () -> UInt64
        private let lock = NSLock()
        private var last: Entry?

        /// `foregroundGroup`: the terminal's foreground process group, -1 when unknown.
        convenience init(_ foregroundGroup: @escaping () -> Int64) {
            self.init(enabled: ForegroundProbe.forks(), foregroundGroup: foregroundGroup,
                      probe: ForegroundProbe.probe, clock: { DispatchTime.now().uptimeNanoseconds })
        }

        init(enabled: Bool, foregroundGroup: @escaping () -> Int64, probe: @escaping (Int64) -> Foreground,
             clock: @escaping () -> UInt64) {
            self.enabled = enabled
            self.foregroundGroup = foregroundGroup
            self.probeFunction = probe
            self.clock = clock
        }

        /// The foreground of `shellPid`; `outputBytes` is the session's output counter, whose
        /// change means the screen (and maybe the foreground) moved on.
        func probe(_ shellPid: Int64, _ outputBytes: Int64) -> Foreground {
            lock.lock(); defer { lock.unlock() }
            if !enabled {
                return probeFunction(shellPid)
            }
            let group = foregroundGroup()
            let now = clock()
            if group > 0, let e = last, e.shellPid == shellPid, e.group == group, now >= e.atNanos {
                let age = now - e.atNanos
                let fresh = age < Memo.FRESH
                let quiet = outputBytes == e.outputBytes && age < Memo.IDLE
                if fresh || quiet {
                    return e.foreground
                }
            }
            let fg = probeFunction(shellPid)
            last = group > 0 ? Entry(shellPid: shellPid, group: group, outputBytes: outputBytes, atNanos: now,
                                     foreground: fg) : nil
            return fg
        }
    }

    /// `ProcessNode` over one snapshot of the live process table.
    private struct TableNode: ProcessNode {
        let entry: ProcessEntry?
        let pidValue: Int32
        let table: [ProcessEntry]

        init(pid: Int32, table: [ProcessEntry]) {
            self.pidValue = pid
            self.table = table
            self.entry = table.first { $0.pid == pid }
        }

        var pid: Int64 { Int64(pidValue) }

        var command: String {
            let path = ProcessTable.executablePath(pidValue)
            return path.isEmpty ? (entry?.comm ?? "") : path
        }

        var isAlive: Bool { entry.map { !$0.zombie } ?? false }

        var startTime: TimeInterval { entry?.startTime ?? 0 }

        var children: [ProcessNode] {
            table.filter { $0.ppid == pidValue && $0.pid != pidValue }.map { TableNode(pid: $0.pid, table: table) }
        }
    }
}
