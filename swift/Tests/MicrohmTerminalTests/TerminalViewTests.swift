import AppKit
import XCTest
import MicrohmVT
@testable import MicrohmTerminal

/// Collects what the view sends (thread-safe: replies arrive on the feeding thread).
final class Recorder: TerminalViewOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    var resizes: [String] = []

    func write(_ b: [UInt8]) {
        lock.lock()
        bytes += b
        lock.unlock()
    }

    func resize(columns: Int, rows: Int) {
        resizes.append("\(columns)x\(rows)")
    }

    /// Everything written since the last call, ESC shown as is.
    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let s = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll()
        return s
    }
}

/// Spins the main run loop until `condition` holds or `timeout` passes.
func spin(until condition: () -> Bool = { false }, timeout: TimeInterval = 0.05) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
    }
}

final class TerminalViewTests: XCTestCase {

    private let E = "\u{1b}"
    private var C: String { E + "[" }
    private let palette = AnsiPalettes.forSetting(.macosTerminal)
    private let background = 0x101010

    private var out: Recorder!
    private var view: TerminalView!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        out = Recorder()
        view = TerminalView(columns: 20, rows: 5, maxHistory: 100, output: out, palette: palette,
                            background: background, light: false, fontFamily: "Menlo", fontSize: 12)
        view.setDeviceScale(1)
        let size = NSSize(width: 20 * view.cellWidth, height: 5 * view.cellHeight)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.applyResize()
        out.resizes.removeAll()
    }

    override func tearDown() {
        window.contentView = nil
        window.close()
        view = nil
        super.tearDown()
    }

    /// Feeds and lets the frame run.
    private func feed(_ s: String) {
        let frames = view.frames
        view.feed(Array(s.utf8))
        spin(until: { self.view.frames > frames }, timeout: 0.5)
    }

    private func lines(_ from: Int, _ to: Int) {
        var s = ""
        for i in from..<to {
            s += "line\(i)\r\n"
        }
        feed(s)
    }

    // MARK: size

    func testGridSizeFromPixels() {
        XCTAssertTrue(TerminalView.gridSize(800, 512, 8, 16) == (100, 32))
        XCTAssertTrue(TerminalView.gridSize(799, 511, 8, 16) == (99, 31))
        XCTAssertTrue(TerminalView.gridSize(5, 5, 8, 16) == (2, 2))
        XCTAssertTrue(TerminalView.gridSize(0, 0, 8, 16) == (2, 2))
    }

    func testLayoutResizesTheEmulatorAndTheConnection() {
        view.setFrameSize(NSSize(width: 30 * view.cellWidth + 3, height: 10 * view.cellHeight + 1))
        view.applyResize()
        XCTAssertEqual(out.resizes, ["30x10"])
        XCTAssertEqual(view.emulator.columns(), 30)
        XCTAssertEqual(view.emulator.rows(), 10)
        view.setFrameSize(NSSize(width: 30 * view.cellWidth, height: 10 * view.cellHeight))
        view.applyResize() // same grid: no second resize
        XCTAssertEqual(out.resizes.count, 1)
    }

    /// At 2× the cell is measured in device pixels, so rounding costs half a point instead of
    /// a point: Menlo 14 keeps its own proportions (8.5 × 16.5 points).
    func testRetinaCellsKeepTheFontsProportions() {
        let retina = TerminalFonts(family: "Menlo", size: 14, scale: 2)
        XCTAssertEqual(retina.cellWidth, 17)
        XCTAssertEqual(retina.cellHeight, 33)
        let points = TerminalFonts(family: "Menlo", size: 14, scale: 1)
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        var w: UniChar = 0x57
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &w, &glyph, 1)
        let natural = Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
            / CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        let atPoints = Double(points.cellHeight) / Double(points.cellWidth)
        let atRetina = Double(retina.cellHeight) / Double(retina.cellWidth)
        XCTAssertLessThan(abs(atRetina - natural), abs(atPoints - natural))
        XCTAssertLessThan(abs(atRetina / natural - 1), 0.03)
    }

    // MARK: mouse helpers

    private func mouse(_ type: NSEvent.EventType, _ column: Int, _ row: Int, _ flags: NSEvent.ModifierFlags = [],
                       clicks: Int = 1) -> NSEvent {
        let scale = view.deviceScale
        let x = (Double(column * view.cellWidth) + 1) / scale
        let y = (Double(row * view.cellHeight) + 1) / scale
        let p = NSPoint(x: x, y: Double(view.bounds.height) - y)
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: 1)!
    }

    private func drag(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int, _ flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, c0, r0, flags))
        view.mouseDragged(with: mouse(.leftMouseDragged, c1, r1, flags))
        view.mouseUp(with: mouse(.leftMouseUp, c1, r1, flags))
    }

    func testAtTwoXTheViewConvertsBetweenPointsAndDevicePixels() {
        view.setDeviceScale(2)
        let cw = view.cellWidth
        let ch = view.cellHeight
        XCTAssertEqual(view.intrinsicContentSize.width, (Double(20 * cw) / 2).rounded(.up))
        view.setFrameSize(NSSize(width: (Double(33 * cw) / 2).rounded(.up), height: (Double(9 * ch) / 2).rounded(.up)))
        view.applyResize()
        XCTAssertEqual(out.resizes, ["33x9"])
        feed(C + "?1000h" + C + "?1006h")
        _ = out.drain()
        view.mouseDown(with: mouse(.leftMouseDown, 7, 3))
        XCTAssertEqual(out.drain(), C + "<0;8;4M")
    }

    // MARK: scrollback

    func testScrolledBackViewStaysAnchoredWhileOutputArrives() {
        lines(0, 50)
        view.pageUp()
        XCTAssertEqual(view.scrollOffset, 5)
        lines(50, 60)
        XCTAssertEqual(view.scrollOffset, 15, "anchored on the same lines")
        XCTAssertEqual(view.scrollPosition.offset, 15)
        view.scrollToBottom()
        lines(60, 70)
        XCTAssertEqual(view.scrollOffset, 0, "live view follows")
    }

    func testPagingIsClampedToTheHistory() {
        lines(0, 12)
        view.scrollToTop()
        let history = view.emulator.historySize()
        XCTAssertEqual(view.scrollOffset, history)
        view.pageUp()
        XCTAssertEqual(view.scrollOffset, history)
        view.pageDown()
        XCTAssertEqual(view.scrollOffset, history - 5)
        view.setScrollOffset(2) // the scroller drives the offset
        XCTAssertEqual(view.scrollOffset, 2)
    }

    func testTypingReturnsToTheLiveScreen() {
        lines(0, 30)
        view.pageUp()
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.scrollOffset, 0)
        XCTAssertEqual(out.drain(), "a")
    }

    func testPageKeysPageTheScrollbackExceptInAFullScreenProgram() {
        func key(_ code: UInt16) -> NSEvent {
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{F72C}",
                                    charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: code)!
        }
        lines(0, 30)
        view.keyDown(with: key(0x74)) // Page Up
        XCTAssertEqual(view.scrollOffset, 5)
        view.keyDown(with: key(0x73)) // Home
        XCTAssertEqual(view.scrollOffset, view.emulator.historySize())
        view.keyDown(with: key(0x77)) // End
        XCTAssertEqual(view.scrollOffset, 0)
        XCTAssertEqual(out.drain(), "")
        feed(C + "?1049h")
        view.keyDown(with: key(0x74))
        XCTAssertEqual(out.drain(), C + "5~", "the program gets it")
    }

    // MARK: wheel

    func testWheelRouting() {
        XCTAssertEqual(TerminalView.wheelRoute(true, .normal, true), .swallow)
        XCTAssertEqual(TerminalView.wheelRoute(true, .none, false), .swallow)
        XCTAssertEqual(TerminalView.wheelRoute(false, .x10, false), .mouseReport)
        XCTAssertEqual(TerminalView.wheelRoute(false, .anyMotion, true), .mouseReport)
        XCTAssertEqual(TerminalView.wheelRoute(false, .none, true), .arrowKeys)
        XCTAssertEqual(TerminalView.wheelRoute(false, .none, false), .scrollback)
    }

    /// One wheel notch: `lines` > 0 is up, towards the history.
    private func wheel(_ lines: Int32, _ flags: CGEventFlags = []) {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
                         wheel3: 0)!
        cg.flags = flags
        cg.location = window.convertPoint(toScreen: NSPoint(x: 2, y: view.bounds.height - 2))
        view.scrollWheel(with: NSEvent(cgEvent: cg)!)
    }

    func testWheelScrollsLocalHistory() {
        lines(0, 30)
        wheel(1)
        XCTAssertGreaterThanOrEqual(view.scrollOffset, 3)
        wheel(-1)
        XCTAssertEqual(view.scrollOffset, 0)
        XCTAssertEqual(out.drain(), "")
    }

    func testDisabledWheelIsSwallowed() {
        lines(0, 30)
        feed(C + "?1000h" + C + "?1006h")
        _ = out.drain()
        view.mouseWheelDisabled = true
        wheel(1)
        XCTAssertEqual(view.scrollOffset, 0)
        XCTAssertEqual(out.drain(), "")
    }

    func testWheelIsReportedWhenTheProgramTracksTheMouse() {
        feed(C + "?1000h" + C + "?1006h")
        _ = out.drain()
        wheel(1)
        XCTAssertTrue(out.drain().hasPrefix(C + "<64;1;1M"))
        wheel(-1, .maskControl)
        XCTAssertTrue(out.drain().hasPrefix(C + "<81;1;1M"))
    }

    func testWheelOnTheAlternateScreenSendsArrows() {
        feed(C + "?1049h")
        wheel(1)
        XCTAssertTrue(out.drain().hasPrefix(String(repeating: C + "A", count: 3)))
        feed(C + "?1h")
        wheel(-1)
        XCTAssertTrue(out.drain().hasPrefix(String(repeating: E + "OB", count: 3)))
    }

    // MARK: input

    func testAnswersOnlyTheColourSchemeQuery() {
        feed(C + "?996n")
        XCTAssertEqual(out.drain(), C + "?997;1n")
        view.setTheme(background: nil, light: true)
        feed(C + "?996n" + C + "?6n" + C + "?u" + C + ">q" + C + "?2004$p" + C + "c" + C + "5n")
        XCTAssertEqual(out.drain(), C + "?997;2n")
    }

    private func key(_ code: UInt16, _ chars: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!
    }

    func testPressedKeysAreSentOnceAndCommandChordsNever() {
        view.keyDown(with: key(0x7E, "\u{F700}", "\u{F700}")) // Up
        XCTAssertEqual(out.drain(), C + "A")
        view.keyDown(with: key(0x08, "\u{3}", "c", .control))
        XCTAssertEqual(out.drain(), "\u{3}")
        view.keyDown(with: key(0x0B, "∫", "b", .option))
        XCTAssertEqual(out.drain(), E + "b")
        view.optionAsMeta = false
        view.insertText("∫", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(out.drain(), "∫")
        XCTAssertFalse(view.performKeyEquivalent(with: key(0x11, "t", "t", .command)))
        XCTAssertEqual(out.drain(), "")
    }

    func testPasteIsNormalisedAndBracketed() {
        view.pasteText("a\nb")
        XCTAssertEqual(Array(out.drain().unicodeScalars), Array("a\rb".unicodeScalars))
        feed(C + "?2004h")
        view.pasteText("x\u{1b}[201~y")
        XCTAssertEqual(out.drain(), C + "200~xy" + C + "201~")
    }

    func testInputMethodCommitsAreSentAndCompositionIsHeldBack() {
        let none = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(out.drain(), "")
        view.insertText("é", replacementRange: none)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(out.drain(), "é")
        view.insertText("👍🏽", replacementRange: none) // the emoji picker
        XCTAssertEqual(out.drain(), "👍🏽")
    }

    // MARK: menu, links, selection

    private func labels(_ menu: NSMenu) -> [String] {
        return menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.isEnabled ? "" : " (off)") }
    }

    func testContextMenuEnablesCopyOnlyWithASelectionAndPagingOnlyWithHistory() {
        feed("hello")
        XCTAssertEqual(labels(view.contextMenu()),
                       ["Copy (off)", "Paste", "Select All", "-", "Page Up (off)", "Page Down (off)"])
        lines(0, 60)
        view.selectAll()
        XCTAssertEqual(labels(view.contextMenu()), ["Copy", "Paste", "Select All", "-", "Page Up", "Page Down (off)"])
        let up = view.contextMenu().items[4]
        _ = up.target?.perform(up.action, with: up)
        XCTAssertGreaterThan(view.scrollOffset, 0)
        XCTAssertEqual(labels(view.contextMenu())[5], "Page Down")
    }

    func testRightClickGoesToAProgramThatTracksTheMouse() {
        let plain = mouse(.rightMouseDown, 1, 0)
        XCTAssertNotNil(view.menu(for: plain))
        feed(C + "?1000h")
        _ = out.drain()
        XCTAssertNil(view.menu(for: plain), "no menu")
        view.rightMouseDown(with: plain)
        XCTAssertTrue(out.drain().hasPrefix(C + "M"), "reported to the program")
        XCTAssertNotNil(view.menu(for: mouse(.rightMouseDown, 1, 0, .shift)), "Shift+right-click still opens it")
    }

    func testCommandClickOpensTheLinkUnderThePointer() {
        var opened: [String] = []
        view.linkOpener = { opened.append($0.absoluteString) }
        // 20 columns: the link wraps onto the second row; the program tracks the mouse
        feed(C + "?1000hgo https://a.example/path/x end")
        view.mouseDown(with: mouse(.leftMouseDown, 2, 1, .command))
        XCTAssertEqual(opened, ["https://a.example/path/x"])
        XCTAssertEqual(out.drain(), "", "the click is not reported to the program")
        view.mouseDown(with: mouse(.leftMouseDown, 1, 0, .command))
        view.mouseDown(with: mouse(.leftMouseDown, 4, 0))
        XCTAssertEqual(opened.count, 1, "off the link, or without the modifier, nothing opens")
    }

    func testDragSelectsCharactersWordsAndLines() {
        feed("hello world\r\nsecond line")
        drag(6, 0, 6, 1)
        XCTAssertEqual(view.selectedText(), "world\nsecond")
        view.mouseDown(with: mouse(.leftMouseDown, 3, 1, clicks: 2))
        XCTAssertEqual(view.selectedText(), "second")
        view.mouseDown(with: mouse(.leftMouseDown, 3, 0, clicks: 3))
        XCTAssertEqual(view.selectedText(), "hello world")
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(view.selectedText(), "typing clears the selection")
    }

    func testShiftClickExtends() {
        feed("abcdefghij")
        drag(1, 0, 3, 0)
        view.mouseDown(with: mouse(.leftMouseDown, 6, 0, .shift))
        view.mouseUp(with: mouse(.leftMouseUp, 6, 0, .shift))
        XCTAssertEqual(view.selectedText(), "bcdef")
    }

    func testMouseTrackingTakesPlainClicksAndShiftStillSelects() {
        feed("hello world")
        feed(C + "?1002h" + C + "?1006h")
        drag(0, 0, 4, 0)
        XCTAssertEqual(out.drain(), C + "<0;1;1M" + C + "<32;5;1M" + C + "<0;5;1m")
        XCTAssertNil(view.selectedText())
        drag(0, 0, 5, 0, .shift)
        XCTAssertEqual(out.drain(), "")
        XCTAssertEqual(view.selectedText(), "hello")
    }

    // MARK: drawing

    /// The view drawn into an sRGB bitmap (y down), so colours compare exactly.
    private func render() -> Bitmap {
        let scale = view.deviceScale
        let image = Bitmap(Int((Double(view.bounds.width) * scale).rounded()),
                           Int((Double(view.bounds.height) * scale).rounded()))
        let g = image.context
        g.saveGState()
        g.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.current = previous
        g.restoreGState()
        return image
    }

    private func pixel(_ image: Bitmap, _ column: Int, _ row: Int, _ dx: Int, _ dy: Int) -> Int {
        return image.rgb(column * view.cellWidth + dx, row * view.cellHeight + dy)
    }

    private func close(_ a: Int, _ b: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let d = max(abs((a >> 16) - (b >> 16)), abs(((a >> 8) & 0xFF) - ((b >> 8) & 0xFF)), abs((a & 0xFF) - (b & 0xFF)))
        XCTAssertLessThanOrEqual(d, 2, "\(what): \(String(a, radix: 16)) vs \(String(b, radix: 16))",
                                 file: file, line: line)
    }

    func testDrawsBackgroundsInverseBoxDrawingAndTheCursor() {
        feed(C + "41m  " + C + "0m " + C + "7m " + C + "0m\r\n" + "─────\r\n" + C + "48;2;1;2;3m " + C + "0m\r\n"
             + C + "4;3H")
        let image = render()
        let cw = view.cellWidth
        let ch = view.cellHeight
        close(pixel(image, 10, 0, cw / 2, ch / 2), background, "default background")
        close(pixel(image, 0, 0, cw / 2, ch / 2), palette[1], "explicit red background")
        close(pixel(image, 1, 0, 0, 0), palette[1], "merged run")
        close(pixel(image, 3, 0, cw / 2, ch / 2), palette[15], "inverse: default fg behind")
        close(pixel(image, 0, 2, cw / 2, ch / 2), 0x010203, "truecolor background")
        let t = max(1, BoxDrawing.jround(Double(cw) / 8))
        close(pixel(image, 2, 1, cw / 2, (ch - t) / 2), palette[15], "box line through the cell")
        close(pixel(image, 2, 1, 0, (ch - t) / 2), palette[15], "reaches the cell edge")
        close(pixel(image, 2, 1, cw / 2, 1), background, "only the line")
        // unfocused cursor at row 3, column 2: a hollow block
        close(pixel(image, 2, 3, 0, 0), palette[15], "cursor outline")
        close(pixel(image, 2, 3, cw / 2, ch / 2), background, "hollow inside")
        view.setFocusedForTest(true)
        close(pixel(render(), 2, 3, cw / 2, ch / 2), palette[15], "focused: a block")
        feed(C + "?25l")
        close(pixel(render(), 2, 3, 0, 0), background, "hidden cursor")
    }

    func testReverseVideoSwapsTheDefaults() {
        feed(C + "?5h")
        close(pixel(render(), 10, 2, 3, 3), palette[15], "reverse video")
    }

    func testThemeAndPaletteRecolourLive() {
        feed(C + "41m " + C + "0m")
        view.setTheme(background: nil, light: true)
        view.setPalette(AnsiPalettes.forSetting(.xterm))
        let image = render()
        close(pixel(image, 10, 2, 3, 3), 0xFFFFFF, "light default background from the palette")
        close(pixel(image, 0, 0, 3, 3), 0xCD0000, "existing cell redrawn in the new palette")
    }

    func testSelectionIsHighlighted() {
        feed("abc")
        drag(0, 0, 2, 0)
        let image = render()
        close(pixel(image, 0, 0, 0, 0), 0x264F78, "selected")
        close(pixel(image, 2, 0, 0, 0), background, "not selected")
    }

    // MARK: frames

    func testHiddenViewDoesNoFrameWorkAndCatchesUpWhenShown() {
        lines(0, 30)
        view.pageUp()
        let offset = view.scrollOffset
        view.isHidden = true
        let frames = view.frames
        let full = view.fullFrames
        for i in 0..<5 {
            view.feed(Array("hidden\(i)\r\n".utf8))
            spin(timeout: 0.03)
        }
        XCTAssertEqual(view.frames, frames, "no frames while hidden")
        XCTAssertEqual(view.scrollOffset, offset, "not re-anchored yet")
        view.isHidden = false
        spin(until: { self.view.frames > frames }, timeout: 2)
        XCTAssertEqual(view.frames, frames + 1, "one catch-up frame")
        XCTAssertEqual(view.fullFrames, full + 1, "a full redraw")
        XCTAssertEqual(view.scrollOffset, offset + 5, "anchored over everything that arrived")
    }

    func testABurstOfOutputIsCoalescedIntoFewFrames() {
        let frames = view.frames
        DispatchQueue.global().sync {
            for i in 0..<2000 {
                view.feed(Array("burst \(i)\r\n".utf8))
            }
        }
        spin(timeout: 0.2)
        XCTAssertLessThan(view.frames - frames, 20, "frames coalesced")
    }
}
