import XCTest
@testable import OpenUsage

/// Covers the in-pass transient retry: a failure whose category is transport-level (network flap,
/// server 5xx, rate limiting) earns one immediate retry after a short delay, so a seconds-long
/// connectivity blip — the whole-batch failure bursts seen in the field — doesn't paint an error on
/// the card for a full refresh interval. Deterministic failures (auth, decoding, not logged in) are
/// NOT retried. The retry delay is injected as zero so the suite doesn't wait.
@MainActor
final class TransientRetryTests: XCTestCase {
    func testNetworkFailureThenSuccessRecoversWithinOnePass() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeRuntime(snapshots: [
            .error(provider: Self.provider, message: "Usage request failed. Check your connection.", category: .network),
            Self.okSnapshot,
        ])
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertNil(store.errorMessage(for: Self.provider.id))
    }

    func testPersistentNetworkFailureIsRetriedOnceThenFails() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeRuntime(snapshots: [
            .error(provider: Self.provider, message: "Usage request failed. Check your connection.", category: .network),
        ])
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()
        // One initial fetch + one retry — no more.
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertNotNil(store.errorMessage(for: Self.provider.id))
    }

    func testServerErrorAndRateLimitAreRetried() async {
        for category: ErrorCategory in [.http5xx, .rateLimited] {
            let clock = Date(timeIntervalSince1970: 1_800_000_000)
            let runtime = makeRuntime(snapshots: [
                .error(provider: Self.provider, message: "Usage request failed (HTTP 503). Try again later.", category: category),
                Self.okSnapshot,
            ])
            let store = makeStore(runtime: runtime, clock: { clock })

            await store.refreshAll()
            XCTAssertEqual(runtime.refreshCount, 2, "category \(category) should earn a retry")
            XCTAssertNil(store.errorMessage(for: Self.provider.id))
        }
    }

    func testDeterministicFailureIsNotRetried() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeRuntime(snapshots: [
            .error(provider: Self.provider, message: "Not logged in"),
        ])
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertNotNil(store.errorMessage(for: Self.provider.id))
    }

    // MARK: - Helpers

    private static let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))

    private static let descriptor = WidgetDescriptor(
        id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
        sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
    )

    private static let okSnapshot = ProviderSnapshot(
        providerID: provider.id, displayName: provider.displayName,
        lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
        refreshedAt: Date(timeIntervalSince1970: 0)
    )

    private func makeRuntime(snapshots: [ProviderSnapshot]) -> SequenceProviderRuntime {
        SequenceProviderRuntime(provider: Self.provider, descriptors: [Self.descriptor], snapshots: snapshots)
    }

    private func makeStore(
        runtime: some ProviderRuntime,
        clock: @escaping () -> Date
    ) -> WidgetDataStore {
        let suiteName = "OpenUsageTests.TransientRetry.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [Self.provider], descriptors: [Self.descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600, now: clock),
            defaults: suite,
            now: clock,
            transientRetryDelay: 0
        )
    }
}
