import Foundation
import Darwin

/// Finds a session's transcript from the files the harness process under a pane's shell
/// has open: Codex keeps its rollout open, Muse its session directory's lock. Each
/// harness process's answer is remembered so `lsof` is forked once per process rather
/// than once per status tick. A process whose lookup found nothing is retried after
/// `missRetryNanos` (a just-started harness opens its file a moment later); a found
/// transcript is re-checked after `hitRefreshNanos` so a `/new` or `/resume` inside the
/// same process is still picked up. Entries for processes that have exited are dropped.
/// Thread-safe.
///
/// Callable as a function (`locator(paneProcessId)`), Java's `LongFunction<Optional<Path>>`.
public final class OpenFileLocator: @unchecked Sendable {

    static let missRetryNanos: UInt64 = 30 * 1_000_000_000
    static let hitRefreshNanos: UInt64 = 120 * 1_000_000_000
    static let pruneIntervalNanos: UInt64 = 30 * 1_000_000_000

    /// A harness process, identified by pid and start time so a reused pid is not
    /// confused with the process that held it before.
    public struct HarnessProcess: Hashable, Sendable {
        public let pid: Int64
        public let startMillis: Int64
        public init(_ pid: Int64, _ startMillis: Int64) {
            self.pid = pid
            self.startMillis = startMillis
        }
    }

    private struct Lookup {
        let transcript: URL?
        let checkedAtNanos: UInt64
    }

    private let harnessProcesses: (Int64) -> [HarnessProcess]
    private let openTranscript: (HarnessProcess) -> URL?
    private let stillRunning: (HarnessProcess) -> Bool
    private let nanoClock: () -> UInt64
    private let lock = NSLock()
    private var lookups: [HarnessProcess: Lookup] = [:]
    private var lastPruneNanos: UInt64

    /// Over the live process table and `lsof`.
    ///
    /// - `executable`: whether an executable's file name is the harness's
    /// - `transcriptOf`: the transcript an open file shows the process is writing, or nil
    ///   when the file says nothing about one; of several, the most recently modified wins
    public static func overLsof(_ executable: @escaping (String) -> Bool,
                                _ transcriptOf: @escaping (URL) -> URL?) -> OpenFileLocator {
        OpenFileLocator({ pane in processes(pane, executable) },
                        { process in openTranscript(process.pid, transcriptOf) },
                        isRunning,
                        { DispatchTime.now().uptimeNanoseconds })
    }

    /// Test seam: the process walk, the per-process `lsof`, the liveness check and the
    /// clock are all injected.
    init(_ harnessProcesses: @escaping (Int64) -> [HarnessProcess],
         _ openTranscript: @escaping (HarnessProcess) -> URL?,
         _ stillRunning: @escaping (HarnessProcess) -> Bool,
         _ nanoClock: @escaping () -> UInt64) {
        self.harnessProcesses = harnessProcesses
        self.openTranscript = openTranscript
        self.stillRunning = stillRunning
        self.nanoClock = nanoClock
        self.lastPruneNanos = nanoClock()
    }

    public func callAsFunction(_ paneProcessId: Int64) -> URL? {
        apply(paneProcessId)
    }

    public func apply(_ paneProcessId: Int64) -> URL? {
        let now = nanoClock()
        pruneIfDue(now)
        return harnessProcesses(paneProcessId)
            .compactMap { lookup($0, now) }
            .max { OpenFileLocator.lastModified($0) < OpenFileLocator.lastModified($1) }
    }

