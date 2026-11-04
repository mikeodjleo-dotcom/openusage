import XCTest
@testable import OpenUsage

final class KimiProviderTests: XCTestCase {
    /// `/coding/v1/usages` as recorded on 2026-08-17, with the user id redacted.
    private let usages = #"""
    {"user":{"userId":"<redacted-user-id>","region":"REGION_CN","membership":{"level":"LEVEL_ADVANCED"},"businessId":""},
     "usage":{"limit":"100","used":"3","remaining":"97","resetTime":"2026-08-21T12:42:44.820647Z"},
     "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                "detail":{"limit":"100","used":"14","remaining":"86","resetTime":"2026-08-17T04:42:44.820647Z"}}],
     "parallel":{"limit":"30"},"totalQuota":{},"authentication":{"method":"METHOD_ACCESS_TOKEN","scope":"FEATURE_CODING"},
     "subType":"TYPE_PURCHASE","domain":"DOMAIN_NEXUS"}
    """#
    private let rotated = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":900,"scope":"new-scope","token_type":"Bearer"}"#
    private let now = Date(timeIntervalSince1970: 1000)
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credentialsDirectory.path)
        try FileManager.default.removeItem(at: home)
    }

    private var credentialsDirectory: URL { home.appendingPathComponent("credentials") }
    private var credentialURL: URL { credentialsDirectory.appendingPathComponent("kimi-code.json") }
    private var lockPath: String { home.appendingPathComponent("oauth/kimi-code.lock").path }

    private func writeCredential(access: String = "old-access", refresh: String? = "old+refresh/token", expiresAt: Int = 900, extra: String = "") throws {
        try Self.writeCredential(to: credentialURL, access: access, refresh: refresh, expiresAt: expiresAt, extra: extra)
    }

    private static func writeCredential(to url: URL, access: String, refresh: String?, expiresAt: Int, extra: String = "") throws {
        let refreshField = refresh.map { #""refresh_token":"\#($0)","# } ?? ""
        try Data(#"{"access_token":"\#(access)",\#(refreshField)"expires_at":\#(expiresAt),"expires_in":900,"scope":"old-scope","token_type":"Bearer"\#(extra)}"#.utf8)
            .write(to: url)
    }

    private func storedCredential() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: credentialURL)) as? [String: Any])
    }

    @MainActor
    private func makeRuntime(
        lockTimeout: TimeInterval = 5,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> (AccountProviderRuntime, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let fixedNow = now
        let account = Account(kind: .kimi, label: "Kimi")
        let vault = InMemoryCredentialVault()
        try! vault.save(.localCLI, for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { fixedNow })
        runtime.kimiCredentialFile = KimiCredentialFile(home: home, lockTimeout: lockTimeout)
        return (runtime, http)
    }

    /// Answers the refresh endpoint with `refreshed`, and the usage endpoint with the recording.
    private func serving(_ refreshed: HTTPResponse? = nil) -> @Sendable (HTTPRequest) async throws -> HTTPResponse {
        let usages = usages
        let refreshed = refreshed ?? .json(rotated)
        return { request in request.url == KimiUsageClient.refreshURL ? refreshed : .json(usages) }
    }

    private func progress(_ snapshot: ProviderSnapshot, _ label: String) -> (used: Double, resetsAt: Date?, period: Int?)? {
        guard case .progress(_, let used, _, _, let resetsAt, let period)? = snapshot.line(label: label) else { return nil }
        return (used, resetsAt, period)
    }

    // MARK: Response shape

    func testMapsTheRecordedResponseToAllegroWindows() throws {
        let usage = try KimiUsageMapper.map(.json(usages))

        XCTAssertEqual(usage.plan, "Allegro")
        XCTAssertEqual(usage.lines, [
            .percent("Allegro · 5-Hour Code", 14, resetsAt: OpenUsageISO8601.date(from: "2026-08-17T04:42:44.820647Z"), periodMs: KimiUsageMapper.fiveHourPeriodMs),
            .percent("Allegro · 7-Day Code", 3, resetsAt: OpenUsageISO8601.date(from: "2026-08-21T12:42:44.820647Z"), periodMs: KimiUsageMapper.sevenDayPeriodMs)
        ])
        XCTAssertNotNil(OpenUsageISO8601.date(from: "2026-08-17T04:42:44.820647Z"))
    }

    func testPrefixStaysAllegroWhenTheAPIReportsNoLevel() throws {
        let withoutUser = usages.replacingOccurrences(of: #""level":"LEVEL_ADVANCED""#, with: #""other":"x""#)
        let usage = try KimiUsageMapper.map(.json(withoutUser))

        XCTAssertNil(usage.plan)
        XCTAssertEqual(usage.lines.map(\.label), ["Allegro · 5-Hour Code", "Allegro · 7-Day Code"])
    }

    @MainActor
    func testDescriptorsMatchTheLinesAndExportSessionAndWeekly() {
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: Account(kind: .kimi, label: "Kimi"))
        XCTAssertEqual(descriptors.map(\.key), ["session", "weekly"])
        XCTAssertEqual(descriptors.map(\.metricLabel), ["Allegro · 5-Hour Code", "Allegro · 7-Day Code"])
        XCTAssertEqual(descriptors.map(\.sample.title), ["Allegro · 5-Hour Code", "Allegro · 7-Day Code"])
        XCTAssertEqual(descriptors.flatMap(\.limitResources).map(\.key), ["session", "weekly"])
    }

    func testPrefersRemainingOverAStaleUsedCounter() throws {
        let stale = usages.replacingOccurrences(of: #""used":"3""#, with: #""used":"37""#)
        guard case .progress(_, let used, _, _, _, _) = try KimiUsageMapper.map(.json(stale)).lines[1] else { return XCTFail("no progress") }
        XCTAssertEqual(used, 3)
    }

    func testFindsTheFiveHourWindowByItsDurationNotItsPosition() throws {
        let extra = usages.replacingOccurrences(
            of: #""limits":["#,
            with: #""limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","remaining":"1"}},"#
        )
        guard case .progress(_, let used, _, _, _, _) = try KimiUsageMapper.map(.json(extra)).lines[0] else { return XCTFail("no progress") }
        XCTAssertEqual(used, 14)
    }

    func testRejectsMalformedResponses() {
        XCTAssertThrowsError(try KimiUsageMapper.map(.json(#"{"usage":{}}"#)))
        XCTAssertThrowsError(try KimiUsageMapper.map(.json(usages.replacingOccurrences(of: #""detail""#, with: #""quotaDetail""#))))
    }

    // MARK: Refresh

    @MainActor
    func testLiveTokenReadsWithoutRefreshingOrWriting() async throws {
        try writeCredential(access: "live", expiresAt: 2000)
        try Data("device-1\n".utf8).write(to: home.appendingPathComponent("device_id"))
        let before = try Data(contentsOf: credentialURL)
        let (runtime, http) = makeRuntime(handler: serving())

        let snapshot = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(progress(snapshot, KimiUsageMapper.sessionLabel)?.used, 14)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer live")
        XCTAssertEqual(http.requests[0].headers["X-Msh-Device-Id"], "device-1")
        XCTAssertEqual(http.requests[0].headers["X-Msh-Platform"], "kimi_code_cli")
        XCTAssertEqual(try Data(contentsOf: credentialURL), before)
    }

    @MainActor
    func testExpiredTokenRefreshesWritesRotatedTokensBackAndReads() async throws {
        try writeCredential(extra: #","future_field":{"kept":true}"#)
        let (runtime, http) = makeRuntime(handler: serving())

        let snapshot = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(progress(snapshot, KimiUsageMapper.weeklyLabel)?.used, 3)
        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.refreshURL, KimiUsageClient.usageURL])
        XCTAssertEqual(http.requests[0].method, "POST")
        XCTAssertEqual(http.requests[0].headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(http.requests[0].body), encoding: .utf8),
            "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=old%2Brefresh%2Ftoken"
        )
        XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer new-access")

        let stored = try storedCredential()
        XCTAssertEqual(stored["access_token"] as? String, "new-access")
        XCTAssertEqual(stored["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(stored["expires_at"] as? Int, 1900)
        XCTAssertEqual(stored["expires_in"] as? Int, 900)
        XCTAssertEqual(stored["scope"] as? String, "new-scope")
        XCTAssertEqual((stored["future_field"] as? [String: Any])?["kept"] as? Bool, true)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: credentialURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: credentialsDirectory.path), ["kimi-code.json"], "no temporary file left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath), "the CLI's lock is released")
    }

    @MainActor
    func testRefusedLiveTokenRefreshesOnce() async throws {
        try writeCredential(access: "refused", expiresAt: 2000)
        let usages = usages
        let rotated = rotated
        let (runtime, http) = makeRuntime { request in
            if request.url == KimiUsageClient.refreshURL { return .json(rotated) }
            return request.headers["Authorization"] == "Bearer refused" ? .json("{}", status: 401) : .json(usages)
        }

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL, KimiUsageClient.refreshURL, KimiUsageClient.usageURL])
    }

    @MainActor
    func testInvalidGrantAsksForKimiLoginAndLeavesTheFile() async throws {
        try writeCredential()
        let before = try Data(contentsOf: credentialURL)
        let (runtime, http) = makeRuntime(handler: serving(.json(#"{"error":"invalid_grant"}"#, status: 400)))

        let failure = await runtime.refresh().failure

        XCTAssertTrue(try XCTUnwrap(failure?.message).contains("kimi login"))
        XCTAssertEqual(try Data(contentsOf: credentialURL), before)
        XCTAssertEqual(http.requests.count, 1)
    }

    @MainActor
    func testRefreshOutageIsNotAnExpiredSignIn() async throws {
        try writeCredential()
        let before = try Data(contentsOf: credentialURL)
        let (runtime, _) = makeRuntime(handler: serving(.json("", status: 503)))

        let failure = await runtime.refresh().failure

        XCTAssertFalse(try XCTUnwrap(failure?.message).contains("kimi login"))
        XCTAssertEqual(try Data(contentsOf: credentialURL), before)
    }

    @MainActor
    func testMissingFileAndTombstoneAskForKimiLoginWithoutARequest() async throws {
        let (runtime, http) = makeRuntime(handler: serving())
        var failure = await runtime.refresh().failure
        XCTAssertTrue(try XCTUnwrap(failure?.message).contains("kimi login"))

        try writeCredential(access: "", refresh: "", expiresAt: 0)
        failure = await runtime.refresh().failure
        XCTAssertTrue(try XCTUnwrap(failure?.message).contains("kimi login"))
        XCTAssertEqual(http.requests.count, 0)
    }

    // MARK: Sharing the session with the CLI

    @MainActor
    func testWaitsForTheCLIsLockThenUsesTheTokenItGot() async throws {
        try writeCredential()
        try FileManager.default.createDirectory(atPath: home.appendingPathComponent("oauth").path, withIntermediateDirectories: true)
        XCTAssertEqual(mkdir(lockPath, 0o777), 0)
        let (runtime, http) = makeRuntime(handler: serving())
        let path = lockPath
        let url = credentialURL
        let write: @Sendable () throws -> Void = { try Self.writeCredential(to: url, access: "cli-access", refresh: "cli-refresh", expiresAt: 2000) }
        Task {
            try await Task.sleep(for: .milliseconds(500))
            try write()
            rmdir(path)
        }

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(http.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer cli-access")
        XCTAssertEqual(try storedCredential()["refresh_token"] as? String, "cli-refresh")
    }

    @MainActor
    func testALockItCantGetStopsTheRefresh() async throws {
        try writeCredential()
        try FileManager.default.createDirectory(atPath: home.appendingPathComponent("oauth").path, withIntermediateDirectories: true)
        XCTAssertEqual(mkdir(lockPath, 0o777), 0)
        let (runtime, http) = makeRuntime(lockTimeout: 0.3, handler: serving())

        let failure = await runtime.refresh().failure

        XCTAssertNotNil(failure)
        XCTAssertEqual(http.requests.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath), "a lock another process holds stays")
    }

    @MainActor
    func testAStaleLockIsTakenOver() async throws {
        try writeCredential()
        try FileManager.default.createDirectory(atPath: home.appendingPathComponent("oauth").path, withIntermediateDirectories: true)
        XCTAssertEqual(mkdir(lockPath, 0o777), 0)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lockPath)
        let (runtime, http) = makeRuntime(handler: serving())

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(http.requests.first?.url, KimiUsageClient.refreshURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    @MainActor
    func testInvalidGrantAfterSomethingElseRotatedUsesItsToken() async throws {
        try writeCredential()
        let url = credentialURL
        let write: @Sendable () throws -> Void = { try Self.writeCredential(to: url, access: "other-access", refresh: "other-refresh", expiresAt: 2000) }
        let usages = usages
        let (runtime, http) = makeRuntime { request in
            guard request.url == KimiUsageClient.refreshURL else { return .json(usages) }
            try write()
            return .json(#"{"error":"invalid_grant"}"#, status: 400)
        }

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer other-access")
        XCTAssertEqual(try storedCredential()["refresh_token"] as? String, "other-refresh")
    }

    @MainActor
    func testAGrantDoesNotReplaceASignInMadeDuringTheRefresh() async throws {
        try writeCredential()
        let url = credentialURL
        let write: @Sendable () throws -> Void = { try Self.writeCredential(to: url, access: "relogin-access", refresh: "relogin-refresh", expiresAt: 2000) }
        let rotated = rotated
        let usages = usages
        let (runtime, http) = makeRuntime { request in
            guard request.url == KimiUsageClient.refreshURL else { return .json(usages) }
            try write()
            return .json(rotated)
        }

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(try storedCredential()["refresh_token"] as? String, "relogin-refresh")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new-access")
        XCTAssertNil(runtime.kimiUnsavedGrant)
    }

    @MainActor
    func testAGrantRepairsTheTombstoneOfACLIThatLostTheRace() async throws {
        try writeCredential()
        let url = credentialURL
        let write: @Sendable () throws -> Void = { try Self.writeCredential(to: url, access: "", refresh: "", expiresAt: 0) }
        let rotated = rotated
        let usages = usages
        let (runtime, _) = makeRuntime { request in
            guard request.url == KimiUsageClient.refreshURL else { return .json(usages) }
            try write()
            return .json(rotated)
        }

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(try storedCredential()["refresh_token"] as? String, "new-refresh")
    }

    @MainActor
    func testAGrantTheDiskRefusedIsKeptAndSavedOnTheNextRefresh() async throws {
        try writeCredential()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: credentialsDirectory.path)
        let (runtime, http) = makeRuntime(handler: serving())

        _ = try await runtime.readSnapshot(using: .localCLI)

        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new-access")
        XCTAssertNotNil(runtime.kimiUnsavedGrant)
        XCTAssertEqual(try storedCredential()["refresh_token"] as? String, "old+refresh/token")

        _ = try await runtime.readSnapshot(using: .localCLI)
        XCTAssertEqual(http.requests.filter { $0.url == KimiUsageClient.refreshURL }.count, 1, "the spent token is not sent again")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new-access")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credentialsDirectory.path)
        _ = try await runtime.readSnapshot(using: .localCLI)
        XCTAssertNil(runtime.kimiUnsavedGrant)
        XCTAssertEqual(try storedCredential()["refresh_token"] as? String, "new-refresh")
    }

    // MARK: Adding the account

    func testLoginNeedsTheCLIsSignInAndStoresOnlyAMarker() async throws {
        let login = KimiCLILogin(file: KimiCredentialFile(home: home))
        let (input, _) = AsyncStream.makeStream(of: String.self)
        do {
            _ = try await login.login(prompt: { _ in }, pastedCode: input)
            XCTFail("no sign-in to find")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("kimi login"))
        }

        try writeCredential()
        let result = try await login.login(prompt: { _ in }, pastedCode: input)
        XCTAssertEqual(result.credential, .localCLI)
        XCTAssertEqual(ProviderKind.kimi.authMethods, [.localCLI])
    }

    @MainActor
    func testASecondKimiAccountIsADuplicate() throws {
        let defaults = UserDefaults(suiteName: "kimi-\(UUID().uuidString)")!
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        store.add(kind: .kimi, label: "Kimi", credential: .localCLI)
        XCTAssertThrowsError(try store.checkForDuplicate(.localCLI, kind: .kimi, organization: nil))
    }
}
