import XCTest
@testable import OpenUsage

@MainActor
final class CodexAccountAssemblyTests: XCTestCase {
    private func auth(_ id: String, email: String) -> String {
        let payload = Data("{\"email\":\"\(email)\"}".utf8).base64EncodedString()
        return "{\"tokens\":{\"access_token\":\"test\",\"account_id\":\"\(id)\",\"id_token\":\"header.\(payload).signature\"}}"
    }

    func testDefaultHomeChangeKeepsBothPermanentCardsBoundToTheirOwnAccounts() throws {
        let suite = "OpenUsageTests.CodexAccountAssembly.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderAccountsStore(defaults: defaults)
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": auth("mallie", email: "mallie@example.com"),
            "/Users/dev/.codex-cli/auth.json": auth("mallie", email: "mallie@example.com"),
            "/Users/dev/.codex-cli2/auth.json": auth("qq", email: "qq@example.com"),
        ])
        let qqID = ProviderAccountID.make(family: "codex", identityKey: "qq")

        func assemble(home: String?) -> ProviderAccountAssembly {
            let environment = FakeEnvironment(home.map { ["CODEX_HOME": $0] } ?? [:])
            return ProviderAccountAssembly.make(
                observer: DefaultAccountObserver(
                    environment: environment, files: files, keychain: FakeKeychain(nil),
                    homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
                ),
                accountsStore: store,
                families: ["codex"],
                codexDiscovery: CodexHomeDiscovery(
                    environment: environment, files: files,
                    homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
                    listSubdirectories: { url in
                        guard url.path == "/Users/dev" else { return [] }
                        return [".codex", ".codex-cli", ".codex-cli2"].map { url.appendingPathComponent($0) }
                    }
                )
            )
        }

        // First launch gives mallie the permanent bare id. Moving CODEX_HOME to qq must not
        // transfer that id's name to qq's numbers, or hide either account on the next launch.
        let first = assemble(home: nil)
        XCTAssertEqual(first.defaultCodexCard?.id, "codex")
        XCTAssertEqual(first.codexCards.map(\.id), [qqID])
        XCTAssertEqual(first.defaultCodexCard?.extraLogRoots.map(\.path), ["/Users/dev/.codex-cli"])

        let changed = assemble(home: "/Users/dev/.codex-cli2")
        XCTAssertEqual(changed.defaultCodexCard?.id, qqID)
        XCTAssertEqual(changed.codexCards.map(\.id), ["codex"], "the old bare-id guard drops mallie's card")
        XCTAssertEqual(changed.identityKeysByCard, ["codex": "mallie", qqID: "qq"])
        XCTAssertEqual(changed.codexCards.first?.homePath, "/Users/dev/.codex")
        XCTAssertEqual(changed.codexCards.first?.extraLogRoots.map(\.path), ["/Users/dev/.codex-cli"])

        let runtimes = ProviderCatalog.make(
            defaults: defaults, codexCards: changed.codexCards,
            defaultCodexCard: changed.defaultCodexCard
        ).compactMap { $0 as? CodexProvider }
        XCTAssertEqual(runtimes.count, 2)
        let registry = WidgetRegistry.from(runtimes)
        XCTAssertEqual(registry.orderedProviderIDs(savedOrder: ["codex", qqID]), ["codex", qqID])
        for runtime in runtimes {
            let id = runtime.provider.id
            let isMallie = id == "codex"
            let expectedHome = isMallie ? "/Users/dev/.codex" : "/Users/dev/.codex-cli2"
            XCTAssertEqual(runtime.authStore.scope, .home(path: expectedHome))
            var authStore = runtime.authStore
            authStore.files = files
            authStore.keychain = FakeKeychain(auth("other", email: "other@example.com"))
            XCTAssertEqual(authStore.loadAuthCandidates().first?.auth.tokens?.accountID, isMallie ? "mallie" : "qq")
            XCTAssertNil(authStore.loadKeychainAuth())
            XCTAssertEqual(store.resolvedDisplayName(cardID: id), isMallie ? "Codex — mallie@example.com" : "Codex — qq@example.com")
            XCTAssertEqual(registry.descriptor(id: "\(id).weekly")?.providerID, id)
        }

        // A later launch with the original default restores home roles, not account identities.
        let restored = assemble(home: nil)
        XCTAssertEqual(restored.identityKeysByCard, changed.identityKeysByCard)
        XCTAssertEqual(restored.defaultCodexCard?.id, "codex")
        XCTAssertEqual(restored.codexCards.map(\.id), [qqID])
    }

    func testBareAccountFoundWithoutDefaultHomeDoesNotCreateDuplicateRuntime() {
        let card = CodexAccountCard(id: "codex", displayName: "Codex — old@example.com", homePath: "/Users/dev/.codex-cli")
        let runtimes = ProviderCatalog.make(codexCards: [card]).compactMap { $0 as? CodexProvider }
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes.first?.authStore.scope, .home(path: card.homePath))
    }
}
