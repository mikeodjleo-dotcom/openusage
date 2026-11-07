import Foundation
import Testing
import XCTest
@testable import OpenUsage

@Suite struct ClaudeLocalUsageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func body(fetched: Double, fiveReset: Double, weekReset: Double) -> [String: Any] {
        ["fetched_at": fetched,
         "five_hour": ["used_percent": 44.0, "reset_at_ms": fiveReset * 1000],
         "weekly": ["remaining_percent": 87.0, "reset_at_ms": weekReset * 1000]]
    }

    @Test func freshFileGivesSessionAndWeeklyUsed() throws {
        let lines = try #require(ClaudeLocalUsage.lines(from: body(fetched: 1_800_000_000 - 60, fiveReset: 1_800_003_600, weekReset: 1_800_300_000), now: now))
        #expect(lines.map(\.label) == ["Session", "Weekly"])
        #expect(lines == [
            .percent("Session", 44, resetsAt: Date(timeIntervalSince1970: 1_800_003_600), periodMs: MetricPeriod.sessionMs),
            .percent("Weekly", 13, resetsAt: Date(timeIntervalSince1970: 1_800_300_000), periodMs: MetricPeriod.weekMs),
        ])
    }

    @Test func staleFileIsNotUsed() {
        #expect(ClaudeLocalUsage.lines(from: body(fetched: 1_800_000_000 - 3601, fiveReset: 1_800_003_600, weekReset: 1_800_300_000), now: now) == nil)
    }

    @Test func windowPastItsResetIsDropped() throws {
        let lines = try #require(ClaudeLocalUsage.lines(from: body(fetched: 1_800_000_000, fiveReset: 1_799_999_000, weekReset: 1_800_300_000), now: now))
        #expect(lines.map(\.label) == ["Weekly"])
    }
}

/// The runtime falls back to the local file only when the usage read fails and only when the catalog set a path.
@MainActor
final class ClaudeLocalUsageFallbackTests: XCTestCase {
    private func runtime(localFile: URL?) throws -> AccountProviderRuntime {
        let account = Account(kind: .claude, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token-a", refreshToken: "refresh-a")), for: account.id)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 429, headers: ["retry-after": "1800"], body: Data()) }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        runtime.claudeLocalUsageURL = localFile
        return runtime
    }

    private func localFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "claude-local-\(UUID().uuidString).json")
        let now = Date().timeIntervalSince1970
        let body: [String: Any] = ["fetched_at": now - 60,
                                   "five_hour": ["used_percent": 44, "reset_at_ms": (now + 3600) * 1000],
                                   "weekly": ["remaining_percent": 87, "reset_at_ms": (now + 86400) * 1000]]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testA429ShowsTheLocalFile() async throws {
        let snapshot = try await runtime(localFile: try localFile()).refresh().get()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    func testWithoutAPathThe429StillFails() async throws {
        let result = await (try runtime(localFile: nil)).refresh()
        guard case .failure = result else { return XCTFail("a 429 with no local file must still fail") }
    }
}
