import AppKit
import CoreText

/// The terminal font in its four styles, the cell metrics derived from it, and glyph lookup
/// with fallback for code points it cannot display. Everything here is in *device* pixels:
/// the font is sized `size × scale` (Menlo 28 for Menlo 14 on a 2× Retina display), and the
/// view paints in device space. Cell width is the advance of "W" (or "M" if wider), cell
/// height ascent + descent + leading, both rounded up to whole device pixels so every cell
/// starts on a pixel boundary; at 2× that is half a point, so the rounding barely changes
/// the font's own proportions (Menlo 14: 8.5 × 16.5 points, where whole points gave 8 × 17).
///
/// Glyphs of the terminal font are drawn at explicit cell positions (centred in the cell),
/// so a run of them always lines up with the grid whatever the font's fractional advance.
/// Everything else — combining sequences, emoji, wide characters, code points the font
/// lacks — goes through a cached `CTLine`, which brings Core Text's own font cascade (Apple
/// Color Emoji, PingFang, Apple Symbols…), the native equivalent of Java's fallback list.
public final class TerminalFonts {

    public static let plain = 0
    public static let bold = 1
    public static let italic = 2

    public let family: String
    public let size: Double
    public let scale: Double
    private var fonts: [CTFont] = []
    public let cellWidth: Int
    public let cellHeight: Int
    /// Baseline offset from the top of a cell.
    public let baseline: Int
    /// Underline/strike stroke thickness.
    public let lineThickness: Double

    /// Per style: glyph for a BMP code point, 0 for "the font has none", absent for unknown.
    private var glyphs: [[UInt16: CGGlyph]] = [[:], [:], [:], [:]]
    private var advances: [[CGGlyph: Double]] = [[:], [:], [:], [:]]
    private var lines: [String: CTLine] = [:]

    /// `size` in points, `scale` device pixels per point (1 when unknown).
    public init(family: String, size: Double, scale: Double) {
        self.family = family
        self.size = size
        self.scale = scale
        let px = CGFloat(size * scale)
        let plain = TerminalFonts.resolve(family, px)
        let manager = NSFontManager.shared
        let bold = manager.convert(plain, toHaveTrait: .boldFontMask)
        let italic = manager.convert(plain, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        fonts = [plain as CTFont, bold as CTFont, italic as CTFont, boldItalic as CTFont]
        let font = fonts[0]
        let w = max(TerminalFonts.advance(font, "W"), TerminalFonts.advance(font, "M"))
        cellWidth = max(1, Int((w - 0.01).rounded(.up)))
        let ascent = Double(CTFontGetAscent(font))
        let descent = Double(CTFontGetDescent(font))
        let leading = Double(CTFontGetLeading(font))
        let height = ascent + descent + leading
        cellHeight = max(1, Int((height - 0.01).rounded(.up)))
        // centre the glyph box in the rounded-up cell
        baseline = Int((ascent + (Double(cellHeight) - height) / 2 + leading / 2).rounded())
        lineThickness = max(1, Double(CTFontGetUnderlineThickness(font)).rounded())
    }

    /// The family at `px`, or the system's monospaced font when the family is not installed.
    private static func resolve(_ family: String, _ px: CGFloat) -> NSFont {
        if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: px) {
            return f
        }
        if let f = NSFont(name: family, size: px) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: px, weight: .regular)
    }

    private static func advance(_ font: CTFont, _ s: String) -> Double {
        var chars = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) else {
            return Double(CTFontGetSize(font)) * 0.6
        }
        return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, nil, glyphs.count)
    }

    public func font(_ style: Int) -> CTFont {
        return fonts[style]
    }

    /// The terminal font's glyph for a BMP code point in `style`, or nil when it has none
    /// (the cell then goes through `line`, and Core Text's cascade).
    public func glyph(_ cp: Int, _ style: Int) -> CGGlyph? {
        if cp > 0xFFFF {
            return nil
        }
        let key = UInt16(cp)
        if let g = glyphs[style][key] {
            return g == 0 ? nil : g
        }
        var c = key
        var g: CGGlyph = 0
        if !CTFontGetGlyphsForCharacters(fonts[style], &c, &g, 1) {
            g = 0
        }
        glyphs[style][key] = g
        return g == 0 ? nil : g
    }

    /// The advance of a glyph of the terminal font in `style`.
    public func advance(_ glyph: CGGlyph, _ style: Int) -> Double {
        if let a = advances[style][glyph] {
            return a
        }
        var g = glyph
        let a = CTFontGetAdvancesForGlyphs(fonts[style], .horizontal, &g, nil, 1)
        advances[style][glyph] = a
        return a
    }

    /// `text` set in `style` with font fallback, colour taken from the context. Cached.
    public func line(_ text: String, _ style: Int) -> CTLine {
        let key = String(style) + text
        if let l = lines[key] {
            return l
        }
        if lines.count > 2048 {
            lines.removeAll(keepingCapacity: true)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): fonts[style],
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        lines[key] = l
        return l
    }
}
