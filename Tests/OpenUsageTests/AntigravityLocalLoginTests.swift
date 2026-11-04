import XCTest
@testable import OpenUsage

/// Antigravity's local login never writes to the Keychain or the token file: an expired access token is
/// renewed in memory only.
@MainActor
final class AntigravityLocalLoginTests: XCTestCase {
    private nonisolated static let start = OpenUsageISO8601.date(from: "2026-11-04T12:00:00Z")!
    private nonisolated static let summary = #"""
    {"description":"fake","groups":[
      {"displayName":"Gemini","description":"fake","buckets":[
        {"bucketId":"gemini-5h","displayName":"fake","remainingFraction":0.8,"resetTime":"2026-11-04T15:00:00Z","window":"5h"},
        {"bucketId":"gemini-weekly","displayName":"fake","remainingFraction":0.75,"resetTime":"2026-11-10T00:00:00Z","window":"weekly"}]},
      {"displayName":"Claude","description":"fake","buckets":[
        {"bucketId":"3p-5h","displayName":"fake","remainingFraction":0.6,"resetTime":"2026-11-04T15:00:00Z","window":"5h"},
        {"bucketId":"3p-weekly","displayName":"fake","remainingFraction":0.5,"resetTime":"2026-11-10T00:00:00Z","window":"weekly"}]}]}
    """#
    private var userHome: URL!

    override func setUpWithError() throws {
        userHome = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tokenDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: userHome)
    }

    private var tokenDirectory: URL { userHome.appendingPathComponent(".gemini/antigravity-cli") }

    private nonisolated static func json(access: String? = "live", refresh: String? = "refresh-1", expiresIn: TimeInterval = 3600, email: String? = "me@example.test") -> String {
        var token: [String: Any] = ["expiry": OpenUsageISO8601.string(from: start.addingTimeInterval(expiresIn)), "token_type": "Bearer", "expires_in": 3599]
        token["access_token"] = access
        token["refresh_token"] = refresh
        var root: [String: Any] = ["token": token, "auth_method": "oauth"]
        root["id_token_email"] = email
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    private nonisolated static func keyring(_ text: String) -> String {
        "go-keyring-base64:" + Data(text.utf8).base64EncodedString()
    }

    private func writeFile(_ text: String) throws {
        try Data(text.utf8).write(to: tokenDirectory.appendingPathComponent("antigravity-oauth-token"))
    }

    private func fileContents() throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: tokenDirectory.path) {
            contents[name] = try Data(contentsOf: tokenDirectory.appendingPathComponent(name))
        }
        return contents
    }

    private nonisolated static func google(
        renewal: @escaping @Sendable () -> HTTPResponse = { .json(#"{"access_token":"renewed","expires_in":3600,"token_type":"Bearer"}"#) }
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            if request.url == AntigravityLogin.tokenURL { return renewal() }
            return request.url.path.hasSuffix(AntigravityUsageClient.quotaSummaryPath) ? .json(summary) : .json("{}")
        }
    }

    private func makeRuntime(
        keychain: @escaping @Sendable (TimeInterval) throws -> String?,
        clock: TestClock = TestClock(start),
        http: RoutingHTTPClient = google()
    ) throws -> (runtime: AccountProviderRuntime, http: RoutingHTTPClient, vault: InMemoryCredentialVault) {
        let vault = InMemoryCredentialVault()
        let account = Account(kind: .antigravity, label: "me@example.test", usesLocalCLI: true)
        try vault.save(.localCLI, for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        runtime.antigravityLocalSource = AntigravityLocalSource(readKeychain: keychain, userHome: userHome)
        return (runtime, http, vault)
    }

    private func quotaReads(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url.path.hasSuffix(AntigravityUsageClient.quotaSummaryPath) }
    }

    private func renewals(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url == AntigravityLogin.tokenURL }
    }

    // MARK: Sources

    func testReadsTheKeychainItemAndKeepsTheClientsUserAgent() async throws {
        let (runtime, http, vault) = try makeRuntime(keychain: { _ in Self.keyring(Self.json(access: "from-keychain")) })

        let snapshot = try await runtime.refresh().get()

        let read = try XCTUnwrap(quotaReads(http).first)
        XCTAssertEqual(read.headers["Authorization"], "Bearer from-keychain")
        XCTAssertEqual(read.headers["User-Agent"], AntigravityUsageClient.clientUserAgent)
        XCTAssertEqual(renewals(http).count, 0)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI, "the Keychain keeps no copy")
        XCTAssertNotNil(snapshot.line(label: AntigravityMetric.sessionLabel), "Gemini group")
        XCTAssertNotNil(snapshot.line(label: AntigravityMetric.weeklyLabel), "Gemini group")
        XCTAssertNotNil(snapshot.line(label: AntigravityMetric.claudeLabel), "3p group")
        XCTAssertNotNil(snapshot.line(label: AntigravityMetric.claudeWeeklyLabel), "3p group")
    }

    func testReadsTheFileWhenTheKeychainHasNoItem() async throws {
        try writeFile(Self.json(access: "from-file"))
        let (runtime, http, _) = try makeRuntime(keychain: { _ in nil })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(quotaReads(http).first?.headers["Authorization"], "Bearer from-file")
    }

    func testTheTokenThatExpiresLaterIsTheNewerOne() {
        let cases: [(keychain: TimeInterval, file: TimeInterval, expected: String)] = [
            (3600, 1800, "from-keychain"),
            (1800, 3600, "from-file"),
            (1800, 1800, "from-keychain")
        ]
        for item in cases {
            let keychain = Self.keyring(Self.json(access: "from-keychain", expiresIn: item.keychain))
            try? writeFile(Self.json(access: "from-file", expiresIn: item.file))
            let source = AntigravityLocalSource(readKeychain: { _ in keychain }, userHome: userHome)
            XCTAssertEqual(source.read(keychainTimeout: 5).token?.accessToken, item.expected)
        }
    }

    func testParsesTheEmail() {
        XCTAssertEqual(AntigravityLocalSource.parse(Self.json())?.email, "me@example.test")
        XCTAssertNil(AntigravityLocalSource.parse("go-keyring-base64:!!!"))
        XCTAssertNil(AntigravityLocalSource.parse("not json"))
    }

    // MARK: Renewing in memory

    func testAnExpiredTokenRenewsInMemoryOnceAndWritesNothing() async throws {
        try writeFile(Self.json(access: "stale-file", expiresIn: -7200))
        let before = try fileContents()
        let clock = TestClock(Self.start)
        let (runtime, http, vault) = try makeRuntime(
            keychain: { _ in Self.keyring(Self.json(access: "stale", refresh: "refresh+1", expiresIn: -60)) },
            clock: clock
        )

        _ = try await runtime.refresh().get()
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        _ = try await runtime.refresh().get()

        XCTAssertEqual(renewals(http).count, 1, "the renewed token is kept in memory between passes")
        let body = String(decoding: try XCTUnwrap(renewals(http)[0].body), as: UTF8.self)
        XCTAssertTrue(body.contains("refresh_token=refresh%2B1"))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(quotaReads(http).allSatisfy { $0.headers["Authorization"] == "Bearer renewed" })
        XCTAssertEqual(try fileContents(), before)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI, "the app's Keychain item keeps no token")
    }

    func testRenewsAgainWhenTheRenewedTokenRunsOut() async throws {
        let clock = TestClock(Self.start)
        let (runtime, http, _) = try makeRuntime(keychain: { _ in Self.json(expiresIn: -60) }, clock: clock)

        _ = try await runtime.refresh().get()
        clock.set(Self.start.addingTimeInterval(3600))
        _ = try await runtime.refresh().get()

        XCTAssertEqual(renewals(http).count, 2)
    }

    func testAgyNewerLoginReplacesTheRenewedToken() async throws {
        let item = TestSwitch(Self.json(access: "stale", refresh: "refresh-1", expiresIn: -60))
        let clock = TestClock(Self.start)
        let (runtime, http, _) = try makeRuntime(keychain: { _ in item.value }, clock: clock)

        _ = try await runtime.refresh().get()
        item.value = Self.json(access: "agy-new", refresh: "refresh-2", expiresIn: 3600)
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        _ = try await runtime.refresh().get()

        XCTAssertEqual(quotaReads(http).last?.headers["Authorization"], "Bearer agy-new")
        XCTAssertEqual(renewals(http).count, 1)
    }

    func testARefusedLiveTokenRenewsOnceInMemory() async throws {
        let http = RoutingHTTPClient { request in
            if request.url == AntigravityLogin.tokenURL { return .json(#"{"access_token":"renewed","expires_in":3600}"#) }
            guard request.url.path.hasSuffix(AntigravityUsageClient.quotaSummaryPath) else { return .json("{}") }
            return request.headers["Authorization"] == "Bearer renewed" ? .json(Self.summary) : .json("{}", status: 401)
        }
        let (runtime, _, vault) = try makeRuntime(keychain: { _ in Self.json() }, http: http)

        _ = try await runtime.refresh().get()

        XCTAssertEqual(renewals(http).count, 1)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI)
    }

    func testADeadRefreshTokenAsksToSignInAgain() async throws {
        let (runtime, http, _) = try makeRuntime(
            keychain: { _ in Self.json(expiresIn: -60) },
            http: Self.google(renewal: { .json(#"{"error":"invalid_grant"}"#, status: 400) })
        )

        let failure = await runtime.refresh().failure

        XCTAssertEqual(failure?.message, AntigravityLocalMessage.expired)
        XCTAssertEqual(quotaReads(http).count, 0)
    }

    func testARenewalOutageIsReportedAsAnOutage() async throws {
        let (runtime, _, _) = try makeRuntime(
            keychain: { _ in Self.json(expiresIn: -60) },
            http: Self.google(renewal: { .json("", status: 503) })
        )

        let failure = await runtime.refresh().failure

        XCTAssertEqual(failure?.message, ProviderError.requestFailed(503).localizedDescription)
    }

    func testAnExpiredTokenWithNoRefreshTokenAsksToSignInAgainWithoutARequest() async throws {
        let (runtime, http, _) = try makeRuntime(keychain: { _ in Self.json(refresh: nil, expiresIn: -60) })

        let failure = await runtime.refresh().failure

        XCTAssertEqual(failure?.message, AntigravityLocalMessage.expired)
        XCTAssertEqual(http.requests.count, 0)
    }

    func testARotatedRefreshTokenIsRefusedNotUsed() async throws {
        let (runtime, http, _) = try makeRuntime(
            keychain: { _ in Self.json(expiresIn: -60) },
            http: Self.google(renewal: { .json(#"{"access_token":"renewed","refresh_token":"new-refresh","expires_in":3600}"#) })
        )

        let failure = await runtime.refresh().failure

        XCTAssertEqual(failure?.message, AntigravityLocalMessage.rotated)
        XCTAssertEqual(quotaReads(http).count, 0)
    }

    // MARK: The Keychain

    func testARefusedKeychainSaysSoAndIsNotAskedAgainForAnHour() async throws {
        let reads = TestSwitch(0)
        let clock = TestClock(Self.start)
        let (runtime, http, _) = try makeRuntime(
            keychain: { _ in reads.value += 1; throw ProviderError.unavailable("denied") },
            clock: clock
        )

        var failure = await runtime.refresh().failure
        XCTAssertEqual(failure?.message, AntigravityLocalMessage.keychain)
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        failure = await runtime.refresh().failure
        XCTAssertEqual(failure?.message, AntigravityLocalMessage.keychain)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(http.requests.count, 0)

        clock.set(Self.start.addingTimeInterval(AccountProviderRuntime.antigravityKeychainRetryInterval + 1))
        _ = await runtime.refresh()
        XCTAssertEqual(reads.value, 2)
    }

    func testARefusedKeychainStillUsesTheFile() async throws {
        try writeFile(Self.json(access: "from-file"))
        let (runtime, http, _) = try makeRuntime(keychain: { _ in throw ProviderError.unavailable("denied") })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(quotaReads(http).first?.headers["Authorization"], "Bearer from-file")
    }

    // MARK: OAuth accounts are unaffected

    func testAnOAuthAccountStillRenewsThroughItsVaultAndNeverReadsAgy() async throws {
        let reads = TestSwitch(0)
        let vault = InMemoryCredentialVault()
        let account = Account(kind: .antigravity, label: "Work")
        try vault.save(.oauth(OAuthTokens(accessToken: "old", refreshToken: "refresh", expiresAt: Self.start.addingTimeInterval(-60))), for: account.id)
        let http = Self.google()
        let start = Self.start
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { start })
        runtime.antigravityLocalSource = AntigravityLocalSource(readKeychain: { _ in reads.value += 1; return nil }, userHome: userHome)

        _ = try await runtime.refresh().get()

        XCTAssertEqual(renewals(http).count, 1)
        guard case .oauth(let saved)? = try vault.load(account.id) else { return XCTFail("no sign-in") }
        XCTAssertEqual(saved.accessToken, "renewed", "an OAuth account saves its renewal as before")
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(account.authMethod, .oauth)
    }

    // MARK: Adding

    func testTheLocalLoginOpensNoBrowserAndIsNamedByItsEmail() async throws {
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        var opened: [URL] = []
        let source = AntigravityLocalSource(readKeychain: { _ in Self.keyring(Self.json()) }, userHome: userHome)
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, method, _ in
            XCTAssertEqual(method, .localCLI)
            return AntigravityLocalLogin(source: source)
        }

        XCTAssertEqual(ProviderKind.antigravity.authMethods, [.oauth, .localCLI])
        flow.choose(.antigravity)
        XCTAssertNil(flow.method, "the sheet asks which")
        flow.choose(.localCLI)
        XCTAssertFalse(flow.isWorking, "adding waits for the confirmation")
        flow.signIn()
        try await waitUntil { flow.isFinished }

        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.label, "me@example.test")
        XCTAssertEqual(account.authMethod, .localCLI)
        XCTAssertEqual(try vault.load(account.id), .localCLI)
        XCTAssertEqual(opened, [])
    }

    func testTheLoginExplainsARefusedKeychainAndAMissingLogin() async throws {
        let (input, _) = AsyncStream.makeStream(of: String.self)
        do {
            _ = try await AntigravityLocalLogin(source: AntigravityLocalSource(readKeychain: { _ in throw ProviderError.unavailable("denied") }, userHome: userHome))
                .login(prompt: { _ in }, pastedCode: input)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, AntigravityLocalMessage.keychain)
        }
        do {
            _ = try await AntigravityLocalLogin(source: AntigravityLocalSource(readKeychain: { _ in nil }, userHome: userHome))
                .login(prompt: { _ in }, pastedCode: input)
            XCTFail("expected no login")
        } catch {
            XCTAssertEqual(error.localizedDescription, AntigravityLocalMessage.missing)
        }
    }
}
