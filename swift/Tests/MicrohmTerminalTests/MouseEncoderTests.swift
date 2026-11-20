import AppKit
import XCTest
import MicrohmVT
@testable import MicrohmTerminal

final class MouseEncoderTests: XCTestCase {

    private typealias T = TerminalEmulator.MouseTracking
    private typealias E = TerminalEmulator.MouseEncoding
    private static let trackings: [T] = [.none, .x10, .normal, .buttonMotion, .anyMotion]
    private static let encodings: [E] = [.default, .utf8, .sgr, .urxvt]

    private func sgr(_ t: T, _ a: MouseEncoder.Action, _ button: Int, _ col: Int, _ row: Int, _ mods: Int) -> String? {
        guard let b = MouseEncoder.encode(t, .sgr, a, button, col, row, mods) else {
            return nil
        }
        return String(decoding: b, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "^[")
    }

    func testWhichEventsEachModeReports() {
        let actions: [MouseEncoder.Action] = [.press, .release, .drag, .move]
        let expected: [[Bool]] = [
            [false, false, false, false], // NONE
            [true, false, false, false],  // X10
            [true, true, false, false],   // NORMAL
            [true, true, true, false],    // BUTTON_MOTION
            [true, true, true, true],     // ANY_MOTION
        ]
        for (m, mode) in MouseEncoderTests.trackings.enumerated() {
            for (a, action) in actions.enumerated() {
                for enc in MouseEncoderTests.encodings {
                    let button = action == .move ? MouseEncoder.none : MouseEncoder.left
                    let r = MouseEncoder.encode(mode, enc, action, button, 0, 0, 0)
                    XCTAssertEqual(expected[m][a], r != nil, "\(mode) \(action) \(enc)")
                }
            }
        }
    }

    func testSgrPressReleaseDragMoveWheel() {
        XCTAssertEqual(sgr(.normal, .press, MouseEncoder.left, 0, 0, 0), "^[[<0;1;1M")
        XCTAssertEqual(sgr(.normal, .release, MouseEncoder.right, 9, 4, 0), "^[[<2;10;5m")
        XCTAssertEqual(sgr(.buttonMotion, .drag, MouseEncoder.left, 2, 3, 0), "^[[<32;3;4M")
        XCTAssertEqual(sgr(.anyMotion, .move, MouseEncoder.none, 2, 3, 0), "^[[<35;3;4M")
        XCTAssertEqual(sgr(.normal, .press, MouseEncoder.wheelUp, 0, 0, 0), "^[[<64;1;1M")
        XCTAssertEqual(sgr(.normal, .press, MouseEncoder.wheelDown, 0, 0, 0), "^[[<65;1;1M")
        XCTAssertNil(sgr(.normal, .release, MouseEncoder.wheelUp, 0, 0, 0))
        XCTAssertEqual(sgr(.normal, .press, MouseEncoder.middle, 499, 299, 0), "^[[<1;500;300M")
    }

    func testModifierBits() {
        XCTAssertEqual(sgr(.normal, .press, 0, 0, 0, MouseEncoder.shift), "^[[<4;1;1M")
        XCTAssertEqual(sgr(.normal, .press, 0, 0, 0, MouseEncoder.meta), "^[[<8;1;1M")
        XCTAssertEqual(sgr(.normal, .press, 0, 0, 0, MouseEncoder.ctrl), "^[[<16;1;1M")
        XCTAssertEqual(sgr(.normal, .press, MouseEncoder.wheelUp, 0, 0, MouseEncoder.ctrl | MouseEncoder.meta),
                       "^[[<88;1;1M")
        // X10 reports no modifiers
        XCTAssertEqual(sgr(.x10, .press, 0, 0, 0, MouseEncoder.ctrl), "^[[<0;1;1M")
        XCTAssertEqual(MouseEncoder.modifiers([.shift, .control]), MouseEncoder.shift | MouseEncoder.ctrl)
        XCTAssertEqual(MouseEncoder.modifiers([.option, .command]), MouseEncoder.meta)
    }

    func testDefaultEncodingIsOffsetBytesClampedAt223() {
        XCTAssertEqual(MouseEncoder.encode(.normal, .default, .press, 0, 0, 0, 0)!, [0x1b, 0x5B, 0x4D, 32, 33, 33])
        XCTAssertEqual(MouseEncoder.encode(.normal, .default, .release, 2, 9, 4, 0)!, [0x1b, 0x5B, 0x4D, 35, 42, 37])
        let far = MouseEncoder.encode(.normal, .default, .press, 0, 400, 300, 0)!
        XCTAssertEqual(far[4], 255)
        XCTAssertEqual(far[5], 255)
        let wheel = MouseEncoder.encode(.normal, .default, .press, MouseEncoder.wheelDown, 0, 0, MouseEncoder.shift)!
        XCTAssertEqual(Int(wheel[3]), 32 + 65 + 4)
    }

    func testUtf8EncodingWidensCoordinates() {
        XCTAssertEqual(MouseEncoder.encode(.normal, .utf8, .press, 0, 0, 0, 0)!, [0x1b, 0x5B, 0x4D, 32, 33, 33])
        let wide = MouseEncoder.encode(.normal, .utf8, .press, 0, 299, 0, 0)!
        let decoded = Array(String(decoding: wide[3...], as: UTF8.self).unicodeScalars)
        XCTAssertEqual(decoded[1].value, 300 + 32)
        let clamped = MouseEncoder.encode(.normal, .utf8, .press, 0, 5000, 0, 0)!
        XCTAssertEqual(Array(String(decoding: clamped[3...], as: UTF8.self).unicodeScalars)[1].value, 2015 + 32)
    }

    func testUrxvtEncodingIsDecimal() {
        let b = MouseEncoder.encode(.normal, .urxvt, .press, 0, 299, 9, MouseEncoder.ctrl)!
        XCTAssertEqual(String(decoding: b, as: UTF8.self), "\u{1b}[48;300;10M")
        let release = MouseEncoder.encode(.normal, .urxvt, .release, 0, 0, 0, 0)!
        XCTAssertEqual(String(decoding: release, as: UTF8.self), "\u{1b}[35;1;1M")
        XCTAssertNotNil(MouseEncoder.encode(.x10, .urxvt, .press, MouseEncoder.wheelUp, 0, 0, 0))
    }
}
