import Darwin
import Foundation
import MicrohmPTY
import MicrohmShared
import MicrohmVT

@inline(__always) func nanoTime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// The PTY-backed `Session`: a `PtyProcess`, the `HeadlessTerminal` shadowing its output,
/// and the attached clients; see the `Session` contract.
///
/// Threads: the **pump** reads the PTY and, under the one session lock, tokenizes,
/// normalizes, applies to the emulator and fans out to clients; the **writer** drains the
/// PTY input queue (`write`, `sendKeys`, emulator replies) so nothing ever writes to the
/// PTY from under the lock. Tokenizing happens under the lock too (not only the
/// apply/fan-out), which is what makes `tokenizer.openStringBytes()` at attach time exactly
/// "what the others have been sent so far and the emulator has not": the pump is between
/// batches whenever anyone else holds the lock.
///
/// Activity: the pump counts every raw byte it reads (`outputBytes`) and stamps the time of
/// the last read under the lock, then wakes `awaitQuiet` waiters. Watchers' `quiet` events
/// come from one shared timer queue that re-checks the stamp under the lock, so the pump
/// never waits for anyone.
///
/// The lock is not reentrant (Java's monitor was): methods that the lock holder needs again
/// have `…Locked` variants.
public final class PtySession: Session, @unchecked Sendable, CustomStringConvertible {

    /// How the manager learns that the PTY process ended; called once, on the pump thread,
    /// after every attached client got `onExit`.
    typealias ExitListener = (PtySession, Int32) -> Void

    private static let READ_BUFFER_BYTES = 16 * 1024
    /// How long the hung-up shell and its descendants get before survivors are SIGKILLed.
    static let KILL_GRACE: TimeInterval = 2
    /// How often `kill` re-checks the snapshot descendants while the grace runs.
    private static let KILL_POLL: TimeInterval = 0.02
    /// At most this long, input waits for the program's earlier output to be applied, so a
    /// program that never stops printing cannot hold typing up.
    private static let INPUT_SYNC_NANOS: UInt64 = 100_000_000
    /// How long nothing must be pending before input goes out.
    private static let INPUT_SYNC_SETTLE_NANOS: UInt64 = 2_000_000
    /// The PTY kind sessions report.
    static let BACKEND = "unix"
    /// How much input may wait for a program that is not reading its terminal. Past it the
    /// sender is refused: the queue would otherwise grow with every keystroke, paste and
    /// automation retry until the daemon ran out of memory, taking every session with it.
    static let MAX_PENDING_INPUT_BYTES: Int64 = 4 * 1024 * 1024
    private static let CR: [UInt8] = [0x0D]
    /// String terminator, prefixed to a BEHIND re-sync snapshot (see `handSnapshot`).
    private static let ST: [UInt8] = [0x1B, 0x5C]
    private static let PASTE_START = "\u{1b}[200~"
    private static let PASTE_END = "\u{1b}[201~"
    /// Fires watchers' quiet checks for every session; its tasks only take a session lock
    /// briefly and enqueue.
    private static let QUIET_TIMER = DispatchQueue(label: "microhm-mux-quiet-timer")

    /// A watcher's activity state; guarded by the session lock.
    private final class WatchState {
        var active = false
        var quietCheck: DispatchWorkItem?
    }

    public let name: String
    private let workdir: URL
    private let createdAt = Date()
    private let process: PtyProcess
    private let historyLines: Int
    private let exitListener: ExitListener
    /// The foreground probe, memoized (it forks `ps`).
    private let foregroundProbe: ForegroundProbe.Memo

