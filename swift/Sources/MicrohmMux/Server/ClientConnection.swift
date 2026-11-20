import Foundation
import MicrohmShared

/// One accepted socket, on its own thread. Starts as a control connection (any number of
/// request/response pairs, answered from this thread) and, after a successful `attach`,
/// becomes dedicated to that session: from then on this thread only reads (DATA_IN,
/// RESIZE, DETACH) and the `AttachedClient`'s writer owns the socket's outbound side.
/// Whatever ends the inbound loop — DETACH, EOF, a bad frame, the session exiting — the
/// client is detached from the session and the socket closed exactly once.
///
/// A successful `watch` likewise makes the connection dedicated: a `WatchStream` is
/// registered on the watched sessions (on all of them, and on every one created later,
/// when no names were given) and owns the outbound side; this thread then only waits for
/// DETACH or EOF, and closing unregisters it everywhere.
final class ClientConnection: @unchecked Sendable {

    private let socket: UnixSocket
    private let codec: FrameCodec
    private unowned let server: SessionServer
    private let dispatcher: RequestDispatcher
    private let options: ServeOptions

    private let lock = NSLock()
    private var closed = false
    private var session: Session?
    private var client: AttachedClient?
    private var watch: WatchStream?
    /// Every session the watch is registered on, with the per-session watcher it was
    /// registered as, to unregister on close. An entry leaves when its session exits, so a
    /// long-lived watch of all sessions does not keep every ended session reachable.
    private var watched: [ObjectIdentifier: (Session, SessionWatch)] = [:]
    private var watchNewSessions: CreatedListener?

    init(socket: UnixSocket, server: SessionServer, dispatcher: RequestDispatcher, options: ServeOptions) {
        self.socket = socket
        self.codec = FrameCodec(socket)
        self.server = server
        self.dispatcher = dispatcher
        self.options = options
    }

    func run() {
        defer { close() }
        do {
            while true {
                guard let frame = try codec.read() else { return }
                lock.lock()
                let attached = client
                let watching = watch
                lock.unlock()
                if attached != nil {
                    if !handleAttached(frame) { return }
                } else if watching != nil {
                    if frame.type == .DETACH { return }
                    Log.debug("ignoring \(frame.type) frame in watch mode", tag: "mux")
                } else if !(try handleControl(frame)) {
                    return
                }
            }
        } catch {
            // EOF mid-frame, a reset, or our own close from the writer/watchdog/shutdown.
            Log.debug("connection ended: \(error)", tag: "mux")
        }
    }

