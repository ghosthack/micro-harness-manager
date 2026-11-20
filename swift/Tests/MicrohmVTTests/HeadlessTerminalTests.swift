import Foundation
import XCTest
@testable import MicrohmVT

final class HeadlessTerminalTests: XCTestCase {

    private func tokens(_ s: String) -> [VtToken] {
        return VtTokenizer().feed(bytes(s)).tokens.map { SgrNormalizer.normalize($0) }
    }

    func testRepliesGoToTheSessionAndTheColourSchemeQueryIsDropped() {
        let box = Subject.ReplyBox()
        let term = HeadlessTerminal(20, 5, 0) { box.replies.append(String(decoding: $0, as: UTF8.self)) }
        term.apply(tokens("\u{1b}[c\u{1b}[?996n\u{1b}[2;3H\u{1b}[6n\u{1b}[8;50;200t"))
        XCTAssertEqual(["\u{1b}[?62;22c", "\u{1b}[2;3R"], box.replies)
        XCTAssertEqual(20, term.columns())
        XCTAssertEqual(5, term.rows())
    }

    func testStoredCursorAndCwd() {
        let term = HeadlessTerminal(20, 5, 0) { _ in }
        XCTAssertNil(term.storedCursor())
        term.apply(tokens("\u{1b}[3;4H\u{1b}[1m\u{1b}7\u{1b}]7;file://host/tmp/a%20b\u{7}"))
        let stored = term.storedCursor()!
        XCTAssertEqual(3, stored.cursorX)
        XCTAssertEqual(2, stored.cursorY)
        XCTAssertTrue(Style.bold(stored.style))
        XCTAssertEqual("/tmp/a b", term.reportedCwd())
        term.apply(tokens("\u{1b}]9;9;/srv/x\u{1b}\\"))
        XCTAssertEqual("/srv/x", term.reportedCwd())
    }

    func testHistoryIsTheScrollbackAboveTheMainScreenOldestFirst() {
        let term = HeadlessTerminal(20, 3, 100) { _ in }
        XCTAssertEqual(HeadlessTerminal.History(text: "", held: 0, added: 0, alternateScreen: false), term.history(10))
        term.apply(tokens("l1   \r\nl2\r\nl3\r\nl4\r\nl5\r\nl6"))
        XCTAssertEqual(HeadlessTerminal.History(text: "l1\nl2\nl3\n", held: 3, added: 3, alternateScreen: false), term.history(10))
        XCTAssertEqual("l2\nl3\n", term.history(2).text)
        XCTAssertEqual("", term.history(0).text)
        XCTAssertEqual("", term.history(-1).text)
        XCTAssertEqual("l4\nl5\nl6\n", term.screenText())
        term.apply(tokens("\u{1b}[?1049hfull\r\n\r\n\r\n\r\n"))
        XCTAssertEqual(HeadlessTerminal.History(text: "l1\nl2\nl3\n", held: 3, added: 3, alternateScreen: true), term.history(10))
        term.apply(tokens("\u{1b}[?1049l"))
        XCTAssertEqual("l1\nl2\nl3\n", term.history(10).text)
    }

    func testHistorySinceGivesEachLineOnceAndSaysWhenOldOnesFellOut() {
        let term = HeadlessTerminal(20, 2, 3) { _ in }
        term.apply(tokens("a\r\nb\r\nc"))
        let first = term.historySince(0)
        XCTAssertEqual("a\n", first.text)
        XCTAssertEqual(1, first.added)
        XCTAssertEqual("", term.historySince(first.added).text, "nothing new")
        term.apply(tokens("\r\nd\r\ne"))
        let next = term.historySince(first.added)
        XCTAssertEqual("b\nc\n", next.text)
        XCTAssertEqual(3, next.added)
        term.apply(tokens("\r\nf\r\ng\r\nh\r\ni\r\nj"))
        let later = term.historySince(next.added)
        XCTAssertEqual(8, later.added, "five more scrolled off")
        XCTAssertEqual("f\ng\nh\n", later.text, "only the three the history still holds")
        XCTAssertEqual("f\ng\nh\n", term.historySince(99).text)
    }

    func testClosedTerminalIgnoresInput() {
        let term = HeadlessTerminal(20, 5, 0) { _ in }
        term.close()
        term.close()
        term.apply(tokens("text"))
        term.resize(30, 6)
        XCTAssertEqual("\n\n\n\n\n", term.screenText())
        XCTAssertEqual(20, term.columns())
    }

    func testModesAndTheirJavaToString() {
        let term = HeadlessTerminal(20, 5, 0) { _ in }
        term.apply(tokens("\u{1b}[?1002h\u{1b}[?1006h\u{1b}[2;4r\u{1b}]2;hi\u{7}"))
        XCTAssertEqual("Modes[cursorVisible=true, cursorShape=0, bracketedPaste=false, applicationCursorKeys=false, "
                       + "applicationKeypad=false, mouseTrackingMode=1002, mouseSgr=true, focusReporting=false, "
                       + "alternateScreen=false, autoWrap=true, originMode=false, scrollTop=2, scrollBottom=4, title=hi]",
                       term.modes().description)
    }

    func testGettersAreSafeWhileThePumpApplies() {
        let term = HeadlessTerminal(40, 10, 100) { _ in }
        let done = DispatchSemaphore(value: 0)
        var failures = 0
        let reader = Thread {
            for _ in 0..<2000 {
                if !term.screenText().hasSuffix("\n") {
                    failures += 1
                }
                _ = term.annotatedText()
                _ = term.modes()
                _ = term.serialize(10)
            }
            done.signal()
        }
        reader.start()
        for i in 0..<2000 {
            term.apply(tokens("\u{1b}[3\(i % 8)mline \(i) \u{4e2d}\u{6587}\r\n"))
            if i % 500 == 0 {
                term.resize(30 + i % 20, 8 + i % 5)
            }
        }
        done.wait()
        XCTAssertEqual(0, failures)
    }
}

