import Foundation

struct DashboardFamily: Identifiable {
    let id: String
    let provider: Provider
    var accounts: [DashboardAccount]

    /// The family's account when it has just the one, which then has no caption of its own.

    var hidingEmails: DashboardFamily {
        DashboardFamily(
            id: id, provider: provider.hidingEmail,
            accounts: accounts.map(\.hidingEmail)
        )
    }
}

struct DashboardAccount: Identifiable {
    let provider: Provider
    let lines: [DashboardLine]
    /// Before the account's first reading, the metrics it shows, each drawn as a skeleton row.
    var waitingMetricIDs: [String] = []

    var id: String { provider.id }
    var name: String { provider.accountName }
    var hidingEmail: DashboardAccount {
        DashboardAccount(provider: provider.hidingEmail, lines: lines, waitingMetricIDs: waitingMetricIDs)
    }
}

struct DashboardLine: Identifiable {
    let descriptor: WidgetDescriptor
    let data: WidgetData
    var id: String { descriptor.id }

    // Spent reset grants remain available to CLI clients.
    var isVisible: Bool {
        guard data.hasData else { return false }
        if data.showsResetExpiries { return data.resetCreditCount > 0 }
        return true
    }
}

extension DashboardFamily {
    static func make(
        groups: [ProviderMetrics], isWaiting: (Provider) -> Bool = { _ in false }, line: (WidgetDescriptor) -> DashboardLine
    ) -> [DashboardFamily] {
        var families: [DashboardFamily] = []
        for group in groups {
            let account = isWaiting(group.provider)
                ? DashboardAccount(provider: group.provider, lines: [], waitingMetricIDs: group.metrics.map(\.id))
                : DashboardAccount(provider: group.provider, lines: hidingWindowsCappedBySpentWeekly(group.metrics.map(line).filter(\.isVisible)))
            let familyID = group.provider.kind.rawValue
            if let index = families.firstIndex(where: { $0.id == familyID }) {
                families[index].accounts.append(account)
            } else {
                families.append(DashboardFamily(id: familyID, provider: group.provider, accounts: [account]))
            }
        }
        return families
    }

    /// Aix fork: a short window's key and the longer window that caps it. While the longer one is used up the short
    /// one can't be spent, so its "100% left" only misleads (11-12: Gemini 5h / Kimi 5-Hour pinned at 100% with weekly at 0).
    static let windowCaps: [String: String] = [
        "session": "weekly", "daily": "weekly", "spark": "sparkWeekly",
        "geminiPro": "geminiWeekly", "claude": "claudeWeekly",
    ]

    static func hidingWindowsCappedBySpentWeekly(_ lines: [DashboardLine], now: Date = Date()) -> [DashboardLine] {
        let spent = Set(lines.filter { $0.data.meterState(now: now) == .spent }.map(\.descriptor.key))
        return lines.filter { line in windowCaps[line.descriptor.key].map { !spent.contains($0) } ?? true }
    }
}

extension Provider {
    var isNamedByEmail: Bool {
        accountLabel?.contains("@") ?? false
    }

    var hidingEmail: Provider {
        guard isNamedByEmail else { return self }
        var copy = self; copy.accountLabel = nil; return copy
    }
}
