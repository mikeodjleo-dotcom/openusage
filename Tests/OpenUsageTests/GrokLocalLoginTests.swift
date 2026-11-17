import XCTest
@testable import OpenUsage

/// The Grok CLI's auth.json is read only: the entry's key, email and expiry, nothing else.
final class GrokLocalLoginTests: XCTestCase {
    private func source(_ json: String) throws -> GrokLocalSource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return GrokLocalSource(path: url)
    }

    func testReadsCLIEntry() throws {
        let login = try source("""
        {"https://auth.x.ai::b1a00492":{"key":"tok","email":"a@b.c","expires_at":"2026-11-17T20:33:36.691724Z"}}
        """).read()
        XCTAssertEqual(login?.accessToken, "tok")
        XCTAssertEqual(login?.email, "a@b.c")
        let expected = ISO8601DateFormatter().date(from: "2026-11-17T20:33:36Z")!
        XCTAssertEqual(login?.expiresAt?.timeIntervalSince(expected) ?? -1, 0.69, accuracy: 0.01)
    }

    func testMissingKeyOrFileIsNoLogin() throws {
        XCTAssertNil(try source(#"{"x":{"email":"a@b.c"}}"#).read())
        XCTAssertNil(GrokLocalSource(path: URL(fileURLWithPath: "/nonexistent/auth.json")).read())
    }
}
