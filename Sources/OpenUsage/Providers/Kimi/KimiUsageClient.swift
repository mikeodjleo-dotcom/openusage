import Foundation

struct KimiUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        let body = [
            "client_id=\(Self.clientID.urlFormEncoded)",
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlFormEncoded)"
        ].joined(separator: "&")
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))
    }

    static func refreshedCredential(from body: Data, now: Date) throws -> KimiRefreshedOAuthCredential {
        guard let object = ProviderParse.jsonObject(body),
              let accessToken = (object["access_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let refreshToken = (object["refresh_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let expiresInValue = ProviderParse.number(object["expires_in"]),
              expiresInValue > 0,
              expiresInValue <= Double(Int.max)
        else {
            throw KimiUsageError.invalidResponse
        }
        let expiresIn = Int(expiresInValue)
        return KimiRefreshedOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + Double(expiresIn)),
            expiresIn: expiresIn,
            scope: object["scope"] as? String ?? "",
            tokenType: object["token_type"] as? String ?? "Bearer"
        )
    }

    func fetchUsage(auth: KimiAuth) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(auth.token)",
            "Accept": "application/json"
        ]
        if case .cliOAuth(let deviceID) = auth.source {
            headers["X-Msh-Platform"] = "kimi_code_cli"
            if let deviceID { headers["X-Msh-Device-Id"] = deviceID }
        }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: headers,
            timeout: 15
        ))
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return ProviderUsageErrorText.connectionFailed
        case .invalidResponse: return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status): return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
