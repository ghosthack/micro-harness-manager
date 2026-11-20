import Foundation
import MicrohmMux
import MicrohmShared

/// A `SessionConnection` over the daemon's attach stream. Thin by design: the daemon's
/// `AttachedSession` was shaped after what a terminal widget needs from a PTY, so every
/// call maps one to one. `close()` sends DETACH and closes the socket; the session — and
/// the daemon — live on.
///
/// It is also a push-style terminal transport with exactly the members of
/// `MicrohmTerminal.TerminalTransport` (`send(_:)`, `resize(cols:rows:)`, `onBytes`,
/// `onEnd`, `start()`, `isAlive`, `close()`), so the app conforms it with a one-line
/// `extension SessionServerConnection: TerminalTransport {}`. Set `onBytes`/`onEnd`, then
/// `start()`: a reader thread delivers the output (the daemon's redraw first) and calls
/// `onEnd` once. Don't mix that with the pull-style `read`.
public final class SessionServerConnection: SessionConnection, @unchecked Sendable {

    private let attached: AttachedSession
    private let lock = NSLock()
    private var started = false
    private var ended = false

    /// Program output, on the reader thread, in order. Set before `start()`.
    public var onBytes: ((Data) -> Void)?
    /// The stream ended (EOF, an error, or after `close()`). Called once, on any thread.
    public var onEnd: (() -> Void)?

    init(_ attached: AttachedSession) {
        self.attached = attached
    }

    public var name: String { attached.sessionName }

    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try attached.read(into: buffer)
    }

    public func write(_ bytes: [UInt8]) throws {
        try attached.write(bytes)
    }

    /// Best effort: the widget calls this from its layout pass, and a socket that breaks
    /// underneath it is reported by the reader's next `read` returning -1, not by an error
    /// out of a layout.
    public func resize(_ columns: Int, _ rows: Int) {
        guard attached.isConnected else { return }
        do {
            try attached.resize(columns: columns, rows: rows)
        } catch {
            Log.debug("resize of the attach stream for \(name) failed: \(error)", tag: "daemon")
        }
    }

    public var isAlive: Bool { attached.isConnected }

    /// The session's exit code when it ended while attached; 0 after a detach or a lost
    /// server, which have no process status.
    @discardableResult
    public func waitFor() -> Int32 {
        attached.waitFor()
        return attached.exitCode ?? 0
    }

    public func close() {
        attached.close()
    }

    // MARK: - TerminalTransport shape

    /// Sends input bytes; a broken stream drops them (the reader reports the end).
    public func send(_ bytes: Data) {
        do {
            try attached.write([UInt8](bytes))
        } catch {
            Log.debug("write to the attach stream for \(name) failed: \(error)", tag: "daemon")
        }
    }

    public func resize(cols: Int, rows: Int) {
        resize(cols, rows)
    }

    /// Begins delivering `onBytes`; idempotent.
    public func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        let reader = Thread { [self] in pump() }
        reader.name = "microhm-attach-\(name)"
        reader.start()
    }

    private func pump() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n: Int
            do {
                n = try buffer.withUnsafeMutableBytes { try attached.read(into: $0) }
            } catch {
                Log.debug("attach stream for \(name) ended: \(error)", tag: "daemon")
                break
            }
            if n < 0 {
                break
            }
            if n > 0 {
                onBytes?(Data(buffer[0..<n]))
            }
        }
        finish()
    }

    private func finish() {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        lock.unlock()
        onEnd?()
    }
}
