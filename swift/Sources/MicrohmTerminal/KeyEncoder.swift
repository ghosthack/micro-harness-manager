import AppKit

/// Key codes the encoder works with: Java's `KeyEvent.VK_*` values, so the encoder and its
/// table tests port one to one. `KeyEncoder.key(for:)` maps an `NSEvent` onto them.
public enum VK {
    public static let enter = 0x0A
    public static let backSpace = 0x08
    public static let tab = 0x09
    public static let shift = 0x10
    public static let control = 0x11
    public static let alt = 0x12
    public static let escape = 0x1B
    public static let space = 0x20
    public static let pageUp = 0x21
    public static let pageDown = 0x22
    public static let end = 0x23
    public static let home = 0x24
    public static let left = 0x25
    public static let up = 0x26
    public static let right = 0x27
    public static let down = 0x28
    public static let comma = 0x2C
    public static let minus = 0x2D
    public static let period = 0x2E
    public static let slash = 0x2F
    public static let d0 = 0x30 // VK_0 … VK_9 are 0x30 … 0x39
    public static let d9 = 0x39
    public static let semicolon = 0x3B
    public static let equals = 0x3D
    public static let a = 0x41 // VK_A … VK_Z are 0x41 … 0x5A
    public static let z = 0x5A
    public static let openBracket = 0x5B
    public static let backSlash = 0x5C
    public static let closeBracket = 0x5D
    public static let numpad0 = 0x60 // VK_NUMPAD0 … 9 are 0x60 … 0x69
    public static let numpad9 = 0x69
    public static let multiply = 0x6A
    public static let add = 0x6B
    public static let separator = 0x6C
    public static let subtract = 0x6D
    public static let decimal = 0x6E
    public static let divide = 0x6F
    public static let f1 = 0x70 // VK_F1 … VK_F12 are 0x70 … 0x7B
    public static let f12 = 0x7B
    public static let delete = 0x7F
    public static let insert = 0x9B
    public static let backQuote = 0xC0
    public static let quote = 0xDE
    public static let kpUp = 0xE0
    public static let kpDown = 0xE1
    public static let kpLeft = 0xE2
    public static let kpRight = 0xE3
    public static let at = 0x200
    public static let circumflex = 0x202
    public static let underscore = 0x20B
    /// No key code (a key the encoder has no name for).
    public static let undefined = 0

    public static func letter(_ c: Character) -> Int {
        return a + Int(c.asciiValue! - 97)
    }

    public static func digit(_ n: Int) -> Int {
        return d0 + n
    }

    public static func f(_ n: Int) -> Int {
        return f1 + n - 1
    }
}

/// Key presses → the bytes xterm sends for them. Pure, so the whole table is unit-tested.
/// `pressed` handles every key that does not produce a plain character — and the Ctrl/Alt
/// chords that would otherwise type one — and returns nil for the rest, which then arrive as
/// typed text (`typed`, or the input method's `insertText`).
///
/// - Enter → CR (CR LF in newline mode, LNM); Backspace → DEL, Ctrl+Backspace → BS;
///   Tab, Shift+Tab → `CSI Z`; Esc.
/// - Arrows, Home, End: `CSI X`, or SS3 in application cursor mode (DECCKM); with
///   modifiers always `CSI 1 ; m X` (m = 1 + Shift 1 + Alt 2 + Ctrl 4).
/// - Insert/Delete/PageUp/PageDown: `CSI n ~` / `CSI n ; m ~`.
/// - F1–F4: SS3 P–S (`CSI 1 ; m P–S` with modifiers); F5–F12: `CSI 15~` … `CSI 24~`.
/// - Ctrl+letter → C0; Ctrl+Space/@/2 → NUL; Ctrl+[ \ ] ^ _ (and Ctrl+6, Ctrl+-, Ctrl+/) →
///   ESC, FS, GS, RS, US.
/// - Alt as Meta: an ESC prefix on the key's own encoding. On macOS Option normally
///   composes characters (Option+e is a dead acute, Option+a "å"); here Option+letter and
///   Option+digit are Meta instead — the chords agents and shells bind (word motion,
///   Option+Enter for a newline) — *unless* the keyboard layout composes a plain ASCII
///   character on that chord (Option+L is "@" on German layouts), which is typed as usual.
///   Option with punctuation still composes. Option+Left/Right send `ESC b` / `ESC f` (word
///   motion), as Terminal.app and iTerm2 do. The trade-off: an Option+dead-key chord
///   (Option+e, u, i, n, `) is Meta, so it cannot also start an accent. With
///   Option-as-Meta off (`Modes.optionAsMeta`) every Option+character chord composes
///   natively instead; Option with Enter, Backspace, Tab, Escape and the arrows keeps its
///   encoding either way.
/// - Keypad digits and operators send SS3 codes in application keypad mode (DECKPAM).
///
/// The Cmd key never reaches the program: chords with it return nil so the window's
/// shortcuts see them. Shift+Enter is plain CR (Option+Enter, `ESC CR`, is the chord agents
/// such as Claude Code take as "insert newline").
public enum KeyEncoder {

