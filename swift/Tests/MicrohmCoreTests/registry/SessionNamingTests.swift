import Foundation
import XCTest
@testable import MicrohmCore

final class SessionNamingTests: XCTestCase {

    func testDerivesFromBasename() throws {
        let name = try SessionNaming.deriveUnique(URL(fileURLWithPath: "/Users/x/Projects/foo")) { _ in false }
        XCTAssertEqual("mhm-foo", name)
    }

    func testSanitizesUnsafeCharacters() throws {
        let name = try SessionNaming.deriveUnique(URL(fileURLWithPath: "/Users/x/Projects/my project!")) { _ in false }
        XCTAssertEqual("mhm-my-project-", name)
    }

    func testSuffixesOnCollision() throws {
        let existing: Set<String> = ["mhm-foo", "mhm-foo-2"]
        let name = try SessionNaming.deriveUnique(URL(fileURLWithPath: "/Users/x/Projects/foo"), existing.contains)
        XCTAssertEqual("mhm-foo-3", name)
    }
}
