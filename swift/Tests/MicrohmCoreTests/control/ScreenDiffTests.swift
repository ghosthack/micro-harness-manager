import XCTest
@testable import MicrohmCore

/// The read tool's text helpers.
final class ScreenDiffTests: XCTestCase {

    func testPlainDropsMarkersAndTheCursorPadding() {
        XCTAssertEqual("  1. Yes\n  2. No\n> hi\n", ScreenDiff.plain("▶   1. Yes\n  2. No\n> hi   ▮\n"))
    }

    func testBodyLinesTrimsOnlyTrailingBlankRows() {
        XCTAssertEqual(["", "a", "", "b"], ScreenDiff.bodyLines("\na\n\nb\n\n  \n▮\n"))
    }

    func testScrolledOutputYieldsTheLinesBelowTheOverlapIncludingAChangedFooter() throws {
        let before = ["a", "b", "c", "d", "e", "f", "g", "h", "› ", "ctx 50% left"]
        let after = ["c", "d", "e", "f", "g", "h", "i", "j", "› ▮", "ctx 48% left"]
        let delta = try XCTUnwrap(ScreenDiff.newLines(before, after))
        XCTAssertEqual(6, delta.unchangedAbove)
        XCTAssertEqual(["i", "j", "› ▮", "ctx 48% left"], delta.lines)
    }

    func testAChangeBelowTheOverlapIsKept() {
        XCTAssertEqual(ScreenDiff.Delta(unchangedAbove: 3, lines: ["X", "e"]),
                       ScreenDiff.newLines(["a", "b", "c", "d", "e"], ["a", "b", "c", "X", "e"]))
    }

    func testWholeScreenWhenTheOverlapIsTooShortOrTheChangeTooBig() {
        // a changed first line: no leading overlap at all
        XCTAssertNil(ScreenDiff.newLines(["t1", "a", "b", "c"], ["t2", "a", "b", "c"]))
        // two lines of overlap are not enough
        XCTAssertNil(ScreenDiff.newLines(["a", "b", "c"], ["b", "c", "d", "e"]))
        // blank rows do not count toward the overlap
        XCTAssertNil(ScreenDiff.newLines(["", "", "", "a", "b"], ["", "", "", "a", "X"]))
        // more than 60% new
        XCTAssertNil(ScreenDiff.newLines(["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"],
                                         ["1", "2", "3", "x", "x", "x", "x", "x", "x", "x"]))
        // nothing after the overlap: lines vanished, show it all
        XCTAssertNil(ScreenDiff.newLines(["a", "b", "c", "d"], ["a", "b", "c"]))
    }

    func testCapKeepsTheTailAndCountsWhatWasDropped() {
        let lines = (0..<100).map { "row \($0) " + String(repeating: "-", count: 90) }
        let capped = ScreenDiff.cap(lines, 1000)
        XCTAssertLessThanOrEqual(capped.utf16.count, 1000)
        let cappedLines = capped.components(separatedBy: "\n")
        let kept = cappedLines.count - 1
        XCTAssertEqual("… (\(100 - kept) earlier lines omitted)", cappedLines[0])
        XCTAssertTrue(capped.hasSuffix(lines.last!))
        XCTAssertEqual("short", ScreenDiff.cap(["short"], 1000))
        let oneHuge = ScreenDiff.cap([String(repeating: "y", count: 5000)], 1000)
        XCTAssertLessThanOrEqual(oneHuge.utf16.count, 1000)
    }
}