    /// Terminal modes the encoding depends on. `optionAsMeta` (macOS only) chooses whether
    /// Option+letter/digit is Meta or composes; see the type documentation.
    public struct Modes: Equatable, Sendable {
        public var applicationCursorKeys: Bool
        public var applicationKeypad: Bool
        public var newLineMode: Bool
        public var mac: Bool
        public var optionAsMeta: Bool

        public init(_ applicationCursorKeys: Bool, _ applicationKeypad: Bool, _ newLineMode: Bool,
                    _ mac: Bool, _ optionAsMeta: Bool = true) {
            self.applicationCursorKeys = applicationCursorKeys
            self.applicationKeypad = applicationKeypad
            self.newLineMode = newLineMode
            self.mac = mac
            self.optionAsMeta = optionAsMeta
        }
    }

    /// Modifier keys held (Java's modifiersEx bits): `meta` is Cmd, `alt` is Option.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let ctrl = Modifiers(rawValue: 2)
        public static let meta = Modifiers(rawValue: 4)
        public static let alt = Modifiers(rawValue: 8)
        public static let altGraph = Modifiers(rawValue: 16)

        public init(_ flags: NSEvent.ModifierFlags) {
            var m: Modifiers = []
            if flags.contains(.shift) { m.insert(.shift) }
            if flags.contains(.control) { m.insert(.ctrl) }
            if flags.contains(.command) { m.insert(.meta) }
            if flags.contains(.option) { m.insert(.alt) }
            self = m
        }
    }

    public enum Location: Sendable {
        case standard
        case numpad
    }

    private static let esc = "\u{1b}"
    private static let csi = esc + "["
    private static let ss3 = esc + "O"

    /// The bytes for a key press, or nil when the press sends nothing by itself (a plain
    /// character — see `typed` — a lone modifier, or a Cmd chord).
    ///
    /// - Parameters:
    ///   - keyCode: a `VK` code
    ///   - keyChar: what the layout composes for the press (`NSEvent.characters`), nil for
    ///     none (a dead key, a function key)
    public static func pressed(_ keyCode: Int, location: Location = .standard, keyChar: Unicode.Scalar?,
                               modifiers: Modifiers, modes: Modes) -> [UInt8]? {
        guard let s = pressedString(keyCode, location, keyChar, modifiers, modes) else {
            return nil
        }
        return Array(s.utf8)
    }

    /// The bytes for a typed character the press did not already send, or nil.
    public static func typed(_ c: Unicode.Scalar?, modifiers: Modifiers) -> [UInt8]? {
        guard let c = c, !modifiers.contains(.meta) else {
            return nil
        }
        if c.value < 0x20 || c.value == 0x7F {
            // Control characters the press handler did not map (e.g. Ctrl+letter on a
            // layout whose key codes are not Latin) still reach the program as typed.
            return modifiers.contains(.ctrl) ? [UInt8(c.value)] : nil
        }
        return Array(String(Character(c)).utf8)
    }

    private static func pressedString(_ keyCode: Int, _ location: Location, _ keyChar: Unicode.Scalar?,
                                      _ modifiers: Modifiers, _ modes: Modes) -> String? {
        if modifiers.contains(.meta) {
            return nil
        }
        let shift = modifiers.contains(.shift)
        let altGraph = modifiers.contains(.altGraph)
        let alt = modifiers.contains(.alt) && !altGraph
        let ctrl = modifiers.contains(.ctrl) && !altGraph
        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        let meta = alt ? esc : ""

        if location == .numpad && modes.applicationKeypad && mod == 1, let k = keypad(keyCode) {
            return ss3 + k
        }
        switch keyCode {
        case VK.enter:
            return meta + (modes.newLineMode ? "\r\n" : "\r")
        case VK.backSpace:
            return meta + (ctrl ? "\u{8}" : "\u{7f}")
        case VK.tab:
            return shift ? csi + "Z" : meta + "\t"
        case VK.escape:
            return meta + esc
        case VK.up, VK.kpUp:
            return cursor("A", mod, modes)
        case VK.down, VK.kpDown:
            return cursor("B", mod, modes)
        case VK.right, VK.kpRight:
            if modes.mac && mod == 3 {
                return esc + "f"
            }
            return cursor("C", mod, modes)
        case VK.left, VK.kpLeft:
            if modes.mac && mod == 3 {
                return esc + "b"
            }
            return cursor("D", mod, modes)
        case VK.home:
            return cursor("H", mod, modes)
        case VK.end:
            return cursor("F", mod, modes)
        case VK.insert:
            return tilde(2, mod)
        case VK.delete:
            return tilde(3, mod)
        case VK.pageUp:
            return tilde(5, mod)
        case VK.pageDown:
            return tilde(6, mod)
        case VK.f1...(VK.f1 + 3):
            let fin = String(UnicodeScalar(UInt8(0x50 + keyCode - VK.f1)))
            return mod == 1 ? ss3 + fin : csi + "1;" + String(mod) + fin
        case VK.f1 + 4:
            return tilde(15, mod)
        case VK.f1 + 5:
            return tilde(17, mod)
        case VK.f1 + 6:
            return tilde(18, mod)
        case VK.f1 + 7:
            return tilde(19, mod)
        case VK.f1 + 8:
            return tilde(20, mod)
        case VK.f1 + 9:
            return tilde(21, mod)
        case VK.f1 + 10:
            return tilde(23, mod)
        case VK.f1 + 11:
            return tilde(24, mod)
        default:
            break
        }
        if ctrl {
            guard let control = control(keyCode) else {
                return nil
            }
            return meta + control
        }
        if alt {
            return altChord(keyCode, keyChar, shift, modes.mac, modes.optionAsMeta)
        }
        return nil
    }

    private static func cursor(_ fin: String, _ mod: Int, _ modes: Modes) -> String {
        if mod > 1 {
            return csi + "1;" + String(mod) + fin
        }
        return (modes.applicationCursorKeys ? ss3 : csi) + fin
    }

    private static func tilde(_ code: Int, _ mod: Int) -> String {
        return mod > 1 ? csi + String(code) + ";" + String(mod) + "~" : csi + String(code) + "~"
    }

    /// Ctrl+key → its C0 control, or nil for a key with none.
    private static func control(_ keyCode: Int) -> String? {
        if keyCode >= VK.a && keyCode <= VK.z {
            return String(UnicodeScalar(UInt8(keyCode - VK.a + 1)))
        }
        switch keyCode {
        case VK.space, VK.d0 + 2, VK.at: return "\u{0}"
        case VK.openBracket: return esc
        case VK.backSlash: return "\u{1c}"
        case VK.closeBracket: return "\u{1d}"
        case VK.d0 + 6, VK.circumflex: return "\u{1e}"
        case VK.minus, VK.underscore, VK.slash: return "\u{1f}"
        default: return nil
        }
    }

    /// Alt (Option) without Ctrl: ESC + the key's character. On macOS only letters and digits
    /// are Meta, and only when the layout does not compose a plain ASCII character on the
    /// chord (see the type documentation); elsewhere any printable character is.
    private static func altChord(_ keyCode: Int, _ keyChar: Unicode.Scalar?, _ shift: Bool, _ mac: Bool,
                                 _ optionAsMeta: Bool) -> String? {
        let letter = keyCode >= VK.a && keyCode <= VK.z
        let digit = keyCode >= VK.d0 && keyCode <= VK.d9
        if mac {
            if !optionAsMeta {
                return nil // Option composes everything (é, å, ©), as macOS does natively
            }
            if !letter && !digit {
                return nil // Option+punctuation composes (typed)
            }
            let base: Unicode.Scalar = letter
                ? UnicodeScalar(UInt8((shift ? 0x41 : 0x61) + keyCode - VK.a))
                : UnicodeScalar(UInt8(0x30 + keyCode - VK.d0))
            var composesAscii = false
            if let k = keyChar, k.value >= 0x20, k.value < 0x7F {
                composesAscii = lower(k) != lower(base)
            }
            if composesAscii || (digit && shift) {
                return nil // a layout character (German Option+L = '@'), typed as usual
            }
            return esc + String(Character(base))
        }
        if let k = keyChar, k.value >= 0x20, k.value != 0x7F {
            return esc + String(Character(k))
        }
        if letter {
            return esc + String(UnicodeScalar(UInt8((shift ? 0x41 : 0x61) + keyCode - VK.a)))
        }
        return nil
    }

    private static func lower(_ s: Unicode.Scalar) -> UInt32 {
        return s.value >= 0x41 && s.value <= 0x5A ? s.value + 32 : s.value
    }

    /// DECKPAM keypad: the SS3 final for a keypad key, or nil.
    private static func keypad(_ keyCode: Int) -> String? {
        if keyCode >= VK.numpad0 && keyCode <= VK.numpad9 {
            return String(UnicodeScalar(UInt8(0x70 + keyCode - VK.numpad0)))
        }
        switch keyCode {
        case VK.enter: return "M"
        case VK.multiply: return "j"
        case VK.add: return "k"
        case VK.separator: return "l"
        case VK.subtract: return "m"
        case VK.decimal: return "n"
        case VK.divide: return "o"
        default: return nil
        }
    }

    // MARK: - NSEvent → VK

    /// Mac virtual key codes (Carbon `kVK_*`) of the keys that are not characters, and of the
    /// keypad, to VK codes.
    private static let namedKeys: [UInt16: (Int, Location)] = [
        0x24: (VK.enter, .standard), 0x4C: (VK.enter, .numpad), 0x30: (VK.tab, .standard),
        0x31: (VK.space, .standard), 0x33: (VK.backSpace, .standard), 0x35: (VK.escape, .standard),
        0x75: (VK.delete, .standard), 0x72: (VK.insert, .standard), // Help is where Insert is
        0x73: (VK.home, .standard), 0x77: (VK.end, .standard), 0x74: (VK.pageUp, .standard),
        0x79: (VK.pageDown, .standard), 0x7B: (VK.left, .standard), 0x7C: (VK.right, .standard),
        0x7D: (VK.down, .standard), 0x7E: (VK.up, .standard),
        0x7A: (VK.f1, .standard), 0x78: (VK.f1 + 1, .standard), 0x63: (VK.f1 + 2, .standard),
        0x76: (VK.f1 + 3, .standard), 0x60: (VK.f1 + 4, .standard), 0x61: (VK.f1 + 5, .standard),
        0x62: (VK.f1 + 6, .standard), 0x64: (VK.f1 + 7, .standard), 0x65: (VK.f1 + 8, .standard),
        0x6D: (VK.f1 + 9, .standard), 0x67: (VK.f1 + 10, .standard), 0x6F: (VK.f1 + 11, .standard),
        0x52: (VK.numpad0, .numpad), 0x53: (VK.numpad0 + 1, .numpad), 0x54: (VK.numpad0 + 2, .numpad),
        0x55: (VK.numpad0 + 3, .numpad), 0x56: (VK.numpad0 + 4, .numpad), 0x57: (VK.numpad0 + 5, .numpad),
        0x58: (VK.numpad0 + 6, .numpad), 0x59: (VK.numpad0 + 7, .numpad), 0x5B: (VK.numpad0 + 8, .numpad),
        0x5C: (VK.numpad0 + 9, .numpad), 0x41: (VK.decimal, .numpad), 0x43: (VK.multiply, .numpad),
        0x45: (VK.add, .numpad), 0x4E: (VK.subtract, .numpad), 0x4B: (VK.divide, .numpad),
        0x51: (VK.equals, .numpad),
    ]

    /// ANSI positions of the character keys, for layouts whose characters are not Latin
    /// (Ctrl+C on a Cyrillic layout is still the C key).
    private static let ansiKeys: [UInt16: Int] = [
        0x00: VK.letter("a"), 0x0B: VK.letter("b"), 0x08: VK.letter("c"), 0x02: VK.letter("d"),
        0x0E: VK.letter("e"), 0x03: VK.letter("f"), 0x05: VK.letter("g"), 0x04: VK.letter("h"),
        0x22: VK.letter("i"), 0x26: VK.letter("j"), 0x28: VK.letter("k"), 0x25: VK.letter("l"),
        0x2E: VK.letter("m"), 0x2D: VK.letter("n"), 0x1F: VK.letter("o"), 0x23: VK.letter("p"),
        0x0C: VK.letter("q"), 0x0F: VK.letter("r"), 0x01: VK.letter("s"), 0x11: VK.letter("t"),
        0x20: VK.letter("u"), 0x09: VK.letter("v"), 0x0D: VK.letter("w"), 0x07: VK.letter("x"),
        0x10: VK.letter("y"), 0x06: VK.letter("z"),
        0x1D: VK.digit(0), 0x12: VK.digit(1), 0x13: VK.digit(2), 0x14: VK.digit(3), 0x15: VK.digit(4),
        0x17: VK.digit(5), 0x16: VK.digit(6), 0x1A: VK.digit(7), 0x1C: VK.digit(8), 0x19: VK.digit(9),
        0x1B: VK.minus, 0x18: VK.equals, 0x21: VK.openBracket, 0x1E: VK.closeBracket,
        0x2A: VK.backSlash, 0x29: VK.semicolon, 0x27: VK.quote, 0x2B: VK.comma, 0x2F: VK.period,
        0x2C: VK.slash, 0x32: VK.backQuote,
    ]

    /// The VK code of an ASCII character the layout puts on a key (unshifted).
    private static func vk(forAscii c: Unicode.Scalar) -> Int? {
        switch c.value {
        case 0x61...0x7A: return VK.a + Int(c.value) - 0x61
        case 0x41...0x5A: return VK.a + Int(c.value) - 0x41
        case 0x30...0x39: return VK.d0 + Int(c.value) - 0x30
        case 0x2D: return VK.minus
        case 0x3D: return VK.equals
        case 0x5B: return VK.openBracket
        case 0x5D: return VK.closeBracket
        case 0x5C: return VK.backSlash
        case 0x3B: return VK.semicolon
        case 0x27: return VK.quote
        case 0x2C: return VK.comma
        case 0x2E: return VK.period
        case 0x2F: return VK.slash
        case 0x60: return VK.backQuote
        case 0x40: return VK.at
        case 0x5E: return VK.circumflex
        case 0x5F: return VK.underscore
        default: return nil
        }
    }

    /// The VK code and location of a key event. Character keys follow the layout (Dvorak's
    /// C key is where it types "c"), falling back to the ANSI position where the layout's
    /// character is not ASCII.
    public static func key(for event: NSEvent) -> (keyCode: Int, location: Location) {
        if let named = namedKeys[event.keyCode] {
            return named
        }
        if let chars = event.charactersIgnoringModifiers, chars.unicodeScalars.count == 1,
           let vk = vk(forAscii: chars.unicodeScalars.first!) {
            return (vk, .standard)
        }
        return (ansiKeys[event.keyCode] ?? VK.undefined, .standard)
    }

    /// What the layout composes for the press (`characters`), nil for none (a dead key).
    public static func keyChar(for event: NSEvent) -> Unicode.Scalar? {
        guard let chars = event.characters, chars.unicodeScalars.count == 1 else {
            return nil
        }
        let s = chars.unicodeScalars.first!
        // AppKit's function-key range (arrows, F-keys) is not a character
        return (0xF700...0xF8FF).contains(s.value) ? nil : s
    }
}
