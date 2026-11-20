import Foundation
import XCTest
@testable import MicrohmVT

/** A terminal with replies captured in the FULL scope. */
final class Term {
    let e: TerminalEmulator
    private let box = Subject.ReplyBox()
    var replies: [String] { box.replies }

    init(_ columns: Int, _ rows: Int, _ history: Int = 100) {
        e = TerminalEmulator(columns, rows, history)
        let box = self.box
        e.setReplies({ box.replies.append(String(decoding: $0, as: UTF8.self)) }, .full)
    }

    @discardableResult
    func feed(_ s: String) -> Term {
        e.feed(bytes(s))
        return self
    }

    func row(_ y: Int) -> String {
        return stripTrailing(e.line(y).toString())
    }

    func style(_ y: Int, _ x: Int) -> Int64 {
        return e.line(y).style(x)
    }

    func cursor(_ row: Int, _ column: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual("\(row),\(column)", "\(e.cursorRow()),\(e.cursorColumn())", "cursor", file: file, line: line)
    }

    func rows() -> [String] {
        return (0..<e.rows()).map { row($0) }
    }
}

/** Java's String.stripTrailing (whitespace as Character.isWhitespace, ASCII range). */
func stripTrailing(_ s: String) -> String {
    var scalars = s.unicodeScalars
    while let last = scalars.last, last == " " || (last.value >= 0x09 && last.value <= 0x0D) || (last.value >= 0x1C && last.value <= 0x1F) {
        scalars.removeLast()
    }
    return String(scalars)
}

/** Code point equality (Swift's String == is canonical equivalence). */
func XCTAssertScalars(_ expected: String, _ actual: String, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(expected.unicodeScalars.elementsEqual(actual.unicodeScalars),
                  "\(message) expected \(Array(expected.unicodeScalars)) got \(Array(actual.unicodeScalars))",
                  file: file, line: line)
}

func term(_ columns: Int, _ rows: Int) -> Term {
    return Term(columns, rows, 100)
}

func visible(_ s: String) -> String {
    return s.replacingOccurrences(of: "\u{1b}", with: "ESC").replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{7}", with: "BEL")
        .replacingOccurrences(of: "\u{8}", with: "\\b").replacingOccurrences(of: "\t", with: "\\t")
}

/** True when another thread cannot take `lock` (so this thread holds it). */
func heldByCurrentThread(_ lock: NSRecursiveLock) -> Bool {
    var acquired = false
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        acquired = lock.try()
        if acquired {
            lock.unlock()
        }
        done.signal()
    }
    thread.start()
    done.wait()
    return !acquired
}

/** Unit tests of `TerminalEmulator`, per feature area, against xterm's behaviour. */
final class TerminalEmulatorPrintingTests: XCTestCase {

    func testDeferredWrapAtTheLastColumn() {
        let t = term(5, 3).feed("abcde")
        t.cursor(0, 4)
        XCTAssertTrue(t.e.cursorPendingWrap())
        t.feed("f")
        XCTAssertEqual("abcde", t.row(0))
        XCTAssertEqual("f", t.row(1))
        XCTAssertTrue(t.e.line(0).isWrapped())
        XCTAssertFalse(t.e.line(1).isWrapped())
    }

    func testCarriageReturnClearsThePendingWrap() {
        let t = term(5, 3).feed("abcde\rX")
        XCTAssertEqual("Xbcde", t.row(0))
        XCTAssertFalse(t.e.line(0).isWrapped())
    }

    func testAutowrapOffOverwritesTheLastColumn() {
        let t = term(5, 3).feed(C + "?7labcdefg")
        XCTAssertEqual("abcdg", t.row(0))
        XCTAssertEqual("", t.row(1))
    }

    func testWrappingAtTheBottomScrollsIntoHistory() {
        let t = term(3, 2).feed("abcdefghi")
        XCTAssertEqual(1, t.e.historySize())
        XCTAssertEqual("abc", t.e.line(-1).toString())
        XCTAssertTrue(t.e.line(-1).isWrapped())
        XCTAssertEqual("def", t.row(0))
        XCTAssertEqual("ghi", t.row(1))
    }

    func testWideCharactersTakeTwoCells() {
        let t = term(10, 2).feed("a\u{4e2d}b")
        let l = t.e.line(0)
        XCTAssertEqual(2, l.width(1))
        XCTAssertTrue(l.isWideTail(2))
        XCTAssertEqual(0, l.width(2))
        XCTAssertEqual("", l.text(2))
        XCTAssertEqual(0x62, l.codePoint(3))
        t.cursor(0, 4)
    }

    func testWideCharacterThatDoesNotFitWraps() {
        let t = term(4, 3).feed("abc\u{4e2d}")
        XCTAssertEqual("abc", t.row(0))
        XCTAssertTrue(t.e.line(0).isEmpty(3))
        XCTAssertTrue(t.e.line(0).isWrapped())
        XCTAssertEqual("\u{4e2d}", t.row(1))
        t.cursor(1, 2)
    }

    func testOverwritingHalfAWideCharacterBlanksTheOtherHalf() {
        let t = term(10, 2).feed("\u{4e2d}\u{6587}" + C + "1;2Hx")
        XCTAssertEqual(" x\u{6587}", t.row(0))
        t.feed(C + "1;3Hy")
        XCTAssertEqual(" xy ", String(t.e.line(0).toString().prefix(4)))
        XCTAssertFalse(t.e.line(0).isWideTail(3))
    }

    func testCombiningMarksAttachToThePreviousCell() {
        let t = term(10, 2).feed("e\u{301}x")
        XCTAssertScalars("e\u{301}", t.e.line(0).text(0))
        XCTAssertEqual(0x78, t.e.line(0).codePoint(1))
        t.cursor(0, 2)
    }

