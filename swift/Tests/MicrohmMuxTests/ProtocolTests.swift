import Darwin
import XCTest
@testable import MicrohmMux

/// Frames and JSON as they go on the wire (port of `FrameCodecTest`, plus the JSON shape
/// the Java side's Jackson writes).
final class ProtocolTests: XCTestCase {

    /// A connected socket pair: what one end writes, the other reads.
    private func pair() -> (UnixSocket, UnixSocket) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(0, socketpair(AF_UNIX, SOCK_STREAM, 0, &fds))
        return (UnixSocket(fd: fds[0]), UnixSocket(fd: fds[1]))
    }

    /// A reader over exactly `bytes`, then EOF.
    private func reader(_ bytes: [UInt8]) -> FrameCodec {
        let (a, b) = pair()
        Thread {
            bytes.withUnsafeBytes { try! a.write($0) }
            a.close()
        }.start()
        return FrameCodec(b)
    }

    private func wire(_ frames: [Frame]) -> [UInt8] {
        let (a, b) = pair()
        let codec = FrameCodec(a)
        // Written from another thread: a socket pair buffers only a few kilobytes.
        Thread {
            for frame in frames { try! codec.write(frame) }
            a.close()
        }.start()
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = try! buffer.withUnsafeMutableBytes { try b.read($0.baseAddress!, $0.count) }
            if n == 0 { break }
            out += buffer[0..<n]
        }
        return out
    }

    func testRoundTripsEveryFrameTypeInOrder() throws {
        let bytes = wire([Frame(.REQUEST, Array(#"{"op":"ping"}"#.utf8)), Frame(.DATA_OUT, [0, 1, 2, 0xff]),
                          Frame(.DETACH), Frame(.SESSION_EXITED, Array(#"{"exitCode":3}"#.utf8))])
        let codec = reader(bytes)
        let first = try XCTUnwrap(try codec.read())
        XCTAssertEqual(.REQUEST, first.type)
        XCTAssertEqual(#"{"op":"ping"}"#, first.payloadAsString)
        let second = try XCTUnwrap(try codec.read())
        XCTAssertEqual(.DATA_OUT, second.type)
        XCTAssertEqual([0, 1, 2, 0xff], second.payload)
        let third = try XCTUnwrap(try codec.read())
        XCTAssertEqual(.DETACH, third.type)
        XCTAssertEqual(0, third.payload.count)
        XCTAssertEqual(.SESSION_EXITED, try codec.read()?.type)
        XCTAssertNil(try codec.read(), "clean EOF at a frame boundary is nil")
    }

    func testTheHeaderIsABigEndianLengthOfTypePlusPayloadThenTheType() {
        XCTAssertEqual([0, 0, 0, 3, 17, 0x41, 0x42], wire([Frame(.DATA_IN, [0x41, 0x42])]))
        XCTAssertEqual([0, 0, 0, 1, 19], wire([Frame(.DETACH)]))
    }

    func testLargePayloadsGoOutWhole() throws {
        let payload = (0..<200_000).map { UInt8($0 & 0xff) }
        let codec = reader(wire([Frame(.DATA_OUT, payload)]))
        XCTAssertEqual(payload, try codec.read()?.payload)
    }

    func testEofAtBoundaryIsNilAndStaysNil() throws {
        let codec = reader([])
        XCTAssertNil(try codec.read())
        XCTAssertNil(try codec.read())
    }

    func testTruncatedFrameIsAnError() throws {
        let full = wire([Frame(.DATA_IN, Array("hello world".utf8))])
        XCTAssertThrowsError(try reader(Array(full.dropLast(3))).read())
        XCTAssertThrowsError(try reader(Array(full.prefix(4))).read())
        // Fewer than four bytes cannot be told from a clean EOF: the codec reports nil.
        XCTAssertNil(try reader(Array(full.prefix(2))).read())
    }

    func testOversizedLengthIsAnErrorWithoutAllocating() {
        let length = UInt32(Frame.MAX_PAYLOAD + 2)
        let bytes: [UInt8] = [UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff),
                              UInt8(length & 0xff), FrameType.DATA_OUT.code]
        XCTAssertThrowsError(try reader(bytes).read()) { error in
            XCTAssertTrue("\(error)".contains("bad frame length"), "\(error)")
        }
    }

    func testUnknownTypeAndZeroLengthAreErrors() {
        XCTAssertThrowsError(try reader([0, 0, 0, 1, 99]).read())
        XCTAssertThrowsError(try reader([0, 0, 0, 0]).read())
    }

    // MARK: JSON

    func testObjectsKeepInsertionOrderAndWriteCompactly() {
        let object = Json.ok().with("name", "a\"b\\c\n").with("n", 3).with("big", Int64(1) << 40).with("f", false)
            .with("labels", .object(Json.object().with("k", "v"))).with("list", .array([.string("x"), .null]))
        XCTAssertEqual(#"{"ok":true,"name":"a\"b\\c\n","n":3,"big":1099511627776,"f":false,"labels":{"k":"v"},"list":["x",null]}"#,
                       JSON.object(object).description)
    }

    func testControlCharactersAreEscapedAndUnicodeKeptAsJacksonDoes() {
        XCTAssertEqual(#""\u001B[0m\t/é中🚀""#, JSON.string("\u{1b}[0m\t/é中🚀").description)
        let u = "\\u"
        XCTAssertEqual("\"" + ["00E9", "4E2D", "D83D", "DE80", "25AE"].map { u + $0 }.joined() + "\"",
                       JSON.string("\u{e9}\u{4e2d}\u{1F680}\u{25ae}").serialized(escapeNonASCII: true))
    }

    func testParsesWhatJavaSends() throws {
        let u = "\\u"
        let parsed = try JSON.parse(#"{"ok":true,"text":""# + u + "001b[0m" + u + "d83d" + u + "de80"
                                    + #" \/","n":-12,"d":1.5,"e":2E3,"arr":[1,{"x":null}],"t":false}"#)
        let o = try XCTUnwrap(parsed.objectValue)
        XCTAssertEqual(o.keys, ["ok", "text", "n", "d", "e", "arr", "t"])
        XCTAssertEqual("\u{1b}[0m🚀 /", o["text"]?.stringValue)
        XCTAssertEqual(-12, o["n"]?.asInt())
        XCTAssertTrue(o["d"]!.canConvertToInt)
        XCTAssertEqual(1, o["d"]?.asInt())
        XCTAssertEqual(2000, o["e"]?.asLong())
        XCTAssertEqual(true, o["ok"]?.asBoolean())
        XCTAssertFalse(o["t"]!.asBoolean(true))
        XCTAssertFalse(JSON.string("3").canConvertToInt, "text is not a number")
    }

    func testMalformedJsonIsAnError() {
        for bad in ["", "{", #"{"a":}"#, "[1,]", "nul", #"{"a":1}x"#, "\"\u{01}\""] {
            XCTAssertThrowsError(try JSON.parse(bad), bad)
        }
    }

    func testInstantsLookLikeJavas() {
        XCTAssertEqual("1970-01-01T00:00:00Z", InstantFormat.format(Date(timeIntervalSince1970: 0)))
        XCTAssertEqual("2026-11-20T11:53:42.745Z", InstantFormat.format(Date(timeIntervalSince1970: 1_795_175_622.745)))
        let parsed = InstantFormat.parse("2026-11-20T11:53:42.745895Z")
        XCTAssertEqual(1_795_175_622.745895, parsed.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual("2026-11-20T11:53:42.745895Z", InstantFormat.format(parsed))
        XCTAssertEqual(0, InstantFormat.parse("garbage").timeIntervalSince1970)
    }
}
