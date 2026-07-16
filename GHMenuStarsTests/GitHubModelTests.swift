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

    func testReleaseDecodingReadsTagDateAndFlags() throws {
        let json = """
        [{"tag_name":"v0.3.1","name":"0.3.1","published_at":"2026-06-26T10:00:00Z",
          "draft":false,"prerelease":true,
          "assets":[{"name":"App-arm64.dmg","download_count":820}]}]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([GitHubRelease].self, from: json)
        XCTAssertEqual(releases.first?.tagName, "v0.3.1")
        XCTAssertEqual(releases.first?.name, "0.3.1")
        XCTAssertEqual(releases.first?.prerelease, true)
        XCTAssertEqual(releases.first?.draft, false)
        XCTAssertEqual(releases.first?.assets.first?.downloadCount, 820)
        XCTAssertNotNil(releases.first?.publishedAt)
    }

    func testLatestReleaseSummaryPicksNewestPublishedNonDraft() {
        let old = GitHubRelease(tagName: "v0.2.0", name: nil,
            publishedAt: Date(timeIntervalSince1970: 1_000_000),
            draft: false, prerelease: false,
            assets: [GitHubReleaseAsset(name: "App-0.2.0-arm64.dmg", downloadCount: 100)])
        let draft = GitHubRelease(tagName: "v0.4.0", name: nil,
            publishedAt: Date(timeIntervalSince1970: 3_000_000),
            draft: true, prerelease: false, assets: [])
        let newest = GitHubRelease(tagName: "v0.3.1", name: "0.3.1",
            publishedAt: Date(timeIntervalSince1970: 2_000_000),
            draft: false, prerelease: true,
            assets: [GitHubReleaseAsset(name: "App-0.3.1-arm64.dmg", downloadCount: 820),
                     GitHubReleaseAsset(name: "App-0.3.1.zip", downloadCount: 410)])
        let summary = LatestReleaseSummaryBuilder.summary(from: [old, draft, newest], totalDownloads: 1_330)
        XCTAssertEqual(summary?.tag, "v0.3.1")
        XCTAssertEqual(summary?.isPrerelease, true)
        XCTAssertEqual(summary?.downloads, 1_230)
        XCTAssertEqual(summary?.totalDownloads, 1_330)
        XCTAssertEqual(summary?.assets.map(\.count), [820, 410])
        XCTAssertEqual(summary?.assets.map(\.label), ["arm64.dmg", "zip"])
    }

    func testLatestReleaseSummaryNilWhenNoPublishedRelease() {
        let draftOnly = GitHubRelease(tagName: "v1", name: nil, publishedAt: nil,
            draft: true, prerelease: false, assets: [])
        XCTAssertNil(LatestReleaseSummaryBuilder.summary(from: [draftOnly], totalDownloads: 0))
        XCTAssertNil(LatestReleaseSummaryBuilder.summary(from: [], totalDownloads: 0))
    }

    func testRecentReleasesSummaryCountsWindowAndSumsDownloads() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let day = 24.0 * 60 * 60
        let inWindow1 = GitHubRelease(tagName: "v3", name: nil, publishedAt: now.addingTimeInterval(-5 * day),
            draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "a.dmg", downloadCount: 800)])
        let inWindow2 = GitHubRelease(tagName: "v2", name: nil, publishedAt: now.addingTimeInterval(-20 * day),
            draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "b.dmg", downloadCount: 300),
                                                       GitHubReleaseAsset(name: "b.zip", downloadCount: 100)])
        let outWindow = GitHubRelease(tagName: "v1", name: nil, publishedAt: now.addingTimeInterval(-40 * day),
            draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "c.dmg", downloadCount: 5000)])
        let draftInWindow = GitHubRelease(tagName: "v4", name: nil, publishedAt: now.addingTimeInterval(-1 * day),
            draft: true, prerelease: false, assets: [GitHubReleaseAsset(name: "d.dmg", downloadCount: 999)])
        let summary = RecentReleasesSummaryBuilder.summary(from: [inWindow1, inWindow2, outWindow, draftInWindow], totalDownloads: 6200, now: now)
        XCTAssertEqual(summary?.releaseCount, 2)
        XCTAssertEqual(summary?.downloads, 1200)
        XCTAssertEqual(summary?.totalDownloads, 6200)
    }

    func testRecentReleasesSummaryNilWhenNoPublishedReleases() {
        let draftOnly = GitHubRelease(tagName: "v1", name: nil, publishedAt: nil, draft: true, prerelease: false, assets: [])
        XCTAssertNil(RecentReleasesSummaryBuilder.summary(from: [draftOnly], totalDownloads: 0, now: Date()))
    }

    func testRecentReleasesSummaryZeroCountWhenReleasesAllOld() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let old = GitHubRelease(tagName: "v1", name: nil, publishedAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
            draft: false, prerelease: false, assets: [GitHubReleaseAsset(name: "a.dmg", downloadCount: 10)])
        let summary = RecentReleasesSummaryBuilder.summary(from: [old], totalDownloads: 10, now: now)
        XCTAssertEqual(summary?.releaseCount, 0)
        XCTAssertEqual(summary?.downloads, 0)
    }

    func testShortLabelsReduceAndCapLongNames() {
        // No common prefix -> the long name collapses to its most specific token.
        XCTAssertEqual(
            LatestReleaseSummaryBuilder.shortLabels(for: ["StargazerBar-arm64.dmg", "checksums.txt"]),
            ["arm64.dmg", "checksums.txt"]
        )
        // A long dashless name is hard-capped to 16 characters.
        XCTAssertEqual(
            LatestReleaseSummaryBuilder.shortLabels(for: ["averyveryverylongsinglename.bin"]).first?.count,
            16
        )
    }

    func testAccessiblePublicReposFollowPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var tokenProviderCallCount = 0
        let client = GitHubClient(session: session, tokenProvider: {
            tokenProviderCallCount += 1
            return "token"
        })

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
        XCTAssertEqual(tokenProviderCallCount, 2)
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
        XCTAssertEqual(MockURLProtocol.requestedAuthorizations, [nil])
    }

    func testPublicRepoFetchUsesOptionalTokenWhenAvailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var optionalTokenProviderCallCount = 0
        let client = GitHubClient(session: session, optionalTokenProvider: {
            optionalTokenProviderCallCount += 1
            return "token"
        })

        MockURLProtocol.responses = [
            "/repos/owner/repo": MockURLProtocol.Response(
                data: Data(#"{"full_name":"owner/repo","stargazers_count":12,"forks_count":3,"private":false}"#.utf8)
            )
        ]

        let result = try await client.fetchRepo(owner: "owner", name: "repo", etag: nil)

        XCTAssertEqual(result.value.stargazersCount, 12)
        XCTAssertEqual(optionalTokenProviderCallCount, 1)
        XCTAssertEqual(MockURLProtocol.requestedAuthorizations, ["Bearer token"])
    }

    func testMaintainerRadarUsesOptionalTokenForPublicEndpoints() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var optionalTokenProviderCallCount = 0
        let client = GitHubClient(session: session, optionalTokenProvider: {
            optionalTokenProviderCallCount += 1
            return "token"
        })

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
            )
        ]

        _ = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off)

        XCTAssertEqual(optionalTokenProviderCallCount, 1)
        XCTAssertEqual(MockURLProtocol.requestedAuthorizations.count, 3)
        XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer token" })
    }

    func testMaintainerRadarDoesNotReadRequiredTokenProviderForOptionalAuth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var tokenProviderCallCount = 0
        let client = GitHubClient(session: session, tokenProvider: {
            tokenProviderCallCount += 1
            return "token"
        })

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
            )
        ]

        _ = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off)

        XCTAssertEqual(tokenProviderCallCount, 0)
        XCTAssertEqual(MockURLProtocol.requestedAuthorizations, [nil, nil, nil])
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

    func testAllStargazerHistoryFollowsPaginationForward() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)
        let formatter = ISO8601DateFormatter()

        MockURLProtocol.responses = [
            "/repos/owner/repo/stargazers?per_page=100": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/repos/owner/repo/stargazers?per_page=100&page=2>; rel="next", <https://api.github.com/repos/owner/repo/stargazers?per_page=100&page=3>; rel="last""#
                ],
                data: Data(#"[{"starred_at":"2024-01-01T00:00:00Z","user":{"login":"old"}}]"#.utf8)
            ),
            "/repos/owner/repo/stargazers?per_page=100&page=2": MockURLProtocol.Response(
                data: Data(#"[{"starred_at":"2025-01-01T00:00:00Z","user":{"login":"middle"}}]"#.utf8)
            ),
            "/repos/owner/repo/stargazers?per_page=100&page=3": MockURLProtocol.Response(
                data: Data(#"[{"starred_at":"2026-01-03T00:00:00Z","user":{"login":"new"}}]"#.utf8)
            )
        ]

        let dates = try await client.fetchStargazerDates(owner: "owner", name: "repo")

        XCTAssertEqual(dates, [
            formatter.date(from: "2024-01-01T00:00:00Z")!,
            formatter.date(from: "2025-01-01T00:00:00Z")!,
            formatter.date(from: "2026-01-03T00:00:00Z")!
        ])
        XCTAssertEqual(MockURLProtocol.requestedPaths, [
            "/repos/owner/repo/stargazers?per_page=100",
            "/repos/owner/repo/stargazers?per_page=100&page=2",
            "/repos/owner/repo/stargazers?per_page=100&page=3"
        ])
    }

    func testAllStargazerBackfillIsPageBoundedForLargeRepos() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)
        let formatter = ISO8601DateFormatter()

        var responses: [String: MockURLProtocol.Response] = [
            "/repos/owner/repo/stargazers?per_page=100": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/repos/owner/repo/stargazers?per_page=100&page=2>; rel="next", <https://api.github.com/repos/owner/repo/stargazers?per_page=100&page=10>; rel="last""#
                ],
                data: Data(#"[{"starred_at":"2020-01-01T00:00:00Z","user":{"login":"oldest"}}]"#.utf8)
            )
        ]
        for page in 2...10 {
            responses["/repos/owner/repo/stargazers?per_page=100&page=\(page)"] = MockURLProtocol.Response(
                data: Data("[{\"starred_at\":\"2026-01-\(String(format: "%02d", page))T00:00:00Z\",\"user\":{\"login\":\"u\(page)\"}}]".utf8)
            )
        }
        MockURLProtocol.responses = responses

        let dates = try await client.fetchStargazerDates(owner: "owner", name: "repo", maxPages: 3)

        // Only the base request plus the three newest pages are fetched — a
        // popular repo must not trigger a request per page.
        XCTAssertEqual(MockURLProtocol.requestedPaths, [
            "/repos/owner/repo/stargazers?per_page=100",
            "/repos/owner/repo/stargazers?per_page=100&page=10",
            "/repos/owner/repo/stargazers?per_page=100&page=9",
            "/repos/owner/repo/stargazers?per_page=100&page=8"
        ])
        // The oldest page (page 1) is outside the fetched window and dropped.
        XCTAssertFalse(dates.contains(formatter.date(from: "2020-01-01T00:00:00Z")!))
        XCTAssertTrue(dates.contains(formatter.date(from: "2026-01-10T00:00:00Z")!))
    }

    func testForkBackfillIsPageBoundedForLargeRepos() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)

        MockURLProtocol.responses = [
            "/repos/owner/repo/forks?sort=newest&per_page=100": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/repos/owner/repo/forks?sort=newest&per_page=100&page=2>; rel="next""#
                ],
                data: Data(#"[{"created_at":"2026-04-01T00:00:00Z","full_name":"fork/newest"}]"#.utf8)
            ),
            "/repos/owner/repo/forks?sort=newest&per_page=100&page=2": MockURLProtocol.Response(
                headers: [
                    "Link": #"<https://api.github.com/repos/owner/repo/forks?sort=newest&per_page=100&page=3>; rel="next""#
                ],
                data: Data(#"[{"created_at":"2026-03-01T00:00:00Z","full_name":"fork/mid"}]"#.utf8)
            ),
            "/repos/owner/repo/forks?sort=newest&per_page=100&page=3": MockURLProtocol.Response(
                data: Data(#"[{"created_at":"2026-02-01T00:00:00Z","full_name":"fork/old"}]"#.utf8)
            )
        ]

        _ = try await client.fetchForkDates(owner: "owner", name: "repo", maxPages: 2)

        // Stops after the newest two pages; page 3 is never requested.
        XCTAssertEqual(MockURLProtocol.requestedPaths, [
            "/repos/owner/repo/forks?sort=newest&per_page=100",
            "/repos/owner/repo/forks?sort=newest&per_page=100&page=2"
        ])
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

    func testMaintainerRadarFetchesPublicCountsAndFailedWorkflow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":2,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":5,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":1,"workflow_runs":[{"workflow_id":10,"name":"CI","display_title":"Tests","html_url":"https://github.com/owner/repo/actions/runs/1","status":"completed","conclusion":"failure","created_at":"2026-06-13T12:00:00Z"}]}"#.utf8)
            )
        ]

        let radar = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off)

        XCTAssertEqual(radar.openPullRequests, 2)
        XCTAssertEqual(radar.unansweredIssues, 5)
        XCTAssertEqual(radar.latestFailedWorkflow?.name, "CI")
        XCTAssertEqual(radar.latestFailedWorkflow?.url, "https://github.com/owner/repo/actions/runs/1")
        // Dated, so the menu can distinguish "broke minutes ago" from a failure
        // that has sat there for months.
        XCTAssertNotNil(radar.latestFailedWorkflow?.failedAt)
        XCTAssertTrue(radar.workflowChecked)
        XCTAssertEqual(radar.attentionCount, 6)
    }

    func testMaintainerRadarIgnoresOlderWorkflowFailureAfterNewerSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":2,"workflow_runs":[{"workflow_id":10,"name":"CI","display_title":"Tests","html_url":"https://github.com/owner/repo/actions/runs/2","status":"completed","conclusion":"success","created_at":"2026-06-14T12:00:00Z"},{"workflow_id":10,"name":"CI","display_title":"Tests","html_url":"https://github.com/owner/repo/actions/runs/1","status":"completed","conclusion":"failure","created_at":"2026-06-13T12:00:00Z"}]}"#.utf8)
            )
        ]

        let radar = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off)

        XCTAssertNil(radar.latestFailedWorkflow)
        XCTAssertTrue(radar.workflowChecked)
        XCTAssertEqual(radar.attentionCount, 0)
    }

    func testMaintainerRadarFetchesActivityWindowCounts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session)
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-06-14T12:00:00Z")!

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":9,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open%20created:%3E%3D2026-06-13T12:00:00Z&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":2,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20created:%3E%3D2026-06-13T12:00:00Z&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":3,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":4,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            // Commits now come from /activity -> active refs -> per-ref fan-out,
            // deduped by SHA: the default-branch-only path reported 0 on a repo
            // with 100+ commits that week on a feature branch. Two refs moved,
            // and they share one commit — 7 unique, not 8.
            "/repos/owner/repo/activity?time_period=day&per_page=100": MockURLProtocol.Response(
                data: Data(#"[{"activity_type":"push","ref":"refs/heads/main","timestamp":"2026-06-13T18:00:00Z"},{"activity_type":"push","ref":"refs/heads/feature","timestamp":"2026-06-14T09:00:00Z"}]"#.utf8)
            ),
            "/repos/owner/repo/commits?sha=feature&since=2026-06-13T12:00:00Z&per_page=100": MockURLProtocol.Response(
                data: Data(#"[{"sha":"a","commit":{"author":{"date":"2026-06-14T09:00:00Z"}}},{"sha":"b","commit":{"author":{"date":"2026-06-14T09:10:00Z"}}},{"sha":"c","commit":{"author":{"date":"2026-06-14T09:20:00Z"}}},{"sha":"shared","commit":{"author":{"date":"2026-06-13T18:00:00Z"}}}]"#.utf8)
            ),
            "/repos/owner/repo/commits?sha=main&since=2026-06-13T12:00:00Z&per_page=100": MockURLProtocol.Response(
                data: Data(#"[{"sha":"d","commit":{"author":{"date":"2026-06-13T19:00:00Z"}}},{"sha":"e","commit":{"author":{"date":"2026-06-13T20:00:00Z"}}},{"sha":"f","commit":{"author":{"date":"2026-06-13T21:00:00Z"}}},{"sha":"shared","commit":{"author":{"date":"2026-06-13T18:00:00Z"}}}]"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
            )
        ]

        let radar = await client.fetchMaintainerRadar(
            owner: "owner",
            name: "repo",
            activityWindow: .oneDay,
            now: now,
            // Private-repo path: this test covers the cross-branch dedup.
            // Public repos take the cheap default-branch count instead.
            crossBranchCommits: true
        )

        XCTAssertEqual(radar.openPullRequests, 9)
        XCTAssertEqual(radar.newPullRequests, 2)
        XCTAssertEqual(radar.newIssues, 3)
        XCTAssertEqual(radar.unansweredIssues, 4)
        XCTAssertEqual(radar.recentCommits, 7)
        XCTAssertEqual(radar.activityWindow, .oneDay)
    }

    func testMaintainerRadarAnchorsToReleaseDate() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let anchor = Date(timeIntervalSince1970: 1_500_000)
        let radar = await client.fetchMaintainerRadar(
            owner: "owner", name: "repo",
            activityWindow: .oneDay,
            releaseAnchor: anchor,
            now: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertEqual(radar.activityAnchoredSince, anchor)
        let sinceString = ISO8601DateFormatter().string(from: anchor)
        XCTAssertTrue(MockURLProtocol.requestedPaths.contains { $0.contains(sinceString) })
    }

    func testMaintainerRadarPrefersSuppliedTokenOverAmbientProvider() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var ambientCallCount = 0
        let client = GitHubClient(session: session, optionalTokenProvider: {
            ambientCallCount += 1
            return "ambient-oauth"
        })

        // .off suppresses the created:>= calls, whose paths embed Date() and so
        // cannot be pre-keyed. Leaves exactly 3 deterministic paths.
        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
            )
        ]

        _ = await client.fetchMaintainerRadar(
            owner: "owner", name: "repo", activityWindow: .off, optionalAuthToken: "pat-token"
        )

        XCTAssertEqual(MockURLProtocol.requestedAuthorizations.count, 3)
        // The whole feature: any radar call carrying the ambient token 404s on a
        // private repo, and the optional* wrappers turn that into a blank row
        // with no error at all.
        XCTAssertTrue(
            MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer pat-token" },
            "radar used the ambient token: \(MockURLProtocol.requestedAuthorizations)"
        )
        XCTAssertEqual(ambientCallCount, 0, "a supplied token must short-circuit the ambient provider")
    }

    func testMaintainerRadarFallsBackToAmbientWhenNoTokenSupplied() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session, optionalTokenProvider: { "ambient-oauth" })

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
            )
        ]

        _ = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off)

        // Public repos must behave exactly as before this change.
        XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer ambient-oauth" })
    }

    func testFetchRepoAndReleasesAcceptSuppliedToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session, optionalTokenProvider: { "ambient-oauth" })

        MockURLProtocol.responses = [
            "/repos/owner/repo": MockURLProtocol.Response(
                data: Data(#"{"full_name":"owner/repo","stargazers_count":0,"forks_count":0,"private":true}"#.utf8)
            ),
            "/repos/owner/repo/releases?per_page=100": MockURLProtocol.Response(data: Data("[]".utf8))
        ]

        _ = try await client.fetchRepo(owner: "owner", name: "repo", etag: nil, optionalAuthToken: "pat-token")
        _ = try await client.fetchReleases(owner: "owner", name: "repo", etag: nil, optionalAuthToken: "pat-token")

        XCTAssertEqual(MockURLProtocol.requestedAuthorizations, ["Bearer pat-token", "Bearer pat-token"])
    }


    func testFetchAuthenticatedLoginUsesTheSuppliedTokenNotTheAmbientOne() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GitHubClient(session: session, optionalTokenProvider: { "ambient-oauth" })

        MockURLProtocol.responses = [
            "/user": MockURLProtocol.Response(data: Data(#"{"login":"jazzyalex","id":1}"#.utf8))
        ]

        let login = try await client.fetchAuthenticatedLogin(token: "pat-token")

        XCTAssertEqual(login, "jazzyalex")
        // Validation must exercise the token being validated, or it would report
        // the OAuth token's identity and call a broken PAT healthy.
        XCTAssertEqual(MockURLProtocol.requestedAuthorizations, ["Bearer pat-token"])
    }


    func testFetchAccessiblePrivateReposUsesThePATAndMarksThemPrivate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        // The OAuth scope is public_repo and cannot see private repos, so this
        // must go out on the PAT, not the ambient token.
        let client = GitHubClient(session: session, optionalTokenProvider: { "ambient-oauth" })

        MockURLProtocol.responses = [
            "/user/repos?visibility=private&affiliation=owner,collaborator&sort=updated&per_page=100":
                MockURLProtocol.Response(
                    data: Data(#"[{"id":9,"name":"Triada","full_name":"jazzyalex/Triada","owner":{"login":"jazzyalex"},"private":true}]"#.utf8)
                )
        ]

        let repos = try await client.fetchAccessiblePrivateRepos(token: "pat-token")

        XCTAssertEqual(repos.map(\.fullName), ["jazzyalex/Triada"])
        XCTAssertTrue(repos[0].isPrivate)
        XCTAssertEqual(MockURLProtocol.requestedAuthorizations, ["Bearer pat-token"])
    }

    func testPublicRepoSummariesDecodeAsNotPrivate() throws {
        // The public listing omits nothing, but older fixtures have no "private"
        // key — those must decode as public rather than throwing.
        let data = Data(#"[{"id":1,"name":"one","full_name":"owner/one","owner":{"login":"owner"}}]"#.utf8)
        let repos = try JSONDecoder().decode([GitHubRepoSummary].self, from: data)
        XCTAssertFalse(repos[0].isPrivate)
    }


    func testCrossBranchCommitsFollowPagesRatherThanCappingAt100() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-06-14T12:00:00Z")!
        let since = formatter.date(from: "2026-06-13T12:00:00Z")!

        func page(_ shas: [String]) -> Data {
            Data(("[" + shas.map { #"{"sha":"\#($0)","commit":{"author":{"date":"2026-06-14T09:00:00Z"}}}"# }.joined(separator: ",") + "]").utf8)
        }

        MockURLProtocol.responses = [
            "/repos/o/n/activity?time_period=day&per_page=100": MockURLProtocol.Response(
                data: Data(#"[{"activity_type":"push","ref":"refs/heads/main","timestamp":"2026-06-14T09:00:00Z"}]"#.utf8)
            ),
            // A full page means "there may be more" — and there is.
            "/repos/o/n/commits?sha=main&since=2026-06-13T12:00:00Z&per_page=100": MockURLProtocol.Response(
                headers: ["Link": #"<https://api.github.com/repos/o/n/commits?sha=main&since=2026-06-13T12:00:00Z&per_page=100&page=2>; rel="next""#],
                data: page((1...100).map { "sha\($0)" })
            ),
            "/repos/o/n/commits?sha=main&since=2026-06-13T12:00:00Z&per_page=100&page=2": MockURLProtocol.Response(
                data: page((101...137).map { "sha\($0)" })
            )
        ]

        let dates = await client.fetchCrossBranchCommitDates(owner: "o", name: "n", since: since, now: now)

        // Without following the Link header this reports exactly 100: a number
        // that looks plausible and is simply wrong.
        XCTAssertEqual(dates?.count, 137)
    }


    func testBranchNameKeepsSlashesInsteadOfTakingTheLastComponent() {
        // Taking the last path component turned refs/heads/feature/foo into
        // "foo", which is not a branch: the commits API answers 422, the whole
        // fetch collapses to nil, and the chart keeps stale data under a fresh
        // timestamp. Slashes in branch names are the norm.
        XCTAssertEqual(GitHubClient.branchName(fromRef: "refs/heads/main"), "main")
        XCTAssertEqual(GitHubClient.branchName(fromRef: "refs/heads/feature/private-repos"), "feature/private-repos")
        XCTAssertEqual(GitHubClient.branchName(fromRef: "refs/heads/release/0.6"), "release/0.6")
        XCTAssertEqual(GitHubClient.branchName(fromRef: "refs/heads/dependabot/swift/foo"), "dependabot/swift/foo")
        // Tags and other refs aren't branches and must not be walked.
        XCTAssertNil(GitHubClient.branchName(fromRef: "refs/tags/v1.0"))
        XCTAssertNil(GitHubClient.branchName(fromRef: "refs/heads/"))
    }

    func testPublicRadarUsesTheCheapDefaultBranchCountNotTheBranchWalk() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-06-14T12:00:00Z")!

        MockURLProtocol.responses = [
            "/search/issues?q=repo:owner/repo%20is:pr%20is:open&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/search/issues?q=repo:owner/repo%20is:issue%20is:open%20comments:0&per_page=1": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8)
            ),
            "/repos/owner/repo/actions/runs?per_page=20": MockURLProtocol.Response(
                data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
            )
        ]

        _ = await client.fetchMaintainerRadar(owner: "owner", name: "repo", activityWindow: .off, now: now)

        // The branch walk costs /activity plus up to 20 commit pages per active
        // ref, sequentially. A public repo's headline is stars; it must not pay.
        XCTAssertFalse(MockURLProtocol.requestedPaths.contains { $0.contains("/activity") },
                       "public repos must not walk branches: \(MockURLProtocol.requestedPaths)")
    }

    func testCrossBranchWalkCapsTheNumberOfBranches() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-06-14T12:00:00Z")!
        let since = formatter.date(from: "2026-06-13T12:00:00Z")!

        // /activity can report up to 100 distinct refs. At 20 pages each that is
        // 2,000 sequential requests for one repo, which would exhaust the budget
        // and stall every repo after it.
        let refs = (1...40).map { #"{"activity_type":"push","ref":"refs/heads/b\#($0)","timestamp":"2026-06-14T09:00:00Z"}"# }
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/activity") {
                return .init(data: Data(("[" + refs.joined(separator: ",") + "]").utf8))
            }
            return .init(data: Data(#"[{"sha":"x","commit":{"author":{"date":"2026-06-14T09:00:00Z"}}}]"#.utf8))
        }

        _ = await client.fetchCrossBranchCommitDates(owner: "o", name: "n", since: since, now: now)

        let commitCalls = MockURLProtocol.requestedPaths.filter { $0.contains("/commits") }.count
        XCTAssertLessThanOrEqual(commitCalls, GitHubClient.commitRefLimit,
                                 "walked \(commitCalls) branches; cap is \(GitHubClient.commitRefLimit)")
    }

}