    func testCombiningMarkAtThePendingWrapAttachesToTheLastCell() {
        let t = term(3, 2).feed("abe\u{301}")
        XCTAssertScalars("e\u{301}", t.e.line(0).text(2))
        XCTAssertTrue(t.e.cursorPendingWrap())
    }

    func testEmojiSequencesShareOneCell() {
        let s = "\u{1f469}\u{200d}\u{1f4bb}|\u{1f44d}\u{1f3fd}|\u{1f1fa}\u{1f1f8}|\u{2764}\u{fe0f}|"
        let t = term(20, 2).feed(s)
        XCTAssertScalars(s, t.row(0).replacingOccurrences(of: " ", with: ""))
        XCTAssertEqual(2, t.e.line(0).width(0))
        XCTAssertEqual(0x7C, t.e.line(0).codePoint(2))
        XCTAssertEqual(0x7C, t.e.line(0).codePoint(5))
        XCTAssertEqual(0x7C, t.e.line(0).codePoint(8))
        XCTAssertEqual(0x7C, t.e.line(0).codePoint(10)) // U+2764 is narrow; VS16 attaches
    }

    func testAsciiAfterZwjDoesNotJoin() {
        let t = term(10, 2).feed("a\u{200d}b")
        XCTAssertScalars("a\u{200d}", t.e.line(0).text(0))
        XCTAssertEqual(0x62, t.e.line(0).codePoint(1))
    }

    func testInsertModeShiftsTheLine() {
        XCTAssertEqual("XYZbcd", term(6, 2).feed("abcdef\r" + C + "4hXY" + C + "4lZ").row(0))
    }

    func testRepeatsTheLastCharacter() {
        XCTAssertEqual("abbbb", term(10, 2).feed("ab" + C + "3b").row(0))
    }

    func testDecSpecialGraphicsAndUkCharsets() {
        let t = term(20, 2).feed(E + "(0lqkx_" + E + "(B lqk " + E + "(A#" + E + "(B#")
        XCTAssertScalars("\u{250c}\u{2500}\u{2510}\u{2502}\u{a0} lqk \u{a3}#", t.row(0))
    }

    func testShiftOutAndShiftIn() {
        let t = term(10, 2).feed(E + ")0a\u{e}q\u{f}q" + E + "*0" + E + "Nqq")
        XCTAssertEqual("a\u{2500}q\u{2500}q", t.row(0))
    }

    func testMalformedUtf8BecomesReplacementCharacters() {
        let t = term(10, 2)
        t.e.feed([0x61, 0xC3, 0x62, 0xFF, 0xE4, 0xB8, 0xAD])
        XCTAssertEqual("a\u{fffd}b\u{fffd}\u{4e2d}", t.row(0))
    }

    func testUtf8SplitAcrossFeeds() {
        let t = term(10, 2)
        for b in bytes("x\u{4e2d}y") {
            t.e.feed([b])
        }
        XCTAssertEqual("x\u{4e2d}y", t.row(0))
    }

    func testC1ControlsAndDelAreDropped() {
        XCTAssertEqual("abc", term(10, 2).feed("a\u{85}b\u{7f}c").row(0))
    }
}

final class TerminalEmulatorCursorTests: XCTestCase {

    func testAbsolutePositioning() {
        let t = term(20, 10)
        t.feed(C + "3;4H").cursor(2, 3)
        t.feed(C + "5;6f").cursor(4, 5)
        t.feed(C + "H").cursor(0, 0)
        t.feed(C + "99;99H").cursor(9, 19)
        t.feed(C + "7G").cursor(9, 6)
        t.feed(C + "3`").cursor(9, 2)
        t.feed(C + "2d").cursor(1, 2)
        t.feed(C + "0;0H").cursor(0, 0)
    }

    func testRelativeMovesWithDefaultsAndClamping() {
        let t = term(20, 10).feed(C + "5;5H")
        t.feed(C + "A").cursor(3, 4)
        t.feed(C + "0B").cursor(4, 4)
        t.feed(C + "3C").cursor(4, 7)
        t.feed(C + "2D").cursor(4, 5)
        t.feed(C + "99D").cursor(4, 0)
        t.feed(C + "99A").cursor(0, 0)
        t.feed(C + "2a").cursor(0, 2) // HPR
        t.feed(C + "3e").cursor(3, 2) // VPR
        t.feed(C + "2E").cursor(5, 0)
        t.feed(C + "4;4H" + C + "F").cursor(2, 0)
    }

    func testVerticalMovesRespectTheMarginsFromInside() {
        let t = term(20, 10).feed(C + "3;6r" + C + "5;1H")
        t.feed(C + "9A").cursor(2, 0)
        t.feed(C + "9B").cursor(5, 0)
        t.feed(C + "8;1H" + C + "9A").cursor(2, 0)
        t.feed(C + "1;1H" + C + "9B").cursor(5, 0)
        t.feed(C + "2;1H" + C + "A").cursor(0, 0)
    }

    func testOriginModeIsRelativeToTheRegion() {
        let t = term(20, 10).feed(C + "3;6r" + C + "?6h")
        t.cursor(2, 0)
        t.feed(C + "2;3H").cursor(3, 2)
        t.feed(C + "99;1H").cursor(5, 0)
        t.feed(C + "1d").cursor(2, 0)
        t.feed(C + "6n")
        XCTAssertEqual(C + "1;1R", t.replies.last)
        t.feed(C + "?6l").cursor(0, 0)
    }

    func testBackspaceStopsAtColumnZeroAndClearsThePendingWrap() {
        XCTAssertEqual("abcXe", term(5, 3).feed("\u{8}").feed("abcde\u{8}X").row(0))
    }

