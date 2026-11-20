import Darwin
import Foundation
import XCTest
@testable import MicrohmMux

/// A private temporary home with a short path (a Unix socket path has a 104-byte ceiling),
/// removed afterwards. Never the user's real home.
final class TempHome {
    let root: URL
    let home: URL

    init() {
        var template = Array("/tmp/mhm-test-XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        precondition(made != nil, "mkdtemp failed")
        root = URL(fileURLWithPath: String(cString: template), isDirectory: true).resolvingSymlinksInPath()
        home = root.appendingPathComponent("mux", isDirectory: true)
    }

    /// A plain directory for sessions to start in.
    func workdir(_ name: String = "work") -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Polls `condition` until it holds or `timeout` elapses (Java tests' `Await`).
func awaitCondition(_ timeout: TimeInterval = 10, _ what: String = "condition",
                    file: StaticString = #filePath, line: UInt = #line, _ condition: () throws -> Bool) rethrows {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if try condition() { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
    if try condition() { return }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

let testEnvironmentShell = "/bin/sh"

/// The built `microhm-mux` next to the test bundle (SwiftPM puts every product in one
/// directory).
func builtMicrohmMux() -> URL? {
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("microhm-mux")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// Records what a session hands an attached client (Java tests' `RecordingClient`).
final class RecordingClient: SessionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private(set) var snapshots = 0
    private var exit: Int32?

    func onOutput(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        self.bytes += bytes
    }

    func onSnapshot(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        snapshots += 1
        self.bytes += bytes
    }

    func onExit(_ exitCode: Int32) {
        lock.lock(); defer { lock.unlock() }
        exit = exitCode
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var exitCode: Int32? {
        lock.lock(); defer { lock.unlock() }
        return exit
    }
}

/// Records watch events.
final class RecordingWatcher: SessionWatcher, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SessionEvent] = []
    let quietMs: Int64

    init(quietMs: Int64 = 200) { self.quietMs = quietMs }

    func onEvent(_ event: SessionEvent) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event)
    }

    var events: [SessionEvent] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var types: [String] { events.map(\.type) }
}

/// A raw protocol connection for wire-level assertions.
final class RawConnection {
    let socket: UnixSocket
    let codec: FrameCodec

    init(_ home: URL) throws {
        socket = try UnixSocket.connect(ServerHome.socket(home).path)
        codec = FrameCodec(socket)
    }

    func send(_ object: JSONObject) throws {
        try codec.write(Frame.json(.REQUEST, object))
    }

    func sendRaw(_ type: FrameType, _ payload: [UInt8]) throws {
        try codec.write(Frame(type, payload))
    }

    func reply() throws -> JSONObject? {
        guard let frame = try codec.read() else { return nil }
        return try Json.parse(frame.payload).objectValue
    }

    func request(_ op: String, _ fields: JSONObject = Json.object()) throws -> JSONObject? {
        try send(fields.with(MuxProtocol.F_OP, op).with(MuxProtocol.F_PROTOCOL, MuxProtocol.VERSION))
        return try reply()
    }

    func close() { socket.close() }
}
