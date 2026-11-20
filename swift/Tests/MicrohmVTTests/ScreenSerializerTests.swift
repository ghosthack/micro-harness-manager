import XCTest
@testable import MicrohmVT

/**
 * The redraw on attach (`ScreenSerializer`). The contract is the round trip: feed a byte
 * stream into emulator A, serialize A, feed the result into a fresh emulator B of the same
 * size, and assert A and B agree on every cell, wrapped flag, cursor, scroll region, autowrap,
 * origin mode, current style and mode.
 */
final class ScreenSerializerTests: XCTestCase {

    private static let HISTORY = 2000

    private func build(_ cols: Int, _ rows: Int, _ inputs: String...) -> HeadlessTerminal {
        let term = HeadlessTerminal(cols, rows, ScreenSerializerTests.HISTORY) { _ in }
        let tok = VtTokenizer()
        for s in inputs {
            apply(term, tok, s)
        }
        return term
    }

    private func apply(_ term: HeadlessTerminal, _ tok: VtTokenizer, _ s: String) {
        apply(term, tok, bytes(s))
    }

    private func apply(_ term: HeadlessTerminal, _ tok: VtTokenizer, _ data: [UInt8]) {
        term.apply(tok.feed(data).tokens.map { SgrNormalizer.normalize($0) })
    }

    /** Serialize A into a fresh B of the same size and assert they match. */
    @discardableResult
    private func roundTrip(_ a: HeadlessTerminal, file: StaticString = #filePath, line: UInt = #line) -> HeadlessTerminal {
        let redraw = a.serialize(ScreenSerializerTests.HISTORY)
        let b = HeadlessTerminal(a.columns(), a.rows(), ScreenSerializerTests.HISTORY) { _ in }
        apply(b, VtTokenizer(), redraw)
        assertSameState(a, b, file: file, line: line)
        XCTAssertEqual(a.modes(), b.modes(), "modes", file: file, line: line)
        XCTAssertEqual(a.screenText(), b.screenText(), "screen text", file: file, line: line)
        return b
    }

    private func assertSameState(_ a: HeadlessTerminal, _ b: HeadlessTerminal, file: StaticString = #filePath, line: UInt = #line) {
        ModelAssert.assertSameState(a.emulator(), b.emulator(), ScreenSerializerTests.HISTORY, file: file, line: line)
    }

    private func cursorX(_ t: HeadlessTerminal) -> Int {
        return t.emulator().cursorColumn()
    }

    func testPlainText() {
        roundTrip(build(40, 6, "hello world\r\nsecond line\r\nthird"))
    }

    func testStylesRgb256AndInverseSpaceRuns() {
        roundTrip(build(40, 6,
                        "\u{1b}[1;31mbold red\u{1b}[m normal\r\n"
                            + "\u{1b}[38;5;208m256orange\u{1b}[m\r\n"
                            + "\u{1b}[38;2;10;200;30mtruecolor\u{1b}[m\r\n"
                            + "\u{1b}[7m inverse spaces \u{1b}[m done"))
    }

    func testColours256AndRgb() {
        roundTrip(build(30, 4, "\u{1b}[48;5;27m bg256 \u{1b}[m\u{1b}[48;2;1;2;3m bgrgb \u{1b}[m"))
    }

    func testTitleIsRestored() {
        roundTrip(build(30, 3, "\u{1b}]0;My Session\u{7}content"))
    }

    func testBracketedPasteAndMouseModes() {
        roundTrip(build(30, 3, "\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?25l\u{1b}[3 qprompt"))
    }

    func testHistoryBeyondTheScreen() {
        var sb = ""
        for i in 0..<30 {
            sb += "line \(i)\r\n"
        }
        sb += "last"
        roundTrip(build(20, 5, sb))
    }

    func testWrappedLineWhoseLastCellIsSpace() {
        roundTrip(build(10, 4, "ABCDEFGHI JKLMNOP"))
    }

    func testEraseAfterBackgroundColour() {
        roundTrip(build(20, 4, "hi\u{1b}[44m\u{1b}[K\r\nnext"))
    }

    func testEraseDisplayAfterBackgroundColour() {
        roundTrip(build(20, 4, "\u{1b}[41mstart\u{1b}[2J\u{1b}[Hafter"))
    }

    func testDeleteCharOnWrappedLine() {
        roundTrip(build(8, 4, "ABCDEFGHijkl\u{1b}[3;1H\u{1b}[2P"))
    }

