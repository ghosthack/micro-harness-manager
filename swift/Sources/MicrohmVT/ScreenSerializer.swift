/**
 * Turns a `TerminalEmulator`'s state back into the escape-sequence stream a freshly attached
 * client needs to show the same thing. The contract is a round trip: feeding the output of
 * `serialize` into a fresh emulator of the same size yields the same cells (an empty cell and
 * a default-style space count as equal), styles, wrapped flags, history, cursor (including a
 * pending wrap), pen, modes, scroll region, tab stops, charsets, title, alternate screen and
 * saved cursors (ScreenSerializerTest and the corpus round trips).
 *
 * Output order:
 *  1. reset to a known state: `CSI ?1049 l`, `CSI 0 m`, `CSI ?7 h`, `CSI r`, `CSI ?25 l`
 *     (hidden while drawing), `CSI H`, `CSI 2 J`, `CSI 3 J`, `ESC ( B`, `SI`, `CSI 4 l`;
 *  2. the last `historyLines` history lines, then the main screen's rows, each as styled runs.
 *     A wide character's tail cell is skipped. A non-wrapped row stops at its last cell that
 *     is not a default-style blank, then `CSI 0 m` and `CSI K` (unless the row is full) and
 *     `CR LF` except after the last row. A wrapped row writes all its cells and no `CR LF`, so
 *     the client's deferred wrap marks it on the next write; an entirely blank continuation
 *     row still writes its first cell so that wrap fires. (A wrapped *last* row cannot be
 *     reproduced without scrolling; its flag is lost.)
 *  3. the main screen's saved cursor, staged (origin mode, cursor, pending wrap, autowrap,
 *     pen, charsets) and saved. On the alternate screen it is saved by `CSI ?1049 h`
 *     (`CSI ?1047 h` when nothing was saved), followed by the alternate rows drawn from home
 *     the same way and, if one exists, its own saved cursor (`ESC 7`); otherwise by `ESC 7`;
 *  4. the tail: scroll region, tab stops, origin mode, the cursor (re-writing the last cell
 *     when a wrap is pending), then the modes that do not move the cursor (autowrap, DECSCUSR,
 *     cursor blink, bracketed paste, cursor keys, keypad, mouse tracking and encoding, focus
 *     reporting, reverse video, insert and newline modes, kitty keyboard flags), the title,
 *     charsets, the pen, synchronized output, and cursor visibility last.
 *
 * The caller holds the emulator's lock so the snapshot is consistent.
 */
public enum ScreenSerializer {

    /** The redraw stream for `emulator`, with up to `historyLines` history lines. */
    public static func serialize(_ emulator: TerminalEmulator, _ historyLines: Int) -> [UInt8] {
        let writer = Writer(emulator)
        writer.write(historyLines)
        return writer.sb
    }

    private final class Writer {
        let t: TerminalEmulator
        let columns: Int
        let rows: Int
        var sb: [UInt8] = []
        /** The client's pen after our last SGR. */
        var pen: Int64 = Style.default

        init(_ t: TerminalEmulator) {
            self.t = t
            self.columns = t.columns()
            self.rows = t.rows()
            sb.reserveCapacity(4096)
        }

        @inline(__always) func append(_ s: String) {
            sb.append(contentsOf: s.utf8)
        }

        @inline(__always) func csi(_ s: String) {
            sb.append(0x1B)
            sb.append(UInt8(ascii: "["))
            sb.append(contentsOf: s.utf8)
        }

        func write(_ historyLines: Int) {
            csi("?1049l"); csi("0m"); csi("?7h"); csi("r"); csi("?25l"); csi("H"); csi("2J"); csi("3J")
            append("\u{1b}(B\u{0f}")
            csi("4l")

            let history = min(max(0, historyLines), t.mainHistorySize())
            let total = history + rows
            var afterWrap = false
            var i = -history
            while i < rows {
                afterWrap = emitLine(t.mainLine(i), i + history == total - 1, afterWrap)
                i += 1
            }
            let savedMain = t.savedCursor(false)
            if t.alternateScreen() {
                if let savedMain = savedMain {
                    stage(savedMain, false)
                    csi("?1049h")
                    unstage()
                } else {
                    csi("?1047h")
                }
                csi("H")
                afterWrap = false
                for y in 0..<rows {
                    afterWrap = emitLine(t.line(y), y == rows - 1, afterWrap)
                }
                if let savedAlt = t.savedCursor(true) {
                    stage(savedAlt, true)
                    append("\u{1b}7")
                    unstage()
                }
            } else if let savedMain = savedMain {
                stage(savedMain, false)
                append("\u{1b}7")
                unstage()
            }
            emitTail()
        }