    private let lock = NSCondition()
    private let tokenizer = VtTokenizer()                 // guarded by lock
    private var terminal: HeadlessTerminal!               // apply/resize/serialize under lock
    private var clientList: [SessionClient] = []          // guarded by lock
    private var columns: Int                              // guarded by lock
    private var rows: Int                                 // guarded by lock
    private var exited = false                            // guarded by lock
    private var exitCode: Int32 = 0                       // guarded by lock, valid once exited
    private var labelMap: [String: String] = [:]          // guarded by lock
    private var outputCount: Int64 = 0                    // guarded by lock
    private var lastOutputNanos = nanoTime()              // guarded by lock
    private var watchers: [(SessionWatcher, WatchState)] = [] // guarded by lock, insertion order

    private let input = InputQueue()
    private var applyFailureLogged = false                // pump thread only

    private init(name: String, workdir: URL, process: PtyProcess, columns: Int, rows: Int, historyLines: Int,
                 labels: [String: String], exitListener: @escaping ExitListener) {
        self.name = name
        self.workdir = workdir
        self.process = process
        self.historyLines = historyLines
        self.exitListener = exitListener
        self.columns = columns
        self.rows = rows
        self.labelMap = labels
        self.foregroundProbe = ForegroundProbe.Memo { Int64(process.foregroundProcessGroup()) }
        // Emulator replies (DA, DSR, CPR) are enqueued for the writer thread, never written
        // from under the lock the pump holds while the emulator produces them. A reply that
        // does not fit is dropped, never thrown back into the pump: a program that is not
        // reading its input is not waiting for the answer either.
        let queue = input
        self.terminal = HeadlessTerminal(columns, rows, historyLines) { bytes in _ = queue.offer(bytes) }
    }

    /// Spawns `shell` in a PTY of `columns`×`rows` at `workdir` and starts the pump and
    /// writer threads.
    static func spawn(name: String, workdir: URL, columns: Int, rows: Int, shell: ShellCommand, historyLines: Int,
                      labels: [String: String] = [:], exitListener: @escaping ExitListener) throws -> PtySession {
        let process = try PtyProcess.start(shell.command, environment: shell.environment, directory: workdir,
                                           columns: columns, rows: rows)
        let session = PtySession(name: name, workdir: workdir, process: process, columns: columns, rows: rows,
                                 historyLines: historyLines, labels: labels, exitListener: exitListener)
        let writer = Thread { [session] in session.drainPtyInput() }
        writer.name = "microhm-mux-pty-writer-\(name)"
        writer.stackSize = 256 * 1024
        let pump = Thread { [session] in session.pump() }
        pump.name = "microhm-mux-pump-\(name)"
        writer.start()
        pump.start()
        return session
    }

    // MARK: - Session

    public func info() -> SessionInfo {
        lock.lock()
        let info = (columns, rows, clientList.count, exited, labelMap, outputCount)
        lock.unlock()
        return SessionInfo(name: name, workdir: workdir, columns: info.0, rows: info.1, pid: Int64(process.pid),
                           createdAt: createdAt, clients: info.2, alive: !info.3 && process.isAlive,
                           backend: PtySession.BACKEND, labels: info.4, outputBytes: info.5)
    }

    public func isAlive() -> Bool {
        lock.lock()
        let done = exited
        lock.unlock()
        // kill() may have reaped the process before the pump noticed EOF.
        return !done && process.isAlive
    }

    public func write(_ bytes: [UInt8]) throws {
        if !input.offer(bytes) {
            throw InputRejectedError("session \(name) is not reading its input (\(input.pendingBytes) bytes pending);"
                                     + " nothing was written")
        }
    }

    public func sendKeys(_ text: String, enter: Bool) throws {
        try write(Array(text.utf8))
        if !enter { return }
        // tmux parity: the pause lives here, off every lock, so a TUI with paste detection
        // sees the CR as a submit and not as a pasted newline.
        Thread.sleep(forTimeInterval: Double(MuxProtocol.SEND_KEYS_ENTER_DELAY_MS) / 1000)
        try write(PtySession.CR)
    }

    public func resize(columns: Int, rows: Int, except: SessionClient?) {
        lock.lock(); defer { lock.unlock() }
        resizeLocked(columns, rows, except)
    }

