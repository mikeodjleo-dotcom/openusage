import Foundation

/// A sign-in the Antigravity app or `agy` keeps on this Mac.
struct AntigravityLocalToken: Sendable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
    var email: String?
}

struct AntigravityLocalReading: Sendable, Equatable {
    var token: AntigravityLocalToken?
    /// The Keychain was asked and refused: not allowed, locked, or a prompt nobody answered.
    var keychainFailed = false
}

/// `agy` keeps its sign-in in the Keychain item `gemini` / `antigravity`, and in a token file when it
/// logs in without one, as over SSH, so the two can differ.
struct AntigravityLocalSource: Sendable {
    var readKeychain: @Sendable (_ timeout: TimeInterval) throws -> String? = { timeout in
        try SecurityCommand.read(["find-generic-password", "-a", "antigravity", "-s", "gemini", "-w"], timeout: timeout)
    }
    var userHome = FileManager.default.homeDirectoryForCurrentUser

    /// The Keychain item wins, unless the file's token expires later. Access tokens all live about an
    /// hour, so the later expiry is the later sign-in or renewal; neither store records when it was written.
    func read(keychainTimeout: TimeInterval?) -> AntigravityLocalReading {
        var reading = AntigravityLocalReading()
        var keychain: AntigravityLocalToken?
        if let keychainTimeout {
            do {
                keychain = try readKeychain(keychainTimeout).flatMap(Self.parse)
            } catch {
                reading.keychainFailed = true
            }
        }
        let path = userHome.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let file = (try? String(contentsOf: path, encoding: .utf8)).flatMap(Self.parse)
        reading.token = switch (keychain?.expiry, file?.expiry) {
        case (let held?, let written?): written > held ? file : keychain
        case (nil, _?): keychain?.accessToken == nil ? file : keychain
        default: keychain ?? file
        }
        return reading
    }

    /// JSON, bare or wrapped as `go-keyring-base64:<base64>`.
    static func parse(_ raw: String) -> AntigravityLocalToken? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapper = "go-keyring-base64:"
        if text.hasPrefix(wrapper) {
            guard let data = Data(base64Encoded: String(text.dropFirst(wrapper.count))),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded
        }
        guard let root = ProviderParse.jsonObject(Data(text.utf8)) else { return nil }
        let token = root["token"] as? [String: Any] ?? root
        let parsed = AntigravityLocalToken(
            accessToken: (token["access_token"] as? String)?.nilIfEmpty,
            refreshToken: (token["refresh_token"] as? String)?.nilIfEmpty,
            expiry: (token["expiry"] as? String).flatMap(OpenUsageISO8601.date(from:)),
            email: (root["id_token_email"] as? String)?.nilIfEmpty
        )
        return parsed.accessToken == nil && parsed.refreshToken == nil ? nil : parsed
    }
}

enum AntigravityLocalMessage {
    static let keychain = "OpenUsage couldn’t read Antigravity’s login from the Keychain. Unlock it and choose Always Allow when asked; OpenUsage asks again within the hour."
    static let missing = "No Antigravity login found on this Mac. Sign in to Antigravity, then try again."
    static let expired = "Antigravity’s login has expired. Sign in to Antigravity again; this recovers on the next refresh."
    static let rotated = "Google returned a new refresh token, which OpenUsage won’t store. Sign in with the browser instead."
}

/// Checks there's a login to read and stores only the marker. The user is here to answer a Keychain
/// prompt, unlike on a refresh, so this one waits for them.
struct AntigravityLocalLogin: ProviderLogin {
    var source = AntigravityLocalSource()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let reading = source.read(keychainTimeout: 60)
        guard let token = reading.token else {
            throw ProviderError.unavailable(reading.keychainFailed ? AntigravityLocalMessage.keychain : AntigravityLocalMessage.missing)
        }
        return (token.email ?? ProviderKind.antigravity.displayName, .localCLI)
    }
}

extension AccountProviderRuntime {
    static let antigravityKeychainRetryInterval: TimeInterval = 60 * 60
    private static let antigravityKeychainRefreshTimeout: TimeInterval = 5
    private static let antigravityExpiryMargin: TimeInterval = 60

    /// The marker's stand-in for this one read. `agy` isn't always running to renew its hour-long access
    /// token, and Google doesn't rotate the refresh token, so an expired one is renewed here in memory
    /// only: nothing goes back to the Keychain, the file, or this app's own Keychain item. The tokens
    /// passed on carry no refresh token, so the shared OAuth code can't renew or save them.
    func antigravityLocalCredential() async throws -> AccountCredential {
        let now = now()
        let timeout = now < antigravityKeychainNotBefore ? nil : Self.antigravityKeychainRefreshTimeout
        let source = antigravityLocalSource
        let reading = await Task.detached(priority: .utility) { source.read(keychainTimeout: timeout) }.value
        if reading.keychainFailed {
            AppLog.warn(LogTag.auth("antigravity"), "\(account.cardID) Keychain refused Antigravity's login; not asking again for an hour")
            antigravityKeychainNotBefore = now.addingTimeInterval(Self.antigravityKeychainRetryInterval)
        }
        guard let token = reading.token else {
            let refused = reading.keychainFailed || now < antigravityKeychainNotBefore
            throw ProviderError.unreachable(refused ? AntigravityLocalMessage.keychain : AntigravityLocalMessage.missing)
        }
        antigravityLocalRefreshToken = token.refreshToken
        if let accessToken = token.accessToken, token.expiry.map({ $0.timeIntervalSince(now) > Self.antigravityExpiryMargin }) ?? true {
            return Self.antigravityTokens(accessToken)
        }
        return Self.antigravityTokens(try await renewedAntigravityToken())
    }

    /// The token renewed earlier if it's still good and from this refresh token, else a new one.
    private func renewedAntigravityToken() async throws -> String {
        if let memo = antigravityRenewal, memo.refreshToken == antigravityLocalRefreshToken,
           memo.expiresAt.timeIntervalSince(now()) > Self.antigravityExpiryMargin {
            return memo.accessToken
        }
        return try await renewAntigravityTokenInMemory()
    }

    /// Also the one renewal after Google refuses a token that looked live.
    func renewAntigravityTokenInMemory() async throws -> String {
        guard let refreshToken = antigravityLocalRefreshToken else {
            throw ProviderError.unreachable(AntigravityLocalMessage.expired)
        }
        do {
            let token = try await AntigravityLogin.renewal(refreshToken, http: http)
            if let returned = token.refreshToken, returned != refreshToken {
                AppLog.error(LogTag.auth("antigravity"), "\(account.cardID) Google returned a new refresh token; discarding it")
                throw ProviderError.unavailable(AntigravityLocalMessage.rotated)
            }
            antigravityRenewal = (refreshToken, token.accessToken, now().addingTimeInterval(token.expiresIn ?? 3600))
            return token.accessToken
        } catch ProviderError.signInExpired {
            throw ProviderError.unreachable(AntigravityLocalMessage.expired)
        }
    }

    private static func antigravityTokens(_ accessToken: String) -> AccountCredential {
        .oauth(OAuthTokens(accessToken: accessToken, extras: [OAuthTokens.identityKey: AccountCredential.localCLI.identity!]))
    }
}
