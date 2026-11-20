import XCTest
import MicrohmVT
@testable import MicrohmTerminal

final class AnsiPalettesTests: XCTestCase {

    func testEverySettingHasSixteenSlots() {
        for p in AnsiPalettes.Palette.allCases {
            XCTAssertEqual(AnsiPalettes.forSetting(p).count, 16, p.rawValue)
        }
        XCTAssertEqual(AnsiPalettes.forSetting(.xterm)[1], 0xCD0000)
        XCTAssertEqual(AnsiPalettes.forSetting(.macosTerminal)[1], 0xC23621)
        XCTAssertEqual(AnsiPalettes.forSetting(.iterm2)[15], 0xFFFFFF)
    }

    func testDefaultsFollowThePaletteAndTheme() {
        let palette = AnsiPalettes.forSetting(.macosTerminal)
        let dark = TerminalColors(palette, false)
        XCTAssertEqual(dark.defaultBackground, 0x000000)
        XCTAssertEqual(dark.defaultForeground, 0xE9EBEB)
        let light = TerminalColors(palette, true)
        XCTAssertEqual(light.defaultBackground, 0xE9EBEB)
        XCTAssertEqual(light.defaultForeground, 0x000000)
        light.setTheme(0x123456, true)
        XCTAssertEqual(light.defaultBackground, 0x123456)
        XCTAssertEqual(light.defaultForeground, 0x000000)
        XCTAssertEqual(dark.rgb(Style.indexed(1), true), 0xC23621)
        XCTAssertEqual(dark.rgb(Style.indexed(231), true), 0xFFFFFF)
        XCTAssertEqual(dark.rgb(Style.rgb(10, 11, 12), false), 0x0A0B0C)
    }
}