    private func resizeLocked(_ columns: Int, _ rows: Int, _ except: SessionClient?) {
        if exited { return }
        do {
            try process.setWinSize(columns: columns, rows: rows)
        } catch {
            // A PTY whose slave side is already gone; the emulator still follows the client.
            Log.debug("setWinSize(\(columns)x\(rows)) on \(name) failed: \(error)", tag: "mux")
        }
        terminal.resize(columns, rows)
        // The emulator may clamp to a minimum size; announce what it really is.
        self.columns = terminal.columns()
        self.rows = terminal.rows()
        let announcement = Array("\u{1b}[8;\(self.rows);\(self.columns)t".utf8)
        for client in clientList where client !== except {
            deliver(client, announcement)
        }
    }

    public func capture(_ format: CaptureFormat) -> SessionCapture {
        capture(format) { _ in nil }
    }

    public func capture(_ format: CaptureFormat, historyLines: Int) -> SessionCapture {
        capture(format) { t in historyLines > 0 ? t.history(historyLines) : nil }
    }

    public func captureSince(_ format: CaptureFormat, since: Int64) -> SessionCapture {
        capture(format) { t in t.historySince(since) }
    }

    private func capture(_ format: CaptureFormat, _ scrollback: (HeadlessTerminal) -> HeadlessTerminal.History?) -> SessionCapture {
        lock.lock()
        // Under the session lock so the text is never a half-applied batch.
        let text: String
        switch format {
        case .TEXT: text = terminal.screenText()
        case .ANNOTATED: text = terminal.annotatedText()
        case .ANSI: text = String(decoding: terminal.serialize(0), as: UTF8.self)
        }
        let title = terminal.title()
        let cols = columns
        let rws = rows
        var alive = !exited
        let bytes = outputCount
        let cursorVisible = terminal.modes().cursorVisible
        let history = scrollback(terminal)
        lock.unlock()
        alive = alive && process.isAlive
        let foreground = alive ? foregroundProbe.probe(Int64(process.pid), bytes).command : ""
        return SessionCapture(text: text, alive: alive, foregroundCommand: foreground, processId: Int64(process.pid),
                              title: title, columns: cols, rows: rws, outputBytes: bytes, cursorVisible: cursorVisible,
                              history: history.map {
                                  CaptureHistory(text: $0.text, held: $0.held, added: $0.added,
                                                 alternateScreen: $0.alternateScreen)
                              })
    }

