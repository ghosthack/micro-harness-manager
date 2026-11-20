import CoreGraphics
import XCTest
import MicrohmVT
@testable import MicrohmTerminal

/// A black RGBA bitmap drawn y-down, read back per pixel.
final class Bitmap {
    let width: Int
    let height: Int
    let context: CGContext

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// 0xRRGGBB at `(x, y)`, y down.
    func rgb(_ x: Int, _ y: Int) -> Int {
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * context.bytesPerRow + x * 4
        return Int(p[i]) << 16 | Int(p[i + 1]) << 8 | Int(p[i + 2])
    }
}

final class BoxDrawingTests: XCTestCase {

    private let W = 9
    private let H = 18
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Renders `text` one character per cell.
    private func render(_ text: String, _ rows: Int) -> Bitmap {
        let scalars = Array(text.unicodeScalars)
        let columns = scalars.count / rows
        let image = Bitmap(columns * W, rows * H)
        for (i, s) in scalars.enumerated() {
            XCTAssertTrue(BoxDrawing.draw(image.context, Int(s.value), (i % columns) * W, (i / columns) * H, W, H, white))
        }
        return image
    }

    /// Centres of the lit blobs along one pixel row or column, as the midpoints of runs.
    private func runCentres(_ image: Bitmap, _ horizontal: Bool, _ at: Int) -> [Int] {
        var centres: [Int] = []
        let length = horizontal ? image.width : image.height
        var start = -1
        for i in 0...length {
            let lit = i < length && (image.rgb(horizontal ? i : at, horizontal ? at : i) & 0xFF) > 128
            if lit && start < 0 {
                start = i
            } else if !lit && start >= 0 {
                centres.append((start + i - 1) / 2)
                start = -1
            }
        }
        return centres
    }

    func testBrailleIsDrawnForTheWholeBlock() {
        XCTAssertTrue(BoxDrawing.handles(0x2800))
        XCTAssertTrue(BoxDrawing.handles(0x28FF))
        XCTAssertFalse(BoxDrawing.handles(0x2900))
    }

    func testTheBlankPatternDrawsNothing() {
        let image = render("⠀", 1)
        for x in 0..<W {
            for y in 0..<H {
                XCTAssertEqual(image.rgb(x, y), 0)
            }
        }
    }

    /// Three full cells (⣿) side by side and two rows high: the dots form one even grid, so
    /// the gap between cells equals the gap inside a cell, both ways.
    func testFullCellsTileIntoOneEvenGrid() {
        let image = render("⣿⣿⣿⣿⣿⣿", 2)
        let dotRow = BoxDrawing.jround(Double(H) / 8)
        let xs = runCentres(image, true, dotRow)
        XCTAssertEqual(xs.count, 6, "two dots per cell across three cells: \(xs)")
        let ys = runCentres(image, false, BoxDrawing.jround(Double(W) / 4))
        XCTAssertEqual(ys.count, 8, "four dots per cell down two rows: \(ys)")
        for i in 1..<xs.count {
            XCTAssertLessThanOrEqual(abs(Double(xs[i] - xs[i - 1]) - Double(W) / 2), 1, "horizontal pitch: \(xs)")
        }
        for i in 1..<ys.count {
            XCTAssertLessThanOrEqual(abs(Double(ys[i] - ys[i - 1]) - Double(H) / 4), 1, "vertical pitch: \(ys)")
        }
    }

    /// Brightness-weighted centres of the blobs along a band of pixel rows (horizontal) or
    /// columns (vertical) — sub-pixel positions of antialiased dots.
    private func centroids(_ image: Bitmap, _ horizontal: Bool, _ from: Int, _ to: Int) -> [Double] {
        let length = horizontal ? image.width : image.height
        var profile = [Double](repeating: 0, count: length + 1)
        for i in 0..<length {
            for k in from..<to {
                profile[i] += Double(image.rgb(horizontal ? i : k, horizontal ? k : i) & 0xFF)
            }
        }
        var centres: [Double] = []
        var sum = 0.0
        var weighted = 0.0
        for i in 0...length {
            if profile[i] > 0 {
                sum += profile[i]
                weighted += profile[i] * Double(i)
            } else if sum > 0 {
                centres.append(weighted / sum)
                sum = 0
                weighted = 0
            }
        }
        return centres
    }

