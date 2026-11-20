import XCTest
@testable import MicrohmVT

/**
 * Seeded random streams from `VtFuzz`: (1) in its common mode, the state after every operation
 * against a golden digest chain; (2) the serializer round trip, unrestricted, every few
 * operations; (3) feeding and applying tokens agree.
 */
final class FuzzTests: XCTestCase {

    private static let OPS = 1500

    private static func size(_ seed: Int64) -> (Int, Int) {
        let sizes = [(80, 24), (20, 8), (13, 5), (40, 12), (132, 6)]
        return sizes[Int(seed % Int64(sizes.count))]
    }

    func testSerializerRoundTrips() {
        for seed in Int64(1)...40 {
            let (cols, rows) = FuzzTests.size(seed)
            let e = TerminalEmulator(cols, rows, 100)
            let fuzz = VtFuzz(seed, e, .any)
            for i in 0..<FuzzTests.OPS {
                e.feed(bytes(fuzz.next()))
                if i % 25 == 24 {
                    if let d = ModelAssert.difference(e, ModelAssert.roundTripCopy(e, 100), 100) {
                        XCTFail("seed \(seed) op \(i): \(d)")
                    }
                }
            }
        }
    }

    /** `feed` and `apply` of the same tokens agree on unrestricted random streams, fed in
     * random pieces (ops split mid sequence and mid character). */
    func testFeedingMatchesApplyingTokens() {
        for seed in Int64(1)...40 {
            let (cols, rows) = FuzzTests.size(seed)
            let fed = TerminalEmulator(cols, rows, 100)
            let applied = TerminalEmulator(cols, rows, 100)
            let tokenizer = VtTokenizer()
            let fuzz = VtFuzz(seed, fed, .any)
            var rnd = JavaRandom(seed)
            var stream: [UInt8] = []
            for _ in 0..<FuzzTests.OPS {
                stream.append(contentsOf: bytes(fuzz.next()))
            }
            var off = 0
            while off < stream.count {
                let n = min(1 + rnd.nextInt(40), stream.count - off)
                fed.feed(stream, off, n)
                applied.apply(tokenizer.feed(stream, off, n).tokens)
                off += n
            }
            ModelAssert.assertSameState(fed, applied, 100, "seed \(seed): ")
        }
    }

    /** The state after every operation, chained into a digest recorded every 100 operations,
     * then the final state in full. */
    func testMatchesGolden() {
        for seed in Int64(1)...40 {
            let (cols, rows) = FuzzTests.size(seed)
            let s = Subject(cols, rows, 200)
            let fuzz = VtFuzz(seed, s.emulator(), .common)
            let chain = Snapshot.Chain()
            var out = ""
            for i in 0..<FuzzTests.OPS {
                s.feed(fuzz.next())
                chain.add(s.snapshot())
                if i % 100 == 99 {
                    out += "after op \(i + 1) \(chain.value())\n"
                }
            }
            out += s.snapshot()
            Golden.check(String(format: "fuzz/seed-%02d.txt", seed), out)
        }
    }
}

extension ModelAssert {
    /** The redraw of `a` fed into a fresh emulator of the same size. */
    static func roundTripCopy(_ a: TerminalEmulator, _ historyLines: Int) -> TerminalEmulator {
        a.lock().lock()
        let redraw = ScreenSerializer.serialize(a, historyLines)
        a.lock().unlock()
        let b = TerminalEmulator(a.columns(), a.rows(), historyLines)
        b.feed(redraw)
        return b
    }
}
