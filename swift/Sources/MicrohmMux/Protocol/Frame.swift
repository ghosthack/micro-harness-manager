import Foundation

/// Frame type codes of wire protocol v1. A frame is `u32 big-endian length` (of type byte
/// + payload), `u8 type`, then the payload. See PROTOCOL.md.
public enum FrameType: UInt8, Sendable, CustomStringConvertible {
    /// Client → server: a JSON object with an `"op"` field.
    case REQUEST = 1
    /// Server → client: JSON `{"ok":true,...}` or `{"ok":false,"error":"..."}`.
    case RESPONSE = 2
    /// Server → client, attach mode only: raw bytes the session wrote.
    case DATA_OUT = 16
    /// Client → server, attach mode only: raw bytes for the session's PTY.
    case DATA_IN = 17
    /// Client → server, attach mode only: JSON `{"columns":n,"rows":n}`.
    case RESIZE = 18
    /// Client → server, attach mode only: empty payload; the server closes the connection.
    case DETACH = 19
    /// Server → client, attach mode only: JSON `{"name":...,"exitCode":n}`; the server
    /// closes the connection right after.
    case SESSION_EXITED = 20

    public var code: UInt8 { rawValue }

    public static func fromCode(_ code: Int) throws -> FrameType {
        guard let type = FrameType(rawValue: UInt8(truncatingIfNeeded: code)), code >= 0, code <= 255 else {
            throw MuxIOError("unknown frame type \(code)")
        }
        return type
    }

    public var description: String {
        switch self {
        case .REQUEST: return "REQUEST"
        case .RESPONSE: return "RESPONSE"
        case .DATA_OUT: return "DATA_OUT"
        case .DATA_IN: return "DATA_IN"
        case .RESIZE: return "RESIZE"
        case .DETACH: return "DETACH"
        case .SESSION_EXITED: return "SESSION_EXITED"
        }
    }
}

/// One wire frame. `payload` is never nil (empty for DETACH).
public struct Frame: Sendable {
    /// Hard ceiling on a single frame's payload; larger is a protocol error, not a resize.
    public static let MAX_PAYLOAD = 16 * 1024 * 1024

    public let type: FrameType
    public let payload: [UInt8]

    public init(_ type: FrameType, _ payload: [UInt8] = []) {
        precondition(payload.count <= Frame.MAX_PAYLOAD, "frame payload too large: \(payload.count)")
        self.type = type
        self.payload = payload
    }

    public static func of(_ type: FrameType, _ payload: [UInt8]) -> Frame { Frame(type, payload) }

    public static func json(_ type: FrameType, _ object: JSONObject) -> Frame { Frame(type, Json.bytes(object)) }

    public var payloadAsString: String { String(decoding: payload, as: UTF8.self) }
}

/// Reads and writes `Frame`s over one socket. One reader thread per connection; writes are
/// serialized here (attach mode: session output and SESSION_EXITED race). The input is
/// buffered (a header and a small payload cost one read syscall); the output is not: each
/// `write` pushes its frame out before returning.
public final class FrameCodec: @unchecked Sendable {

    /// Payloads up to this size are sent in one write together with the header; larger ones
    /// go header-then-payload to avoid copying them.
    static let COALESCE_LIMIT = 16 * 1024

    private let socket: UnixSocket
    private let writeLock = NSLock()
    private var buffer = [UInt8](repeating: 0, count: 8192)
    private var start = 0
    private var end = 0

    public init(_ socket: UnixSocket) {
        self.socket = socket
    }

    /// Fills `count` bytes into `out`; returns how many arrived before EOF.
    private func readFully(_ out: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        var got = 0
        while got < count {
            if start < end {
                let n = min(count - got, end - start)
                buffer.withUnsafeBytes { raw in
                    (out + got).copyMemory(from: raw.baseAddress! + start, byteCount: n)
                }
                start += n
                got += n
                continue
            }
            if count - got >= buffer.count {
                // A large payload: straight into the destination.
                let n = try socket.read(out + got, count - got)
                if n == 0 { return got }
                got += n
                continue
            }
            let n = try buffer.withUnsafeMutableBytes { try socket.read($0.baseAddress!, $0.count) }
            if n == 0 { return got }
            start = 0
            end = n
        }
        return got
    }

    /// Blocks until one full frame has arrived. Returns nil on EOF before a complete header;
    /// throws on a truncated frame or an oversized/unknown one.
    public func read() throws -> Frame? {
        var header = [UInt8](repeating: 0, count: 5)
        let got = try header.withUnsafeMutableBytes { try readFully($0.baseAddress!, 4) }
        if got < 4 { return nil }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        let signed = Int(Int32(bitPattern: UInt32(length)))
        if signed < 1 || signed - 1 > Frame.MAX_PAYLOAD {
            throw MuxIOError("bad frame length \(signed)")
        }
        let typeGot = try header.withUnsafeMutableBytes { try readFully($0.baseAddress! + 4, 1) }
        if typeGot < 1 { throw MuxIOError("end of stream inside a frame", isEOF: true) }
        let type = try FrameType.fromCode(Int(header[4]))
        var payload = [UInt8](repeating: 0, count: signed - 1)
        if !payload.isEmpty {
            let n = try payload.withUnsafeMutableBytes { try readFully($0.baseAddress!, $0.count) }
            if n < payload.count { throw MuxIOError("end of stream inside a frame", isEOF: true) }
        }
        return Frame(type, payload)
    }

    /// Writes one frame. Thread-safe.
    public func write(_ frame: Frame) throws {
        let payload = frame.payload
        let length = UInt32(payload.count + 1)
        let header: [UInt8] = [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff),
                               UInt8(length >> 8 & 0xff), UInt8(length & 0xff), frame.type.code]
        writeLock.lock(); defer { writeLock.unlock() }
        if payload.count <= FrameCodec.COALESCE_LIMIT {
            let wire = header + payload
            try wire.withUnsafeBytes { try socket.write($0) }
        } else {
            try header.withUnsafeBytes { try socket.write($0) }
            try payload.withUnsafeBytes { try socket.write($0) }
        }
    }
}
