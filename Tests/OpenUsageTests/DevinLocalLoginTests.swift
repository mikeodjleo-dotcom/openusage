import XCTest
@testable import OpenUsage

/// The Devin CLI's credentials.toml is read only: the API key and an https API server, nothing else.
final class DevinLocalLoginTests: XCTestCase {
    private func source(_ toml: String) throws -> DevinLocalSource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devin-cred-\(UUID().uuidString).toml")
        try Data(toml.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return DevinLocalSource(path: url)
    }

    func testReadsCLIKeyAndServer() throws {
        let login = try source("""
        windsurf_api_key = "devin-session-token$abc=="
        api_server_url = "https://server.codeium.com"
        devin_api_url = "https://api.devin.ai"
        """).read()
        XCTAssertEqual(login, .init(apiKey: "devin-session-token$abc==", apiServerURL: "https://server.codeium.com"))
    }

    func testMissingKeyOrFileIsNoLoginAndHTTPServerIsDropped() throws {
        XCTAssertNil(try source(#"api_server_url = "https://server.codeium.com""#).read())
        XCTAssertNil(DevinLocalSource(path: URL(fileURLWithPath: "/nonexistent/credentials.toml")).read())
        XCTAssertNil(try source("windsurf_api_key = \"k\"\napi_server_url = \"http://evil.example\"").read()?.apiServerURL)
    }
}
