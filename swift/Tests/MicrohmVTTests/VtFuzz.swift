@testable import MicrohmVT

/**
 * Port of the Java VtFuzz: a seeded generator of mixed text / CSI / SGR / scroll-region /
 * alternate-screen operations, reading the emulator's state between operations. It must draw
 * from `JavaRandom` in exactly the Java order, or the fuzz goldens diverge. In `.common` mode
 * it avoids the situations where jediterm-core (the reference the goldens were checked
 * against) behaves differently (see KnownDifferencesTests); `.any` drops those restrictions.
 */
final class VtFuzz {

    enum Mode { case common, any }

    private static let NARROW = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:-+=*/#!?()[]{}<>|'\"%&@$^~`".unicodeScalars)
    private static let EXTRA_NARROW = ["é", "ü", "ñ", "ß", "─", "│", "┌", "λ", "Ж", "€", "«", "»"]
    private static let WIDE = ["中", "文", "字", "日", "本", "語", "한", "가", "Ｗ", "⌚"]
    private static let SUPPLEMENTARY = ["🛑", "🚀", "😀", "\u{1F44D}\u{1F3FD}", "\u{1F1FA}\u{1F1F8}", "\u{1F469}\u{200D}\u{1F4BB}", "𝐀"]
    private static let COMBINING = ["e\u{301}", "a\u{308}", "n\u{303}", "x\u{301}\u{302}", "\u{200D}", "\u{FE0F}"]

    private var rnd: JavaRandom
    private let state: TerminalEmulator
    private let mode: Mode

    init(_ seed: Int64, _ state: TerminalEmulator, _ mode: Mode) {
        rnd = JavaRandom(seed)
        self.state = state
        self.mode = mode
    }

    /** The next operation's bytes, chosen for the emulator's current state. */
    func next() -> String {
        while true {
            if let op = tryNext() {
                return op
            }
        }
    }

    private func common() -> Bool {
        return mode == .common
    }

    private func regionActive() -> Bool {
        return state.scrollTop() != 0 || state.scrollBottom() != state.rows() - 1
    }

    /** "\r" when a wrap is pending and the next operation is one jediterm treats differently. */
    private func settle() -> String {
        return common() && state.cursorPendingWrap() ? "\r" : ""
    }

    private func letter(_ s: String, _ i: Int) -> String {
        return String(Array(s)[i])
    }

