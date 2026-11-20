import AppKit
import XCTest
import MicrohmVT
@testable import MicrohmTerminal

/// A transport fed by the test: program output on a background thread, input recorded.
final class FakeTransport: TerminalTransport, @unchecked Sendable {
    var onBytes: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    private let lock = NSLock()
    private var sent = Data()
    private(set) var log: [String] = []
    private(set) var closes = 0
    private(set) var started = false
    private var alive = true

    func send(_ bytes: Data) {
        lock.lock()
        sent += bytes
        log.append("w:" + String(decoding: bytes, as: UTF8.self))
        lock.unlock()
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        log.append("r:\(cols)x\(rows)")
        lock.unlock()
    }

    func start() {
        started = true
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    func close() {
        lock.lock()
        closes += 1
        alive = false
        lock.unlock()
        onEnd?()
    }

    /// Program output, from another thread as a real transport would.
    func emit(_ s: String) {
        let data = Data(s.utf8)
        DispatchQueue.global().sync {
            onBytes?(data)
        }
    }

    func end() {
        lock.lock()
        alive = false
        lock.unlock()
        DispatchQueue.global().async {
            self.onEnd?()
        }
    }

    var written: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: sent, as: UTF8.self)
    }

    func entries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}

final class SessionTerminalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testOutputReachesTheModel() {
        let t = FakeTransport()
        let terminal = SessionTerminal(transport: t, config: SessionTerminal.Config())
        XCTAssertTrue(t.started)
        t.emit("hello")
        XCTAssertEqual(terminal.terminalView.emulator.line(0).toString().trimmingCharacters(in: .whitespaces), "hello")
        XCTAssertTrue(terminal.isAlive)
    }

    func testEndOfStreamEndsTheTerminal() {
        let t = FakeTransport()
        let terminal = SessionTerminal(transport: t, config: SessionTerminal.Config())
        var ended = 0
        terminal.onEnded { ended += 1 }
        t.end()
        spin(until: { ended > 0 }, timeout: 2)
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(terminal.isAlive)
        XCTAssertTrue(terminal.terminalView.ended)
    }

    func testDetachClosesTheTransportOnceAndDoesNotReportAnEnd() {
        let t = FakeTransport()
        let terminal = SessionTerminal(transport: t, config: SessionTerminal.Config())
        var ended = 0
        terminal.onEnded { ended += 1 }
        terminal.detach()
        terminal.detach()
        spin(until: { t.closes > 0 }, timeout: 2)
        spin(timeout: 0.05)
        XCTAssertEqual(t.closes, 1)
        XCTAssertEqual(ended, 0, "a detach is not the session ending")
        terminal.terminalView.pasteText("ignored")
        spin(timeout: 0.05)
        XCTAssertEqual(t.written, "", "input after detach goes nowhere")
    }

    func testInputAndResizesGoToTheTransportInOrder() {
        let t = FakeTransport()
        let terminal = SessionTerminal(transport: t, config: SessionTerminal.Config())
        terminal.terminalView.pasteText("one")
        terminal.terminalView.setFrameSize(NSSize(width: 400, height: 200))
        terminal.terminalView.applyResize()
        terminal.terminalView.pasteText("two")
        spin(until: { t.written == "onetwo" }, timeout: 2)
        let entries = t.entries()
        XCTAssertEqual(entries.first, "w:one")
        XCTAssertTrue(entries[1].hasPrefix("r:"), "\(entries)")
        XCTAssertEqual(entries.last, "w:two")
    }

    func testColourSchemeQueryIsAnsweredThroughTheTransport() {
        let t = FakeTransport()
        let terminal = SessionTerminal(transport: t, config: SessionTerminal.Config())
        t.emit("\u{1b}[?996n")
        spin(until: { t.written.contains("997") }, timeout: 2)
        XCTAssertEqual(t.written, "\u{1b}[?997;1n")
        terminal.applyBackground(light: true)
        t.emit("\u{1b}[?996n")
        spin(until: { t.written.hasSuffix("997;2n") }, timeout: 2)
        XCTAssertTrue(t.written.hasSuffix("\u{1b}[?997;2n"))
    }

    func testSettingsApplyLive() {
        let t = FakeTransport()
        let terminal = SessionTerminal(transport: t, config: SessionTerminal.Config(fontSize: 99))
        XCTAssertEqual(terminal.terminalView.fonts.size, 36, "clamped")
        terminal.applyFont(family: "Menlo", size: 12)
        XCTAssertEqual(terminal.terminalView.fonts.size, 12)
        terminal.applyOptionAsMeta(false)
        XCTAssertFalse(terminal.terminalView.optionAsMeta)
        terminal.applyMouseWheelDisabled(true)
        XCTAssertTrue(terminal.terminalView.mouseWheelDisabled)
        terminal.applyPalette(.xterm)
        XCTAssertEqual(terminal.terminalView.colors.rgb(Style.indexed(1), true), 0xCD0000)
    }
}
