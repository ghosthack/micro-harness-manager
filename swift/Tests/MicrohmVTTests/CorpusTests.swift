import XCTest
@testable import MicrohmVT

/**
 * Hand-written sequences, one or a few per feature, whose full state (text, styles, cursor,
 * modes and replies) must match its golden file and whose redraw round trips.
 */
final class CorpusTests: XCTestCase {

    struct Case {
        let name: String
        let columns: Int
        let rows: Int
        let input: String

        init(_ name: String, _ columns: Int, _ rows: Int, _ input: String) {
            self.name = name
            self.columns = columns
            self.rows = rows
            self.input = input
        }
    }

    static func cases() -> [Case] {
        var lines = ""
        for i in 0..<40 {
            lines += "line \(i)\r\n"
        }
        return [
            // --- text, wrapping, C0 -------------------------------------------------
            Case("plain text and CRLF", 20, 5, "hello\r\nworld\r\n"),
            Case("autowrap of a long line", 10, 5, "abcdefghijklmnopqrstuvwxyz"),
            Case("line exactly the width, then CRLF", 10, 4, "0123456789\r\nnext"),
            Case("scrolling into history", 20, 5, lines),
            Case("carriage return overwrite", 20, 3, "hello\rJ"),
            Case("backspace mid-line", 20, 3, "abc\u{8}\u{8}X"),
            Case("tab stops", 40, 3, "a\tb\tc\r\n\tx"),
            Case("BEL, ENQ and NUL are ignored", 20, 3, "a\u{7}b\u{5}c\u{0}d"),
            Case("vertical tab and form feed are line feeds", 20, 4, "a\u{b}b\u{c}c"),
            Case("set and clear tab stops", 40, 3, C + "3g" + C + "1;5H" + E + "H" + C + "1;12H" + E + "H\r\tx\ty"
                    + C + "2;5H" + C + "0g\r\n\tz"),
            // --- SGR ---------------------------------------------------------------
            Case("SGR attributes", 60, 3, C + "1mB" + C + "2mD" + C + "3mI" + C + "4mU" + C + "5mK" + C + "6mR"
                    + C + "7mV" + C + "8mH" + C + "0mN"),
            Case("SGR resets", 60, 3, C + "1;2;3;4;5;7;8mx" + C + "22my" + C + "23mz" + C + "24mw" + C + "25mv"
                    + C + "27mu" + C + "28mt" + C + "mz"),
            Case("SGR 16 colours", 40, 4, C + "31mr" + C + "42mg" + C + "97mW" + C + "104mB" + C + "39mf" + C + "49mb"),
            Case("SGR 256 colours", 40, 3, C + "38;5;9mlo" + C + "38;5;208mhi" + C + "48;5;27mbg" + C + "48;5;250mgr"),
            Case("SGR truecolour", 40, 3, C + "38;2;10;200;30mfg" + C + "48;2;1;2;3mbg"),
            Case("SGR colon forms (normalised)", 40, 3, C + "38:2::10:20:30mx" + C + "48:5:100my" + C + "4:3mz"),
            Case("SGR several in one", 40, 3, C + "0;1;4;31;44mmixed" + C + "0m plain"),
            // --- cursor --------------------------------------------------------------
            Case("CUP and HVP", 20, 6, C + "3;4Hx" + C + "5;10fy" + C + "Hz" + C + "99;99Hw"),
            Case("relative moves", 20, 6, C + "3;10H" + C + "2Aa" + C + "3Bb" + C + "4Cc" + C + "5Dd" + C + "0Ae"),
            Case("CNL and CPL", 20, 6, C + "3;10H" + C + "2Ea" + C + "Fb"),
            Case("CHA, HPA and VPA", 20, 6, C + "5Ga" + C + "10`b" + C + "4dc"),
            Case("DECSC and DECRC with style", 20, 4, C + "2;3H" + C + "1;31m" + E + "7" + C + "0m" + C + "4;1Hx"
                    + E + "8y"),
            Case("DECRC without DECSC homes", 20, 4, C + "3;3H" + C + "1m" + E + "8z"),
            // --- erase / edit --------------------------------------------------------
            Case("ED 0 and 2", 20, 5, "aaaa\r\nbbbb\r\ncccc\r\ndddd" + C + "2;3H" + C + "0J" + C + "5;1He"
                    + C + "2J" + C + "Hnew"),
            Case("ED with a background colour", 20, 4, "x\r\ny" + C + "44m" + C + "2J" + C + "0mz"),
            Case("EL 0, 1 and 2", 20, 4, "abcdefgh" + C + "1;4H" + C + "0K\r\nabcdefgh" + C + "2;4H" + C + "1K"
                    + "\r\nabcdefgh" + C + "2K"),
            Case("ICH, DCH and ECH", 20, 4, "abcdefgh" + C + "1;3H" + C + "2@xy\r\nabcdefgh" + C + "2;3H" + C + "2P"
                    + "\r\nabcdefgh" + C + "3;3H" + C + "3X"),
            Case("ECH with a background colour", 20, 3, "abcdefgh" + C + "1;3H" + C + "41m" + C + "3X" + C + "0m"),
            Case("IL and DL inside the region", 20, 6, "1\r\n2\r\n3\r\n4\r\n5\r\n6" + C + "2;5r" + C + "3;1H" + C + "2L"
                    + "\r" + C + "4;1H" + C + "M\r"),
            // --- scrolling -----------------------------------------------------------
            Case("DECSTBM and line feeds in the region", 20, 6, "top\r\n" + C + "2;4r" + C + "4;1Ha\r\nb\r\nc\r\nd"),
            Case("SU and SD", 20, 5, "1\r\n2\r\n3\r\n4\r\n5" + C + "2S" + C + "T"),
            Case("SU and SD in a region", 20, 6, "1\r\n2\r\n3\r\n4\r\n5\r\n6" + C + "2;5r" + C + "2S" + C + "3T"),
            Case("IND, NEL and RI", 20, 5, C + "2;4r" + C + "4;3H" + E + "Da" + E + "Eb" + C + "2;3H" + E + "Mc"),
            Case("origin mode CUP", 20, 6, C + "2;5r" + C + "?6h" + C + "Ha" + C + "9;9Hb" + C + "?6l" + C + "Hc"),
            // --- screens -------------------------------------------------------------
            Case("alternate screen 1049 and back", 20, 4, "main" + C + "2;3H" + C + "?1049halt text" + C + "?1049l"
                    + "!"),
            Case("alternate screen keeps its own content", 20, 4, C + "?1049h" + C + "3;3Hx" + C + "?1049l"
                    + C + "?1049hy"),
            Case("RIS", 20, 4, C + "1;31mtext" + C + "?2004h" + E + "c" + C + "?2004lafter"),
            // --- modes and strings ----------------------------------------------------
            Case("private modes", 20, 3, C + "?1h" + C + "?7l" + C + "?25l" + C + "?2004h" + C + "?1002h" + C + "?1006h"
                    + C + "?1004h" + C + "5 q" + E + "="),
            Case("mouse modes replace each other", 20, 3, C + "?1000h" + C + "?1003h" + C + "?1006h" + C + "?1006l"),
            Case("titles", 20, 3, E + "]0;zero\u{7}" + E + "]2;two" + E + "\\" + "after"),
            Case("ignored OSC, DCS and APC", 20, 3, "a" + E + "]7;file://h/tmp\u{7}b" + E + "]8;;http://x\u{7}c"
                    + E + "]8;;\u{7}" + E + "]52;c;?\u{7}" + E + "]133;A\u{7}" + E + "P+q544e\u{1b}\\" + E + "_Gi=1\u{1b}\\d"),
            Case("DEC special graphics", 20, 4, E + "(0lqqk\r\nx  x\r\nmqqj" + E + "(Bascii"),
            Case("autowrap off at the margin", 10, 3, C + "?7l" + "0123456789" + "\r\nshort"),
            // --- Unicode ---------------------------------------------------------------
            Case("wide CJK", 20, 3, "中文 and 日本語"),
            Case("wide character wraps at the margin", 7, 3, "abcdef中x"),
            Case("emoji", 20, 3, "hi 🛑 stop 🚀 go"),
            Case("precomposed and NFC-composable accents", 20, 3, "caf\u{e9} e\u{301} a\u{308}"),
            Case("overwriting half of a wide character", 20, 3, "中文字" + C + "1;2Hx" + C + "1;5Hy"),
            // --- replies -------------------------------------------------------------
            Case("DSR and CPR", 20, 5, C + "3;7H" + C + "5n" + C + "6n" + C + "2;4r" + C + "?6h" + C + "2;2H" + C + "6n"),
        ]
    }

    func testSerializerRoundTrips() {
        for c in CorpusTests.cases() {
            let e = TerminalEmulator(c.columns, c.rows, 100)
            e.feed(bytes(c.input))
            ModelAssert.roundTrip(e, 100, c.name + ": ")
        }
    }

    func testMatchesGolden() {
        for c in CorpusTests.cases() {
            let s = Subject(c.columns, c.rows, 100)
            s.feed(c.input)
            Golden.check("corpus/" + Golden.slug(c.name) + ".txt", s.snapshot())
        }
    }

    func testEveryCorpusGoldenHasACase() {
        let names = Set(CorpusTests.cases().map { Golden.slug($0.name) + ".txt" })
        let files = try! FileManager.default.contentsOfDirectory(atPath: Golden.root().appendingPathComponent("corpus").path)
        XCTAssertEqual(Set(files), names)
    }
}
