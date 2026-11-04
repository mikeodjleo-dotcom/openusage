import Foundation

enum KimiUsageMapper {
    /// Fixed titles: the usage API stopped reporting the membership level, and a row is matched by its label.
    static let sessionLabel = "Allegro · 5-Hour Code"
    static let weeklyLabel = "Allegro · 7-Day Code"
    static let fiveHourPeriodMs = 5 * 60 * 60 * 1000
    static let sevenDayPeriodMs = 7 * 24 * 60 * 60 * 1000

    static func map(_ response: HTTPResponse) throws -> ProviderUsage {
        let root = try ProviderError.requireSuccessJSON(response, kind: .kimi)
        guard let usage = root["usage"] as? [String: Any] else { throw ProviderError.invalidResponse }

        var lines: [MetricLine] = []
        let limits = root["limits"] as? [[String: Any]] ?? []
        if let fiveHour = limits.first(where: { ($0["window"] as? [String: Any]).flatMap(periodMs) == fiveHourPeriodMs }) {
            guard let detail = fiveHour["detail"] as? [String: Any] else { throw ProviderError.invalidResponse }
            lines.append(try percentLine(detail, label: sessionLabel, periodMs: fiveHourPeriodMs))
        }
        lines.append(try percentLine(usage, label: weeklyLabel, periodMs: sevenDayPeriodMs))

        let level = ((root["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String
        return ProviderUsage(plan: level.map(planName), lines: lines)
    }

    /// Kimi's own quota page works from `remaining / limit`; `used` can be stale or differently scoped.
    private static func percentLine(_ detail: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let limit = ProviderParse.number(detail["limit"]), limit > 0 else { throw ProviderError.invalidResponse }
        let used: Double
        if let remaining = ProviderParse.number(detail["remaining"]), (0...limit).contains(remaining) {
            used = limit - remaining
        } else if let explicit = ProviderParse.number(detail["used"]), explicit >= 0 {
            used = explicit
        } else {
            throw ProviderError.invalidResponse
        }
        let reset = ["resetTime", "resetAt", "reset_time", "reset_at"].lazy
            .compactMap { (detail[$0] as? String).flatMap(OpenUsageISO8601.date(from:)) }.first
        // Multiplying first keeps a whole percentage exact.
        return .percent(label, ProviderParse.clampPercent(used * 100 / limit), resetsAt: reset, periodMs: periodMs)
    }

    private static func periodMs(_ window: [String: Any]) -> Int? {
        guard let duration = ProviderParse.number(window["duration"]), duration > 0 else { return nil }
        let unitMs: Double
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": unitMs = 60 * 1000
        case "TIME_UNIT_HOUR": unitMs = 60 * 60 * 1000
        case "TIME_UNIT_DAY": unitMs = 24 * 60 * 60 * 1000
        case "TIME_UNIT_WEEK": unitMs = 7 * 24 * 60 * 60 * 1000
        default: return nil
        }
        return ProviderParse.int(duration * unitMs)
    }

    private static func planName(_ level: String) -> String {
        level == "LEVEL_ADVANCED" ? "Allegro" : level.replacingOccurrences(of: "LEVEL_", with: "").capitalized
    }
}
