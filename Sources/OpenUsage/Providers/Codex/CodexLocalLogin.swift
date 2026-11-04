import Foundation

/// A ChatGPT sign-in a Codex home holds. Read-only by design: the Codex CLI and app rotate these tokens
/// themselves, and a refresh from here could sign them out, so this never holds a refresh token.
struct CodexLocalLogin: Sendable, Equatable, Hashable {
    var home: String
    var accountID: String
    var email: String?
    var accessToken: String

    var label: String { email ?? "ChatGPT Account" }
}

struct CodexLocalSource: Sendable {
    var userHome = FileManager.default.homeDirectoryForCurrentUser

    /// Every `~/.codex*` directory and `~/.config/codex` with a ChatGPT sign-in, each directory once.
    func logins() -> [CodexLocalLogin] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: userHome.path)) ?? []
        let candidates = names.filter { $0.hasPrefix(".codex") }.sorted().map { userHome.appendingPathComponent($0) }
            + [userHome.appendingPathComponent(".config/codex")]
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            seen.insert(candidate.resolvingSymlinksInPath().path).inserted ? login(home: candidate.path) : nil
        }
    }

    /// Nil unless the home holds a ChatGPT sign-in naming its account: an API key can't read this usage.
    func login(home: String) -> CodexLocalLogin? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (auth["auth_mode"] as? String)?.lowercased() != "apikey",
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?.nilIfEmpty else { return nil }
        // Decoded only to name the account; the provider checks the token when it's used.
        let idClaims = (tokens["id_token"] as? String).flatMap(ProviderParse.jwtPayload)
        let accessClaims = ProviderParse.jwtPayload(accessToken)
        let authClaim = (idClaims ?? accessClaims)?["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = (tokens["account_id"] as? String)?.nilIfEmpty ?? (authClaim?["chatgpt_account_id"] as? String)?.nilIfEmpty else {
            return nil
        }
        return CodexLocalLogin(home: home, accountID: accountID, email: (idClaims?["email"] as? String)?.nilIfEmpty, accessToken: accessToken)
    }

    /// `~/.codex-cli` rather than the full path, for showing.
    func displayPath(_ home: String) -> String {
        home.hasPrefix(userHome.path + "/") ? "~" + home.dropFirst(userHome.path.count) : home
    }
}

extension AccountProviderRuntime {
    /// The marker's stand-in for this one read: tokens with no refresh token and no expiry, so no path
    /// through the shared OAuth code can renew them. Failures are `unreachable` so the backoff stays at
    /// one refresh interval and the next pass reads the home again.
    func codexLocalCredential(accountID: String) async throws -> AccountCredential {
        let source = codexLocalSource
        guard let home = account.localCLIHome else { throw ProviderError.invalidResponse }
        let shown = source.displayPath(home)
        guard let login = try await loadOffMainActor({ source.login(home: home) }) else {
            throw ProviderError.unreachable("No ChatGPT sign-in found in \(shown). Sign in to Codex there; this recovers on the next refresh.")
        }
        guard login.accountID == accountID else {
            throw ProviderError.unreachable("\(shown) is now signed in to another ChatGPT account. Remove this account and add it again.")
        }
        if let expiry = ProviderParse.jwtExpiry(login.accessToken), expiry <= now() {
            throw codexLocalExpired
        }
        return .oauth(OAuthTokens(accessToken: login.accessToken, extras: [
            "chatgpt_account_id": accountID,
            OAuthTokens.identityKey: "codex:\(accountID)"
        ]))
    }

    var codexLocalExpired: ProviderError {
        let shown = account.localCLIHome.map(codexLocalSource.displayPath) ?? "Codex"
        return .unreachable("The ChatGPT sign-in in \(shown) has expired. Open Codex and this recovers on the next refresh.")
    }
}
