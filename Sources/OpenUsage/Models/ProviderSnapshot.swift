import Foundation

/// Provider-owned account identity safe to expose through the local read-only API. `label` is the
/// human account name when the provider supplies one (normally an email); `id` is the provider's
/// stable opaque account id. Neither field ever contains an access token or credential fingerprint.
struct ProviderAccountIdentity: Hashable, Sendable, Codable {
    var label: String?
    var id: String?

    init?(label: String?, id: String?) {
        let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let cleanID = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard cleanLabel != nil || cleanID != nil else { return nil }
        self.label = cleanLabel
        self.id = cleanID
    }

    static func openIDUserInfo(_ data: Data) -> ProviderAccountIdentity? {
        guard let object = ProviderParse.jsonObject(data) else { return nil }
        return from(
            object,
            labelKeys: ["email", "preferred_username", "name"],
            idKeys: ["sub", "user_id", "id"]
        )
    }

    static func from(
        _ object: [String: Any],
        labelKeys: [String],
        idKeys: [String]
    ) -> ProviderAccountIdentity? {
        ProviderAccountIdentity(
            label: firstString(in: object, keys: labelKeys),
            id: firstString(in: object, keys: idKeys)
        )
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }
}

enum ProviderAccountAvailability: String, Hashable, Sendable, Codable {
    case available
    case missingCredential
    case expiredCredential
    case requestFailed
}

/// One independently queried account inside a provider card. Most providers expose one account and
/// leave this nil; providers such as Kimi can keep multiple local credential channels visible without
/// pretending their limits belong to the card's primary account.
struct ProviderAccountEntry: Hashable, Sendable, Codable {
    var label: String
    var isPrimary: Bool
    var availability: ProviderAccountAvailability
    var message: String?
    var account: ProviderAccountIdentity?
    var plan: String?
    var resources: [String: MetricLine]
}

/// Latest normalized output for one provider refresh.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    /// The card title at refresh time — always the baked DERIVED name (renames never reach the
    /// cache or iCloud). The CLI/API boundary re-resolves it against the account registry at
    /// respond time (`LocalUsageAPI.State.resolvingDisplayNames`), so human-facing output carries
    /// renames without persisting them.
    var displayName: String
    /// Account metadata returned by the provider. Claude/Codex snapshots are enriched at the local
    /// API boundary from `ProviderAccountsStore`, keeping their cached snapshots rename-free.
    var account: ProviderAccountIdentity?
    var accountEntries: [ProviderAccountEntry]?
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// Raw normalized daily history used to build spend rows. This always belongs to this Mac; peer
    /// history is combined only in the in-memory rendered view and is never written into the cache.
    var usageHistory: ProviderUsageHistory?
    /// A soft, non-blocking notice carried on a *successful* snapshot — e.g. Claude's "Re-login for live
    /// usage" when the saved login lacks the `user:profile` scope. Distinct from `errorCategory` (which is
    /// only on error snapshots): the refresh succeeded and partial data (spend tiles) still loads, so this
    /// surfaces as the provider header's amber triangle rather than blanking the provider. Cached with the
    /// snapshot; cleared on the next refresh when the condition resolves.
    var warning: String?
    /// Set only on error snapshots: a stable, non-PII bucket for the failure, read by telemetry on the
    /// failure path. Always `nil` on success (and error snapshots aren't cached), so it never persists.
    var errorCategory: ErrorCategory?

    init(
        providerID: String,
        displayName: String,
        account: ProviderAccountIdentity? = nil,
        accountEntries: [ProviderAccountEntry]? = nil,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        errorCategory: ErrorCategory? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.account = account
        self.accountEntries = accountEntries
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.warning = warning
        self.errorCategory = errorCategory
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// The success-path counterpart to `error(provider:message:)`: derives `providerID`/`displayName`
    /// from the provider so every runtime builds its snapshot the same way (`refreshedAt` is required
    /// so each call passes its own `now()`).
    static func make(
        provider: Provider,
        account: ProviderAccountIdentity? = nil,
        accountEntries: [ProviderAccountEntry]? = nil,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date,
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            account: account,
            accountEntries: accountEntries,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: warning
        )
    }

    /// Build an error snapshot straight from a caught error: the badge text stays the error's
    /// user-facing `localizedDescription` (UI copy is unchanged), and the telemetry category is derived
    /// from the error's `CategorizedError` conformance (falling back to `.other` for anything that
    /// doesn't classify itself). Preferred over `error(provider:message:)` wherever an `Error` is in hand.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(
            provider: provider,
            message: error.localizedDescription,
            category: (error as? CategorizedError)?.errorCategory ?? .other
        )
    }

    static func error(provider: Provider, message: String, category: ErrorCategory? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")],
            errorCategory: category
        )
    }
}
