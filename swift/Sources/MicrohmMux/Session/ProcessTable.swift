import Darwin
import Foundation

/// One row of the kernel's process table (`sysctl KERN_PROC`), what Java's
/// `ProcessHandle` reads on macOS: no fork.
struct ProcessEntry: Sendable {
    let pid: Int32
    let ppid: Int32
    let pgid: Int32
    let tpgid: Int32
    /// The kernel's short name (`p_comm`, up to 16 bytes).
    let comm: String
    let startTime: TimeInterval
    let zombie: Bool
}

enum ProcessTable {

    /// Every process, or empty when the table cannot be read.
    static func all() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            if sysctl(&mib, 4, nil, &size, nil, 0) != 0 { return [] }
            size += size / 8 + 16 * MemoryLayout<kinfo_proc>.stride
            let capacity = size / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            let rc = procs.withUnsafeMutableBytes { raw in
                sysctl(&mib, 4, raw.baseAddress, &size, nil, 0)
            }
            if rc != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            let count = size / MemoryLayout<kinfo_proc>.stride
            return procs.prefix(count).map(entry)
        }
        return []
    }

    static func entry(of pid: Int32) -> ProcessEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, 4, &info, &size, nil, 0) != 0 || size == 0 { return nil }
        return entry(info)
    }

    private static func entry(_ k: kinfo_proc) -> ProcessEntry {
        let comm = withUnsafeBytes(of: k.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let start = k.kp_proc.p_un.__p_starttime
        return ProcessEntry(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid,
                            tpgid: k.kp_eproc.e_tpgid, comm: comm,
                            startTime: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000,
                            zombie: k.kp_proc.p_stat == SZOMB)
    }

    /// The descendants of `pid` (children, grandchildren, …), from one table snapshot.
    static func descendants(of pid: Int32) -> [ProcessEntry] {
        let table = all()
        var children: [Int32: [ProcessEntry]] = [:]
        for entry in table where entry.pid != entry.ppid {
            children[entry.ppid, default: []].append(entry)
        }
        var result: [ProcessEntry] = []
        var queue = [pid]
        var seen: Set<Int32> = [pid]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where seen.insert(child.pid).inserted {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    static func children(of pid: Int32) -> [ProcessEntry] {
        all().filter { $0.ppid == pid && $0.pid != pid }
    }

    /// Whether `pid` names a live (non-zombie) process.
    static func isAlive(_ pid: Int32) -> Bool {
        guard let entry = entry(of: pid), entry.pid == pid else { return false }
        return !entry.zombie
    }

    /// The executable path (`proc_pidpath`), "" when unreadable.
    static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if n <= 0 { return "" }
        return String(cString: buffer)
    }
}
