/**
 * A cell's graphic rendition packed into one `Int64` (Java `long`), so a screen line stores its
 * styles in a plain buffer and nothing is allocated per cell. This type holds only static
 * helpers; `Style.default` (`0`) is the default style (default colours, no attributes).
 *
 * Layout: bits 0–25 foreground colour, 26–51 background colour, 52–63 attributes.
 *
 * A **colour** is a 26-bit `Int`: `colorDefault` (`0`) means the renderer's default
 * foreground/background; `indexed(_:)` is a palette index 0–255 (0–7 the ANSI colours set by
 * SGR 30–37/40–47, 8–15 their bright variants from SGR 90–97/100–107, 16–255 the xterm
 * 256-colour cube and grey ramp, see `xterm256Rgb(_:)`); `rgb(_:_:_:)` is a 24-bit direct
 * colour. Inspect one with `isIndexed`, `index`, `isRgb` and `rgbValue`.
 *
 * Attributes: bold, dim, italic, underline (a style number, see `underlineSingle` etc.),
 * blink (SGR 5), rapidBlink (SGR 6), inverse, invisible, strikethrough and overline. Inverse
 * is *not* applied to the colours here; a renderer swaps them itself.
 */
public enum Style {

    /** The default style: default colours, no attributes. */
    public static let `default`: Int64 = 0

    /** The renderer's default foreground or background colour. */
    public static let colorDefault: Int = 0

    /** No underline. */
    public static let underlineNone = 0
    /** SGR 4 / 4:1. */
    public static let underlineSingle = 1
    /** SGR 21 / 4:2. */
    public static let underlineDouble = 2
    /** SGR 4:3. */
    public static let underlineCurly = 3
    /** SGR 4:4. */
    public static let underlineDotted = 4
    /** SGR 4:5. */
    public static let underlineDashed = 5

    /** Java-named aliases of the constants above. */
    public static let DEFAULT: Int64 = 0
    public static let COLOR_DEFAULT = 0
    public static let UNDERLINE_NONE = 0
    public static let UNDERLINE_SINGLE = 1
    public static let UNDERLINE_DOUBLE = 2
    public static let UNDERLINE_CURLY = 3
    public static let UNDERLINE_DOTTED = 4
    public static let UNDERLINE_DASHED = 5

    static let colorBits: Int64 = 26
    static let colorMask: Int64 = (1 << 26) - 1
    static let kindIndexed = 1 << 24
    static let kindRgb = 2 << 24
    static let bgShift: Int64 = 26

    static let BOLD: Int64 = 1 << 52
    static let DIM: Int64 = 1 << 53
    static let underlineShift: Int64 = 54
    static let underlineMask: Int64 = 7 << 54
    static let ITALIC: Int64 = 1 << 57
    static let BLINK: Int64 = 1 << 58
    static let INVERSE: Int64 = 1 << 59
    static let INVISIBLE: Int64 = 1 << 60
    static let STRIKETHROUGH: Int64 = 1 << 61
    static let OVERLINE: Int64 = 1 << 62
    static let RAPID_BLINK: Int64 = Int64.min // 1 << 63

    static let fgMask: Int64 = colorMask
    static let bgMask: Int64 = colorMask << 26

    // --- colours ---------------------------------------------------------------------

    /** Palette colour `index` (0–255). */
    @inlinable public static func indexed(_ index: Int) -> Int {
        return (1 << 24) | (index & 0xFF)
    }

    /** 24-bit direct colour. */
    @inlinable public static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Int {
        return (2 << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)
    }

    /** True for a palette colour. */
    @inlinable public static func isIndexed(_ color: Int) -> Bool {
        return (color & ~0xFFFFFF) == (1 << 24)
    }

    /** The palette index of an `isIndexed` colour. */
    @inlinable public static func index(_ color: Int) -> Int {
        return color & 0xFF
    }

    /** True for a 24-bit direct colour. */
    @inlinable public static func isRgb(_ color: Int) -> Bool {
        return (color & ~0xFFFFFF) == (2 << 24)
    }

    /** The `0xRRGGBB` value of an `isRgb` colour. */
    @inlinable public static func rgbValue(_ color: Int) -> Int {
        return color & 0xFFFFFF
    }

