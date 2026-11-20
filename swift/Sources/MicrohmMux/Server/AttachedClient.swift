import Foundation
import MicrohmShared

/// The server's view of one attached connection: a bounded outbound byte queue and the
/// writer thread that drains it — the only thing that ever writes to the socket once the
/// connection is in attach mode. The pump (`onOutput`) and attach only enqueue.
///
/// Overflow policy (tmux's blocked-client behaviour): when a chunk would not fit behind
/// what is already queued, the queued live bytes are dropped, the client is marked BEHIND
/// and further output is discarded; when the writer finds the queue empty it asks the
/// session for a fresh snapshot (`Session.snapshotFor`), which arrives through `onSnapshot`
/// under the session lock — that is where BEHIND is cleared, so no live batch can slip in
/// ahead of the redraw. A client still BEHIND when the session ends is re-synced once more
/// before SESSION_EXITED, so it shows the final screen. A single chunk is always accepted
/// into an empty queue whatever its size, so a snapshot larger than the buffer cannot loop
/// the client through BEHIND for ever. A BEHIND client that completes no write for
/// `behindTimeout` is closed with an error RESPONSE (best effort: the socket is by
/// definition not draining) and its connection unwinds through `ClientConnection`, which
/// detaches it.
///
/// Nothing here blocks the caller of `onOutput` or `onExit`.
final class AttachedClient: SessionClient, @unchecked Sendable {

    /// How long the watchdog gives the writer to deliver the error RESPONSE before it
    /// closes the socket underneath it.
    private static let ERROR_DELIVERY_GRACE: TimeInterval = 1

    /// Upper bound on the payload of one DATA_OUT frame assembled from several queued
    /// chunks; a single larger chunk (e.g. a snapshot) still goes out whole.
    static let MAX_BATCH_BYTES = 64 * 1024

    private let session: Session
    private let sessionName: String
    private let socket: UnixSocket
    private let codec: FrameCodec
    private let capacity: Int
    private let behindTimeout: TimeInterval

    private let lock = NSCondition()
    private var queue: [[UInt8]] = []
    private var head = 0
    private var queued = 0
    private var behind = false
    /// A re-snapshot has been requested and not yet handed over (`onSnapshot`).
    private var resyncRequested = false
    private var watchdogArmed = false
    /// SESSION_EXITED or the error RESPONSE: written after the queue drains, then the
    /// socket is closed. Nil while the attachment is healthy.
    private var terminal: Frame?
    private var closed = false
    private var lastProgressNanos = nanoTime()
    private var writerDone = false

    init(session: Session, socket: UnixSocket, codec: FrameCodec, options: ServeOptions) {
        self.session = session
        self.sessionName = session.name
        self.socket = socket
        self.codec = codec
        self.capacity = options.clientBufferBytes
        self.behindTimeout = options.behindTimeout
    }

    func start() {
        let writer = Thread { [self] in drain() }
        writer.name = "microhm-mux-writer-\(sessionName)"
        writer.start()
    }

    private var isEmpty: Bool { head == queue.count }

    func onOutput(_ bytes: [UInt8]) {
        if bytes.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        if closed || terminal != nil || behind { return }
        if queued > 0 && queued + bytes.count > capacity {
            queue.removeAll()
            head = 0
            queued = 0
            behind = true
            armWatchdog()
            Log.debug("client of \(sessionName) fell behind; dropped its queue", tag: "mux")
            return
        }
        queue.append(bytes)
        queued += bytes.count
        lock.broadcast()
    }

    func onSnapshot(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        // Called under the session lock: clearing BEHIND here (and not a moment earlier in
        // the writer) is what guarantees nothing precedes the redraw.
        behind = false
        resyncRequested = false
        queue.removeAll()
        head = 0
        queued = 0
        if !bytes.isEmpty {
            queue.append(bytes)
            queued = bytes.count
        }
        lock.broadcast()
    }

    func onExit(_ exitCode: Int32) {
        let json = Json.object().with(MuxProtocol.F_NAME, sessionName).with(MuxProtocol.F_EXIT_CODE, exitCode)
        terminate(Frame.json(.SESSION_EXITED, json))
    }