    /// Number of harness processes currently remembered (for tests).
    func cachedProcessCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return lookups.count
    }

    private func lookup(_ process: HarnessProcess, _ now: UInt64) -> URL? {
        lock.lock()
        if let cached = lookups[process] {
            let age = now &- cached.checkedAtNanos
            let ttl = cached.transcript != nil ? OpenFileLocator.hitRefreshNanos : OpenFileLocator.missRetryNanos
            if age < ttl {
                lock.unlock()
                return cached.transcript
            }
        }
        lock.unlock()
        let found = openTranscript(process)
        lock.lock()
        lookups[process] = Lookup(transcript: found, checkedAtNanos: now)
        lock.unlock()
        return found
    }

    private func pruneIfDue(_ now: UInt64) {
        lock.lock()
        if now &- lastPruneNanos < OpenFileLocator.pruneIntervalNanos {
            lock.unlock()
            return
        }
        lastPruneNanos = now
        let known = Array(lookups.keys)
        lock.unlock()
        let gone = known.filter { !stillRunning($0) }
        lock.lock()
        for process in gone { lookups.removeValue(forKey: process) }
        lock.unlock()
    }

    // MARK: - the live process table

    private struct ProcInfo {
        let pid: Int64
        let parent: Int64
        let startMillis: Int64
    }

    /// Every process: pid, parent pid and start time, from `sysctl(KERN_PROC_ALL)`.
    private static func processTable() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs[0..<(size / stride)].map { p in
            let start = p.kp_proc.p_un.__p_starttime
            return ProcInfo(pid: Int64(p.kp_proc.p_pid), parent: Int64(p.kp_eproc.e_ppid),
                            startMillis: Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000)
        }
    }

    private static func info(_ pid: Int64) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var p = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &p, &size, nil, 0) == 0, size > 0, p.kp_proc.p_pid == Int32(pid) else { return nil }
        let start = p.kp_proc.p_un.__p_starttime
        return ProcInfo(pid: pid, parent: Int64(p.kp_eproc.e_ppid),
                        startMillis: Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000)
    }

    /// The executable's path (`ProcessHandle.Info.command()`).
    static func executablePath(_ pid: Int64) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The pane's shell and its descendants whose executable's file name passes
    /// `executable`; empty when the pane is gone.
    public static func processes(_ paneProcessId: Int64, _ executable: (String) -> Bool) -> [HarnessProcess] {
        if paneProcessId <= 0 {
            return []
        }
        guard let pane = info(paneProcessId) else {
            return []
        }
        let table = processTable()
        var children: [Int64: [ProcInfo]] = [:]
        for p in table where p.pid != p.parent {
            children[p.parent, default: []].append(p)
        }
        var all = [pane]
        var frontier = [pane.pid]
        var seen: Set<Int64> = [pane.pid]
        while let next = frontier.popLast() {
            for child in children[next] ?? [] where !seen.contains(child.pid) {
                seen.insert(child.pid)
                all.append(child)
                frontier.append(child.pid)
            }
        }
        return all.compactMap { p in
            guard let command = executablePath(p.pid) else { return nil }
            let name = (command as NSString).lastPathComponent
            return !name.isEmpty && executable(name) ? HarnessProcess(p.pid, p.startMillis) : nil
        }
    }

    private static func isRunning(_ process: HarnessProcess) -> Bool {
        guard let p = info(process.pid) else { return false }
        return p.startMillis == process.startMillis
    }

    private static let lsofCandidates = ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]

    private static func openTranscript(_ processId: Int64, _ transcriptOf: (URL) -> URL?) -> URL? {
        guard let lsof = lsofCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // Into a file, not a pipe: nothing reads a pipe while this waits, so a process
        // with more open files than the pipe holds would block lsof until the timeout.
        let listing = FileManager.default.temporaryDirectory
            .appendingPathComponent("microhm-lsof-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: listing.path, contents: nil),
              let out = FileHandle(forWritingAtPath: listing.path) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: listing) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = ["-a", "-p", String(processId), "-Fn"]
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? out.close()
            return nil
        }
        try? out.close()
        if !ProcessWaiter.wait(process, timeout: 2) {
            ProcessWaiter.kill(process)
            return nil
        }
        guard let data = try? Data(contentsOf: listing) else { return nil }
        var newest: URL?
        for line in JavaText.lines(String(decoding: data, as: UTF8.self)) where line.hasPrefix("n/") {
            let path = PathCompat.normalize(URL(fileURLWithPath: String(line.dropFirst())))
            guard let candidate = transcriptOf(path) else { continue }
            if newest == nil || lastModified(candidate) > lastModified(newest!) {
                newest = candidate
            }
        }
        return newest
    }

    static func lastModified(_ path: URL) -> Int64 {
        PathCompat.lastModifiedMillis(path) ?? Int64.min
    }
}