    public func outputBytes() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return outputCount
    }

    public func labels() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return labelMap
    }

    public func label(_ changes: [String: String?]) {
        lock.lock(); defer { lock.unlock() }
        for (key, value) in changes {
            if let value {
                labelMap[key] = value
            } else {
                labelMap.removeValue(forKey: key)
            }
        }
    }

    public func input(_ keys: [String]) throws {
        awaitOutputApplied()
        try write(KeyNames.encode(keys, terminal.modes().applicationCursorKeys))
    }

    public func paste(_ text: String) throws {
        if text.isEmpty { return }
        awaitOutputApplied()
        if terminal.modes().bracketedPaste {
            try writeBracketed(text)
        } else {
            try write(Array(text.utf8))
        }
    }

    public func pasteIfBracketed(_ text: String) throws -> Bool {
        awaitOutputApplied()
        if !terminal.modes().bracketedPaste {
            return false
        }
        if !text.isEmpty {
            try writeBracketed(text)
        }
        return true
    }

    /// Keys and pastes are encoded from the terminal's modes (cursor keys, bracketed paste),
    /// so they must see every mode switch the program printed before them. A caller can
    /// observe the program's state ahead of the pump (e.g. "cat is now the foreground" while
    /// printf's `CSI ?1l` is still in the PTY buffer): wait until all output is read and
    /// applied, bounded by `INPUT_SYNC_NANOS`.
    private func awaitOutputApplied() {
        let deadline = nanoTime() + PtySession.INPUT_SYNC_NANOS
        lock.lock(); defer { lock.unlock() }
        // Nothing pending for INPUT_SYNC_SETTLE, not just once: what a program writes
        // reaches the master's readable queue through the kernel's tty buffer,
        // asynchronously, and while in transit it shows neither to FIONREAD nor to poll.
        var cleanSince: UInt64?
        while !exited {
            let now = nanoTime()
            if process.outputPending() {
                cleanSince = nil
            } else if let since = cleanSince {
                if now - since >= PtySession.INPUT_SYNC_SETTLE_NANOS { return }
            } else {
                cleanSince = now
            }
            if now >= deadline { return }
            // The pump signals after applying; bytes still in the kernel don't, so re-check
            // on a short timer as well.
            _ = lock.wait(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    private func writeBracketed(_ text: String) throws {
        try write(Array((PtySession.PASTE_START + PtySession.pasteSafe(text) + PtySession.PASTE_END).utf8))
    }

    /// `text` without any ESC (0x1b) or C1 CSI (U+009B) character: with neither, no escape
    /// sequence can be formed inside the bracket, so no end marker either — however it is
    /// nested (`ESC[201ESC[201~~` survives a one-pass removal of the marker).
    static func pasteSafe(_ text: String) -> String {
        var safe = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.value != 0x1B && scalar.value != 0x9B {
            safe.append(scalar)
        }
        return String(safe)
    }

    public func awaitQuiet(sinceBytes: Int64, quietMs: Int64, timeoutMs: Int64) -> WaitResult {
        let quietNanos = UInt64(max(0, quietMs)) * 1_000_000
        let deadline = nanoTime() + UInt64(max(0, timeoutMs)) * 1_000_000
        lock.lock(); defer { lock.unlock() }
        if sinceBytes >= 0 {
            // Phase 1: the output the caller's input is expected to cause. If none comes the
            // screen is taken as settled and the quiet check below answers at once.
            while !exited && outputCount <= sinceBytes {
                let now = nanoTime()
                if now >= deadline { break }
                waitNanos(deadline - now)
            }
        }
        while true {
            if exited {
                return WaitResult(quiet: true, outputBytes: outputCount, alive: false)
            }
            let now = nanoTime()
            let idle = now >= lastOutputNanos ? now - lastOutputNanos : 0
            if idle >= quietNanos {
                return WaitResult(quiet: true, outputBytes: outputCount, alive: true)
            }
            if now >= deadline {
                return WaitResult(quiet: false, outputBytes: outputCount, alive: true)
            }
            waitNanos(min(quietNanos - idle, deadline - now))
        }
    }

    /// Waits on the lock for about `nanos` (at least a millisecond); the caller holds the
    /// lock and re-checks its condition.
    private func waitNanos(_ nanos: UInt64) {
        let seconds = max(0.001, Double(nanos) / 1e9)
        _ = lock.wait(until: Date(timeIntervalSinceNow: seconds))
    }

    public func addWatcher(_ watcher: SessionWatcher) {
        lock.lock(); defer { lock.unlock() }
        if exited {
            // Raced with the exit, as attach can: the watcher still learns the end.
            emit(watcher, SessionEvent(name: name, type: MuxProtocol.EVENT_EXIT, outputBytes: outputCount,
                                       exitCode: exitCode))
            return
        }
        if !watchers.contains(where: { $0.0 === watcher }) {
            watchers.append((watcher, WatchState()))
        }
    }

    public func removeWatcher(_ watcher: SessionWatcher) {
        lock.lock(); defer { lock.unlock() }
        if let index = watchers.firstIndex(where: { $0.0 === watcher }) {
            watchers[index].1.quietCheck?.cancel()
            watchers.remove(at: index)
        }
    }

    public func currentPath() -> URL {
        if let hint = terminal.reportedCwd(), !hint.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: hint)
        }
        if isAlive() {
            let shellPid = Int64(process.pid)
            let foregroundPid = foregroundProbe.probe(shellPid, outputBytes()).pid
            var cwd = CwdProbe.cwdOf(foregroundPid)
            if cwd == nil && foregroundPid != shellPid {
                cwd = CwdProbe.cwdOf(shellPid)
            }
            if let cwd { return cwd }
        }
        return workdir
    }

    public func attach(_ client: SessionClient, columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        if !exited && (columns != self.columns || rows != self.rows) {
            resizeLocked(columns, rows, client)
        }
        handSnapshot(client, closeOpenString: false)
        if exited {
            // Raced with the exit: the client gets the final screen, then the end.
            client.onExit(exitCode)
            return
        }
        clientList.append(client)
    }

    public func snapshotFor(_ client: SessionClient) {
        lock.lock(); defer { lock.unlock() }
        handSnapshot(client, closeOpenString: true)
    }

    /// Under the lock: the redraw, then the open OSC/DCS body the others are mid-way
    /// through. With `closeOpenString` the redraw is prefixed by ST, joined into the same
    /// chunk (a separate two-byte chunk ahead of an oversized snapshot would trip the
    /// client's overflow check and loop it through BEHIND).
    private func handSnapshot(_ client: SessionClient, closeOpenString: Bool) {
        var screen = terminal.serialize(historyLines)
        if closeOpenString {
            // The client may be inside an OSC/DCS body: its last delivered batch ended
            // in-string and the terminator was dropped with its queue, or a batch landed
            // between its BEHIND clear and this lock. Close it so the redraw is not consumed
            // as string body; a stray ST in ground state is ignored.
            screen = PtySession.ST + screen
        }
        client.onSnapshot(screen)
        let open = tokenizer.openStringBytes()
        if !open.isEmpty {
            deliver(client, open)
        }
    }

    public func detach(_ client: SessionClient) {
        lock.lock(); defer { lock.unlock() }
        clientList.removeAll { $0 === client }
    }

    public func clients() -> [SessionClient] {
        lock.lock(); defer { lock.unlock() }
        return clientList
    }

    public func kill() {
        let pid = process.pid
        // Snapshot before signalling: once the shell dies its children are reparented and
        // its descendants can no longer be found.
        let descendants = process.isAlive ? ProcessTable.descendants(of: pid).map(\.pid) : []
        if process.isAlive {
            // SIGHUP, what tmux delivers by closing the master: interactive bash/zsh ignore
            // SIGTERM but exit on SIGHUP and forward it to their jobs.
            process.hangup()
        }
        // One deadline for the whole tree: an interactive shell exits at once after
        // forwarding SIGHUP, so waiting on it alone would SIGKILL its jobs (a harness
        // flushing state, vim writing its recovery file) milliseconds after the HUP.
        let deadline = Date(timeIntervalSinceNow: PtySession.KILL_GRACE)
        _ = process.waitFor(timeout: PtySession.KILL_GRACE)
        while Date() < deadline && descendants.contains(where: ProcessTable.isAlive) {
            Thread.sleep(forTimeInterval: PtySession.KILL_POLL)
        }
        if process.isAlive {
            process.destroyForcibly()
        }
        for survivor in descendants where ProcessTable.isAlive(survivor) {
            _ = Darwin.kill(survivor, SIGKILL)
        }
        process.waitFor()
    }

    public var description: String {
        "PtySession[\(name), pid \(process.pid), \(PtySession.BACKEND)]"
    }

    // MARK: - pump

    private func pump() {
        var buffer = [UInt8](repeating: 0, count: PtySession.READ_BUFFER_BYTES)
        while true {
            let n: Int
            do {
                n = try buffer.withUnsafeMutableBytes { try process.read(into: $0) }
            } catch {
                break // the PTY's way of saying EOF
            }
            if n < 0 { break }
            if n == 0 {
                process.outputConsumed()
                continue
            }
            lock.lock()
            outputCount += Int64(n)
            lastOutputNanos = nanoTime()
            markActive()
            let batch = buffer.withUnsafeBufferPointer { tokenizer.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            applyAndBroadcast(batch)
            process.outputConsumed()
            // awaitQuiet re-checks the counter and the stamp; input, the pending output.
            lock.broadcast()
            lock.unlock()
        }
        finish()
    }

    /// EOF: flush the tokenizer, apply the last batch, end the clients, tell the manager.
    private func finish() {
        let code = process.waitFor()
        lock.lock()
        applyAndBroadcast(tokenizer.flush())
        exited = true
        exitCode = code
        let ended = clientList
        clientList.removeAll()
        terminal.close()
        let exit = SessionEvent(name: name, type: MuxProtocol.EVENT_EXIT, outputBytes: outputCount, exitCode: code)
        for (watcher, state) in watchers {
            state.quietCheck?.cancel()
            emit(watcher, exit)
        }
        watchers.removeAll()
        lock.broadcast() // awaitQuiet returns at once for an exited session
        lock.unlock()
        input.end()
        process.closeTerminal()
        for client in ended {
            client.onExit(code)
        }
        Log.info("session \(name) (pid \(process.pid)) exited with \(code)", tag: "mux")
        exitListener(self, code)
    }

    /// Under the lock: emulator first, then the same bytes to every client — everything
    /// `QueryFilter` does not strip, followed by the open string fragment.
    private func applyAndBroadcast(_ batch: VtTokenizer.Batch) {
        let normalized = batch.tokens.map(SgrNormalizer.normalize)
        let titleBefore = terminal.title()
        terminal.apply(normalized)
        if !watchers.isEmpty {
            notifyTitleAndBell(titleBefore, normalized)
        }
        if clientList.isEmpty { return }
        let bytes = PtySession.forwardBytes(normalized, batch.openStringFragment)
        if bytes.isEmpty { return }
        for client in clientList {
            deliver(client, bytes)
        }
    }

    /// The broadcast for one batch: every token `QueryFilter` keeps, as forwarded, then the
    /// open string fragment. Not simply the raw chunk: the tokenizer holds back partial
    /// tails across reads (and can reorder a dangling UTF-8 lead around an escape), so the
    /// bytes are assembled from the tokens.
    private static func forwardBytes(_ tokens: [VtToken], _ fragment: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for token in tokens where !QueryFilter.isServerAnswered(token) {
            out += token.bytesToForward()
        }
        out += fragment
        return out
    }

    /// Under the lock, on every read: each idle watcher turns active (`output`) and gets a
    /// quiet check scheduled if it has none pending.
    private func markActive() {
        if watchers.isEmpty { return }
        for (watcher, state) in watchers {
            if !state.active {
                state.active = true
                emit(watcher, SessionEvent(name: name, type: MuxProtocol.EVENT_OUTPUT, outputBytes: outputCount))
            }
            if state.quietCheck == nil {
                scheduleQuietCheck(watcher, state, watcher.quietMs)
            }
        }
    }

    /// Must hold the lock.
    private func scheduleQuietCheck(_ watcher: SessionWatcher, _ state: WatchState, _ delayMs: Int64) {
        let item = DispatchWorkItem { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.quietCheck(watcher)
        }
        state.quietCheck = item
        PtySession.QUIET_TIMER.asyncAfter(deadline: .now() + .milliseconds(Int(max(1, delayMs))), execute: item)
    }

    /// On the timer: `quiet` if the watcher's period passed since the last read, otherwise a
    /// re-check when it would have. One pending check per watcher, so a busy session costs
    /// one timer task per quiet period, not one per read.
    private func quietCheck(_ watcher: SessionWatcher) {
        lock.lock(); defer { lock.unlock() }
        guard let state = watchers.first(where: { $0.0 === watcher })?.1, !exited else { return }
        state.quietCheck = nil
        if !state.active { return }
        let quietNanos = UInt64(max(0, watcher.quietMs)) * 1_000_000
        let now = nanoTime()
        let idle = now >= lastOutputNanos ? now - lastOutputNanos : 0
        if idle >= quietNanos {
            state.active = false
            emit(watcher, SessionEvent(name: name, type: MuxProtocol.EVENT_QUIET, outputBytes: outputCount))
        } else {
            scheduleQuietCheck(watcher, state, Int64((quietNanos - idle + 999_999) / 1_000_000))
        }
    }

    /// Under the lock, after an apply: a changed title, and one `bell` for a batch holding
    /// any BEL control (an OSC's BEL terminator is inside its OSC token, so a CONTROL BEL is
    /// always a real bell).
    private func notifyTitleAndBell(_ titleBefore: String, _ tokens: [VtToken]) {
        let title = terminal.title()
        if titleBefore != title {
            let event = SessionEvent(name: name, type: MuxProtocol.EVENT_TITLE, outputBytes: outputCount, title: title)
            for (watcher, _) in watchers { emit(watcher, event) }
        }
        for token in tokens where token.kind == .control && token.bytes.count == 1 && token.bytes[0] == 0x07 {
            let event = SessionEvent(name: name, type: MuxProtocol.EVENT_BELL, outputBytes: outputCount)
            for (watcher, _) in watchers { emit(watcher, event) }
            break
        }
    }

    /// Watchers and clients only enqueue (Swift has no unchecked exceptions to guard
    /// against, unlike the Java original).
    private func emit(_ watcher: SessionWatcher, _ event: SessionEvent) {
        watcher.onEvent(event)
    }

    private func deliver(_ client: SessionClient, _ bytes: [UInt8]) {
        client.onOutput(bytes)
    }

    // MARK: - writer

    private func drainPtyInput() {
        while let bytes = input.take() {
            do {
                try process.write(bytes)
            } catch {
                // The PTY closed underneath us: the pump is about to report the exit.
                Log.debug("writing to \(name) failed: \(error)", tag: "mux")
                input.finished(bytes.count)
                break
            }
            // Only now: a chunk stuck in the write is still held for the program.
            input.finished(bytes.count)
        }
        // Deliberately no close here: the master is shared with the pump, which closes it
        // once at EOF.
    }
}

/// The session's PTY input queue: bytes in order of acceptance, bounded by
/// `MAX_PENDING_INPUT_BYTES` counting the chunk the writer is in the middle of. A chunk is
/// always accepted into an empty queue whatever its size, so one large paste is never
/// refused outright.
private final class InputQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [[UInt8]] = []
    private var head = 0
    private var pending: Int64 = 0
    private var ended = false

    var pendingBytes: Int64 {
        condition.lock(); defer { condition.unlock() }
        return pending
    }

    /// False, with nothing enqueued, when `bytes` would not fit behind what is pending.
    func offer(_ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        condition.lock(); defer { condition.unlock() }
        if pending > 0 && pending + Int64(bytes.count) > PtySession.MAX_PENDING_INPUT_BYTES {
            return false
        }
        pending += Int64(bytes.count)
        if !ended {
            chunks.append(bytes)
            condition.signal()
        }
        return true
    }

    /// The next chunk; nil once the PTY is gone.
    func take() -> [UInt8]? {
        condition.lock(); defer { condition.unlock() }
        while head == chunks.count && !ended { condition.wait() }
        if head == chunks.count { return nil }
        let chunk = chunks[head]
        head += 1
        if head > 64 && head * 2 > chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
        return chunk
    }

    func finished(_ count: Int) {
        condition.lock(); defer { condition.unlock() }
        pending -= Int64(count)
    }

    /// The PTY is gone: the writer stops once it is woken.
    func end() {
        condition.lock(); defer { condition.unlock() }
        ended = true
        chunks.removeAll()
        head = 0
        condition.broadcast()
    }
}
