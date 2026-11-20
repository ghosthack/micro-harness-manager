import XCTest
@testable import MicrohmCore

final class HarnessUsageServiceLoaderTests: XCTestCase {
    func testALoaderReplacesTheLiveSources() throws {
        let canned = UsageSnapshot("Canned", "Test", [.init("Current session (5 hours)", 30, nil, nil)], [], nil)
        let service = HarnessUsageService(loader: { _ in canned })
        XCTAssertEqual(try service.load(.claudeCode), canned)
        XCTAssertEqual(try service.load(.codex), canned)
    }
}
