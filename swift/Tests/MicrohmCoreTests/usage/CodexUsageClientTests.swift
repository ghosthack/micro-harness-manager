import Foundation
import XCTest
@testable import MicrohmCore

final class CodexUsageClientTests: XCTestCase {

    /// The script is written to a temp file and run as `/bin/sh <file>`.
    private func fakeServer(_ script: String) throws -> Process {
        let dir = try makeTempDir(self)
        let scriptFile = try writeString(dir.appendingPathComponent("codex-fake-server.sh"), script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptFile.path]
        return process
    }

    func testReturnsAndStopsAppServerAfterResponsesArrive() throws {
        let process = try fakeServer("""
            while IFS= read -r line; do
              case "$line" in
                *'"id":1'*) echo '{"id":1,"result":{"userAgent":"test"}}' ;;
                *'"id":2'*) echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":300}}}}' ;;
                *'"id":3'*) echo '{"id":3,"result":{"summary":{"lifetimeTokens":42}}}' ;;
              esac
            done

            """)

        let started = Date()
        let snapshot = try CodexUsageClient().load(process)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        XCTAssertEqual(23, snapshot.limits[0].usedPercent)
        XCTAssertTrue(snapshot.statistics.contains(UsageSnapshot.Statistic("Lifetime tokens", "42")))
        XCTAssertFalse(process.isRunning)
    }

    func testParsesAllRateLimitBucketsAndTokenSummary() throws {
        let rates = try CoreJSON.parse("""
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1787804546},
                "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {"usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1787804546}
                },
                "spark": {
                  "limitId": "spark",
                  "limitName": "GPT Spark",
                  "primary": {"usedPercent": 2, "windowDurationMins": 300, "resetsAt": 1787453913},
                  "secondary": {"usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 1788040713}
                }
              },
              "rateLimitResetCredits": {"availableCount": 1}
            }
            """)
        let usage = try CoreJSON.parse("""
            {"summary": {
              "lifetimeTokens": 12345678,
              "peakDailyTokens": 1234,
              "longestRunningTurnSec": 3725,
              "currentStreakDays": 3,
              "longestStreakDays": 8
            }}
            """)

        let snapshot = CodexUsageClient.parse(rates, usage)

        XCTAssertEqual(3, snapshot.limits.count)
        XCTAssertEqual("Codex · 1 week", snapshot.limits[0].label)
        XCTAssertEqual(18, snapshot.limits[0].usedPercent)
        XCTAssertEqual(Date(timeIntervalSince1970: 1787804546), snapshot.limits[0].resetsAt)
        XCTAssertEqual("GPT Spark · 5 hours", snapshot.limits[1].label)
        XCTAssertTrue(snapshot.statistics.contains(UsageSnapshot.Statistic("Plan", "Pro")))
        XCTAssertTrue(snapshot.statistics.contains(UsageSnapshot.Statistic("Lifetime tokens", "12,345,678")))
        XCTAssertTrue(snapshot.statistics.contains(UsageSnapshot.Statistic("Longest turn", "1h 2m")))
        XCTAssertNil(snapshot.note)
    }

    func testKeepsLimitsWhenOlderCodexHasNoUsageMethod() throws {
        let rates = try CoreJSON.parse("""
            {"rateLimits": {
              "primary": {"usedPercent": 51, "windowDurationMins": 300}
            }}
            """)

        let snapshot = CodexUsageClient.parse(rates, nil)

        XCTAssertEqual(1, snapshot.limits.count)
        XCTAssertEqual("Codex · 5 hours", snapshot.limits[0].label)
        XCTAssertTrue(snapshot.note!.contains("not aggregate token usage"))
    }
}
