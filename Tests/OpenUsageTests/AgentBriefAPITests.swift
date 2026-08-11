import Foundation
import XCTest
@testable import OpenUsage

final class AgentBriefAPITests: XCTestCase {
    func testJSONCombinesLimitsSpendAndTrends() throws {
        let state = makeState()
        let data = try AgentBriefAPI.json(providerIDs: state.enabledOrderedIDs, state: state)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["schema"] as? String, "openusage.brief.v1")
        let spend = try XCTUnwrap(root["spend"] as? [String: Any])
        let today = try XCTUnwrap(spend["today"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(today["costUSD"] as? NSNumber).doubleValue, 45.44, accuracy: 0.001)
        XCTAssertEqual(today["tokens"] as? Int, 61_490_886)
        XCTAssertEqual((today["providers"] as? [[String: Any]])?.count, 2)

        let trends = try XCTUnwrap(root["trends"] as? [String: Any])
        let claude = try XCTUnwrap(trends["claude"] as? [[String: Any]])
        XCTAssertEqual(claude.last?["tokens"] as? Int, 60_700_000)
    }

    func testMarkdownIsCompactAndDecisionReady() throws {
        let state = makeState()
        let data = AgentBriefAPI.markdown(providerIDs: state.enabledOrderedIDs, state: state)
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(output.contains("| Claude | Session | 95% |"))
        XCTAssertTrue(output.contains("| Today | $45.44 | 61,490,886 |"))
        XCTAssertTrue(output.contains("| Codex CLI | $0.55 | 790,886 |"))
    }

    private func makeState() -> LocalUsageAPI.State {
        let now = Date(timeIntervalSince1970: 1_786_420_800)
        let claude = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Max 20x",
            lines: [
                .progress(label: "Session", used: 5, limit: 100, format: .percent,
                          resetsAt: now.addingTimeInterval(10_800)),
                .values(label: "Today", values: [
                    MetricValue(number: 44.89, kind: .dollars, estimated: true),
                    MetricValue(number: 60_700_000, kind: .count, label: "tokens")
                ]),
                .chart(label: "Usage Trend", points: [
                    MetricChartPoint(value: 10, label: "Aug 10", valueLabel: nil),
                    MetricChartPoint(value: 60_700_000, label: "Aug 11", valueLabel: nil)
                ])
            ],
            refreshedAt: now
        )
        let codex = ProviderSnapshot(
            providerID: "codex@cli",
            displayName: "Codex CLI",
            plan: "Pro 20x",
            lines: [
                .values(label: "Today", values: [
                    MetricValue(number: 0.55, kind: .dollars, estimated: true),
                    MetricValue(number: 790_886, kind: .count, label: "tokens")
                ])
            ],
            refreshedAt: now
        )
        return LocalUsageAPI.State(
            enabledOrderedIDs: ["claude", "codex@cli"],
            knownIDs: ["claude", "codex@cli"],
            snapshots: ["claude": claude, "codex@cli": codex],
            generatedAt: now
        )
    }
}