    /// At the 2× cell of Menlo 14 (17 × 33 device pixels; dot pitch 8.5 × 8.25) the dots are
    /// evenly spaced to a fraction of a pixel, inside cells and across their edges.
    func testRetinaCellsKeepAnEvenPitch() {
        let w = 17
        let h = 33
        let image = Bitmap(3 * w, 2 * h)
        for i in 0..<6 {
            BoxDrawing.draw(image.context, 0x28FF, (i % 3) * w, (i / 3) * h, w, h, white)
        }
        let xs = centroids(image, true, 0, Int(Double(h) / 4))  // the first dot row
        let ys = centroids(image, false, 0, Int(Double(w) / 2)) // the first dot column
        XCTAssertEqual(xs.count, 6, "\(xs)")
        XCTAssertEqual(ys.count, 8, "\(ys)")
        for i in 1..<xs.count {
            XCTAssertEqual(xs[i] - xs[i - 1], Double(w) / 2, accuracy: 0.15, "horizontal pitch: \(xs)")
        }
        for i in 1..<ys.count {
            XCTAssertEqual(ys[i] - ys[i - 1], Double(h) / 4, accuracy: 0.15, "vertical pitch: \(ys)")
        }
    }

    /// Dots 1–8 map to the standard positions: 1 2 3 7 down the left, 4 5 6 8 the right.
    func testDotNumberingFollowsTheStandard() {
        let expected = [[0x01, 0, 0], [0x02, 0, 1], [0x04, 0, 2], [0x40, 0, 3],
                        [0x08, 1, 0], [0x10, 1, 1], [0x20, 1, 2], [0x80, 1, 3]]
        for e in expected {
            let image = render(String(Character(Unicode.Scalar(UInt32(0x2800 + e[0]))!)), 1)
            let cx = BoxDrawing.jround(Double((2 * e[1] + 1) * W) / 4)
            let cy = BoxDrawing.jround(Double((2 * e[2] + 1) * H) / 8)
            XCTAssertGreaterThan(image.rgb(cx, cy) & 0xFF, 128, "dot bit \(e[0])")
            let other = BoxDrawing.jround(Double((2 * (1 - e[1]) + 1) * W) / 4)
            XCTAssertEqual(image.rgb(other, cy), 0, "only that column, bit \(e[0])")
        }
    }

    // MARK: block mosaics

    private func name(_ cp: Int) -> String {
        return Unicode.Scalar(UInt32(cp))!.properties.name!
    }

    private func matching(_ regex: String) -> Int {
        let r = try! NSRegularExpression(pattern: "^(?:" + regex + ")$")
        return BoxDrawing.mosaics.keys.filter { cp in
            let n = name(cp)
            return r.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil
        }.count
    }

    private func count(_ prefix: String) -> Int {
        return BoxDrawing.mosaics.keys.filter { name($0).hasPrefix(prefix) }.count
    }

