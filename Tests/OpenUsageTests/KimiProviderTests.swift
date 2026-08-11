import XCTest
@testable import OpenUsage

final class KimiProviderTests: XCTestCase {
    @MainActor
    func testProviderDefaultsExposeBothMenuBarMeters() {
        let provider = KimiProvider()
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["kimi.session", "kimi.weekly"])
        XCTAssertTrue(DefaultLayout.metricIDs.contains("kimi.session"))
        XCTAssertTrue(DefaultLayout.metricIDs.contains("kimi.weekly"))
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.contains("kimi.session"))
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.contains("kimi.weekly"))
    }

    func testReadsStaticKimiKeyFromCLIConfig() {
        let config = #"""
        default_model = "kimi-code-key/k3"

        [providers.kimi-code-key]
        type = "kimi"
        api_key = "kimi-static"
        base_url = "https://api.kimi.com/coding/v1"
        """#
        XCTAssertEqual(KimiAuthStore.staticAPIKey(from: config), "kimi-static")
    }

    func testIgnoresNonKimiProviderKeys() {
        let config = #"""
        [providers.openai]
        type = "openai"
        api_key = "wrong-key"
        """#
        XCTAssertNil(KimiAuthStore.staticAPIKey(from: config))
    }

    func testMapsWeeklyAndFiveHourQuota() throws {
        let json = #"""
        {
          "user": {"userId": "kimi-user-1", "membership": {"level": "LEVEL_ADVANCED"}},
          "usage": {
            "limit": "100", "used": "23", "remaining": "77",
            "resetTime": "2026-08-13T09:47:14.880960Z"
          },
          "limits": [{
            "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
            "detail": {
              "limit": "100", "remaining": "99",
              "resetTime": "2026-08-09T11:47:14.880960Z"
            }
          }]
        }
        """#

        let mapped = try KimiUsageMapper.map(Data(json.utf8))

        XCTAssertEqual(mapped.plan, "Advanced")
        XCTAssertEqual(mapped.account?.id, "kimi-user-1")
        XCTAssertNil(mapped.account?.label)
        XCTAssertEqual(mapped.lines.count, 2)
        guard case .progress(let sessionLabel, let sessionUsed, let sessionLimit, _, _, let sessionPeriod, _) = mapped.lines[0],
              case .progress(let weeklyLabel, let weeklyUsed, let weeklyLimit, _, _, let weeklyPeriod, _) = mapped.lines[1]
        else {
            return XCTFail("Expected session and weekly progress lines")
        }
        XCTAssertEqual(sessionLabel, "Session")
        XCTAssertEqual(sessionUsed, 1, accuracy: 0.001)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionPeriod, 5 * 60 * 60 * 1000)
        XCTAssertEqual(weeklyLabel, "Weekly")
        XCTAssertEqual(weeklyUsed, 23, accuracy: 0.001)
        XCTAssertEqual(weeklyLimit, 100)
        XCTAssertEqual(weeklyPeriod, KimiUsageMapper.weeklyPeriodMs)
    }

    func testRejectsMalformedQuota() {
        XCTAssertThrowsError(try KimiUsageMapper.map(Data(#"{"usage":{}}"#.utf8)))
    }
}