    private func tryNext() -> String? {
        let rows = state.rows()
        let cols = state.columns()
        let pick = rnd.nextInt(100)
        if pick < 30 {
            return text()
        }
        if pick < 38 {
            return sgr()
        }
        if pick < 44 {
            return rnd.nextBoolean() ? "\r\n" : settle() + "\n"
        }
        if pick < 50 {
            let r = 1 + rnd.nextInt(rows + 2)
            let c = 1 + rnd.nextInt(cols + 2)
            return C + "\(r);\(c)H"
        }
        if pick < 54 {
            if common() && state.originMode() {
                return nil // jediterm's CHA re-applies the origin offset to the row
            }
            let c = 1 + rnd.nextInt(cols)
            return C + "\(c)" + (rnd.nextBoolean() ? "G" : "`")
        }
        if pick < 58 {
            if common() && state.originMode() {
                return nil
            }
            let s = settle()
            return s + C + "\(1 + rnd.nextInt(rows))d"
        }
        if pick < 62 {
            let f = letter("ABCDEF", rnd.nextInt(6))
            let vertical = f != "C" && f != "D"
            if common() && vertical && regionActive() && !state.originMode() {
                return nil
            }
            if common() && (f == "E" || f == "F") && state.originMode() {
                return nil // CNL/CPL end in jediterm's CHA, which re-applies the origin offset
            }
            let s = settle()
            let n = rnd.nextInt(4) == 0 ? "" : String(rnd.nextInt(cols))
            return s + C + n + f
        }
        if pick < 64 {
            if common() && (state.cursorPendingWrap() || state.cursorColumn() == 0) {
                return nil
            }
            return "\u{8}"
        }
        if pick < 66 {
            if common() && colouredBlankBeforeTab() {
                return nil // jediterm's tab overwrites blank cells with spaces in the pen
            }
            return settle() + (common() ? C + "0m" : "") + "\t"
        }
        if pick < 70 {
            let s = settle() + plainBackground()
            return s + C + "\(rnd.nextInt(3))K"
        }
        if pick < 72 {
            // ED 1: jediterm also clears the rest of the cursor row (an off-by-one).
            let s = settle() + plainBackground()
            let n = common() ? 2 * rnd.nextInt(2) : rnd.nextInt(3)
            return s + C + "\(n)J"
        }
        if pick < 75 {
            let f = letter("@PX", rnd.nextInt(3))
            // jediterm fills ICH/DCH blanks at the end of the written text, not the margin.
            let pen = common() && f != "X" ? C + "49m" : ""
            let s = settle()
            return s + pen + C + "\(1 + rnd.nextInt(cols / 2))" + f
        }
        if pick < 78 {
            let y = state.cursorRow()
            if common() && (y < state.scrollTop() || y > state.scrollBottom()) {
                return nil
            }
            let n = 1 + rnd.nextInt(3)
            return C + "\(n)" + (rnd.nextBoolean() ? "L" : "M") + "\r"
        }
        if pick < 80 {
            let n = 1 + rnd.nextInt(3)
            return C + "\(n)" + (rnd.nextBoolean() ? "S" : "T")
        }
        if pick < 83 {
            if rnd.nextInt(3) == 0 {
                return C + "r"
            }
            let top = 1 + rnd.nextInt(rows - 1)
            let bottom = top + 1 + rnd.nextInt(rows - top)
            return C + "\(top);\(bottom)r"
        }
        if pick < 86 {
            let y = state.cursorRow()
            switch rnd.nextInt(3) {
            case 0:
                return common() && y == rows - 1 && state.scrollBottom() != rows - 1 ? nil : settle() + E + "D"
            case 1:
                return common() && y == rows - 1 && state.scrollBottom() != rows - 1 ? nil : settle() + E + "E"
            default:
                return common() && y == 0 && state.scrollTop() != 0 ? nil : settle() + E + "M"
            }
        }
        if pick < 88 {
            if common() && state.alternateScreen() {
                return nil
            }
            if rnd.nextBoolean() {
                return E + "7"
            }
            return restoreDiffers() ? nil : E + "8"
        }
        if pick < 90 {
            if state.alternateScreen() {
                return restoreDiffers() ? nil : C + "?1049l"
            }
            return common() ? C + "?1049h" : C + "?" + (rnd.nextBoolean() ? "1049" : "47") + "h"
        }
        if pick < 95 {
            return modeOp()
        }
        if pick < 97 {
            switch rnd.nextInt(4) {
            case 0:
                return E + "]2;title \(rnd.nextInt(100))\u{7}"
            case 1:
                return E + "]0;icon+title\u{1b}\\"
            case 2:
                let n = rnd.nextInt(9)
                return E + "]8;;https://example.test/\(n)\u{1b}\\" + fitting("link") + E + "]8;;\u{1b}\\"
            default:
                return E + "P1$r0m" + E + "\\"
            }
        }
        if pick < 98 {
            return rnd.nextBoolean() ? E + "(0" + fitting("lqqkxjmn") + E + "(B" : E + "H"
        }
        if pick < 99 {
            return C + (rnd.nextBoolean() ? "0" : "3") + "g"
        }
        if rnd.nextInt(4) == 0 {
            // jediterm's RIS keeps its DECSC slot, its tab stops and bracketed paste; re-sync.
            return E + "c" + (common() ? E + "7" + C + "?2004l" + defaultTabStops() : "")
        }
        return C + "\(rnd.nextInt(7)) q"
    }

    /** Whether restoring the main screen's saved cursor (ESC 8, CSI ?1049 l) would clamp it
     * into the region: xterm confines it in origin mode, jediterm does not. */
    private func restoreDiffers() -> Bool {
        guard common(), let saved = state.savedCursor(false) else {
            return false
        }
        return saved.originMode && (saved.row < state.scrollTop() || saved.row > state.scrollBottom())
    }

    /** ASCII `text` written where jediterm agrees: with autowrap off it must fit before the
     * margin (jediterm wraps to column 0 of the same row instead). */
    private func fitting(_ text: String) -> String {
        if common() && !state.autoWrap()
            && (state.cursorPendingWrap() || state.cursorColumn() + text.count > state.columns()) {
            return "\r" + String(text.prefix(min(text.count, state.columns())))
        }
        return text
    }

    private func defaultTabStops() -> String {
        var sb = C + "3g"
        var x = 8
        while x < state.columns() {
            sb += C + "1;\(x + 1)H" + E + "H"
            x += 8
        }
        return sb + C + "H"
    }

