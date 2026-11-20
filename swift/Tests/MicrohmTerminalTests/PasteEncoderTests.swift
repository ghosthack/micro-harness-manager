import XCTest
@testable import MicrohmTerminal

final class PasteEncoderTests: XCTestCase {

    private func paste(_ text: String, _ bracketed: Bool) -> String {
        return String(decoding: PasteEncoder.encode(text, bracketed: bracketed), as: UTF8.self)
    }

    private func same(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        // compared as scalars: "\r\n" is one Character to Swift
        XCTAssertEqual(Array(a.unicodeScalars), Array(b.unicodeScalars), file: file, line: line)
    }

    func testLineBreaksBecomeCarriageReturns() {
        same(paste("a\r\nb\nc\r", false), "a\rb\rc\r")
        same(paste("a\n\nb", false), "a\r\rb")
    }

    func testUnbracketedKeepsTextAsIs() {
        same(paste("x\u{1b}[201~y", false), "x\u{1b}[201~y")
        same(paste("héllo ✓", false), "héllo ✓")
    }

    func testBracketedWrapsAndStripsEscapes() {
        same(paste("one\ntwo", true), "\u{1b}[200~one\rtwo\u{1b}[201~")
        same(paste("x\u{1b}[201~y", true), "\u{1b}[200~xy\u{1b}[201~")
        same(paste("a\u{1b}b\u{1b}[31mc", true), "\u{1b}[200~ab[31mc\u{1b}[201~")
        // removing one end marker must not leave another behind
        same(paste("\u{1b}[20\u{1b}[201~1~", true), "\u{1b}[200~\u{1b}[201~")
        same(paste("a\u{9b}b", true), "\u{1b}[200~ab\u{1b}[201~")
    }
}

final class DroppedPathsTests: XCTestCase {
    func testSafePathsStayBare() {
        XCTAssertEqual(PasteEncoder.droppedPaths(["/Users/me/a.png"]), "/Users/me/a.png ")
    }

    func testSpacesAndQuotesAreQuoted() {
        XCTAssertEqual(PasteEncoder.droppedPaths(["/tmp/My File.txt", "/tmp/it's"]),
                       "'/tmp/My File.txt' '/tmp/it'\\''s' ")
    }

    func testShellMetacharactersAreQuoted() {
        XCTAssertEqual(PasteEncoder.droppedPaths(["/tmp/$(rm -rf ~)"]), "'/tmp/$(rm -rf ~)' ")
        XCTAssertEqual(PasteEncoder.droppedPaths(["/tmp/a;b"]), "'/tmp/a;b' ")
    }

    func testNothingDroppedIsEmpty() {
        XCTAssertEqual(PasteEncoder.droppedPaths([]), "")
    }
}
