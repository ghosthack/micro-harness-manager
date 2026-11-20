/**
 * Tracks, from the token stream alone, the terminal modes a session cares about: DEC private
 * modes set/reset with `CSI ? Pm h/l` (1 cursor keys, 6 origin, 7 autowrap, 25 cursor visible,
 * 1000/1002/1003 mouse tracking, 1004 focus, 1006 SGR mouse, 1049/47/1047 alternate screen,
 * 2004 bracketed paste), DECSCUSR (`CSI Ps SP q`), DECKPAM/DECKPNM (`ESC =` / `ESC >`),
 * DECSTBM, the OSC 0/1/2 title, the OSC 7 / OSC 9;9 working directory, and RIS (`ESC c`), which
 * resets the modes. Pure: no I/O, no threads; feed it every token the emulator gets, in order.
 *
 * `HeadlessTerminal` uses it for the working directory, which the emulator does not keep; for
 * everything else `TerminalEmulator` is authoritative and the two agree (ModeTrackerTest
 * cross-checks them). Like the emulator (and xterm), a resize resets the scroll region to the
 * full screen: feed resizes through `resized(_:)`.
 */
public final class ModeTracker {

    private var rows: Int

    private var applicationCursorKeys = false // DEC 1
    private var originMode = false            // DEC 6
    private var autoWrap = true               // DEC 7 (default on)
    private var cursorVisible = true          // DEC 25 (default on)
    private var mouseTrackingMode = 0         // 1000 / 1002 / 1003, 0 = none
    private var mouseSgr = false              // DEC 1006
    private var focusReporting = false        // DEC 1004
    private var alternateScreen = false       // DEC 47 / 1047 / 1049
    private var bracketedPaste = false        // DEC 2004
    private var applicationKeypad = false     // DECKPAM / DECKPNM
    private var cursorShape = 0               // DECSCUSR 0..6, 0 = default

    private var scrollTop = 1                 // 1-based
    private var scrollBottom: Int             // 1-based; initialised to rows

    private var title = ""
    private var _reportedCwd: String?         // nil until reported

    init(_ rows: Int) {
        self.rows = rows
        self.scrollBottom = rows
    }

    public func observe(_ token: VtToken) {
        switch token.kind {
        case .csi: observeCsi(token)
        case .escape: observeEscape(token.bytes)
        case .osc: observeOsc(token.bytes)
        default: break
        }
    }

    /** Looks at the final byte first, so the body is only decoded for the few finals tracked
     * here (every other CSI — cursor motion, SGR, erase — costs nothing). */
    private func observeCsi(_ token: VtToken) {
        let finalByte = token.csiFinalByte()
        switch finalByte {
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            observeDecPrivateModes(token.bytes, finalByte == UInt8(ascii: "h"))
        case UInt8(ascii: "q"):
            // DECSCUSR: CSI Ps SP q. Ignore XTVERSION (CSI > q).
            let body = token.csiBody()
            if !body.hasPrefix(">") {
                let ps = ModeTracker.leadingInt(body)
                cursorShape = ps == 0 ? 1 : ps // 0 and 1 both mean a blinking block
            }
        case UInt8(ascii: "r"):
            // DECSTBM: CSI t;b r. CSI ? ... r is "restore DEC private modes" — not us.
            let body = token.csiBody()
            if !body.hasPrefix("?") {
                setScrollingRegion(body)
            }
        default:
            break
        }
    }

    /** `CSI ? Pm h/l` straight from the token bytes (`ESC [ ? Pm final`): each ';'-separated
     * parameter that is a non-empty run of digits fitting an int is applied; anything else
     * (empty, other characters, overflow) is skipped. A body not starting with '?' is not a
     * DEC private mode set/reset. */
    private func observeDecPrivateModes(_ bytes: [UInt8], _ set: Bool) {
        let end = bytes.count - 1 // the final byte
        if end < 3 || bytes[2] != UInt8(ascii: "?") {
            return
        }
        var i = 3
        while true {
            var value: Int64 = 0
            var digits = false
            var valid = true
            while i < end && bytes[i] != UInt8(ascii: ";") {
                let b = bytes[i]
                if b >= 0x30 && b <= 0x39 {
                    digits = true
                    if valid {
                        value = value * 10 + Int64(b - 0x30)
                        if value > Int64(Int32.max) {
                            valid = false
                        }
                    }
                } else {
                    valid = false
                }
                i += 1
            }
            if digits && valid {
                applyDecPrivateMode(Int(value), set)
            }
            if i >= end {
                return
            }
            i += 1 // past ';'
        }
    }

    private func applyDecPrivateMode(_ mode: Int, _ set: Bool) {
        switch mode {
        case 1: applicationCursorKeys = set
        case 6: originMode = set
        case 7: autoWrap = set
        case 25: cursorVisible = set
        case 1000: mouseTrackingMode = set ? 1000 : 0
        case 1002: mouseTrackingMode = set ? 1002 : 0
        case 1003: mouseTrackingMode = set ? 1003 : 0
        case 1004: focusReporting = set
        case 1006: mouseSgr = set
        case 47, 1047, 1049: alternateScreen = set
        case 2004: bracketedPaste = set
        default: break
        }
    }

    private func setScrollingRegion(_ body: String) {
        let parts = ModeTracker.split(body, ";")
        var top = parts.count > 0 && !parts[0].isEmpty ? ModeTracker.leadingInt(parts[0]) : 1
        var bottom = parts.count > 1 && !parts[1].isEmpty ? ModeTracker.leadingInt(parts[1]) : rows
        if top == 0 {
            top = 1
        }
        if bottom == 0 {
            bottom = rows
        }
        bottom = min(rows, bottom)
        if top >= bottom {
            return // ignored, as by the emulator (and xterm): fewer than two lines
        }
        scrollTop = top
        scrollBottom = bottom
    }

