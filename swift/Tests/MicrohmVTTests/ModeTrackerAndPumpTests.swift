import XCTest
@testable import MicrohmVT

final class ModeTrackerTests: XCTestCase {

    private func observe(_ tracker: ModeTracker, _ s: String) {
        for t in VtTokenizer().feed(bytes(s)).tokens {
            tracker.observe(SgrNormalizer.normalize(t))
        }
    }

    private func track(_ s: String) -> HeadlessTerminal.Modes {
        let tracker = ModeTracker(24)
        observe(tracker, s)
        return tracker.snapshot()
    }

    func testModes() {
        XCTAssertTrue(track("\u{1b}[?2004h").bracketedPaste)
        XCTAssertFalse(track("\u{1b}[?2004h\u{1b}[?2004l").bracketedPaste)
        XCTAssertTrue(track("\u{1b}[?1h").applicationCursorKeys)
        XCTAssertTrue(track("\u{1b}=").applicationKeypad)
        XCTAssertFalse(track("\u{1b}=\u{1b}>").applicationKeypad)
        XCTAssertTrue(track("").autoWrap)
        XCTAssertFalse(track("\u{1b}[?7l").autoWrap)
        XCTAssertTrue(track("").cursorVisible)
        XCTAssertFalse(track("\u{1b}[?25l").cursorVisible)
        XCTAssertTrue(track("\u{1b}[?6h").originMode)
        XCTAssertEqual(1000, track("\u{1b}[?1000h").mouseTrackingMode)
        XCTAssertEqual(1002, track("\u{1b}[?1002h").mouseTrackingMode)
        XCTAssertEqual(1003, track("\u{1b}[?1003h").mouseTrackingMode)
        XCTAssertEqual(0, track("\u{1b}[?1000h\u{1b}[?1000l").mouseTrackingMode)
        XCTAssertTrue(track("\u{1b}[?1006h").mouseSgr)
        XCTAssertTrue(track("\u{1b}[?1004h").focusReporting)
        XCTAssertTrue(track("\u{1b}[?1049h").alternateScreen)
        XCTAssertFalse(track("\u{1b}[?1049h\u{1b}[?1049l").alternateScreen)
        XCTAssertTrue(track("\u{1b}[?47h").alternateScreen)
        XCTAssertEqual(4, track("\u{1b}[4 q").cursorShape)
        XCTAssertEqual(1, track("\u{1b}[0 q").cursorShape)
        XCTAssertEqual("hello", track("\u{1b}]0;hello\u{7}").title)
        XCTAssertEqual("win", track("\u{1b}]2;win\u{1b}\\").title)
    }

    func testReportedCwd() {
        let tracker = ModeTracker(24)
        observe(tracker, "\u{1b}]7;file://myhost/home/me%20dir\u{7}")
        XCTAssertEqual("/home/me dir", tracker.reportedCwd())
        let nine = ModeTracker(24)
        observe(nine, "\u{1b}]9;9;/tmp/work\u{7}")
        XCTAssertEqual("/tmp/work", nine.reportedCwd())
        XCTAssertNil(ModeTracker(24).reportedCwd())
    }

    func testRisResetsEverything() {
        let tracker = ModeTracker(24)
        observe(tracker, "\u{1b}[?7l\u{1b}[?25l\u{1b}[?2004h\u{1b}[?1000h\u{1b}[4 q\u{1b}=\u{1b}[3;20r")
        observe(tracker, "\u{1b}c")
        let m = tracker.snapshot()
        XCTAssertTrue(m.autoWrap)
        XCTAssertTrue(m.cursorVisible)
        XCTAssertFalse(m.bracketedPaste)
        XCTAssertEqual(0, m.mouseTrackingMode)
        XCTAssertEqual(0, m.cursorShape)
        XCTAssertFalse(m.applicationKeypad)
        XCTAssertEqual(1, m.scrollTop)
        XCTAssertEqual(24, m.scrollBottom)
    }

    func testScrollRegionClampedAndValidated() {
        let m = track("\u{1b}[3;20r")
        XCTAssertEqual(3, m.scrollTop)
        XCTAssertEqual(20, m.scrollBottom)
        XCTAssertEqual(1, track("\u{1b}[3;20r\u{1b}[r").scrollTop)
        XCTAssertEqual(24, track("\u{1b}[3;20r\u{1b}[r").scrollBottom)
        XCTAssertEqual(24, track("\u{1b}[3;99r").scrollBottom)
        XCTAssertEqual(3, track("\u{1b}[3;20r\u{1b}[9;9r").scrollTop)
    }

