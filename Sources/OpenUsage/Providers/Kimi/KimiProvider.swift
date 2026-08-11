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
            .percent(id: "kimi.session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAuth() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAuth() }) else {
            return ProviderSnapshot.error(provider: provider, error: KimiAuthError.notLoggedIn)
        }
        do {
            let response = try await usageClient.fetchUsage(auth: auth)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: KimiAuthError.invalidCredential)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: KimiUsageError.requestFailed(response.statusCode))
            }
            let mapped = try KimiUsageMapper.map(response.body)
            return ProviderSnapshot.make(
                provider: provider,
                account: mapped.account,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch let error as KimiUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: KimiUsageError.connectionFailed)
        }
    }
}
