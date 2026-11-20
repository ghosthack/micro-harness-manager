import Darwin
import Foundation

/// Where the CLI writes (Java: a `PrintStream`): a file descriptor, or a buffer in tests.
public protocol CliOutput: AnyObject {
    func write(_ bytes: [UInt8])
}

extension CliOutput {
    /// `PrintStream.println`.
    public func println(_ text: String) { write(Array((text + "\n").utf8)) }
    /// `PrintStream.print`.
    public func print(_ text: String) { write(Array(text.utf8)) }
}

/// Where the CLI reads keystrokes from (attach): -1 at end of input.
public protocol CliInput: AnyObject {
    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int
}

public final class FileDescriptorOutput: CliOutput, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    public init(_ fd: Int32) { self.fd = fd }

    public static let standardOutput = FileDescriptorOutput(1)
    public static let standardError = FileDescriptorOutput(2)

    public func write(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        bytes.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + written, raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                written += n
            }
        }
    }
}

public final class FileDescriptorInput: CliInput, @unchecked Sendable {
    private let fd: Int32
    public init(_ fd: Int32) { self.fd = fd }

    public static let standardInput = FileDescriptorInput(0)

    public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        while true {
            let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
            if n < 0 && errno == EINTR { continue }
            return n <= 0 ? -1 : n
        }
    }
}

/// Collects output in memory (tests).
public final class BufferOutput: CliOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []

    public init() {}

    public func write(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        buffer += bytes
    }

    public var bytes: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// Input from a fixed byte string, then end of input (tests).
public final class BufferInput: CliInput, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]
    public init(_ bytes: [UInt8] = []) { self.bytes = bytes }

    public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        lock.lock(); defer { lock.unlock() }
        if bytes.isEmpty { return -1 }
        let n = min(buffer.count, bytes.count)
        buffer.copyBytes(from: bytes[0..<n])
        bytes.removeFirst(n)
        return n
    }
}
