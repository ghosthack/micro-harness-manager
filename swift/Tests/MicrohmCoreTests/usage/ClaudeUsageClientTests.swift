import Foundation
import XCTest
@testable import MicrohmCore

final class ClaudeUsageClientTests: XCTestCase {

    func testParsesSubscriptionWindowsAndExtraUsage() throws {
        let snapshot = ClaudeUsageClient.parse(try CoreJSON.parse("""
            {
              "five_hour": {
                "utilization": 12.4,
                "resets_at": "2026-08-22T23:10:00+00:00"
              },
              "seven_day": {
                "utilization": 45,
                "resets_at": "2026-08-29T05:00:00Z"
              },
              "seven_day_overage_included": {
                "utilization": 63,
                "resets_at": "2026-08-29T05:00:00Z"
              },
              "seven_day_opus": null,
              "extra_usage": {
                "is_enabled": true,
                "monthly_limit": 10000,
                "used_credits": 750,
                "utilization": 7.5,
                "decimal_places": 2,
                "currency": "USD"
              }
            }
            """))

        XCTAssertEqual("Claude Code subscription", snapshot.heading)
        XCTAssertEqual(4, snapshot.limits.count)
        XCTAssertEqual("Current session (5 hours)", snapshot.limits[0].label)
        XCTAssertEqual(12, snapshot.limits[0].usedPercent)
        XCTAssertEqual(IsoInstant.parse("2026-08-22T23:10:00Z"), snapshot.limits[0].resetsAt)
        XCTAssertEqual("Current week (Fable)", snapshot.limits[2].label)
        XCTAssertEqual(63, snapshot.limits[2].usedPercent)
        XCTAssertEqual("Monthly credits", snapshot.limits[3].label)
        XCTAssertEqual(8, snapshot.limits[3].usedPercent)
        XCTAssertEqual("$7.50 of $100.00", snapshot.limits[3].detail)
        XCTAssertEqual(UsageSnapshot.Statistic("Extra usage", "Enabled"), snapshot.statistics[0])
        XCTAssertTrue(snapshot.note!.contains("vendor-internal"))
    }

    func testToleratesAnEmptyUsageResponse() throws {
        let snapshot = ClaudeUsageClient.parse(try CoreJSON.parse("{}"))

        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertTrue(snapshot.statistics.isEmpty)
        XCTAssertNotNil(snapshot.note)
    }

    func testParsesFableFromNewerModelScopedUsageShape() throws {
        let snapshot = ClaudeUsageClient.parse(try CoreJSON.parse("""
            {
              "five_hour": {"utilization": 10},
              "seven_day": {"utilization": 20},
              "model_scoped": [{
                "display_name": "Fable",
                "utilization": 0.38,
                "resets_at": "2026-08-29T05:00:00Z"
              }]
            }
            """))

        let fable = snapshot.limits[2]
        XCTAssertEqual("Current week (Fable)", fable.label)
        XCTAssertEqual(38, fable.usedPercent)
        XCTAssertEqual(IsoInstant.parse("2026-08-29T05:00:00Z"), fable.resetsAt)
    }

    func testParsesFableFromWeeklyScopedLimitsFallback() throws {
        let snapshot = ClaudeUsageClient.parse(try CoreJSON.parse("""
            {
              "limits": [{
                "kind": "weekly_scoped",
                "percent": 44,
                "resets_at": "2026-08-29T05:00:00Z",
                "scope": {"model": {"id": null, "display_name": "Fable"}}
              }]
            }
            """))

        XCTAssertEqual("Current week (Fable)", snapshot.limits[0].label)
        XCTAssertEqual(44, snapshot.limits[0].usedPercent)
    }
}
