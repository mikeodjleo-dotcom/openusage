import CryptoKit
import Foundation

enum ProviderAuthMethod: Sendable, Hashable {
    case oauth
    case apiKey(keyPage: URL)
    case organizationToken
    /// The sign-in the provider's own CLI keeps on this Mac: nothing to paste and no browser.
    case localCLI
}

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case copilot
    case devin
    case grok
    case kimi
    case muse
    case ollama
    case opencodeGo = "opencode"
    case openrouter
    case zai

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .devin: "Devin"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .muse: "Muse Code"
        case .ollama: "Ollama"
        case .opencodeGo: "OpenCode"
        case .openrouter: "OpenRouter"
        case .zai: "Z.ai"
        }
    }

    var links: [ProviderLink] {
        switch self {
        case .claude: [.init(label: "Status Page", url: URL(string: "https://status.claude.com/")!),
                       .init(label: "Usage Dashboard", url: URL(string: "https://claude.ai/settings/usage")!)]
        case .codex: [.init(label: "Status Page", url: URL(string: "https://status.openai.com/")!),
                      .init(label: "Usage Dashboard", url: URL(string: "https://chatgpt.com/settings/usage")!)]
        case .cursor: [.init(label: "Status Page", url: URL(string: "https://status.cursor.com/")!),
                       .init(label: "Usage Dashboard", url: URL(string: "https://www.cursor.com/dashboard")!)]
        case .antigravity: []
        case .copilot: [.init(label: "Status Page", url: URL(string: "https://www.githubstatus.com/")!),
                        .init(label: "Usage Dashboard", url: URL(string: "https://github.com/settings/billing")!)]
        case .devin: [.init(label: "Usage Dashboard", url: URL(string: "https://app.devin.ai/settings/plans")!)]
        case .grok: [.init(label: "Usage Dashboard", url: URL(string: "https://grok.com/?_s=usage")!)]
        case .kimi: [.init(label: "Usage Dashboard", url: URL(string: "https://www.kimi.com/code/console")!)]
        case .muse: [.init(label: "Usage Dashboard", url: URL(string: "https://dev.meta.ai/usage")!)]
        case .ollama: [.init(label: "Usage Dashboard", url: URL(string: "https://ollama.com/settings")!),
                       .init(label: "API Keys", url: URL(string: "https://ollama.com/settings/keys")!)]
        case .opencodeGo: [.init(label: "Status Page", url: URL(string: "https://status.opencode.ai/")!),
                           .init(label: "Usage Dashboard", url: URL(string: "https://opencode.ai/console")!)]
        case .openrouter: [.init(label: "Status Page", url: URL(string: "https://status.openrouter.ai/")!),
                           .init(label: "Usage Dashboard", url: URL(string: "https://openrouter.ai/activity")!),
                           .init(label: "Credits", url: URL(string: "https://openrouter.ai/settings/credits")!)]
        case .zai: [.init(label: "Usage Dashboard", url: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!),
                    .init(label: "API Keys", url: URL(string: "https://z.ai/manage-apikey/apikey-list")!)]
        }
    }

    var authMethods: [ProviderAuthMethod] {
        switch self {
        case .claude: [.oauth, .localCLI]
        case .codex: [.oauth, .localCLI]
        case .cursor, .antigravity, .devin, .grok, .muse: [.oauth]
        case .copilot: [.oauth, .organizationToken]
        case .kimi: [.localCLI]
        case .ollama: [.apiKey(keyPage: URL(string: "https://ollama.com/settings/keys")!)]
        case .opencodeGo: [.apiKey(keyPage: URL(string: "https://opencode.ai/console")!)]
        case .openrouter: [.apiKey(keyPage: URL(string: "https://openrouter.ai/settings/management-keys")!)]
        case .zai: [.apiKey(keyPage: URL(string: "https://z.ai/manage-apikey/apikey-list")!)]
        }
    }
}

struct Account: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ProviderKind
    var label: String
    /// A Copilot organization account carries the login whose billing its token reads; every other
    /// account has none.
    let organization: String?
    /// An account mirrored from a CLIProxyAPI hub carries where its login lives there; every other
    /// account has none.
    var hub: HubLink?
    /// True for an account that reads its provider's CLI sign-in; absent on every other account.
    let usesLocalCLI: Bool?
    /// The Codex home a local ChatGPT account reads; absent on every other account.
    let localCLIHome: String?
    let addedAt: Date

    var authMethod: ProviderAuthMethod {
        if organization != nil { return .organizationToken }
        return usesLocalCLI == true ? .localCLI : kind.authMethods[0]
    }

    var cardID: String {
        "\(kind.rawValue)@\(id.uuidString.lowercased().prefix(8))"
    }

    init(
        id: UUID = UUID(), kind: ProviderKind, label: String, organization: String? = nil, hub: HubLink? = nil,
        usesLocalCLI: Bool = false, localCLIHome: String? = nil, addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.organization = organization
        self.hub = hub
        self.usesLocalCLI = usesLocalCLI ? true : nil
        self.localCLIHome = localCLIHome
        self.addedAt = addedAt
    }
}

struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var extras: [String: String] = [:]

    static let identityKey = "account_identity"

    static let refreshMargin: TimeInterval = 5 * 60

    func needsRefresh(at now: Date) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.refreshMargin)
    }
}

enum AccountCredential: Codable, Sendable, Equatable {
    case oauth(OAuthTokens)
    case apiKey(String)
    /// A marker: the sign-in itself stays with the provider's CLI. One Mac has one such sign-in per provider.
    case localCLI
    /// A marker for a Codex home's sign-in, which the account's `localCLIHome` names. The account id tells
    /// two logins apart; no token is kept.
    case localCodex(accountID: String)

    var identity: String? {
        switch self {
        case .oauth(let tokens):
            tokens.extras[OAuthTokens.identityKey]
        case .apiKey(let key):
            "key:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        case .localCLI:
            "local-cli"
        case .localCodex(let accountID):
            "codex:\(accountID)"
        }
    }
}
