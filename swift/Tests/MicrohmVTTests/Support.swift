import Foundation
import XCTest
@testable import MicrohmVT

// Ports of the Java test helpers: Golden, Snapshot, Subject, VtPipe, ModelAssert, plus
// java.util.Random and SHA-256 (the fuzz goldens depend on both, bit for bit).

let E = "\u{1b}"
let C = "\u{1b}["

func bytes(_ s: String) -> [UInt8] {
    return Array(s.utf8)
}

// MARK: - Golden

enum Golden {
    static func root() -> URL {
        return Bundle.module.url(forResource: "golden", withExtension: nil)!
    }

    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: root().appendingPathComponent(name)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func data(_ name: String) -> [UInt8] {
        return [UInt8](try! Data(contentsOf: root().appendingPathComponent(name)))
    }

    /** Asserts `actual` equals the golden file `name` (compared as scalars, like Java). */
    static func check(_ name: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let expected = read(name) else {
            XCTFail("missing golden file \(name)", file: file, line: line)
            return
        }
        if !expected.unicodeScalars.elementsEqual(actual.unicodeScalars) {
            XCTFail("differs from golden \(name)" + firstDifference(expected, actual), file: file, line: line)
        }
    }

    private static func firstDifference(_ expected: String, _ actual: String) -> String {
        let a = ModeTracker.split(expected, "\n")
        let b = ModeTracker.split(actual, "\n")
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<end>"
            let y = i < b.count ? b[i] : "<end>"
            if !x.unicodeScalars.elementsEqual(y.unicodeScalars) {
                return " at line \(i + 1):\n  expected: \(x)\n  actual:   \(y)"
            }
        }
        return ""
    }

    /** A file-name-safe form of a case name. */
    static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for c in name.lowercased().unicodeScalars {
            if (c.value >= 0x61 && c.value <= 0x7A) || (c.value >= 0x30 && c.value <= 0x39) {
                out.unicodeScalars.append(c)
                dash = false
            } else if !dash {
                out += "-"
                dash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

// MARK: - ModelAssert

enum ModelAssert {
    /** Feeds `a`'s redraw into a fresh emulator of the same size and asserts equality; returns
     * the copy. */
    @discardableResult
    static func roundTrip(_ a: TerminalEmulator, _ historyLines: Int, _ context: String = "",
                          file: StaticString = #filePath, line: UInt = #line) -> TerminalEmulator {
        a.lock().lock()
        let redraw = ScreenSerializer.serialize(a, historyLines)
        a.lock().unlock()
        let b = TerminalEmulator(a.columns(), a.rows(), historyLines)
        b.feed(redraw)
        assertSameState(a, b, historyLines, context, file: file, line: line)
        return b
    }

    /** Returns the first difference, or nil. */
    static func difference(_ a: TerminalEmulator, _ b: TerminalEmulator, _ historyLines: Int) -> String? {
        if a.columns() != b.columns() { return "columns" }
        if a.rows() != b.rows() { return "rows" }
        let sa = describeState(a)
        let sb = describeState(b)
        if sa != sb { return "cursor, pen and modes:\n  \(sa)\n  \(sb)" }
        if a.savedCursor(false) != b.savedCursor(false) {
            return "main saved cursor \(String(describing: a.savedCursor(false))) vs \(String(describing: b.savedCursor(false)))"
        }
        if a.alternateScreen() && a.savedCursor(true) != b.savedCursor(true) {
            return "alternate saved cursor"
        }
        let history = min(historyLines, a.mainHistorySize())
        if history != b.mainHistorySize() { return "history size \(history) vs \(b.mainHistorySize())" }
        var i = -history
        while i < 0 {
            if let d = lineDifference(a.mainLine(i), b.mainLine(i), a.columns(), true, "history[\(i)]") { return d }
            i += 1
        }
        for y in 0..<a.rows() {
            if let d = lineDifference(a.mainLine(y), b.mainLine(y), a.columns(), y < a.rows() - 1, "main row \(y)") {
                return d
            }
        }
        if a.alternateScreen() {
            for y in 0..<a.rows() {
                if let d = lineDifference(a.line(y), b.line(y), a.columns(), y < a.rows() - 1, "alternate row \(y)") {
                    return d
                }
            }
        }
        return nil
    }

    static func assertSameState(_ a: TerminalEmulator, _ b: TerminalEmulator, _ historyLines: Int, _ context: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        if let d = difference(a, b, historyLines) {
            XCTFail(context + d, file: file, line: line)
        }
    }

    /** Everything but the cells, as one comparable string. */
    static func describeState(_ t: TerminalEmulator) -> String {
        var tabs = ""
        for x in 0..<t.columns() where t.isTabStop(x) {
            tabs += "\(x),"
        }
        return "cursor=\(t.cursorRow()),\(t.cursorColumn())" + (t.cursorPendingWrap() ? "+wrap" : "")
            + " pen=" + Style.describe(t.pen())
            + " visible=\(t.cursorVisible()) shape=\(t.cursorShape()) blink=\(t.cursorBlink())"
            + " alt=\(t.alternateScreen()) paste=\(t.bracketedPaste())"
            + " ckm=\(t.applicationCursorKeys()) keypad=\(t.applicationKeypad())"
            + " mouse=\(t.mouseTracking())/\(t.mouseEncoding()) focus=\(t.focusReporting())"
            + " sync=\(t.synchronizedOutput()) rv=\(t.reverseVideo()) awm=\(t.autoWrap())"
            + " decom=\(t.originMode()) irm=\(t.insertMode()) lnm=\(t.newLineMode())"
            + " region=\(t.scrollTop())-\(t.scrollBottom()) kitty=\(t.kittyKeyboardFlags())"
            + " charsets=\(t.charsetState()) title=\(t.title()) tabs=\(tabs)"
    }

    static func lineDifference(_ a: Line, _ b: Line, _ width: Int, _ compareWrapped: Bool, _ label: String) -> String? {
        if compareWrapped && a.isWrapped() != b.isWrapped() {
            return "\(label) wrapped"
        }
        for x in 0..<width {
            if !cell(a, x).unicodeScalars.elementsEqual(cell(b, x).unicodeScalars) {
                return "\(label) cell \(x) in\n  \(a)\n  \(b)"
            }
            if Style.describe(a.style(x)) != Style.describe(b.style(x)) {
                return "\(label) style \(x)"
            }
        }
        return nil
    }

    private static func cell(_ line: Line, _ x: Int) -> String {
        if line.isWideTail(x) {
            return "<tail>"
        }
        let text = line.text(x)
        return text.isEmpty ? " " : text
    }
}

// MARK: - Snapshot

enum Snapshot {
    static func of(_ terminal: HeadlessTerminal, _ replies: [String]) -> String {
        let e = terminal.emulator()
        e.lock().lock()
        defer { e.lock().unlock() }
        var sb = "size \(e.columns())x\(e.rows()) history \(e.historySize())\n"
        sb += "state " + escape(ModelAssert.describeState(e)) + "\n"
        sb += "modes " + escape(terminal.modes().description) + "\n"
        for reply in replies {
            sb += "reply " + escape(reply) + "\n"
        }
        for y in 0..<e.rows() {
            let line = e.line(y)
            let num = String(y)
            sb += String(repeating: " ", count: max(0, 3 - num.count)) + num + (line.isWrapped() ? "+" : " ") + "|"
            for x in 0..<e.columns() {
                if line.isWideTail(x) {
                    continue
                }
                let text = line.text(x)
                sb += text.isEmpty ? " " : escape(text)
            }
            sb += "|\n"
            appendStyles(&sb, line, e.columns())
        }
        return sb
    }

    /** Runs of non-default style: `    cols A-B <style>`. */
    private static func appendStyles(_ sb: inout String, _ line: Line, _ width: Int) {
        var x = 0
        while x < width {
            let style = line.style(x)
            var end = x
            while end + 1 < width && line.style(end + 1) == style {
                end += 1
            }
            if style != Style.default {
                sb += "    cols \(x)-\(end) " + Style.describe(style) + "\n"
            }
            x = end + 1
        }
    }

    /** Printable as is; C0, DEL, C1, backslash and format characters as `\u{..}`. */
    static func escape(_ s: String) -> String {
        var sb = ""
        for c in s.unicodeScalars {
            let cp = c.value
            let cat = c.properties.generalCategory
            if cp == 0x5C || cp < 0x20 || (cp >= 0x7F && cp < 0xA0) || cat == .format || cat == .unassigned
                || cat == .privateUse || cat == .surrogate {
                sb += "\\u{" + String(cp, radix: 16) + "}"
            } else {
                sb.unicodeScalars.append(c)
            }
        }
        return sb
    }

    /** A running SHA-256 over successive snapshots, for streams checked after every step. */
    final class Chain {
        private var digest = SHA256()

        func add(_ snapshot: String) {
            digest.update(Array(snapshot.utf8))
            digest.update([0])
        }

        /** The digest so far (the chain continues). */
        func value() -> String {
            var copy = digest
            let hash = copy.finish()
            return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
        }
    }
}

// MARK: - Subject / VtPipe

/** A `HeadlessTerminal` fed the way the daemon feeds one (tokenised, SGR-normalised),
 * collecting its replies. */
final class Subject {
    let terminal: HeadlessTerminal
    let box = ReplyBox()
    private let tokenizer = VtTokenizer()

    final class ReplyBox {
        var replies: [String] = []
    }

    init(_ columns: Int, _ rows: Int, _ history: Int) {
        let box = self.box
        terminal = HeadlessTerminal(columns, rows, history) { b in
            box.replies.append(String(decoding: b, as: UTF8.self))
        }
    }

    var replies: [String] { box.replies }

    func feed(_ data: [UInt8]) {
        let tokens = tokenizer.feed(data).tokens.map { SgrNormalizer.normalize($0) }
        terminal.apply(tokens)
    }

    func feed(_ s: String) {
        feed(Array(s.utf8))
    }

    func emulator() -> TerminalEmulator {
        return terminal.emulator()
    }

    func snapshot() -> String {
        return Snapshot.of(terminal, box.replies)
    }
}

/** The vt pipeline as the session pump wires it: tokenizer → normaliser → headless terminal,
 * forwarding to clients everything `QueryFilter` does not strip. */
final class VtPipe {
    let tokenizer = VtTokenizer()
    let terminal: HeadlessTerminal
    let box = Subject.ReplyBox()
    var replyBytes: [[UInt8]] = []
    var forwarded: [UInt8] = []
    private let replySink: ReplySinkBox

    final class ReplySinkBox {
        var replies: [[UInt8]] = []
    }

    init(_ columns: Int, _ rows: Int, _ historyLines: Int) {
        let sink = ReplySinkBox()
        replySink = sink
        terminal = HeadlessTerminal(columns, rows, historyLines) { sink.replies.append($0) }
    }

    var replies: [[UInt8]] { replySink.replies }

    func feed(_ chunk: [UInt8], _ off: Int, _ len: Int) {
        let batch = tokenizer.feed(chunk, off, len)
        var normalized: [VtToken] = []
        for token in batch.tokens {
            let n = SgrNormalizer.normalize(token)
            normalized.append(n)
            if !QueryFilter.isServerAnswered(n) {
                forwarded.append(contentsOf: n.bytesToForward())
            }
        }
        terminal.apply(normalized)
        forwarded.append(contentsOf: batch.openStringFragment)
    }

    func feed(_ chunk: [UInt8]) {
        feed(chunk, 0, chunk.count)
    }

    func feed(_ s: String) {
        feed(Array(s.utf8))
    }

    func feedChunked(_ data: [UInt8], _ chunkSize: Int) {
        var off = 0
        while off < data.count {
            feed(data, off, min(chunkSize, data.count - off))
            off += chunkSize
        }
    }
}

// MARK: - java.util.Random

struct JavaRandom {
    private var seed: Int64

    init(_ seed: Int64) {
        self.seed = (seed ^ 0x5DEECE66D) & ((1 << 48) - 1)
    }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
        return Int32(truncatingIfNeeded: seed >> (48 - Int64(bits)))
    }

    mutating func nextInt(_ bound: Int) -> Int {
        precondition(bound > 0)
        let b = Int32(bound)
        if (b & -b) == b {
            return Int(Int32(truncatingIfNeeded: (Int64(b) &* Int64(next(31))) >> 31))
        }
        var bits = next(31)
        var val = bits % b
        while bits &- val &+ (b &- 1) < 0 {
            bits = next(31)
            val = bits % b
        }
        return Int(val)
    }

    mutating func nextBoolean() -> Bool {
        return next(1) != 0
    }
}

// MARK: - SHA-256 (no CryptoKit dependency)

struct SHA256 {
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    mutating func update(_ data: [UInt8]) {
        length += UInt64(data.count)
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 64 {
            block(buffer, offset)
            offset += 64
        }
        if offset > 0 {
            buffer.removeFirst(offset)
        }
    }

    mutating func finish() -> [UInt8] {
        let bitLength = length &* 8
        var pad: [UInt8] = [0x80]
        let rem = (buffer.count + 1) % 64
        pad.append(contentsOf: [UInt8](repeating: 0, count: rem <= 56 ? 56 - rem : 120 - rem))
        for i in (0..<8).reversed() {
            pad.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8)))
        }
        let savedLength = length
        update(pad)
        length = savedLength
        var out: [UInt8] = []
        for v in h {
            out.append(UInt8(v >> 24))
            out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    private mutating func block(_ data: [UInt8], _ offset: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ SHA256.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
}
