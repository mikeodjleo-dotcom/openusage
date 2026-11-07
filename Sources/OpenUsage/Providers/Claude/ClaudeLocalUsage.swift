import Foundation

/// Claude usage read from a local file when Anthropic's usage endpoint can't be reached (the worker Mac gets a
/// 429 on it all day). Something else on the machine keeps the file current — on the worker Mac the job loop
/// writes the `rate_limit_event` windows that `claude -p` prints into `quota-claude.json` and the file here
/// links to it. Shape: `{"fetched_at": <epoch s>, "weekly": {"remaining_percent", "reset_at_ms"},
/// "five_hour": {"used_percent", "reset_at_ms"}}`. A file older than `maxAge` is not used.
enum ClaudeLocalUsage {
    static let maxAge: TimeInterval = 3600

    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["OPENUSAGE_CLAUDE_LOCAL_USAGE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/openusage/claude-local-usage.json")
    }

    static func lines(at url: URL, now: Date) -> [MetricLine]? {
        guard let data = try? Data(contentsOf: url), let body = ProviderParse.jsonObject(data) else { return nil }
        return lines(from: body, now: now)
    }

    static func lines(from body: [String: Any], now: Date) -> [MetricLine]? {
        guard let fetched = ProviderParse.number(body["fetched_at"]),
              now.timeIntervalSince1970 - fetched <= maxAge
        else { return nil }
        var lines: [MetricLine] = []
        if let five = body["five_hour"] as? [String: Any], let used = ProviderParse.number(five["used_percent"]),
           let reset = ClaudeUsageMapper.resetDate(five["reset_at_ms"]), reset > now {
            lines.append(.percent("Session", used, resetsAt: reset, periodMs: MetricPeriod.sessionMs))
        }
        if let week = body["weekly"] as? [String: Any], let remaining = ProviderParse.number(week["remaining_percent"]),
           let reset = ClaudeUsageMapper.resetDate(week["reset_at_ms"]), reset > now {
            lines.append(.percent("Weekly", max(0, 100 - remaining), resetsAt: reset, periodMs: MetricPeriod.weekMs))
        }
        return lines.isEmpty ? nil : lines
    }
}
