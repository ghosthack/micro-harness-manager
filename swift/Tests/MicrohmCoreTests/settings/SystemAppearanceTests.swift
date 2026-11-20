import Foundation
import XCTest
@testable import MicrohmCore

final class SystemAppearanceTests: XCTestCase {

    func testMacReportsDarkOnlyWhenTheKeySaysSo() {
        XCTAssertEqual(AppSettings.UiTheme.dark, SystemAppearance.parseMac(0, "Dark\n"))
        XCTAssertEqual(AppSettings.UiTheme.light, SystemAppearance.parseMac(1,
            "The domain/default pair of (kCFPreferencesAnyApplication, AppleInterfaceStyle) does not exist\n"))
    }

    func testUnknownPlatformsHaveNoDetector() {
        XCTAssertNil(SystemAppearance.detect("Plan 9"))
        XCTAssertNotNil(SystemAppearance.detect("Mac OS X"))
    }
}
