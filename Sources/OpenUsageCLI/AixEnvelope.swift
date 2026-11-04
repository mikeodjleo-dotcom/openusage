import Foundation

/// Aix fork: keeps our scripts reading the shape they know. The first account of a kind (by id) goes
/// under the bare kind (`claude`), as 0.7 did; other accounts keep their `kind@id` key.
/// ponytail: "first by id" stands in for 0.7's default account; add an explicit default if two
/// accounts of one kind ever need a specific one to be primary.
enum AixEnvelope {
    static func reshape(_ data: Data, brief: Bool) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else { return data }
        var renamed: [String: Any] = [:]
        for id in providers.keys.sorted() {
            let kind = String(id.prefix { $0 != "@" })
            renamed[renamed[kind] == nil ? kind : id] = providers[id]
        }
        root["providers"] = renamed
        if brief {
            root["schema"] = "openusage.brief.v1"
            root["errors"] = [Any]()
            root["spend"] = [String: Any]()
            root["trends"] = [String: Any]()
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? data
    }
}
