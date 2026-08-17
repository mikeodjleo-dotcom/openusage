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
        [
            .percent(id: "kimi.session", provider: provider, title: "Kimi 官方订阅 · 5-Hour Code", isSessionWindow: true)
                .exportingLimit("officialSession", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Kimi 官方订阅 · 7-Day Code")
                .exportingLimit("officialWeekly", unit: "percent"),
            .percent(id: "kimi.key.session", provider: provider, title: "Kimi 拼车key · 5-Hour Code", isSessionWindow: true)
                .exportingLimit("keySession", unit: "percent"),
            .percent(id: "kimi.key.weekly", provider: provider, title: "Kimi 拼车key · 7-Day Code")
                .exportingLimit("keyWeekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAccounts().contains { $0.auth != nil } }
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
            plan: primary.map { entry in
                [entry.plan, "主：\(entry.label)"].compactMap { $0 }.joined(separator: " · ")
            },
            lines: entries.flatMap(flattenedLines),
            refreshedAt: now()
        )
    }

    private func refreshAccount(_ credential: KimiAccountCredential) async -> ProviderAccountEntry {
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
        let prefix = entry.label + " · "
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
