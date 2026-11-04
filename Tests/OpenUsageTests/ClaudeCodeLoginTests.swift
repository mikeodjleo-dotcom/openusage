import XCTest
@testable import OpenUsage

/// Claude's local login only reads: no refresh request and no write, whatever the token's state.
@MainActor
final class ClaudeCodeLoginTests: XCTestCase {
    private nonisolated static let start = Date(timeIntervalSince1970: 1_000_000)
    private nonisolated static let usage = #"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"},"seven_day":{"utilization":7,"resets_at":"2099-01-02T00:00:00.000Z"}}"#
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private nonisolated static func item(_ token: String, expiresIn: TimeInterval = 3600, from now: Date = start) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"must-not-be-used","expiresAt":\#(Int(now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)),"scopes":["user:profile"]}}"#
    }

    private func writeFile(_ text: String) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(".credentials.json"))
    }

    /// Everything in the fake `~/.claude`, to show nothing was written.
    private func homeContents() throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: home.path) {
            contents[name] = try Data(contentsOf: home.appendingPathComponent(name))
        }
        return contents
    }

    private func makeRuntime(
        keychain: @escaping @Sendable (TimeInterval) throws -> String?,
        clock: TestClock = TestClock(start),
        http: RoutingHTTPClient = RoutingHTTPClient { _ in .json(usage) }
    ) throws -> (runtime: AccountProviderRuntime, http: RoutingHTTPClient, vault: InMemoryCredentialVault) {
        let vault = InMemoryCredentialVault()
        let account = Account(kind: .claude, label: "Claude Code", usesLocalCLI: true)
        try vault.save(.localCLI, for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        runtime.claudeCodeSource = ClaudeCodeSource(readKeychain: keychain, home: home)
        return (runtime, http, vault)
    }

    private func assertNoRenewal(_ http: RoutingHTTPClient, line: UInt = #line) {
        XCTAssertFalse(http.requests.contains { $0.url == ClaudeLogin.tokenURL }, line: line)
        XCTAssertFalse(http.requests.contains { $0.method == "POST" }, line: line)
    }

    // MARK: Reading

    func testReadsWithTheKeychainTokenAndShowsTheSameMetrics() async throws {
        try writeFile(Self.item("file-token"))
        let (runtime, http, vault) = try makeRuntime(keychain: { _ in Self.item("keychain-token") })

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(http.requests.map(\.url), [ClaudeUsageClient.usageURL])
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer keychain-token")
        guard case .progress(_, let used, _, _, _, _)? = snapshot.line(label: "Session") else { return XCTFail("no Session row") }
        XCTAssertEqual(used, 42)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI, "the Keychain keeps no copy")
    }

    func testAHexEncodedKeychainItemIsRead() async throws {
        let hex = Self.item("hex-token").utf8.map { String(format: "%02x", $0) }.joined()
        let (runtime, http, _) = try makeRuntime(keychain: { _ in hex })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer hex-token")
    }

    func testFallsBackToTheFile() async throws {
        try writeFile(Self.item("file-token"))
        let (runtime, http, _) = try makeRuntime(keychain: { _ in nil })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer file-token")
    }

    func testAnExpiredKeychainItemGivesWayToALiveFile() async throws {
        try writeFile(Self.item("file-token"))
        let (runtime, http, _) = try makeRuntime(keychain: { _ in Self.item("old", expiresIn: -60) })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer file-token")
    }

    func testEveryRefreshRereads() async throws {
        let token = TestSwitch("first")
        let clock = TestClock(Self.start)
        let (runtime, http, _) = try makeRuntime(keychain: { _ in Self.item(token.value) }, clock: clock)

        _ = try await runtime.refresh().get()
        token.value = "rotated-by-claude-code"
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer first", "Bearer rotated-by-claude-code"])
    }

    // MARK: Never renewing

    func testAnExpiredTokenSendsNothingWritesNothingAndRecoversOnTheNextPass() async throws {
        let contents = Self.item("old", expiresIn: -60)
        try writeFile(contents)
        let token = TestSwitch(contents)
        let (runtime, http, vault) = try makeRuntime(keychain: { _ in token.value })
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        let before = try homeContents()

        await store.refreshAll()

        XCTAssertEqual(http.requests.count, 0)
        XCTAssertEqual(try homeContents(), before)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI)
        XCTAssertEqual(store.problem(for: runtime.provider.id), ClaudeCodeMessage.expired)

        token.value = Self.item("new")
        await store.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new")
        XCTAssertNil(store.problem(for: runtime.provider.id))
    }

    func testAnExpiredLoginWaitsOneRefreshIntervalNotALongerBackoff() {
        let failure = RefreshFailure(error: ProviderError.unreachable(ClaudeCodeMessage.expired))
        var backoff = RefreshBackoff.after(failure, previous: nil, now: Self.start)
        backoff = RefreshBackoff.after(failure, previous: backoff, now: Self.start)
        XCTAssertEqual(backoff.retryAt, Self.start + RefreshSetting.failureBackoffBase)
    }

    func testARefused401DoesNotRenew() async throws {
        try writeFile(Self.item("file-token"))
        let before = try homeContents()
        let (runtime, http, vault) = try makeRuntime(
            keychain: { _ in nil },
            http: RoutingHTTPClient { _ in .json("{}", status: 401) }
        )

        let failure = await runtime.refresh().failure

        XCTAssertEqual(failure?.message, ClaudeCodeMessage.expired)
        XCTAssertEqual(http.requests.count, 1)
        assertNoRenewal(http)
        XCTAssertEqual(try homeContents(), before)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI)
    }

    func testTheHourlyReadsNeitherRenewNorStoreTheToken() async throws {
        let http = RoutingHTTPClient { request in
            request.url == ClaudeUsageClient.profileURL
                ? .json(#"{"account":{"uuid":"acct"},"organization":{"uuid":"6a9f1c2e-1b4d-4c3a-9e8f-0123456789ab","organization_type":"claude_max"}}"#)
                : .json(Self.usage)
        }
        let (runtime, _, vault) = try makeRuntime(keychain: { _ in Self.item("token") }, http: http)
        let snapshot = try await runtime.refresh().get()

        let updated = await runtime.refreshHourlyReads(of: snapshot)

        XCTAssertEqual(updated?.plan, "Max", "the plan reads as on an OAuth account")
        assertNoRenewal(http)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCLI)
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
        XCTAssertEqual(failure?.message, ClaudeCodeMessage.keychain)
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        failure = await runtime.refresh().failure
        XCTAssertEqual(failure?.message, ClaudeCodeMessage.keychain)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(http.requests.count, 0)

        clock.set(Self.start.addingTimeInterval(AccountProviderRuntime.claudeKeychainRetryInterval + 1))
        _ = await runtime.refresh()
        XCTAssertEqual(reads.value, 2)
    }

    func testARefreshGivesAPromptNoLongerThanFiveSeconds() async throws {
        let timeout = TestSwitch<TimeInterval>(0)
        let (runtime, _, _) = try makeRuntime(keychain: { asked in timeout.value = asked; return Self.item("token") })

        _ = await runtime.refresh()

        XCTAssertEqual(timeout.value, 5)
    }

    func testARefusedKeychainStillUsesALiveFile() async throws {
        try writeFile(Self.item("file-token"))
        let (runtime, http, _) = try makeRuntime(keychain: { _ in throw ProviderError.unavailable("denied") })

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer file-token")
    }

    // MARK: 429

    func testA429KeepsTheLastReadingAndHoldsTheNextRequest() async throws {
        let limited = TestSwitch(false)
        let clock = TestClock(Self.start)
        let http = RoutingHTTPClient { _ in
            limited.value ? HTTPResponse(statusCode: 429, headers: ["retry-after": "3600"], body: Data()) : .json(Self.usage)
        }
        let (runtime, _, _) = try makeRuntime(keychain: { _ in Self.item("token", expiresIn: 90000) }, clock: clock, http: http)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        let session = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "session" })

        await store.refreshAll()
        limited.value = true
        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval))
        await store.refreshAll()
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(store.data(for: session).hasData)
        XCTAssertEqual(store.data(for: session).used, 42)

        clock.set(Self.start.addingTimeInterval(RefreshSetting.interval * 2))
        await store.refreshAll()
        XCTAssertEqual(http.requests.count, 2, "nothing is sent inside the 429 window")
    }

    // MARK: OAuth accounts are unaffected

    func testAnOAuthAccountStillRenewsAndNeverReadsClaudeCode() async throws {
        let reads = TestSwitch(0)
        let vault = InMemoryCredentialVault()
        let account = Account(kind: .claude, label: "Work")
        try vault.save(.oauth(OAuthTokens(accessToken: "old", refreshToken: "refresh", expiresAt: Self.start.addingTimeInterval(-60))), for: account.id)
        let http = RoutingHTTPClient { request in
            request.url == ClaudeLogin.tokenURL
                ? .json(#"{"access_token":"renewed","refresh_token":"refresh-2","expires_in":3600}"#)
                : .json(Self.usage)
        }
        let start = Self.start
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { start })
        runtime.claudeCodeSource = ClaudeCodeSource(readKeychain: { _ in reads.value += 1; return nil }, home: home)

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests.first?.url, ClaudeLogin.tokenURL)
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer renewed")
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(account.authMethod, .oauth)
    }

    // MARK: Adding the account

    func testBothMethodsAreOfferedWithTheBrowserFirst() {
        XCTAssertEqual(ProviderKind.claude.authMethods, [.oauth, .localCLI])
    }

    func testTheLocalLoginOpensNoBrowserAndStoresOnlyTheMarker() async throws {
        let vault = InMemoryCredentialVault()
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        var opened: [URL] = []
        let source = ClaudeCodeSource(readKeychain: { _ in Self.item("token") }, home: home)
        let flow = AddAccountFlow(store: store, openURL: { opened.append($0) }) { _, method, _ in
            XCTAssertEqual(method, .localCLI)
            return ClaudeCodeLogin(source: source)
        }

        flow.choose(.claude)
        XCTAssertNil(flow.method, "the sheet asks which")
        flow.choose(.localCLI)
        XCTAssertFalse(flow.isWorking, "adding waits for the confirmation")
        flow.signIn()
        try await waitUntil { flow.isFinished }

        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.authMethod, .localCLI)
        XCTAssertEqual(try vault.load(account.id), .localCLI)
        XCTAssertEqual(opened, [])
    }

    func testTheLoginExplainsARefusedKeychainAndAMissingLogin() async throws {
        let (input, _) = AsyncStream.makeStream(of: String.self)
        do {
            _ = try await ClaudeCodeLogin(source: ClaudeCodeSource(readKeychain: { _ in throw ProviderError.unavailable("denied") }, home: home))
                .login(prompt: { _ in }, pastedCode: input)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, ClaudeCodeMessage.keychain)
        }
        do {
            _ = try await ClaudeCodeLogin(source: ClaudeCodeSource(readKeychain: { _ in nil }, home: home))
                .login(prompt: { _ in }, pastedCode: input)
            XCTFail("expected no login")
        } catch {
            XCTAssertEqual(error.localizedDescription, ClaudeCodeMessage.missing)
        }
    }

    func testTheMethodSurvivesASaveAndAnOlderAccountStaysOAuth() throws {
        let local = Account(kind: .claude, label: "Claude Code", usesLocalCLI: true)
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(decoded.authMethod, .localCLI)

        let older = Account(kind: .claude, label: "Work")
        let json = try JSONEncoder().encode(older)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("usesLocalCLI"))
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: json).authMethod, .oauth)
    }

    func testALocalAccountOffersNoSignInAgainOrReplaceKey() {
        let account = Account(kind: .claude, label: "Claude Code", usesLocalCLI: true)
        XCTAssertNotEqual(account.authMethod, .oauth)
    }
}
