import XCTest
@testable import OpenUsage

/// ChatGPT's local login only reads: no refresh request and no write, whatever the token's state.
@MainActor
final class CodexLocalLoginTests: XCTestCase {
    private nonisolated static let start = Date(timeIntervalSince1970: 1_000_000)
    private nonisolated static let usage = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_at":2000000000},"secondary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_at":2000000000}}}"#
    private var userHome: URL!

    override func setUpWithError() throws {
        userHome = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: userHome)
    }

    private nonisolated static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    private nonisolated static func auth(
        token: String = "A", account: String? = "acct-a", email: String? = "a@example.test", expiresIn: TimeInterval = 3600, mode: String? = "chatgpt"
    ) -> String {
        var tokens: [String: Any] = [
            "access_token": jwt(["tag": token, "exp": start.addingTimeInterval(expiresIn).timeIntervalSince1970]),
            "refresh_token": "must-not-be-used",
            "id_token": jwt(email.map { ["email": $0] } ?? [:])
        ]
        tokens["account_id"] = account
        var root: [String: Any] = ["tokens": tokens]
        root["auth_mode"] = mode
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    @discardableResult
    private func writeHome(_ name: String, _ text: String) throws -> String {
        let home = userHome.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: home.appendingPathComponent("auth.json"))
        return home.path
    }

    private func contents(_ home: String) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: home) {
            contents[name] = try Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent(name))
        }
        return contents
    }

    private func makeRuntime(
        home: String, accountID: String = "acct-a", clock: TestClock = TestClock(start),
        http: RoutingHTTPClient = RoutingHTTPClient { _ in .json(usage) }
    ) throws -> (runtime: AccountProviderRuntime, http: RoutingHTTPClient, vault: InMemoryCredentialVault) {
        let vault = InMemoryCredentialVault()
        let account = Account(kind: .codex, label: "a@example.test", usesLocalCLI: true, localCLIHome: home)
        try vault.save(.localCodex(accountID: accountID), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        runtime.codexLocalSource = CodexLocalSource(userHome: userHome)
        return (runtime, http, vault)
    }

    private func store() -> AccountStore {
        AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
    }

    // MARK: Discovery

    func testListsTheChatGPTLoginsAndSkipsAPIKeyHomes() throws {
        try writeHome(".codex", Self.auth(account: "acct-a", email: "a@example.test"))
        try writeHome(".codex-cli", Self.auth(account: "acct-b", email: "b@example.test"))
        try writeHome(".codex-cli2", Self.auth(account: "acct-c", email: nil, mode: nil))
        try writeHome(".codex-unity2", Self.auth(account: "acct-d", email: "d@example.test"))
        try writeHome(".codex-key", #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test"}"#)
        try writeHome(".codex-key2", #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test","tokens":{"access_token":"x","account_id":"acct-k"}}"#)
        try writeHome(".codex-noid", Self.auth(account: nil, email: "n@example.test"))
        try writeHome(".other", Self.auth(account: "acct-z"))

        let source = CodexLocalSource(userHome: userHome)
        let logins = source.logins()

        XCTAssertEqual(logins.map(\.accountID), ["acct-a", "acct-b", "acct-c", "acct-d"])
        XCTAssertEqual(logins.map(\.email), ["a@example.test", "b@example.test", nil, "d@example.test"])
        XCTAssertEqual(logins.map { source.displayPath($0.home) }, ["~/.codex", "~/.codex-cli", "~/.codex-cli2", "~/.codex-unity2"])
    }

    func testTakesTheAccountIDFromTheIDTokenWhenAuthJSONHasNone() throws {
        let tokens: [String: Any] = [
            "access_token": Self.jwt(["exp": 2_000_000_000]),
            "id_token": Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "from-claim"]])
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["tokens": tokens]), as: UTF8.self)
        let home = try writeHome(".codex", text)

        XCTAssertEqual(CodexLocalSource(userHome: userHome).login(home: home)?.accountID, "from-claim")
    }

    // MARK: Reading

    func testReadsWithTheHomesTokenAndAccountAndShowsTheSameMetrics() async throws {
        let home = try writeHome(".codex-cli", Self.auth(token: "live"))
        let (runtime, http, vault) = try makeRuntime(home: home)

        let snapshot = try await runtime.refresh().get()

        let usageRead = try XCTUnwrap(http.requests.first { $0.url == CodexUsageClient.usageURL })
        XCTAssertEqual(usageRead.headers["Authorization"], "Bearer \(Self.jwt(["tag": "live", "exp": Self.start.addingTimeInterval(3600).timeIntervalSince1970]))")
        XCTAssertEqual(usageRead.headers["ChatGPT-Account-Id"], "acct-a")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertFalse(http.requests.contains { $0.url == CodexLogin.tokenURL })
        XCTAssertEqual(try vault.load(runtime.account.id), .localCodex(accountID: "acct-a"), "the Keychain keeps no copy")
    }

    func testEachAccountReadsItsOwnHome() async throws {
        let first = try writeHome(".codex", Self.auth(token: "one", account: "acct-a"))
        let second = try writeHome(".codex-cli", Self.auth(token: "two", account: "acct-b"))
        let (a, httpA, _) = try makeRuntime(home: first, accountID: "acct-a")
        let (b, httpB, _) = try makeRuntime(home: second, accountID: "acct-b")

        _ = try await a.refresh().get()
        _ = try await b.refresh().get()

        XCTAssertEqual(httpA.requests.first?.headers["ChatGPT-Account-Id"], "acct-a")
        XCTAssertEqual(httpB.requests.first?.headers["ChatGPT-Account-Id"], "acct-b")
        XCTAssertNotEqual(httpA.requests.first?.headers["Authorization"], httpB.requests.first?.headers["Authorization"])
    }

    func testAHomeSignedInToAnotherAccountIsNotReadAsThisOne() async throws {
        let home = try writeHome(".codex", Self.auth(account: "acct-other"))
        let (runtime, http, _) = try makeRuntime(home: home, accountID: "acct-a")

        let failure = await runtime.refresh().failure

        XCTAssertTrue(try XCTUnwrap(failure?.message).contains("another ChatGPT account"))
        XCTAssertEqual(http.requests.count, 0)
    }

    // MARK: Never renewing

    func testAnExpiredTokenSendsNothingWritesNothingAndRecoversOnTheNextPass() async throws {
        let home = try writeHome(".codex", Self.auth(expiresIn: -60))
        let before = try contents(home)
        let (runtime, http, vault) = try makeRuntime(home: home)
        let widgets = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { Self.start })

        await widgets.refreshAll()

        XCTAssertEqual(http.requests.count, 0)
        XCTAssertEqual(try contents(home), before)
        XCTAssertEqual(try vault.load(runtime.account.id), .localCodex(accountID: "acct-a"))
        XCTAssertEqual(widgets.problem(for: runtime.provider.id), "The ChatGPT sign-in in ~/.codex has expired. Open Codex and this recovers on the next refresh.")

        try writeHome(".codex", Self.auth(token: "new"))
        await widgets.refresh(providerID: runtime.provider.id, force: true)
        XCTAssertFalse(http.requests.isEmpty)
        XCTAssertNil(widgets.problem(for: runtime.provider.id))
    }

    func testARefused401DoesNotRenewOrWrite() async throws {
        let home = try writeHome(".codex", Self.auth())
        let before = try contents(home)
        let (runtime, http, _) = try makeRuntime(home: home, http: RoutingHTTPClient { _ in .json("{}", status: 401) })

        let failure = await runtime.refresh().failure

        XCTAssertTrue(try XCTUnwrap(failure?.message).contains("has expired"))
        XCTAssertFalse(http.requests.contains { $0.url == CodexLogin.tokenURL || $0.method == "POST" })
        XCTAssertEqual(try contents(home), before)
    }

    func testAMissingLoginSaysSoWithoutARequest() async throws {
        let (runtime, http, _) = try makeRuntime(home: userHome.appendingPathComponent(".codex-gone").path)

        let failure = await runtime.refresh().failure

        XCTAssertTrue(try XCTUnwrap(failure?.message).contains("~/.codex-gone"))
        XCTAssertEqual(http.requests.count, 0)
    }

    // MARK: OAuth accounts are unaffected

    func testAnOAuthAccountStillRenews() async throws {
        let vault = InMemoryCredentialVault()
        let account = Account(kind: .codex, label: "Work")
        try vault.save(.oauth(OAuthTokens(accessToken: "old", refreshToken: "refresh", expiresAt: Self.start.addingTimeInterval(-60), extras: ["chatgpt_account_id": "acct-a"])), for: account.id)
        let http = RoutingHTTPClient { request in
            request.url == CodexLogin.tokenURL ? .json(#"{"access_token":"renewed","refresh_token":"refresh-2","expires_in":3600}"#) : .json(Self.usage)
        }
        let start = Self.start
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { start })
        runtime.codexLocalSource = CodexLocalSource(userHome: userHome)

        _ = try await runtime.refresh().get()

        XCTAssertEqual(http.requests.first?.url, CodexLogin.tokenURL)
        XCTAssertEqual(account.authMethod, .oauth)
    }

    // MARK: Adding

    func testBothMethodsAreOfferedWithTheBrowserFirst() {
        XCTAssertEqual(ProviderKind.codex.authMethods, [.oauth, .localCLI])
    }

    func testTwoHomesWithTwoAccountsCanBothBeAdded() throws {
        let accounts = store()
        let first = CodexLocalLogin(home: "/h/.codex", accountID: "acct-a", email: "mallie@example.test", accessToken: "x")
        let second = CodexLocalLogin(home: "/h/.codex-cli", accountID: "acct-b", email: "qq@example.test", accessToken: "y")
        var opened: [URL] = []
        for login in [first, second] {
            let flow = AddAccountFlow(store: accounts, openURL: { opened.append($0) }, findCodexLogins: { [first, second] })
            flow.choose(.codex)
            XCTAssertNil(flow.method, "the sheet asks which")
            flow.choose(.localCLI)
            XCTAssertEqual(flow.codexLogins, [first, second])
            XCTAssertFalse(flow.isWorking)
            flow.add(login)
            XCTAssertTrue(flow.isFinished)
        }
        XCTAssertEqual(accounts.accounts.map(\.label), ["mallie@example.test", "qq@example.test"])
        XCTAssertEqual(accounts.accounts.map(\.localCLIHome), ["/h/.codex", "/h/.codex-cli"])
        XCTAssertEqual(accounts.accounts.map(\.authMethod), [.localCLI, .localCLI])
        XCTAssertEqual(try accounts.accounts.map { try accounts.credential(for: $0.id) }, [.localCodex(accountID: "acct-a"), .localCodex(accountID: "acct-b")])
        XCTAssertEqual(opened, [])
    }

    func testTheSameAccountInASecondHomeIsADuplicate() throws {
        let accounts = store()
        let first = CodexLocalLogin(home: "/h/.codex", accountID: "acct-a", email: "a@example.test", accessToken: "x")
        let second = CodexLocalLogin(home: "/h/.codex-cli", accountID: "acct-a", email: "a@example.test", accessToken: "y")
        let adding = AddAccountFlow(store: accounts, openURL: { _ in }, findCodexLogins: { [first, second] })
        adding.choose(.codex)
        adding.choose(.localCLI)
        adding.add(first)

        let again = AddAccountFlow(store: accounts, openURL: { _ in }, findCodexLogins: { [first, second] })
        again.choose(.codex)
        again.choose(.localCLI)
        again.add(second)

        XCTAssertEqual(again.errorMessage, "This account is already added as a@example.test.")
        XCTAssertFalse(again.isFinished)
        XCTAssertEqual(accounts.accounts.count, 1)
    }

    func testTheHomeSurvivesASaveAndAnOlderAccountHasNone() throws {
        let local = Account(kind: .codex, label: "a", usesLocalCLI: true, localCLIHome: "/h/.codex")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(decoded.localCLIHome, "/h/.codex")
        XCTAssertEqual(decoded.authMethod, .localCLI)

        let json = try JSONEncoder().encode(Account(kind: .codex, label: "Work"))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("localCLIHome"))
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: json).authMethod, .oauth)
    }

    func testTheLocalMarkerHoldsNoToken() throws {
        let json = String(decoding: try JSONEncoder().encode(AccountCredential.localCodex(accountID: "acct-a")), as: UTF8.self)
        XCTAssertFalse(json.contains("Token"))
        XCTAssertEqual(AccountCredential.localCodex(accountID: "acct-a").identity, "codex:acct-a")
    }
}
