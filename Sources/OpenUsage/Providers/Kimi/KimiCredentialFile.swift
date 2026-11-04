import Foundation

struct KimiCredential: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

/// The Kimi Code CLI's own sign-in, the one place OpenUsage reads another tool's credential: Kimi has no
/// login a third party can use, and its owner chose this. The CLI keeps using the same session, and
/// every refresh rotates the refresh token, so the file stays the only copy and OpenUsage follows the
/// CLI's rules for it: refresh under the CLI's lock, re-read inside the lock, and never replace a sign-in
/// other than the one the grant spent.
struct KimiCredentialFile: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    var lockTimeout: TimeInterval = 10

    private var url: URL { home.appendingPathComponent("credentials/kimi-code.json") }

    /// Nil for a missing or unreadable file and for the CLI's tombstone, whose access token is empty.
    func load() -> KimiCredential? {
        guard let data = try? Data(contentsOf: url), let object = ProviderParse.jsonObject(data),
              let accessToken = (object["access_token"] as? String)?.nilIfEmpty,
              let expiresAt = ProviderParse.number(object["expires_at"]) else { return nil }
        return KimiCredential(
            accessToken: accessToken,
            refreshToken: (object["refresh_token"] as? String)?.nilIfEmpty,
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }

    func deviceID() -> String? {
        (try? String(contentsOf: home.appendingPathComponent("device_id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Writes the grant over the fields it renews, keeping any others. Skips the write when the file no
    /// longer holds the token the grant spent, since it is then a newer sign-in or a logout, except for
    /// the tombstone the CLI leaves after losing a refresh race, which this grant repairs.
    func save(_ grant: KimiGrant) throws {
        guard var object = (try? Data(contentsOf: url)).flatMap(ProviderParse.jsonObject) else {
            return AppLog.warn(LogTag.auth("kimi"), "credential file went away during a refresh; leaving it")
        }
        let isTombstone = (object["access_token"] as? String)?.isEmpty == true
        guard isTombstone || object["refresh_token"] as? String == grant.spentRefreshToken else {
            return AppLog.warn(LogTag.auth("kimi"), "credential file changed during a refresh; leaving it")
        }
        object["access_token"] = grant.accessToken
        object["refresh_token"] = grant.refreshToken
        object["expires_at"] = Int(grant.expiresAt.timeIntervalSince1970)
        object["expires_in"] = grant.expiresIn
        if let scope = grant.scope { object["scope"] = scope }
        if let tokenType = grant.tokenType { object["token_type"] = tokenType }
        try writeAtomically(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
    }

    /// A private temporary file, flushed, then renamed: the file is whole and 0600 from the moment it exists.
    private func writeAtomically(_ data: Data) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".kimi-code.json.\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    /// Takes the lock the CLI takes around its own refresh, the directory `proper-lockfile` makes at
    /// `oauth/kimi-code.lock`. A CLI that lost a refresh race revokes its own sign-in, so this fails closed
    /// when the lock can't be had, as the CLI does. A lock untouched for 5 seconds is stale, by the CLI's
    /// setting, so the holder touches it every 2.
    func lockForRefresh() async throws -> KimiRefreshLock {
        let directory = home.appendingPathComponent("oauth")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("kimi-code.lock").path
        let deadline = Date().addingTimeInterval(lockTimeout)
        while mkdir(path, 0o777) != 0 {
            guard errno == EEXIST else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let touched = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let touched, Date().timeIntervalSince(touched) > 5 { rmdir(path) }
            guard Date() < deadline else {
                throw ProviderError.unavailable("Kimi Code is renewing its sign-in. OpenUsage will try again shortly.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let heartbeat = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { utimes(path, nil) }
            }
        }
        return KimiRefreshLock(path: path, heartbeat: heartbeat)
    }
}

struct KimiRefreshLock: Sendable {
    let path: String
    let heartbeat: Task<Void, Never>

    func release() {
        heartbeat.cancel()
        rmdir(path)
    }
}

/// Checks the CLI's sign-in is there, and asks for nothing: the runtime reads the file on every refresh.
struct KimiCLILogin: ProviderLogin {
    var file = KimiCredentialFile()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        guard file.load() != nil else {
            throw ProviderError.unavailable("No Kimi Code sign-in found. Run kimi login in Terminal, then try again.")
        }
        return (ProviderKind.kimi.displayName, .localCLI)
    }
}