    /// Closes the socket (and the attach-mode writer) from any thread; idempotent.
    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let attached = client
        let attachedSession = session
        let stream = watch
        let listener = watchNewSessions
        let registrations = Array(watched.values)
        watched.removeAll()
        lock.unlock()
        if let attached, let attachedSession {
            attachedSession.detach(attached)
            attached.close()
        }
        if let stream {
            if let listener {
                dispatcher.manager.removeCreatedListener(listener)
            }
            for (s, watcher) in registrations {
                s.removeWatcher(watcher)
            }
            stream.close()
        }
        socket.close()
        server.forget(self)
    }

    /// False when the connection must end after this frame.
    private func handleControl(_ frame: Frame) throws -> Bool {
        if frame.type != .REQUEST {
            try codec.write(response(Json.error("expected a request frame, got \(frame.type)")))
            return false
        }
        let parsed: JSON
        do {
            parsed = try Json.parse(frame.payload)
        } catch {
            try codec.write(response(Json.error("malformed request: \(error)")))
            return false
        }
        guard case .object(let request) = parsed else {
            try codec.write(response(Json.error("request must be a JSON object")))
            return false
        }
        let op = JsonEncoding.textField(request, MuxProtocol.F_OP)
        let protocolNode = request[MuxProtocol.F_PROTOCOL]
        // Shutdown is exempt: it is the one request a client of another protocol version
        // must be able to make, or its only way to replace this server is to kill the pid.
        if op != MuxProtocol.OP_SHUTDOWN
            && (protocolNode == nil || !protocolNode!.canConvertToInt || protocolNode!.asInt() != MuxProtocol.VERSION) {
            try codec.write(response(server.identity(Json.error(MuxProtocol.ERROR_PROTOCOL_MISMATCH))))
            return false
        }
        guard let op else {
            try codec.write(response(Json.error("request has no op")))
            return true
        }
        switch op {
        case MuxProtocol.OP_ATTACH:
            return try attach(request)
        case MuxProtocol.OP_WATCH:
            return try watch(request)
        case MuxProtocol.OP_SHUTDOWN:
            try codec.write(response(Json.ok()))
            // Synchronous on purpose: the client's shutdown() returns when this socket
            // closes, and that must be after the lock is released so a follow-up `new`
            // cannot spawn a server that loses the lock to a dying one.
            server.shutdown()
            return false
        default:
            let reply = dispatcher.handle(op, request)
            try codec.write(response(reply ?? Json.error("unknown op: \(op)")))
            return true
        }
    }

    private func attach(_ request: JSONObject) throws -> Bool {
        guard let found = dispatcher.find(request) else {
            let name = JsonEncoding.textField(request, MuxProtocol.F_NAME) ?? ""
            try codec.write(response(RequestDispatcher.noSuchSession(name)))
            return true
        }
        let columns = JsonEncoding.intField(request, MuxProtocol.F_COLUMNS, 80)
        let rows = JsonEncoding.intField(request, MuxProtocol.F_ROWS, 24)
        if let badSize = RequestDispatcher.invalidSize(columns, rows) {
            try codec.write(response(Json.error(badSize)))
            return true
        }
        // The ok goes out from this thread before the writer exists, so it precedes every
        // DATA_OUT; from here on only the writer touches the outbound side.
        try codec.write(response(Json.ok()))
        let attached = AttachedClient(session: found, socket: socket, codec: codec, options: options)
        lock.lock()
        session = found
        client = attached
        lock.unlock()
        attached.start()
        found.attach(attached, columns: columns, rows: rows)
        return true
    }

    private func watch(_ request: JSONObject) throws -> Bool {
        var names: [String] = []
        if let namesNode = request[MuxProtocol.F_NAMES], !namesNode.isNull {
            guard case .array(let array) = namesNode else {
                try codec.write(response(Json.error("names must be an array of session names")))
                return true
            }
            for name in array {
                guard case .string(let s) = name else {
                    try codec.write(response(Json.error("names must be an array of session names")))
                    return true
                }
                names.append(s)
            }
        }
        var sessions: [Session] = []
        for name in names {
            guard let found = dispatcher.manager.find(name) else {
                try codec.write(response(RequestDispatcher.noSuchSession(name)))
                return true
            }
            sessions.append(found)
        }
        let quietMs = RequestDispatcher.clampMs(JsonEncoding.longField(request, MuxProtocol.F_QUIET_MS,
                                                                       MuxProtocol.WATCH_DEFAULT_QUIET_MS))
        // As with attach: the ok precedes every event because the writer starts after it.
        try codec.write(response(Json.ok()))
        let stream = WatchStream(socket: socket, codec: codec, quietMs: quietMs)
        lock.lock()
        watch = stream
        lock.unlock()
        stream.start()
        if names.isEmpty {
            // Listener first, then the current list: a session created in between is seen
            // twice, and register() registers it once.
            let listener = CreatedListener { [weak self, weak stream] created in
                guard let self, let stream else { return }
                self.register(stream, created)
            }
            lock.lock()
            watchNewSessions = listener
            lock.unlock()
            dispatcher.manager.addCreatedListener(listener)
            sessions = dispatcher.manager.sessions()
        }
        for s in sessions {
            register(stream, s)
        }
        return true
    }

    private func register(_ stream: WatchStream, _ s: Session) {
        let watcher = SessionWatch(stream: stream, session: s, connection: self)
        lock.lock()
        if closed || watched[ObjectIdentifier(s)] != nil {
            lock.unlock()
            return // closed, or seen twice (created listener and the list): already registered
        }
        watched[ObjectIdentifier(s)] = (s, watcher)
        lock.unlock()
        // An exited session emits its exit from inside addWatcher, which removes it again.
        s.addWatcher(watcher)
        lock.lock()
        let closedNow = closed
        lock.unlock()
        if closedNow {
            s.removeWatcher(watcher) // close() ran in between and may have missed it
        }
    }

    /// Forget a session whose exit the watch has seen.
    fileprivate func forgetWatched(_ s: Session, _ watcher: SessionWatch) {
        lock.lock(); defer { lock.unlock() }
        if let entry = watched[ObjectIdentifier(s)], entry.1 === watcher {
            watched.removeValue(forKey: ObjectIdentifier(s))
        }
    }

    /// The sessions the watch is currently registered on (tests).
    func watchedSessions() -> [Session] {
        lock.lock(); defer { lock.unlock() }
        return watched.values.map { $0.0 }
    }

    private func handleAttached(_ frame: Frame) -> Bool {
        lock.lock()
        let attachedSession = session
        let attached = client
        lock.unlock()
        guard let attachedSession else { return false }
        switch frame.type {
        case .DATA_IN:
            do {
                try attachedSession.write(frame.payload)
            } catch {
                // Attach mode has no reply to carry this; the keystrokes are dropped and the
                // attachment stays, as for a terminal whose program is hung.
                Log.debug("dropping input: \(error)", tag: "mux")
            }
            return true
        case .RESIZE:
            guard case .object(let size)? = try? Json.parse(frame.payload) else {
                Log.debug("ignoring malformed RESIZE", tag: "mux")
                return true
            }
            let columns = JsonEncoding.intField(size, MuxProtocol.F_COLUMNS, 80)
            let rows = JsonEncoding.intField(size, MuxProtocol.F_ROWS, 24)
            if let badSize = RequestDispatcher.invalidSize(columns, rows) {
                Log.debug("ignoring RESIZE: \(badSize)", tag: "mux")
                return true
            }
            attachedSession.resize(columns: columns, rows: rows, except: attached)
            return true
        case .DETACH:
            return false
        default:
            Log.debug("ignoring \(frame.type) frame in attach mode", tag: "mux")
            return true
        }
    }

    private func response(_ body: JSONObject) -> Frame {
        Frame(.RESPONSE, Json.bytes(body))
    }
}

/// The watcher one session of a watch is registered as: forwards to the connection's
/// `WatchStream` and, on the session's `exit` (its last event: the session drops its
/// watchers then), forgets the session. Runs under the session lock like any watcher.
/// Identity equality on purpose: sessions key their watchers by it.
private final class SessionWatch: SessionWatcher, @unchecked Sendable {
    private let stream: WatchStream
    private weak var session: Session?
    private weak var connection: ClientConnection?

    init(stream: WatchStream, session: Session, connection: ClientConnection) {
        self.stream = stream
        self.session = session
        self.connection = connection
    }

    func onEvent(_ event: SessionEvent) {
        stream.onEvent(event)
        if event.type == MuxProtocol.EVENT_EXIT, let session, let connection {
            connection.forgetWatched(session, self)
        }
    }

    var quietMs: Int64 { stream.quietMs }
}
