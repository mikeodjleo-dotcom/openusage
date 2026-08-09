import Foundation

struct KimiAuth: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case apiKey
        case cliOAuth(deviceID: String?)
    }

    var token: String
    var source: Source
}

enum KimiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Kimi Code is not configured. Run `kimi login` or add a Kimi Code API key."
        case .invalidCredential:
            return "Kimi Code credential is invalid or expired. Sign in again with `kimi login`."
        }
    }
}

/// Reuses the official Kimi Code CLI's local configuration. A static Kimi Code API key is preferred;
/// if none exists, a still-live OAuth credential from the CLI is accepted. OpenUsage never copies or
/// persists either secret.
struct KimiAuthStore: Sendable {
    static let defaultHome = "~/.kimi-code"
    static let homeEnvironmentName = "KIMI_CODE_HOME"

    var files: TextFileAccessing
    var environment: EnvironmentReading
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.environment = environment
        self.now = now
    }

    func loadAuth() -> KimiAuth? {
        if let text = try? files.readText(configPath()),
           let key = Self.staticAPIKey(from: text) {
            return KimiAuth(token: key, source: .apiKey)
        }

        guard let text = try? files.readText(credentialPath()),
              let credential = Self.oauthCredential(from: text),
              credential.expiresAt.timeIntervalSince(now()) > 60 else {
            return nil
        }
        let deviceID = (try? files.readText(deviceIDPath()))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return KimiAuth(token: credential.accessToken, source: .cliOAuth(deviceID: deviceID))
    }

    func configPath() -> String { homePath() + "/config.toml" }
    func credentialPath() -> String { homePath() + "/credentials/kimi-code.json" }
    func deviceIDPath() -> String { homePath() + "/device_id" }

    private func homePath() -> String {
        environment.value(for: Self.homeEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.defaultHome
    }

    /// Reads API keys only from `[providers.*]` sections whose declared type is `kimi`. OAuth-managed
    /// sections are skipped so their placeholder/fallback `api_key` cannot outrank the credential file.
    static func staticAPIKey(from toml: String) -> String? {
        var section: [String: String] = [:]
        var sections: [[String: String]] = []

        func flush() {
            if !section.isEmpty { sections.append(section) }
            section = [:]
        }

        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                section["__name"] = String(line.dropFirst().dropLast())
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let decoded = quotedString(value) { section[key] = decoded }
        }
        flush()

        return sections.first { candidate in
            guard candidate["__name"]?.hasPrefix("providers.") == true,
                  candidate["type"] == "kimi",
                  candidate["oauth"] == nil else { return false }
            return candidate["api_key"]?.nilIfEmpty != nil
        }?["api_key"]
    }

    private static func quotedString(_ text: String) -> String? {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private struct OAuthCredential: Decodable {
        var accessToken: String
        var expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
        }
    }

    private static func oauthCredential(from json: String) -> (accessToken: String, expiresAt: Date)? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OAuthCredential.self, from: data),
              !decoded.accessToken.isEmpty else { return nil }
        return (decoded.accessToken, Date(timeIntervalSince1970: decoded.expiresAt))
    }
}
