import Foundation
import MicrohmMux
import MicrohmShared

/// The MCP session controller: the tools agents running in micro-harness-manager's
/// sessions use to list, read, drive, watch, start and end each other. Everything
/// harness-specific (state detection, chrome masking, transcripts) lives here, on top of
/// the daemon's generic input/capture/wait/watch.
///
/// Per session the controller keeps its own `SessionTracker` (state detection fed by every
/// capture it takes); per (caller, session) what that caller last read, so reads are
/// incremental; and the pending one-shot notifications and spawn prompts, which a
/// background monitor re-evaluates — once a second while anything is pending, and at once
/// when the daemon's event stream reports activity in a session involved. The monitor runs
/// while the MCP server does (`serverStarted`/`serverStopped`); it reconnects the event
/// stream with backoff when the daemon restarts or is not running yet.
///
/// Thread-safe: tool calls arrive on concurrent request threads.
public final class SessionController: McpToolset, @unchecked Sendable {

    static let TOOL_LIST = "list"
    static let TOOL_READ = "read"
    static let TOOL_SEND = "send"
    static let TOOL_KEYS = "keys"
    static let TOOL_NOTIFY = "notify"
    static let TOOL_SPAWN = "spawn"
    static let TOOL_KILL = "kill"

    /// Label a spawned session carries naming the session whose agent spawned it.
    static let LABEL_SPAWNED_BY = "spawned-by"

    static let MAX_BODY_CHARS = 8000
    /// Cap on the changed lines a read shows when only status lines changed.
    static let MAX_STATUS_CHARS = 2000
    static let NOTICE_PREFIX = "[micro-harness-manager] "
    /// Appended to a read's header when the daemon only gave plain text.
    static let OLD_DAEMON_NOTE = "(old daemon: no selection/cursor markers)"
    static let OLD_DAEMON_REPLACED = "It is replaced automatically once every session has ended and a new one starts."
    /// A multi-line paste the session's program would receive as typed lines.
    static let MULTI_LINE_REFUSED = "this session doesn't accept multi-line pastes; send one line at a time"
        + " (line breaks and control characters can only be pasted where the program enables bracketed paste)"
    static let DAEMON_UNREACHABLE = "the session daemon is not answering; try again shortly"

    /// Whether `ch`, written raw (no bracketed paste), would act as a key rather than as
    /// text: a line break or any other C0 control except tab, DEL, or a C1 control.
    static func actsAsKeyOutsidePaste(_ ch: UInt32) -> Bool {
        (ch < 0x20 && ch != 0x09) || (ch >= 0x7f && ch <= 0x9f)
    }

    /// How many times an owed Enter (after its text was pasted) is tried before giving up.
    static let MAX_ENTER_ATTEMPTS = 5

    /// Every duration the controller waits on (seconds, or milliseconds where named),
    /// injectable so tests run instantly.
    public struct Timings: Sendable {
        var tick: TimeInterval
        var enterDelay: TimeInterval
        var shortQuiescence: TimeInterval
        var longQuiescence: TimeInterval
        var notifyTtl: TimeInterval
        var promptTimeout: TimeInterval
        var keysQuietMs: Int64
        var keysTimeoutMs: Int64
        var watchQuietMs: Int64
        var watchBackoffMin: TimeInterval
        var watchBackoffMax: TimeInterval

        public static let DEFAULT = Timings(tick: 1, enterDelay: 0.4, shortQuiescence: 5, longQuiescence: 20,
                                            notifyTtl: 30 * 60, promptTimeout: 120, keysQuietMs: 300,
                                            keysTimeoutMs: 3000, watchQuietMs: 500, watchBackoffMin: 1,
                                            watchBackoffMax: 30)
    }

    /// `Thread.sleep`, replaceable in tests.
    typealias Sleeper = (TimeInterval) throws -> Void
    /// Runs a delivery off the monitor (its own thread in production; inline in tests).
    typealias Executor = (@escaping () -> Void) -> Void

