import XCTest
@testable import MicrohmVT

/** The tokenizer contract (`VtTokenizer`). */
final class VtTokenizerTests: XCTestCase {

    /** All tokens completed by feeding `data` in one chunk. */
    private func tokens(_ data: String) -> [VtToken] {
        return VtTokenizer().feed(bytes(data)).tokens
    }

    private func str(_ b: [UInt8]) -> String {
        return String(decoding: b, as: UTF8.self)
    }

    func testCurlyQuotesAndEmojiAreOneTextToken() {
        let t = tokens("\u{201c}hi\u{201d} 🛑")
        XCTAssertEqual(1, t.count)
        XCTAssertEqual(.text, t[0].kind)
        XCTAssertEqual("\u{201c}hi\u{201d} 🛑", t[0].asString())
    }

    func testBytesAbove0x80AreNeverC1() {
        // 0x9B is the 8-bit CSI introducer; here it is the 2nd byte of U+201C and must stay text.
        let input = bytes("\u{201c}") // E2 80 9C
        let b = VtTokenizer().feed(input)
        XCTAssertEqual(1, b.tokens.count)
        XCTAssertEqual(.text, b.tokens[0].kind)
        XCTAssertEqual(input, b.tokens[0].bytes)
    }

    func testCsiSplitAcrossReads() {
        let tok = VtTokenizer()
        XCTAssertTrue(tok.feed(bytes("\u{1b}[")).tokens.isEmpty)
        XCTAssertTrue(tok.feed(bytes("31")).tokens.isEmpty)
        XCTAssertEqual(bytes("\u{1b}[31"), tok.pending())
        let b = tok.feed(bytes("m"))
        XCTAssertEqual(1, b.tokens.count)
        let t = b.tokens[0]
        XCTAssertEqual(.csi, t.kind)
        XCTAssertEqual("31", t.csiBody())
        XCTAssertEqual("m", t.csiFinal())
    }

    func testLoneEscThenCsiInNextRead() {
        let tok = VtTokenizer()
        let first = tok.feed(bytes("\u{1b}"))
        XCTAssertTrue(first.tokens.isEmpty)
        XCTAssertEqual(bytes("\u{1b}"), tok.pending())
        let second = tok.feed(bytes("[6n"))
        XCTAssertEqual(1, second.tokens.count)
        let t = second.tokens[0]
        XCTAssertEqual(.csi, t.kind)
        XCTAssertEqual("6", t.csiBody())
        XCTAssertEqual("n", t.csiFinal())
    }

    func testOscTerminatedByBel() {
        let t = tokens("\u{1b}]0;title\u{7}")
        XCTAssertEqual(1, t.count)
        XCTAssertEqual(.osc, t[0].kind)
        XCTAssertEqual("\u{1b}]0;title\u{7}", t[0].asString())
    }

    func testOscTerminatedBySt() {
        let t = tokens("\u{1b}]0;title\u{1b}\\")
        XCTAssertEqual(1, t.count)
        XCTAssertEqual(.osc, t[0].kind)
        XCTAssertEqual("\u{1b}]0;title\u{1b}\\", t[0].asString())
    }

    func testOscBodyIsForwardedBeforeTermination() {
        let tok = VtTokenizer()
        let open = tok.feed(bytes("\u{1b}]0;par"))
        XCTAssertTrue(open.tokens.isEmpty)
        // The introducer + partial body were streamed immediately.
        XCTAssertEqual("\u{1b}]0;par", str(open.openStringFragment))
        XCTAssertEqual(bytes("\u{1b}]0;par"), tok.openStringBytes())
        // pending() never reports a string body.
        XCTAssertEqual(0, tok.pending().count)

        let more = tok.feed(bytes("tial"))
        XCTAssertEqual("tial", str(more.openStringFragment))

        let done = tok.feed(bytes("\u{7}"))
        XCTAssertEqual(1, done.tokens.count)
        let t = done.tokens[0]
        XCTAssertEqual(.osc, t.kind)
        XCTAssertEqual("\u{1b}]0;partial\u{7}", t.asString())
        // Only the not-yet-streamed tail (the BEL terminator) is forwarded with the token.
        XCTAssertEqual("\u{7}", str(t.bytesToForward()))
        XCTAssertEqual(0, done.openStringFragment.count)
    }

