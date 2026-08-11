import XCTest
@testable import OpenUsageCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesProviderAndForce() throws {
        let parsed = try CLIArguments.parse(["Codex", "--force"])
        XCTAssertEqual(parsed.providerID, "codex")
        XCTAssertTrue(parsed.force)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--wat"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }

    func testParsesBriefFormats() throws {
        let json = try CLIArguments.parse(["brief", "--json", "--force"])
        XCTAssertTrue(json.isBrief)
        XCTAssertEqual(json.briefOutput, .json)
        XCTAssertTrue(json.force)

        let markdown = try CLIArguments.parse(["brief", "--markdown"])
        XCTAssertEqual(markdown.briefOutput, .markdown)

        let defaultFormat = try CLIArguments.parse(["brief"])
        XCTAssertEqual(defaultFormat.briefOutput, .json)
    }

    func testRejectsBriefFormatWithoutBriefAndProviderWithBrief() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json"]))
        XCTAssertThrowsError(try CLIArguments.parse(["brief", "codex"]))
        XCTAssertThrowsError(try CLIArguments.parse(["brief", "--json", "--markdown"]))
    }
}
