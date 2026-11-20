import XCTest
import MicrohmVT
@testable import MicrohmTerminal

func term(_ columns: Int, _ rows: Int, _ content: String) -> TerminalEmulator {
    let e = TerminalEmulator(columns, rows, 100)
    e.feed(Array(content.utf8))
    return e
}

final class SelectionTextTests: XCTestCase {

    func testTrimsTrailingBlanksOfHardLines() {
        let e = term(10, 3, "ab   \r\ncd\r\nef")
        XCTAssertEqual(SelectionText.extract(e, 0, 0, 2, 10), "ab\ncd\nef")
    }

    func testPartialFirstAndLastLines() {
        let e = term(10, 3, "hello\r\nworld")
        XCTAssertEqual(SelectionText.extract(e, 0, 2, 1, 3), "llo\nwor")
        XCTAssertEqual(SelectionText.extract(e, 0, 1, 0, 4), "ell")
    }

    func testSoftWrapsJoinWithoutANewline() {
        let e = term(5, 3, "abcdefgh\r\nz")
        XCTAssertEqual(SelectionText.extract(e, 0, 0, 2, 5), "abcdefgh\nz")
    }

    func testInteriorEmptyCellsAreSpaces() {
        let e = term(10, 2, "a\u{1b}[5Gb")
        XCTAssertEqual(SelectionText.extract(e, 0, 0, 0, 10), "a   b")
    }

    func testWideCharactersAreCopiedOnce() {
        let e = term(10, 2, "x中文y")
        XCTAssertEqual(SelectionText.extract(e, 0, 0, 0, 10), "x中文y")
        // starting on the tail of 中 takes the whole character
        XCTAssertEqual(SelectionText.extract(e, 0, 2, 0, 5), "中文")
    }

    func testWideCharacterThatDidNotFitLeavesNoGapAcrossTheWrap() {
        let e = term(4, 3, "abc中")
        XCTAssertEqual(SelectionText.extract(e, 0, 0, 1, 4), "abc中")
    }

    func testCombiningMarksStayWithTheirCell() {
        let e = term(10, 2, "e\u{301}a\u{308}!")
        XCTAssertEqual(SelectionText.extract(e, 0, 0, 0, 10), "e\u{301}a\u{308}!")
        XCTAssertEqual(SelectionText.extract(e, 0, 1, 0, 2), "a\u{308}")
    }

    func testReachesIntoHistory() {
        var s = ""
        for i in 0..<6 {
            s += "line\(i)\r\n"
        }
        let e = term(10, 3, s)
        XCTAssertEqual(e.historySize(), 4)
        XCTAssertEqual(SelectionText.extract(e, -2, 0, 0, 10), "line2\nline3\nline4")
        // a start older than the history is clamped to its first line
        XCTAssertEqual(SelectionText.extract(e, -10, 0, -3, 10), "line0\nline1")
    }

    func testWordBoundaries() {
        let e = term(40, 2, "cat /usr/local/bin  foo(bar) x中文y")
        XCTAssertTrue(SelectionText.word(e.line(0), 8) == (4, 18))
        XCTAssertTrue(SelectionText.word(e.line(0), 18) == (18, 20)) // the blank run
        XCTAssertTrue(SelectionText.word(e.line(0), 21) == (20, 23))
        XCTAssertTrue(SelectionText.word(e.line(0), 23) == (23, 24)) // '(' alone
        XCTAssertTrue(SelectionText.word(e.line(0), 31) == (29, 35)) // wide chars, from a tail
    }

    func testLogicalLineSpansSoftWraps() {
        let e = term(5, 5, "ab\r\nabcdefghijk\r\nz")
        XCTAssertTrue(SelectionText.logicalLine(e, 2) == (1, 3))
        XCTAssertTrue(SelectionText.logicalLine(e, 0) == (0, 0))
    }
}
