import CoreGraphics
import MicrohmVT

/// Resolves the emulator's colours (`Style` colour ints) to `0xRRGGBB`: the 16 ANSI slots
/// from the palette, 16-255 from the xterm cube and grey ramp, truecolor as is, and
/// `Style.colorDefault` to the theme's default foreground/background. Mutable, main thread
/// only: the theme and palette switch live, and every paint resolves through here, so cells
/// already on screen recolour too.
///
/// Defaults follow the palette like the earlier widget did: on a dark terminal the
/// background is slot 0 and text slot 15, on a light one the reverse; a custom background
/// (matching a UI surface) replaces only the background.
public final class TerminalColors {

    private static let cube: [Int] = (0..<256).map { $0 < 16 ? 0 : Style.xterm256Rgb($0) }

    private var ansi = [Int](repeating: 0, count: 16)
    public private(set) var light = false
    private var customBackground: Int?
    public private(set) var defaultForeground = 0
    public private(set) var defaultBackground = 0
    /// Direct-mapped cache so painting does not allocate a `CGColor` per run.
    private var cache = [CGColor?](repeating: nil, count: 1024)
    private var cacheKeys = [Int](repeating: -1, count: 1024)

    public init(_ palette: [Int], _ light: Bool) {
        setPalette(palette)
        setTheme(nil, light)
    }

    public func setPalette(_ palette: [Int]) {
        for i in 0..<16 {
            ansi[i] = palette[i]
        }
        recompute()
    }

    /// `background` nil: the palette's black (dark) or white (light) slot.
    public func setTheme(_ background: Int?, _ light: Bool) {
        customBackground = background
        self.light = light
        recompute()
    }

    private func recompute() {
        defaultBackground = customBackground ?? (light ? ansi[15] : ansi[0])
        defaultForeground = light ? ansi[0] : ansi[15]
    }

    /// The selection highlight behind selected cells.
    public func selection() -> Int {
        return light ? 0xB4D5FE : 0x264F78
    }

    /// `0xRRGGBB` of an emulator colour used as a foreground or a background.
    public func rgb(_ color: Int, _ foreground: Bool) -> Int {
        if color == Style.colorDefault {
            return foreground ? defaultForeground : defaultBackground
        }
        if Style.isIndexed(color) {
            let index = Style.index(color)
            return index < 16 ? ansi[index] : TerminalColors.cube[index]
        }
        return Style.rgbValue(color)
    }

    /// A cached opaque sRGB `CGColor` for `rgb`.
    public func color(_ rgb: Int) -> CGColor {
        let rgb = rgb & 0xFFFFFF
        let slot = (rgb ^ (rgb >> 10) ^ (rgb >> 20)) & (cache.count - 1)
        if cacheKeys[slot] == rgb, let c = cache[slot] {
            return c
        }
        let c = TerminalColors.cgColor(rgb)
        cache[slot] = c
        cacheKeys[slot] = rgb
        return c
    }

    public static func cgColor(_ rgb: Int, alpha: CGFloat = 1) -> CGColor {
        return CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    /// `a` moved `amount` (0..1) of the way to `b`, per channel.
    public static func blend(_ a: Int, _ b: Int, _ amount: Double) -> Int {
        let r = mix((a >> 16) & 0xFF, (b >> 16) & 0xFF, amount)
        let g = mix((a >> 8) & 0xFF, (b >> 8) & 0xFF, amount)
        let bl = mix(a & 0xFF, b & 0xFF, amount)
        return (r << 16) | (g << 8) | bl
    }

    private static func mix(_ a: Int, _ b: Int, _ amount: Double) -> Int {
        return BoxDrawing.jround(Double(a) + Double(b - a) * amount)
    }
}