    /** Whether a blank cell with a background lies between the cursor and the next tab stop. */
    private func colouredBlankBeforeTab() -> Bool {
        let line = state.line(state.cursorRow())
        var x = state.cursorColumn()
        while x < state.columns() {
            if x > state.cursorColumn() && state.isTabStop(x) {
                break
            }
            if Style.background(line.style(x)) != Style.colorDefault {
                return true
            }
            x += 1
        }
        return false
    }

    private func plainBackground() -> String {
        return common() ? C + "49m" : ""
    }

    private func modeOp() -> String {
        let modes = [1, 6, 7, 25, 1000, 1002, 1003, 1004, 1006, 2004]
        let m = modes[rnd.nextInt(modes.count)]
        let set = rnd.nextBoolean()
        var s = C + "?\(m)" + (set ? "h" : "l")
        if m == 6 && common() {
            s += C + "H" // jediterm does not home on DECOM
        }
        if rnd.nextInt(5) == 0 {
            s += rnd.nextBoolean() ? E + "=" : E + ">"
        }
        if !common() && rnd.nextInt(4) == 0 {
            switch rnd.nextInt(5) {
            case 0: s += C + "4" + (set ? "h" : "l")
            case 1: s += C + "3b"
            case 2: s += C + "2I" + C + "Z"
            case 3: s += C + "s" + C + "u"
            default: s += "\u{e}" + E + ")0" + "q" + "\u{f}"
            }
        }
        return s
    }

    private func sgr() -> String {
        var sb = C
        let n = 1 + rnd.nextInt(3)
        for i in 0..<n {
            if i > 0 {
                sb += ";"
            }
            switch rnd.nextInt(10) {
            case 0: sb += "38;5;\(rnd.nextInt(256))"
            case 1: sb += "48;5;\(rnd.nextInt(256))"
            case 2:
                let r = rnd.nextInt(256)
                let g = rnd.nextInt(256)
                let b = rnd.nextInt(256)
                sb += "38;2;\(r);\(g);\(b)"
            case 3:
                sb += rnd.nextBoolean() ? "48:2::" : "38:2::"
                let r = rnd.nextInt(256)
                let g = rnd.nextInt(256)
                let b = rnd.nextInt(256)
                sb += "\(r):\(g):\(b)"
            case 4: sb += "\(30 + rnd.nextInt(8))"
            case 5: sb += "\(40 + rnd.nextInt(8))"
            case 6: sb += "\(rnd.nextBoolean() ? 90 + rnd.nextInt(8) : 100 + rnd.nextInt(8))"
            case 7:
                let attrs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 22, 23, 24, 25, 27, 28, 29, 39, 49, 53]
                sb += "\(attrs[rnd.nextInt(attrs.count)])"
            case 8: sb += "4:\(rnd.nextInt(6))"
            default: sb += "0"
            }
        }
        return sb + "m"
    }

    private func text() -> String {
        let cols = state.columns()
        var sb = ""
        var x = state.cursorColumn()
        var pending = state.cursorPendingWrap()
        var limit = Int.max
        if common() && !state.autoWrap() {
            if pending {
                sb += "\r"
                x = 0
                pending = false
            }
            limit = cols - x
        }
        let len = 1 + rnd.nextInt(rnd.nextInt(10) == 0 ? 3 * cols : 24)
        var used = 0
        for _ in 0..<len {
            let piece: String
            let width: Int
            let r = rnd.nextInt(100)
            if r < 80 {
                piece = String(VtFuzz.NARROW[rnd.nextInt(VtFuzz.NARROW.count)])
                width = 1
            } else if r < 88 {
                piece = VtFuzz.EXTRA_NARROW[rnd.nextInt(VtFuzz.EXTRA_NARROW.count)]
                width = 1
            } else if r < 96 {
                piece = VtFuzz.WIDE[rnd.nextInt(VtFuzz.WIDE.count)]
                width = 2
            } else if !common() {
                piece = r < 98 ? VtFuzz.SUPPLEMENTARY[rnd.nextInt(VtFuzz.SUPPLEMENTARY.count)]
                    : VtFuzz.COMBINING[rnd.nextInt(VtFuzz.COMBINING.count)]
                width = 2
            } else {
                piece = String(VtFuzz.NARROW[rnd.nextInt(VtFuzz.NARROW.count)])
                width = 1
            }
            if used + width > limit {
                break
            }
            sb += piece
            used += width
            x = pending ? width : x + width
            pending = false
            if x >= cols {
                x = cols - 1
                pending = true
            }
        }
        return sb
    }
}
