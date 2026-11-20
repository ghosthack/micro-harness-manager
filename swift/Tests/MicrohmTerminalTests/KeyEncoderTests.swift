import XCTest
@testable import MicrohmTerminal

final class KeyEncoderTests: XCTestCase {

    private let normal = KeyEncoder.Modes(false, false, false, true)
    private let app = KeyEncoder.Modes(true, true, false, true)
    private let linux = KeyEncoder.Modes(false, false, false, false)

    private func press(_ keyCode: Int, _ keyChar: Unicode.Scalar? = nil, _ mods: KeyEncoder.Modifiers,
                       _ modes: KeyEncoder.Modes) -> String? {
        guard let b = KeyEncoder.pressed(keyCode, keyChar: keyChar, modifiers: mods, modes: modes) else {
            return nil
        }
        return KeyEncoderTests.visible(String(decoding: b, as: UTF8.self))
    }

    /// ESC as "^[", other C0 as ^X, so failures read.
    static func visible(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            if c.value == 0x1b {
                out += "^["
            } else if c.value < 0x20 {
                out += "^" + String(Character(Unicode.Scalar(c.value + 0x40)!))
            } else if c.value == 0x7f {
                out += "^?"
            } else {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// 1 shift, 2 alt, 4 ctrl.
    private func ex(_ mods: Int) -> KeyEncoder.Modifiers {
        var m: KeyEncoder.Modifiers = []
        if mods & 1 != 0 { m.insert(.shift) }
        if mods & 2 != 0 { m.insert(.alt) }
        if mods & 4 != 0 { m.insert(.ctrl) }
        return m
    }

    private static let keys: [String: Int] = [
        "UP": VK.up, "DOWN": VK.down, "RIGHT": VK.right, "LEFT": VK.left, "HOME": VK.home, "END": VK.end,
        "INSERT": VK.insert, "DELETE": VK.delete, "PAGE_UP": VK.pageUp, "PAGE_DOWN": VK.pageDown,
        "F1": VK.f(1), "F2": VK.f(2), "F3": VK.f(3), "F4": VK.f(4), "F5": VK.f(5), "F6": VK.f(6),
        "F7": VK.f(7), "F8": VK.f(8), "F9": VK.f(9), "F10": VK.f(10), "F11": VK.f(11), "F12": VK.f(12),
        "ENTER": VK.enter, "BACK_SPACE": VK.backSpace, "TAB": VK.tab, "ESCAPE": VK.escape,
    ]

    func testSpecialKeys() {
        let table = """
            UP               | 0    | ^[[A         | ^[OA
            DOWN             | 0    | ^[[B         | ^[OB
            RIGHT            | 0    | ^[[C         | ^[OC
            LEFT             | 0    | ^[[D         | ^[OD
            HOME             | 0    | ^[[H         | ^[OH
            END              | 0    | ^[[F         | ^[OF
            UP               | 1    | ^[[1;2A      | ^[[1;2A
            DOWN             | 4    | ^[[1;5B      | ^[[1;5B
            RIGHT            | 5    | ^[[1;6C      | ^[[1;6C
            LEFT             | 6    | ^[[1;7D      | ^[[1;7D
            HOME             | 1    | ^[[1;2H      | ^[[1;2H
            END              | 4    | ^[[1;5F      | ^[[1;5F
            UP               | 2    | ^[[1;3A      | ^[[1;3A
            INSERT           | 0    | ^[[2~        | ^[[2~
            DELETE           | 0    | ^[[3~        | ^[[3~
            PAGE_UP          | 0    | ^[[5~        | ^[[5~
            PAGE_DOWN        | 0    | ^[[6~        | ^[[6~
            DELETE           | 4    | ^[[3;5~      | ^[[3;5~
            PAGE_UP          | 1    | ^[[5;2~      | ^[[5;2~
            F1               | 0    | ^[OP         | ^[OP
            F2               | 0    | ^[OQ         | ^[OQ
            F3               | 0    | ^[OR         | ^[OR
            F4               | 0    | ^[OS         | ^[OS
            F1               | 1    | ^[[1;2P      | ^[[1;2P
            F4               | 4    | ^[[1;5S      | ^[[1;5S
            F5               | 0    | ^[[15~       | ^[[15~
            F6               | 0    | ^[[17~       | ^[[17~
            F7               | 0    | ^[[18~       | ^[[18~
            F8               | 0    | ^[[19~       | ^[[19~
            F9               | 0    | ^[[20~       | ^[[20~
            F10              | 0    | ^[[21~       | ^[[21~
            F11              | 0    | ^[[23~       | ^[[23~
            F12              | 0    | ^[[24~       | ^[[24~
            F5               | 1    | ^[[15;2~     | ^[[15;2~
            F12              | 4    | ^[[24;5~     | ^[[24;5~
            ENTER            | 0    | ^M           | ^M
            ENTER            | 1    | ^M           | ^M
            ENTER            | 2    | ^[^M         | ^[^M
            BACK_SPACE       | 0    | ^?           | ^?
            BACK_SPACE       | 4    | ^H           | ^H
            BACK_SPACE       | 2    | ^[^?         | ^[^?
            TAB              | 0    | ^I           | ^I
            TAB              | 1    | ^[[Z         | ^[[Z
            ESCAPE           | 0    | ^[           | ^[
            ESCAPE           | 2    | ^[^[         | ^[^[
            """
        for row in table.split(separator: "\n") {
            let f = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let code = KeyEncoderTests.keys[f[0]]!
            let mods = ex(Int(f[1])!)
            XCTAssertEqual(press(code, nil, mods, normal), f[2], "\(f[0]) mods=\(f[1]) normal")
            XCTAssertEqual(press(code, nil, mods, app), f[3], "\(f[0]) mods=\(f[1]) app")
        }
    }

    func testEnterSendsCrLfInNewLineMode() {
        XCTAssertEqual(press(VK.enter, nil, [], KeyEncoder.Modes(false, false, true, true)), "^M^J")
    }

    func testCtrlLettersAndPunctuationAreC0() {
        for k in VK.a...VK.z {
            let expected = "^" + String(Character(Unicode.Scalar(UInt8(0x41 + k - VK.a))))
            XCTAssertEqual(press(k, nil, .ctrl, normal), expected)
            XCTAssertEqual(press(k, nil, [.ctrl, .shift], normal), expected)
        }
        XCTAssertEqual(press(VK.space, nil, .ctrl, normal), "^@")
        XCTAssertEqual(press(VK.digit(2), nil, [.ctrl, .shift], normal), "^@")
        XCTAssertEqual(press(VK.openBracket, nil, .ctrl, normal), "^[")
        XCTAssertEqual(press(VK.backSlash, nil, .ctrl, normal), "^\\")
        XCTAssertEqual(press(VK.closeBracket, nil, .ctrl, normal), "^]")
        XCTAssertEqual(press(VK.digit(6), nil, [.ctrl, .shift], normal), "^^")
        XCTAssertEqual(press(VK.minus, nil, [.ctrl, .shift], normal), "^_")
        XCTAssertEqual(press(VK.slash, nil, .ctrl, normal), "^_")
        XCTAssertNil(press(VK.period, nil, .ctrl, normal))
    }

    func testCtrlAltLetterIsEscPrefixedC0() {
        XCTAssertEqual(press(VK.letter("x"), nil, [.ctrl, .alt], normal), "^[^X")
    }

    func testMacOptionLettersAndDigitsAreMeta() {
        XCTAssertEqual(press(VK.letter("b"), "∫", .alt, normal), "^[b")
        XCTAssertEqual(press(VK.letter("f"), "ƒ", .alt, normal), "^[f")
        XCTAssertEqual(press(VK.letter("e"), nil, .alt, normal), "^[e") // dead acute
        XCTAssertEqual(press(VK.letter("b"), "ı", [.alt, .shift], normal), "^[B")
        XCTAssertEqual(press(VK.letter("a"), "a", .alt, normal), "^[a")
        XCTAssertEqual(press(VK.digit(1), "¡", .alt, normal), "^[1")
    }

    func testMacOptionKeepsLayoutAsciiAndPunctuationComposing() {
        XCTAssertNil(press(VK.letter("l"), "@", .alt, normal)) // German Option+L
        XCTAssertNil(press(VK.digit(5), "[", .alt, normal))
        XCTAssertNil(press(VK.openBracket, "“", .alt, normal))
        XCTAssertNil(press(VK.digit(1), "⁄", [.alt, .shift], normal))
    }

    func testMacOptionArrowsAreWordMotion() {
        XCTAssertEqual(press(VK.left, nil, .alt, normal), "^[b")
        XCTAssertEqual(press(VK.right, nil, .alt, normal), "^[f")
        XCTAssertEqual(press(VK.left, nil, .alt, linux), "^[[1;3D")
    }

    func testOptionComposesWhenOptionAsMetaIsOff() {
        let composing = KeyEncoder.Modes(false, false, false, true, false)
        // letters, digits and dead keys go to the input method instead
        XCTAssertNil(press(VK.letter("e"), nil, .alt, composing)) // dead acute
        XCTAssertNil(press(VK.letter("a"), "å", .alt, composing))
        XCTAssertNil(press(VK.letter("g"), "©", .alt, composing))
        XCTAssertNil(press(VK.digit(1), "¡", .alt, composing))
        // named keys keep their encodings
        XCTAssertEqual(press(VK.left, nil, .alt, composing), "^[b")
        XCTAssertEqual(press(VK.enter, nil, .alt, composing), "^[^M")
        XCTAssertEqual(press(VK.backSpace, nil, .alt, composing), "^[^?")
        // the setting is macOS-only: Linux Alt stays Meta
        let linuxOff = KeyEncoder.Modes(false, false, false, false, false)
        XCTAssertEqual(press(VK.letter("x"), "x", .alt, linuxOff), "^[x")
    }

    func testAltElsewhereIsMetaForAnyPrintable() {
        XCTAssertEqual(press(VK.period, ".", .alt, linux), "^[.")
        XCTAssertEqual(press(VK.letter("x"), "x", .alt, linux), "^[x")
        XCTAssertEqual(press(VK.letter("x"), nil, [.alt, .shift], linux), "^[X")
    }

    func testAltGraphIsNotMeta() {
        XCTAssertNil(press(VK.letter("q"), "@", [.altGraph, .ctrl, .alt], linux))
    }

    func testCmdChordsAreNeverSent() {
        for k in [VK.letter("c"), VK.letter("v"), VK.letter("t"), VK.letter("w"), VK.digit(1), VK.up, VK.enter,
                  VK.backSpace] {
            XCTAssertNil(press(k, nil, .meta, normal))
            XCTAssertNil(press(k, nil, [.meta, .shift], normal))
        }
        XCTAssertNil(KeyEncoder.typed("c", modifiers: .meta))
    }

    func testPlainCharactersAreLeftToTyped() {
        XCTAssertNil(press(VK.letter("a"), "a", [], normal))
        XCTAssertNil(press(VK.letter("a"), "A", .shift, normal))
        XCTAssertNil(press(VK.space, " ", [], normal))
        XCTAssertNil(press(VK.shift, nil, [], normal))
        XCTAssertEqual(KeyEncoder.typed("a", modifiers: []).map { String(decoding: $0, as: UTF8.self) }, "a")
        XCTAssertEqual(KeyEncoder.typed("é", modifiers: .alt).map { String(decoding: $0, as: UTF8.self) }, "é")
        XCTAssertEqual(KeyEncoder.typed("é", modifiers: [])?.count, 2)
    }

    func testTypedControlsOnlyWithCtrl() {
        XCTAssertNil(KeyEncoder.typed("\n", modifiers: []))
        XCTAssertNil(KeyEncoder.typed("\u{8}", modifiers: []))
        XCTAssertNil(KeyEncoder.typed("\u{7f}", modifiers: []))
        XCTAssertNil(KeyEncoder.typed(nil, modifiers: []))
        XCTAssertEqual(KeyEncoder.typed("\u{3}", modifiers: .ctrl)?.first, 3)
    }

    func testKeypadInApplicationMode() {
        let five = KeyEncoder.pressed(VK.numpad0 + 5, location: .numpad, keyChar: "5", modifiers: [], modes: app)!
        XCTAssertEqual(KeyEncoderTests.visible(String(decoding: five, as: UTF8.self)), "^[Ou")
        let enter = KeyEncoder.pressed(VK.enter, location: .numpad, keyChar: "\r", modifiers: [], modes: app)!
        XCTAssertEqual(KeyEncoderTests.visible(String(decoding: enter, as: UTF8.self)), "^[OM")
        XCTAssertNil(KeyEncoder.pressed(VK.numpad0 + 5, location: .numpad, keyChar: "5", modifiers: [], modes: normal))
    }

    /// The NSEvent mapping: layout characters pick the VK, named keys their own codes.
    func testEventMapping() {
        func event(_ keyCode: UInt16, _ chars: String, _ ignoring: String,
                   _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: chars,
                                    charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)!
        }
        XCTAssertEqual(KeyEncoder.key(for: event(0x08, "\u{3}", "c", .control)).keyCode, VK.letter("c"))
        // a Cyrillic layout's C key still is Ctrl+C
        XCTAssertEqual(KeyEncoder.key(for: event(0x08, "\u{3}", "с", .control)).keyCode, VK.letter("c"))
        XCTAssertEqual(KeyEncoder.key(for: event(0x7E, "\u{F700}", "\u{F700}")).keyCode, VK.up)
        XCTAssertNil(KeyEncoder.keyChar(for: event(0x7E, "\u{F700}", "\u{F700}")))
        let keypad = KeyEncoder.key(for: event(0x57, "5", "5"))
        XCTAssertEqual(keypad.keyCode, VK.numpad0 + 5)
        XCTAssertEqual(keypad.location, .numpad)
        XCTAssertNil(KeyEncoder.keyChar(for: event(0x0E, "", "e", .option))) // dead key
        XCTAssertEqual(KeyEncoder.keyChar(for: event(0x0B, "∫", "b", .option)), "∫")
    }
}
