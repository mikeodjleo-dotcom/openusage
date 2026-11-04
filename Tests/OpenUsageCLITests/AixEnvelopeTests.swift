import XCTest
@testable import OpenUsageCLI

final class AixEnvelopeTests: XCTestCase {
    private let input = Data(#"{"schema":"openusage.limits.v2","providers":{"codex@b":{"plan":"B"},"codex@a":{"plan":"A"},"claude@c":{"plan":"C"}}}"#.utf8)

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFirstAccountOfEachKindGoesUnderTheBareKind() throws {
        let root = try decode(AixEnvelope.reshape(input, brief: false))
        let providers = try XCTUnwrap(root["providers"] as? [String: [String: String]])
        XCTAssertEqual(Set(providers.keys), ["claude", "codex", "codex@b"])
        XCTAssertEqual(providers["codex"]?["plan"], "A")
        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v2")
    }

    func testBriefUsesTheOldSchemaWithEmptySpendAndTrends() throws {
        let root = try decode(AixEnvelope.reshape(input, brief: true))
        XCTAssertEqual(root["schema"] as? String, "openusage.brief.v1")
        XCTAssertEqual((root["spend"] as? [String: Any])?.count, 0)
        XCTAssertEqual((root["trends"] as? [String: Any])?.count, 0)
        XCTAssertEqual((root["errors"] as? [Any])?.count, 0)
    }

    func testBriefAndItsJSONFlagParse() throws {
        let parsed = try CLIArguments.parse(["brief", "--json"])
        XCTAssertTrue(parsed.brief)
        XCTAssertNil(parsed.providerID)
    }

    func testUnreadableInputPassesThrough() {
        let junk = Data("not json".utf8)
        XCTAssertEqual(AixEnvelope.reshape(junk, brief: true), junk)
    }
}
