import AppKit
import MicrohmVT

/// Mouse events → xterm mouse reports, per the program's tracking mode and encoding. Pure.
///
/// Buttons: 0 left, 1 middle, 2 right, `wheelUp` 64 / `wheelDown` 65. Which events are
/// reported: X10 (9) presses only, without modifiers; NORMAL (1000) presses and releases;
/// BUTTON_MOTION (1002) also motion with a button held; ANY_MOTION (1003) all motion. Wheel
/// notches are presses with no release. Motion adds 32 to the button code (button 3 when
/// none is held); modifiers add Shift 4, Alt/Meta 8, Ctrl 16.
///
/// Encodings: DEFAULT `CSI M Cb Cx Cy` as single bytes offset by 32, coordinates clamped to
/// 223; UTF8 (1005) the same values as UTF-8 characters, clamped to 2015; SGR (1006)
/// `CSI < b ; x ; y M`, or `m` for a release, which keeps the button; URXVT (1015)
/// `CSI b+32 ; x ; y M`. Releases in every encoding but SGR are button 3.
public enum MouseEncoder {

    public static let left = 0
    public static let middle = 1
    public static let right = 2
    public static let wheelUp = 64
    public static let wheelDown = 65
    /// Motion with no button held.
    public static let none = 3

    public enum Action: CaseIterable, Sendable {
        case press, release, drag, move
    }

    /// Modifier bits.
    public static let shift = 4
    public static let meta = 8
    public static let ctrl = 16

    /// The report for one event, or nil when the mode does not report it.
    ///
    /// - Parameters:
    ///   - column: 0-based cell column
    ///   - row: 0-based cell row
    ///   - mods: `shift` | `meta` | `ctrl`
    public static func encode(_ tracking: TerminalEmulator.MouseTracking, _ encoding: TerminalEmulator.MouseEncoding,
                              _ action: Action, _ button: Int, _ column: Int, _ row: Int, _ mods: Int) -> [UInt8]? {
        let wheel = button >= wheelUp
        let reported: Bool
        switch tracking {
        case .none: reported = false
        case .x10: reported = action == .press
        case .normal: reported = action == .press || (action == .release && !wheel)
        case .buttonMotion: reported = action != .move && !(action == .release && wheel)
        case .anyMotion: reported = !(action == .release && wheel)
        }
        if !reported {
            return nil
        }
        var code: Int
        switch action {
        case .press: code = button
        case .release: code = encoding == .sgr ? button : 3
        case .drag: code = button + 32
        case .move: code = none + 32
        }
        if tracking != .x10 {
            code |= mods & (shift | meta | ctrl)
        }
        let x = max(0, column) + 1
        let y = max(0, row) + 1
        switch encoding {
        case .sgr:
            return Array("\u{1b}[<\(code);\(x);\(y)\(action == .release ? "m" : "M")".utf8)
        case .urxvt:
            return Array("\u{1b}[\(code + 32);\(x);\(y)M".utf8)
        case .`default`:
            return [0x1b, 0x5B, 0x4D, UInt8(truncatingIfNeeded: code + 32),
                    UInt8(min(x, 223) + 32), UInt8(min(y, 223) + 32)]
        case .utf8:
            var out: [UInt8] = [0x1b, 0x5B, 0x4D]
            utf8(&out, code + 32)
            utf8(&out, min(x, 2015) + 32)
            utf8(&out, min(y, 2015) + 32)
            return out
        }
    }

    /// Modifier bits from an event's modifier flags (Option is Meta).
    public static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var mods = 0
        if flags.contains(.shift) {
            mods |= shift
        }
        if flags.contains(.option) {
            mods |= meta
        }
        if flags.contains(.control) {
            mods |= ctrl
        }
        return mods
    }

    private static func utf8(_ out: inout [UInt8], _ value: Int) {
        if value < 0x80 {
            out.append(UInt8(value))
        } else {
            out.append(UInt8(0xC0 | (value >> 6)))
            out.append(UInt8(0x80 | (value & 0x3F)))
        }
    }
}
