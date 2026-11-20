import XCTest
@testable import MicrohmVT

/** Every row of the query policy table (`QueryFilter`). */
final class QueryFilterTests: XCTestCase {

    private func stripped(_ seq: String) -> Bool {
        let kind: VtToken.Kind = seq.hasPrefix("\u{1b}[") ? .csi : .text
        return QueryFilter.isServerAnswered(VtToken(kind, bytes(seq)))
    }

    func testDa1IsStripped() {
        XCTAssertTrue(stripped("\u{1b}[c"))
        XCTAssertTrue(stripped("\u{1b}[0c"))
        XCTAssertTrue(stripped("\u{1b}[0;1c"))
    }

    func testOnlyPlainDa1IsStripped() {
        XCTAssertFalse(stripped("\u{1b}[?6c")) // the Linux console's cursor shape, not a query
        XCTAssertFalse(stripped("\u{1b}[?c"))
        XCTAssertFalse(stripped("\u{1b}[=c"))  // DA3: nobody answers it
        XCTAssertFalse(stripped("\u{1b}[1c"))
        XCTAssertFalse(stripped("\u{1b}[0 c"))
        XCTAssertFalse(stripped("\u{1b}[0:1c"))
        XCTAssertFalse(stripped("\u{1b}[4294967296c")) // must not wrap round to 0
    }

    func testDa2AbsentOrZeroIsStripped() {
        XCTAssertTrue(stripped("\u{1b}[>c"))
        XCTAssertTrue(stripped("\u{1b}[>0c"))
        XCTAssertTrue(stripped("\u{1b}[>0;1c"))
    }

    func testDa2NonZeroPassesThrough() {
        XCTAssertFalse(stripped("\u{1b}[>1c"))
    }

    func testDsrCprStripped() {
        XCTAssertTrue(stripped("\u{1b}[5n"))
        XCTAssertTrue(stripped("\u{1b}[6n"))
    }

    func testDecxcprAndColorSchemePassThrough() {
        XCTAssertFalse(stripped("\u{1b}[?6n"))
        XCTAssertFalse(stripped("\u{1b}[?996n"))
    }

    func testDsrWithoutFiveOrSixPassesThrough() {
        XCTAssertFalse(stripped("\u{1b}[n"))
        XCTAssertFalse(stripped("\u{1b}[0n"))
    }

    func testXtwinops() {
        XCTAssertTrue(stripped("\u{1b}[8;24;80t"))
        XCTAssertFalse(stripped("\u{1b}[22;0t"))
        XCTAssertFalse(stripped("\u{1b}[18t"))
    }

    func testUnrelatedSequencesPassThrough() {
        XCTAssertFalse(stripped("\u{1b}[?2004h"))
        XCTAssertFalse(stripped("\u{1b}[38;5;9m"))
        XCTAssertFalse(stripped("\u{1b}[>1;1;0c"))
        XCTAssertFalse(stripped("\u{1b}[?6;1$y"))
    }

    func testNonCsiNeverStripped() {
        XCTAssertFalse(QueryFilter.isServerAnswered(VtToken(.osc, bytes("\u{1b}]10;?\u{7}"))))
    }

    /** The filter and the emulator's basic reply scope stay in lock-step. */
    func testStrippedQueriesAreExactlyTheBasicReplies() {
        let queries = ["\u{1b}[c", "\u{1b}[0c", "\u{1b}[>c", "\u{1b}[>0c", "\u{1b}[5n", "\u{1b}[6n", "\u{1b}[?6n",
                       "\u{1b}[?6c", "\u{1b}[>1c", "\u{1b}[1c", "\u{1b}[?996n", "\u{1b}[?2004$p", "\u{1b}[>q",
                       "\u{1b}[?u", "\u{1b}[18t"]
        for q in queries {
            let e = TerminalEmulator(20, 5, 0)
            var replies = 0
            e.setReplies({ _ in replies += 1 }, .basic)
            e.feed(bytes(q))
            XCTAssertEqual(replies > 0, stripped(q), q.replacingOccurrences(of: "\u{1b}", with: "ESC"))
        }
    }
}

