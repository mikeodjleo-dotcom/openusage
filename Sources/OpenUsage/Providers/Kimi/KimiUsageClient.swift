import Foundation

struct KimiGrant: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var expiresIn: Int
    var scope: String?
    var tokenType: String?
    /// The token this grant used up, which is what the credential file must still hold to take the grant.
    var spentRefreshToken: String
}

struct KimiUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    var http: any HTTPClient

    func fetchUsage(accessToken: String, deviceID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "X-Msh-Platform": "kimi_code_cli"
        ]
        headers["X-Msh-Device-Id"] = deviceID
        return try await http.send(HTTPRequest(method: "GET", url: Self.usageURL, headers: headers, timeout: 15))
    }

    func refresh(_ refreshToken: String, now: Date) async throws -> KimiGrant {
        let body = "client_id=\(Self.clientID.urlFormEncoded)&grant_type=refresh_token&refresh_token=\(refreshToken.urlFormEncoded)"
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))
        let token = try OAuthTokenResponse(renewal: response, kind: .kimi)
        guard let expiresIn = token.expiresIn.flatMap(ProviderParse.int), expiresIn > 0 else { throw ProviderError.invalidResponse }
        let fields = ProviderParse.jsonObject(response.body)
        return KimiGrant(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken?.nilIfEmpty ?? refreshToken,
            expiresAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + Double(expiresIn)),
            expiresIn: expiresIn,
            scope: fields?["scope"] as? String,
            tokenType: fields?["token_type"] as? String,
            spentRefreshToken: refreshToken
        )
    }
}
