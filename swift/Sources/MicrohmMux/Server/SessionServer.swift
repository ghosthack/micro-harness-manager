import Darwin
import Foundation
import MicrohmShared

/// The daemon's transport: a Unix-domain listener on `<home>/server.sock` handing every
/// accepted socket to a `ClientConnection` on its own thread.
///
/// Startup order is fixed: (1) take `server.lock`; if another server holds it, `start`
/// returns false having touched nothing else; (2) holding the lock, probe-connect the
/// socket file and delete it when nobody answers — a bound socket file is never unlinked
/// on close, so a stale file is the normal state after every exit; (3) bind; (4) write the
/// pid into the lock file for diagnostics. Shutdown (the `shutdown` op, the idle timer, or
/// `close`) kills every session, closes the listener and the open connections, deletes the
/// socket file and releases the lock, in that order, then releases `awaitExit`.
public final class SessionServer: @unchecked Sendable {

    private let options: ServeOptions
    private let manager: SessionManager
    private var dispatcher: RequestDispatcher!
    private let lock = NSCondition()
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private var exited = false
    private var shuttingDown = false
    public let pid: Int32 = getpid()
    public let version: String = ServerVersion.current()

    private var serverLock: ServerLock?
    private var listener: UnixListener?

    public init(options: ServeOptions, manager: SessionManager) {
        self.options = options
        self.manager = manager
        self.dispatcher = RequestDispatcher(manager: manager, server: self)
    }

    /// Runs the startup sequence and begins accepting on a background thread. Returns false
    /// — with a log line and nothing bound, deleted or written — when another server owns
    /// the home; the caller exits 0 in that case.
    public func start() throws -> Bool {
        let home = options.home
        // Before anything is created in it: private to this user, or not ours to serve from.
        try ServerHome.secure(home)
        guard let acquired = try ServerLock.tryAcquire(ServerHome.lock(home)) else {
            Log.info("another server owns \(home.path); exiting", tag: "mux")
            return false
        }
        serverLock = acquired
        do {
            let socket = ServerHome.socket(home)
            try SessionServer.removeStaleSocket(socket)
            do {
                listener = try UnixListener(bind: socket.path)
            } catch let error as MuxIOError where error.message.contains("too long") {
                // The OS's message names neither the path nor the fix; this is the one bind
                // failure a user can act on directly.
                throw MuxIOError("cannot bind \(socket.path): the socket path is \(socket.path.utf8.count) bytes, over"
                                 + " the OS limit for Unix-domain sockets (104 on macOS, 108 on Linux); set"
                                 + " \(ServerHome.HOME_ENV) to a shorter directory")
            }
            // bind creates it with the umask's permissions; nobody else got to it in
            // between because the directory around it is already private.
            try ServerHome.restrict(socket)
            try acquired.writePid(pid)
        } catch {
            acquired.close()
            serverLock = nil
            throw error
        }
        manager.setListener { [weak self] in self?.onLastSessionEnded() }
        let accept = Thread { [self] in acceptLoop() }
        accept.name = "microhm-mux-accept"
        accept.start()
        Log.info("microhm-mux \(version) (protocol \(MuxProtocol.VERSION), pid \(pid)) listening on"
                 + " \(ServerHome.socket(home).path)", tag: "mux")
        return true
    }

    /// Blocks until the server has shut down.
    public func awaitExit() {
        lock.lock(); defer { lock.unlock() }
        while !exited { lock.wait() }
    }

    /// True when the server shut down within `timeout` seconds.
    public func awaitExit(within timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock(); defer { lock.unlock() }
        while !exited {
            if !lock.wait(until: deadline) { break }
        }
        return exited
    }

    public var isRunning: Bool { listener?.isOpen ?? false }

    public var home: URL { options.home }

    /// Adds `protocol`, `version` and `pid` — the ping reply and the fields a
    /// protocol-mismatch error carries.
    func identity(_ body: JSONObject) -> JSONObject {
        body.with(MuxProtocol.F_PROTOCOL, MuxProtocol.VERSION)
            .with(MuxProtocol.F_VERSION, version)
            .with(MuxProtocol.F_PID, pid)
    }

    /// Kills every session, stops listening, closes every connection, removes the socket
    /// file and releases the lock. Safe to call from any thread and more than once.
    public func shutdown() {
        lock.lock()
        if shuttingDown {
            lock.unlock()
            return
        }
        shuttingDown = true
        lock.unlock()
        Log.info("shutting down", tag: "mux")
        // Closes before it kills: a `new` still arriving on the open listener is refused
        // instead of being answered ok and dying with the process.
        manager.close()
        listener?.close()
        // Socket file and lock go before the connections: the client that asked for the
        // shutdown sees EOF only once a follow-up `new` can already take the home over.
        unlink(ServerHome.socket(options.home).path)
        serverLock?.close()
        lock.lock()
        let open = Array(connections.values)
        lock.unlock()
        for connection in open {
            connection.close()
        }
        lock.lock()
        exited = true
        lock.broadcast()
        lock.unlock()
    }

    public func close() {
        if serverLock == nil {
            return // start() never got the lock: nothing of ours to release
        }
        shutdown()
    }

    func forget(_ connection: ClientConnection) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// The open connections (tests).
    func openConnections() -> [ClientConnection] {
        lock.lock(); defer { lock.unlock() }
        return Array(connections.values)
    }

    private func onLastSessionEnded() {
        if options.keepAlive {
            Log.info("no sessions left; --keep-alive keeps the server up", tag: "mux")
            return
        }
        if !manager.closeIfIdle() {
            return // a session was created after the timer fired; its end re-arms the timer
        }
        Log.info("no sessions left; exiting", tag: "mux")
        // Off the manager's timer thread: shutdown calls back into the manager.
        let exit = Thread { [self] in shutdown() }
        exit.name = "microhm-mux-idle-exit"
        exit.start()
    }

    /// Step (2): under the lock, a socket file nobody answers on is stale and removed; one
    /// that answers means a live server without the lock, which is not ours to replace.
    private static func removeStaleSocket(_ socket: URL) throws {
        var st = stat()
        if lstat(socket.path, &st) != 0 {
            return
        }
        if let probe = try? UnixSocket.connect(socket.path) {
            probe.close()
            throw MuxIOError("\(socket.path) is in use by a server that does not hold the lock")
        }
        Log.info("removing stale socket file \(socket.path)", tag: "mux")
        unlink(socket.path)
    }

    private func acceptLoop() {
        guard let listener else { return }
        while true {
            let accepted: UnixSocket?
            do {
                accepted = try listener.accept()
            } catch {
                if !listener.isOpen { return }
                Log.warn("accept failed: \(error)", tag: "mux")
                continue
            }
            guard let socket = accepted else { return }
            let connection = ClientConnection(socket: socket, server: self, dispatcher: dispatcher, options: options)
            lock.lock()
            let refused = shuttingDown
            if !refused { connections[ObjectIdentifier(connection)] = connection }
            lock.unlock()
            if refused {
                socket.close()
                continue
            }
            let thread = Thread { connection.run() }
            thread.name = "microhm-mux-conn"
            thread.start()
        }
    }
}