    func testRelativeMoveFromAPendingWrapStartsAtTheLastColumn() {
        term(5, 3).feed("abcde" + C + "D").cursor(0, 3)
    }

    func testTabsAndTabStops() {
        let t = term(30, 3).feed("\tx")
        t.cursor(0, 9)
        t.feed(C + "2I").cursor(0, 24)
        t.feed("\t\t\t").cursor(0, 29)
        t.feed(C + "Z").cursor(0, 24)
        t.feed(C + "3Z").cursor(0, 0)
        t.feed(C + "3g" + C + "1;4H" + E + "H\r\t").cursor(0, 3)
        t.feed("\t").cursor(0, 29)
        t.feed(C + "1;4H" + C + "g\r\t").cursor(0, 29)
        XCTAssertFalse(t.e.isTabStop(3))
    }

    func testSaveAndRestoreCursor() {
        let t = term(20, 5).feed(C + "2;3H" + C + "1;31m" + C + "?7l" + E + "7")
        t.feed(C + "0m" + C + "?7h" + C + "5;5H" + E + "8")
        t.cursor(1, 2)
        XCTAssertTrue(Style.bold(t.e.pen()))
        XCTAssertFalse(t.e.autoWrap())
        t.feed(C + "4;4H" + C + "s" + C + "1;1H" + C + "u").cursor(3, 3)
    }

    func testRestoreWithoutSaveHomesAndResets() {
        let t = term(20, 5).feed(C + "3;3H" + C + "1m" + E + "(0" + E + "8q")
        t.cursor(0, 1)
        XCTAssertEqual(Style.default, t.e.pen())
        XCTAssertEqual("q", t.row(0))
    }

    func testRestoredPendingWrapStillWraps() {
        XCTAssertEqual("x", term(4, 3).feed("abcd" + E + "7" + C + "3;1H" + E + "8x").row(1))
    }
}

final class TerminalEmulatorEraseTests: XCTestCase {

    func testEraseInDisplay() {
        var t = term(5, 3).feed("aaaaa\r\nbbbbb\r\nccccc" + C + "2;3H" + C + "J")
        XCTAssertEqual(["aaaaa", "bb", ""], t.rows())
        t = term(5, 3).feed("aaaaa\r\nbbbbb\r\nccccc" + C + "2;3H" + C + "1J")
        XCTAssertEqual(["", "   bb", "ccccc"], t.rows())
    }

    func testEraseDisplayTwoMovesTheScreenToHistory() {
        let t = term(5, 3).feed("one\r\ntwo" + C + "2J")
        XCTAssertEqual(2, t.e.historySize())
        XCTAssertEqual("one", stripTrailing(t.e.line(-2).toString()))
        XCTAssertEqual("", t.row(0))
        t.feed(C + "3J")
        XCTAssertEqual(0, t.e.historySize())
    }

    func testEraseInLine() {
        XCTAssertEqual("ab", term(6, 2).feed("abcdef" + C + "1;3H" + C + "K").row(0))
        XCTAssertEqual("   def", term(6, 2).feed("abcdef" + C + "1;3H" + C + "1K").row(0))
        XCTAssertEqual("", term(6, 2).feed("abcdef" + C + "2K").row(0))
    }

    func testEraseUsesTheBackgroundOnly() {
        let t = term(6, 2).feed("ab" + C + "1;4;31;44m" + C + "K")
        let erased = t.style(0, 5)
        XCTAssertEqual(Style.indexed(4), Style.background(erased))
        XCTAssertEqual(Style.colorDefault, Style.foreground(erased))
        XCTAssertFalse(Style.bold(erased))
        XCTAssertTrue(t.e.line(0).isEmpty(5))
    }

    func testEraseLineClearsTheWrappedFlag() {
        XCTAssertFalse(term(3, 3).feed("abcdef" + C + "1;1H" + C + "K").e.line(0).isWrapped())
    }

    func testInsertDeleteAndEraseCharacters() {
        XCTAssertEqual("ab  cdef", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "2@").row(0))
        XCTAssertEqual("abefgh", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "2P").row(0))
        XCTAssertEqual("ab   fgh", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "3X").row(0))
        XCTAssertEqual("ab", term(8, 2).feed("abcdefgh" + C + "1;3H" + C + "99P").row(0))
    }

    func testDeleteCharactersSplittingAWideCharacter() {
        let t = term(8, 2).feed("a\u{4e2d}b" + C + "1;3H" + C + "P")
        XCTAssertEqual("a b", t.row(0))
        XCTAssertFalse(t.e.line(0).isWideTail(1))
    }

    func testInsertAndDeleteLinesInsideTheRegion() {
        let t = term(3, 5).feed("1\r\n2\r\n3\r\n4\r\n5" + C + "2;4r" + C + "3;2H" + C + "L")
        XCTAssertEqual(["1", "2", "", "3", "5"], t.rows())
        t.cursor(2, 0)
        t.feed(C + "2;1H" + C + "2M")
        XCTAssertEqual(["1", "3", "", "", "5"], t.rows())
        t.feed(C + "5;1H" + C + "L") // outside the region: nothing
        XCTAssertEqual(["1", "3", "", "", "5"], t.rows())
    }

    func testAlignmentTest() {
        let t = term(3, 2).feed(C + "2;2r" + C + "2;2H" + E + "#8")
        XCTAssertEqual(["EEE", "EEE"], t.rows())
        t.cursor(0, 0)
        XCTAssertEqual(1, t.e.scrollBottom())
    }
}

final class TerminalEmulatorScrollingTests: XCTestCase {

