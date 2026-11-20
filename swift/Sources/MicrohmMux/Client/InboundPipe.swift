import Foundation

/// The bounded byte buffer between an attachment's socket reader thread and whoever calls
/// `SocketAttachedSession.read`. The bound is deliberate: a widget that stops reading
/// fills this, then the socket, and the server's per-client policy takes over —
/// backpressure instead of an unbounded heap. `eof` and `fail` end the stream after
/// whatever is already buffered has been read; `close` ends it now.
final class InboundPipe: @unchecked Sendable {

    private let condition = NSCondition()
    private var chunks: [[UInt8]] = []
    private var head = 0          // index of the first chunk still queued
    private let capacity: Int
    private var headOffset = 0
    private var buffered = 0
    private var ended = false
    private var closed = false
    private var failure: String?
    private var failureReported = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Blocks while the pipe is full; returns false once the pipe has been closed.
    func append(_ bytes: [UInt8]) -> Bool {
        condition.lock(); defer { condition.unlock() }
        if bytes.isEmpty { return !closed }
        while buffered > 0 && buffered + bytes.count > capacity && !closed && !ended {
            condition.wait()
        }
        if closed || ended { return false }
        chunks.append(bytes)
        buffered += bytes.count
        condition.broadcast()
        return true
    }

    /// -1 at the end of the stream; throws once when the server refused the attachment
    /// mid-stream, then behaves as ended.
    func read(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if buffer.count == 0 { return 0 }
        condition.lock(); defer { condition.unlock() }
        while head == chunks.count && !ended && !closed && failure == nil {
            condition.wait()
        }
        if head == chunks.count {
            if let failure, !failureReported {
                failureReported = true
                throw MuxIOError(failure)
            }
            return -1
        }
        var copied = 0
        while copied < buffer.count && head < chunks.count {
            let chunk = chunks[head]
            let n = min(buffer.count - copied, chunk.count - headOffset)
            chunk.withUnsafeBytes { raw in
                (buffer.baseAddress! + copied).copyMemory(from: raw.baseAddress! + headOffset, byteCount: n)
            }
            copied += n
            headOffset += n
            buffered -= n
            if headOffset == chunk.count {
                head += 1
                headOffset = 0
            }
        }
        if head > 64 && head * 2 > chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
        condition.broadcast()
        return copied
    }

    /// The server ended the stream cleanly: buffered bytes stay readable, then -1.
    func eof() {
        condition.lock(); defer { condition.unlock() }
        ended = true
        condition.broadcast()
    }

    /// The server refused the attachment: buffered bytes stay readable, then an error with
    /// `message`, then -1.
    func fail(_ message: String) {
        condition.lock(); defer { condition.unlock() }
        if failure == nil { failure = message }
        ended = true
        condition.broadcast()
    }

    /// Local close: pending reads return -1 immediately and buffered bytes are dropped.
    func close() {
        condition.lock(); defer { condition.unlock() }
        closed = true
        chunks.removeAll()
        head = 0
        headOffset = 0
        buffered = 0
        condition.broadcast()
    }
}
