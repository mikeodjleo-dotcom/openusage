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
    var oauthCredential: KimiOAuthCredential?
    var deviceID: String?
}

struct KimiOAuthCredential: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var originalJSON: String
}

struct KimiRefreshedOAuthCredential: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var expiresIn: Int
    var scope: String
    var tokenType: String
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
/// Rotated OAuth credentials are written back to the CLI file immediately because Kimi rotates the
/// refresh token on every successful grant.
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
                auth: isLive ? KimiAuth(token: credential.accessToken, source: .cliOAuth(deviceID: deviceID)) : nil,
                oauthCredential: credential,
                deviceID: deviceID
            )
        } else {
            oauth = KimiAccountCredential(
                kind: .officialSubscription,
                isPrimary: config.activeProvider == config.managedProvider,
                availability: .missingCredential,
                auth: nil,
                oauthCredential: nil,
                deviceID: deviceID
            )
        }

        // 拼车 key 从 CLI config 拿掉后不再占一张「未找到凭据」卡（爸 08-29：现在不用了）。
        // 真写回 [providers.kimi-code-key] 的 api_key 时才重新出这一路。
        guard let staticAPIKey = config.staticAPIKey else { return [oauth] }
        let key = KimiAccountCredential(
            kind: .sharedAPIKey,
            isPrimary: config.activeProvider == config.staticProvider,
            availability: .available,
            auth: KimiAuth(token: staticAPIKey, source: .apiKey),
            oauthCredential: nil,
            deviceID: nil
        )
        return [oauth, key]
    }

    func saveRefreshedCredential(
        _ refreshed: KimiRefreshedOAuthCredential,
        replacing credential: KimiOAuthCredential
    ) throws {
        guard let data = credential.originalJSON.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw KimiUsageError.invalidResponse
        }
        object["access_token"] = refreshed.accessToken
        object["refresh_token"] = refreshed.refreshToken
        object["expires_at"] = Int(refreshed.expiresAt.timeIntervalSince1970)
        object["expires_in"] = refreshed.expiresIn
        object["scope"] = refreshed.scope
        object["token_type"] = refreshed.tokenType

        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: updated, encoding: .utf8) else {
            throw KimiUsageError.invalidResponse
        }
        try files.writeText(credentialPath(), text)
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
        var refreshToken: String?
        var expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
        }
    }

    private static func oauthCredential(from json: String) -> KimiOAuthCredential? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OAuthCredential.self, from: data),
              !decoded.accessToken.isEmpty else { return nil }
        return KimiOAuthCredential(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            expiresAt: Date(timeIntervalSince1970: decoded.expiresAt),
            originalJSON: json
        )
    }
}