    func testEverySextantOctantAndEighthBarIsDrawn() {
        XCTAssertEqual(count("BLOCK SEXTANT-"), 60)
        XCTAssertEqual(count("BLOCK OCTANT-"), 230)
        XCTAssertEqual(count("VERTICAL ONE EIGHTH BLOCK-"), 6)
        XCTAssertEqual(count("HORIZONTAL ONE EIGHTH BLOCK-"), 7)
        XCTAssertEqual(matching(".* ONE SIXTEENTH BLOCK"), 16)
        XCTAssertEqual(matching(".* (HALF|THREE QUARTERS) .* ONE QUARTER BLOCK"), 16)
        XCTAssertEqual(matching("(UPPER|RIGHT) (ONE QUARTER|THREE EIGHTHS|FIVE EIGHTHS|THREE QUARTERS|SEVEN EIGHTHS) BLOCK"), 10)
        XCTAssertEqual(matching(".* AND .* ONE EIGHTH BLOCK"), 5)
        XCTAssertEqual(matching("LEFT .* THIRDS? BLOCK"), 2)
        XCTAssertEqual(matching("(UPPER|LOWER) CENTRE ONE QUARTER BLOCK|MIDDLE (LEFT|RIGHT) ONE QUARTER BLOCK"), 4)
        XCTAssertEqual(BoxDrawing.mosaics.count, 60 + 230 + 6 + 7 + 16 + 16 + 10 + 5 + 2 + 4, "nothing else")
        for cp in [0x1FB00, 0x1FB3B, 0x1CD00, 0x1CDE5, 0x1FB70, 0x1FB82, 0x1FB8B, 0x23BA] {
            XCTAssertTrue(BoxDrawing.handles(cp), String(cp, radix: 16))
            XCTAssertEqual(CharWidth.of(cp), 1, "one cell: " + String(cp, radix: 16))
        }
        XCTAssertFalse(BoxDrawing.handles(0x1FB3C), "the wedges are not mosaics")
    }

    func testMosaicsFollowTheirNames() {
        typealias M = BoxDrawing.Mosaic
        XCTAssertEqual(BoxDrawing.mosaic("BLOCK SEXTANT-1"), M(2, 3, 0b000001))
        XCTAssertEqual(BoxDrawing.mosaic("BLOCK SEXTANT-13456"), M(2, 3, 0b111101))
        XCTAssertEqual(BoxDrawing.mosaic("BLOCK OCTANT-23"), M(2, 4, 0b00000110))
        XCTAssertEqual(BoxDrawing.mosaic("VERTICAL ONE EIGHTH BLOCK-3"), M(8, 1, 0b100))
        XCTAssertEqual(BoxDrawing.mosaic("HORIZONTAL ONE EIGHTH BLOCK-1358"), M(1, 8, 0b10010101))
        XCTAssertEqual(BoxDrawing.mosaic("UPPER ONE QUARTER BLOCK"), M(1, 8, 0b11))
        XCTAssertEqual(BoxDrawing.mosaic("RIGHT THREE EIGHTHS BLOCK"), M(8, 1, 0b11100000))
        XCTAssertEqual(BoxDrawing.mosaic("LEFT TWO THIRDS BLOCK"), M(3, 1, 0b11))
        // 4 × 4, bit row * 4 + column
        XCTAssertEqual(BoxDrawing.mosaic("UPPER MIDDLE CENTRE RIGHT ONE SIXTEENTH BLOCK"), M(4, 4, 1 << 6))
        XCTAssertEqual(BoxDrawing.mosaic("RIGHT HALF LOWER ONE QUARTER BLOCK"), M(4, 4, (1 << 14) | (1 << 15)))
        XCTAssertEqual(BoxDrawing.mosaic("LEFT HALF UPPER ONE QUARTER BLOCK"), M(4, 4, 0b0011))
        XCTAssertEqual(BoxDrawing.mosaic("LOWER THREE QUARTERS LEFT ONE QUARTER BLOCK"),
                       M(4, 4, (1 << 4) | (1 << 8) | (1 << 12)))
        XCTAssertEqual(BoxDrawing.mosaic("UPPER CENTRE ONE QUARTER BLOCK"), M(4, 4, 0x0066))
        XCTAssertTrue(BoxDrawing.tiles(0x1FB3C) && BoxDrawing.tiles(0x1CCA6) && !BoxDrawing.tiles(0x2800))
        let corner = BoxDrawing.mosaic("LEFT AND LOWER ONE EIGHTH BLOCK")!
        XCTAssertTrue(corner.mask & 1 != 0 && corner.mask & (1 << 63) != 0 && corner.mask & 2 == 0)
    }

