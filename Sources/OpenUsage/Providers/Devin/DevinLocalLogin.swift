import Foundation

/// Aix fork: the Devin CLI's own sign-in in `~/.local/share/devin/credentials.toml`, read only.
/// `devin auth login` writes it; OpenUsage never renews or rewrites it.
struct DevinLocalSource: Sendable {
    var path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devin/credentials.toml")

    struct Login: Equatable { let apiKey: String; let apiServerURL: String? }

    // ponytail: line scan of flat `key = "value"` pairs, not a TOML parser; the CLI writes only that shape.
    func read() -> Login? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].count >= 2, parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") else { continue }
            values[parts[0]] = String(parts[1].dropFirst().dropLast())
        }
        guard let key = values["windsurf_api_key"]?.nilIfEmpty else { return nil }
        let server = values["api_server_url"].flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" && $0.host() != nil ? $0.absoluteString : nil }
        return Login(apiKey: key, apiServerURL: server)
    }
}

enum DevinLocalMessage {
    static let missing = "No Devin CLI login found on this Mac. Run devin auth login in Terminal, then try again."
    static let expired = "Devin rejected the CLI’s login. Run devin auth login in Terminal; OpenUsage picks it up on its next refresh."
}

struct DevinLocalLogin: ProviderLogin {
    var source = DevinLocalSource()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        guard source.read() != nil else { throw ProviderError.unavailable(DevinLocalMessage.missing) }
        return (ProviderKind.devin.displayName, .localCLI)
    }
}

extension AccountProviderRuntime {
    /// Same stand-in as Grok's: no refresh token and an identity, so nothing renews or writes it back.
    func devinLocalCredential() throws -> AccountCredential {
        guard let login = DevinLocalSource().read() else { throw ProviderError.unreachable(DevinLocalMessage.missing) }
        var extras = [OAuthTokens.identityKey: AccountCredential.localCLI.identity!]
        if let server = login.apiServerURL { extras[DevinUsageClient.apiServerURLKey] = server }
        return .oauth(OAuthTokens(accessToken: login.apiKey, extras: extras))
    }
}