    func testLineExactlyColumnsWideNoCarriageReturn() {
        let a = build(12, 4, "ABCDEFGHIJKL")
        XCTAssertEqual(11, cursorX(a))
        XCTAssertTrue(a.emulator().cursorPendingWrap())
        let b = roundTrip(a)
        XCTAssertEqual(11, cursorX(b))
        XCTAssertTrue(b.emulator().cursorPendingWrap())
        apply(a, VtTokenizer(), "Z")
        apply(b, VtTokenizer(), "Z")
        assertSameState(a, b)
    }

    func testPendingWrapFollowUpWrite() {
        let a = build(6, 4, "\u{1b}[1;33mABCDEF")
        XCTAssertTrue(a.emulator().cursorPendingWrap())
        let b = roundTrip(a)
        apply(a, VtTokenizer(), "g")
        apply(b, VtTokenizer(), "g")
        assertSameState(a, b)
    }

    func testWideCharAtLastColumn() {
        let a = build(6, 4, "abcd\u{4e2d}")
        let b = roundTrip(a)
        apply(a, VtTokenizer(), "x")
        apply(b, VtTokenizer(), "x")
        assertSameState(a, b)
    }

    func testEmojiOnScreen() {
        roundTrip(build(20, 4, "hi 🛑 stop 🚀 go"))
    }

    func testAltScreenWithNonHomeCursorSgrAndOrigin() {
        let a = build(20, 6, "\u{1b}]0;main\u{7}main text\u{1b}[3;5H"
                        + "\u{1b}[?1049h\u{1b}[?6h\u{1b}[2;10r\u{1b}[4;3H\u{1b}[1;32malt screen")
        let b = roundTrip(a)
        apply(a, VtTokenizer(), "\u{1b}[?1049l")
        apply(b, VtTokenizer(), "\u{1b}[?1049l")
        assertSameState(a, b)
    }

    func testScrollRegionSetThenResized() {
        let a = build(20, 10, "\u{1b}[3;8rregion text\r\nmore")
        a.resize(20, 14)
        roundTrip(a)
    }

    func testAltScreenEnteredFromNonZeroMainColumnDrawsRowZeroFromHome() {
        roundTrip(build(20, 6, "main text\r\nlong prompt $ " + "\u{1b}[?1049h\u{1b}[2J\u{1b}[Hheader row\r\nsecond row"))
    }

    func testWrappedLineWithBlankContinuation() {
        roundTrip(build(10, 4, "abcdefghij   \r\nnext"))
    }

    func testSpacePaddedLineWiderThanTheScreen() {
        let a = build(10, 4, "short         \r\n$ ")
        XCTAssertEqual(2, a.emulator().cursorRow())
        roundTrip(a)
    }

    func testWrappedHistoryLineWhoseBlankContinuationIsScreenRowZero() {
        let a = build(10, 4, "abcdefghij   \r\none\r\ntwo\r\nthree")
        XCTAssertEqual(1, a.emulator().historySize())
        XCTAssertTrue(a.emulator().line(-1).isWrapped())
        roundTrip(a)
    }

    func testScrollRegionRoundTrips() {
        roundTrip(build(20, 10, "\u{1b}[2;9rinside"))
    }

    func testModesKittyCharsetsAndSyncRoundTrip() {
        roundTrip(build(20, 4, "\u{1b}[>5u\u{1b}[?2026h\u{1b})0\u{e}\u{1b}[4h\u{1b}[20h\u{1b}[?5h\u{1b}=\u{1b}[?1015h"
                            + "\u{1b}[3g\u{1b}[1;4H\u{1b}H\u{1b}[1;1Hx\u{1b}[4:3;53m"))
    }

    func testExactRedrawBytes() {
        let a = build(10, 2, "\u{1b}[1mhi\u{1b}[m")
        let expected = "\u{1b}[?1049l\u{1b}[0m\u{1b}[?7h\u{1b}[r\u{1b}[?25l\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}(B\u{f}\u{1b}[4l"
            + "\u{1b}[0;1mhi\u{1b}[0m\u{1b}[K\r\n\u{1b}[K"
            + "\u{1b}[?6l\u{1b}[1;3H\u{1b}[?7h\u{1b}[?25h"
        XCTAssertEqual(visible(expected), visible(String(decoding: a.serialize(0), as: UTF8.self)))
    }
}