    /// Sextants 1+2 in every cell of a 3 × 3 block, at a cell height not divisible by three:
    /// each row of cells is one unbroken band of a third of the cell.
    func testMosaicsTileWithoutGapsOrSteps() {
        let h = 17
        let image = Bitmap(3 * W, 3 * h)
        for r in 0..<3 {
            for c in 0..<3 {
                BoxDrawing.draw(image.context, 0x1FB02, c * W, r * h, W, h, white)
            }
        }
        for r in 0..<3 {
            let band = r * h + 1
            for x in 0..<(3 * W) {
                XCTAssertGreaterThan(image.rgb(x, band) & 0xFF, 0, "band row \(r) gap at x=\(x)")
            }
            var bandHeight = 0
            for y in (r * h)..<((r + 1) * h) where image.rgb(W, y) & 0xFF > 0 {
                bandHeight += 1
            }
            XCTAssertEqual(bandHeight, BoxDrawing.jround(Double(h) / 3), "a third of the cell, row \(r)")
        }
    }

    func testScanLinesStepDownTheCell() {
        var previous = -1
        for cp in 0x23BA...0x23BD {
            let image = render(String(Character(Unicode.Scalar(UInt32(cp))!)), 1)
            var lit = -1
            for y in 0..<H where lit < 0 && image.rgb(W / 2, y) & 0xFF > 0 {
                lit = y
            }
            XCTAssertGreaterThan(lit, previous, "scan line \(String(cp, radix: 16)) at \(lit)")
            previous = lit
        }
    }

    /// Box-drawing lines meet across cell edges: the top of ┌─┬─┐ and the column under ┬
    /// (│, then ┼) are unbroken.
    func testLinesJoinAcrossCells() {
        let rows = ["┌─┬─┐", "│ │ │", "├─┼─┤"]
        let image = Bitmap(5 * W, 3 * H)
        for (r, row) in rows.enumerated() {
            for (c, s) in row.unicodeScalars.enumerated() where s != " " {
                BoxDrawing.draw(image.context, Int(s.value), c * W, r * H, W, H, white)
            }
        }
        let light = max(1, BoxDrawing.jround(Double(W) / 8))
        let topLine = (H - light) / 2
        for x in (W / 2)...(4 * W + W / 2) {
            XCTAssertGreaterThan(image.rgb(x, topLine) & 0xFF, 0, "top line gap at x=\(x)")
        }
        let vx = 2 * W + (W - light) / 2
        for y in (H / 2)..<(3 * H) {
            XCTAssertGreaterThan(image.rgb(vx, y) & 0xFF, 0, "column gap at y=\(y)")
        }
    }

    /// Every non-empty pattern of a 2 × 4 grid (what an octant-resolution picture needs) is
    /// drawn exactly by some character drawn as geometry, whichever block Unicode put it in.
    func testEveryTwoByFourPatternHasAGeometricCharacter() {
        var patterns = Set<Int>()
        var candidates = Array(BoxDrawing.mosaics.keys)
        candidates.append(contentsOf: 0x2580...0x259F)
        for cp in candidates {
            let image = Bitmap(8, 8)
            BoxDrawing.draw(image.context, cp, 0, 0, 8, 8, white)
            var pattern = 0
            var exact = true
            for row in 0..<4 where exact {
                for column in 0..<2 where exact {
                    var lit = 0
                    for y in (row * 2)..<(row * 2 + 2) {
                        for x in (column * 4)..<(column * 4 + 4) where image.rgb(x, y) == 0xFFFFFF {
                            lit += 1
                        }
                    }
                    if lit == 8 {
                        pattern |= 1 << (row * 2 + column)
                    } else if lit != 0 {
                        exact = false
                    }
                }
            }
            if exact && pattern != 0 {
                patterns.insert(pattern)
            }
        }
        let missing = (1..<256).filter { !patterns.contains($0) }.map { String($0, radix: 2) }
        XCTAssertTrue(missing.isEmpty, "2 × 4 patterns with no geometric character: \(missing)")
    }
}