/** `HeadlessTerminal.annotatedText()` through the real pipeline (`VtPipe`). */
final class AnnotatedTextTests: XCTestCase {

    private let HIDE_CURSOR = "\u{1b}[?25l"

    private func rows(_ pipe: VtPipe) -> [String] {
        let text = pipe.terminal.annotatedText()
        XCTAssertTrue(text.hasSuffix("\n"))
        return ModeTracker.split(String(text.dropLast()), "\n")
    }

    func testPlainScreenMatchesScreenTextWhenTheCursorIsHidden() {
        let pipe = VtPipe(20, 4, 0)
        pipe.feed("one\r\ntwo  \r\n" + HIDE_CURSOR)
        XCTAssertEqual(pipe.terminal.screenText(), pipe.terminal.annotatedText())
        XCTAssertEqual("one\ntwo\n\n\n", pipe.terminal.annotatedText())
    }

    func testReverseVideoRowIsMarked() {
        let pipe = VtPipe(20, 6, 0)
        pipe.feed("  apple\r\n\u{1b}[7m  banana\u{1b}[0m\r\n  cherry\r\n  damson\r\n" + HIDE_CURSOR)
        XCTAssertEqual(["  apple", "▶   banana", "  cherry", "  damson", "", ""], rows(pipe))
    }

    func testBackgroundColouredRowIsMarked() {
        let pipe = VtPipe(20, 6, 0)
        pipe.feed("  apple\r\n\u{1b}[44m  banana        \u{1b}[0m\r\n  cherry\r\n  damson\r\n" + HIDE_CURSOR)
        XCTAssertEqual(["  apple", "▶   banana", "  cherry", "  damson", "", ""], rows(pipe))
    }

    func testFullScreenColourThemeHasNoSelection() {
        let pipe = VtPipe(10, 4, 0)
        pipe.feed("\u{1b}[44m\u{1b}[2J\u{1b}[Hab\r\n\u{1b}[42mcd\u{1b}[44m\r\nef\r\ngh" + HIDE_CURSOR)
        XCTAssertEqual(["ab", "▶ cd", "ef", "gh"], rows(pipe))
        let themed = VtPipe(10, 4, 0)
        themed.feed("\u{1b}[44m\u{1b}[2J\u{1b}[Hab\r\n\u{1b}[42mcd\r\nef\u{1b}[44m\r\ngh" + HIDE_CURSOR)
        XCTAssertEqual(["ab", "cd", "ef", "gh"], rows(themed))
        let allInverse = VtPipe(10, 3, 0)
        allInverse.feed("\u{1b}[7mab\r\ncd\r\nef" + HIDE_CURSOR)
        XCTAssertFalse(allInverse.terminal.annotatedText().contains("▶"))
    }

    func testCursorInTheMiddleOfText() {
        let pipe = VtPipe(20, 3, 0)
        pipe.feed("hello world\u{1b}[1;6H")
        XCTAssertEqual("hello▮ world", rows(pipe)[0])
    }

    func testCursorAfterTextAndPastTrailingSpace() {
        let pipe = VtPipe(20, 3, 0)
        pipe.feed("$ ")
        XCTAssertEqual("$ ▮", rows(pipe)[0], "trailing whitespace before the cursor is kept")
        pipe.feed("\r\nab\u{1b}[2;8H")
        XCTAssertEqual(["$", "ab     ▮", ""], rows(pipe), "padded out to the cursor column")
    }

    func testCursorAtPendingWrapSitsOnTheLastColumn() {
        let pipe = VtPipe(5, 3, 0)
        pipe.feed("abcde")
        XCTAssertEqual("abcd▮e", rows(pipe)[0])
    }

    func testHiddenCursorIsNotMarked() {
        let pipe = VtPipe(20, 3, 0)
        pipe.feed("text" + HIDE_CURSOR)
        XCTAssertFalse(pipe.terminal.annotatedText().contains("▮"))
        pipe.feed("\u{1b}[?25h")
        XCTAssertEqual("text▮", rows(pipe)[0])
    }

    func testWideCharactersMapBufferColumnsToTextIndices() {
        let pipe = VtPipe(20, 3, 0)
        pipe.feed("中文x")
        XCTAssertEqual("中文x▮", rows(pipe)[0])
        pipe.feed("\u{1b}[1;5H")
        XCTAssertEqual("中文▮x", rows(pipe)[0])
        XCTAssertEqual(pipe.terminal.screenText().replacingOccurrences(of: "▮", with: ""),
                       pipe.terminal.annotatedText().replacingOccurrences(of: "▮", with: ""))
    }

    func testSupplementaryAndCombiningCharactersCountAsUtf16() {
        let pipe = VtPipe(20, 3, 0)
        pipe.feed("🚀e\u{301}x\u{1b}[1;4H")
        XCTAssertScalars("🚀e\u{301}▮x", rows(pipe)[0])
    }

    func testMarkerAndSelectionTogether() {
        let pipe = VtPipe(20, 6, 0)
        pipe.feed("a\r\n\u{1b}[7m> b\u{1b}[0m\r\nc\r\nd\u{1b}[2;2H")
        XCTAssertEqual("▶ >▮ b", rows(pipe)[1])
    }
}