/** SGR normalisation (`SgrNormalizer`). */
final class SgrNormalizerTests: XCTestCase {

    private func csi(_ seq: String) -> VtToken {
        return VtToken(.csi, bytes(seq))
    }

    private func normalized(_ seq: String) -> String {
        return SgrNormalizer.normalize(csi(seq)).asString()
    }

    func testRgbForms() {
        XCTAssertEqual("\u{1b}[38;2;10;20;30m", normalized("\u{1b}[38:2::10:20:30m"))
        XCTAssertEqual("\u{1b}[48;2;1;2;3m", normalized("\u{1b}[48:2:1:2:3m"))
        XCTAssertEqual("\u{1b}[38;5;9m", normalized("\u{1b}[38:5:9m"))
    }

    func testUnderlines() {
        XCTAssertEqual("\u{1b}[4:3m", normalized("\u{1b}[4:3m"))
        XCTAssertEqual("\u{1b}[4:4m", normalized("\u{1b}[4:4m"))
        XCTAssertEqual("\u{1b}[4:5m", normalized("\u{1b}[4:5m"))
        XCTAssertEqual("\u{1b}[4m", normalized("\u{1b}[4:1m"))
        XCTAssertEqual("\u{1b}[21m", normalized("\u{1b}[4:2m"))
        XCTAssertEqual("\u{1b}[4m", normalized("\u{1b}[4:9m"))
        XCTAssertEqual("\u{1b}[4m", normalized("\u{1b}[4:m"))
        XCTAssertEqual("\u{1b}[24m", normalized("\u{1b}[4:0m"))
    }

    func testUnderlineColourDropped() {
        XCTAssertEqual("\u{1b}[1;4m", normalized("\u{1b}[1;4;58:2::1:2:3m"))
        XCTAssertEqual("\u{1b}[4:3m", normalized("\u{1b}[59;4:3m"))
        let colonFree = csi("\u{1b}[1;59m")
        XCTAssertEqual(colonFree, SgrNormalizer.normalize(colonFree))
    }

    func testOtherSubparametersAndMixedGroups() {
        XCTAssertEqual("\u{1b}[38;5;9;1m", normalized("\u{1b}[38:5:9;1:2m"))
        XCTAssertEqual("\u{1b}[0;38;2;255;0;0;4:3m", normalized("\u{1b}[0;38:2::255:0:0;4:3m"))
    }

    func testSemicolonColourArgumentsAreValuesNotCodes() {
        XCTAssertEqual("\u{1b}[48;2;1;2;3;38;2;186;172;59m", normalized("\u{1b}[48:2::1:2:3;38;2;186;172;59m"))
        XCTAssertEqual("\u{1b}[4:3;38;5;59m", normalized("\u{1b}[4:3;38;5;59m"))
        XCTAssertEqual("\u{1b}[1;24;31m", normalized("\u{1b}[1;58;2;10;20;30;4:0;31m"))
    }

    func testOtherTokensAreReturnedUnchanged() {
        for t in [csi("\u{1b}[38;5;9m"), csi("\u{1b}[6n"), VtToken(.text, bytes("a:b"))] {
            XCTAssertEqual(t, SgrNormalizer.normalize(t))
        }
    }
}

final class KeyNamesTests: XCTestCase {

    private func text(_ keys: [String], _ app: Bool = false) -> String {
        return String(decoding: try! KeyNames.encode(keys, app), as: UTF8.self)
    }

    func testSingleCharactersAreTheirUtf8Bytes() {
        XCTAssertEqual("1y/", text(["1", "y", "/"]))
        XCTAssertEqual("Y", text(["Y"]), "a literal keeps its case")
        XCTAssertEqual(bytes("é"), try KeyNames.encode(["é"], false))
        XCTAssertEqual(bytes("😀"), try KeyNames.encode(["😀"], false))
    }

