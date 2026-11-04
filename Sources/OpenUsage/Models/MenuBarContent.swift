import Foundation

struct MenuBarContent: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let provider: Provider
        let label: String
        let shortLabel: String
        let value: String
    }

    let items: [Item]
    var overflow = 0
    var updateAvailable = false

    var isEmpty: Bool { items.isEmpty }

    /// One menu-bar segment per account, in first-seen order. At most two values fit a segment's height.
    var groups: [(provider: Provider, items: [Item])] {
        var result: [(provider: Provider, items: [Item])] = []
        for item in items {
            if let index = result.firstIndex(where: { $0.provider.id == item.provider.id }) {
                if result[index].items.count < 2 { result[index].items.append(item) }
            } else {
                result.append((item.provider, [item]))
            }
        }
        return result
    }

    var accessibilityText: String {
        let shown = items.map { "\($0.provider.fullName) \($0.label) \($0.value)" }
        let more = overflow > 0 ? ["\(overflow) more"] : []
        let update = updateAvailable ? ["Update available"] : []
        return (shown + more + update).joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    private static let genericWords: Set<String> = ["models", "bot", "usage"]

    static func build(board: PriorityBoard, limit: MenuBarLimit) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let shown = board.attention.prefix(limit.count).map { item in
            let label = item.data.title
            return MenuBarContent.Item(
                id: item.id,
                provider: item.provider,
                label: label,
                shortLabel: shortLabel(label),
                value: item.data.menuBarValue
            )
        }
        return MenuBarContent(items: shown, overflow: board.attention.count - shown.count)
    }

    /// Aix fork: as in 0.7, pinned metrics are the menu bar. They stay in place, however full they are and
    /// however many there are, until they are unpinned. `limit` only still means App Icon Only.
    static func build(accounts: [DashboardAccount], pinned: Set<String>, limit: MenuBarLimit) -> MenuBarContent? {
        guard limit != .iconOnly, !pinned.isEmpty else { return nil }
        let items = accounts.flatMap { account in
            account.lines.filter { pinned.contains($0.id) && $0.data.hasData }.map { line in
                MenuBarContent.Item(
                    id: line.id,
                    provider: account.provider,
                    label: line.data.title,
                    shortLabel: shortLabel(line.data.title),
                    value: line.data.menuBarValue
                )
            }
        }
        return items.isEmpty ? nil : MenuBarContent(items: items)
    }

    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }
}
