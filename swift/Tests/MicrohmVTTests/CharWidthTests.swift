import XCTest
@testable import MicrohmVT

/** The generated width table, spot-checked and against its golden wide set. */
final class CharWidthTests: XCTestCase {

    func testSpotChecks() {
        XCTAssertEqual(1, CharWidth.of(0x61))     // a
        XCTAssertEqual(1, CharWidth.of(0xE9))     // é
        XCTAssertEqual(1, CharWidth.of(0x2500))   // ─ (ambiguous: narrow)
        XCTAssertEqual(1, CharWidth.of(0x00A1))   // ¡ (ambiguous)
        XCTAssertEqual(2, CharWidth.of(0x4E2D))   // 中
        XCTAssertEqual(2, CharWidth.of(0xAC00))   // 가
        XCTAssertEqual(2, CharWidth.of(0xFF21))   // Ａ fullwidth
        XCTAssertEqual(2, CharWidth.of(0x231A))   // ⌚ emoji presentation
        XCTAssertEqual(2, CharWidth.of(0x1F680))  // 🚀
        XCTAssertEqual(2, CharWidth.of(0x1F1FA))  // regional indicator
        XCTAssertEqual(2, CharWidth.of(0x20000))  // CJK extension B
        XCTAssertEqual(1, CharWidth.of(0x2764))   // ❤ text presentation
        XCTAssertEqual(1, CharWidth.of(0x1D400))  // 𝐀
        XCTAssertEqual(0, CharWidth.of(0x0301))   // combining acute
        XCTAssertEqual(0, CharWidth.of(0x200D))   // ZWJ
        XCTAssertEqual(0, CharWidth.of(0xFE0F))   // VS16
        XCTAssertEqual(2, CharWidth.of(0x1F3FB))  // skin tone modifier: wide on its own, joins an emoji
        XCTAssertEqual(0, CharWidth.of(0x1160))   // Hangul jungseong filler
        XCTAssertEqual(1, CharWidth.of(0x00AD))   // soft hyphen
        XCTAssertEqual(0, CharWidth.of(0xE0100))  // variation selector supplement
        XCTAssertEqual(0, CharWidth.of(0x85))     // C1
    }

    /** The BMP code points from U+00A1 that are two cells wide, as ranges. */
    func testWideBmpSetMatchesGolden() {
        var out = ""
        var start = -1
        func hex(_ v: Int) -> String {
            let h = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, 4 - h.count)) + h
        }
        for c in 0xA1...0x10000 {
            let wide = c < 0x10000 && !(c >= 0xD800 && c <= 0xDFFF) && CharWidth.of(c) == 2
            if wide && start < 0 {
                start = c
            } else if !wide && start >= 0 {
                out += "\(hex(start))..\(hex(c - 1))\n"
                start = -1
            }
        }
        Golden.check("wide-bmp.txt", out)
    }
}