    func testHistoryIsBoundedAndKeepsTheNewestLines() {
        let t = Term(10, 2, 3)
        for i in 0..<10 {
            t.feed("l\(i)\r\n")
        }
        XCTAssertEqual(3, t.e.historySize())
        XCTAssertEqual("l6", stripTrailing(t.e.line(-3).toString()))
        XCTAssertEqual("l8", stripTrailing(t.e.line(-1).toString()))
        XCTAssertEqual("l9", t.row(0))
    }

    func testNoHistoryWhenMaxIsZero() {
        let t = Term(10, 2, 0).feed("a\r\nb\r\nc")
        XCTAssertEqual(0, t.e.historySize())
        XCTAssertEqual(["b", "c"], t.rows())
    }

    func testRegionScrollingKeepsLinesOutsideAndAddsNoHistory() {
        let t = term(3, 4).feed("A\r\nB\r\nC\r\nD" + C + "2;3r" + C + "3;1H\nx\ny")
        XCTAssertEqual(["A", "x", " y", "D"], t.rows())
        XCTAssertEqual(0, t.e.historySize())
    }

    func testTopAnchoredRegionScrollsIntoHistory() {
        // ratatui's inline viewport: region 1..n above the viewport, lines pushed into history.
        let t = term(10, 4).feed("h1\r\nh2\r\nh3\r\nview" + C + "1;3r" + C + "3;1H\nnew" + C + "r")
        XCTAssertEqual(1, t.e.historySize())
        XCTAssertEqual("h1", stripTrailing(t.e.line(-1).toString()))
        XCTAssertEqual(["h2", "h3", "new", "view"], t.rows())
    }

    func testScrollUpAndDown() {
        let t = term(3, 3).feed("1\r\n2\r\n3" + C + "S")
        XCTAssertEqual(["2", "3", ""], t.rows())
        XCTAssertEqual(1, t.e.historySize())
        t.feed(C + "2T")
        XCTAssertEqual(["", "", "2"], t.rows())
    }

    func testIndexReverseIndexAndNextLine() {
        let t = term(3, 3).feed("1\r\n2\r\n3" + C + "1;2H" + E + "M")
        XCTAssertEqual(["", "1", "2"], t.rows())
        t.feed(C + "3;2H" + E + "D")
        XCTAssertEqual(["1", "2", ""], t.rows())
        t.feed(C + "2;3H" + E + "E").cursor(2, 0)
    }

    func testScrolledInLinesTakeTheBackground() {
        XCTAssertEqual(Style.indexed(1), Style.background(term(3, 2).feed(C + "41m\r\n\r\n").style(1, 0)))
    }

    func testLineFeedModeAddsACarriageReturn() {
        term(10, 3).feed(C + "20habc\n").cursor(1, 0)
    }

    func testInvalidRegionIsIgnored() {
        let t = term(10, 6).feed(C + "2;5r" + C + "4;4r" + C + "5;2r")
        XCTAssertEqual(1, t.e.scrollTop())
        XCTAssertEqual(4, t.e.scrollBottom())
        t.feed(C + "r")
        XCTAssertEqual(5, t.e.scrollBottom())
    }
}

final class TerminalEmulatorScreenTests: XCTestCase {

    func testMode1049SavesClearsAndRestores() {
        let t = term(10, 3).feed("main" + C + "2;3H" + C + "?1049h")
        XCTAssertTrue(t.e.alternateScreen())
        XCTAssertEqual("", t.row(0))
        XCTAssertEqual(0, t.e.historySize())
        t.feed("alt\r\n\r\n\r\n\r\n" + C + "?1049l")
        XCTAssertFalse(t.e.alternateScreen())
        XCTAssertEqual("main", t.row(0))
        t.cursor(1, 2)
        XCTAssertEqual(0, t.e.historySize(), "the alternate screen has no history")
    }

    func testMode47KeepsTheAlternateContent() {
        XCTAssertEqual("one", term(10, 3).feed(C + "?47hone" + C + "?47l" + C + "?47h").row(0))
    }

    func testMode1047ClearsOnLeaving() {
        XCTAssertEqual("", term(10, 3).feed(C + "?1047hone" + C + "?1047l" + C + "?1047h").row(0))
    }

    func testMode1048SavesTheCursor() {
        term(10, 3).feed(C + "2;2H" + C + "?1048h" + C + "H" + C + "?1048l").cursor(1, 1)
    }

    func testSavedCursorPerScreen() {
        let t = term(10, 5).feed(C + "2;3H" + C + "?1049h" + C + "4;4H" + E + "7" + C + "H" + E + "8")
        t.cursor(3, 3)
        t.feed(C + "?1049l").cursor(1, 2)
        XCTAssertEqual(3, t.e.savedCursor(true)?.row)
    }

    func testFullReset() {
        let t = term(10, 3).feed(E + "]2;keep\u{7}text" + C + "1;31m" + C + "?1049h" + C + "?2004h" + C + "2;3r"
            + E + "7" + E + "c")
        XCTAssertFalse(t.e.alternateScreen())
        XCTAssertEqual("", t.row(0))
        XCTAssertEqual(Style.default, t.e.pen())
        XCTAssertFalse(t.e.bracketedPaste())
        XCTAssertEqual(2, t.e.scrollBottom())
        XCTAssertNil(t.e.savedCursor(false))
        XCTAssertEqual("keep", t.e.title())
    }

    func testSoftReset() {
        let t = term(10, 3).feed(C + "2;3H" + C + "1m" + C + "?6h" + C + "4h" + C + "?25l" + C + "!p")
        XCTAssertEqual(Style.default, t.e.pen())
        XCTAssertFalse(t.e.originMode())
        XCTAssertFalse(t.e.insertMode())
        XCTAssertTrue(t.e.cursorVisible())
    }
}

final class TerminalEmulatorSgrTests: XCTestCase {

