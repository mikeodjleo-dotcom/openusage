import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi",
        icon: .providerMark("kimi"),
        links: [
            ProviderLink(label: "Usage", url: "https://www.kimi.com/code/console")
        ]
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        var items: [WidgetDescriptor] = [
            .percent(id: "kimi.session", provider: provider, title: "Allegro · 5-Hour Code", isSessionWindow: true)
                .exportingLimit("officialSession", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Allegro · 7-Day Code")
                .exportingLimit("officialWeekly", unit: "percent")
        ]
        if authStore.loadAccounts().contains(where: { $0.kind == .sharedAPIKey }) {
            items.append(
                .percent(id: "kimi.key.session", provider: provider, title: "Kimi 拼车key · 5-Hour Code", isSessionWindow: true)
                    .exportingLimit("keySession", unit: "percent")
            )
            items.append(
                .percent(id: "kimi.key.weekly", provider: provider, title: "Kimi 拼车key · 7-Day Code")
                    .exportingLimit("keyWeekly", unit: "percent")
            )
        }
        return items
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            authStore.loadAccounts().contains { $0.auth != nil || $0.oauthCredential?.refreshToken != nil }
        }
    }

    func refresh() async -> ProviderSnapshot {
        let credentials = await loadOffMainActor { [authStore] in authStore.loadAccounts() }
        var entries: [ProviderAccountEntry] = []
        for credential in credentials.sorted(by: { $0.isPrimary && !$1.isPrimary }) {
            entries.append(await refreshAccount(credential))
        }
        let primary = entries.first(where: \.isPrimary) ?? entries.first
        return ProviderSnapshot.make(
            provider: provider,
            account: primary?.account,
            accountEntries: entries,
            // 只要套餐名（Allegro）。「主：官方订阅」是双号时代用来标主号的，拼车下线后会抢掉套餐位。
            plan: primary?.plan,
            lines: entries.flatMap(flattenedLines),
            refreshedAt: now()
        )
    }

    private func refreshAccount(_ credential: KimiAccountCredential) async -> ProviderAccountEntry {
        if credential.kind == .officialSubscription,
           credential.auth == nil,
           let oauthCredential = credential.oauthCredential {
            return await refreshOfficialAccount(credential, oauthCredential: oauthCredential)
        }
        guard let auth = credential.auth else {
            let message = credential.availability == .expiredCredential ? "凭据已过期，请重新登录" : "未找到凭据"
            return ProviderAccountEntry(
                label: credential.kind.label, isPrimary: credential.isPrimary,
                availability: credential.availability, message: message,
                account: nil, plan: nil, resources: [:]
            )
        }
        do {
            let response = try await usageClient.fetchUsage(auth: auth)
            if response.statusCode == 401 || response.statusCode == 403 {
                if credential.kind == .officialSubscription,
                   let oauthCredential = credential.oauthCredential {
                    return await refreshOfficialAccount(credential, oauthCredential: oauthCredential)
                }
                return failedEntry(credential, availability: .expiredCredential, message: KimiAuthError.invalidCredential.localizedDescription)
            }
            guard (200..<300).contains(response.statusCode) else {
                return failedEntry(credential, availability: .requestFailed, message: KimiUsageError.requestFailed(response.statusCode).localizedDescription)
            }
            let mapped = try KimiUsageMapper.map(response.body)
            return ProviderAccountEntry(
                label: credential.kind.label, isPrimary: credential.isPrimary, availability: .available,
                message: nil, account: mapped.account, plan: mapped.plan,
                resources: Dictionary(uniqueKeysWithValues: mapped.lines.compactMap { line in
                    switch line.label {
                    case "5-Hour Code": ("session", line)
                    case "7-Day Code": ("weekly", line)
                    case "Monthly Total": ("monthly", line)
                    default: nil
                    }
                })
            )
        } catch let error as KimiUsageError {
            return failedEntry(credential, availability: .requestFailed, message: error.localizedDescription)
        } catch {
            return failedEntry(credential, availability: .requestFailed, message: KimiUsageError.connectionFailed.localizedDescription)
        }
    }

    private func refreshOfficialAccount(
        _ credential: KimiAccountCredential,
        oauthCredential: KimiOAuthCredential
    ) async -> ProviderAccountEntry {
        guard let refreshToken = oauthCredential.refreshToken else {
            return failedEntry(credential, availability: .expiredCredential, message: "凭据已过期，请重新登录")
        }
        do {
            let refreshResponse = try await usageClient.refreshToken(refreshToken)
            if refreshResponse.statusCode == 401 || refreshResponse.statusCode == 403 ||
                Self.isInvalidGrant(refreshResponse) {
                return failedEntry(credential, availability: .expiredCredential, message: "凭据已过期，请重新登录")
            }
            guard (200..<300).contains(refreshResponse.statusCode) else {
                return failedEntry(
                    credential,
                    availability: .requestFailed,
                    message: KimiUsageError.requestFailed(refreshResponse.statusCode).localizedDescription
                )
            }

            let refreshed = try KimiUsageClient.refreshedCredential(from: refreshResponse.body, now: now())
            try authStore.saveRefreshedCredential(refreshed, replacing: oauthCredential)
            let response = try await usageClient.fetchUsage(auth: KimiAuth(
                token: refreshed.accessToken,
                source: .cliOAuth(deviceID: credential.deviceID)
            ))
            guard response.statusCode != 401 && response.statusCode != 403 else {
                return failedEntry(
                    credential,
                    availability: .requestFailed,
                    message: "Kimi Code credential refresh succeeded, but usage access was rejected."
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                return failedEntry(
                    credential,
                    availability: .requestFailed,
                    message: KimiUsageError.requestFailed(response.statusCode).localizedDescription
                )
            }
            let mapped = try KimiUsageMapper.map(response.body)
            return availableEntry(credential, mapped: mapped)
        } catch let error as KimiUsageError {
            return failedEntry(credential, availability: .requestFailed, message: error.localizedDescription)
        } catch {
            AppLog.error(LogTag.auth("kimi"), "failed to refresh or persist Kimi OAuth credentials")
            return failedEntry(credential, availability: .requestFailed, message: KimiUsageError.connectionFailed.localizedDescription)
        }
    }

    private static func isInvalidGrant(_ response: HTTPResponse) -> Bool {
        guard response.statusCode == 400,
              let body = ProviderParse.jsonObject(response.body),
              let code = body["error"] as? String else { return false }
        return code == "invalid_grant"
    }

    private func availableEntry(_ credential: KimiAccountCredential, mapped: KimiMappedUsage) -> ProviderAccountEntry {
        ProviderAccountEntry(
            label: credential.kind.label, isPrimary: credential.isPrimary, availability: .available,
            message: nil, account: mapped.account, plan: mapped.plan,
            resources: Dictionary(uniqueKeysWithValues: mapped.lines.compactMap { line in
                switch line.label {
                case "5-Hour Code": ("session", line)
                case "7-Day Code": ("weekly", line)
                case "Monthly Total": ("monthly", line)
                default: nil
                }
            })
        )
    }

    private func failedEntry(
        _ credential: KimiAccountCredential,
        availability: ProviderAccountAvailability,
        message: String
    ) -> ProviderAccountEntry {
        ProviderAccountEntry(
            label: credential.kind.label, isPrimary: credential.isPrimary, availability: availability,
            message: message, account: nil, plan: nil, resources: [:]
        )
    }

    private func flattenedLines(_ entry: ProviderAccountEntry) -> [MetricLine] {
        let prefix = (entry.plan ?? (entry.isPrimary ? "Allegro" : entry.label)) + " · "
        if entry.availability != .available {
            let message = entry.message ?? "不可用"
            return ["5-Hour Code", "7-Day Code"].map {
                .badge(label: prefix + $0, text: message, colorHex: "#EF4444")
            }
        }
        return ["session", "weekly"].compactMap { key in
            entry.resources[key].map { relabeled($0, prefix: prefix) }
        }
    }

    private func relabeled(_ line: MetricLine, prefix: String) -> MetricLine {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, let colorHex):
            return .progress(label: prefix + line.label, used: used, limit: limit, format: format,
                             resetsAt: resetsAt, periodDurationMs: periodDurationMs, colorHex: colorHex)
        default:
            return line
        }
    }
}
