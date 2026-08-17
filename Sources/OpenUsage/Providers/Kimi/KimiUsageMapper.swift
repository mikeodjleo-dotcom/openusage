import Foundation

struct KimiMappedUsage: Sendable {
    var plan: String?
    var lines: [MetricLine]
    var account: ProviderAccountIdentity?
}

enum KimiUsageMapper {
    static let fiveHourPeriodMs = 5 * 60 * 60 * 1000
    static let sevenDayPeriodMs = 7 * 24 * 60 * 60 * 1000

    static func map(_ body: Data) throws -> KimiMappedUsage {
        guard let root = ProviderParse.jsonObject(body),
              let usage = root["usage"] as? [String: Any] else {
            throw KimiUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let window = limit["window"] as? [String: Any],
                      let periodMs = periodDurationMs(window) else { continue }
                guard periodMs == fiveHourPeriodMs else { continue }
                guard let detail = limit["detail"] as? [String: Any] else {
                    throw KimiUsageError.invalidResponse
                }
                lines.append(try percentLine(detail, label: "5-Hour Code", periodMs: periodMs))
                break
            }
        }
        lines.append(try percentLine(usage, label: "7-Day Code", periodMs: sevenDayPeriodMs))

        let user = root["user"] as? [String: Any]
        let level = ((user?["membership"] as? [String: Any])?["level"] as? String)
        let account = user.flatMap {
            ProviderAccountIdentity.from(
                $0,
                labelKeys: ["email", "username", "nickname", "name"],
                idKeys: ["userId", "user_id", "id"]
            )
        }
        return KimiMappedUsage(plan: planName(level), lines: lines, account: account)
    }

    private static func percentLine(_ detail: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let limit = ProviderParse.number(detail["limit"]), limit > 0 else {
            throw KimiUsageError.invalidResponse
        }
        let used: Double
        // Kimi's own quota UI calculates these windows from remaining / limit. The API's `used`
        // field can be a stale or differently-scoped counter, so it is only a compatibility fallback.
        if let remaining = ProviderParse.number(detail["remaining"]), remaining >= 0, remaining <= limit {
            used = limit - remaining
        } else if let explicit = ProviderParse.number(detail["used"]), explicit >= 0 {
            used = explicit
        } else {
            throw KimiUsageError.invalidResponse
        }
        let usedPercent = ProviderParse.clampPercent(used / limit * 100)
        let reset = (detail["resetTime"] as? String).flatMap(OpenUsageISO8601.date(from:))
            ?? (detail["resetAt"] as? String).flatMap(OpenUsageISO8601.date(from:))
            ?? (detail["reset_time"] as? String).flatMap(OpenUsageISO8601.date(from:))
            ?? (detail["reset_at"] as? String).flatMap(OpenUsageISO8601.date(from:))
        return .progress(
            label: label,
            used: usedPercent,
            limit: 100,
            format: .percent,
            resetsAt: reset,
            periodDurationMs: periodMs
        )
    }

    private static func periodDurationMs(_ window: [String: Any]) -> Int? {
        guard let duration = ProviderParse.number(window["duration"]), duration > 0,
              duration < Double(Int.max) else { return nil }
        let multiplier: Double
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": multiplier = 60 * 1000
        case "TIME_UNIT_HOUR": multiplier = 60 * 60 * 1000
        case "TIME_UNIT_DAY": multiplier = 24 * 60 * 60 * 1000
        case "TIME_UNIT_WEEK": multiplier = 7 * 24 * 60 * 60 * 1000
        default: return nil
        }
        let value = duration * multiplier
        guard value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func planName(_ level: String?) -> String? {
        guard let level else { return nil }
        if let displayName = officialPlanNames[level] {
            return displayName
        }
        let raw = level.replacingOccurrences(of: "LEVEL_", with: "")
        return raw.lowercased().capitalized
    }

    /// Kimi Code's usage API identifies subscriptions by level rather than display name. Keep the
    /// names Kimi shows in its membership UI here; unknown levels retain the prior readable fallback.
    private static let officialPlanNames = [
        "LEVEL_ADVANCED": "Allegro"
    ]
}