        /** Puts the client in the state `saved` records, ready for it to be saved. The region
         * is full-screen here, so a CUP after `?6 h` is absolute. */
        private func stage(_ saved: TerminalEmulator.SavedCursor, _ alternate: Bool) {
            csi(saved.originMode ? "?6h" : "?6l")
            placeCursor(saved.row, saved.column, saved.pendingWrap, alternate, saved.row)
            if !saved.autoWrap {
                csi("?7l")
            }
            emitSgr(saved.style)
            emitCharsets(saved.charsets)
        }

        /** Back to the drawing state after a `stage`. */
        private func unstage() {
            append("\u{1b}(B\u{1b})B\u{1b}*B\u{1b}+B\u{0f}")
            csi("0m"); csi("?7h"); csi("?6l")
            pen = Style.default
        }

        private func emitTail() {
            csi("?6l")
            let top = t.scrollTop()
            let bottom = t.scrollBottom()
            if top != 0 || bottom != rows - 1 {
                csi("\(top + 1);\(bottom + 1)r")
            }
            if !t.defaultTabs() {
                csi("3g")
                for x in 0..<columns where t.isTabStop(x) {
                    csi("1;\(x + 1)H\u{1b}H")
                }
            }
            if t.originMode() {
                csi("?6h")
            }
            let row = t.originMode() ? t.cursorRow() - top : t.cursorRow()
            placeCursor(row, t.cursorColumn(), t.cursorPendingWrap(), t.alternateScreen(), t.cursorRow())

            csi(t.autoWrap() ? "?7h" : "?7l")
            if t.cursorShape() != 0 {
                csi("\(t.cursorShape()) q")
            }
            if t.cursorBlink() {
                csi("?12h")
            }
            if t.bracketedPaste() {
                csi("?2004h")
            }
            if t.applicationCursorKeys() {
                csi("?1h")
            }
            if t.applicationKeypad() {
                append("\u{1b}=")
            }
            if t.mouseTracking() != .none {
                csi("?\(t.mouseTracking().mode)h")
            }
            switch t.mouseEncoding() {
            case .utf8: csi("?1005h")
            case .sgr: csi("?1006h")
            case .urxvt: csi("?1015h")
            case .default: break
            }
            if t.focusReporting() {
                csi("?1004h")
            }
            if t.reverseVideo() {
                csi("?5h")
            }
            if t.insertMode() {
                csi("4h")
            }
            if t.newLineMode() {
                csi("20h")
            }
            if t.kittyKeyboardFlags() != 0 {
                csi("=\(t.kittyKeyboardFlags());1u")
            }
            if !t.title().isEmpty {
                append("\u{1b}]2;")
                for c in t.title().unicodeScalars where c.value >= 0x20 && c.value != 0x7F {
                    Line.appendUtf8(Int(c.value), &sb)
                }
                sb.append(0x07)
            }
            emitCharsets(t.charsetState())
            emitSgr(t.pen())
            if t.synchronizedOutput() {
                csi("?2026h")
            }
            csi(t.cursorVisible() ? "?25h" : "?25l")
        }

        /**
         * `CSI row;col H` (1-based from the 0-based `row`, which is relative to the region in
         * origin mode; `screenRow` is the absolute one). With a pending wrap the cursor sits on
         * the last column, which a CUP cannot express: move to the cell the last character
         * occupies and write it again with its style, which re-arms the wrap.
         */
        private func placeCursor(_ row: Int, _ column: Int, _ pendingWrap: Bool, _ alternate: Bool, _ screenRow: Int) {
            if !pendingWrap {
                csi("\(row + 1);\(column + 1)H")
                return
            }
            let line = alternate ? t.line(screenRow) : t.mainLine(screenRow)
            let x = line.isWideTail(column) ? column - 1 : column
            csi("\(row + 1);\(x + 1)H")
            let restore = pen
            emitCell(line, x)
            emitSgr(restore)
        }

