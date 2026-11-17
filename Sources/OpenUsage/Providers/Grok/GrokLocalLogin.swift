import Foundation

/// Aix fork: the Grok CLI's own sign-in in `~/.grok/auth.json`, read only. The CLI renews it while it
/// runs; OpenUsage never does, since a renewal here could rotate the refresh token out from under the CLI.
struct GrokLocalSource: Sendable {
    var path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")

    struct Login: Equatable { let accessToken: String; let email: String?; let expiresAt: Date? }

    func read() -> Login? {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // One entry per issuer::client; the CLI writes only its own.
        for case let entry as [String: Any] in root.values {
            guard let key = (entry["key"] as? String)?.nilIfEmpty else { continue }
            let expires = (entry["expires_at"] as? String).flatMap(Self.parseDate)
            return Login(accessToken: key, email: entry["email"] as? String, expiresAt: expires)
        }
        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

enum GrokLocalMessage {
    static let missing = "No Grok CLI login found on this Mac. Run grok login in Terminal, then try again."
    static let expired = "The Grok CLI’s login has expired. Run any grok command (grok models) and this recovers on the next refresh."
}

struct GrokLocalLogin: ProviderLogin {
    var source = GrokLocalSource()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        guard let login = source.read() else { throw ProviderError.unavailable(GrokLocalMessage.missing) }
        return (login.email ?? ProviderKind.grok.displayName, .localCLI)
    }
}

extension AccountProviderRuntime {
    /// Same stand-in as Claude Code's: no refresh token, so nothing renews it, and an identity, so nothing
    /// writes it back. Failures are `unreachable` so the next pass simply reads the file again.
    func grokLocalCredential() throws -> AccountCredential {
        guard let login = GrokLocalSource().read() else { throw ProviderError.unreachable(GrokLocalMessage.missing) }
        if let expiresAt = login.expiresAt, expiresAt <= now() { throw ProviderError.unreachable(GrokLocalMessage.expired) }
        return .oauth(OAuthTokens(accessToken: login.accessToken, extras: [OAuthTokens.identityKey: AccountCredential.localCLI.identity!]))
    }
}
