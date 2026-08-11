import Foundation

/// Agent-facing projection of the same rendered snapshots used by the dashboard.
/// JSON keeps raw values for automation; Markdown is intentionally compact for prompt context.
enum AgentBriefAPI {
    static let schema = "openusage.brief.v1"

    static func json(providerIDs: [String], state: LocalUsageAPI.State) throws -> Data {
        let limitsData = LocalLimitsAPI.encode(providerIDs: providerIDs, state: state)
        guard let limits = try JSONSerialization.jsonObject(with: limitsData) as? [String: Any] else {
            throw AgentBriefError.invalidLimitsEnvelope
        }
        let snapshots = providerIDs.compactMap { state.snapshots[$0] }

        let root: [String: Any] = [
            "schema": schema,
            "generatedAt": OpenUsageISO8601.string(from: state.generatedAt),
            "providers": limits["providers"] ?? [:],
            "spend": spendObject(snapshots: snapshots),
            "trends": trendsObject(snapshots: snapshots),
            "errors": limits["errors"] ?? []
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func markdown(providerIDs: [String], state: LocalUsageAPI.State) -> Data {
        let snapshots = providerIDs.compactMap { state.snapshots[$0] }
        var lines = [
            "# OpenUsage brief",
            "",
            "Updated: \(OpenUsageISO8601.string(from: state.generatedAt))",
            "",
            "## Limits",
            "",
            "| Provider | Resource | Remaining | Resets at |",
            "| --- | --- | ---: | --- |"
        ]

        var limitCount = 0
        for snapshot in snapshots {
            for line in snapshot.lines {
                guard case .progress(let label, let used, let limit, let format, let resetsAt, _, _) = line,
                      format == .percent,
                      limit > 0 else { continue }
                limitCount += 1
                let remaining = max(0, min(100, ((limit - used) / limit) * 100))
                lines.append("| \(escape(snapshot.displayName)) | \(escape(label)) | \(percent(remaining)) | \(resetsAt.map(OpenUsageISO8601.string(from:)) ?? "-") |")
            }
        }
        if limitCount == 0 { lines.append("| No current limit data | - | - | - |") }

        lines += ["", "## Spend", "", "| Period | Cost | Tokens |", "| --- | ---: | ---: |"]
        for period in periods {
            let slices = spendSlices(label: period.label, snapshots: snapshots)
            let cost = slices.reduce(0) { $0 + $1.costUSD }
            let tokens = slices.reduce(0) { $0 + $1.tokens }
            lines.append("| \(period.title) | \(money(cost)) | \(integer(tokens)) |")
        }

        let today = spendSlices(label: "Today", snapshots: snapshots)
        if !today.isEmpty {
            lines += ["", "### Today by provider", "", "| Provider | Cost | Tokens |", "| --- | ---: | ---: |"]
            for slice in today.sorted(by: { $0.costUSD > $1.costUSD }) {
                lines.append("| \(escape(slice.displayName)) | \(money(slice.costUSD)) | \(integer(slice.tokens)) |")
            }
        }

        let warnings = state.errors
            .filter { providerIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
        if !warnings.isEmpty {
            lines += ["", "## Errors", ""]
            lines += warnings.map { "- \($0.key): \($0.value)" }
        }

        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static let periods = [
        (key: "today", title: "Today", label: "Today"),
        (key: "yesterday", title: "Yesterday", label: "Yesterday"),
        (key: "last30Days", title: "Last 30 Days", label: "Last 30 Days")
    ]

    private struct SpendSlice {
        let providerID: String
        let displayName: String
        let costUSD: Double
        let tokens: Int
        let estimated: Bool
    }

    private static func spendObject(snapshots: [ProviderSnapshot]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: periods.map { period in
            let slices = spendSlices(label: period.label, snapshots: snapshots)
            let providers: [[String: Any]] = slices.map { slice in
                [
                    "providerId": slice.providerID,
                    "displayName": slice.displayName,
                    "costUSD": moneyNumber(slice.costUSD),
                    "tokens": slice.tokens,
                    "estimated": slice.estimated
                ]
            }
            let value: [String: Any] = [
                "costUSD": moneyNumber(slices.reduce(0) { $0 + $1.costUSD }),
                "tokens": slices.reduce(0) { $0 + $1.tokens },
                "providers": providers
            ]
            return (period.key, value)
        })
    }

    private static func spendSlices(label: String, snapshots: [ProviderSnapshot]) -> [SpendSlice] {
        snapshots.compactMap { snapshot in
            guard let line = snapshot.line(label: label),
                  case .values(_, let values, _, _, _, _) = line else { return nil }
            let dollars = values.filter { $0.kind == .dollars }
            let cost = dollars.reduce(0) { $0 + $1.number }
            let tokens = Int(values
                .filter { $0.kind == .count && $0.label == "tokens" }
                .reduce(0) { $0 + $1.number })
            guard cost > 0 || tokens > 0 else { return nil }
            return SpendSlice(
                providerID: snapshot.providerID,
                displayName: snapshot.displayName,
                costUSD: max(0, cost),
                tokens: max(0, tokens),
                estimated: dollars.contains(where: \.estimated)
            )
        }
    }

    private static func trendsObject(snapshots: [ProviderSnapshot]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: snapshots.compactMap { snapshot in
            guard let line = snapshot.line(label: "Usage Trend"),
                  case .chart(_, let points, _) = line else { return nil }
            let values: [[String: Any]] = points.map { ["label": $0.label, "tokens": Int($0.value)] }
            return (snapshot.providerID, values)
        })
    }

    private static func roundedMoney(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), roundedMoney(value))
    }

    private static func moneyNumber(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), roundedMoney(value)))
    }

    private static func percent(_ value: Double) -> String {
        let rounded = value.rounded()
        return rounded == value ? "\(Int(rounded))%" : String(format: "%.1f%%", value)
    }

    private static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}

private enum AgentBriefError: LocalizedError {
    case invalidLimitsEnvelope

    var errorDescription: String? {
        "OpenUsage could not build the agent brief from its limits data."
    }
}