    func testAttributesSetAndReset() {
        let t = term(20, 2).feed(C + "1;2;3;5;7;8;9;53mA" + C + "22;23;25;27;28;29;55mB" + C + "6mC" + C + "21mD"
            + C + "4:3mE" + C + "4:0mF" + C + "4mG" + C + "24mH" + C + "mI")
        let a = t.style(0, 0)
        XCTAssertTrue(Style.bold(a) && Style.dim(a) && Style.italic(a) && Style.blink(a) && Style.inverse(a)
            && Style.invisible(a) && Style.strikethrough(a) && Style.overline(a))
        XCTAssertEqual(Style.default, t.style(0, 1))
        XCTAssertTrue(Style.rapidBlink(t.style(0, 2)))
        XCTAssertEqual(Style.underlineDouble, Style.underline(t.style(0, 3)))
        XCTAssertEqual(Style.underlineCurly, Style.underline(t.style(0, 4)))
        XCTAssertEqual(Style.underlineNone, Style.underline(t.style(0, 5)))
        XCTAssertEqual(Style.underlineSingle, Style.underline(t.style(0, 6)))
        XCTAssertEqual(Style.underlineNone, Style.underline(t.style(0, 7)))
        XCTAssertEqual(Style.default, t.style(0, 8))
    }

    func testColours() {
        let t = term(20, 2).feed(C + "31;42mA" + C + "97;104mB" + C + "38;5;208;48;5;17mC"
            + C + "38;2;1;2;3;48;2;250;251;252mD" + C + "38:2::9:8:7;48:5:99mE" + C + "38:2:4:5:6mF"
            + C + "39;49mG")
        XCTAssertEqual(Style.indexed(1), Style.foreground(t.style(0, 0)))
        XCTAssertEqual(Style.indexed(2), Style.background(t.style(0, 0)))
        XCTAssertEqual(Style.indexed(15), Style.foreground(t.style(0, 1)))
        XCTAssertEqual(Style.indexed(12), Style.background(t.style(0, 1)))
        XCTAssertEqual(Style.indexed(208), Style.foreground(t.style(0, 2)))
        XCTAssertEqual(Style.indexed(17), Style.background(t.style(0, 2)))
        XCTAssertEqual(Style.rgb(1, 2, 3), Style.foreground(t.style(0, 3)))
        XCTAssertEqual(Style.rgb(250, 251, 252), Style.background(t.style(0, 3)))
        XCTAssertEqual(Style.rgb(9, 8, 7), Style.foreground(t.style(0, 4)))
        XCTAssertEqual(Style.indexed(99), Style.background(t.style(0, 4)))
        XCTAssertEqual(Style.rgb(4, 5, 6), Style.foreground(t.style(0, 5)))
        XCTAssertEqual(Style.default, t.style(0, 6))
    }

    func testAShortColonColourGroupDoesNotReadPastItself() {
        let t = term(20, 2).feed(C + "38:2:1:2;3mA")
        XCTAssertEqual(Style.colorDefault, Style.foreground(t.style(0, 0)))
        XCTAssertTrue(Style.italic(t.style(0, 0)))
        t.feed(C + String(repeating: ";", count: 28) + "38:2:1:2mB")
        XCTAssertEqual(Style.default, t.style(0, 1))
        XCTAssertEqual("AB", t.row(0))
    }

    func testUnderlineColourIsParsedAndIgnored() {
        let t = term(20, 2).feed(C + "58;2;1;2;3;1mA" + C + "0;58:5:9;3mB")
        XCTAssertEqual(Style.with(Style.default, Style.BOLD, true), t.style(0, 0))
        XCTAssertEqual(Style.with(Style.default, Style.ITALIC, true), t.style(0, 1))
    }

    func testInvalidColoursLeaveThePenAlone() {
        let t = term(20, 2).feed(C + "31m" + C + "38;5;300mA" + C + "38;2;1;2;999mB" + C + "38;7mC")
        for x in 0..<3 {
            XCTAssertEqual(Style.indexed(1), Style.foreground(t.style(0, x)))
        }
    }

    func testStyleColourHelpers() {
        XCTAssertTrue(Style.isIndexed(Style.indexed(0)))
        XCTAssertEqual(0, Style.index(Style.indexed(0)))
        XCTAssertTrue(Style.isRgb(Style.rgb(0, 0, 0)))
        XCTAssertEqual(0x010203, Style.rgbValue(Style.rgb(1, 2, 3)))
        XCTAssertFalse(Style.isIndexed(Style.colorDefault) || Style.isRgb(Style.colorDefault))
        XCTAssertEqual(0x000000, Style.xterm256Rgb(16))
        XCTAssertEqual(0xff8700, Style.xterm256Rgb(208))
        XCTAssertEqual(0x080808, Style.xterm256Rgb(232))
        XCTAssertEqual(0xeeeeee, Style.xterm256Rgb(255))
        XCTAssertEqual(-1, Style.xterm256Rgb(7))
    }
}

final class TerminalEmulatorModeTests: XCTestCase {

    func testPrivateModes() {
        let t = term(10, 2).feed(C + "?1;5;12;25l" + C + "?1;5;12;2004;1004;2026h" + C + "?25l" + E + "=")
        let e = t.e
        XCTAssertTrue(e.applicationCursorKeys() && e.reverseVideo() && e.cursorBlink() && e.bracketedPaste()
            && e.focusReporting() && e.synchronizedOutput() && e.applicationKeypad())
        XCTAssertFalse(e.cursorVisible())
        t.feed(C + "?1;5;12;2004;1004;2026l" + C + "?25h" + E + ">")
        XCTAssertFalse(e.applicationCursorKeys() || e.reverseVideo() || e.cursorBlink() || e.bracketedPaste()
            || e.focusReporting() || e.synchronizedOutput() || e.applicationKeypad())
        XCTAssertTrue(e.cursorVisible())
    }

