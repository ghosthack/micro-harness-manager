import Darwin
import Foundation

/// When this run of the app started, reached `main`, and first showed its window.
public enum StartupTimes {

    nonisolated(unsafe) private static var mainMillis: Int64 = -1
    nonisolated(unsafe) private static var windowMillis: Int64 = -1

    /// Called first thing in `main`.
    public static func markMain() {
        mainMillis = nowMillis()
    }

    /// Called when the main window first opens.
    public static func markWindowShown() {
        if windowMillis < 0 {
            windowMillis = nowMillis()
        }
    }

    /// The process's start, in epoch milliseconds.
    public static func processStartMillis() -> Int64 {
        HostOwner.startMillis(Int64(getpid())) ?? -1
    }

    /// Milliseconds from the process's start to `main`, or -1.
    public static func toMain() -> Int64 {
        mainMillis < 0 ? -1 : mainMillis - processStartMillis()
    }

    /// Milliseconds from the process's start to the window opening, or -1.
    public static func toWindow() -> Int64 {
        windowMillis < 0 ? -1 : windowMillis - processStartMillis()
    }

    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// Inexpensive figures about this run of the app, for Settings' Performance section: all
/// read from the kernel when asked (`task_info`, `getrusage`, `task_threads`), so nothing is
/// measured in the background. (The Java figures about the heap, garbage collection,
/// classes and the startup cache have no native counterpart.)
public enum PerfStats {

    /// One line of the section.
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public static func snapshot() -> [Row] {
        var rows: [Row] = []
        let toWindow = StartupTimes.toWindow()
        rows.append(Row("Startup", toWindow < 0 ? "—" : seconds(toWindow) + " to the window"
                        + (StartupTimes.toMain() < 0 ? "" : " (" + seconds(StartupTimes.toMain()) + " to start the app code)")))
        let start = StartupTimes.processStartMillis()
        if start > 0 {
            rows.append(Row("Uptime", duration(Int64(Date().timeIntervalSince1970 * 1000) - start)))
        }
        if let cpu = cpuMillis() {
            rows.append(Row("CPU time", seconds(cpu)))
        }
        if let memory = memory() {
            rows.append(Row("Memory in use", megabytes(memory.footprint)))
            rows.append(Row("Resident memory", megabytes(memory.resident) + " (peak " + megabytes(memory.peak) + ")"))
        }
        if let threads = threadCount() {
            rows.append(Row("Threads", String(threads)))
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        rows.append(Row("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        return rows
    }

    /// The rows as plain text, for Copy.
    public static func asText(_ rows: [Row]) -> String {
        rows.map { $0.label + ": " + $0.value + "\n" }.joined()
    }

    /// User plus system CPU time of this process, in milliseconds.
    static func cpuMillis() -> Int64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func ms(_ t: timeval) -> Int64 { Int64(t.tv_sec) * 1000 + Int64(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    /// The physical footprint (what Activity Monitor calls Memory), resident size and its
    /// peak, in bytes.
    static func memory() -> (footprint: Int64, resident: Int64, peak: Int64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Int64(info.phys_footprint), Int64(info.resident_size), Int64(info.resident_size_peak))
    }

    static func threadCount() -> Int? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        for i in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, threads[i])
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    static func seconds(_ millis: Int64) -> String {
        millis < 10_000 ? String(format: "%.2f s", Double(millis) / 1000) : String(format: "%.1f s", Double(millis) / 1000)
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes < 0 ? "—" : String(format: "%.0f MB", Double(bytes) / (1024 * 1024))
    }

    static func duration(_ millis: Int64) -> String {
        let total = max(0, millis / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? "\(h) h \(m) min" : m > 0 ? "\(m) min \(s) s" : "\(s) s"
    }
}