    /**
     * The `0xRRGGBB` of xterm's default palette entry `index` for 16–255 (the 6×6×6 cube,
     * then the 24-step grey ramp). Entries 0–15 are theme colours, so this returns -1 for them.
     */
    public static func xterm256Rgb(_ index: Int) -> Int {
        if index < 16 || index > 255 {
            return -1
        }
        if index < 232 {
            let i = index - 16
            return (cube(i / 36) << 16) | (cube((i / 6) % 6) << 8) | cube(i % 6)
        }
        let grey = 8 + 10 * (index - 232)
        return (grey << 16) | (grey << 8) | grey
    }

    private static func cube(_ level: Int) -> Int {
        return level == 0 ? 0 : 55 + 40 * level
    }

    // --- reading a style -------------------------------------------------------------

    /** The foreground colour. */
    @inlinable public static func foreground(_ style: Int64) -> Int {
        return Int(style & ((1 << 26) - 1))
    }

    /** The background colour. */
    @inlinable public static func background(_ style: Int64) -> Int {
        return Int((style >> 26) & ((1 << 26) - 1))
    }

    @inlinable public static func bold(_ style: Int64) -> Bool { (style & (1 << 52)) != 0 }

    @inlinable public static func dim(_ style: Int64) -> Bool { (style & (1 << 53)) != 0 }

    @inlinable public static func italic(_ style: Int64) -> Bool { (style & (1 << 57)) != 0 }

    /** The underline style, `underlineNone` … `underlineDashed`. */
    @inlinable public static func underline(_ style: Int64) -> Int { Int((style >> 54) & 7) }

    /** SGR 5, slow blink. */
    @inlinable public static func blink(_ style: Int64) -> Bool { (style & (1 << 58)) != 0 }

    /** SGR 6, rapid blink. */
    @inlinable public static func rapidBlink(_ style: Int64) -> Bool { style < 0 }

    @inlinable public static func inverse(_ style: Int64) -> Bool { (style & (1 << 59)) != 0 }

    /** SGR 8, concealed. */
    @inlinable public static func invisible(_ style: Int64) -> Bool { (style & (1 << 60)) != 0 }

    @inlinable public static func strikethrough(_ style: Int64) -> Bool { (style & (1 << 61)) != 0 }

    /** SGR 53. */
    @inlinable public static func overline(_ style: Int64) -> Bool { (style & (1 << 62)) != 0 }

    // --- building a style (internal: only the emulator writes styles) -----------------

    static func withForeground(_ style: Int64, _ color: Int) -> Int64 {
        return (style & ~fgMask) | (Int64(color) & colorMask)
    }

    static func withBackground(_ style: Int64, _ color: Int) -> Int64 {
        return (style & ~bgMask) | ((Int64(color) & colorMask) << bgShift)
    }

    static func withUnderline(_ style: Int64, _ underline: Int) -> Int64 {
        return (style & ~underlineMask) | ((Int64(underline) << underlineShift) & underlineMask)
    }

    static func with(_ style: Int64, _ flag: Int64, _ on: Bool) -> Int64 {
        return on ? style | flag : style & ~flag
    }

    /** The style an erase leaves behind: only the background survives (xterm's BCE). */
    @inline(__always) static func eraseStyle(_ pen: Int64) -> Int64 {
        return pen & bgMask
    }

    /** A readable form for test failure messages, e.g. `fg=idx1 bg=#0a0b0c bold`. */
    public static func describe(_ style: Int64) -> String {
        var sb = "fg=" + describeColor(foreground(style))
        sb += " bg=" + describeColor(background(style))
        if bold(style) { sb += " bold" }
        if dim(style) { sb += " dim" }
        if italic(style) { sb += " italic" }
        if underline(style) != 0 { sb += " underline=\(underline(style))" }
        if blink(style) { sb += " blink" }
        if rapidBlink(style) { sb += " rapidBlink" }
        if inverse(style) { sb += " inverse" }
        if invisible(style) { sb += " invisible" }
        if strikethrough(style) { sb += " strike" }
        if overline(style) { sb += " overline" }
        return sb
    }

    private static func describeColor(_ color: Int) -> String {
        if isIndexed(color) {
            return "idx\(index(color))"
        }
        if isRgb(color) {
            let hex = String(rgbValue(color), radix: 16)
            return "#" + String(repeating: "0", count: max(0, 6 - hex.count)) + hex
        }
        return "default"
    }
}
