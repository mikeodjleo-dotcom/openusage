import Foundation

extension AccountProviderRuntime {
    /// The stored credential is only a marker: the CLI's file is read on every refresh, so a `kimi login`
    /// or a refresh the CLI made is picked up at once. A token with a minute left is still the CLI's to
    /// renew, which it does well before that when it is running.
    func refreshKimi() async throws -> ProviderUsage {
        let client = KimiUsageClient(http: http)
        let deviceID = try await loadOffMainActor { [kimiCredentialFile] in kimiCredentialFile.deviceID() }
        let credential = try await currentKimiCredential()
        if isLive(credential) {
            let response = try await client.fetchUsage(accessToken: credential.accessToken, deviceID: deviceID)
            if !ProviderError.isAuthFailure(response) { return try KimiUsageMapper.map(response) }
            AppLog.debug(.auth, "\(account.cardID) usage read unauthorized; renewing the sign-in once")
        }
        let accessToken = try await renewedKimiToken(replacing: credential, client: client)
        let response = try await client.fetchUsage(accessToken: accessToken, deviceID: deviceID)
        if ProviderError.isAuthFailure(response) {
            throw ProviderError.unavailable("Kimi renewed the sign-in but refused the usage read.")
        }
        return try KimiUsageMapper.map(response)
    }

    private func isLive(_ credential: KimiCredential) -> Bool {
        credential.expiresAt.timeIntervalSince(now()) > 60
    }

    /// Runs in its own task, like `renewedTokens`: a refresh deadline must not abandon a grant the server
    /// may already have made, since that would lose the rotated token.
    private func renewedKimiToken(replacing stale: KimiCredential, client: KimiUsageClient) async throws -> String {
        try await Task {
            let lock = try await kimiCredentialFile.lockForRefresh()
            defer { lock.release() }
            let current = try await currentKimiCredential()
            if current.accessToken != stale.accessToken, isLive(current) { return current.accessToken }
            guard let refreshToken = current.refreshToken else { throw ProviderError.signInExpired(.kimi) }
            do {
                let grant = try await client.refresh(refreshToken, now: now())
                kimiUnsavedGrant = grant
                try? await saveKimiGrant(grant)
                return grant.accessToken
            } catch ProviderError.signInExpired {
                // Something that doesn't take the lock, such as a 0.7 build, rotated the token first.
                if let latest = try await loadOffMainActor({ [kimiCredentialFile] in kimiCredentialFile.load() }),
                   latest.refreshToken != refreshToken, isLive(latest) {
                    return latest.accessToken
                }
                throw ProviderError.signInExpired(.kimi)
            }
        }.value
    }

    /// A grant the disk refused stands in for the file until it is saved: the token in the file is spent.
    private func currentKimiCredential() async throws -> KimiCredential {
        if let grant = kimiUnsavedGrant {
            do {
                try await saveKimiGrant(grant)
            } catch {
                return KimiCredential(accessToken: grant.accessToken, refreshToken: grant.refreshToken, expiresAt: grant.expiresAt)
            }
        }
        guard let credential = try await loadOffMainActor({ [kimiCredentialFile] in kimiCredentialFile.load() }) else {
            throw ProviderError.signInExpired(.kimi)
        }
        return credential
    }

    private func saveKimiGrant(_ grant: KimiGrant) async throws {
        do {
            try await loadOffMainActor { [kimiCredentialFile] in try kimiCredentialFile.save(grant) }
            kimiUnsavedGrant = nil
        } catch {
            AppLog.error(LogTag.auth("kimi"), "couldn't save the renewed sign-in; keeping it and retrying: \(error.localizedDescription)")
            throw error
        }
    }
}