        private func emitCharsets(_ packed: Int) {
            let designators: [UInt8] = [UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+")]
            for i in 0..<4 {
                let set = (packed >> (2 * i)) & 3
                if set != TerminalEmulator.charsetAscii {
                    sb.append(0x1B)
                    sb.append(designators[i])
                    sb.append(set == TerminalEmulator.charsetDecGraphics ? UInt8(ascii: "0") : UInt8(ascii: "A"))
                }
            }
            switch (packed >> 8) & 3 {
            case 1: sb.append(0x0E)
            case 2: append("\u{1b}n")
            case 3: append("\u{1b}o")
            default: break
            }
        }

        /** Emits one line and returns whether it was wrapped. */
        private func emitLine(_ line: Line, _ isLast: Bool, _ afterWrap: Bool) -> Bool {
            let width = min(line.columns(), columns)
            if line.isWrapped() {
                for x in 0..<width {
                    emitCell(line, x)
                }
                return true
            }
            var last = width - 1
            while last >= 0 && Writer.isDroppable(line, last) {
                last -= 1
            }
            if last < 0 && afterWrap {
                // A blank continuation: write one cell so the client's deferred wrap fires.
                emitCell(line, 0)
            }
            var x = 0
            while x <= last {
                emitCell(line, x)
                x += 1
            }
            emitSgr(Style.default)
            if last + 1 < columns {
                csi("K")
            }
            if !isLast {
                sb.append(0x0D)
                sb.append(0x0A)
            }
            return false
        }

        /** A cell CSI K reproduces: empty or a space, default style, nothing attached. */
        private static func isDroppable(_ line: Line, _ x: Int) -> Bool {
            let cp = line.codePoint(x)
            return (cp == 0 || cp == 0x20) && !line.isWideTail(x) && line.style(x) == Style.default
                && !line.hasExtras(x)
        }

        private func emitCell(_ line: Line, _ x: Int) {
            if line.isWideTail(x) {
                return // written with its lead
            }
            emitSgr(line.style(x))
            if line.codePoint(x) == 0 {
                sb.append(0x20)
            } else {
                line.appendUtf8(x, &sb)
            }
        }

        /** Moves the client's pen to `target`: `CSI 0;…m`, restating it in full. */
        private func emitSgr(_ target: Int64) {
            if target == pen {
                return
            }
            var p = ""
            ScreenSerializer.appendSgrParams(&p, target)
            csi("0" + p + "m")
            pen = target
        }
    }

    /** The SGR parameters for `s`, each prefixed with ';'; empty for the default style. */
    static func appendSgrParams(_ p: inout String, _ s: Int64) {
        if Style.bold(s) { p += ";1" }
        if Style.dim(s) { p += ";2" }
        if Style.italic(s) { p += ";3" }
        switch Style.underline(s) {
        case Style.underlineNone: break
        case Style.underlineSingle: p += ";4"
        case Style.underlineDouble: p += ";21"
        default: p += ";4:\(Style.underline(s))"
        }
        if Style.blink(s) { p += ";5" }
        if Style.rapidBlink(s) { p += ";6" }
        if Style.inverse(s) { p += ";7" }
        if Style.invisible(s) { p += ";8" }
        if Style.strikethrough(s) { p += ";9" }
        if Style.overline(s) { p += ";53" }
        appendColor(&p, Style.foreground(s), 30, 90, 38)
        appendColor(&p, Style.background(s), 40, 100, 48)
    }

    private static func appendColor(_ p: inout String, _ color: Int, _ base: Int, _ brightBase: Int, _ extended: Int) {
        if Style.isIndexed(color) {
            let idx = Style.index(color)
            if idx < 8 {
                p += ";\(base + idx)"
            } else if idx < 16 {
                p += ";\(brightBase + idx - 8)"
            } else {
                p += ";\(extended);5;\(idx)"
            }
        } else if Style.isRgb(color) {
            let rgb = Style.rgbValue(color)
            p += ";\(extended);2;\(rgb >> 16);\((rgb >> 8) & 0xFF);\(rgb & 0xFF)"
        }
    }
}