    private func apply(_ term: HeadlessTerminal, _ tracker: ModeTracker, _ s: String) {
        var norm: [VtToken] = []
        for t in VtTokenizer().feed(bytes(s)).tokens {
            let n = SgrNormalizer.normalize(t)
            norm.append(n)
            tracker.observe(n)
        }
        term.apply(norm)
    }

    func testScrollRegionResetsOnResizeLikeTheEmulator() {
        let term = HeadlessTerminal(80, 24, 100) { _ in }
        let tracker = ModeTracker(24)
        apply(term, tracker, "\u{1b}[3;20r")
        XCTAssertEqual(3, term.modes().scrollTop)
        XCTAssertEqual(20, term.modes().scrollBottom)
        term.resize(80, 30)
        tracker.resized(30)
        XCTAssertEqual(1, term.modes().scrollTop)
        XCTAssertEqual(30, term.modes().scrollBottom)
        XCTAssertEqual(term.modes(), tracker.snapshot())
    }

    func testModesCrossCheckTheEmulator() {
        let term = HeadlessTerminal(80, 24, 100) { _ in }
        let tracker = ModeTracker(24)
        apply(term, tracker, "\u{1b}[?1h\u{1b}[?7l\u{1b}[?6h\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?1002h"
                + "\u{1b}[?1006h\u{1b}[?1004h\u{1b}[5 q\u{1b}=\u{1b}[?25l\u{1b}[2;9r\u{1b}]2;t\u{7}")
        XCTAssertEqual(tracker.snapshot(), term.modes())
        apply(term, tracker, "\u{1b}c")
        XCTAssertEqual(tracker.snapshot(), term.modes())
    }
}

/**
 * Feeding a stream in random chunk sizes yields the same screen as one read, and the broadcast
 * bytes concatenate to the input minus the stripped queries and the SGR rewrites.
 */
final class PumpTests: XCTestCase {

    private static let COLS = 24
    private static let ROWS = 8
    private static let HISTORY = 500