    func testUnterminatedOscThenHugeTextStreamsWithoutStalling() {
        let tok = VtTokenizer()
        var forwarded = 0
        forwarded += tok.feed(bytes("\u{1b}]1337;File=")).openStringFragment.count
        // 100 KiB of "text" that is actually still OSC body (never terminated).
        let big = [UInt8](repeating: UInt8(ascii: "A"), count: 100 * 1024)
        let b = tok.feed(big)
        forwarded += b.openStringFragment.count
        // Nothing was held from clients: everything fed so far was forwarded as fragments.
        XCTAssertTrue(forwarded >= 100 * 1024)
        // Over the 64 KiB cap the body is given up, but the string is still open: what follows
        // is skipped (and streamed), not tokenized as text.
        XCTAssertEqual(bytes("\u{1b}X"), tok.openStringBytes())
        let still = tok.feed(bytes("hi"))
        XCTAssertTrue(still.tokens.isEmpty)
        XCTAssertEqual("hi", str(still.openStringFragment))
        // The terminator ends it: its unstreamed bytes come as a DISCARDED token, in order.
        let after = tok.feed(bytes("x\u{7}hi"))
        XCTAssertEqual([.discarded, .text], after.tokens.map { $0.kind })
        XCTAssertEqual("x\u{7}", after.tokens[0].asString())
        XCTAssertEqual("hi", after.tokens[1].asString())
        XCTAssertEqual(0, tok.openStringBytes().count)
    }

    /** The tokens and forwarded bytes of `data` fed in pieces of `chunk` bytes. */
    private func fedInChunks(_ data: [UInt8], _ chunk: Int, _ forwarded: inout [UInt8]) -> String {
        let tok = VtTokenizer()
        var kinds = ""
        var off = 0
        while off < data.count {
            let b = tok.feed(data, off, min(chunk, data.count - off))
            for t in b.tokens {
                // Text may be split differently; what matters is which sequences are seen.
                if t.kind != .text && t.kind != .discarded {
                    kinds += "\(t.kind)\(t.bytes.count) "
                } else if t.kind == .text {
                    kinds += t.asString()
                }
                forwarded.append(contentsOf: t.bytesToForward())
            }
            forwarded.append(contentsOf: b.openStringFragment)
            off += chunk
        }
        return kinds
    }

    func testAnOverlongStringIsSkippedTheSameHoweverItIsChunked() {
        for terminator in ["\u{7}", "\u{1b}\\"] {
            var data = bytes("a\u{1b}Pq")
            var body = [UInt8](repeating: UInt8(ascii: "~"), count: 70_000)
            body[69_000] = 0x1B // an ESC in the body that is not a terminator
            data += body
            data += bytes(terminator + "b\u{1b}[1mc")
            let expected = "abCSI4 c"
            for chunk in [data.count, 1, 7, 4096, VtTokenizer.maxStringLength] {
                var forwarded: [UInt8] = []
                XCTAssertEqual(expected, fedInChunks(data, chunk, &forwarded), "chunk \(chunk)")
                // Clients get every byte, in order: their tokenizers skip the same string.
                XCTAssertEqual(data, forwarded, "chunk \(chunk)")
            }
        }
    }

    func testAStringAtTheCapIsStillAToken() {
        var data = [UInt8](repeating: UInt8(ascii: "x"), count: VtTokenizer.maxStringLength + 1)
        data[0] = 0x1B
        data[1] = UInt8(ascii: "]")
        data[data.count - 1] = 0x07 // the terminator is the byte past the cap
        for chunk in [data.count, 1000] {
            var ignored: [UInt8] = []
            XCTAssertEqual("OSC\(data.count) ", fedInChunks(data, chunk, &ignored))
        }
    }

    func testAttachingDuringASkippedStringGetsAnIntroducerThatSkipsTheRest() {
        let tok = VtTokenizer()
        let big = [UInt8](repeating: UInt8(ascii: "A"), count: 70_000)
        _ = tok.feed(bytes("\u{1b}]52;c;"))
        _ = tok.feed(big)
        _ = tok.feed(bytes("\u{1b}")) // half of the ESC \ terminator
        let client = VtTokenizer()
        XCTAssertTrue(client.feed(tok.openStringBytes()).tokens.isEmpty)
        let rest = client.feed(bytes("\\ok")).tokens
        XCTAssertEqual("ok", rest.last!.asString())
        XCTAssertEqual(.text, rest.last!.kind)
        XCTAssertEqual(2, rest.count)
    }

