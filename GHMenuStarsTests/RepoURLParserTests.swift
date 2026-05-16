import XCTest
@testable import GHMenuStars

final class RepoURLParserTests: XCTestCase {
    func testParsesOwnerRepo() throws {
        XCTAssertEqual(try RepoURLParser.parse("owner/repo"), ParsedRepo(owner: "owner", name: "repo"))
    }

    func testParsesGitHubURL() throws {
        XCTAssertEqual(
            try RepoURLParser.parse("https://github.com/apple/swift.git"),
            ParsedRepo(owner: "apple", name: "swift")
        )
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try RepoURLParser.parse("https://example.com/a/b"))
        XCTAssertThrowsError(try RepoURLParser.parse("owner"))
    }
}

