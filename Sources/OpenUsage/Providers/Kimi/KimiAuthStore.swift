import Foundation

struct KimiAuth: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case apiKey
        case cliOAuth(deviceID: String?)
    }

    var token: String
    var source: Source
}

enum KimiAccountKind: String, CaseIterable, Hashable, Sendable {
    case officialSubscription
    case sharedAPIKey

    var label: String {
        switch self {
        case .officialSubscription: "Kimi 官方订阅"
        case .sharedAPIKey: "Kimi 拼车key"
        }
    }
}

struct KimiAccountCredential: Sendable, Equatable {
    var kind: KimiAccountKind
    var isPrimary: Bool
    var availability: ProviderAccountAvailability
    var auth: KimiAuth?
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

/// Reuses the official Kimi Code CLI's local configuration. A still-live OAuth credential is preferred
/// because it identifies the same account as the CLI; a static Kimi API key is only a fallback.
/// OpenUsage never copies or persists either secret.
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
        let accounts = loadAccounts()
        return accounts.first(where: { $0.isPrimary })?.auth ?? accounts.compactMap(\.auth).first
    }

    func loadAccounts() -> [KimiAccountCredential] {
        let configText = (try? files.readText(configPath())) ?? ""
        let config = Self.configuration(from: configText)
        let deviceID = (try? files.readText(deviceIDPath()))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let oauth: KimiAccountCredential
        if let text = try? files.readText(credentialPath()),
           let credential = Self.oauthCredential(from: text) {
            let isLive = credential.expiresAt.timeIntervalSince(now()) > 60
            oauth = KimiAccountCredential(
                kind: .officialSubscription,
                isPrimary: config.activeProvider == config.managedProvider,
                availability: isLive ? .available : .expiredCredential,
                auth: isLive ? KimiAuth(token: credential.accessToken, source: .cliOAuth(deviceID: deviceID)) : nil
            )
        } else {
            oauth = KimiAccountCredential(
                kind: .officialSubscription,
                isPrimary: config.activeProvider == config.managedProvider,
                availability: .missingCredential,
                auth: nil
            )
        }

        let key = KimiAccountCredential(
            kind: .sharedAPIKey,
            isPrimary: config.activeProvider == config.staticProvider,
            availability: config.staticAPIKey == nil ? .missingCredential : .available,
            auth: config.staticAPIKey.map { KimiAuth(token: $0, source: .apiKey) }
        )
        return [oauth, key]
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
        configuration(from: toml).staticAPIKey
    }

    private struct Configuration {
        var activeProvider: String?
        var managedProvider: String?
        var staticProvider: String?
        var staticAPIKey: String?
    }

    private static func configuration(from toml: String) -> Configuration {
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

        let root = sections.first(where: { $0["__name"] == nil }) ?? [:]
        let defaultModel = root["default_model"]
        let modelSection = defaultModel.flatMap { model in
            sections.first { normalizedSectionName($0["__name"]) == "models.\(model)" }
        }
        let activeProvider = modelSection?["provider"]
        let managedProvider = sections.first { candidate in
            guard let name = normalizedSectionName(candidate["__name"]),
                  name.hasPrefix("providers."), name.hasSuffix(".oauth") else { return false }
            return true
        }.flatMap { candidate in
            normalizedSectionName(candidate["__name"])
                .map { String($0.dropFirst("providers.".count).dropLast(".oauth".count)) }
        }
        let staticSection = sections.first { candidate in
            guard candidate["__name"]?.hasPrefix("providers.") == true,
                  candidate["type"] == "kimi",
                  candidate["oauth"] == nil else { return false }
            let name = normalizedSectionName(candidate["__name"])
                .map { String($0.dropFirst("providers.".count)) }
            return candidate["api_key"]?.nilIfEmpty != nil && name != managedProvider
        }
        let staticProvider = staticSection.flatMap { normalizedSectionName($0["__name"]) }
            .map { String($0.dropFirst("providers.".count)) }
        return Configuration(
            activeProvider: activeProvider,
            managedProvider: managedProvider,
            staticProvider: staticProvider,
            staticAPIKey: staticSection?["api_key"]?.nilIfEmpty
        )
    }

    private static func normalizedSectionName(_ name: String?) -> String? {
        name?.replacingOccurrences(of: "\"", with: "")
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
