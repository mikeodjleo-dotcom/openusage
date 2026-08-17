import XCTest
@testable import OpenUsage

final class KimiProviderTests: XCTestCase {
    @MainActor
    func testProviderDefaultsExposeBothMenuBarMeters() {
        let provider = KimiProvider()
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), [
            "kimi.session", "kimi.weekly", "kimi.key.session", "kimi.key.weekly"
        ])
        XCTAssertEqual(provider.widgetDescriptors.map(\.sample.title), [
            "Kimi 官方订阅 · 5-Hour Code", "Kimi 官方订阅 · 7-Day Code",
            "Kimi 拼车key · 5-Hour Code", "Kimi 拼车key · 7-Day Code"
        ])
        XCTAssertTrue(DefaultLayout.metricIDs.contains("kimi.session"))
        XCTAssertTrue(DefaultLayout.metricIDs.contains("kimi.weekly"))
        XCTAssertTrue(DefaultLayout.metricIDs.contains("kimi.key.session"))
        XCTAssertTrue(DefaultLayout.metricIDs.contains("kimi.key.weekly"))
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.contains("kimi.session"))
        XCTAssertTrue(DefaultLayout.pinnedMetricIDs.contains("kimi.weekly"))
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains("kimi.key.session"))
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains("kimi.key.weekly"))
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

    func testManagedDefaultModelMarksOAuthPrimary() {
        let files = FakeFiles([
            "~/.kimi-code/config.toml": #"""
            default_model = "kimi-code/k3"
            [providers.key]
            type = "kimi"
            api_key = "other-account"
            [providers."managed:kimi-code"]
            type = "kimi"
            api_key = "placeholder"
            [providers."managed:kimi-code".oauth]
            storage = "file"
            [models."kimi-code/k3"]
            provider = "managed:kimi-code"
            """#,
            "~/.kimi-code/credentials/kimi-code.json": #"{"access_token":"cli-account","expires_at":2000}"#,
            "~/.kimi-code/device_id": "device-1\n"
        ])
        let store = KimiAuthStore(
            files: files,
            environment: FakeEnvironment(),
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let accounts = store.loadAccounts()
        XCTAssertEqual(accounts.map(\.kind), [.officialSubscription, .sharedAPIKey])
        XCTAssertEqual(accounts.map(\.isPrimary), [true, false])
        XCTAssertEqual(store.loadAuth(), KimiAuth(token: "cli-account", source: .cliOAuth(deviceID: "device-1")))
    }

    func testKeyDefaultModelMarksStaticKeyPrimaryEvenWithLiveOAuth() {
        let files = FakeFiles([
            "~/.kimi-code/config.toml": #"""
            default_model = "kimi-code-key/k3"
            [providers.key]
            type = "kimi"
            api_key = "fallback-key"
            [providers."managed:kimi-code"]
            type = "kimi"
            api_key = "placeholder"
            [providers."managed:kimi-code".oauth]
            storage = "file"
            [models."kimi-code-key/k3"]
            provider = "key"
            """#,
            "~/.kimi-code/credentials/kimi-code.json": #"{"access_token":"live-oauth","expires_at":2000}"#
        ])
        let store = KimiAuthStore(
            files: files,
            environment: FakeEnvironment(),
            now: { Date(timeIntervalSince1970: 1000) }
        )

        XCTAssertEqual(store.loadAccounts().map(\.isPrimary), [false, true])
        XCTAssertEqual(store.loadAuth(), KimiAuth(token: "fallback-key", source: .apiKey))
    }

    func testExpiredOAuthRemainsEnumeratedAsUnavailable() {
        let store = KimiAuthStore(
            files: FakeFiles([
                "~/.kimi-code/config.toml": #"""
                default_model = "kimi-code/k3"
                [providers."managed:kimi-code"]
                type = "kimi"
                api_key = "placeholder"
                [providers."managed:kimi-code".oauth]
                storage = "file"
                [models."kimi-code/k3"]
                provider = "managed:kimi-code"
                """#,
                "~/.kimi-code/credentials/kimi-code.json": #"{"access_token":"expired","expires_at":1050}"#
            ]),
            environment: FakeEnvironment(),
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let official = store.loadAccounts()[0]
        XCTAssertTrue(official.isPrimary)
        XCTAssertEqual(official.availability, .expiredCredential)
        XCTAssertNil(official.auth)
    }

    @MainActor
    func testExpiredOAuthRefreshesPersistsRotatedTokensAndFetchesUsage() async throws {
        let credentialPath = "~/.kimi-code/credentials/kimi-code.json"
        let files = FakeFiles([
            "~/.kimi-code/config.toml": managedConfig(),
            credentialPath: #"{"access_token":"old-access","refresh_token":"old+refresh/token","expires_at":900,"expires_in":900,"scope":"old-scope","token_type":"Bearer","future_field":{"kept":true}}"#,
            "~/.kimi-code/device_id": "device-1\n"
        ])
        let fixture = try realUsageFixture()
        let http = RoutingHTTPClient { request in
            if request.url == KimiUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":900,"scope":"new-scope","token_type":"Bearer"}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: fixture)
        }
        let now = Date(timeIntervalSince1970: 1000)
        let provider = KimiProvider(
            authStore: KimiAuthStore(files: files, environment: FakeEnvironment(), now: { now }),
            usageClient: KimiUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        let official = try XCTUnwrap(snapshot.accountEntries?.first)
        XCTAssertEqual(official.availability, .available)
        XCTAssertNotNil(official.resources["session"])
        XCTAssertNotNil(official.resources["weekly"])
        XCTAssertEqual(http.requests.count, 2)
        let refreshRequest = http.requests[0]
        XCTAssertEqual(refreshRequest.method, "POST")
        XCTAssertEqual(refreshRequest.url, KimiUsageClient.refreshURL)
        XCTAssertEqual(refreshRequest.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(refreshRequest.body), encoding: .utf8),
            "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=old%2Brefresh%2Ftoken"
        )
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(http.requests[1].headers["X-Msh-Device-Id"], "device-1")

        let persistedData = try XCTUnwrap(files.files[credentialPath]?.data(using: .utf8))
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
        XCTAssertEqual(persisted["access_token"] as? String, "new-access")
        XCTAssertEqual(persisted["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(persisted["expires_at"] as? Int, 1900)
        XCTAssertEqual(persisted["expires_in"] as? Int, 900)
        XCTAssertEqual(persisted["scope"] as? String, "new-scope")
        XCTAssertEqual((persisted["future_field"] as? [String: Any])?["kept"] as? Bool, true)
    }

    @MainActor
    func testInvalidRefreshTokenIsTheOnlyRefreshFailureThatRequestsRelogin() async throws {
        let credentialPath = "~/.kimi-code/credentials/kimi-code.json"
        let original = #"{"access_token":"expired","refresh_token":"invalid-refresh","expires_at":900,"extra":"kept"}"#
        let files = FakeFiles([
            "~/.kimi-code/config.toml": managedConfig(),
            credentialPath: original
        ])
        let http = RoutingHTTPClient { _ in
            HTTPResponse(
                statusCode: 400,
                headers: [:],
                body: Data(#"{"error":"invalid_grant"}"#.utf8)
            )
        }
        let provider = KimiProvider(
            authStore: KimiAuthStore(
                files: files,
                environment: FakeEnvironment(),
                now: { Date(timeIntervalSince1970: 1000) }
            ),
            usageClient: KimiUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        let official = try XCTUnwrap(snapshot.accountEntries?.first)
        XCTAssertEqual(official.availability, .expiredCredential)
        XCTAssertEqual(official.message, "凭据已过期，请重新登录")
        XCTAssertEqual(files.files[credentialPath], original)
        XCTAssertEqual(http.requests.count, 1)
    }

    @MainActor
    func testRefreshServiceFailureDoesNotRequestRelogin() async throws {
        let files = FakeFiles([
            "~/.kimi-code/config.toml": managedConfig(),
            "~/.kimi-code/credentials/kimi-code.json": #"{"access_token":"expired","refresh_token":"still-valid","expires_at":900}"#
        ])
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = KimiProvider(
            authStore: KimiAuthStore(
                files: files,
                environment: FakeEnvironment(),
                now: { Date(timeIntervalSince1970: 1000) }
            ),
            usageClient: KimiUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        let official = try XCTUnwrap(snapshot.accountEntries?.first)
        XCTAssertEqual(official.availability, .requestFailed)
        XCTAssertNotEqual(official.message, "凭据已过期，请重新登录")
    }

    @MainActor
    func testRefreshKeepsBothAccountsSeparatedAndPrimaryFirst() async throws {
        let authStore = accountStore(defaultModel: "kimi-code/k3", includeKey: true)
        let fixture = try realUsageFixture()
        let http = RoutingHTTPClient { request in
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
            var user = try XCTUnwrap(root["user"] as? [String: Any])
            if request.headers["Authorization"] == "Bearer shared-key" {
                user["userId"] = "shared-user"
                root["user"] = user
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: root))
        }
        let provider = KimiProvider(
            authStore: authStore, usageClient: KimiUsageClient(http: http), now: { Date(timeIntervalSince1970: 1000) }
        )
        let snapshot = await provider.refresh()

        let entries = try XCTUnwrap(snapshot.accountEntries)
        XCTAssertEqual(entries.map(\.label), ["Kimi 官方订阅", "Kimi 拼车key"])
        XCTAssertEqual(entries.map(\.isPrimary), [true, false])
        XCTAssertEqual(entries.map(\.availability), [.available, .available])
        XCTAssertEqual(entries[1].account?.id, "shared-user")
        XCTAssertEqual(snapshot.lines.map(\.label), [
            "Kimi 官方订阅 · 5-Hour Code", "Kimi 官方订阅 · 7-Day Code",
            "Kimi 拼车key · 5-Hour Code", "Kimi 拼车key · 7-Day Code"
        ])
        XCTAssertEqual(http.requests.count, 2)

        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["kimi"], knownIDs: ["kimi"], snapshots: ["kimi": snapshot],
            limitDescriptors: ["kimi": provider.widgetDescriptors], generatedAt: snapshot.refreshedAt
        )
        let brief = try XCTUnwrap(JSONSerialization.jsonObject(
            with: AgentBriefAPI.json(providerIDs: ["kimi"], state: state)
        ) as? [String: Any])
        let providers = try XCTUnwrap(brief["providers"] as? [String: Any])
        let kimi = try XCTUnwrap(providers["kimi"] as? [String: Any])
        let wireEntries = try XCTUnwrap(kimi["entries"] as? [[String: Any]])
        XCTAssertEqual(wireEntries.count, 2)
        XCTAssertEqual(wireEntries.map { $0["account"] as? String }, ["Kimi 官方订阅", "Kimi 拼车key"])
        XCTAssertEqual(wireEntries.map { $0["isPrimary"] as? Bool }, [true, false])
        XCTAssertNotNil((wireEntries[0]["resources"] as? [String: Any])?["session"])

        let markdown = try XCTUnwrap(String(
            data: AgentBriefAPI.markdown(providerIDs: ["kimi"], state: state), encoding: .utf8
        ))
        XCTAssertTrue(markdown.contains("| Kimi | Kimi 官方订阅 (主) | 5-Hour Code |"))
        XCTAssertTrue(markdown.contains("| Kimi | Kimi 拼车key | 7-Day Code |"))
    }

    @MainActor
    func testMissingStaticKeyStaysVisibleAsUnavailableEntry() async throws {
        let authStore = accountStore(defaultModel: "kimi-code/k3", includeKey: false)
        let provider = KimiProvider(
            authStore: authStore,
            usageClient: KimiUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 200, headers: [:], body: try realUsageFixture()
            )))
        )
        let snapshot = await provider.refresh()

        let entries = try XCTUnwrap(snapshot.accountEntries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].availability, .missingCredential)
        XCTAssertEqual(entries[1].message, "未找到凭据")
        XCTAssertTrue(snapshot.lines.suffix(2).allSatisfy { line in
            guard case .badge(_, let text, _, _) = line else { return false }
            return text == "未找到凭据"
        })
    }

    func testMapsRealUsageFixtureToOfficialCodeWindows() throws {
        let mapped = try KimiUsageMapper.map(try realUsageFixture())

        XCTAssertEqual(mapped.plan, "Allegro")
        XCTAssertEqual(mapped.account?.id, "<redacted-user-id>")
        XCTAssertNil(mapped.account?.label)
        XCTAssertEqual(mapped.lines.count, 2)
        guard case .progress(let fiveHourLabel, let fiveHourUsed, let fiveHourLimit, _, let fiveHourReset, let fiveHourPeriod, _) = mapped.lines[0],
              case .progress(let sevenDayLabel, let sevenDayUsed, let sevenDayLimit, _, let sevenDayReset, let sevenDayPeriod, _) = mapped.lines[1]
        else {
            return XCTFail("Expected 5-hour and 7-day Code progress lines")
        }
        XCTAssertEqual(fiveHourLabel, "5-Hour Code")
        XCTAssertEqual(fiveHourUsed, 14, accuracy: 0.001)
        XCTAssertEqual(fiveHourLimit, 100)
        XCTAssertEqual(fiveHourReset, OpenUsageISO8601.date(from: "2026-08-17T04:42:44.820647Z"))
        XCTAssertEqual(fiveHourPeriod, KimiUsageMapper.fiveHourPeriodMs)
        XCTAssertEqual(sevenDayLabel, "7-Day Code")
        XCTAssertEqual(sevenDayUsed, 3, accuracy: 0.001)
        XCTAssertEqual(sevenDayLimit, 100)
        XCTAssertEqual(sevenDayReset, OpenUsageISO8601.date(from: "2026-08-21T12:42:44.820647Z"))
        XCTAssertEqual(sevenDayPeriod, KimiUsageMapper.sevenDayPeriodMs)
    }

    func testPrefersRemainingWhenLegacyUsedCountersDisagree() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: realUsageFixture()) as? [String: Any])
        var usage = try XCTUnwrap(root["usage"] as? [String: Any])
        usage["used"] = "37"
        root["usage"] = usage
        var limits = try XCTUnwrap(root["limits"] as? [[String: Any]])
        var detail = try XCTUnwrap(limits[0]["detail"] as? [String: Any])
        detail["used"] = "0"
        limits[0]["detail"] = detail
        root["limits"] = limits

        let mapped = try KimiUsageMapper.map(try JSONSerialization.data(withJSONObject: root))

        XCTAssertEqual(progress(mapped.lines, label: "5-Hour Code")?.used, 14)
        XCTAssertEqual(progress(mapped.lines, label: "7-Day Code")?.used, 3)
    }

    func testFindsFiveHourWindowByMetadataInsteadOfArrayPosition() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: realUsageFixture()) as? [String: Any])
        var limits = try XCTUnwrap(root["limits"] as? [[String: Any]])
        limits.insert([
            "window": ["duration": 1, "timeUnit": "TIME_UNIT_HOUR"],
            "detail": ["limit": "100", "remaining": "1"]
        ], at: 0)
        root["limits"] = limits

        let mapped = try KimiUsageMapper.map(try JSONSerialization.data(withJSONObject: root))

        XCTAssertEqual(progress(mapped.lines, label: "5-Hour Code")?.used, 14)
    }

    func testRejectsMutatedFiveHourDetailFieldName() throws {
        let mutated = String(decoding: try realUsageFixture(), as: UTF8.self)
            .replacingOccurrences(of: "\"detail\"", with: "\"quotaDetail\"")
        XCTAssertThrowsError(try KimiUsageMapper.map(Data(mutated.utf8)))
    }

    func testRejectsMalformedQuota() {
        XCTAssertThrowsError(try KimiUsageMapper.map(Data(#"{"usage":{}}"#.utf8)))
    }

    func testPreservesReadableFallbackForUnknownMembershipLevel() throws {
        let json = #"""
        {
          "user": {"membership": {"level": "LEVEL_FUTURE"}},
          "usage": {"limit": "100", "used": "0"}
        }
        """#

        let mapped = try KimiUsageMapper.map(Data(json.utf8))

        XCTAssertEqual(mapped.plan, "Future")
    }

    private func realUsageFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Kimi/usages-2026-08-17.json")
        return try Data(contentsOf: url)
    }

    private func accountStore(defaultModel: String, includeKey: Bool) -> KimiAuthStore {
        let keyLine = includeKey ? "api_key = \"shared-key\"" : ""
        let config = """
        default_model = "\(defaultModel)"
        [providers.kimi-code-key]
        type = "kimi"
        \(keyLine)
        [providers."managed:kimi-code"]
        type = "kimi"
        api_key = "placeholder"
        [providers."managed:kimi-code".oauth]
        storage = "file"
        [models."kimi-code/k3"]
        provider = "managed:kimi-code"
        [models."kimi-code-key/k3"]
        provider = "kimi-code-key"
        """
        return KimiAuthStore(
            files: FakeFiles([
                "~/.kimi-code/config.toml": config,
                "~/.kimi-code/credentials/kimi-code.json": #"{"access_token":"oauth-token","expires_at":2000}"#
            ]),
            environment: FakeEnvironment(),
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }

    private func managedConfig() -> String {
        #"""
        default_model = "kimi-code/k3"
        [providers."managed:kimi-code"]
        type = "kimi"
        api_key = "placeholder"
        [providers."managed:kimi-code".oauth]
        storage = "file"
        [models."kimi-code/k3"]
        provider = "managed:kimi-code"
        """#
    }

    private func progress(_ lines: [MetricLine], label: String) -> (used: Double, resetsAt: Date?)? {
        guard case .progress(_, let used, _, _, let resetsAt, _, _)? = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, resetsAt)
    }
}
