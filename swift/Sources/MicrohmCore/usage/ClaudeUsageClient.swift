import Foundation

/// Reads subscription limits through the same OAuth usage endpoint as Claude Code.
final class ClaudeUsageClient: @unchecked Sendable {

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let requestTimeout: TimeInterval = 12

    private let session: URLSession

    convenience init() {
        let config = URLSessionConfiguration.ephemeral
        // Java's HttpClient connect timeout was 8s; URLSession has no separate connect
        // timeout, so the request timeout below bounds the whole exchange.
        config.timeoutIntervalForRequest = ClaudeUsageClient.requestTimeout
        self.init(session: URLSession(configuration: config))
    }

    init(session: URLSession) {
        self.session = session
    }

    func load() throws -> UsageSnapshot {
        let accessToken = try ClaudeUsageClient.readAccessToken()
        var request = URLRequest(url: ClaudeUsageClient.usageURL, timeoutInterval: ClaudeUsageClient.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (status, body) = try send(request)
        if status == 401 || status == 403 {
            throw UsageError("Claude login expired; run 'claude auth login' and retry")
        }
        if status / 100 != 2 {
            throw UsageError("Claude usage API returned HTTP \(status)")
        }
        let root: CoreJSON
        do {
            root = try CoreJSON.parse(body)
        } catch {
            throw UsageError("Claude usage API returned unreadable JSON: \(error)")
        }
        return ClaudeUsageClient.parse(root)
    }

    /// A blocking round trip — the Java client's `HttpClient.send`.
    private func send(_ request: URLRequest) throws -> (Int, Data) {
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var status = 0
            var data = Data()
            var error: Error?
        }
        let box = Box()
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            done.signal()
        }
        task.resume()
        done.wait()
        if let error = box.error {
            throw UsageError("Claude usage request failed: \(error.localizedDescription)")
        }
        return (box.status, box.data)
    }

    static func parse(_ root: CoreJSON) -> UsageSnapshot {
        var limits: [UsageSnapshot.Limit] = []
        addWindow(&limits, root, "five_hour", "Current session (5 hours)")
        addWindow(&limits, root, "seven_day", "Current week (all models)")
        addWindow(&limits, root, "seven_day_opus", "Current week (Opus)")
        addWindow(&limits, root, "seven_day_sonnet", "Current week (Sonnet)")
        addWindow(&limits, root, "seven_day_overage_included", "Current week (Fable)")
        addModelScopedWindows(&limits, root)

        var statistics: [UsageSnapshot.Statistic] = []
        addExtraUsageCredits(&limits, &statistics, root)

        let note = limits.isEmpty
            ? "Claude returned no active subscription limit windows."
            : "Claude Code uses a vendor-internal OAuth endpoint; its schema may change."
        return UsageSnapshot("Claude Code subscription", "Claude Code OAuth usage", limits, statistics, note)
    }

    private static func addWindow(_ limits: inout [UsageSnapshot.Limit], _ root: CoreJSON,
                                  _ field: String, _ label: String) {
        let window = root.path(field)
        if !window.isObject || !window.hasNonNull("utilization") {
            return
        }
        let percent = JavaText.round(window.path("utilization").asDouble())
        let reset = parseInstant(window.path("resets_at").asText(nil))
        var detail: String?
        if window.hasNonNull("used_dollars") && window.hasNonNull("limit_dollars") {
            detail = "$" + fixed2(window.path("used_dollars").asDouble())
                + " of $" + fixed2(window.path("limit_dollars").asDouble())
        }
        limits.append(UsageSnapshot.Limit(label, percent, reset, detail))
    }

    /// Newer Claude responses can carry named weekly model buckets instead of (or in
    /// addition to) the legacy seven_day_* fields.
    private static func addModelScopedWindows(_ limits: inout [UsageSnapshot.Limit], _ root: CoreJSON) {
        var scoped = root.path("model_scoped")
        if !scoped.isArray {
            scoped = root.path("rate_limits").path("model_scoped")
        }
        if scoped.isArray {
            for window in scoped.elements {
                let model = window.path("display_name").asText("") ?? ""
                let utilization = window.path("utilization")
                if !JavaText.isBlank(model) && utilization.isNumber && !hasModelWindow(limits, model) {
                    let fraction = utilization.asDouble()
                    let usedPercent = JavaText.round(fraction <= 1 ? fraction * 100 : fraction)
                    addModelWindow(&limits, model, usedPercent, parseInstant(window.path("resets_at").asText(nil)))
                }
            }
        }

        let rawLimits = root.path("limits")
        if rawLimits.isArray {
            for window in rawLimits.elements {
                if window.path("kind").asText() != "weekly_scoped" { continue }
                let model = window.path("scope").path("model").path("display_name").asText("") ?? ""
                if !JavaText.isBlank(model) && window.path("percent").isNumber && !hasModelWindow(limits, model) {
                    addModelWindow(&limits, model, window.path("percent").asInt(),
                                   parseInstant(window.path("resets_at").asText(nil)))
                }
            }
        }
    }

    /// Credit-metered (e.g. Enterprise) accounts report spend against a monthly dollar
    /// allotment instead of the five_hour/seven_day rate-limit windows above, so surface
    /// it as a limit too — otherwise it silently disappears whenever no rate-limit window
    /// is present.
    private static func addExtraUsageCredits(_ limits: inout [UsageSnapshot.Limit],
                                             _ statistics: inout [UsageSnapshot.Statistic], _ root: CoreJSON) {
        let extra = root.path("extra_usage")
        if !extra.isObject {
            return
        }
        let enabled = extra.path("is_enabled").asBoolean(false)
        statistics.append(UsageSnapshot.Statistic("Extra usage", enabled ? "Enabled" : "Disabled"))
        if !extra.hasNonNull("monthly_limit") || !extra.hasNonNull("used_credits")
            || !extra.hasNonNull("utilization") {
            return
        }
        // used_credits/monthly_limit are minor units (e.g. cents), scaled by decimal_places;
        // the API has no reset-date field for this window.
        let scale = pow(10.0, Double(extra.path("decimal_places").asInt(2)))
        let used = extra.path("used_credits").asDouble() / scale
        let limit = extra.path("monthly_limit").asDouble() / scale
        let currency = extra.path("currency").asText("USD") ?? "USD"
        let percent = JavaText.round(extra.path("utilization").asDouble())
        limits.append(UsageSnapshot.Limit("Monthly credits", percent, nil,
                                          money(used, currency) + " of " + money(limit, currency)))
    }

    private static func addModelWindow(_ limits: inout [UsageSnapshot.Limit], _ model: String,
                                       _ usedPercent: Int, _ reset: Date?) {
        limits.append(UsageSnapshot.Limit("Current week (" + model + ")", usedPercent, reset, nil))
    }

    private static func hasModelWindow(_ limits: [UsageSnapshot.Limit], _ model: String) -> Bool {
        let marker = "(" + model + ")"
        return limits.contains { $0.label.caseInsensitiveCompare("Current week " + marker) == .orderedSame }
    }

    /// `OffsetDateTime.parse(value).toInstant()`: an offset is required.
    private static func parseInstant(_ value: String?) -> Date? {
        guard let value, !JavaText.isBlank(value) else {
            return nil
        }
        return IsoInstant.parse(value)
    }

    private static func money(_ value: Double, _ currency: String) -> String {
        let symbol = currency.caseInsensitiveCompare("USD") == .orderedSame ? "$" : currency + " "
        return symbol + fixed2(value)
    }

    /// `String.format(Locale.ROOT, "%.2f", value)` (Java rounds half-up on the decimal value).
    static func fixed2(_ value: Double) -> String {
        let decimal = NSDecimalNumber(value: value)
        let handler = NSDecimalNumberHandler(roundingMode: .plain, scale: 2, raiseOnExactness: false,
                                             raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)
        let rounded = decimal.rounding(accordingToBehavior: handler)
        return String(format: "%.2f", rounded.doubleValue)
    }

    private static func readAccessToken() throws -> String {
        if let keychain = try readMacKeychain() {
            return try tokenFromCredentials(keychain)
        }
        let credentials = PathCompat.userHome.appendingPathComponent(".claude").appendingPathComponent(".credentials.json")
        if PathCompat.isRegularFile(credentials) {
            guard let text = try? String(contentsOf: credentials, encoding: .utf8) else {
                throw UsageError("Claude Code credentials at \(credentials.path) could not be read")
            }
            return try tokenFromCredentials(text)
        }
        throw UsageError("Claude Code OAuth credentials were not found; run 'claude auth login'")
    }

    /// `security find-generic-password -s "Claude Code-credentials" -w`: the JSON Claude
    /// Code keeps in the login keychain. Nil when there is no such item.
    private static func readMacKeychain() throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // read concurrently so a large item can't fill the pipe and stall the process
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if !ProcessWaiter.wait(process, timeout: 5) {
            ProcessWaiter.kill(process)
            throw UsageError("Timed out reading Claude Code credentials from Keychain")
        }
        reader.wait()
        if process.terminationStatus != 0 {
            return nil
        }
        return String(decoding: box.data, as: UTF8.self)
    }

    private static func tokenFromCredentials(_ json: String) throws -> String {
        let credentials: CoreJSON
        do {
            credentials = try CoreJSON.parse(json)
        } catch {
            throw UsageError("Claude Code credentials are not valid JSON")
        }
        let token = credentials.path("claudeAiOauth").path("accessToken").asText("") ?? ""
        if JavaText.isBlank(token) {
            throw UsageError("Claude Code credentials do not contain an OAuth access token")
        }
        return token
    }
}

/// `Process.waitFor(timeout)` / `destroyForcibly()` for Foundation's `Process`.
enum ProcessWaiter {

    /// Waits up to `timeout` seconds; true when the process exited.
    static func wait(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                return false
            }
            usleep(5_000)
        }
        return true
    }

    /// SIGKILL (`destroyForcibly`).
    static func kill(_ process: Process) {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