    private func strip(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func oneShot(_ input: [UInt8]) -> VtPipe {
        let pipe = VtPipe(PumpTests.COLS, PumpTests.ROWS, PumpTests.HISTORY)
        pipe.feed(input)
        return pipe
    }

    func testTypingAroundDcsAndCursorSequencesSurvivesEverySplit() {
        let streams = [
            "blah blah",
            "bl\u{1b}Pzz\u{1b}\\ah blah",
            "\u{1b}[3;1H\u{1b}Pzz\u{1b}\\\u{1b}[0%m\u{1b}[6n\u{1b}[1;1Hblah blah",
            "bla\u{1b}[1;3Ha\u{1b}[1;4Hh blah",
            "\u{1b}[?2026hbl\u{1b}Pzz\u{1b}\\ah blah\u{1b}[?2026l",
        ]
        for stream in streams {
            let input = bytes(stream)
            let expected = oneShot(input)
            XCTAssertEqual("blah blah", strip(expected.terminal.screenText()))
            for split in 0...input.count {
                let pipe = VtPipe(PumpTests.COLS, PumpTests.ROWS, PumpTests.HISTORY)
                pipe.feed(input, 0, split)
                pipe.feed(input, split, input.count - split)
                XCTAssertEqual("blah blah", strip(pipe.terminal.screenText()), "split \(split)")
                XCTAssertEqual(9, pipe.terminal.emulator().cursorColumn(), "split \(split)")
                XCTAssertEqual(expected.forwarded, pipe.forwarded, "split \(split)")
                let client = oneShot(pipe.forwarded)
                XCTAssertEqual("blah blah", strip(client.terminal.screenText()), "client split \(split)")
            }
            let bytewise = VtPipe(PumpTests.COLS, PumpTests.ROWS, PumpTests.HISTORY)
            bytewise.feedChunked(input, 1)
            XCTAssertEqual("blah blah", strip(bytewise.terminal.screenText()))
            XCTAssertEqual(expected.forwarded, bytewise.forwarded)
        }
    }

    private func syntheticStream() -> [UInt8] {
        var sb = ""
        sb += "plain ascii line one\r\n"
        sb += "\u{201c}curly\u{201d} and emoji 🛑🚀 here\r\n"
        sb += "\u{1b}[1;31mbold red\u{1b}[0m \u{1b}[38:2::10:200:30mtruecolor-colon\u{1b}[m\r\n"
        sb += "\u{1b}[4:3municode underline\u{1b}[m tail\r\n"
        sb += "\u{1b}]0;pump title 🛑\u{7}after title\r\n"
        sb += "query DA \u{1b}[c CPR \u{1b}[6n keeps going\r\n"
        sb += "\u{1b}[38;5;208m256 colour\u{1b}[m and \u{1b}[48;2;1;2;3mrgb bg\u{1b}[m\r\n"
        sb += "\u{1b}P1;2|somedcs\u{1b}\\ dcs done\r\n"
        sb += "\u{1b}[2;5Hmoved cursor\u{1b}[K wrote\r\n"
        sb += "winop \u{1b}[8;30;100t ignored and \u{1b}[?996n passed\r\n"
        sb += "a very long line that will certainly wrap around the terminal width boundary here\r\n"
        sb += "\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h mode soup \u{1b}[3 q"
        return bytes(sb)
    }

    func testRandomChunkingMatchesOneRead() {
        let input = syntheticStream()
        for seed: Int64 in [1, 2, 7, 42, 1234, 99999] {
            let one = oneShot(input)
            let many = VtPipe(PumpTests.COLS, PumpTests.ROWS, PumpTests.HISTORY)
            var rnd = JavaRandom(seed)
            var off = 0
            while off < input.count {
                let len = min(1 + rnd.nextInt(7), input.count - off)
                many.feed(input, off, len)
                off += len
            }
            XCTAssertEqual(one.terminal.serialize(PumpTests.HISTORY), many.terminal.serialize(PumpTests.HISTORY),
                           "screen state differs for seed \(seed)")
            XCTAssertEqual(one.forwarded, many.forwarded, "forwarded bytes differ for seed \(seed)")
        }
    }

    func testForwardedStreamOmitsQueriesAndRewritesSgr() {
        let pipe = oneShot(syntheticStream())
        let text = String(decoding: pipe.forwarded, as: UTF8.self)
        XCTAssertFalse(text.contains("\u{1b}[c"), "DA1 must be stripped")
        XCTAssertFalse(text.contains("\u{1b}[6n"), "CPR must be stripped")
        XCTAssertFalse(text.contains("\u{1b}[8;30;100t"), "XTWINOPS 8 stripped")
        XCTAssertTrue(text.contains("\u{1b}[?996n"), "996 passes through")
        XCTAssertFalse(text.contains("38:2:"), "colon SGR rewritten")
        XCTAssertTrue(text.contains("\u{1b}[38;2;10;200;30m"), "rewritten form present")
        let client = VtPipe(PumpTests.COLS, PumpTests.ROWS, PumpTests.HISTORY)
        client.feed(pipe.forwarded)
        XCTAssertEqual(pipe.terminal.serialize(PumpTests.HISTORY), client.terminal.serialize(PumpTests.HISTORY),
                       "client view differs from server view")
    }
}

/**
 * Every place the emulator deliberately differs from jediterm-core, each asserting the
 * emulator's (xterm's) behaviour, plus the serializer round trip of each input.
 */
final class KnownDifferencesTests: XCTestCase {

    struct Case {
        let name: String
        let columns: Int
        let rows: Int
        let input: String
        let xterm: (TerminalEmulator) -> Void
        let replies: [String]?

        init(_ name: String, _ columns: Int, _ rows: Int, _ input: String, _ xterm: @escaping (TerminalEmulator) -> Void,
             _ replies: [String]? = nil) {
            self.name = name
            self.columns = columns
            self.rows = rows
            self.input = input
            self.xterm = xterm
            self.replies = replies
        }
    }

    private static func cursorAt(_ row: Int, _ column: Int) -> (TerminalEmulator) -> Void {
        return { e in
            XCTAssertEqual(row, e.cursorRow(), "row")
            XCTAssertEqual(column, e.cursorColumn(), "column")
        }
    }

    private static func row(_ y: Int, _ text: String) -> (TerminalEmulator) -> Void {
        return { e in XCTAssertScalars(text, stripTrailing(e.line(y).toString()), "row \(y)") }
    }

