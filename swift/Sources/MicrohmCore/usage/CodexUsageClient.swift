import Foundation

/// Fetches account usage through Codex's local JSON-RPC app server.
final class CodexUsageClient: @unchecked Sendable {

    private static let responseTimeout: TimeInterval = 15

    func load() throws -> UsageSnapshot {
        let codex = try CliLocator.find("codex")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server", "--listen", "stdio://"]
        return try load(process)
    }

    /// Process seam keeps the protocol and shutdown lifecycle testable: `process` is
    /// configured but not yet started; this wires its stdio, runs it, and always stops it.
    func load(_ process: Process) throws -> UsageSnapshot {
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UsageError("Could not start the Codex app server: \(error.localizedDescription)")
        }
        let writeFd = stdin.fileHandleForWriting.fileDescriptor
        // a dead server must surface as a write error, not a SIGPIPE that kills the app
        _ = fcntl(writeFd, F_SETNOSIGPIPE, 1)
        let messages = MessageQueue()
        let reader = LineReaderThread(fd: stdout.fileHandleForReading.fileDescriptor, queue: messages)
        reader.start()
        defer {
            // The app server intentionally stays alive waiting for more requests. Stop it
            // before stopping the stdout reader.
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            if !ProcessWaiter.wait(process, timeout: 1) {
                ProcessWaiter.kill(process)
                _ = ProcessWaiter.wait(process, timeout: 1)
            }
            reader.stop()
            try? stdout.fileHandleForReading.close()
        }

        try send(writeFd, request(1, "initialize", CoreJSON.obj([
            ("clientInfo", CoreJSON.obj([("name", .string("micro-harness-manager")), ("version", .string("0.1.0"))])),
        ])))
        let initialized = try awaitResponse(messages, 1)
        try ensureSuccess(initialized, "initialize")

        try send(writeFd, CoreJSON.obj([("method", .string("initialized"))]))
        try send(writeFd, request(2, "account/rateLimits/read", nil))
        try send(writeFd, request(3, "account/usage/read", nil))

