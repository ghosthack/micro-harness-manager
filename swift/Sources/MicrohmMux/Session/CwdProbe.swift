import Darwin
import Foundation

/// The current working directory of a process: `proc_pidinfo(PROC_PIDVNODEPATHINFO)` (the
/// kernel's answer, no fork; the Java port could only read `/proc` or run `lsof`), falling
/// back to `lsof -a -p <pid> -d cwd -Fn`. Nil means "unknown", and the session falls back
/// to the shell's pid and then to its launch directory.
public enum CwdProbe {

    public static func cwdOf(_ pid: Int64) -> URL? {
        viaProcInfo(pid) ?? viaLsof(pid)
    }

    /// The kernel's record of the process's current directory; nil for another user's
    /// process or a gone one.
    static func viaProcInfo(_ pid: Int64) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size)
        if n != size { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return toPath(path)
    }

    /// One field-mode query for the cwd descriptor. `-b` keeps lsof itself off the blocking
    /// `stat`/`readlink` calls it would otherwise make on every mount point (a dead network
    /// mount hangs them); the `ProbeCommand` deadline is the real guard.
    static func viaLsof(_ pid: Int64) -> URL? {
        ProbeCommand.output(["lsof", "-b", "-a", "-p", String(pid), "-d", "cwd", "-Fn"]).flatMap(parseLsof)
    }

    /// `-Fn` output is one field per line: `p<pid>`, `fcwd`, `n<path>`.
    static func parseLsof(_ output: String) -> URL? {
        var inCwd = false
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("f") {
                inCwd = line == "fcwd"
            } else if inCwd && line.hasPrefix("n") && line.count > 1 {
                return toPath(String(line.dropFirst()))
            }
        }
        return nil
    }

    private static func toPath(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }
}