    func testMouseModes() {
        let t = term(10, 2).feed(C + "?1000h")
        XCTAssertEqual(.normal, t.e.mouseTracking())
        t.feed(C + "?1002h")
        XCTAssertEqual(.buttonMotion, t.e.mouseTracking())
        t.feed(C + "?1003h" + C + "?1006h")
        XCTAssertEqual(.anyMotion, t.e.mouseTracking())
        XCTAssertEqual(.sgr, t.e.mouseEncoding())
        t.feed(C + "?1015h")
        XCTAssertEqual(.urxvt, t.e.mouseEncoding())
        t.feed(C + "?1005h" + C + "?9h")
        XCTAssertEqual(.utf8, t.e.mouseEncoding())
        XCTAssertEqual(.x10, t.e.mouseTracking())
        t.feed(C + "?1005l" + C + "?1000l")
        XCTAssertEqual(.default, t.e.mouseEncoding())
        XCTAssertEqual(TerminalEmulator.MouseTracking.none, t.e.mouseTracking())
    }

    func testCursorShape() {
        let t = term(10, 2)
        XCTAssertEqual(0, t.e.cursorShape())
        t.feed(C + "4 q")
        XCTAssertEqual(4, t.e.cursorShape())
        t.feed(C + " q")
        XCTAssertEqual(1, t.e.cursorShape())
        t.feed(C + "9 q")
        XCTAssertEqual(1, t.e.cursorShape())
    }

    func testKittyKeyboardFlags() {
        let t = term(10, 2).feed(C + ">1u" + C + ">3u")
        XCTAssertEqual(3, t.e.kittyKeyboardFlags())
        t.feed(C + "=4;2u")
        XCTAssertEqual(7, t.e.kittyKeyboardFlags())
        t.feed(C + "=2;3u")
        XCTAssertEqual(5, t.e.kittyKeyboardFlags())
        t.feed(C + "?u")
        XCTAssertEqual(C + "?5u", t.replies.last)
        t.feed(C + "<u")
        XCTAssertEqual(1, t.e.kittyKeyboardFlags())
        t.feed(C + "<9u")
        XCTAssertEqual(0, t.e.kittyKeyboardFlags())
    }

    func testTitlesAndTheTitleStack() {
        let t = term(10, 2).feed(E + "]0;one\u{7}")
        XCTAssertEqual("one", t.e.title())
        t.feed(E + "]2;two" + E + "\\")
        XCTAssertEqual("two", t.e.title())
        t.feed(E + "]1;icon\u{7}")
        XCTAssertEqual("icon", t.e.title())
        t.feed(C + "22;0t" + E + "]2;pushed\u{7}" + C + "23;0t")
        XCTAssertEqual("icon", t.e.title())
        t.feed(E + "]2;t\u{e9}l\u{e9}\u{7}")
        XCTAssertEqual("t\u{e9}l\u{e9}", t.e.title())
        t.feed(E + "]7;file://h/tmp\u{7}" + E + "]x;y\u{7}" + E + "]2\u{7}")
        XCTAssertEqual("t\u{e9}l\u{e9}", t.e.title())
    }

    func testWindowResizeRequestsAreIgnored() {
        let t = term(10, 2).feed(C + "8;40;120t")
        XCTAssertEqual(10, t.e.columns())
        XCTAssertEqual(2, t.e.rows())
    }

    func testSynchronizedOutputIsTracked() {
        let t = term(10, 2).feed(C + "?2026h")
        XCTAssertTrue(t.e.synchronizedOutput())
        t.feed(C + "?2026$p")
        XCTAssertEqual(C + "?2026;1$y", t.replies.last)
        t.feed(C + "?2026l")
        XCTAssertFalse(t.e.synchronizedOutput())
    }
}

final class TerminalEmulatorOverlongStringTests: XCTestCase {

    private func stream(_ terminator: String) -> String {
        return "A" + E + "Pq" + String(repeating: "~", count: 70_000) + terminator + "B" + E + "]0;"
            + String(repeating: "t", count: 70_000) + "\u{7}C"
    }

    func testAStringOverTheCapPrintsNothing() {
        let t = term(80, 24).feed(stream(E + "\\"))
        XCTAssertEqual("ABC", t.row(0))
        XCTAssertEqual("", t.row(1))
        XCTAssertEqual(0, t.e.historySize())
        XCTAssertEqual("", t.e.title())
    }

    func testTheScreenDoesNotDependOnChunking() {
        let data = bytes(stream("\u{7}"))
        for chunk in [1, 4096, 65_536] {
            let t = term(80, 24)
            var off = 0
            while off < data.count {
                t.e.feed(data, off, min(chunk, data.count - off))
                off += chunk
            }
            XCTAssertEqual("ABC", t.row(0), "chunk \(chunk)")
            XCTAssertEqual(0, t.e.historySize(), "chunk \(chunk)")
        }
    }

    func testTokensFromTheDaemonGiveTheSameScreen() {
        let data = bytes(stream(E + "\\"))
        let tokenizer = VtTokenizer()
        let daemon = term(80, 24)
        let client = term(80, 24)
        var off = 0
        while off < data.count {
            let batch = tokenizer.feed(data, off, min(5000, data.count - off))
            daemon.e.apply(batch.tokens)
            for token in batch.tokens {
                client.e.feed(token.bytesToForward())
            }
            client.e.feed(batch.openStringFragment)
            off += 5000
        }
        XCTAssertEqual("ABC", daemon.row(0))
        XCTAssertEqual("ABC", client.row(0))
    }
}

final class TerminalEmulatorReplyTests: XCTestCase {