    static func cases() -> [Case] {
        return [
            Case("CUU stops at the top margin outside origin mode", 20, 8, C + "3;6r" + C + "5;1H" + C + "9A", cursorAt(2, 0)),
            Case("relative move from a pending wrap", 5, 3, "abcde" + C + "D", cursorAt(0, 3)),
            Case("line feed clears a pending wrap", 5, 4, "abcde\nX", row(1, "    X")),
            Case("EL 0 at a pending wrap", 5, 3, "abcde" + C + "K", row(0, "abcd")),
            Case("autowrap off overwrites the last column", 5, 3, C + "?7labcdefg", row(0, "abcdg")),
            Case("IL and DL return to column 0", 20, 5, C + "2;5H" + C + "L", cursorAt(1, 0)),
            Case("DECOM homes the cursor", 20, 6, C + "2;5r" + C + "4;4H" + C + "?6h", cursorAt(1, 0)),
            Case("ED 3 keeps the screen", 20, 3, "keep" + C + "3J", row(0, "keep")),
            Case("ED 1 keeps the rest of the cursor row", 20, 3, "abcdef" + C + "1;3H" + C + "1J", row(0, "   def")),
            Case("EL with a background reaches the margin", 10, 3, "ab" + C + "44m" + C + "K",
                 { e in XCTAssertEqual(Style.indexed(4), Style.background(e.line(0).style(9))) }),
            Case("tab only moves the cursor", 20, 3, C + "41m" + C + "K" + C + "0m\tx",
                 { e in XCTAssertEqual(Style.indexed(1), Style.background(e.line(0).style(3))) }),
            Case("DCH fills at the right margin", 20, 3, "abcdef" + C + "1;2H" + C + "42m" + C + "2P",
                 { e in XCTAssertEqual(Style.indexed(2), Style.background(e.line(0).style(19))) }),
            Case("CHA in origin mode keeps the row", 20, 8, C + "3;6r" + C + "?6h" + C + "2;1H" + C + "5G", cursorAt(3, 4)),
            Case("VPA in origin mode is relative to the region", 20, 8, C + "3;6r" + C + "?6h" + C + "2d", cursorAt(3, 0)),
            Case("restored cursor is confined to the region in origin mode", 20, 8,
                 C + "?6h" + C + "1;1H" + E + "7" + C + "4;6r" + E + "8", cursorAt(3, 0)),
            Case("saved cursor per screen", 20, 6, C + "2;3H" + C + "?1049h" + C + "5;5H" + E + "7" + C + "?1049l",
                 cursorAt(1, 2)),
            Case("RIS resets tab stops, bracketed paste and the saved cursor", 20, 3,
                 C + "3g" + C + "?2004h" + C + "2;5H" + E + "7" + E + "c" + E + "8\tx", { e in
                     XCTAssertFalse(e.bracketedPaste())
                     XCTAssertEqual("        x", stripTrailing(e.line(0).toString()))
                 }),
            Case("DECALN resets the margins and homes", 6, 3, C + "2;3r" + C + "3;4H" + E + "#8", cursorAt(0, 0)),
            Case("DECSTBM needs two lines", 20, 6, C + "4;4r", { e in XCTAssertEqual(5, e.scrollBottom()) }),
            Case("backspace at column 0 stays", 10, 3, "\r\n\u{8}", cursorAt(1, 0)),
            Case("DEL is ignored", 10, 3, "a\u{7f}b", row(0, "ab")),
            Case("SO selects G1", 10, 3, E + ")0\u{e}q\u{f}q", row(0, "\u{2500}q")),
            Case("insert mode", 10, 3, "abc\r" + C + "4hX", row(0, "Xabc")),
            Case("REP, CHT, CBT, HPR, VPR, CSI s/u", 20, 4,
                 "x" + C + "3b" + C + "I" + "y" + C + "Z" + "z" + C + "2a" + C + "e" + C + "s" + C + "1;1H" + C + "u!", { e in
                     XCTAssertEqual("xxxx    z", stripTrailing(e.line(0).toString()))
                     XCTAssertEqual("           !", stripTrailing(e.line(1).toString()))
                 }),
            Case("alternate screen 47 is not cleared", 20, 3, C + "?47hkept" + C + "?47l" + C + "?47h", row(0, "kept")),
            Case("combining marks attach to the previous cell", 10, 3, "x\u{301}\u{302}y",
                 { e in XCTAssertScalars("x\u{301}\u{302}", e.line(0).text(0)) }),
            Case("supplementary narrow characters are one cell", 10, 3, "\u{1d400}b", row(0, "\u{1d400}b")),
            Case("emoji sequences are one wide cell", 20, 3, "\u{1f44d}\u{1f3fd}\u{1f1fa}\u{1f1f8}!",
                 { e in XCTAssertEqual(0x21, e.line(0).codePoint(4)) }),
            Case("C1 controls are not printed", 10, 3, "a\u{85}b", row(0, "ab")),
            Case("strikethrough, overline and underline styles", 10, 3, C + "9;53;4:3mx", { e in
                let style = e.line(0).style(0)
                XCTAssertTrue(Style.strikethrough(style) && Style.overline(style))
            }),
            Case("DA1 identifies as a VT220 with ANSI colour", 10, 3, C + "c", { _ in }, [C + "?62;22c"]),
            Case("CPR at a pending wrap reports the last column", 5, 3, "abcde" + C + "6n", { _ in }, [C + "1;5R"]),
        ]
    }