        var rates: CoreJSON?
        var usage: CoreJSON?
        let deadline = Date().addingTimeInterval(CodexUsageClient.responseTimeout)
        while rates == nil || usage == nil, Date() < deadline {
            guard let message = messages.poll(until: deadline) else {
                break
            }
            if message.path("id").asInt(-1) == 2 {
                rates = message
            } else if message.path("id").asInt(-1) == 3 {
                usage = message
            }
        }
        guard let rates else {
            throw UsageError("Timed out waiting for Codex rate limits")
        }
        try ensureSuccess(rates, "rate limits")
        let usageResult = usage.flatMap { $0.has("result") ? $0.path("result") : nil }
        return CodexUsageClient.parse(rates.path("result"), usageResult)
    }

    static func parse(_ rateResult: CoreJSON, _ usageResult: CoreJSON?) -> UsageSnapshot {
        var limits: [UsageSnapshot.Limit] = []
        let buckets = rateResult.path("rateLimitsByLimitId")
        if buckets.isObject && !buckets.isEmpty {
            for entry in buckets.fields {
                addSnapshot(&limits, entry.value)
            }
        } else {
            addSnapshot(&limits, rateResult.path("rateLimits"))
        }

        var statistics: [UsageSnapshot.Statistic] = []
        let primary = rateResult.path("rateLimits")
        if primary.hasNonNull("planType") {
            statistics.append(UsageSnapshot.Statistic("Plan", friendly(primary.path("planType").asText())))
        }
        let credits = primary.path("credits")
        if credits.isObject {
            let value = credits.path("unlimited").asBoolean(false) ? "Unlimited"
                : credits.path("balance").asText(credits.path("hasCredits").asBoolean() ? "Available" : "None")!
            statistics.append(UsageSnapshot.Statistic("Credits", value))
        }
        let resetCredits = rateResult.path("rateLimitResetCredits")
        if resetCredits.hasNonNull("availableCount") {
            statistics.append(UsageSnapshot.Statistic("Limit resets", String(resetCredits.path("availableCount").asInt())))
        }
        if let usageResult, usageResult.isObject {
            let summary = usageResult.path("summary")
            addNumber(&statistics, summary, "lifetimeTokens", "Lifetime tokens")
            addNumber(&statistics, summary, "peakDailyTokens", "Peak daily tokens")
            addDays(&statistics, summary, "currentStreakDays", "Current streak")
            addDays(&statistics, summary, "longestStreakDays", "Longest streak")
            if summary.hasNonNull("longestRunningTurnSec") {
                statistics.append(UsageSnapshot.Statistic("Longest turn",
                                                          formatDuration(summary.path("longestRunningTurnSec").asLong())))
            }
        }

        let note: String? = usageResult == nil
            ? "This Codex version returned limits but not aggregate token usage."
            : nil
        return UsageSnapshot("Codex account", "Codex app server", limits, statistics, note)
    }

    private static func addSnapshot(_ limits: inout [UsageSnapshot.Limit], _ snapshot: CoreJSON) {
        if !snapshot.isObject {
            return
        }
        var name = snapshot.path("limitName").asText("") ?? ""
        if JavaText.isBlank(name) {
            name = "Codex"
        }
        addWindow(&limits, name, snapshot.path("primary"))
        addWindow(&limits, name, snapshot.path("secondary"))
        let individual = snapshot.path("individualLimit")
        if individual.isObject && individual.hasNonNull("remainingPercent") {
            let used = 100 - individual.path("remainingPercent").asInt()
            let reset = epoch(individual.path("resetsAt"))
            let detail = individual.path("used").asText() + " of " + individual.path("limit").asText()
            limits.append(UsageSnapshot.Limit(name + " spend control", used, reset, detail))
        }
    }

    private static func addWindow(_ limits: inout [UsageSnapshot.Limit], _ name: String, _ window: CoreJSON) {
        if !window.isObject || !window.hasNonNull("usedPercent") {
            return
        }
        let minutes = window.path("windowDurationMins").asLong(0)
        let label = minutes > 0 ? name + " · " + windowLabel(minutes) : name
        limits.append(UsageSnapshot.Limit(label, window.path("usedPercent").asInt(), epoch(window.path("resetsAt")), nil))
    }

    private static func windowLabel(_ minutes: Int64) -> String {
        if minutes % (7 * 24 * 60) == 0 {
            return "\(minutes / (7 * 24 * 60)) week" + (minutes == 7 * 24 * 60 ? "" : "s")
        }
        if minutes % (24 * 60) == 0 {
            return "\(minutes / (24 * 60)) day" + (minutes == 24 * 60 ? "" : "s")
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) hours"
        }
        return "\(minutes) minutes"
    }

    private static func epoch(_ value: CoreJSON) -> Date? {
        value.isIntegralNumber ? Date(timeIntervalSince1970: Double(value.asLong())) : nil
    }

    private static func addNumber(_ statistics: inout [UsageSnapshot.Statistic], _ summary: CoreJSON,
                                  _ field: String, _ label: String) {
        if summary.hasNonNull(field) {
            statistics.append(UsageSnapshot.Statistic(label, grouped(summary.path(field).asLong())))
        }
    }

    private static func addDays(_ statistics: inout [UsageSnapshot.Statistic], _ summary: CoreJSON,
                                _ field: String, _ label: String) {
        if summary.hasNonNull(field) {
            let value = summary.path(field).asLong()
            statistics.append(UsageSnapshot.Statistic(label, "\(value)" + (value == 1 ? " day" : " days")))
        }
    }

    /// `String.format(Locale.ROOT, "%,d", value)`.
    static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 {
                out += ","
            }
            out.append(c)
        }
        return value < 0 ? "-" + out : out
    }

    private static func formatDuration(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static func friendly(_ value: String) -> String {
        let words = value.replacingOccurrences(of: "-", with: "_").split(separator: "_", omittingEmptySubsequences: true)
        return words.map { word in
            let s = String(word)
            return s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
    }

    private func request(_ id: Int, _ method: String, _ params: CoreJSON?) -> CoreJSON {
        var request = CoreJSON.obj([("id", .int(Int64(id))), ("method", .string(method))])
        if let params {
            request.set("params", params)
        }
        return request
    }

    private func send(_ fd: Int32, _ message: CoreJSON) throws {
        let bytes = Array((message.compact() + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw UsageError("Could not write to the Codex app server: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }

    private func awaitResponse(_ messages: MessageQueue, _ id: Int) throws -> CoreJSON {
        let deadline = Date().addingTimeInterval(CodexUsageClient.responseTimeout)
        while Date() < deadline {
            guard let message = messages.poll(until: deadline) else { break }
            if message.path("id").asInt(-1) == id { return message }
        }
        throw UsageError("Timed out initializing the Codex app server")
    }

    private func ensureSuccess(_ response: CoreJSON, _ action: String) throws {
        if !response.has("result") {
            let message = response.path("error").path("message").asText("unknown error") ?? "unknown error"
            throw UsageError("Codex " + action + " failed: " + message)
        }
    }

    /// A `LinkedBlockingQueue<JsonNode>` with a deadline-bounded `poll`.
    private final class MessageQueue: @unchecked Sendable {
        private let condition = NSCondition()
        private var items: [CoreJSON] = []

        func offer(_ item: CoreJSON) {
            condition.lock()
            items.append(item)
            condition.signal()
            condition.unlock()
        }

        func poll(until deadline: Date) -> CoreJSON? {
            condition.lock()
            defer { condition.unlock() }
            while items.isEmpty {
                if !condition.wait(until: deadline) {
                    break
                }
            }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    /// Reads newline-delimited JSON from the server's stdout on its own thread. It polls
    /// so `stop()` ends it even when something still holds the pipe open; a line that
    /// isn't JSON is dropped (Java's reader stopped at the first IOException instead —
    /// either way the waiting side owns timeout/error reporting).
    private final class LineReaderThread: @unchecked Sendable {
        private let fd: Int32
        private let queue: MessageQueue
        private let lock = NSLock()
        private var stopped = false
        private let finished = DispatchSemaphore(value: 0)

        init(fd: Int32, queue: MessageQueue) {
            self.fd = fd
            self.queue = queue
        }

        func start() {
            let thread = Thread { [self] in
                run()
                finished.signal()
            }
            thread.name = "codex-usage-reader"
            thread.start()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            _ = finished.wait(timeout: .now() + 2)
        }

        private var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        private func run() {
            var pending = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !isStopped {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pfd, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                if n == 0 {
                    emit(&pending, final: true)
                    return
                }
                pending.append(contentsOf: buffer[0..<n])
                emit(&pending, final: false)
            }
        }

        private func emit(_ pending: inout [UInt8], final: Bool) {
            while let newline = pending.firstIndex(of: 0x0A) {
                deliver(Array(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
            if final && !pending.isEmpty {
                deliver(pending)
                pending.removeAll()
            }
        }

        private func deliver(_ bytes: [UInt8]) {
            var line = String(decoding: bytes, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if JavaText.isBlank(line) { return }
            if let message = try? CoreJSON.parse(line) {
                queue.offer(message)
            }
        }
    }
}