    func testBasicScopeAnswersWhatQueryFilterStrips() {
        var replies: [String] = []
        let e = TerminalEmulator(10, 3, 0)
        e.setReplies({ replies.append(String(decoding: $0, as: UTF8.self)) }, .basic)
        let queries = [C + "c", C + "0c", C + "0;1c", C + "=c", C + "?6c", C + "?c", C + "1c", C + "0 c",
                       C + "4294967296c", C + ">c", C + ">0c", C + "5n", C + "6n",
                       C + ">1c", C + "?6n", C + "?996n", C + "?1$p", C + "4$p", C + ">q", C + "?u", E + "]11;?\u{7}",
                       E + "P+q544e" + E + "\\"]
        for q in queries {
            replies.removeAll()
            e.feed(bytes(q))
            let token = VtTokenizer().feed(bytes(q)).tokens.first!
            let stripped = QueryFilter.isServerAnswered(token)
            let xtgettcap = q.hasPrefix(E + "P")
            XCTAssertEqual(stripped || xtgettcap, !replies.isEmpty, visible(q))
        }
    }

    func testDeviceAttributesAndStatus() {
        let t = term(10, 3).feed(C + "c" + C + ">c" + C + "5n" + C + "2;4H" + C + "6n" + C + "?6n")
        XCTAssertEqual([C + "?62;22c", C + ">0;10;0c", C + "0n", C + "2;4R", C + "?2;4;1R"], t.replies)
    }

    func testOnlyPlainDa1IsAnswered() {
        XCTAssertTrue(term(10, 3).feed(C + "?6c" + C + "?c" + C + "=c" + C + "1c" + C + "0 c").replies.isEmpty)
        XCTAssertEqual([C + "?62;22c", C + "?62;22c"], term(10, 3).feed(C + "c" + C + "0c").replies)
    }

    func testCursorReportAtAPendingWrapUsesTheLastColumn() {
        XCTAssertEqual(C + "1;5R", term(5, 3).feed("abcde" + C + "6n").replies.last)
    }

    func testDecrqmAndXtversion() {
        let t = term(10, 3).feed(C + "?2004h" + C + "?2004$p" + C + "?1$p" + C + "?9999$p" + C + "4$p" + C + ">q")
        XCTAssertEqual([C + "?2004;1$y", C + "?1;2$y", C + "?9999;0$y", C + "4;2$y", E + "P>|microhm-vt" + E + "\\"],
                       t.replies)
    }

    func testColourSchemeQueryIsNotAnswered() {
        XCTAssertTrue(term(10, 3).feed(C + "?996n").replies.isEmpty)
    }

    func testColourSchemeQueryIsAnsweredOnceASchemeIsSet() {
        let t = term(10, 3)
        t.e.setColorScheme(.dark)
        t.feed(C + "?996n")
        t.e.setColorScheme(.light)
        t.feed(C + "?996n")
        XCTAssertEqual([C + "?997;1n", C + "?997;2n"], t.replies)
        t.e.setColorScheme(nil)
        t.feed(C + "?996n")
        XCTAssertEqual(2, t.replies.count)
    }

    func testClientScopeAnswersOnlyTheColourScheme() {
        var replies: [String] = []
        let e = TerminalEmulator(10, 3, 0)
        e.setReplies({ replies.append(String(decoding: $0, as: UTF8.self)) }, .client)
        e.setColorScheme(.light)
        let all = C + "c" + C + ">c" + C + "5n" + C + "6n" + C + "?6n" + C + "?1$p" + C + ">q" + C + "?u"
            + E + "P+q544e" + E + "\\" + C + "?996n"
        e.feed(bytes(all))
        XCTAssertEqual([C + "?997;2n"], replies)
    }

    func testSchemeChangesAreReportedWhileMode2031IsOn() {
        let t = term(10, 3)
        t.e.setColorScheme(.dark)
        t.e.setColorScheme(.light) // 2031 off: silent
        XCTAssertTrue(t.replies.isEmpty)
        t.feed(C + "?2031h")
        XCTAssertTrue(t.e.colorSchemeUpdates())
        t.e.setColorScheme(.light) // unchanged: silent
        t.e.setColorScheme(.dark)
        XCTAssertEqual([C + "?997;1n"], t.replies)
        t.feed(C + "?2031l")
        t.e.setColorScheme(.light)
        XCTAssertEqual(1, t.replies.count)
    }

    func testHistoryLinesAddedKeepsCountingOnceTheHistoryIsFull() {
        let e = TerminalEmulator(5, 2, 3)
        e.feed(bytes("1\r\n2\r\n3\r\n4\r\n5\r\n6"))
        XCTAssertEqual(3, e.historySize())
        XCTAssertEqual(4, e.historyLinesAdded())
        e.feed(bytes(C + "3J"))
        XCTAssertEqual(0, e.historySize())
        XCTAssertEqual(4, e.historyLinesAdded())
        let alt = TerminalEmulator(5, 2, 3)
        alt.feed(bytes(C + "?1049h" + "1\r\n2\r\n3"))
        XCTAssertEqual(0, alt.historyLinesAdded())
    }

    func testNoSinkNoReplies() {
        let e = TerminalEmulator(10, 3, 0)
        e.feed(bytes(C + "c" + C + "6n"))
        XCTAssertEqual(0, e.cursorRow())
    }
}

final class TerminalEmulatorResizeTests: XCTestCase {

    func testShrinkingRowsPushesTopLinesIntoHistoryToKeepTheCursor() {
        let t = term(10, 5).feed("1\r\n2\r\n3\r\n4\r\n5")
        t.e.resize(10, 3)
        XCTAssertEqual(["3", "4", "5"], t.rows())
        XCTAssertEqual(2, t.e.historySize())
        t.cursor(2, 1)
    }

