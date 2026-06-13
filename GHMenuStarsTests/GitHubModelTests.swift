import XCTest
@testable import GHMenuStars

final class GitHubModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testRepoJSONDecoding() throws {
        let data = Data(#"{"full_name":"owner/repo","stargazers_count":1248,"forks_count":42,"private":false}"#.utf8)
        let repo = try JSONDecoder().decode(GitHubRepoResponse.self, from: data)
        XCTAssertEqual(repo.fullName, "owner/repo")
        XCTAssertEqual(repo.stargazersCount, 1248)
        XCTAssertEqual(repo.forksCount, 42)
        XCTAssertFalse(repo.private)
    }

    func testReleaseDownloadAggregation() throws {
        let data = Data("""
        [
          {"assets":[{"name":"a.dmg","download_count":10},{"name":"b.zip","download_count":5}]},
          {"assets":[{"name":"c.dmg","download_count":27}]}
        ]
        """.utf8)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        XCTAssertEqual(ReleaseDownloadAggregator.totalDownloads(from: releases), 42)
    }

    func testAccessiblePublicReposFollowPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session, tokenProvider: { "token" })

        MockURLProtocol.responses = [
            "/user/repos?visibility=public&affiliation=owner,collaborator&sort=updated&per_page=100": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/user/repos?visibility=public&affiliation=owner,collaborator&sort=updated&per_page=100&page=2>; rel="next""#
                ],
                data: Data(#"[{"id":1,"name":"one","full_name":"owner/one","owner":{"login":"owner"}}]"#.utf8)
            ),
            "/user/repos?visibility=public&affiliation=owner,collaborator&sort=updated&per_page=100&page=2": MockURLProtocol.Response(
                data: Data(#"[{"id":2,"name":"two","full_name":"owner/two","owner":{"login":"owner"}}]"#.utf8)
            )
        ]

        let repos = try await client.fetchAccessiblePublicRepos()

        XCTAssertEqual(repos.map(\.fullName), ["owner/one", "owner/two"])
        XCTAssertEqual(MockURLProtocol.requestedPaths, [
            "/user/repos?visibility=public&affiliation=owner,collaborator&sort=updated&per_page=100",
            "/user/repos?visibility=public&affiliation=owner,collaborator&sort=updated&per_page=100&page=2"
        ])
    }

    func testPublicRepoFetchDoesNotReadToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var tokenProviderCallCount = 0
        let client = GitHubClient(session: session, tokenProvider: {
            tokenProviderCallCount += 1
            return "token"
        })

        MockURLProtocol.responses = [
            "/repos/owner/repo": MockURLProtocol.Response(
                data: Data(#"{"full_name":"owner/repo","stargazers_count":12,"forks_count":3,"private":false}"#.utf8)
            )
        ]

        let result = try await client.fetchRepo(owner: "owner", name: "repo", etag: nil)

        XCTAssertEqual(result.value.fullName, "owner/repo")
        XCTAssertEqual(tokenProviderCallCount, 0)
    }

    func testStargazerHistoryUsesStarAcceptAndWalksBackFromLastPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)
        let formatter = ISO8601DateFormatter()
        let since = formatter.date(from: "2025-06-13T00:00:00Z")!

        MockURLProtocol.responses = [
            "/repos/owner/repo/stargazers?per_page=100": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/repos/owner/repo/stargazers?per_page=100&page=2>; rel="next", <https://api.github.com/repos/owner/repo/stargazers?per_page=100&page=3>; rel="last""#
                ],
                data: Data(#"[{"starred_at":"2024-01-01T00:00:00Z","user":{"login":"old"}}]"#.utf8)
            ),
            "/repos/owner/repo/stargazers?per_page=100&page=3": MockURLProtocol.Response(
                data: Data(#"[{"starred_at":"2026-01-03T00:00:00Z","user":{"login":"new"}}]"#.utf8)
            ),
            "/repos/owner/repo/stargazers?per_page=100&page=2": MockURLProtocol.Response(
                data: Data(#"[{"starred_at":"2024-12-31T00:00:00Z","user":{"login":"older"}}]"#.utf8)
            )
        ]

        let dates = try await client.fetchRecentStargazerDates(owner: "owner", name: "repo", since: since)

        XCTAssertEqual(dates, [formatter.date(from: "2026-01-03T00:00:00Z")!])
        XCTAssertEqual(MockURLProtocol.requestedPaths, [
            "/repos/owner/repo/stargazers?per_page=100",
            "/repos/owner/repo/stargazers?per_page=100&page=3",
            "/repos/owner/repo/stargazers?per_page=100&page=2"
        ])
        XCTAssertTrue(MockURLProtocol.requestedAccepts.allSatisfy { $0 == "application/vnd.github.star+json" })
    }

    func testForkHistoryFollowsNewestPaginationUntilOlderThanWindow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)
        let formatter = ISO8601DateFormatter()
        let since = formatter.date(from: "2025-06-13T00:00:00Z")!

        MockURLProtocol.responses = [
            "/repos/owner/repo/forks?sort=newest&per_page=100": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/repos/owner/repo/forks?sort=newest&per_page=100&page=2>; rel="next""#
                ],
                data: Data(#"[{"created_at":"2026-04-01T00:00:00Z","full_name":"fork/new"}]"#.utf8)
            ),
            "/repos/owner/repo/forks?sort=newest&per_page=100&page=2": MockURLProtocol.Response(
                data: Data(#"[{"created_at":"2024-12-31T00:00:00Z","full_name":"fork/old"}]"#.utf8)
            )
        ]

        let dates = try await client.fetchRecentForkDates(owner: "owner", name: "repo", since: since)

        XCTAssertEqual(dates, [formatter.date(from: "2026-04-01T00:00:00Z")!])
        XCTAssertEqual(MockURLProtocol.requestedPaths, [
            "/repos/owner/repo/forks?sort=newest&per_page=100",
            "/repos/owner/repo/forks?sort=newest&per_page=100&page=2"
        ])
    }
}

private final class MockURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var data: Data
    }

    static var responses: [String: Response] = [:]
    static var requestedPaths: [String] = []
    static var requestedAccepts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let key = Self.pathAndQuery(for: url)
        Self.requestedPaths.append(key)
        Self.requestedAccepts.append(request.value(forHTTPHeaderField: "Accept") ?? "")

        guard let response = Self.responses[key],
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        responses = [:]
        requestedPaths = []
        requestedAccepts = []
    }

    private static func pathAndQuery(for url: URL) -> String {
        if let query = url.query {
            return "\(url.path)?\(query)"
        }
        return url.path
    }
}