    /// Stops the writer and closes the socket; idempotent. Called by the connection when its
    /// inbound side ends (DETACH, EOF, error).
    func close() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
        socket.close()
    }

    private func terminate(_ frame: Frame) {
        lock.lock(); defer { lock.unlock() }
        if closed || terminal != nil { return }
        terminal = frame
        lock.broadcast()
    }

    /// The writer loop: live bytes in order, a re-snapshot when BEHIND has drained (also
    /// once before the terminal frame, so a client that fell behind still sees the final
    /// screen), and finally the terminal frame, after which the socket is closed.
    private func drain() {
        defer {
            lock.lock()
            writerDone = true
            lock.broadcast()
            lock.unlock()
            socket.close()
        }
        while true {
            var next: Frame?
            var resnapshot = false
            lock.lock()
            while true {
                if closed {
                    lock.unlock()
                    return
                }
                if !isEmpty {
                    next = Frame(.DATA_OUT, pollBatch())
                    break
                }
                if behind && !resyncRequested {
                    // Drained while BEHIND: ask for a snapshot. BEHIND stays set until
                    // onSnapshot hands it over under the session lock.
                    resyncRequested = true
                    resnapshot = true
                    break
                }
                if let terminal, !behind || resyncRequested {
                    // Healthy, or the re-sync was requested and either landed (queue drained
                    // above) or can no longer arrive: send the terminal frame.
                    next = terminal
                    break
                }
                lock.wait()
            }
            lock.unlock()
            if resnapshot {
                session.snapshotFor(self)
                continue
            }
            guard let frame = next else { continue }
            do {
                try codec.write(frame)
            } catch {
                // The client went away or the connection was closed underneath us; the
                // reader side sees the same and detaches.
                Log.debug("writer for \(sessionName) stopped: \(error)", tag: "mux")
                return
            }
            markProgress()
            if frame.type != .DATA_OUT {
                return
            }
        }
    }

    /// Must hold `lock`; the queue must not be empty. Takes the head chunk and, while the
    /// total stays within `MAX_BATCH_BYTES`, the chunks queued behind it, so a backlog goes
    /// out as a few large frames rather than one frame per pump read.
    private func pollBatch() -> [UInt8] {
        var batch = queue[head]
        head += 1
        while head < queue.count && batch.count + queue[head].count <= AttachedClient.MAX_BATCH_BYTES {
            batch += queue[head]
            head += 1
        }
        queued -= batch.count
        if isEmpty {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
        return batch
    }

    private func markProgress() {
        lock.lock(); defer { lock.unlock() }
        lastProgressNanos = nanoTime()
    }

    /// Must hold `lock`.
    private func armWatchdog() {
        if watchdogArmed { return }
        watchdogArmed = true
        let watchdog = Thread { [self] in watch() }
        watchdog.name = "microhm-mux-watchdog-\(sessionName)"
        watchdog.start()
    }

    /// Sleeps until the BEHIND client has either recovered or gone `behindTimeout` without
    /// a completed write, then drops it.
    private func watch() {
        let timeoutNanos = UInt64(behindTimeout * 1e9)
        while true {
            lock.lock()
            if !behind || closed || terminal != nil {
                watchdogArmed = false
                lock.unlock()
                return
            }
            let now = nanoTime()
            let due = lastProgressNanos + timeoutNanos
            if now >= due {
                watchdogArmed = false
                lock.unlock()
                break
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: Double(due - now) / 1e9)
        }
        Log.info("client of \(sessionName) stayed behind for \(Int(behindTimeout)) s; dropping it", tag: "mux")
        terminate(Frame.json(.RESPONSE, Json.error("client fell behind and did not drain within "
                                                   + "\(Int(behindTimeout)) s; detached")))
        lock.lock()
        let deadline = Date(timeIntervalSinceNow: AttachedClient.ERROR_DELIVERY_GRACE)
        while !writerDone {
            if !lock.wait(until: deadline) { break }
        }
        lock.unlock()
        socket.close()
    }
}