    private func observeEscape(_ bytes: [UInt8]) {
        if bytes.count == 2 && bytes[0] == 0x1B {
            switch bytes[1] {
            case UInt8(ascii: "c"): reset()                    // RIS
            case UInt8(ascii: "="): applicationKeypad = true   // DECKPAM
            case UInt8(ascii: ">"): applicationKeypad = false  // DECKPNM
            default: break
            }
        }
    }

    private func observeOsc(_ bytes: [UInt8]) {
        let body = ModeTracker.oscBody(bytes)
        let args = ModeTracker.split(body, ";")
        guard let ps = ModeTracker.parseIntOrNull(args[0]) else {
            return
        }
        switch ps {
        case 0, 1, 2:
            // Icon name / window title: the emulator sets the title for all three.
            if args.count > 1 {
                title = args[1]
            }
        case 7:
            if args.count > 1 {
                _reportedCwd = ModeTracker.decodeFileUri(args[1])
            }
        case 9:
            // OSC 9 ; 9 ; <path> — iTerm2 current-directory report.
            if args.count > 2 && args[1].unicodeScalars.elementsEqual("9".unicodeScalars) {
                _reportedCwd = args[2]
            }
        default:
            break
        }
    }

    /** RIS: reset the tracked modes to their power-on defaults. Title and cwd are display state
     * (the emulator's RIS keeps the title too), so they are left untouched. */
    private func reset() {
        applicationCursorKeys = false
        originMode = false
        autoWrap = true
        cursorVisible = true
        mouseTrackingMode = 0
        mouseSgr = false
        focusReporting = false
        alternateScreen = false
        bracketedPaste = false
        applicationKeypad = false
        cursorShape = 0
        scrollTop = 1
        scrollBottom = rows
    }

    /** Applies a resize to `newRows`: the scroll region becomes the full screen. */
    func resized(_ newRows: Int) {
        rows = newRows
        scrollTop = 1
        scrollBottom = newRows
    }

    public func snapshot() -> HeadlessTerminal.Modes {
        return HeadlessTerminal.Modes(cursorVisible: cursorVisible, cursorShape: cursorShape,
                                      bracketedPaste: bracketedPaste, applicationCursorKeys: applicationCursorKeys,
                                      applicationKeypad: applicationKeypad, mouseTrackingMode: mouseTrackingMode,
                                      mouseSgr: mouseSgr, focusReporting: focusReporting,
                                      alternateScreen: alternateScreen, autoWrap: autoWrap, originMode: originMode,
                                      scrollTop: scrollTop, scrollBottom: scrollBottom, title: title)
    }

    /** OSC 7 `file://host/path` → decoded path, or nil if never reported. */
    public func reportedCwd() -> String? {
        return _reportedCwd
    }

    // --- parsing helpers -------------------------------------------------------------

    /** Java's `s.split(sep, -1)` for a one-character literal separator. */
    static func split(_ s: String, _ sep: Unicode.Scalar) -> [String] {
        // On scalars, not Characters: a separator followed by a combining mark still splits.
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if c == sep {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(c)
            }
        }
        parts.append(String(current))
        return parts
    }

    private static func oscBody(_ bytes: [UInt8]) -> String {
        // bytes = ESC ] <body> <terminator>; terminator is BEL or ESC \.
        let start = 2
        var end = bytes.count
        if end > start && bytes[end - 1] == 0x07 { // BEL
            end -= 1
        } else if end > start + 1 && bytes[end - 2] == 0x1B && bytes[end - 1] == UInt8(ascii: "\\") {
            end -= 2 // ESC \
        }
        if end < start {
            end = start
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func decodeFileUri(_ value: String) -> String {
        // file://host/path -> /path (host dropped), percent-decoded.
        var rest = value
        if rest.hasPrefix("file://") {
            let scalars = rest.unicodeScalars.dropFirst(7)
            if let slash = scalars.firstIndex(of: "/") {
                rest = String(String.UnicodeScalarView(scalars[slash...]))
            } else {
                rest = ""
            }
        }
        return percentDecode(rest)
    }

    private static func hexDigit(_ c: Unicode.Scalar) -> Int {
        switch c.value {
        case 0x30...0x39: return Int(c.value - 0x30)
        case 0x41...0x46: return Int(c.value - 0x41 + 10)
        case 0x61...0x66: return Int(c.value - 0x61 + 10)
        default: return -1
        }
    }

    private static func percentDecode(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "%" && i + 2 < scalars.count {
                let hi = hexDigit(scalars[i + 1])
                let lo = hexDigit(scalars[i + 2])
                if hi >= 0 && lo >= 0 {
                    bytes.append(UInt8((hi << 4) | lo))
                    i += 3
                    continue
                }
            }
            bytes.append(contentsOf: String(c).utf8)
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseIntOrNull(_ s: String) -> Int? {
        if s.isEmpty {
            return nil
        }
        for c in s.unicodeScalars where c.value < 0x30 || c.value > 0x39 {
            return nil
        }
        guard let v = Int32(s) else {
            return nil
        }
        return Int(v)
    }

    /** Leading decimal digits as an `int`, overflowing as Java's does. */
    private static func leadingInt(_ s: String) -> Int {
        var value: Int32 = 0
        for c in s.unicodeScalars {
            guard c.value >= 0x30 && c.value <= 0x39 else {
                break
            }
            value = value &* 10 &+ Int32(c.value - 0x30)
        }
        return Int(value)
    }
}
