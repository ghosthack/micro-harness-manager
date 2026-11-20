/**
 * How many terminal columns a code point occupies: 0 (it attaches to the previous cell —
 * combining marks, format characters such as ZWJ, variation selectors), 1, or 2 (East Asian
 * Wide/Fullwidth and emoji presentation). East Asian Ambiguous characters are 1. The data is
 * the generated `WidthTable` (Unicode 17.0.0, the same version jediterm-core's widecharwidth
 * table uses); the Basic Multilingual Plane is expanded into a 64 KiB lookup on first use, so
 * the common case is one array read.
 *
 * C0/C1 controls and DEL never reach this (the tokenizer and emulator handle them); they
 * report 0.
 */
public enum CharWidth {

    /** The BMP lookup: one byte per code point, allocated once and never freed. */
    static let bmp: UnsafeMutablePointer<UInt8> = {
        let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x10000)
        table.initialize(repeating: 1, count: 0x10000)
        fill(table, WidthTable.wide, 2)
        fill(table, WidthTable.zero, 0)
        for c in 0..<0x20 {
            table[c] = 0
        }
        for c in 0x7F..<0xA0 {
            table[c] = 0
        }
        return table
    }()

    private static func fill(_ table: UnsafeMutablePointer<UInt8>, _ ranges: [Int32], _ width: UInt8) {
        var i = 0
        while i < ranges.count {
            let lo = Int(ranges[i])
            if lo > 0xFFFF {
                break
            }
            let hi = min(Int(ranges[i + 1]), 0xFFFF)
            for c in lo...hi {
                table[c] = width
            }
            i += 2
        }
    }

    /** The column width of `codePoint`: 0, 1 or 2. */
    @inline(__always)
    public static func of(_ codePoint: Int) -> Int {
        if codePoint < 0x10000 {
            return codePoint < 0 ? 0 : Int(bmp[codePoint])
        }
        return supplementary(codePoint)
    }

    private static func supplementary(_ codePoint: Int) -> Int {
        if contains(WidthTable.zero, codePoint) {
            return 0
        }
        return contains(WidthTable.wide, codePoint) ? 2 : 1
    }

    private static func contains(_ ranges: [Int32], _ cp: Int) -> Bool {
        var lo = 0
        var hi = ranges.count / 2 - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if cp < Int(ranges[2 * mid]) {
                hi = mid - 1
            } else if cp > Int(ranges[2 * mid + 1]) {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