    func testShrinkingRowsDropsBlankRowsBelowTheCursorFirst() {
        let t = term(10, 5).feed("1\r\n2")
        t.e.resize(10, 3)
        XCTAssertEqual(["1", "2", ""], t.rows())
        XCTAssertEqual(0, t.e.historySize())
    }

    func testGrowingRowsAddsBlankRowsAndColumnsTruncateAndPad() {
        let t = term(6, 2).feed("abcdef\r\nxy")
        t.e.resize(4, 4)
        XCTAssertEqual(["abcd", "xy", "", ""], t.rows())
        t.e.resize(8, 4)
        XCTAssertEqual("abcd", t.row(0))
        XCTAssertEqual(8, t.e.line(0).columns())
        t.feed(C + "1;8Hz")
        XCTAssertEqual("abcd   z", t.row(0))
    }

    func testResizeResetsTheRegionAndClampsTheCursor() {
        let t = term(10, 10).feed(C + "2;8r" + C + "9;10H")
        t.e.resize(5, 10)
        XCTAssertEqual(0, t.e.scrollTop())
        XCTAssertEqual(9, t.e.scrollBottom())
        t.cursor(8, 4)
        XCTAssertFalse(t.e.cursorPendingWrap())
    }

    func testBothScreensResize() {
        let t = term(10, 4).feed("main\r\n\r\n\r\nlast" + C + "?1049h" + C + "Halt")
        t.e.resize(6, 2)
        XCTAssertEqual("alt", t.row(0), "blank alternate rows below the cursor go first")
        t.feed(C + "?1049l")
        XCTAssertEqual(6, t.e.line(0).columns())
        XCTAssertEqual("last", t.row(1), "the main screen kept the row of its saved cursor")
        t.cursor(1, 4)
        XCTAssertEqual(2, t.e.historySize())
    }

    func testWideCharacterCutByTheNewWidthIsBlanked() {
        let t = term(6, 2).feed("abcd\u{4e2d}")
        t.e.resize(5, 2)
        XCTAssertEqual("abcd", t.row(0))
        XCTAssertFalse(t.e.line(0).isWideTail(4))
    }

    func testHistoryLinesKeepTheirWidth() {
        let t = term(6, 2).feed("abcdef\r\n\r\n\r\n")
        t.e.resize(3, 2)
        XCTAssertEqual("abcdef", t.e.line(-2).toString())
        XCTAssertEqual(6, t.e.line(-2).columns())
    }
}

final class TerminalEmulatorNotificationTests: XCTestCase {

    final class Recorder: TerminalListener {
        var events: [String] = []
        weak var emulator: TerminalEmulator?
        var calledUnderLock = false

        func contentChanged() {
            if let e = emulator, heldByCurrentThread(e.lock()) {
                calledUnderLock = true
            }
            events.append("changed")
        }

        func bell(_ count: Int) {
            events.append("bell \(count)")
        }

        func titleChanged(_ title: String) {
            events.append("title \(title)")
        }
    }

    func testListenerGetsChangesBellsAndTitles() {
        let e = TerminalEmulator(10, 2, 0)
        let r = Recorder()
        r.emulator = e
        e.setListener(r)
        let before = e.changeCount()
        e.feed(bytes("a\u{7}\u{7}" + E + "]2;t\u{7}"))
        XCTAssertEqual(["title t", "bell 2", "changed"], r.events)
        XCTAssertFalse(r.calledUnderLock, "called outside the lock")
        XCTAssertTrue(e.changeCount() > before)
        e.resize(12, 3)
        XCTAssertEqual("changed", r.events.last)
    }

    func testRepliesAreSentOutsideTheLock() {
        let e = TerminalEmulator(10, 2, 0)
        var held: [Bool] = []
        e.setReplies({ _ in held.append(heldByCurrentThread(e.lock())) }, .basic)
        e.feed(bytes(C + "c"))
        XCTAssertEqual([false], held)
    }
}

final class TerminalEmulatorLineVersionTests: XCTestCase {

    /** Each sequence must change the version of the line at row 0 (cursor at 0,2). */
    func testEveryRowMutationBumpsTheVersion() {
        let mutations = ["x", "\u{e9}", "\u{4e2d}", "e\u{301}", C + "K", C + "1K", C + "2K", C + "@",
                         C + "P", C + "X", C + "4hz", C + "J", C + "1J", C + "2J", E + "#8"]
        for m in mutations {
            let t = term(6, 3).feed("abcdef" + C + "1;3H")
            let line = t.e.line(0)
            let before = line.version()
            t.feed(m)
            let after = t.e.line(0)
            XCTAssertTrue(after !== line || line.version() != before, visible(m))
        }
    }

    func testSoftWrapAndUntouchedRows() {
        let t = term(4, 3).feed("ab")
        let row1 = t.e.line(1)
        let v1 = row1.version()
        let row0 = t.e.line(0)
        var v0 = row0.version()
        t.feed("cd")
        XCTAssertNotEqual(v0, row0.version())
        XCTAssertEqual(v1, row1.version(), "a row nothing wrote to keeps its version")
        v0 = row0.version()
        t.feed("e") // the deferred wrap marks row 0 wrapped
        XCTAssertTrue(row0.isWrapped())
        XCTAssertNotEqual(v0, row0.version())
    }

    func testScrollRecyclesALineWithANewVersion() {
        let t = Term(4, 2, 0).feed("ab\r\ncd")
        let top = t.e.line(0)
        let v = top.version()
        t.feed("\r\n") // row 0 is recycled as the new, cleared bottom row
        XCTAssertTrue(t.e.line(1) !== top || top.version() != v)
    }
}