    func testEndOfStreamInASkippedStringFlushesWhatWasNotStreamed() {
        let tok = VtTokenizer()
        var big = [UInt8](repeating: UInt8(ascii: "A"), count: 70_000)
        big[0] = 0x1B
        big[1] = UInt8(ascii: "P")
        XCTAssertEqual(70_000, tok.feed(big).openStringFragment.count)
        XCTAssertTrue(tok.flush().tokens.isEmpty)
        XCTAssertEqual("z", tok.feed(bytes("z")).tokens.first!.asString())
    }

    func testDcsWithEmbeddedEscEscBracketStaysIntact() {
        // ESC P ... ESC ESC [ ... ESC \  — the inner "ESC ESC [" is tmux-style passthrough.
        let dcs = "\u{1b}Pq\u{1b}\u{1b}[2;3m data \u{1b}\\"
        let t = tokens(dcs)
        XCTAssertEqual(1, t.count)
        XCTAssertEqual(.string, t[0].kind)
        XCTAssertEqual(dcs, t[0].asString())
    }

    func testUtf8CodePointSplitAcrossReads() {
        let emoji = bytes("🛑") // F0 9F 9B 91
        let tok = VtTokenizer()
        let first = tok.feed(emoji, 0, 2)
        XCTAssertTrue(first.tokens.isEmpty)
        XCTAssertEqual([emoji[0], emoji[1]], tok.pending())
        let second = tok.feed(emoji, 2, 2)
        XCTAssertEqual(1, second.tokens.count)
        XCTAssertEqual(emoji, second.tokens[0].bytes)
        XCTAssertEqual("🛑", second.tokens[0].asString())
    }

    func testOverlongCsiWithoutFinalIsFlushedAsText() {
        let s = "\u{1b}[" + String(repeating: "1;", count: 40) // > 64 bytes, still no final byte
        let t = tokens(s)
        XCTAssertFalse(t.isEmpty)
        XCTAssertEqual(.text, t[0].kind)
        // The bytes are preserved (nothing is lost when the cap trips).
        XCTAssertEqual(bytes(s), t.flatMap { $0.bytes })
    }

    func testC0ControlsAreTheirOwnTokensEvenMidText() {
        let t = tokens("ab\u{7}cd")
        XCTAssertEqual(3, t.count)
        XCTAssertEqual(.text, t[0].kind)
        XCTAssertEqual("ab", t[0].asString())
        XCTAssertEqual(.control, t[1].kind)
        XCTAssertEqual([0x07], t[1].bytes)
        XCTAssertEqual("cd", t[2].asString())
    }

    func testReassemblyIsByteExactAcrossChunkSizes() {
        let input = bytes("plain \u{1b}[1;31mred\u{1b}[m \u{201c}q\u{201d} 🛑 "
            + "\u{1b}]0;t\u{7} \u{1b}Px\u{1b}\\ done\u{1b}[6n")
        for chunk in 1...input.count {
            let tok = VtTokenizer()
            var out: [UInt8] = []
            var off = 0
            while off < input.count {
                let b = tok.feed(input, off, min(chunk, input.count - off))
                for t in b.tokens {
                    out += t.bytesToForward()
                }
                out += b.openStringFragment
                off += chunk
            }
            // The input ends on a complete CSI, so nothing is held back.
            XCTAssertEqual(input, out, "chunk size \(chunk)")
        }
    }

    func testSinkSeesTheSameTokensAsTheBatch() {
        let input = bytes("x\u{1b}[1mé\u{7}\u{1b}]2;t\u{1b}\\\u{1b}(0q")
        for chunk in 1...input.count {
            let batches = VtTokenizer()
            let sinks = VtTokenizer()
            var a: [String] = []
            var b: [String] = []
            var off = 0
            while off < input.count {
                let n = min(chunk, input.count - off)
                a += batches.feed(input, off, n).tokens.map { "\($0.kind):\($0.bytes)" }
                sinks.feed(input, off, n) { kind, buf in b.append("\(kind):\(Array(buf))") }
                off += n
            }
            XCTAssertEqual(a, b, "chunk \(chunk)")
        }
    }
}
