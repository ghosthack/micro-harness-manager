import XCTest
@testable import MicrohmVT

/**
 * Real program output recorded with `vt/scripts/record.py` (see the file names for the program
 * and the terminal size): checked against golden state at checkpoints along the stream, run
 * through the serializer round trip, and fed in random chunks.
 */
final class RecordingsTests: XCTestCase {

    /** Compare after every this many bytes (a pty read's worth). */
    private static let CHECKPOINT = 256

    struct Recording {
        let file: String
        let columns: Int
        let rows: Int

        func bytes() -> [UInt8] {
            return Golden.data("recordings/" + file)
        }
    }

    static func recordings() -> [Recording] {
        return ["ls-color.80x24.bin", "ls-narrow.20x10.bin", "vim.80x24.bin", "less.80x24.bin",
                "man.80x24.bin", "git-log-graph.100x30.bin", "zsh.80x24.bin", "bash.80x24.bin",
                "unicode.40x16.bin", "curses.80x24.bin", "inline-viewport.80x24.bin"].map { f in
            let size = f.split(separator: ".")[1].split(separator: "x")
            return Recording(file: f, columns: Int(size[0])!, rows: Int(size[1])!)
        }
    }

    func testSerializerRoundTripsAlongTheStream() {
        for r in RecordingsTests.recordings() {
            let data = r.bytes()
            let e = TerminalEmulator(r.columns, r.rows, 1000)
            let step = max(64, data.count / 20)
            var off = 0
            while off < data.count {
                e.feed(data, off, min(step, data.count - off))
                ModelAssert.roundTrip(e, 1000, "\(r.file) at \(off): ")
                off += step
            }
        }
    }

    func testChunkingDoesNotMatter() {
        for r in RecordingsTests.recordings() {
            let data = r.bytes()
            let whole = TerminalEmulator(r.columns, r.rows, 1000)
            whole.feed(data)
            let pieces = TerminalEmulator(r.columns, r.rows, 1000)
            var rnd = JavaRandom(Int64(data.count))
            var off = 0
            while off < data.count {
                let n = min(1 + rnd.nextInt(17), data.count - off)
                pieces.feed(data, off, n)
                off += n
            }
            XCTAssertEqual(ScreenSerializer.serialize(whole, 1000), ScreenSerializer.serialize(pieces, 1000), r.file)
            XCTAssertEqual(whole.title(), pieces.title(), r.file)
        }
    }

    /** `feed` (tokens straight from the tokenizer, the app's path) and `apply` of the
     * tokenizer's batches (the daemon's path) leave the same state, chunk for chunk; and the
     * tokens are the same. */
    func testFeedingMatchesApplyingTokens() {
        for r in RecordingsTests.recordings() {
            let data = r.bytes()
            let fed = TerminalEmulator(r.columns, r.rows, 1000)
            let applied = TerminalEmulator(r.columns, r.rows, 1000)
            let batches = VtTokenizer()
            let sinks = VtTokenizer()
            var rnd = JavaRandom(Int64(data.count) * 31)
            var off = 0
            while off < data.count {
                let n = min(1 + rnd.nextInt(300), data.count - off)
                fed.feed(data, off, n)
                let tokens = batches.feed(data, off, n).tokens
                applied.apply(tokens)
                var sunk: [String] = []
                sinks.feed(data, off, n) { kind, b in sunk.append("\(kind):\(Array(b))") }
                XCTAssertEqual(tokens.map { "\($0.kind):\($0.bytes)" }, sunk, "\(r.file) at byte \(off)")
                off += n
            }
            ModelAssert.assertSameState(fed, applied, 1000, r.file + ": ")
            XCTAssertEqual(applied.title(), fed.title())
        }
    }

    /** The state at every checkpoint, chained into a digest recorded at each one, then the
     * final state in full. */
    func testMatchesGolden() {
        for r in RecordingsTests.recordings() {
            let s = Subject(r.columns, r.rows, 1000)
            let chain = Snapshot.Chain()
            var out = ""
            let data = r.bytes()
            var off = 0
            while off < data.count {
                let n = min(RecordingsTests.CHECKPOINT, data.count - off)
                s.feed(Array(data[off..<(off + n)]))
                chain.add(s.snapshot())
                out += "byte \(off + n) \(chain.value())\n"
                off += RecordingsTests.CHECKPOINT
            }
            out += s.snapshot()
            Golden.check("recordings/" + r.file.replacingOccurrences(of: ".bin", with: ".txt"), out)
        }
    }
}
