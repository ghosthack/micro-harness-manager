import Foundation
import XCTest
@testable import MicrohmCore

final class UsageSnapshotTests: XCTestCase {

    func testLimitPercentIsClampedForProgressBars() {
        XCTAssertEqual(0, UsageSnapshot.Limit("low", -4, nil, nil).usedPercent)
        XCTAssertEqual(100, UsageSnapshot.Limit("high", 104, nil, nil).usedPercent)
    }

    /// The ported JSON reader keeps Jackson's coercions and its writer Jackson's layout.
    func testCoreJsonFollowsJackson() throws {
        let node = try CoreJSON.parse(#"{"i": 7, "d": 7.9, "s": " 12 ", "b": true, "n": null, "u": "é😀"}"#)
        XCTAssertEqual(7, node.path("i").asInt())
        XCTAssertEqual(7, node.path("d").asInt())
        XCTAssertEqual(12, node.path("s").asInt())
        XCTAssertEqual(-1, node.path("missing").asInt(-1))
        XCTAssertEqual("null", node.path("n").asText())
        XCTAssertEqual("", node.path("missing").asText())
        XCTAssertEqual("x", node.path("n").asText("x"))
        XCTAssertEqual("7.9", node.path("d").asText())
        XCTAssertEqual("é😀", node.path("u").asText())
        XCTAssertTrue(node.hasNonNull("b"))
        XCTAssertFalse(node.hasNonNull("n"))
        XCTAssertTrue(node.has("n"))
        XCTAssertEqual(#"{"a":[1,2.5,"x\n"],"b":{}}"#,
                       CoreJSON.obj([("a", .array([.int(1), .double(2.5), .string("x\n")])), ("b", .obj([]))]).compact())
        XCTAssertEqual("{\n  \"a\" : [ 1, {\n    \"b\" : null\n  } ],\n  \"c\" : { }\n}",
                       CoreJSON.obj([("a", .array([.int(1), .obj([("b", .null)])])), ("c", .obj([]))]).pretty())
        XCTAssertThrowsError(try CoreJSON.parse("{not-yet-complete"))
        XCTAssertEqual(CoreJSON.missing, try CoreJSON.parse("  "))
    }
}
