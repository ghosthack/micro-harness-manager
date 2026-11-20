import Foundation

/// `SessionServerClient.Watch` over one watch-mode connection: a reader thread hands each
/// event RESPONSE to the consumer, in order. The stream ends on EOF, on an `ok:false`
/// RESPONSE (the server dropping a watcher that fell behind), or on `close`, which sends
/// DETACH first.
final class SocketWatch: SessionServerClient.Watch, @unchecked Sendable {

    private let connection: ServerConnection
    private let codec: FrameCodec
    private let onEvent: (SessionEvent) -> Void
    private let lock = NSLock()
    private var closed = false
    private var open = true
    private var failure: String?

    init(connection: ServerConnection, onEvent: @escaping (SessionEvent) -> Void) {
        self.connection = connection
        self.codec = connection.codec
        self.onEvent = onEvent
        let reader = Thread { [self] in pump() }
        reader.name = "microhm-mux-watch-reader"
        reader.start()
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    var error: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let wasOpen = open
        lock.unlock()
        if wasOpen {
            // The server is gone or already closed the socket; closing below suffices.
            try? codec.write(Frame(.DETACH))
        }
        lock.lock(); open = false; lock.unlock()
        connection.close()
    }

    private func pump() {
        defer {
            lock.lock(); open = false; lock.unlock()
            connection.close()
        }
        while true {
            guard let frame = try? codec.read() else { return }
            if frame.type != .RESPONSE { continue } // not part of the watch vocabulary
            guard let body = (try? Json.parse(frame.payload))?.objectValue else { return }
            if !JsonDecoding.path(body, MuxProtocol.F_OK).asBoolean(false) {
                lock.lock(); failure = JsonDecoding.text(body, MuxProtocol.F_ERROR); lock.unlock()
                return
            }
            if body.has(MuxProtocol.F_EVENT) {
                onEvent(JsonDecoding.event(body))
            }
        }
    }
}
