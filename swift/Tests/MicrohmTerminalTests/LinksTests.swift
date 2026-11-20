import XCTest
import MicrohmVT
@testable import MicrohmTerminal

final class LinksTests: XCTestCase {

    func testFindsTheLinkUnderACell() {
        let e = term(40, 2, "see https://a.example/x now")
        XCTAssertEqual(Links.urlAt(e, 0, 4), "https://a.example/x")
        XCTAssertEqual(Links.urlAt(e, 0, 22), "https://a.example/x")
        XCTAssertNil(Links.urlAt(e, 0, 3))
        XCTAssertNil(Links.urlAt(e, 0, 23))
        XCTAssertNil(Links.urlAt(e, 1, 4))
    }

    func testFollowsALinkAcrossSoftWraps() {
        let e = term(12, 4, "go https://claude.ai/code/s\r\nnext")
        let url = "https://claude.ai/code/s"
        XCTAssertEqual(Links.urlAt(e, 0, 5), url)
        XCTAssertEqual(Links.urlAt(e, 2, 0), url)
        XCTAssertNil(Links.urlAt(e, 3, 0))
    }

    func testFollowsALinkTheProgramBrokeAtTheEdge() {
        // Claude Code's /rc at 30 columns: it breaks the link itself, indenting the rest
        let e = term(30, 4, "  phone, or at https://claude\r\n  .ai/code/session_01Vwo\r\n  more text here")
        let url = "https://claude.ai/code/session_01Vwo"
        XCTAssertEqual(Links.urlAt(e, 0, 20), url)
        XCTAssertEqual(Links.urlAt(e, 1, 2), url)
        XCTAssertEqual(Links.urlAt(e, 1, 23), url)
        XCTAssertNil(Links.urlAt(e, 1, 24))
        XCTAssertNil(Links.urlAt(e, 2, 3))
    }

    func testALinkShortOfTheEdgeEndsWithItsRow() {
        let e = term(40, 2, "  - https://a.example/x\r\n  - next item")
        XCTAssertEqual(Links.urlAt(e, 0, 5), "https://a.example/x")
        XCTAssertNil(Links.urlAt(e, 1, 4))
    }

    func testABreakAtADifferentIndentIsNotTheLink() {
        let e = term(20, 2, "  https://a.example/\r\n    word")
        XCTAssertEqual(Links.urlAt(e, 0, 5), "https://a.example/")
        XCTAssertNil(Links.urlAt(e, 1, 5))
    }

    func testLeavesOutTheSentenceAroundIt() {
        XCTAssertEqual(Links.trim("https://a.example/x."), "https://a.example/x")
        XCTAssertEqual(Links.trim("https://a.example/x),"), "https://a.example/x")
        XCTAssertEqual(Links.trim("https://en.example/A_(b)"), "https://en.example/A_(b)")
        let e = term(40, 1, "(at https://a.example/x).")
        XCTAssertEqual(Links.urlAt(e, 0, 10), "https://a.example/x")
        XCTAssertNil(Links.urlAt(e, 0, 23))
    }

    func testOnlyWebLinks() {
        XCTAssertNil(Links.urlAt(term(40, 1, "file:///etc/hosts ftp://x"), 0, 3))
        XCTAssertEqual(Links.urlAt(term(40, 1, "http://h:7393/#k=1"), 0, 0), "http://h:7393/#k=1")
    }
}