    func testBehavesAsXtermDoes() {
        for c in KnownDifferencesTests.cases() {
            let s = Subject(c.columns, c.rows, 100)
            s.feed(c.input)
            c.xterm(s.emulator())
            if let replies = c.replies {
                XCTAssertEqual(replies, s.replies, c.name)
            }
        }
    }

    func testSerializerRoundTrips() {
        for c in KnownDifferencesTests.cases() {
            let e = TerminalEmulator(c.columns, c.rows, 100)
            e.feed(bytes(c.input))
            ModelAssert.roundTrip(e, 100, c.name + ": ")
        }
    }
}

/** Throughput: mixed text and SGR through the daemon path (tokenizer, normaliser, emulator). */
final class PerformanceTests: XCTestCase {

    private func stream(_ size: Int) -> [UInt8] {
        var rnd = JavaRandom(7)
        var out: [UInt8] = []
        out.reserveCapacity(size + 1024)
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed",
                     "do", "eiusmod", "tempor", "中文", "café", "───", "x"]
        while out.count < size {
            var line = ""
            let n = 5 + rnd.nextInt(15)
            for _ in 0..<n {
                if rnd.nextInt(3) == 0 {
                    let a = rnd.nextInt(2)
                    let b = 30 + rnd.nextInt(8)
                    line += "\u{1b}[\(a);\(b)m"
                }
                if rnd.nextInt(20) == 0 {
                    line += "\u{1b}[38;2;\(rnd.nextInt(256));9;99m"
                }
                line += words[rnd.nextInt(words.count)] + " "
            }
            line += "\u{1b}[0m"
            if rnd.nextInt(50) == 0 {
                line += "\u{1b}[K\u{1b}[2A\u{1b}[5G"
            }
            line += "\r\n"
            out.append(contentsOf: line.utf8)
        }
        return out
    }

    func testMixedOutputThroughput() {
        // 20 MB as in Java when optimised; a smaller stream in debug builds (unoptimised Swift).
        #if DEBUG
        let size = 4 * 1024 * 1024
        #else
        let size = 20 * 1024 * 1024
        #endif
        let data = stream(size)
        let term = HeadlessTerminal(160, 50, 10_000) { _ in }
        let tokenizer = VtTokenizer()
        let start = Date()
        var off = 0
        while off < data.count {
            let batch = tokenizer.feed(data, off, min(65536, data.count - off))
            term.apply(batch.tokens.map { SgrNormalizer.normalize($0) })
            off += 65536
        }
        let millis = Int(Date().timeIntervalSince(start) * 1000)
        print("PerformanceTests: \(data.count >> 20) MB in \(millis) ms (\(Double(data.count) / 1048576 / Double(max(1, millis)) * 1000) MB/s)")
        XCTAssertLessThan(millis, 10_000)
        XCTAssertGreaterThan(term.emulator().historySize(), 0)
    }

    func testClientFeedThroughput() {
        #if DEBUG
        let size = 4 * 1024 * 1024
        #else
        let size = 20 * 1024 * 1024
        #endif
        let data = stream(size)
        let e = TerminalEmulator(160, 50, 10_000)
        let start = Date()
        var off = 0
        while off < data.count {
            e.feed(data, off, min(65536, data.count - off))
            off += 65536
        }
        let millis = Int(Date().timeIntervalSince(start) * 1000)
        print("PerformanceTests (feed): \(data.count >> 20) MB in \(millis) ms")
        XCTAssertLessThan(millis, 10_000)
    }
}
