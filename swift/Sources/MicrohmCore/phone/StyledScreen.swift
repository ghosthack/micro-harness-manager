import Foundation
import MicrohmVT

/// A session's screen with its colours, for the phone page: the daemon's styled capture
/// (the attach redraw stream) replayed into the project's own emulator, then each row as
/// runs of text sharing a style. Colours resolve through the app's ANSI palette on a dark
/// terminal, as the window draws them; the defaults come separately, so the page paints its
/// background to match.
///
/// Wire shape: `{fg, bg, rows: [[run…]…]}`; a run is `{t, f?, b?, s?}`: its text, its
/// colours as `#rrggbb` (absent: the defaults) and its style bits (`BOLD`, `DIM`, `ITALIC`,
/// `UNDERLINE`, `STRIKE`; an underline that is not a single line adds `DOUBLE`, `CURLY`,
/// `DOTTED` or `DASHED`). Inverse and invisible are resolved here. Trailing blank cells on
/// the default background are left out.
public final class StyledScreen: @unchecked Sendable {

    static let BOLD = 1
    static let DIM = 2
    static let ITALIC = 4
    static let UNDERLINE = 8
    static let STRIKE = 16
    /// With `UNDERLINE`: its kind, when not a single line.
    static let DOUBLE = 32
    static let CURLY = 64
    static let DOTTED = 128
    static let DASHED = 256

    private static let CUBE: [Int] = (0..<256).map { $0 < 16 ? 0 : Style.xterm256Rgb($0) }

    private let ansi: [Int]
    private let defaultForeground: Int
    private let defaultBackground: Int

    /// `palette`: the 16 ANSI colours as `0xRRGGBB`.
    public init(_ palette: [Int]) {
        precondition(palette.count >= 16, "16 colours expected")
        self.ansi = palette
        self.defaultBackground = palette[0]
        self.defaultForeground = palette[15]
    }

    /// `redraw` (a styled capture) drawn on a `columns`×`rows` screen.
    public func render(_ redraw: String, _ columns: Int, _ rows: Int) -> CoreJSON {
        let terminal = HeadlessTerminal(max(1, columns), max(1, rows), 0) { _ in }
        defer { terminal.close() }
        let bytes = Array(redraw.utf8)
        let tokenizer = VtTokenizer()
        terminal.apply(tokenizer.feed(bytes).tokens)
        terminal.apply(tokenizer.flush().tokens)
        let emulator = terminal.emulator()
        emulator.lock().lock()
        var lines: [CoreJSON] = []
        for y in 0..<emulator.rows() {
            lines.append(row(emulator.line(y)))
        }
        emulator.lock().unlock()
        return .obj([("fg", .string(StyledScreen.hex(defaultForeground))),
                     ("bg", .string(StyledScreen.hex(defaultBackground))),
                     ("rows", .array(lines))])
    }

    private func row(_ line: Line) -> CoreJSON {
        var runs: [CoreJSON] = []
        var end = line.columns()
        // leave out trailing blanks on the default background
        while end > 0 && (line.isEmpty(end - 1) || line.codePoint(end - 1) == 0x20)
            && Style.background(line.style(end - 1)) == Style.COLOR_DEFAULT
            && !Style.inverse(line.style(end - 1)) {
            end -= 1
        }
        var text = ""
        var runFg: String?
        var runBg: String?
        var runStyle = 0
        var open = false
        for x in 0..<end {
            if line.isWideTail(x) {
                continue
            }
            let style = line.style(x)
            var fg = rgb(Style.foreground(style), true)
            var bg = rgb(Style.background(style), false)
            var defaultFg = Style.foreground(style) == Style.COLOR_DEFAULT
            var defaultBg = Style.background(style) == Style.COLOR_DEFAULT
            if Style.inverse(style) {
                swap(&fg, &bg)
                swap(&defaultFg, &defaultBg)
            }
            if Style.invisible(style) {
                fg = bg
                defaultFg = defaultBg && defaultFg
            }
            let cellFg = defaultFg && !Style.inverse(style) ? nil : StyledScreen.hex(fg)
            let cellBg = defaultBg && !Style.inverse(style) ? nil : StyledScreen.hex(bg)
            let bits = (Style.bold(style) ? StyledScreen.BOLD : 0) | (Style.dim(style) ? StyledScreen.DIM : 0)
                | (Style.italic(style) ? StyledScreen.ITALIC : 0)
                | StyledScreen.underlineBits(Style.underline(style))
                | (Style.strikethrough(style) ? StyledScreen.STRIKE : 0)
            if open && (cellFg != runFg || cellBg != runBg || bits != runStyle) {
                runs.append(StyledScreen.run(text, runFg, runBg, runStyle))
                text = ""
            }
            runFg = cellFg
            runBg = cellBg
            runStyle = bits
            open = true
            if line.isEmpty(x) {
                text += " "
            } else {
                line.appendText(x, &text)
            }
        }
        if open {
            runs.append(StyledScreen.run(text, runFg, runBg, runStyle))
        }
        return .array(runs)
    }

    static func underlineBits(_ underline: Int) -> Int {
        switch underline {
        case Style.UNDERLINE_NONE: return 0
        case Style.UNDERLINE_DOUBLE: return UNDERLINE | DOUBLE
        case Style.UNDERLINE_CURLY: return UNDERLINE | CURLY
        case Style.UNDERLINE_DOTTED: return UNDERLINE | DOTTED
        case Style.UNDERLINE_DASHED: return UNDERLINE | DASHED
        default: return UNDERLINE
        }
    }

    private static func run(_ text: String, _ fg: String?, _ bg: String?, _ style: Int) -> CoreJSON {
        var run = CoreJSON.obj([("t", .string(text))])
        if let fg {
            run.set("f", .string(fg))
        }
        if let bg {
            run.set("b", .string(bg))
        }
        if style != 0 {
            run.set("s", .int(Int64(style)))
        }
        return run
    }

    /// `0xRRGGBB` of an emulator colour, as the window resolves it on a dark terminal.
    func rgb(_ color: Int, _ foreground: Bool) -> Int {
        if color == Style.COLOR_DEFAULT {
            return foreground ? defaultForeground : defaultBackground
        }
        if Style.isIndexed(color) {
            let index = Style.index(color)
            return index < 16 ? ansi[index] : StyledScreen.CUBE[index]
        }
        return Style.rgbValue(color)
    }

    static func hex(_ rgb: Int) -> String {
        String(format: "#%06x", rgb & 0xFFFFFF)
    }

    /// The 16 base ANSI colours behind each `AppSettings.TerminalPalette` (the same values
    /// as `MicrohmTerminal.AnsiPalettes`, which this module cannot import).
    public static func palette(_ setting: AppSettings.TerminalPalette) -> [Int] {
        switch setting {
        case .iterm2:
            return [0x000000, 0xC91B00, 0x00C200, 0xC7C400, 0x0225C7, 0xCA30C7, 0x00C5C7, 0xC7C7C7,
                    0x686868, 0xFF6E67, 0x5FFA68, 0xFFFC67, 0x6871FF, 0xFF77FF, 0x60FDFF, 0xFFFFFF]
        case .xterm:
            return [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x1E90FF, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                    0x4C4C4C, 0xFF0000, 0x00FF00, 0xFFFF00, 0x4682B4, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
        case .macosTerminal:
            return [0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                    0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB]
        }
    }
}
