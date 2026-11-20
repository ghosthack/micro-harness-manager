import Foundation

/// A live attachment: the byte stream of one session plus resize, over a dedicated
/// connection. Shape mirrors what a terminal widget needs from a PTY, so the app's adapter
/// is a thin wrapper. Reading and writing may happen on different threads; `close` may be
/// called from any thread and unblocks a pending `read`.
public protocol AttachedSession: AnyObject {

    var sessionName: String { get }

    /// Blocks for the next chunk of session output (DATA_OUT payloads, delivered whole or
    /// in part). Returns -1 once the server has sent SESSION_EXITED or closed the
    /// connection, or after `close`. Throws once when the server dropped the attachment
    /// (a client that fell behind), with its reason.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// Sends keystrokes/bytes to the session (DATA_IN).
    func write(_ bytes: [UInt8]) throws

    func resize(columns: Int, rows: Int) throws

    /// True until SESSION_EXITED / EOF / close.
    var isConnected: Bool { get }

    /// The session's exit code once SESSION_EXITED arrived; nil while attached, or when the
    /// attachment ended for another reason (detach, server gone).
    var exitCode: Int32? { get }

    /// Blocks until the attachment ends; returns the exit code or -1.
    @discardableResult
    func waitFor() -> Int32

    /// Detaches (DETACH frame, then closes the socket). Never kills the session.
    func close()
}

extension AttachedSession {
    /// Up to `maxLength` bytes; nil at the end of the stream.
    public func read(maxLength: Int = 64 * 1024) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let n = try buffer.withUnsafeMutableBytes { try read(into: $0) }
        return n < 0 ? nil : Array(buffer[0..<n])
    }
}

/// `AttachedSession` over one attach-mode connection. A reader thread demultiplexes the
/// inbound frames: DATA_OUT into the `InboundPipe` that `read` drains, SESSION_EXITED into
/// `exitCode` followed by EOF, and an `ok:false` RESPONSE (the server dropping a client
/// that fell behind) into an error on the next read. Writes go straight to the codec from
/// the calling thread; the codec serializes them against a concurrent `close`.
final class SocketAttachedSession: AttachedSession, @unchecked Sendable {

    /// Enough for a full redraw plus a burst; beyond it the reader blocks and the server
    /// sees a slow client (see `InboundPipe`).
    static let PIPE_CAPACITY = 1024 * 1024

    let sessionName: String
    private let connection: ServerConnection
    private let codec: FrameCodec
    private let pipe = InboundPipe(capacity: SocketAttachedSession.PIPE_CAPACITY)
    private let state = NSCondition()
    private var ended = false
    private var closed = false
    private var connected = true
    private var exit: Int32?

    init(name: String, connection: ServerConnection) {
        self.sessionName = name
        self.connection = connection
        self.codec = connection.codec
        let reader = Thread { [self] in pump() }
        reader.name = "microhm-mux-attach-reader-\(name)"
        reader.start()
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try pipe.read(buffer)
    }

    func write(_ bytes: [UInt8]) throws {
        try send(Frame(.DATA_IN, bytes))
    }

    func resize(columns: Int, rows: Int) throws {
        try send(Frame.json(.RESIZE, Json.object().with(MuxProtocol.F_COLUMNS, columns).with(MuxProtocol.F_ROWS, rows)))
    }

    var isConnected: Bool {
        state.lock(); defer { state.unlock() }
        return connected
    }

    var exitCode: Int32? {
        state.lock(); defer { state.unlock() }
        return exit
    }

    func waitFor() -> Int32 {
        state.lock(); defer { state.unlock() }
        while !ended { state.wait() }
        return exit ?? -1
    }

    func close() {
        state.lock()
        if closed {
            state.unlock()
            return
        }
        closed = true
        let wasConnected = connected
        state.unlock()
        if wasConnected {
            // The server is gone or already closed the socket: closing below suffices.
            try? codec.write(Frame(.DETACH))
        }
        connection.close()
        pipe.close()
        finish()
    }

    private func send(_ frame: Frame) throws {
        if !isConnected {
            throw MuxIOError("not attached to \(sessionName)")
        }
        try codec.write(frame)
    }

    private func pump() {
        defer {
            finish()
            connection.close()
        }
        do {
            while true {
                guard let frame = try codec.read() else {
                    pipe.eof()
                    return
                }
                switch frame.type {
                case .DATA_OUT:
                    if !pipe.append(frame.payload) { return }
                case .SESSION_EXITED:
                    let body = (try? Json.parse(frame.payload))?.objectValue ?? Json.object()
                    let code = JsonDecoding.path(body, MuxProtocol.F_EXIT_CODE).asInt(-1)
                    state.lock(); exit = Int32(code); state.unlock()
                    pipe.eof()
                    return
                case .RESPONSE:
                    let body = (try? Json.parse(frame.payload))?.objectValue ?? Json.object()
                    if !JsonDecoding.path(body, MuxProtocol.F_OK).asBoolean(false) {
                        pipe.fail(JsonDecoding.text(body, MuxProtocol.F_ERROR))
                        return
                    }
                default:
                    break // not part of the server→client attach vocabulary; skip it
                }
            }
        } catch {
            // Server gone, a reset, or our own close(): the stream simply ends.
            pipe.eof()
        }
    }

    private func finish() {
        state.lock()
        connected = false
        ended = true
        state.broadcast()
        state.unlock()
    }
}