    func testNamedKeysAreCaseInsensitive() {
        XCTAssertEqual("\r", text(["Enter"]))
        XCTAssertEqual("\r", text(["ENTER"]))
        XCTAssertEqual("\t", text(["tab"]))
        XCTAssertEqual("\u{1b}[Z", text(["BTab"]))
        XCTAssertEqual("\u{1b}[Z", text(["S-Tab"]))
        XCTAssertEqual("\u{1b}\u{1b}", text(["Esc", "Escape"]))
        XCTAssertEqual(" ", text(["Space"]))
        XCTAssertEqual("\u{7f}\u{7f}", text(["Backspace", "BSpace"]))
        XCTAssertEqual("\u{1b}[3~\u{1b}[3~", text(["Delete", "DC"]))
        XCTAssertEqual("\u{1b}[2~\u{1b}[2~", text(["Insert", "IC"]))
        XCTAssertEqual("\u{1b}[5~\u{1b}[5~\u{1b}[5~", text(["PageUp", "PgUp", "PPage"]))
        XCTAssertEqual("\u{1b}[6~\u{1b}[6~\u{1b}[6~", text(["PageDown", "PgDn", "NPage"]))
    }

    func testCursorKeysFollowApplicationMode() {
        let keys = ["Up", "Down", "Right", "Left", "Home", "End"]
        XCTAssertEqual("\u{1b}[A\u{1b}[B\u{1b}[C\u{1b}[D\u{1b}[H\u{1b}[F", text(keys))
        XCTAssertEqual("\u{1b}OA\u{1b}OB\u{1b}OC\u{1b}OD\u{1b}OH\u{1b}OF", text(keys, true))
        XCTAssertEqual("\u{1b}[3~", text(["Delete"], true))
    }

    func testFunctionKeys() {
        XCTAssertEqual("\u{1b}OP\u{1b}OQ\u{1b}OR\u{1b}OS", text(["F1", "F2", "F3", "F4"]))
        XCTAssertEqual("\u{1b}[15~\u{1b}[17~\u{1b}[18~\u{1b}[19~\u{1b}[20~\u{1b}[21~\u{1b}[23~\u{1b}[24~",
                       text(["F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]))
    }

    func testControlKeys() {
        XCTAssertEqual("\u{3}", text(["C-c"]))
        XCTAssertEqual("\u{3}", text(["C-C"]))
        XCTAssertEqual("\u{1}\u{1a}", text(["c-a", "C-z"]))
        XCTAssertEqual(bytes("\u{0}\u{0}"), try KeyNames.encode(["C-Space", "C-@"], false))
        XCTAssertEqual("\u{1b}\u{1c}\u{1d}\u{1e}\u{1f}", text(["C-[", "C-\\", "C-]", "C-^", "C-_"]))
        XCTAssertEqual("\u{7f}", text(["C-?"]))
    }

    func testMetaPrefixesEscRecursively() {
        XCTAssertEqual("\u{1b}b", text(["M-b"]))
        XCTAssertEqual(bytes("\u{1b}\r"), try KeyNames.encode(["M-Enter"], false))
        XCTAssertEqual("\u{1b}\u{18}", text(["M-C-x"]))
        XCTAssertEqual("\u{1b}\u{1b}OA", text(["M-Up"], true))
    }

    func testUnknownKeysAreRejectedByName() {
        for bad in ["Bogus", "", "C-", "C-1", "C-ab", "M-", "M-Bogus", "F13", "ab"] {
            XCTAssertThrowsError(try KeyNames.encode(["a", bad], false), bad) { error in
                XCTAssertEqual("unknown key: " + bad, (error as? KeyNames.UnknownKey)?.message)
            }
        }
    }
}
