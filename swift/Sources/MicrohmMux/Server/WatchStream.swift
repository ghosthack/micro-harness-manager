import Foundation
import MicrohmShared

/// The server's side of one `watch` connection: a `SessionWatcher` registered on every
/// watched session, a bounded event queue, and the writer thread that turns each event
/// into a RESPONSE frame — the only thing that writes to the socket once the connection is
/// in watch mode. `onEvent` runs under a session lock and only enqueues. A watcher that
/// lets `CAPACITY` events pile up is dropped: the queue is discarded, an error RESPONSE is
/// written and the socket closed, and the connection's reader unwinds and unregisters it.
/// The error frame is best-effort: a peer that stopped reading leaves the writer blocked in
/// a write, so the overflow also starts a closer that gives the writer
/// `OVERFLOW_GRACE` to get the error out and then closes the socket regardless, which
/// unblocks the writer and the reader alike.
final class WatchStream: SessionWatcher, @unchecked Sendable {

    /// Events, not bytes: activity is edge-triggered, so a healthy reader never gets near.
    static let CAPACITY = 4096

    /// How long an overflowed watch's writer gets to deliver the error before the socket is
    /// closed under it.
    static let OVERFLOW_GRACE: TimeInterval = 2

    private let socket: UnixSocket
    private let codec: FrameCodec
    let quietMs: Int64

    private let lock = NSCondition()
    private var queue: [SessionEvent] = []
    private var head = 0
    private var overflowed = false
    private var closed = false
    private var writerDone = false

    init(socket: UnixSocket, codec: FrameCodec, quietMs: Int64) {
        self.socket = socket
        self.codec = codec
        self.quietMs = quietMs
    }

    func start() {
        let writer = Thread { [self] in drain() }
        writer.name = "microhm-mux-watch-writer"
        writer.start()
    }

    func onEvent(_ event: SessionEvent) {
        lock.lock(); defer { lock.unlock() }
        if closed || overflowed { return }
        if queue.count - head >= WatchStream.CAPACITY {
            queue.removeAll()
            head = 0
            overflowed = true
            Log.info("a watch fell \(WatchStream.CAPACITY) events behind; dropping it", tag: "mux")
            // Off this (session-locked) thread.
            let closer = Thread { [self] in closeAfterGrace() }
            closer.name = "microhm-mux-watch-overflow"
            closer.start()
        } else {
            queue.append(event)
        }
        lock.broadcast()
    }

    /// Stops the writer and closes the socket; idempotent.
    func close() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
        socket.close()
    }

    private func drain() {
        defer {
            lock.lock()
            writerDone = true
            lock.broadcast()
            lock.unlock()
            socket.close()
        }
        while true {
            lock.lock()
            while !closed && !overflowed && head == queue.count {
                lock.wait()
            }
            if closed {
                lock.unlock()
                return
            }
            let dropped = overflowed
            var next: SessionEvent?
            if !dropped {
                next = queue[head]
                head += 1
                if head == queue.count {
                    queue.removeAll(keepingCapacity: true)
                    head = 0
                }
            }
            lock.unlock()
            do {
                if dropped {
                    try codec.write(Frame.json(.RESPONSE, Json.error("watch fell more than \(WatchStream.CAPACITY)"
                                                                     + " events behind; closed")))
                    return
                }
                try codec.write(Frame.json(.RESPONSE, JsonEncoding.event(next!)))
            } catch {
                Log.debug("watch writer stopped: \(error)", tag: "mux")
                return
            }
        }
    }

    /// The overflow closer: waits for the writer to send the error and stop, but not for a
    /// writer stuck on a peer that no longer reads.
    private func closeAfterGrace() {
        lock.lock()
        let deadline = Date(timeIntervalSinceNow: WatchStream.OVERFLOW_GRACE)
        while !writerDone {
            if !lock.wait(until: deadline) { break }
        }
        lock.unlock()
        socket.close()
    }
}
