import CoreGraphics
import Foundation

/// The characters made to tile — to touch the cell's edges and join their neighbours into
/// lines and pictures — drawn as geometry fitted to the cell, since no font's glyph box is
/// the cell (and a fallback font's, used where the terminal font has no glyph, is smaller
/// and sits on its own baseline, leaving gaps and steps between cells):
///
/// - box drawing (U+2500–257F) and block elements (U+2580–259F);
/// - braille patterns (U+2800–28FF): dots on one even 2 × 4 grid across cells, so
///   braille "pixel art" lines up;
/// - block mosaics from Symbols for Legacy Computing and its Supplement: the sextants
///   (2 × 3), octants (2 × 4), one-eighth bars and partial blocks, read from the
///   characters' Unicode names (so the table cannot drift from the standard): see
///   `mosaics`;
/// - the horizontal scan lines (U+23BA–23BD) and the Powerline separators (U+E0B0–E0B3).
///
/// Glyphs that are not made to tile (letters, symbols, emoji) are left to the font: on its
/// baseline they line up with the text around them. Lines are integer rectangles (crisp at
/// any scale); arcs and diagonals are antialiased strokes.
///
/// Coordinates are device pixels in a **y-down** context (a flipped view, or a bitmap
/// context with a flip applied): `(x, y)` is the cell's top-left corner.
///
/// Each line character is four arms — up, right, down, left — of weight 0 none, 1 light,
/// 2 heavy or 3 double. Light is about an eighth of the cell width, heavy twice that, and a
/// double line is two light strokes a light width apart.
public enum BoxDrawing {

    /// URDL weights for U+2500–U+254B ("d" marks the dashed lines, drawn separately).
    private static let lines1: [String] = [
        "0101", "0202", "1010", "2020", "d", "d", "d", "d", "d", "d", "d", "d",
        "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022",
        "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002",
        "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
        "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022",
        "0111", "0112", "0211", "0212", "0121", "0122", "0221", "0222",
        "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
        "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112",
        "2211", "1122", "1221", "2212", "1222", "2122", "2221", "2222"]

    /// URDL weights for U+2550–U+256C (3 = double).
    private static let lines2: [String] = [
        "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033",
        "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
        "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303",
        "3101", "3303", "1313", "3131", "3333"]

    /// URDL weights for U+2574–U+257F.
    private static let lines3: [String] = [
        "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020",
        "0201", "1020", "0102", "2010"]

    public static func handles(_ cp: Int) -> Bool {
        return (cp >= 0x2500 && cp <= 0x259F) || (cp >= 0x2800 && cp <= 0x28FF) || (cp >= 0xE0B0 && cp <= 0xE0B3)
            || (cp >= 0x23BA && cp <= 0x23BD) || mosaics[cp] != nil
    }

    /// A cell divided into `columns` × `rows` equal parts; `mask` bit `row * columns + column`
    /// set where the part is filled.
    public struct Mosaic: Equatable, Sendable {
        public let columns: Int
        public let rows: Int
        public let mask: UInt64

        public init(_ columns: Int, _ rows: Int, _ mask: UInt64) {
            self.columns = columns
            self.rows = rows
            self.mask = mask
        }
    }

    /// Partial-block fractions in eighths.
    private static let eighths: [String: Int] = [
        "ONE QUARTER": 2, "THREE EIGHTHS": 3, "FIVE EIGHTHS": 5, "THREE QUARTERS": 6, "SEVEN EIGHTHS": 7]

    /// Block mosaics by code point, built from the Unicode character names.
    public static let mosaics: [Int: Mosaic] = {
        var out: [Int: Mosaic] = [:]
        for range in [0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF] {
            for cp in range {
                guard let scalar = Unicode.Scalar(cp), let name = scalar.properties.name else {
                    continue
                }
                if let m = mosaic(name) {
                    out[cp] = m
                }
            }
        }
        return out
    }()

