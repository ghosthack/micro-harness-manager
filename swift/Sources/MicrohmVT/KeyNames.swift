/**
 * Named keys → the bytes an xterm-compatible terminal sends for them, so a caller can press
 * keys without attaching (the `input` operation). Pure: no state beyond the
 * application-cursor-keys mode the caller passes in (DECCKM, `CSI ?1 h`), which switches the
 * arrows and Home/End from CSI to SS3 form exactly as a real terminal does.
 *
 * Grammar (names are case-insensitive):
 *  - a single character (any one code point: `1`, `y`, `/`, `é`) → its UTF-8 bytes;
 *  - `Enter` (CR), `Tab`, `BTab`/`S-Tab` (`CSI Z`), `Esc`/`Escape`, `Space`,
 *    `Backspace`/`BSpace` (DEL), `Delete`/`DC` (`CSI 3~`), `Insert`/`IC` (`CSI 2~`),
 *    `Up`/`Down`/`Right`/`Left`, `Home`/`End`, `PageUp`/`PgUp`/`PPage`,
 *    `PageDown`/`PgDn`/`NPage`, `F1`..`F12`;
 *  - `C-x`: control of a letter or one of `@[\]^_?` (`C-?` is DEL, `C-Space` and `C-@` are
 *    NUL);
 *  - `M-key`: ESC followed by the encoding of `key` (`M-b`, `M-Enter`, `M-C-x`).
 */
public enum KeyNames {

    /** Java's `IllegalArgumentException("unknown key: <k>")`. */
    public struct UnknownKey: Error, CustomStringConvertible, Equatable {
        public let key: String

        /** `"unknown key: <k>"`, the Java exception message. */
        public var message: String {
            return "unknown key: " + key
        }

        public var description: String {
            return message
        }

        public var localizedDescription: String {
            return message
        }
    }

    private static let ESC = "\u{1b}"
    private static let CSI = ESC + "["
    private static let SS3 = ESC + "O"

    /** Keys whose encoding does not depend on the cursor-key mode. */
    private static let FIXED: [String: String] = [
        "enter": "\r",
        "tab": "\t",
        "btab": CSI + "Z",
        "s-tab": CSI + "Z",
        "esc": ESC,
        "escape": ESC,
        "space": " ",
        "backspace": "\u{7f}",
        "bspace": "\u{7f}",
        "delete": CSI + "3~",
        "dc": CSI + "3~",
        "insert": CSI + "2~",
        "ic": CSI + "2~",
        "pageup": CSI + "5~",
        "pgup": CSI + "5~",
        "ppage": CSI + "5~",
        "pagedown": CSI + "6~",
        "pgdn": CSI + "6~",
        "npage": CSI + "6~",
        "f1": SS3 + "P",
        "f2": SS3 + "Q",
        "f3": SS3 + "R",
        "f4": SS3 + "S",
        "f5": CSI + "15~",
        "f6": CSI + "17~",
        "f7": CSI + "18~",
        "f8": CSI + "19~",
        "f9": CSI + "20~",
        "f10": CSI + "21~",
        "f11": CSI + "23~",
        "f12": CSI + "24~",
    ]

    /** Cursor keys: the final byte, after CSI (normal) or SS3 (application mode). */
    private static let CURSOR: [String: String] = [
        "up": "A", "down": "B", "right": "C", "left": "D", "home": "H", "end": "F",
    ]

    /** Every key of `keys` in order, concatenated. Throws `UnknownKey` (`"unknown key: <k>"`)
     * on the first bad name. */
    public static func encode(_ keys: [String], _ applicationCursorKeys: Bool) throws -> [UInt8] {
        var out: [UInt8] = []
        for key in keys {
            out.append(contentsOf: try encode(key, applicationCursorKeys).utf8)
        }
        return out
    }

    /** Labelled form of `encode(_:_:)`. */
    public static func encode(keys: [String], applicationCursorKeys: Bool) throws -> [UInt8] {
        return try encode(keys, applicationCursorKeys)
    }

    /** Java-style lower-casing (ASCII letters plus Unicode lowercase mapping). */
    private static func lower(_ s: String) -> String {
        return s.lowercased()
    }

    private static func encode(_ key: String, _ applicationCursorKeys: Bool) throws -> String {
        if key.isEmpty {
            throw UnknownKey(key: key)
        }
        let scalars = key.unicodeScalars
        if scalars.count == 1 {
            return key // a literal character, case preserved
        }
        let lowered = lower(key)
        if let fixed = FIXED[lowered] {
            return fixed
        }
        if let cursor = CURSOR[lowered] {
            return (applicationCursorKeys ? SS3 : CSI) + cursor
        }
        // Java's key.length() counts UTF-16 units; the prefixes are ASCII.
        let utf16Length = key.utf16.count
        if lowered.unicodeScalars.starts(with: "m-".unicodeScalars) && utf16Length > 2 {
            do {
                return ESC + (try encode(String(String.UnicodeScalarView(scalars.dropFirst(2))), applicationCursorKeys))
            } catch {
                throw UnknownKey(key: key)
            }
        }
        if lowered.unicodeScalars.starts(with: "c-".unicodeScalars) && utf16Length > 2 {
            let target = String(String.UnicodeScalarView(scalars.dropFirst(2)))
            if target.lowercased() == "space" {
                return "\0"
            }
            let t16 = Array(target.utf16)
            if t16.count == 1 {
                let c = t16[0]
                if c >= 0x61 && c <= 0x7A { // a-z
                    return String(UnicodeScalar(UInt8(c - 0x61 + 1)))
                }
                if c >= 0x41 && c <= 0x5A { // A-Z
                    return String(UnicodeScalar(UInt8(c - 0x41 + 1)))
                }
                if c == 0x3F { // ?
                    return "\u{7f}"
                }
                if "@[\\]^_".utf16.contains(c) {
                    return String(UnicodeScalar(UInt8(c - 0x40)))
                }
            }
        }
        throw UnknownKey(key: key)
    }
}
