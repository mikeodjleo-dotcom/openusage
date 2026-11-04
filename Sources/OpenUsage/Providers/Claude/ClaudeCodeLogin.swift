import Foundation

/// What Claude Code's sign-in looks like right now. Read-only by design: Claude Code rotates this token
/// itself, and a refresh from here could sign it out, so this never holds a refresh token and nothing
/// from here is written anywhere.
struct ClaudeCodeReading: Sendable, Equatable {
    var accessToken: String?
    var expiresAt: Date?
    /// The Keychain was asked and refused: not allowed, locked, or a prompt nobody answered.
    var keychainFailed = false
}

/// Claude Code's sign-in on this Mac, the Keychain item first since that's where it keeps the current
/// session, then `~/.claude/.credentials.json`.
struct ClaudeCodeSource: Sendable {
    /// The Keychain item's text, nil when there's no item; throws when the Keychain refuses.
    var readKeychain: @Sendable (_ timeout: TimeInterval) throws -> String? = SecurityCommand.readClaudeCodeItem
    var home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    func read(keychainTimeout: TimeInterval?, now: Date) -> ClaudeCodeReading {
        var reading = ClaudeCodeReading()
        var candidates: [(token: String, expiresAt: Date?)] = []
        if let keychainTimeout {
            do {
                if let text = try readKeychain(keychainTimeout), let parsed = Self.parse(text) { candidates.append(parsed) }
            } catch {
                reading.keychainFailed = true
            }
        }
        let file = home.appendingPathComponent(".credentials.json")
        if let text = try? String(contentsOf: file, encoding: .utf8), let parsed = Self.parse(text) { candidates.append(parsed) }
        let chosen = candidates.first { $0.expiresAt.map { $0 > now } ?? true } ?? candidates.first
        reading.accessToken = chosen?.token
        reading.expiresAt = chosen?.expiresAt
        return reading
    }

    /// `expiresAt` is epoch milliseconds. Older Claude Code versions store the Keychain item hex-encoded.
    private static func parse(_ text: String) -> (token: String, expiresAt: Date?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = trimmed.hasPrefix("{") ? Data(trimmed.utf8) : hexDecoded(trimmed)
        guard let data, let oauth = ProviderParse.jsonObject(data)?["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.nilIfEmpty else { return nil }
        return (token, ProviderParse.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            guard let byte = UInt8(rest.prefix(2), radix: 16) else { return nil }
            bytes.append(byte)
            rest = rest.dropFirst(2)
        }
        return Data(bytes)
    }
}

/// `/usr/bin/security`, the tool Claude Code itself stores this item with.
enum SecurityCommand {
    private static let notFoundExitCode: Int32 = 44

    static func readClaudeCodeItem(timeout: TimeInterval) throws -> String? {
        let service = "Claude Code-credentials"
        return try read(["find-generic-password", "-a", NSUserName(), "-s", service, "-w"], timeout: timeout)
            ?? read(["find-generic-password", "-s", service, "-w"], timeout: timeout)
    }

    /// The timeout ends the command and with it any prompt nobody answers. The output is never logged.
    static func read(_ arguments: [String], timeout: TimeInterval) throws -> String? {
        nonisolated(unsafe) let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationStatus == notFoundExitCode { return nil }
        guard process.terminationStatus == 0 else { throw ProviderError.unavailable(ClaudeCodeMessage.keychain) }
        return String(data: data, encoding: .utf8)?.nilIfEmpty
    }
}

enum ClaudeCodeMessage {
    static let keychain = "OpenUsage couldn’t read Claude Code’s login from the Keychain. Unlock it and choose Always Allow when asked; OpenUsage asks again within the hour."
    static let missing = "No Claude Code login found on this Mac. Run claude and sign in, then try again."
    static let expired = "Claude Code’s login has expired. Open Claude Code and this recovers on the next refresh."
}

/// Checks there's a login to read and stores only the marker. The user is here to answer a Keychain
/// prompt, unlike on a refresh, so this one waits for them.
struct ClaudeCodeLogin: ProviderLogin {
    var source = ClaudeCodeSource()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let reading = source.read(keychainTimeout: 60, now: Date())
        guard reading.accessToken != nil else {
            throw ProviderError.unavailable(reading.keychainFailed ? ClaudeCodeMessage.keychain : ClaudeCodeMessage.missing)
        }
        return ("Claude Code", .localCLI)
    }
}

extension AccountProviderRuntime {
    static let claudeKeychainRetryInterval: TimeInterval = 60 * 60
    private static let claudeKeychainRefreshTimeout: TimeInterval = 5

    /// The marker's stand-in for this one read: tokens with no refresh token and no expiry, so no
    /// path through the shared OAuth code can renew them, and with an identity, so none writes them back.
    /// A Keychain refusal isn't asked again for an hour, so a prompt can't keep coming back. Failures
    /// are `unreachable` so the backoff stays at one refresh interval and the next pass reads again.
    func claudeCodeCredential() async throws -> AccountCredential {
        let reading = await readClaudeCode()
        guard let accessToken = reading.accessToken else {
            let refused = reading.keychainFailed || now() < claudeKeychainNotBefore
            throw ProviderError.unreachable(refused ? ClaudeCodeMessage.keychain : ClaudeCodeMessage.missing)
        }
        if let expiresAt = reading.expiresAt, expiresAt <= now() {
            throw ProviderError.unreachable(ClaudeCodeMessage.expired)
        }
        return .oauth(OAuthTokens(accessToken: accessToken, extras: [OAuthTokens.identityKey: AccountCredential.localCLI.identity!]))
    }

    /// One read at a time, so a usage read and the hourly reads can't each raise a prompt.
    private func readClaudeCode() async -> ClaudeCodeReading {
        if let running = claudeCodeRead { return await running.value }
        let now = now()
        let timeout = now < claudeKeychainNotBefore ? nil : Self.claudeKeychainRefreshTimeout
        let task = Task.detached(priority: .utility) { [claudeCodeSource] in
            claudeCodeSource.read(keychainTimeout: timeout, now: now)
        }
        claudeCodeRead = task
        defer { claudeCodeRead = nil }
        let reading = await task.value
        if reading.keychainFailed {
            AppLog.warn(LogTag.auth("claude"), "\(account.cardID) Keychain refused Claude Code's login; not asking again for an hour")
            claudeKeychainNotBefore = now.addingTimeInterval(Self.claudeKeychainRetryInterval)
        }
        return reading
    }
}