    private static func match(_ pattern: String, _ name: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else {
            return nil
        }
        let ns = name as NSString
        guard let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    /// The mosaic a character name describes, or nil. Dots and eighths are numbered from
    /// the top left, row by row (sextant 1 2 / 3 4 / 5 6; octant 1 2 / … / 7 8).
    public static func mosaic(_ name: String) -> Mosaic? {
        // cheap filter: every name below ends in BLOCK or BLOCK-<digits>
        guard name.contains("BLOCK") else {
            return nil
        }
        if let m = match("BLOCK SEXTANT-(\\d+)", name) {
            return Mosaic(2, 3, digits(m[1]))
        }
        if let m = match("BLOCK OCTANT-(\\d+)", name) {
            return Mosaic(2, 4, digits(m[1]))
        }
        if let m = match("VERTICAL ONE EIGHTH BLOCK-(\\d+)", name) {
            return Mosaic(8, 1, digits(m[1]))
        }
        if let m = match("HORIZONTAL ONE EIGHTH BLOCK-(\\d+)", name) {
            return Mosaic(1, 8, digits(m[1]))
        }
        if let m = match("(LEFT|RIGHT|UPPER|LOWER) AND (LEFT|RIGHT|UPPER|LOWER) ONE EIGHTH BLOCK", name) {
            return Mosaic(8, 8, edge(m[1]) | edge(m[2]))
        }
        if let m = match("(UPPER|RIGHT) (ONE QUARTER|THREE EIGHTHS|FIVE EIGHTHS|THREE QUARTERS|SEVEN EIGHTHS) BLOCK", name) {
            let n = eighths[m[2]]!
            let upper = m[1] == "UPPER"
            var mask: UInt64 = 0
            for i in 0..<n {
                mask |= 1 << UInt64(upper ? i : 7 - i)
            }
            return upper ? Mosaic(1, 8, mask) : Mosaic(8, 1, mask)
        }
        if let m = match("LEFT (ONE THIRD|TWO THIRDS) BLOCK", name) {
            return Mosaic(3, 1, m[1].hasPrefix("ONE") ? 0b1 : 0b11)
        }
        // a 4 × 4 grid: rows UPPER, UPPER MIDDLE, LOWER MIDDLE, LOWER; columns LEFT,
        // CENTRE LEFT, CENTRE RIGHT, RIGHT
        if let m = match("(UPPER|UPPER MIDDLE|LOWER MIDDLE|LOWER) (LEFT|CENTRE LEFT|CENTRE RIGHT|RIGHT) ONE SIXTEENTH BLOCK", name) {
            let row = ["UPPER", "UPPER MIDDLE", "LOWER MIDDLE", "LOWER"].firstIndex(of: m[1])!
            let column = ["LEFT", "CENTRE LEFT", "CENTRE RIGHT", "RIGHT"].firstIndex(of: m[2])!
            return Mosaic(4, 4, 1 << UInt64(row * 4 + column))
        }
        if let m = match("(UPPER|LOWER) CENTRE ONE QUARTER BLOCK", name) {
            return Mosaic(4, 4, m[1] == "UPPER" ? 0x0066 : 0x6600)
        }
        if let m = match("MIDDLE (LEFT|RIGHT) ONE QUARTER BLOCK", name) {
            return Mosaic(4, 4, m[1] == "LEFT" ? 0x0330 : 0x0CC0)
        }
        // "RIGHT HALF LOWER ONE QUARTER BLOCK": the quarter-wide strip along the lower edge,
        // over the right half of it
        if let m = match("(LEFT|RIGHT|UPPER|LOWER) (HALF|THREE QUARTERS) (UPPER|LOWER|LEFT|RIGHT) ONE QUARTER BLOCK", name) {
            let from = m[1]
            let extent = m[2] == "HALF" ? 2 : 3
            let side = m[3]
            var mask: UInt64 = 0
            for i in 0..<4 {
                let horizontalStrip = side == "UPPER" || side == "LOWER"
                let along = from == "LEFT" || from == "UPPER" ? i : 3 - i
                if i >= extent {
                    continue
                }
                let row = horizontalStrip ? (side == "UPPER" ? 0 : 3) : along
                let column = horizontalStrip ? along : (side == "LEFT" ? 0 : 3)
                mask |= 1 << UInt64(row * 4 + column)
            }
            return Mosaic(4, 4, mask)
        }
        return nil
    }

    /// Whether `cp` is in a block whose characters are made to tile (Symbols for Legacy
    /// Computing and its Supplement): those this type cannot draw — pictograph pieces,
    /// wedges — are drawn by a font, stretched to fill the cell exactly, so that whatever
    /// font has them they still meet their neighbours.
    public static func tiles(_ cp: Int) -> Bool {
        return (cp >= 0x1FB00 && cp <= 0x1FBFF) || (cp >= 0x1CC00 && cp <= 0x1CEBF)
    }

    /// Parts numbered from 1 in the name → bits from 0.
    private static func digits(_ parts: String) -> UInt64 {
        var mask: UInt64 = 0
        for c in parts.unicodeScalars {
            mask |= 1 << UInt64(c.value - 0x31)
        }
        return mask
    }

    /// One edge eighth of an 8 × 8 grid.
    private static func edge(_ side: String) -> UInt64 {
        var mask: UInt64 = 0
        for i in 0..<8 {
            let bit: Int
            switch side {
            case "LEFT": bit = i * 8
            case "RIGHT": bit = i * 8 + 7
            case "UPPER": bit = i
            default: bit = 56 + i
            }
            mask |= 1 << UInt64(bit)
        }
        return mask
    }

    // MARK: - Drawing

    /// Java's `Math.round` for floats: half up.
    @inline(__always)
    static func jround(_ v: Double) -> Int {
        return Int((v + 0.5).rounded(.down))
    }

    @inline(__always)
    private static func fill(_ g: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        if w > 0 && h > 0 {
            g.fill(CGRect(x: x, y: y, width: w, height: h))
        }
    }

    /// Fills the mosaic's parts, part edges rounded the same way in every cell so
    /// neighbouring cells meet without gaps or overlaps.
    static func mosaic(_ g: CGContext, _ m: Mosaic, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for row in 0..<m.rows {
            let top = y + jround(Double(row * h) / Double(m.rows))
            let bottom = y + jround(Double((row + 1) * h) / Double(m.rows))
            for column in 0..<m.columns {
                if m.mask & (1 << UInt64(row * m.columns + column)) == 0 {
                    continue
                }
                let left = x + jround(Double(column * w) / Double(m.columns))
                let right = x + jround(Double((column + 1) * w) / Double(m.columns))
                fill(g, left, top, right - left, bottom - top)
            }
        }
    }

    /// Draws `cp` into the cell at `(x, y)` of `w` × `h` device pixels in `color`. Returns
    /// false for a character it leaves to the font.
    @discardableResult
    public static func draw(_ g: CGContext, _ cp: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                            _ color: CGColor) -> Bool {
        if !handles(cp) {
            return false
        }
        g.saveGState()
        defer { g.restoreGState() }
        g.setFillColor(color)
        g.setStrokeColor(color)
        if cp >= 0x2800 && cp <= 0x28FF {
            braille(g, cp - 0x2800, x, y, w, h)
            return true
        }
        // rectangles on whole device pixels are exact; antialiasing them would only blur a
        // rect that lands half way (it cannot here, but keeps edges hard regardless)
        g.setShouldAntialias(false)
        if let mosaic = mosaics[cp] {
            self.mosaic(g, mosaic, x, y, w, h)
            return true
        }
        let light = max(1, jround(Double(w) / 8))
        if cp >= 0x23BA && cp <= 0x23BD {
            // scan lines 1, 3, 7, 9 of nine; 5 would be the box-drawing horizontal
            let line = [1, 3, 7, 9][cp - 0x23BA]
            let centre = y + jround((Double(line) - 0.5) * Double(h) / 9)
            fill(g, x, max(y, centre - light / 2), w, light)
            return true
        }
        let heavy = max(light + 1, light * 2)
        if cp >= 0x2580 {
            return cp >= 0xE0B0 ? powerline(g, cp, x, y, w, h, light) : block(g, cp, x, y, w, h, color)
        }
        var arms: String?
        if cp <= 0x254B {
            arms = lines1[cp - 0x2500]
        } else if cp >= 0x2550 && cp <= 0x256C {
            arms = lines2[cp - 0x2550]
        } else if cp >= 0x2574 {
            arms = lines3[cp - 0x2574]
        }
        if let arms = arms, arms != "d" {
            let a = arms.unicodeScalars.map { Int($0.value) - 0x30 }
            let (u, r, d, l) = (a[0], a[1], a[2], a[3])
            if u == 3 || r == 3 || d == 3 || l == 3 {
                doubleLines(g, x, y, w, h, light, u, r, d, l)
            } else {
                lines(g, x, y, w, h, light, heavy, u, r, d, l)
            }
            return true
        }
        switch cp {
        case 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D:
            let n = cp >= 0x254C ? 2 : cp >= 0x2508 ? 4 : 3
            let t = cp & 1 == 0 ? light : heavy
            dashes(g, x, y, w, h, t, n, true)
            return true
        case 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F:
            let n = cp >= 0x254C ? 2 : cp >= 0x2508 ? 4 : 3
            let t = cp & 1 == 0 ? light : heavy
            dashes(g, x, y, w, h, t, n, false)
            return true
        case 0x256D, 0x256E, 0x256F, 0x2570:
            arc(g, cp, x, y, w, h, light)
            return true
        case 0x2571, 0x2572, 0x2573:
            diagonal(g, cp, x, y, w, h, light)
            return true
        default:
            return false
        }
    }

    private static func thickness(_ weight: Int, _ light: Int, _ heavy: Int) -> Int {
        return weight == 2 ? heavy : weight == 0 ? 0 : light
    }

    /// Light and heavy arms: each reaches past the centre by the perpendicular strokes'
    /// half width, so corners and junctions are filled.
    private static func lines(_ g: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ light: Int, _ heavy: Int,
                              _ u: Int, _ r: Int, _ d: Int, _ l: Int) {
        let tu = thickness(u, light, heavy)
        let tr = thickness(r, light, heavy)
        let td = thickness(d, light, heavy)
        let tl = thickness(l, light, heavy)
        let vertical = max(tu, td)
        let horizontal = max(tl, tr)
        if tu > 0 {
            let band = horizontal > 0 ? horizontal : tu
            let end = y + (h - band) / 2 + band
            fill(g, x + (w - tu) / 2, y, tu, end - y)
        }
        if td > 0 {
            let band = horizontal > 0 ? horizontal : td
            let start = y + (h - band) / 2
            fill(g, x + (w - td) / 2, start, td, y + h - start)
        }
        if tl > 0 {
            let band = vertical > 0 ? vertical : tl
            let end = x + (w - band) / 2 + band
            fill(g, x, y + (h - tl) / 2, end - x, tl)
        }
        if tr > 0 {
            let band = vertical > 0 ? vertical : tr
            let start = x + (w - band) / 2
            fill(g, start, y + (h - tr) / 2, x + w - start, tr)
        }
    }

    /// Lines with a double arm. A double arm is two light strokes at ±t from the single
    /// stroke's position; where it meets a perpendicular arm, its outer stroke runs to the far
    /// stroke of that arm and its inner stroke stops at the near one, which draws ╔ ╦ ╬ and
    /// the mixed single/double forms.
    private static func doubleLines(_ g: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ t: Int,
                                    _ u: Int, _ r: Int, _ d: Int, _ l: Int) {
        let up = u > 0
        let right = r > 0
        let down = d > 0
        let left = l > 0
        let vx = x + (w - t) / 2
        let hy = y + (h - t) / 2
        let vDouble = u == 3 || d == 3
        let hDouble = l == 3 || r == 3
        let xa = vDouble ? vx - t : vx
        let xb = vDouble ? vx + t : vx
        let ya = hDouble ? hy - t : hy
        let yb = hDouble ? hy + t : hy
        let bottom = y + h
        let far = x + w
        if up {
            if u == 3 {
                vRect(g, xa, y, (left ? ya : yb) + t, t)
                vRect(g, xb, y, (right ? ya : yb) + t, t)
            } else {
                let end = left && right ? (down ? yb : ya) + t : yb + t
                vRect(g, vx, y, end, t)
            }
        }
        if down {
            if d == 3 {
                vRect(g, xa, left ? yb : ya, bottom, t)
                vRect(g, xb, right ? yb : ya, bottom, t)
            } else {
                let start = left && right ? (up ? ya : yb) : ya
                vRect(g, vx, start, bottom, t)
            }
        }
        if left {
            if l == 3 {
                hRect(g, ya, x, (up ? xa : xb) + t, t)
                hRect(g, yb, x, (down ? xa : xb) + t, t)
            } else {
                let end = up && down ? (right ? xb : xa) + t : xb + t
                hRect(g, hy, x, end, t)
            }
        }
        if right {
            if r == 3 {
                hRect(g, ya, up ? xb : xa, far, t)
                hRect(g, yb, down ? xb : xa, far, t)
            } else {
                let start = up && down ? (left ? xa : xb) : xa
                hRect(g, hy, start, far, t)
            }
        }
    }

    private static func vRect(_ g: CGContext, _ x: Int, _ y0: Int, _ y1: Int, _ t: Int) {
        if y1 > y0 {
            fill(g, x, y0, t, y1 - y0)
        }
    }

    private static func hRect(_ g: CGContext, _ y: Int, _ x0: Int, _ x1: Int, _ t: Int) {
        if x1 > x0 {
            fill(g, x0, y, x1 - x0, t)
        }
    }

    private static func dashes(_ g: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ t: Int, _ n: Int,
                               _ horizontal: Bool) {
        let length = horizontal ? w : h
        let slot = Double(length) / Double(n)
        let gap = max(1, jround(slot / 3))
        for i in 0..<n {
            let a = jround(Double(i) * slot + Double(gap) / 2)
            let b = jround(Double(i + 1) * slot - Double(gap) / 2)
            if b <= a {
                continue
            }
            if horizontal {
                fill(g, x + a, y + (h - t) / 2, b - a, t)
            } else {
                fill(g, x + (w - t) / 2, y + a, t, b - a)
            }
        }
    }

    /// ╭ ╮ ╯ ╰: straight to the cell edges, rounded through the centre.
    private static func arc(_ g: CGContext, _ cp: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ t: Int) {
        let cx = Double(x + (w - t) / 2) + Double(t) / 2
        let cy = Double(y + (h - t) / 2) + Double(t) / 2
        let radius = Double(min(w, h)) / 2
        let toRight = cp == 0x256D || cp == 0x2570
        let toBottom = cp == 0x256D || cp == 0x256E
        let ex = Double(toRight ? x + w : x)
        let ey = Double(toBottom ? y + h : y)
        let sx = toRight ? min(cx + radius, ex) : max(cx - radius, ex)
        let sy = toBottom ? min(cy + radius, ey) : max(cy - radius, ey)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: ey))
        path.addLine(to: CGPoint(x: cx, y: sy))
        path.addQuadCurve(to: CGPoint(x: sx, y: cy), control: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: ex, y: cy))
        stroke(g, path, t)
    }

    private static func diagonal(_ g: CGContext, _ cp: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ t: Int) {
        let path = CGMutablePath()
        if cp != 0x2572 {
            path.move(to: CGPoint(x: x + w, y: y))
            path.addLine(to: CGPoint(x: x, y: y + h))
        }
        if cp != 0x2571 {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + w, y: y + h))
        }
        // clipped to the cell so the butt ends of neighbouring diagonals meet exactly
        g.saveGState()
        g.clip(to: CGRect(x: x, y: y, width: w, height: h))
        stroke(g, path, t)
        g.restoreGState()
    }

    private static func stroke(_ g: CGContext, _ path: CGPath, _ t: Int) {
        g.saveGState()
        g.setShouldAntialias(true)
        g.setLineWidth(CGFloat(t))
        g.setLineCap(.butt)
        g.setLineJoin(.round)
        g.addPath(path)
        g.strokePath()
        g.restoreGState()
    }

    private static func block(_ g: CGContext, _ cp: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                              _ color: CGColor) -> Bool {
        switch cp {
        case 0x2580:
            fill(g, x, y, w, h / 2)
        case 0x2581...0x2588:
            let eighths = cp - 0x2580
            let top = y + h - jround(Double(h * eighths) / 8)
            fill(g, x, top, w, y + h - top)
        case 0x2589...0x258F:
            let eighths = 8 - (cp - 0x2588)
            fill(g, x, y, jround(Double(w * eighths) / 8), h)
        case 0x2590:
            fill(g, x + w / 2, y, w - w / 2, h)
        case 0x2591, 0x2592, 0x2593:
            let alpha = CGFloat((cp - 0x2590) * 64) / 255
            g.setFillColor(color.copy(alpha: alpha) ?? color)
            fill(g, x, y, w, h)
            g.setFillColor(color)
        case 0x2594:
            fill(g, x, y, w, max(1, jround(Double(h) / 8)))
        case 0x2595:
            let bw = max(1, jround(Double(w) / 8))
            fill(g, x + w - bw, y, bw, h)
        default:
            quadrants(g, cp, x, y, w, h)
        }
        return true
    }

    /// U+2596–259F: bit 1 upper left, 2 upper right, 4 lower left, 8 lower right.
    private static let quadrantBits = [4, 8, 1, 1 | 4 | 8, 1 | 8, 1 | 2 | 4, 1 | 2 | 8, 2, 2 | 4, 2 | 4 | 8]

    private static func quadrants(_ g: CGContext, _ cp: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        let bits = quadrantBits[cp - 0x2596]
        let hw = w / 2
        let hh = h / 2
        if bits & 1 != 0 { fill(g, x, y, hw, hh) }
        if bits & 2 != 0 { fill(g, x + hw, y, w - hw, hh) }
        if bits & 4 != 0 { fill(g, x, y + hh, hw, h - hh) }
        if bits & 8 != 0 { fill(g, x + hw, y + hh, w - hw, h - hh) }
    }

    /// Powerline: E0B0 solid right-pointing triangle, E0B1 its outline chevron, E0B2/E0B3
    /// the left-pointing pair.
    private static func powerline(_ g: CGContext, _ cp: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                                  _ t: Int) -> Bool {
        let pointsRight = cp <= 0xE0B1
        let tipX = Double(pointsRight ? x + w : x)
        let baseX = Double(pointsRight ? x : x + w)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: baseX, y: Double(y)))
        path.addLine(to: CGPoint(x: tipX, y: Double(y) + Double(h) / 2))
        path.addLine(to: CGPoint(x: baseX, y: Double(y + h)))
        if cp == 0xE0B0 || cp == 0xE0B2 {
            path.closeSubpath()
            g.saveGState()
            g.setShouldAntialias(true)
            g.addPath(path)
            g.fillPath()
            g.restoreGState()
        } else {
            stroke(g, path, t)
        }
        return true
    }

    /// Braille dot bits (dots 1–8) by column and row: dots 1-2-3-7 down the left, 4-5-6-8
    /// down the right.
    private static let brailleBit = [[0x01, 0x02, 0x04, 0x40], [0x08, 0x10, 0x20, 0x80]]

    /// The cell as a 2 × 4 grid of equal sub-cells, a round dot centred in each set one.
    /// Centres are at exactly a quarter and three quarters of the width and at odd eighths
    /// of the height — fractional positions, antialiased — so the dot pitch is the same
    /// inside a cell and across its edges. Snapping dots to whole pixels cannot do that
    /// when the cell is not a multiple of 2 × 4 pixels (a 17 × 33 device-pixel cell has a
    /// pitch of 8.5 × 8.25: gaps would alternate 8 and 9).
    static func braille(_ g: CGContext, _ dots: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        if dots == 0 {
            return
        }
        let d = max(1, min(Double(w) / 2, Double(h) / 4) * 0.7)
        g.setShouldAntialias(true)
        for column in 0..<2 {
            let cx = Double(x) + Double(2 * column + 1) * Double(w) / 4
            for row in 0..<4 {
                if dots & brailleBit[column][row] == 0 {
                    continue
                }
                let cy = Double(y) + Double(2 * row + 1) * Double(h) / 8
                g.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            }
        }
    }
}