    /// What a notify waits for.
    enum Trigger: String, CaseIterable {
        case FINISHED = "finished"
        case NEEDS_INPUT = "needs-input"
        case EXITED = "exited"
        case ANY_CHANGE = "any-change"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .FINISHED: return "finished"
            case .NEEDS_INPUT: return "needs input"
            case .EXITED: return "exited"
            case .ANY_CHANGE: return "changed"
            }
        }

        static func fromId(_ id: String) -> Trigger? {
            Trigger(rawValue: id)
        }
    }

    private let daemon: DaemonControl
    private let registry: SessionRegistry
    private let spawner: SessionSpawner
    private let clock: MicrohmClock
    private let transcripts: TranscriptLocator
    private let sleeper: Sleeper
    private let deliveries: Executor
    private let timings: Timings
    private var toolList: [ToolDef] = []
    private let compat: DaemonCompat

    private let stateLock = NSLock()
    private var trackers: [String: SessionTracker] = [:]
    /// Keyed by `seenKey`.
    private var seen: [String: Seen] = [:]
    /// Guarded by `pendingLock`, as is `prompts`.
    private var notifications: [Notification] = []
    private var prompts: [PromptDelivery] = []
    private let pendingLock = NSRecursiveLock()
    /// Display names (lower case) of spawns in flight, between their uniqueness check and
    /// their creation returning; guarded by `stateLock`.
    private var spawningDisplays: Set<String> = []

    private let logs = SessionLogs()
    /// Whether logs are kept at all (the user's setting, asked on each use).
    private let sessionLogs: () -> Bool
    /// The logs being kept, by file path: whose, of which session, in which folder.
    private var mirrors: [String: Mirror] = [:]
    private let mirrorLock = NSRecursiveLock()

    /// The monitor's wake-up: a pending flag (one permit) under a condition.
    private let wakeCondition = NSCondition()
    private var wakePending = false
    /// Guarded by `monitorLock`.
    private let monitorLock = NSLock()
    private var monitor: MonitorThread?

    /// The production controller: standard transcript locations, real sleeps, deliveries on
    /// their own threads.
    public convenience init(_ daemon: DaemonControl, _ registry: SessionRegistry, _ spawner: SessionSpawner,
                            _ clock: MicrohmClock = SystemClock.shared) {
        let standard = HarnessTranscripts.standard()
        self.init(daemon, registry, spawner, clock, standard.locator, { Thread.sleep(forTimeInterval: $0) },
                  { task in Thread.detachNewThread(task) }, Timings.DEFAULT, { AppSettings.mcpSessionLogs() })
    }

    init(_ daemon: DaemonControl, _ registry: SessionRegistry, _ spawner: SessionSpawner, _ clock: MicrohmClock,
         _ transcripts: @escaping TranscriptLocator, _ sleeper: @escaping Sleeper, _ deliveries: @escaping Executor,
         _ timings: Timings, _ sessionLogs: @escaping () -> Bool) {
        self.daemon = daemon
        self.registry = registry
        self.spawner = spawner
        self.clock = clock
        self.transcripts = transcripts
        self.sleeper = sleeper
        self.deliveries = deliveries
        self.timings = timings
        self.sessionLogs = sessionLogs
        self.compat = DaemonCompat { try daemon.daemonPid() }
        self.toolList = SessionController.toolDefs()
    }

    // MARK: - McpToolset

    public func tools() -> [ToolDef] {
        toolList
    }

    public func call(_ caller: String?, _ tool: String, _ arguments: CoreJSON) -> ToolResult {
        let args = arguments.isObject ? arguments : CoreJSON.object([])
        do {
            compat.revalidate()
            let text: String
            switch tool {
            case SessionController.TOOL_LIST: text = try list(caller)
            case SessionController.TOOL_READ: text = try read(caller, args)
            case SessionController.TOOL_SEND: text = try send(caller, args)
            case SessionController.TOOL_KEYS: text = try keys(caller, args)
            case SessionController.TOOL_NOTIFY: text = try notify(caller, args)
            case SessionController.TOOL_SPAWN: text = try spawn(caller, args)
            case SessionController.TOOL_KILL: text = try kill(caller, args)
            default: throw ToolError("unknown tool: " + tool)
            }
            return ToolResult.ok(text)
        } catch let e as ToolError {
            return ToolResult.error(e.message)
        } catch {
            Log.debug("tool \(tool) failed: \(error)", tag: "control")
            return ToolResult.error(tool + " failed: " + errorMessage(error))
        }
    }

    // MARK: - phone page

    /// A running session as the phone page lists it; `state` is a `SessionState` name, or
    /// `EXITED`.
    public struct SessionSummary: Equatable, Sendable {
        public let name: String
        public let display: String?
        public let harness: String
        public let state: String
        public let project: String

        public init(_ name: String, _ display: String?, _ harness: String, _ state: String, _ project: String) {
            self.name = name
            self.display = display
            self.harness = harness
            self.state = state
            self.project = project
        }
    }

    /// One session's screen as plain text (no markers), with what the page shows above it.
    public struct ScreenView: Equatable, Sendable {
        public let name: String
        public let display: String?
        public let harness: String
        public let state: String
        public let reason: String
        public let title: String
        public let text: String
        public let columns: Int
        public let rows: Int
        public let outputBytes: Int64
        public let alive: Bool

        public init(_ name: String, _ display: String?, _ harness: String, _ state: String, _ reason: String,
                    _ title: String, _ text: String, _ columns: Int, _ rows: Int, _ outputBytes: Int64, _ alive: Bool) {
            self.name = name
            self.display = display
            self.harness = harness
            self.state = state
            self.reason = reason
            self.title = title
            self.text = text
            self.columns = columns
            self.rows = rows
            self.outputBytes = outputBytes
            self.alive = alive
        }
    }

    /// The running sessions, classified, in the daemon's order. No daemon is no sessions: it
    /// exits with its last session and starts again with the next.
    public func summaries() throws -> [SessionSummary] {
        compat.revalidate()
        var out: [SessionSummary] = []
        for info in try daemon.list() where info.alive {
            // (its program ended: the daemon drops it shortly, the phone lists it as ended)
            let target = self.target(info)
            let state = try observe(target)?.classification.state.name ?? "EXITED"
            out.append(SessionSummary(target.name, target.display, target.harness.id, state, target.project))
        }
        return out
    }

    /// `session`'s screen (by name or display name); nil once it has exited. Throws a
    /// message for the user when no session matches or the daemon does not answer.
    public func screen(_ session: String) throws -> ScreenView? {
        compat.revalidate()
        let target: Target
        do {
            target = try resolve(session)
        } catch let e as ToolError where e.kind == .unreachable {
            if !reachable() {
                // no daemon: it exits with its last session, so this one has ended
                return nil
            }
            throw e
        }
        guard let obs = try observe(target) else { return nil }
        let c = obs.classification
        let capture = obs.capture
        return ScreenView(target.name, target.display, target.harness.id, c.state.name, c.reason, capture.title,
                          obs.plain, capture.columns, capture.rows, capture.outputBytes, capture.alive)
    }

    /// A registered session that is not running: what the phone page offers to resume.
    /// `conversation` is whether its harness conversation can be picked up again (an id was
    /// recorded); without one, resuming starts the harness fresh in its folder.
    public struct EndedSession: Equatable, Sendable {
        public let name: String
        public let display: String?
        public let harness: String
        public let project: String
        public let conversation: Bool
        public let created: Date?
    }

    /// Registered sessions the daemon is not running, newest first. No daemon: all of them.
    public func ended() throws -> [EndedSession] {
        let live = Set(try daemon.list().filter(\.alive).map(\.name))
        return registry.sessions()
            .filter { !live.contains($0.sessionName) }
            .sorted { $0.createdAt > $1.createdAt }
            .map { EndedSession(name: $0.sessionName, display: $0.displayName, harness: $0.harnessType.id,
                                project: $0.projectPath, conversation: $0.harnessSessionIdOpt != nil,
                                created: $0.createdAt) }
    }

    /// Starts the ended registered session `session` (its name or sidebar name) again, as
    /// the window's Resume does; returns its name.
    public func resume(_ session: String) throws -> String {
        compat.revalidate()
        let live = Set(try daemon.list().filter(\.alive).map(\.name))
        guard let entry = registry.sessions().first(where: {
            $0.sessionName == session || ($0.displayName.map { $0.caseInsensitiveCompare(session) == .orderedSame } ?? false)
        }) else {
            throw ToolError("no saved session named " + session)
        }
        if live.contains(entry.sessionName) {
            throw ToolError(entry.sessionName + " is already running")
        }
        forget(entry.sessionName)
        try spawner.resume(entry)
        return entry.sessionName
    }

    /// Scrollback lines as plain text, oldest first, and the count to pass back as `since`
    /// next time; `alternateScreen` while a full-screen program runs.
    public struct HistoryView: Equatable, Sendable {
        public let text: String
        public let added: Int64
        public let alternateScreen: Bool

        public init(_ text: String, _ added: Int64, _ alternateScreen: Bool) {
            self.text = text
            self.added = added
            self.alternateScreen = alternateScreen
        }
    }

    /// The scrollback lines `session` added after the first `since` (0: all it still
    /// holds); nil once it has exited, or from a daemon without history.
    public func history(_ session: String, _ since: Int64) throws -> HistoryView? {
        compat.revalidate()
        let target = try resolve(session)
        do {
            guard let h = try daemon.captureSince(target.name, .TEXT, since)?.history else { return nil }
            return HistoryView(h.text, h.added, h.alternateScreen)
        } catch where DaemonCompat.isUnsupported(error) {
            return nil
        }
    }

    /// A screen as the daemon's styled capture: the redraw stream that reproduces it, with
    /// the size to replay it at.
    public struct AnsiView: Equatable, Sendable {
        public let text: String
        public let columns: Int
        public let rows: Int

        public init(_ text: String, _ columns: Int, _ rows: Int) {
            self.text = text
            self.columns = columns
            self.rows = rows
        }
    }

    /// `session`'s screen with its styles; nil once it has exited, or from a daemon without
    /// the styled capture.
    public func ansi(_ session: String) throws -> AnsiView? {
        compat.revalidate()
        let target = try resolve(session)
        do {
            return try daemon.capture(target.name, .ANSI).map { AnsiView($0.text, $0.columns, $0.rows) }
        } catch where DaemonCompat.isUnsupported(error) {
            return nil
        }
    }

    /// Resizes `session` (by name or display name) for every viewer.
    public func resize(_ session: String, _ columns: Int, _ rows: Int) throws {
        compat.revalidate()
        try daemon.resize(try resolve(session).name, columns, rows)
    }

    /// Starts the background monitor (idempotent).
    public func serverStarted() {
        monitorLock.lock(); defer { monitorLock.unlock() }
        if monitor != nil {
            return
        }
        let m = MonitorThread()
        monitor = m
        let thread = Thread { [self] in
            monitorLoop(m)
            m.done.signal()
        }
        thread.name = "mhm-control-monitor"
        m.thread = thread
        thread.start()
    }

    /// Stops the background monitor, waiting briefly for it to close its event stream.
    /// Pending notifications and prompts are kept for the next start.
    public func serverStopped() {
        monitorLock.lock()
        let stopping = monitor
        monitor = nil
        monitorLock.unlock()
        if let stopping {
            stopping.stopped = true
            wake()
            _ = stopping.done.wait(timeout: .now() + 1)
        }
    }

    /// Whether `m` is still the current monitor — a monitor replaced by a quick stop/start
    /// that outlived its join notices here and ends.
    private func isCurrentMonitor(_ m: MonitorThread) -> Bool {
        monitorLock.lock(); defer { monitorLock.unlock() }
        return monitor === m
    }

    // MARK: - tools

    private func list(_ caller: String?) throws -> String {
        let infos = try daemon.list()
        if infos.isEmpty && !reachable() {
            return "no sessions are running (" + SessionController.DAEMON_UNREACHABLE + ")"
        }
        forgetAllBut(Set(infos.map(\.name)))
        if infos.isEmpty {
            return "no sessions are running"
        }
        let targets = infos.map { self.target($0) }
        let callerDir = SessionController.callerDir(caller, targets)
        var sb = ""
        for (i, info) in infos.enumerated() {
            let target = targets[i]
            let obs = try observe(target)
            let state = obs?.classification.state.name ?? "EXITED"
            let pid = obs?.capture.processId ?? info.pid
            let transcript = transcriptOf(target, pid, targets) ?? "-"
            sb += target.name + " · " + (target.display ?? "-")
            sb += " · " + target.harness.id
            sb += " · " + state
            sb += " · " + target.project
            sb += " · transcript: " + transcript
            sb += " · log: " + (keptLog(caller, callerDir, target)?.path ?? "-")
            if target.name == caller {
                sb += " (you)"
            }
            sb += "\n"
        }
        return JavaText.stripTrailing(sb)
    }

    private func read(_ caller: String?, _ args: CoreJSON) throws -> String {
        let infos = try liveSessions()
        let target = try resolve(try SessionController.requiredText(args, "session"), infos)
        let full = args.path("full").asBoolean(false)
        guard let obs = try observe(target) else {
            return target.name + " · exited"
        }
        let pid = obs.capture.processId
        let all = infos.map { self.target($0) }
        let log = logOf(caller, SessionController.callerDir(caller, all), target)
        return render(caller, target, obs, full) {
            SessionController.earlierOutputNote(self.transcriptOf(target, pid, all), log)
        }
    }

    /// Where a whole-screen read says the earlier output is; nil when nowhere.
    static func earlierOutputNote(_ transcript: String?, _ log: URL?) -> String? {
        if transcript == nil && log == nil {
            return nil
        }
        var note = "… (earlier output is in "
        if let transcript {
            note += "the transcript, " + transcript + (log != nil ? ", and in " : "")
        }
        if let log {
            note += "the screen log, " + log.path
        }
        note += ": grep or tail " + (transcript != nil && log != nil ? "them" : "it") + ")"
        return note
    }

    // MARK: - screen logs

    /// Whose log, of which session (and harness), in which folder.
    private final class Mirror {
        var callers: Set<String> = []
        let session: String
        let harness: HarnessType
        let dir: URL

        init(_ session: String, _ harness: HarnessType, _ dir: URL) {
            self.session = session
            self.harness = harness
            self.dir = dir
        }
    }

    /// The project folder of the calling session, where its logs go; nil when the caller is
    /// not a running session with a project folder.
    private static func callerDir(_ caller: String?, _ all: [Target]) -> URL? {
        guard let caller, !JavaText.isBlank(caller),
              let project = all.first(where: { $0.name == caller })?.project, project != "-" else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: project)
    }

    /// `target`'s log for `caller` when one is being kept for it and is there (not one that
    /// could not be written), without starting one: what list shows.
    private func keptLog(_ caller: String?, _ callerDir: URL?, _ target: Target) -> URL? {
        guard let callerDir, let caller, target.name != caller, sessionLogs() else {
            return nil
        }
        let file = SessionLogs.file(callerDir, target.name)
        mirrorLock.lock()
        let kept = mirrors[file.path]?.callers.contains(caller) ?? false
        mirrorLock.unlock()
        var st = stat()
        return kept && lstat(file.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG ? file : nil
    }

    /// `target`'s log for `caller`, brought up to date and kept so from now on: what a read
    /// starts, so a session's output is copied into the caller's project only once the
    /// caller has looked at that session. Nil for the caller's own session, without a
    /// caller folder, or when it can't be written.
    private func logOf(_ caller: String?, _ callerDir: URL?, _ target: Target) -> URL? {
        guard let callerDir, let caller, target.name != caller, sessionLogs() else {
            return nil
        }
        let file = SessionLogs.file(callerDir, target.name)
        // agents sharing a project share the file: it is kept while any of them is running
        mirrorLock.lock()
        let mirror = mirrors[file.path] ?? Mirror(target.name, target.harness, callerDir)
        mirror.callers.insert(caller)
        mirrors[file.path] = mirror
        mirrorLock.unlock()
        do {
            try syncLog(file, mirror)
            return file
        } catch {
            Log.debug("could not write \(file.path): \(error)", tag: "control")
            if let e = error as? ToolError, e.kind == .unreachable {
                return file
            }
            // kept all the same: the next sample tries again (the folder may come back)
            return nil
        }
    }

    /// Appends what is new in the mirrored session to its log; stops keeping a log whose
    /// session has ended (after its last lines).
    private func syncLog(_ file: URL, _ mirror: Mirror) throws {
        let log = try logs.open(mirror.dir, mirror.session)
        log.lock.lock(); defer { log.lock.unlock() }
        var capture = try captureForLog(mirror.session, log.since())
        if let c = capture, log.pid != 0, c.processId != log.pid {
            try log.restarted(c.processId, clock.instant())
            capture = try captureForLog(mirror.session, 0)
        }
        guard let c = capture else {
            if !reachable() {
                throw ToolError.unreachable()
            }
            stopLog(file)
            return
        }
        let plugin = HarnessPlugins.of(mirror.harness)
        try log.record(c, { plugin.maskChrome($0) }, clock.instant())
        if !c.alive {
            stopLog(file)
        }
    }

    private func stopLog(_ file: URL) {
        mirrorLock.lock()
        mirrors.removeValue(forKey: file.path)
        mirrorLock.unlock()
        logs.close(file)
    }

    /// The screen as text with the scrollback added since `since`.
    private func captureForLog(_ name: String, _ since: Int64) throws -> SessionCapture? {
        try daemon.captureSince(name, .TEXT, since)
    }

    /// One pass over the logs being kept: drops those whose caller has gone (all of them
    /// once the setting is off), and brings the rest up to date.
    private func syncLogs() throws {
        mirrorLock.lock()
        let kept = mirrors
        mirrorLock.unlock()
        if kept.isEmpty {
            return
        }
        if !sessionLogs() { // turned off: the logs kept so far stay as they are
            kept.keys.forEach { stopLog(URL(fileURLWithPath: $0)) }
            return
        }
        let infos = try daemon.list()
        if infos.isEmpty && !reachable() {
            return
        }
        let live = Set(infos.map(\.name))
        for (path, mirror) in kept {
            mirrorLock.lock()
            mirror.callers.formIntersection(live)
            let empty = mirror.callers.isEmpty
            mirrorLock.unlock()
            let file = URL(fileURLWithPath: path)
            if empty {
                stopLog(file)
                continue
            }
            do {
                try syncLog(file, mirror)
            } catch {
                Log.debug("could not update \(path): \(error)", tag: "control")
            }
        }
    }

    /// The session's transcript as list shows it: the file, or — for a claude-code session
    /// whose id is unknown while other claude-code sessions share its project — the folder
    /// with a note. Nil when there is none. `all` is every live session.
    private func transcriptOf(_ target: Target, _ pid: Int64, _ all: [Target]) -> String? {
        let id = target.entry?.harnessSessionIdOpt
        let siblings = all.filter { $0.harness == target.harness && $0.project == target.project }.count
        guard let found = transcripts(target.harness, URL(fileURLWithPath: target.project), id, pid) else {
            return nil
        }
        if id == nil && target.harness == .claudeCode && siblings > 1 {
            // the newest file there may well be a sibling's: point at the folder
            return found.deletingLastPathComponent().path + "/" + " (id unknown and other claude-code sessions"
                + " share this project: one of these files, not necessarily the newest)"
        }
        return found.path
    }

    private func send(_ caller: String?, _ args: CoreJSON) throws -> String {
        let target = try resolve(try SessionController.requiredText(args, "session"))
        guard let textNode = args.get("text"), textNode.isTextual else {
            throw ToolError("text is required (a string)")
        }
        let enter = args.path("enter").asBoolean(true)
        try SessionController.refuseSelf(caller, target, "send to")
        let text = textNode.asText()
        if text.isEmpty && !enter {
            throw ToolError("nothing to send: text is empty and enter is false")
        }
        try type(target.name, text, enter, false, true) {}
        return "sent to " + target.name
    }

    private func keys(_ caller: String?, _ args: CoreJSON) throws -> String {
        let target = try resolve(try SessionController.requiredText(args, "session"))
        guard let keysNode = args.get("keys"), keysNode.isArray, !keysNode.isEmpty else {
            throw ToolError("keys is required: a non-empty array of key names, e.g. [\"Down\",\"Enter\"]")
        }
        var keys: [String] = []
        for k in keysNode.elements {
            if !k.isTextual || k.asText().isEmpty {
                throw ToolError("every key must be a non-empty string, e.g. \"Enter\", \"y\", \"C-c\"")
            }
            keys.append(k.asText())
        }
        if !compat.has(.INPUT) {
            throw ToolError(keysNeedNewerDaemon())
        }
        guard let before = try capture(target.name) else {
            throw ToolError(target.name + " has exited")
        }
        do {
            try daemon.input(target.name, nil, false, keys)
        } catch where DaemonCompat.isUnsupported(error) {
            compat.markMissing(.INPUT)
            throw ToolError(keysNeedNewerDaemon())
        }
        if compat.has(.WAIT) {
            do {
                _ = try daemon.awaitQuiet(target.name, before.capture.outputBytes, timings.keysQuietMs,
                                          timings.keysTimeoutMs)
            } catch where DaemonCompat.isUnsupported(error) {
                compat.markMissing(.WAIT)
            }
        }
        guard let obs = try observe(target) else {
            return target.name + " · exited"
        }
        return render(caller, target, obs, true)
    }

    private func notify(_ caller: String?, _ args: CoreJSON) throws -> String {
        guard let caller, !JavaText.isBlank(caller) else {
            throw ToolError("notify only works from a session micro-harness-manager launched: the "
                            + "notification is typed into your session, and this connection does not say which "
                            + "session that is")
        }
        guard let on = Trigger.fromId(args.path("on").asText("") ?? "") else {
            throw ToolError("on must be one of: finished, needs-input, exited, any-change")
        }
        let requested = try SessionController.sessionsArgument(args)
        let infos = try liveSessions()
        guard let callerInfo = infos.first(where: { $0.name == caller }) else {
            throw ToolError("your session " + caller + " is not a running session, so a "
                            + "notification could not be delivered to it")
        }
        if target(callerInfo).harness == .shell {
            throw ToolError("notify cannot deliver to " + caller + ": it is a plain shell session, where the "
                            + "notification line would be typed at the shell prompt and run as a command. Notifications "
                            + "only go to agent sessions (claude-code, codex, …); poll with read instead")
        }
        // resolve and validate every session before registering any, so a failure registers nothing
        var targets: [Target] = []
        for argument in requested {
            let target = try resolve(argument, infos)
            if target.name == caller {
                throw ToolError("notify watches other sessions, not your own (" + caller + ")")
            }
            if !targets.contains(where: { $0.name == target.name }) {
                targets.append(target)
            }
        }
        var observed: [String: Observation?] = [:]
        for target in targets {
            observed[target.name] = .some(try observe(target))
        }
        var replies: [String] = []
        for target in targets {
            guard let o = observed[target.name] ?? nil, o.capture.alive else {
                replies.append(target.name + " has already exited; nothing registered")
                continue
            }
            // a session whose spawn prompt is not typed in yet is about to work on it
            let awaitPrompt = (on == .FINISHED || on == .NEEDS_INPUT) && promptPending(target.name)
            let state = awaitPrompt ? SessionState.working : o.classification.state
            if on == .FINISHED && state != .working {
                replies.append(target.name + " is already \(state.name) (not working); nothing registered")
                continue
            }
            if on == .NEEDS_INPUT && state == .waitingForInput {
                replies.append(target.name + " is already \(state.name); nothing registered")
                continue
            }
            var reply = "will notify " + caller + " when " + target.name + " " + on.id
            pendingLock.lock()
            let duplicate = notifications.contains {
                $0.message == nil && $0.caller == caller && $0.target == target.name && $0.trigger == on
            }
            if duplicate {
                reply = "already registered: " + reply
            } else {
                let n = Notification(caller, target.name, on, o.masked, clock.instant())
                n.awaitPrompt = awaitPrompt
                notifications.append(n)
            }
            pendingLock.unlock()
            replies.append(reply)
        }
        wake()
        return replies.joined(separator: "\n")
    }

    /// Whether a spawn prompt for `session` is still waiting or being typed in.
    private func promptPending(_ session: String) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return prompts.contains { $0.session == session }
    }

    private func spawn(_ caller: String?, _ args: CoreJSON) throws -> String {
        let harnessId = try SessionController.requiredText(args, "harness")
        guard let harness = try? HarnessType.fromId(harnessId) else {
            throw ToolError("unknown harness " + harnessId + "; one of: " + SessionController.harnessIds())
        }
        let project = try SessionController.expandProject(try SessionController.requiredText(args, "project"))
        let display = try SessionController.optionalText(args, "name").map(JavaText.strip)
        // the name becomes part of each line of list's reply: one with a line break (or
        // list's own separator) in it would let an agent forge rows other agents read
        if let d = display, d.utf16.count > 64
            || d.utf16.contains(where: { ($0 < 0x20) || ($0 >= 0x7f && $0 <= 0x9f) || $0 == 0x00B7 }) {
            throw ToolError("name must be at most 64 characters, on one line, without \"·\"")
        }
        let prompt = try SessionController.optionalText(args, "prompt")
        let labels: [String: String] = caller.map { JavaText.isBlank($0) ? [:] : [SessionController.LABEL_SPAWNED_BY: $0] } ?? [:]
        // the check and the creation are one step: a reservation keeps a concurrent spawn
        // from taking the same name before this one's label and registry row exist
        let reservation = display?.lowercased()
        if let reservation {
            stateLock.lock()
            let added = spawningDisplays.insert(reservation).inserted
            stateLock.unlock()
            if !added {
                throw ToolError("name already in use by a session being spawned; choose another")
            }
        }
        defer {
            if let reservation {
                stateLock.lock()
                spawningDisplays.remove(reservation)
                stateLock.unlock()
            }
        }
        if let wanted = display {
            // daemon.list(), not liveSessions(): a daemon that is not running has no
            // session to clash with, and the spawn below is what starts it.
            for info in try daemon.list() {
                let live = target(info)
                if (live.display.map { wanted.caseInsensitiveCompare($0) == .orderedSame } ?? false) || wanted == live.name {
                    throw ToolError("name already in use by " + live.name + "; choose another")
                }
            }
        }
        let name = try spawner.spawn(SpawnRequest(harness, project, display, labels))
        var reply = name + " started (" + harness.id + " in " + project.path + ")"
        if let prompt {
            pendingLock.lock()
            prompts.append(PromptDelivery(name, prompt, caller, clock.instant().addingTimeInterval(timings.promptTimeout)))
            pendingLock.unlock()
            wake()
            reply += "; the prompt will be typed in once it is ready at its prompt"
        }
        return reply
    }

    private func kill(_ caller: String?, _ args: CoreJSON) throws -> String {
        let target = try resolve(try SessionController.requiredText(args, "session"))
        try SessionController.refuseSelf(caller, target, "kill")
        try spawner.kill(target.name)
        forget(target.name)
        return "killed " + target.name
    }

    // MARK: - reading

    /// The read-style answer for `obs`, recording what `caller` has now seen; when it shows
    /// the whole screen it ends with `wholeScreenNote` (asked lazily: finding a transcript
    /// may fork lsof).
    private func render(_ caller: String?, _ target: Target, _ obs: Observation, _ full: Bool,
                        _ wholeScreenNote: () -> String? = { nil }) -> String {
        let header = SessionController.header(target, obs)
        let lines = obs.body
        let bytes = obs.capture.outputBytes
        stateLock.lock()
        let key = SessionController.seenKey(caller, target.name)
        let previous = seen[key]
        seen[key] = Seen(outputBytes: bytes, masked: obs.masked, lines: lines, plain: obs.plain)
        stateLock.unlock()
        if !full, let previous {
            // outputBytes is -1 (unknown) from a daemon that predates the counter
            let sameOutput = previous.outputBytes >= 0 && bytes >= 0 && previous.outputBytes == bytes
            if sameOutput || previous.plain == obs.plain {
                return header + " · unchanged"
            }
            if previous.masked == obs.masked {
                let changed = SessionController.changedLines(previous.lines, lines)
                return header + " · only status lines changed"
                    + (changed.isEmpty ? "" : "\n" + ScreenDiff.cap(changed, SessionController.MAX_STATUS_CHARS))
            }
            if let delta = ScreenDiff.newLines(previous.lines, lines) {
                return header + "\n… (\(delta.unchangedAbove) lines above already seen; full=true shows the whole screen)\n"
                    + ScreenDiff.cap(delta.lines, SessionController.MAX_BODY_CHARS)
            }
        }
        let screen = header + "\n" + ScreenDiff.cap(lines, SessionController.MAX_BODY_CHARS)
        return wholeScreenNote().map { screen + "\n" + $0 } ?? screen
    }

    private static func header(_ target: Target, _ obs: Observation) -> String {
        let c = obs.classification
        let title = obs.capture.title
        return target.name + " · " + target.harness.id + " · " + c.state.name + " (" + c.reason + ")"
            + (!JavaText.isBlank(title) ? " · " + JavaText.strip(title) : "")
            + (obs.annotated ? "" : " " + OLD_DAEMON_NOTE)
    }

    /// The lines of `current` that `previous` does not have (as many times): what changed
    /// when only masked lines did.
    private static func changedLines(_ previous: [String], _ current: [String]) -> [String] {
        var before: [String: Int] = [:]
        previous.forEach { before[$0, default: 0] += 1 }
        var changed: [String] = []
        for line in current {
            let n = before[line, default: 0] - 1
            before[line] = n
            if n < 0 {
                changed.append(line)
            }
        }
        return changed
    }

    /// A capture and whether it is annotated (an old daemon only gives plain text).
    private struct Captured {
        let capture: SessionCapture
        let annotated: Bool
    }

    /// The annotated screen, or plain text from a daemon that predates capture formats.
    private func capture(_ name: String) throws -> Captured? {
        if compat.has(.ANNOTATED_CAPTURE) {
            do {
                return try daemon.capture(name, .ANNOTATED).map { Captured(capture: $0, annotated: true) }
            } catch where DaemonCompat.isUnsupported(error) {
                compat.markMissing(.ANNOTATED_CAPTURE)
            }
        }
        return try daemon.capture(name, .TEXT).map { Captured(capture: $0, annotated: false) }
    }

    /// Captures the screen and classifies it; nil when the session is gone.
    private func observe(_ target: Target) throws -> Observation? {
        guard let captured = try capture(target.name) else {
            if !reachable() {
                throw ToolError.unreachable() // not gone: the daemon may be restarting
            }
            forget(target.name)
            return nil
        }
        let c = captured.capture
        let annotated = captured.annotated
        stateLock.lock()
        let tracker: SessionTracker
        if let existing = trackers[target.name], existing.harness == target.harness {
            tracker = existing
        } else {
            tracker = SessionTracker(target.harness, clock, timings.shortQuiescence, timings.longQuiescence)
            trackers[target.name] = tracker
        }
        stateLock.unlock()
        let text = c.text
        let plain = annotated ? ScreenDiff.plain(text) : ScreenDiff.trimmed(text)
        let classification = tracker.classify(
            SessionTracker.screen(plain, c.alive, clock.instant(), c.foregroundCommand, c.processId, c.title)) {
                self.probeQuiet(target.name, $0)
            }
        return Observation(capture: c, annotated: annotated, classification: classification,
                           masked: tracker.plugin.maskChrome(text), body: ScreenDiff.bodyLines(text), plain: plain,
                           tracker: tracker)
    }

    /// Whether the session's output has been quiet this long; false (no backdating) when
    /// the daemon predates wait.
    private func probeQuiet(_ name: String, _ quiet: TimeInterval) -> Bool {
        if !compat.has(.WAIT) {
            return false
        }
        do {
            let result = try daemon.awaitQuiet(name, -1, Int64((quiet * 1000).rounded()), 0)
            return result.quiet && result.alive
        } catch {
            if DaemonCompat.isUnsupported(error) {
                compat.markMissing(.WAIT)
            }
            return false
        }
    }

    // MARK: - resolution

    private func resolve(_ argument: String) throws -> Target {
        try resolve(argument, try liveSessions())
    }

    /// `DaemonControl.list`, but an empty answer from a daemon that does not answer is
    /// unreachable, never "no sessions".
    private func liveSessions() throws -> [SessionInfo] {
        let infos = try daemon.list()
        if infos.isEmpty && !reachable() {
            throw ToolError.unreachable()
        }
        return infos
    }

    /// Whether the daemon answers a ping; a failing ping counts as no.
    private func reachable() -> Bool {
        (try? daemon.ping()) ?? false
    }

    /// The daemon session `argument` names: a session name, else a registry display name
    /// (case-insensitive), else a `display` label.
    private func resolve(_ argument: String, _ infos: [SessionInfo]) throws -> Target {
        if let info = infos.first(where: { $0.name == argument }) {
            return target(info)
        }
        let targets = infos.map { self.target($0) }
        for registryName in [true, false] {
            let matches = targets.filter { t in
                let candidate = registryName ? t.entry?.displayName : t.labels[SessionLauncher.LABEL_DISPLAY]
                return candidate.map { $0.caseInsensitiveCompare(argument) == .orderedSame } ?? false
            }
            if matches.count == 1 {
                return matches[0]
            }
            if matches.count > 1 {
                throw ToolError("\"" + argument + "\" is ambiguous: " + matches.map(\.name).joined(separator: ", ")
                                + " — use the session name")
            }
        }
        let registered = registry.find(argument) ?? registry.sessions().first {
            $0.displayName.map { $0.caseInsensitiveCompare(argument) == .orderedSame } ?? false
        }
        if let registered {
            throw ToolError(registered.sessionName + " is not running")
        }
        throw ToolError("no such session: " + argument + " (list shows the sessions)")
    }

    private func target(_ info: SessionInfo) -> Target {
        let labels = info.labels
        let entry = registry.find(info.name)
        let harness = entry?.harnessType ?? SessionController.harnessFromLabel(labels[SessionLauncher.LABEL_HARNESS])
        let display = entry?.displayName.flatMap { JavaText.isBlank($0) ? nil : $0 }
            ?? SessionController.blankToNil(labels[SessionLauncher.LABEL_DISPLAY])
        let project = entry?.projectPath ?? SessionController.blankToNil(labels[SessionLauncher.LABEL_PROJECT])
            ?? info.workdir.path
        return Target(name: info.name, entry: entry, labels: labels, harness: harness, display: display, project: project)
    }

    private static func harnessFromLabel(_ id: String?) -> HarnessType {
        guard let id, let type = try? HarnessType.fromId(id) else { return .shell }
        return type
    }

    // MARK: - typing

    /// Types in two phases: pastes `text` (unless empty or `pasted` — a retry after the
    /// paste went in but the Enter did not), runs `onPasted`, then after the enter delay
    /// presses Enter. Against a daemon that predates input it falls back to the old
    /// send-keys op, which types the text as is and presses Enter after its own pause.
    ///
    /// `multiLineNeedsBracketedPaste`: when `text` has a line break or another control
    /// character, refuse the paste (nothing written, a paste refusal) unless the session's
    /// program enabled bracketed paste — otherwise each line would arrive as typed, the
    /// first newline would submit early, and ESC or ^C would act as keys.
    private func type(_ session: String, _ text: String, _ enter: Bool, _ pasted: Bool,
                      _ multiLineNeedsBracketedPaste: Bool, _ onPasted: () -> Void) throws {
        if !compat.has(.INPUT) {
            try typeLegacy(session, pasted ? "" : text, enter)
            onPasted()
            return
        }
        if !pasted && !text.isEmpty {
            let requireBracketed = multiLineNeedsBracketedPaste
                && text.utf16.contains { SessionController.actsAsKeyOutsidePaste(UInt32($0)) }
            do {
                try daemon.input(session, text, true, requireBracketed, nil)
            } catch {
                if requireBracketed && SessionController.isBracketedPasteRefusal(error) {
                    throw ToolError(SessionController.MULTI_LINE_REFUSED, .pasteRefusal)
                }
                if !DaemonCompat.isUnsupported(error) {
                    throw error
                }
                compat.markMissing(.INPUT)
                try typeLegacy(session, text, enter)
                onPasted()
                return
            }
            onPasted()
            if enter {
                try sleeper(timings.enterDelay)
            }
        }
        if enter {
            do {
                try daemon.input(session, nil, false, ["Enter"])
            } catch where DaemonCompat.isUnsupported(error) {
                compat.markMissing(.INPUT)
                try typeLegacy(session, "", true)
            }
        }
    }

    /// `text` through the old send-keys op: typed as is, so a newline would submit a line
    /// and a control character would act as a key — such text is refused.
    private func typeLegacy(_ session: String, _ text: String, _ enter: Bool) throws {
        if text.utf16.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            throw ToolError("the running daemon (pid \(compat.pid())) predates pasting, so text is typed as is and "
                            + "every newline would submit a line: send one line at a time. "
                            + SessionController.OLD_DAEMON_REPLACED, .legacyRefusal)
        }
        if text.utf16.contains(where: { ($0 < 0x20 && $0 != 0x09) || ($0 >= 0x7f && $0 < 0xa0) }) {
            throw ToolError("the running daemon (pid \(compat.pid())) predates pasting, so text is typed as is and "
                            + "control characters in it would act as keys: remove them. "
                            + SessionController.OLD_DAEMON_REPLACED, .legacyRefusal)
        }
        if text.isEmpty && !enter {
            return
        }
        try daemon.sendKeys(session, text, enter)
    }

    /// Whether `error` is the daemon refusing a paste the program did not enable bracketed
    /// paste for.
    private static func isBracketedPasteRefusal(_ error: Error) -> Bool {
        (error as? SessionServerException)?.message == MuxProtocol.ERROR_BRACKETED_PASTE_DISABLED
    }

    private func keysNeedNewerDaemon() -> String {
        "keys needs a newer daemon; the running one (pid \(compat.pid())) predates it. "
            + SessionController.OLD_DAEMON_REPLACED
    }

    // MARK: - monitor

    /// Whether the monitor has anything to evaluate.
    func hasPending() -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return !notifications.isEmpty || !prompts.isEmpty
    }

    /// One monitor pass: fires the registrations whose condition holds, delivers spawn
    /// prompts to sessions now ready (and gives up on ones that never got there), and types
    /// fired notifications into callers idle at their harness's prompt. Internal so tests
    /// drive it with a mutable clock instead of the background thread.
    func tick() throws {
        try syncLogs()
        if !hasPending() {
            return
        }
        let infos = try daemon.list()
        if infos.isEmpty && !reachable() {
            // not "every session is gone": the daemon does not answer — judge nothing now
            Log.debug("control monitor: the session daemon is not answering; skipping this pass", tag: "control")
            return
        }
        var live: [String: Target] = [:]
        for info in infos {
            live[info.name] = target(info)
        }
        var observed: [String: Look] = [:]
        let now = clock.instant()
        evaluateRegistrations(live, &observed, now)
        evaluatePrompts(live, &observed, now)
        deliverNotifications(live, &observed, now)
    }

    /// One monitor look at a session: seen, gone, or unknown (the capture failed for some
    /// other reason, or the daemon stopped answering — try again next tick rather than take
    /// it for gone).
    private struct Look {
        let obs: Observation?
        let unknown: Bool

        static let GONE = Look(obs: nil, unknown: false)
        static let UNKNOWN = Look(obs: nil, unknown: true)

        var gone: Bool {
            !unknown && (obs == nil || !obs!.capture.alive)
        }
    }

    private func observeOnce(_ name: String, _ live: [String: Target], _ observed: inout [String: Look]) -> Look {
        if let look = observed[name] {
            return look
        }
        let look: Look
        if let target = live[name] {
            do {
                look = try observe(target).map { Look(obs: $0, unknown: false) } ?? .GONE
            } catch {
                Log.debug("monitor could not capture \(name): \(error)", tag: "control")
                look = .UNKNOWN
            }
        } else {
            forget(name)
            look = .GONE
        }
        observed[name] = look
        return look
    }

    private func evaluateRegistrations(_ live: [String: Target], _ observed: inout [String: Look], _ now: Date) {
        pendingLock.lock()
        let armed = notifications.filter { $0.message == nil }
        pendingLock.unlock()
        for n in armed {
            if live[n.caller] == nil {
                drop(n, "its caller " + n.caller + " is gone")
                continue
            }
            let look = observeOnce(n.target, live, &observed)
            if look.unknown {
                continue
            }
            if look.gone {
                fire(n, "exited", "EXITED", now)
                continue
            }
            let o = look.obs!
            let state = o.classification.state
            if n.trigger == .FINISHED || n.trigger == .NEEDS_INPUT {
                pendingLock.lock()
                let waitingForPrompt = n.awaitPrompt
                pendingLock.unlock()
                if waitingForPrompt {
                    if now.timeIntervalSince(n.registered) > timings.notifyTtl {
                        drop(n, n.target + " did not take up its spawn prompt within "
                             + "\(Int(timings.notifyTtl / 60)) min")
                        continue
                    }
                    // only once the spawn prompt is in and the session has reacted to it:
                    // working on it, asking something, or its harness gone back to a shell
                    let reacted = state == .working || state == .waitingForInput
                        || o.tracker.atShell(o.capture.foregroundCommand)
                    if promptPending(n.target) || !reacted {
                        continue
                    }
                    pendingLock.lock()
                    n.awaitPrompt = false
                    pendingLock.unlock()
                }
            }
            let fired: Bool
            switch n.trigger! {
            case .FINISHED: fired = state != .working
            case .NEEDS_INPUT: fired = state == .waitingForInput
            case .EXITED: fired = false
            case .ANY_CHANGE: fired = o.masked != n.baseline
            }
            if fired {
                fire(n, n.trigger!.description, state.name, now)
            }
        }
    }

    private func evaluatePrompts(_ live: [String: Target], _ observed: inout [String: Look], _ now: Date) {
        pendingLock.lock()
        let waiting = prompts.filter { !$0.delivering }
        pendingLock.unlock()
        for p in waiting {
            pendingLock.lock()
            let enterOwed = p.pasted
            pendingLock.unlock()
            let look = live[p.session] != nil ? observeOnce(p.session, live, &observed) : .GONE
            if enterOwed {
                // the prompt is in its composer: only Enter is owed, whatever the session
                // looks like now and however late it is
                if look.gone {
                    abandon(p, "exited after its prompt was pasted, before it was submitted", live, now)
                    continue
                }
            } else {
                let late = now > p.deadline
                if look.unknown && !late {
                    continue
                }
                if look.gone || late {
                    abandon(p, look.gone ? "exited before its prompt could be sent"
                            : "did not reach its prompt within \(Int(timings.promptTimeout)) s, so the prompt was not sent",
                            live, now)
                    continue
                }
                let o = look.obs!
                let ready = o.classification.state == .idle && o.tracker.harnessRunning(o.capture.foregroundCommand)
                if !ready {
                    continue
                }
            }
            pendingLock.lock()
            if p.delivering || !prompts.contains(where: { $0 === p }) {
                pendingLock.unlock()
                continue // another monitor pass took it meanwhile
            }
            p.delivering = true
            let pasted = p.pasted
            pendingLock.unlock()
            deliveries { [self] in
                do {
                    try type(p.session, p.prompt, true, pasted, true) {
                        pendingLock.lock()
                        p.pasted = true
                        pendingLock.unlock()
                    }
                    pendingLock.lock()
                    prompts.removeAll { $0 === p }
                    pendingLock.unlock()
                } catch let e as ToolError where e.kind == .legacyRefusal || e.kind == .pasteRefusal {
                    abandon(p, "could not be given its prompt: " + e.message, live, clock.instant())
                } catch {
                    Log.warn("could not type the spawn prompt into \(p.session): \(error)", tag: "control")
                    pendingLock.lock()
                    p.delivering = false
                    var giveUp = false
                    if p.pasted {
                        p.enterAttempts += 1
                        giveUp = p.enterAttempts >= SessionController.MAX_ENTER_ATTEMPTS
                    }
                    pendingLock.unlock()
                    if giveUp {
                        abandon(p, "had its prompt pasted but not submitted: pressing Enter failed ("
                                + errorMessage(error) + "); press Enter in it with the keys tool", live, clock.instant())
                    }
                }
            }
        }
    }

    /// Gives up on `p`: tells its requester why, and lets notifications that were waiting
    /// for the prompt judge the session as it is.
    private func abandon(_ p: PromptDelivery, _ why: String, _ live: [String: Target], _ now: Date) {
        pendingLock.lock()
        guard prompts.contains(where: { $0 === p }) else {
            pendingLock.unlock()
            return
        }
        prompts.removeAll { $0 === p }
        pendingLock.unlock()
        Log.info("spawned session \(p.session) \(why)", tag: "control")
        pendingLock.lock()
        notifications.filter { $0.target == p.session }.forEach { $0.awaitPrompt = false }
        pendingLock.unlock()
        if let requesterName = p.requester, let requester = live[requesterName], requester.harness != .shell {
            let notice = Notification(requesterName, p.session, nil, nil, now)
            notice.message = SessionController.NOTICE_PREFIX + p.session + " " + why + ". Use the read tool to see it."
            notice.firedAt = now
            pendingLock.lock()
            notifications.append(notice)
            pendingLock.unlock()
        }
    }

    private func deliverNotifications(_ live: [String: Target], _ observed: inout [String: Look], _ now: Date) {
        var callers: [String] = []
        var byCaller: [String: [Notification]] = [:]
        pendingLock.lock()
        for n in notifications where n.message != nil && !n.delivering {
            if byCaller[n.caller] == nil {
                callers.append(n.caller)
            }
            byCaller[n.caller, default: []].append(n)
        }
        pendingLock.unlock()
        for caller in callers {
            var ready: [Notification] = []
            for n in byCaller[caller]! {
                pendingLock.lock()
                let enterOwed = n.pasted
                pendingLock.unlock()
                // a pasted notice only owes its Enter: never dropped as undelivered
                if !enterOwed && now.timeIntervalSince(n.firedAt!) > timings.notifyTtl {
                    drop(n, "undelivered for \(Int(timings.notifyTtl / 60)) min while \(caller) was busy")
                } else {
                    ready.append(n)
                }
            }
            if ready.isEmpty {
                continue
            }
            let look = live[caller] != nil ? observeOnce(caller, live, &observed) : .GONE
            if look.gone {
                ready.forEach { drop($0, "its caller " + caller + " is gone") }
                continue
            }
            // only into the caller's own harness, idle at its prompt: never while it waits
            // for an answer (Enter would pick an option) and never into a bare shell — except
            // the Enter owed for a notice already pasted, which goes in regardless
            let atItsPrompt = !look.unknown
                && look.obs!.classification.state == .idle
                && live[caller]!.harness != .shell
                && look.obs!.tracker.harnessRunning(look.obs!.capture.foregroundCommand)
            pendingLock.lock()
            let free = ready.filter { n in !n.delivering && notifications.contains { $0 === n } }
            let enterOnly = free.filter(\.pasted)
            let pasted = !enterOnly.isEmpty
            let batch = pasted ? enterOnly : atItsPrompt ? free : []
            batch.forEach { $0.delivering = true }
            pendingLock.unlock()
            if batch.isEmpty {
                continue // held until the caller is ready for input
            }
            // the old send-keys op types as is, where a newline would submit
            let text = pasted ? "" : batch.map { $0.message! }.joined(separator: compat.has(.INPUT) ? "\n" : " ")
            deliveries { [self] in
                do {
                    try type(caller, text, true, pasted, false) {
                        pendingLock.lock()
                        batch.forEach { $0.pasted = true }
                        pendingLock.unlock()
                    }
                    pendingLock.lock()
                    notifications.removeAll { n in batch.contains { $0 === n } }
                    pendingLock.unlock()
                } catch {
                    Log.warn("could not deliver a notification to \(caller): \(error)", tag: "control")
                    var givenUp: [Notification] = []
                    pendingLock.lock()
                    for n in batch {
                        n.delivering = false
                        if n.pasted {
                            n.enterAttempts += 1
                            if n.enterAttempts >= SessionController.MAX_ENTER_ATTEMPTS {
                                givenUp.append(n)
                            }
                        }
                    }
                    pendingLock.unlock()
                    givenUp.forEach {
                        drop($0, "it was pasted into \(caller) but not submitted: pressing Enter failed ("
                             + errorMessage(error) + ")")
                    }
                }
            }
        }
    }

    private func fire(_ n: Notification, _ description: String, _ state: String, _ now: Date) {
        pendingLock.lock(); defer { pendingLock.unlock() }
        n.message = SessionController.NOTICE_PREFIX + n.target + " " + description + " (" + state
            + "). Use the read tool to see it."
        n.firedAt = now
    }

    private func drop(_ n: Notification, _ why: String) {
        Log.info("dropping notification for \(n.caller) about \(n.target): \(why)", tag: "control")
        pendingLock.lock(); defer { pendingLock.unlock() }
        notifications.removeAll { $0 === n }
    }

    /// One monitor's life: stopped by `serverStopped`, which waits on `done`.
    private final class MonitorThread: @unchecked Sendable {
        var thread: Thread?
        @Atomic var stopped = false
        let done = DispatchSemaphore(value: 0)
    }

    private func monitorLoop(_ m: MonitorThread) {
        var watch: DaemonWatch?
        var backoff = timings.watchBackoffMin
        var nextAttempt = Date()
        defer { watch?.close() }
        while isCurrentMonitor(m) && !m.stopped {
            compat.revalidate()
            if compat.has(.WATCH) && (watch == nil || !watch!.isOpen) && Date() >= nextAttempt {
                watch?.close()
                do {
                    watch = try daemon.watch(timings.watchQuietMs) { [weak self] in self?.onEvent($0) }
                    backoff = timings.watchBackoffMin
                } catch {
                    watch = nil
                    if DaemonCompat.isUnsupported(error) {
                        // logged once per daemon; the monitor polls on its tick instead
                        compat.markMissing(.WATCH)
                    } else {
                        Log.debug("daemon watch unavailable, retrying in \(backoff) s: \(error)", tag: "control")
                        nextAttempt = Date().addingTimeInterval(backoff)
                        backoff = min(backoff * 2, timings.watchBackoffMax)
                    }
                }
            }
            do {
                try tick()
            } catch {
                Log.debug("control monitor tick failed: \(error)", tag: "control")
            }
            wakeCondition.lock()
            let deadline = Date().addingTimeInterval(timings.tick)
            while !wakePending && !m.stopped && Date() < deadline {
                _ = wakeCondition.wait(until: deadline)
            }
            wakePending = false
            wakeCondition.unlock()
        }
    }

    private func onEvent(_ event: SessionEvent) {
        if event.type == MuxProtocol.EVENT_EXIT {
            forget(event.name)
        }
        if hasPending() {
            wake()
        }
    }

    private func wake() {
        wakeCondition.lock()
        wakePending = true
        wakeCondition.broadcast()
        wakeCondition.unlock()
    }

    /// Whether the background monitor is running (tests).
    func monitorRunning() -> Bool {
        monitorLock.lock(); defer { monitorLock.unlock() }
        return monitor != nil
    }

    // MARK: - bookkeeping

    private func forget(_ session: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        trackers.removeValue(forKey: session)
        let suffix = "\u{0}" + session
        seen = seen.filter { !$0.key.hasSuffix(suffix) }
    }

    private func forgetAllBut(_ live: Set<String>) {
        stateLock.lock(); defer { stateLock.unlock() }
        trackers = trackers.filter { live.contains($0.key) }
        seen = seen.filter { key, _ in
            guard let cut = key.firstIndex(of: "\u{0}") else { return false }
            return live.contains(String(key[key.index(after: cut)...]))
        }
    }

    private static func seenKey(_ caller: String?, _ session: String) -> String {
        (caller ?? "") + "\u{0}" + session
    }

    private static func refuseSelf(_ caller: String?, _ target: Target, _ verb: String) throws {
        if let caller, target.name == caller {
            throw ToolError("refusing to " + verb + " your own session (" + caller + ")")
        }
    }

    private static func sessionsArgument(_ args: CoreJSON) throws -> [String] {
        var names: [String] = []
        for field in ["session", "sessions"] {
            guard let node = args.get(field), !node.isNull else { continue }
            if node.isTextual && !JavaText.isBlank(node.asText()) {
                let name = JavaText.strip(node.asText())
                if !names.contains(name) { names.append(name) }
            } else if node.isArray {
                for n in node.elements {
                    if !n.isTextual || JavaText.isBlank(n.asText()) {
                        throw ToolError(field + " must hold session names (strings)")
                    }
                    let name = JavaText.strip(n.asText())
                    if !names.contains(name) { names.append(name) }
                }
            } else {
                throw ToolError(field + " must be a session name or an array of them")
            }
        }
        if names.isEmpty {
            throw ToolError("session is required (a session name, or sessions: an array of them)")
        }
        return names
    }

    private static func requiredText(_ args: CoreJSON, _ field: String) throws -> String {
        guard let node = args.get(field), node.isTextual, !JavaText.isBlank(node.asText()) else {
            throw ToolError(field + " is required (a string)")
        }
        return JavaText.strip(node.asText())
    }

    private static func optionalText(_ args: CoreJSON, _ field: String) throws -> String? {
        guard let node = args.get(field), !node.isNull else {
            return nil
        }
        if !node.isTextual {
            throw ToolError(field + " must be a string")
        }
        let text = node.asText()
        return JavaText.isBlank(text) ? nil : text
    }

    /// `~` and `~/…` expanded; must name an existing directory by absolute path.
    static func expandProject(_ text: String) throws -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let expanded = text == "~" ? home : text.hasPrefix("~/") ? home + text.dropFirst() : text
        if expanded.contains("\u{0}") {
            throw ToolError("not a valid path: " + text)
        }
        if !expanded.hasPrefix("/") {
            throw ToolError("project must be an absolute path (or start with ~): " + text)
        }
        let path = PathCompat.normalize(URL(fileURLWithPath: expanded))
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) || !isDir.boolValue {
            throw ToolError("project is not an existing directory: " + path.path)
        }
        return path
    }

    private static func harnessIds() -> String {
        HarnessType.allCases.map(\.id).joined(separator: ", ")
    }

    private static func blankToNil(_ s: String?) -> String? {
        guard let s, !JavaText.isBlank(s) else { return nil }
        return s
    }

    // MARK: - types

    /// A resolved daemon session and what the registry and its labels say about it.
    private struct Target {
        let name: String
        let entry: SessionEntry?
        let labels: [String: String]
        let harness: HarnessType
        let display: String?
        let project: String
    }

    /// One capture of a session, classified. `body` is the annotated screen's lines;
    /// `masked` its chrome-free text for change comparison.
    private struct Observation {
        let capture: SessionCapture
        let annotated: Bool
        let classification: Classification
        let masked: String
        let body: [String]
        let plain: String
        let tracker: SessionTracker
    }

    /// What one caller last read of one session; `plain` is the unmasked screen without
    /// markers.
    private struct Seen {
        let outputBytes: Int64
        let masked: String
        let lines: [String]
        let plain: String
    }

    /// A notify registration; `message` is set once it fired. Mutable fields are guarded by
    /// `pendingLock`. A nil trigger is an internal notice.
    private final class Notification {
        let caller: String
        let target: String
        let trigger: Trigger?
        let baseline: String?
        let registered: Date
        var message: String?
        var firedAt: Date?
        var delivering = false
        /// The message is in the caller's composer; only its Enter is still owed.
        var pasted = false
        /// Failed tries of the owed Enter.
        var enterAttempts = 0
        /// Registered while the target's spawn prompt was pending: FINISHED and NEEDS_INPUT
        /// wait until the prompt is in and the target has reacted (seen WORKING or
        /// WAITING_FOR_INPUT, or back at a shell); dropped when that takes longer than the
        /// notify TTL.
        var awaitPrompt = false

        init(_ caller: String, _ target: String, _ trigger: Trigger?, _ baseline: String?, _ registered: Date) {
            self.caller = caller
            self.target = target
            self.trigger = trigger
            self.baseline = baseline
            self.registered = registered
        }
    }

    /// A spawn prompt waiting for its session to be ready. Mutable fields are guarded by
    /// `pendingLock`.
    private final class PromptDelivery {
        let session: String
        let prompt: String
        let requester: String?
        let deadline: Date
        var delivering = false
        /// The prompt is in the composer; only its Enter is still owed.
        var pasted = false
        /// Failed tries of the owed Enter.
        var enterAttempts = 0

        init(_ session: String, _ prompt: String, _ requester: String?, _ deadline: Date) {
            self.session = session
            self.prompt = prompt
            self.requester = requester
            self.deadline = deadline
        }
    }

    /// A caller mistake, reported verbatim as the tool's error text. `kind` tells the
    /// special ones apart: text the old send-keys fallback cannot type safely, a multi-line
    /// paste the program has not enabled bracketed paste for (nothing was written; retrying
    /// cannot help), and a daemon that did not answer (a session that could not be listed
    /// or captured is not known to be gone).
    struct ToolError: Error, CustomStringConvertible, LocalizedError {
        enum Kind {
            case plain, legacyRefusal, pasteRefusal, unreachable
        }

        let message: String
        let kind: Kind

        init(_ message: String, _ kind: Kind = .plain) {
            self.message = message
            self.kind = kind
        }

        static func unreachable() -> ToolError {
            ToolError(SessionController.DAEMON_UNREACHABLE, .unreachable)
        }

        var description: String { message }
        var errorDescription: String? { message }
    }

    // MARK: - tool definitions

    private static func toolDefs() -> [ToolDef] {
        [
            ToolDef(TOOL_LIST, LIST_DESCRIPTION, schema()),
            ToolDef(TOOL_READ, READ_DESCRIPTION, required(schema(
                prop("session", "string", SESSION_ARG),
                prop("full", "boolean", "true: return the whole screen even if you have seen it. "
                     + "Default false: only what changed since your last read.")),
                "session")),
            ToolDef(TOOL_SEND, SEND_DESCRIPTION, required(schema(
                prop("session", "string", SESSION_ARG),
                prop("text", "string", "The message to type, as one block (newlines do not submit; "
                     + "multi-line text needs a session that accepts pastes)."),
                prop("enter", "boolean", "Press Enter after the text to submit it. Default true.")),
                "session", "text")),
            ToolDef(TOOL_KEYS, KEYS_DESCRIPTION, required(schema(
                prop("session", "string", SESSION_ARG),
                stringArray("keys", "Key names pressed in order, e.g. [\"Down\",\"Enter\"], [\"y\"], "
                            + "[\"Esc\"], [\"C-c\"]. See the tool description for every name.")),
                "session", "keys")),
            ToolDef(TOOL_NOTIFY, NOTIFY_DESCRIPTION, required(schema(
                prop("session", "string", "The session to watch (name or display name)."),
                stringArray("sessions", "Several sessions to watch instead; each notifies separately."),
                enumProp("on", "What to be told about.", ["finished", "needs-input", "exited", "any-change"])),
                "on")),
            ToolDef(TOOL_SPAWN, SPAWN_DESCRIPTION, required(schema(
                enumProp("harness", "Which agent (or plain shell) to run.", HarnessType.allCases.map(\.id)),
                prop("project", "string", "The directory to run it in: an existing absolute path, ~ allowed."),
                prop("name", "string", "Optional display name for the sidebar and for addressing it."),
                prop("prompt", "string", "Optional first message, typed in once the harness is ready "
                     + "(multi-line only where the harness accepts pastes).")),
                "harness", "project")),
            ToolDef(TOOL_KILL, KILL_DESCRIPTION, required(schema(prop("session", "string", SESSION_ARG)), "session")),
        ]
    }

    private static let SESSION_ARG = "The session: its name (mhm-…) or display name, as shown by list."

    static let LIST_DESCRIPTION = """
        List the sessions you can see and drive: every terminal session \
        micro-harness-manager hosts (coding agents and shells), one per line:
        `name · display name · harness · STATE · project · transcript: path · log: path`
        Your own session is marked (you). STATE is WORKING (busy, output changing), \
        WAITING_FOR_INPUT (a question, approval or menu waits for an answer) or IDLE (at its \
        prompt, or its harness is not running). Address a session by its name or display name.
        transcript is the harness's own conversation log (JSONL) when micro-harness-manager can find \
        it (claude-code, codex, muse, grok), else "-" — or, when it can't tell which file is a \
        session's, the folder with a note saying so. History lives there, not on screen: search \
        it with your file tools (grep, tail, read a line range) — never load a whole transcript, \
        they get large. Where the replies are: claude-code rows with "type":"assistant"; codex \
        "type":"response_item" rows whose payload is an assistant message; muse \
        "assistant_message_committed" events (session.jsonl); grok rows with "type":"assistant" \
        (chat_history.jsonl).
        log is a plain-text copy of the session's output kept inside your own project \
        when the user has turned session logs on (Settings → Agent control), in \
        .microhm-sessions/ (git-ignored), for any harness — use it when the transcript is \
        outside what you may read, or for a shell. It holds the lines that scrolled off the \
        screen (the screen itself is what read shows); for a full-screen program, its \
        screen's lines as they appear, each new line once and without the harness's status \
        bars, under `--- microhm · <time> · screen ---`. It is \
        kept up to date from your first read of that session on, starting with the \
        scrollback the session still holds; older parts are beside it as \
        <name>.0001.log.gz, .0002… (zgrep them). "-" until you read the session (nothing \
        of a session is copied into your project before you do), when session logs are \
        off (the default), and when your session has no project folder.
        """

    static let READ_DESCRIPTION = """
        Show a session's terminal screen. The first line is \
        `name · harness · STATE (reason) · window title`; the screen follows.
        Reads are incremental and cheap, per session and per reader: the first read returns \
        the whole visible screen. A later read returns:
        - `… · unchanged` when the session printed nothing since your previous read, or its \
        screen text is identical (only the cursor or highlight moved);
        - `… · only status lines changed` followed by just the lines that differ, when every \
        change is in lines the harness's chrome filter drops: its input box/composer (for \
        opencode and pi everything from it down), hint, tip and footer bars, rules, box-drawn \
        lines, spinner and timer lines, and for codex also numbered option rows and `$ ` \
        command previews;
        - otherwise only the lines that are new since your previous read (a `… (N lines \
        above already seen)` line leads them), or the whole screen when it was redrawn.
        full=true always returns the whole screen.
        Markers: a line starting with `▶ ` is highlighted — usually the selected option of a \
        menu; `▮` is where the cursor is. If the header ends with `(old daemon: no \
        selection/cursor markers)` there are none. Output is capped at 8000 characters (oldest lines \
        dropped). Only the visible screen is shown. A reply showing the whole screen ends with \
        `… (earlier output is in the transcript, <path>, and in the screen log, <path>: grep \
        or tail them)` — the harness's own transcript when it has one (claude-code, codex, \
        muse, grok), and the plain-text log in your project's .microhm-sessions/ (see list): \
        for anything that scrolled off, such as the start of a long answer, grep or tail \
        either with your file tools — never load one whole. \
        Don't call read in a loop to wait for a session: use notify.
        """

    static let SEND_DESCRIPTION = """
        Type a message into another session, as a user would at its prompt, and press Enter \
        to submit it (enter=false only types it). The text is pasted as one block, so \
        newlines in it do not submit early. Multi-line text is only sent where the session's \
        program accepts pastes (coding agents do; a bare shell or a plain program may not): \
        otherwise nothing is typed and you get an error — send one line at a time then. Use \
        it for prompts, follow-ups and slash commands. \
        Returns once typed — it does not wait for an answer: use notify with on=finished to \
        learn when the session is done, then read it. To answer a menu, an approval or a y/n \
        question use keys instead. You cannot send to your own session.
        """

    static let KEYS_DESCRIPTION = """
        Press keys in a session and get back its screen once the output settles (up to 3 s) — \
        for menus, approvals, y/n questions, pickers and interrupting. Work one step at a \
        time: read the screen, press the key(s) for one choice, check the returned screen, \
        repeat. A `▶ ` line is the highlighted option, `▮` the cursor.
        Key names (case-insensitive):
        - a single character: `y`, `n`, `1`, `/`, `?` (typed as is)
        - Enter, Tab, BTab (shift-tab), Esc, Space, Backspace, Delete, Insert
        - Up, Down, Left, Right, Home, End, PageUp, PageDown, F1 … F12
        - C-x: Ctrl with a letter or one of @[\\]^_? — C-c interrupts, C-d is end of input
        - M-x: Alt/Meta, i.e. Esc then the key (M-b, M-Enter)
        Examples: ["Down","Down","Enter"] picks the third option of a menu; ["2"] picks \
        option 2 where digits select; ["Esc"] dismisses. An unknown name fails before \
        anything is pressed. For free text use send.
        """

    static let NOTIFY_DESCRIPTION = """
        Be told when another session reaches a state, instead of polling it with read. \
        One-shot: it fires once, then is gone. on:
        - finished: the session is WORKING now and stops working. If it is not working, \
        you are told its current state and nothing is registered.
        - needs-input: it waits for an answer (question, approval, menu).
        - exited: the session ends.
        - any-change: its content changes. Changes confined to the harness's chrome do not \
        count — its input box/composer, hint and footer bars, rules, spinner and timer lines \
        — so typing into its prompt does not fire it.
        A session that exits always notifies, whatever on says. A session just spawned with \
        a prompt counts as working on it: finished and needs-input fire only after the \
        prompt was typed in and the session took it up.
        The notification arrives as a line typed into your own session, and only while your \
        harness is idle at its prompt: it is held while you are working and while you wait \
        for an answer (a question, approval or menu — so it can never answer one), e.g.
        `[micro-harness-manager] mhm-api finished (IDLE). Use the read tool to see it.`
        So: register, end your turn, and continue when that line arrives. It never contains \
        the session's output — read it. Notifications still undelivered after 30 minutes \
        are dropped. Registering the same session and on again changes nothing. Only works \
        from an agent session micro-harness-manager launched (it must know where to deliver; a plain \
        shell session cannot receive notifications); you cannot watch your own session.
        """

    static let SPAWN_DESCRIPTION = """
        Start a new session in micro-harness-manager: the chosen harness runs in project, \
        the session appears in micro-harness-manager's sidebar (labelled as spawned by you), and \
        claude-code and codex get this same MCP server. name sets its display name (it must \
        not already be used by a running session). prompt, \
        if given, is typed in as its first message once the harness is idle at its prompt \
        (up to 120 s; if it never gets there you are notified and nothing is typed — read \
        the session to see why, e.g. a trust question to answer with keys). A multi-line \
        prompt goes in as one paste; if the harness does not accept pastes you are notified \
        and nothing is typed. Returns the new \
        session's name; use notify with on=finished to learn when it is done.
        """

    static let KILL_DESCRIPTION = """
        End a session: its whole process tree is terminated and it leaves micro-harness-manager's \
        sidebar. Work in progress that the harness has not saved is lost — to stop an agent \
        cleanly, send it its own quit command (/exit, /quit) instead. You cannot kill your \
        own session.
        """

    // MARK: - schema helpers

    private struct Prop {
        let name: String
        let schema: CoreJSON
    }

    private static func schema(_ props: Prop...) -> CoreJSON {
        .obj([
            ("type", .string("object")),
            ("properties", .object(props.map { CoreJSON.Member($0.name, $0.schema) })),
            ("additionalProperties", .bool(false)),
        ])
    }

    private static func required(_ schema: CoreJSON, _ names: String...) -> CoreJSON {
        var s = schema
        s.set("required", .array(names.map(CoreJSON.string)))
        return s
    }

    private static func prop(_ name: String, _ type: String, _ description: String) -> Prop {
        Prop(name: name, schema: .obj([("type", .string(type)), ("description", .string(description))]))
    }

    private static func stringArray(_ name: String, _ description: String) -> Prop {
        Prop(name: name, schema: .obj([("type", .string("array")), ("items", .obj([("type", .string("string"))])),
                                       ("description", .string(description))]))
    }

    private static func enumProp(_ name: String, _ description: String, _ values: [String]) -> Prop {
        Prop(name: name, schema: .obj([("type", .string("string")), ("enum", .array(values.map(CoreJSON.string))),
                                       ("description", .string(description))]))
    }
}

/// A value read and written under a lock (a Java `volatile` field).
@propertyWrapper
final class Atomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
