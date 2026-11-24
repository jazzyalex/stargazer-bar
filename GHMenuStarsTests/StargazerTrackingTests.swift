import XCTest
@testable import GHMenuStars

final class StargazerTrackingTests: XCTestCase {
    private let repo = "/repos/owner/repo"
    private let scope = StargazerScope(repositoryID: 91, viewerID: 7, credentialSource: "oauth", visibility: "public")

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testBaselineRenameRemovalAndRestart() throws {
        let store = makeStore()
        let repoID = UUID()
        let first = snapshot(1, [(1, "original"), (2, "second")])
        XCTAssertTrue(try store.accept(first, repository: "owner/repo", repoID: repoID).events.isEmpty)
        let rename = snapshot(2, [(1, "renamed"), (2, "second"), (3, "addition")])
        XCTAssertTrue(try store.accept(rename, repository: "owner/repo", repoID: repoID).events.isEmpty)
        let after = snapshot(3, [(2, "second"), (3, "addition"), (4, "same-count")])
        let stored = try store.accept(after, repository: "owner/repo", repoID: repoID)
        XCTAssertEqual(stored.events.count, 1)
        XCTAssertEqual(stored.events.first?.account, rename.accounts.first)
        XCTAssertEqual(stored.events.first?.missingAt, after.completedAt)
        XCTAssertEqual(try StargazerHistoryStore(directory: store.directory).read(repoID), stored)
        let returns = snapshot(4, [(1, "renamed"), (2, "second"), (3, "addition"), (4, "same-count")])
        _ = try store.accept(returns, repository: "owner/repo", repoID: repoID)
        let disappearsAgain = snapshot(5, [(2, "second"), (3, "addition"), (4, "same-count")])
        XCTAssertEqual(try store.accept(disappearsAgain, repository: "owner/repo", repoID: repoID).events.count, 2)
    }

    @MainActor
    func testAContinuityBreakAndRepositoryReplacementCreateNewBaselines() throws {
        let store = makeStore()
        let repoID = UUID()
        _ = try store.accept(snapshot(1, [(1, "original")]), repository: "owner/repo", repoID: repoID)
        try store.markContinuityBreak(repoID)
        XCTAssertTrue(try StargazerHistoryStore(directory: store.directory).read(repoID)?.continuityBroken == true)
        let restored = try store.accept(snapshot(2, [(2, "visible")]), repository: "owner/repo", repoID: repoID)
        XCTAssertTrue(restored.events.isEmpty)
        let replacement = StargazerScope(repositoryID: 92, viewerID: 7, credentialSource: "oauth", visibility: "public")
        XCTAssertTrue(try store.accept(snapshot(3, [], scope: replacement), repository: "owner/repo", repoID: repoID).events.isEmpty)
    }

    @MainActor
    func testStoreRejectsStaleDuplicateAndCorruptRecords() throws {
        let store = makeStore()
        let repoID = UUID()
        let stored = try store.accept(snapshot(2, [(1, "one")]), repository: "owner/repo", repoID: repoID)
        XCTAssertThrowsError(try store.accept(snapshot(1, []), repository: "owner/repo", repoID: repoID))
        XCTAssertThrowsError(try store.accept(snapshot(3, [(1, "one"), (1, "two")]), repository: "owner/repo", repoID: repoID))
        XCTAssertEqual(try store.read(repoID), stored)
        let url = store.directory.appendingPathComponent(repoID.uuidString).appendingPathExtension("json")
        let corrupt = Data("unsupported".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.accept(snapshot(4, []), repository: "owner/repo", repoID: repoID))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testMultiPageWalkUsesNumericLinksAndTwoMatchingPassesWithPinnedToken() async throws {
        let client = makeClient()
        let second = "/repositories/91/stargazers?per_page=100&page=2"
        MockURLProtocol.responses = [
            repo: response(repoBody(count: 101)),
            repo + "/stargazers?per_page=100": response(entries(1...100), headers: ["Link": link(second)]),
            second: response(entries(101...101))
        ]
        let observed = try await observe(client, count: 101)
        XCTAssertEqual(observed.snapshot.accounts.map(\.id).sorted(), Array(1...101).map(Int64.init))
        XCTAssertEqual(MockURLProtocol.requestedPaths, [repo + "/stargazers?per_page=100", second,
                         repo + "/stargazers?per_page=100", second, repo])
        XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer pinned" })
    }

    func testChangedMembershipBetweenPassesRejectsEqualCount() async throws {
        let client = makeClient()
        let second = repo + "/stargazers?per_page=100&page=2"
        MockURLProtocol.handler = { [self] request in
            if request.url?.query?.contains("page=2") == true {
                let id = MockURLProtocol.requestedPaths.filter { $0 == second }.count == 1 ? 101 : 102
                return response(entries(id...id))
            }
            return response(entries(1...100), headers: ["Link": link(second)])
        }
        do {
            _ = try await observe(client, count: 101)
            XCTFail("A changing list must be rejected.")
        } catch StargazerCheckError.inconsistent {}
        XCTAssertEqual(MockURLProtocol.requestedPaths.count, 4)
    }

    func testStableTerminalCountMismatchReturnsTheSameListAcrossBothPasses() async throws {
        let second = "/repositories/91/stargazers?per_page=100&page=2"
        MockURLProtocol.responses = [
            repo: response(repoBody(count: 102)),
            repo + "/stargazers?per_page=100": response(entries(1...100), headers: ["Link": link(second)]),
            second: response(entries(101...101))
        ]
        let observation = try await observe(makeClient(), count: 102)
        XCTAssertEqual(observation.reportedCount, 102)
        XCTAssertEqual(observation.snapshot.accounts.map(\.id).sorted(), Array(1...101).map(Int64.init))
        XCTAssertEqual(MockURLProtocol.requestedPaths.filter { $0 == second }.count, 2)
    }

    func testMalformedPaginationPartialPageAndThrottleStopWithoutAnotherRequest() async throws {
        let first = repo + "/stargazers?per_page=100"
        let cases = [
            response(entries(1...100)),
            response(entries(1...100), headers: ["Link": link(first + "&page=3")]),
            response(entries(1...100), headers: ["Link": "<https://example.com/stargazers?per_page=100&page=2>; rel=\"next\""]),
            response(entries(1...100), status: 206),
            response(entries(1...100), status: 304),
            response([], status: 429, headers: ["Retry-After": "120"]),
            response([], status: 401),
            response([], headers: ["X-RateLimit-Remaining": "0"])
        ]
        for fixture in cases {
            MockURLProtocol.reset()
            let client = makeClient()
            MockURLProtocol.responses[first] = fixture
            do {
                _ = try await observe(client, count: 101)
                XCTFail("An incomplete first response must terminate the walk.")
            } catch {}
            XCTAssertEqual(MockURLProtocol.requestedPaths, [first])
        }
    }

    func testEmptyListRequiresZeroCountAndVerifiedAccess() async throws {
        let client = makeClient()
        MockURLProtocol.responses = [repo: response(repoBody(count: 0, owner: 22)),
                                     repo + "/stargazers?per_page=100": response([])]
        do {
            _ = try await observe(client, count: 1)
            XCTFail("An empty body with a nonzero expected count is incomplete.")
        } catch StargazerCheckError.inconsistent {}
        do {
            _ = try await observe(client, count: 0, directory: false)
            XCTFail("An empty response cannot prove list access.")
        } catch StargazerCheckError.accessUnverified {}
        let verified = try await observe(client, count: 0, directory: true)
        XCTAssertTrue(verified.snapshot.accounts.isEmpty)
    }

    @MainActor
    func testPollFailurePreservesBaselineAndSubsequentCheckUsesLastAcceptedSnapshot() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let tracked = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        try repoStore.upsertTrackedRepo(tracked)
        let client = makeClient()
        let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { "pinned" })
        let store = makeStore()
        let tracking = StargazerTrackingService(store: store, client: client, repoStore: repoStore, access: access)
        let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let polling = RepoPollingService(repoStore: repoStore, settingsStore: settings, gitHubClient: client,
            repoAccess: access, notificationService: NotificationService(), soundService: SoundService(),
            animationCoordinator: AnimationCoordinator(), stargazerTracking: tracking)
        MockURLProtocol.responses = [
            repo: response(repoBody(count: 1)),
            repo + "/releases?per_page=100": response([]),
            "/user": response(["id": 7, "login": "owner"]),
            repo + "/stargazers?per_page=100": response(entries(1...1)),
            repo + "/forks?per_page=100": response([])
        ]
        await polling.refresh(repo: tracked)
        let baseline = try XCTUnwrap(store.read(tracked.id))
        XCTAssertEqual(baseline.snapshot.accounts.map(\.id), [1])
        XCTAssertEqual(MockURLProtocol.requestedPaths.filter { $0 == repo + "/stargazers?per_page=100" }.count, 1)

        MockURLProtocol.responses[repo + "/stargazers?per_page=100"] = response([], status: 500)
        await polling.refresh(repo: tracked)
        XCTAssertEqual(try store.read(tracked.id), baseline)
        XCTAssertNotNil(tracking.entries[tracked.id]?.issue)
        XCTAssertEqual(repoStore.trackedRepos.first?.lastStars, 1)
        XCTAssertNil(repoStore.trackedRepos.first?.lastRefreshFailure)

        MockURLProtocol.responses[repo + "/stargazers?per_page=100"] = response(entries(2...2))
        await polling.refresh(repo: tracked)
        let event = try XCTUnwrap(store.read(tracked.id)?.events.first)
        XCTAssertEqual(event.account, baseline.snapshot.accounts.first)
        repoStore.removeTrackedRepo(id: tracked.id)
        XCTAssertNil(try store.read(tracked.id))
        XCTAssertNil(tracking.entries[tracked.id])
    }

    @MainActor
    func testIdentityFailureDoesNotPreventTrendBackfill() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let tracked = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        try repoStore.upsertTrackedRepo(tracked)
        let client = makeClient()
        let access = GitHubRepoAccess(client: client, ambientProvider: { "pinned" })
        let history = makeStore()
        let tracking = StargazerTrackingService(store: history, client: client, repoStore: repoStore, access: access)
        let polling = RepoPollingService(repoStore: repoStore, settingsStore: SettingsStore(defaults: defaults, legacyDefaults: nil),
            gitHubClient: client, repoAccess: access, notificationService: NotificationService(),
            soundService: SoundService(), animationCoordinator: AnimationCoordinator(), stargazerTracking: tracking)
        let starredAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        MockURLProtocol.responses = [
            repo: response(repoBody(count: 1)),
            repo + "/releases?per_page=100": response([]),
            "/user": response(["id": 7, "login": "owner"]),
            repo + "/stargazers?per_page=100": response([["starred_at": starredAt]]),
            repo + "/forks?sort=newest&per_page=100": response([])
        ]
        await polling.refresh(repo: tracked)

        XCTAssertNil(try history.read(tracked.id))
        XCTAssertNotNil(tracking.entries[tracked.id]?.issue)
        let updated = try XCTUnwrap(repoStore.trackedRepos.first)
        XCTAssertEqual(updated.lastStars, 1)
        XCTAssertEqual(updated.trendRange, .all)
        XCTAssertFalse(updated.trendPoints.isEmpty)
    }

    @MainActor
    func testCountMismatchShowsLiveAccountsWithoutWritingBaselineOrHistory() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let tracked = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        try repoStore.upsertTrackedRepo(tracked)
        let client = makeClient()
        let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { "pinned" })
        let store = makeStore()
        let tracking = StargazerTrackingService(store: store, client: client, repoStore: repoStore, access: access)
        let stargazerPath = repo + "/stargazers?per_page=100"
        MockURLProtocol.responses = [
            repo: response(repoBody(count: 3)),
            "/user": response(["id": 7, "login": "owner"]),
            "/user/3": response(["id": 3, "login": "user-3", "bio": "Visible in the returned list"]),
            stargazerPath: response(entries(3...4))
        ]

        _ = await tracking.verify(repo: tracked, metadata: nil, token: "pinned", generation: 0, rate: nil, manual: true)
        XCTAssertNil(try store.read(tracked.id))
        XCTAssertNil(tracking.entries[tracked.id]?.history)
        XCTAssertEqual(tracking.entries[tracked.id]?.displayedSnapshot?.accounts.map(\.id), [3, 4])
        XCTAssertEqual(tracking.entries[tracked.id]?.countMismatch?.reportedCount, 3)
        XCTAssertFalse(MockURLProtocol.requestedPaths.contains("/graphql"))
        XCTAssertEqual(MockURLProtocol.requestedPaths.filter { $0 == stargazerPath }.count, 2)
        await tracking.loadProfiles([3], repoID: tracked.id)
        XCTAssertEqual(tracking.profiles[3]?.bio, "Visible in the returned list")

        let offset = Date().timeIntervalSince1970 / 10
        _ = try store.accept(snapshot(offset - 2, [(1, "one"), (2, "two"), (9, "nine")]),
                             repository: "owner/repo", repoID: tracked.id)
        let saved = try store.accept(snapshot(offset - 1, [(1, "one"), (2, "two")]),
                                     repository: "owner/repo", repoID: tracked.id)
        let storedFile = store.directory.appendingPathComponent(tracked.id.uuidString).appendingPathExtension("json")
        let savedBytes = try Data(contentsOf: storedFile)
        _ = await tracking.verify(repo: tracked, metadata: nil, token: "pinned", generation: 0, rate: nil, manual: true)
        XCTAssertEqual(tracking.entries[tracked.id]?.history, saved)
        XCTAssertEqual(tracking.entries[tracked.id]?.displayedSnapshot?.accounts.map(\.id), [3, 4])
        XCTAssertEqual(try Data(contentsOf: storedFile), savedBytes)

        MockURLProtocol.responses[repo] = response(repoBody(count: 2))
        MockURLProtocol.responses[stargazerPath] = response(entries(2...3))
        _ = await tracking.verify(repo: tracked, metadata: nil, token: "pinned", generation: 0, rate: nil, manual: true)
        XCTAssertNil(tracking.entries[tracked.id]?.countMismatch)
        let recovered = try XCTUnwrap(store.read(tracked.id))
        XCTAssertEqual(recovered.snapshot.accounts.map(\.id), [2, 3])
        XCTAssertEqual(recovered.events.map(\.account.id), [1, 9])
    }

    @MainActor
    func testAgentSessionsFallbackRequiresMatchingIDsAndCompleteHistoryBeforeEverySavedCheck() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let tracked = TrackedRepo(owner: "jazzyalex", name: "agent-sessions", source: .manual)
        try repoStore.upsertTrackedRepo(tracked)
        let client = makeClient()
        let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { "pinned" })
        let store = makeStore()
        let tracking = StargazerTrackingService(store: store, client: client, repoStore: repoStore, access: access)
        let path = "/repos/jazzyalex/agent-sessions"
        let historyPath = path + "/stargazers/history?per_page=30"
        let listPath = path + "/stargazers?per_page=100"
        let week = Int(Date().timeIntervalSince1970) - 60
        let createdAt = Date(timeIntervalSince1970: TimeInterval(week - 604_770))
        var metadata = agentSessionsMetadata(count: 2, createdAt: createdAt)
        let fullHistory = [historyWeek(week, total: 1), historyWeek(week - 604_800, total: 1)]
        MockURLProtocol.responses = [
            path: response(metadata), listPath: response(entries(1...2)),
            "/user": response(["id": 7, "login": "owner"]),
            "/graphql": response(agentSessionsGraph(count: 2, ids: [1, 3])),
            historyPath: response(fullHistory)
        ]
        MockURLProtocol.handler = { request in
            if request.url?.path == "/graphql" { XCTAssertEqual(request.httpMethod, "POST") }
            return nil
        }
        func refresh() async {
            _ = await tracking.verify(repo: tracked, metadata: nil, token: "pinned", generation: 0, rate: nil, manual: true)
        }

        await refresh()
        XCTAssertNil(try store.read(tracked.id), "Headline agreement alone cannot establish a baseline.")
        XCTAssertTrue(MockURLProtocol.requestedPaths.contains("/graphql"))
        XCTAssertFalse(MockURLProtocol.requestedPaths.contains(historyPath))

        metadata["stargazers_count"] = 3
        MockURLProtocol.responses[path] = response(metadata)
        MockURLProtocol.responses["/graphql"] = response(agentSessionsGraph(count: 3, ids: [1, 3]))
        await refresh()
        XCTAssertNil(try store.read(tracked.id))
        XCTAssertFalse(MockURLProtocol.requestedPaths.contains(historyPath))
        XCTAssertEqual(tracking.entries[tracked.id]?.displayedSnapshot?.accounts.map(\.id), [1, 2])

        var partialGraph = agentSessionsGraph(count: 3, ids: [2, 1])
        partialGraph["errors"] = [["message": "Partial response"]]
        MockURLProtocol.responses["/graphql"] = response(partialGraph)
        await refresh()
        XCTAssertNil(try store.read(tracked.id))
        XCTAssertFalse(MockURLProtocol.requestedPaths.contains(historyPath))

        MockURLProtocol.responses["/graphql"] = response(agentSessionsGraph(count: 3, ids: [2, 1]))
        MockURLProtocol.responses[historyPath] = response([historyWeek(week, total: 2)])
        await refresh()
        XCTAssertNil(try store.read(tracked.id), "A correct sum in truncated history is insufficient.")
        MockURLProtocol.responses[historyPath] = response([historyWeek(week, total: 1), historyWeek(week - 604_800, total: 0)])
        await refresh()
        XCTAssertNil(try store.read(tracked.id), "Complete history with the wrong total is insufficient.")

        MockURLProtocol.responses[historyPath] = response(fullHistory)
        await refresh()
        let baseline = try XCTUnwrap(try store.read(tracked.id))
        XCTAssertEqual(baseline.snapshot.accounts.map(\.id), [1, 2])
        XCTAssertEqual(baseline.snapshot.reportedStarCount, 3)
        XCTAssertTrue(baseline.events.isEmpty)
        XCTAssertNil(tracking.entries[tracked.id]?.countMismatch)
        let file = store.directory.appendingPathComponent(tracked.id.uuidString).appendingPathExtension("json")
        let baselineBytes = try Data(contentsOf: file)

        metadata["stargazers_count"] = 2
        MockURLProtocol.responses[path] = response(metadata)
        MockURLProtocol.responses[listPath] = response(entries(2...3))
        MockURLProtocol.responses["/graphql"] = response(agentSessionsGraph(count: 2, ids: [1, 2]))
        await refresh()
        XCTAssertEqual(try Data(contentsOf: file), baselineBytes, "Headline agreement alone cannot replace a corroborated baseline.")
        XCTAssertEqual(tracking.entries[tracked.id]?.history, baseline)

        MockURLProtocol.responses["/graphql"] = response(agentSessionsGraph(count: 2, ids: [3, 2]))
        await refresh()
        let later = try XCTUnwrap(try store.read(tracked.id))
        XCTAssertEqual(later.snapshot.reportedStarCount, 2)
        XCTAssertEqual(later.snapshot.accounts.map(\.id), [2, 3])
        XCTAssertEqual(later.events.map(\.account.id), [1])
        XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer pinned" })
    }

    func testAgentSessionsConsumesAllGraphQLAndHistoryPages() async throws {
        let count = 101
        let checked = Date()
        let scope = StargazerScope(repositoryID: GitHubClient.agentSessionsRepositoryID, viewerID: 7,
                                  credentialSource: "oauth", visibility: "public")
        let snapshot = StargazerSnapshot(scope: scope, startedAt: checked, completedAt: checked,
            accounts: (1...count).map { StargazerAccount(id: Int64($0), login: "user-\($0)", seenAt: checked) })
        let observation = GitHubClient.StargazerObservation(snapshot: snapshot, dates: [],
                                                          repository: "jazzyalex/agent-sessions", reportedCount: 102)
        let week = Int(checked.timeIntervalSince1970) - 60
        let oldest = week - 30 * 604_800
        let createdAt = Date(timeIntervalSince1970: TimeInterval(oldest + 30))
        let path = "/repos/jazzyalex/agent-sessions"
        let historyPath = path + "/stargazers/history?per_page=30"
        let next = "/repositories/\(scope.repositoryID)/stargazers/history?per_page=30&page=2"
        let firstWeeks = (0..<30).map { historyWeek(week - $0 * 604_800, total: $0 == 0 ? 100 : 0) }
        MockURLProtocol.responses = [
            path: response(agentSessionsMetadata(count: 102, createdAt: createdAt)),
            historyPath: response(firstWeeks, headers: ["Link": link(next)]), next: response([historyWeek(oldest, total: 1)])
        ]
        MockURLProtocol.handler = { [self] request in
            guard request.url?.path == "/graphql" else { return nil }
            let first = MockURLProtocol.requestedPaths.filter { $0 == "/graphql" }.count == 1
            return response(agentSessionsGraph(count: 102, ids: first ? Array(1...100) : [101],
                                               nextCursor: first ? "next-cursor" : nil))
        }
        let verified = try await makeClient().corroborateAgentSessionsStargazers(observation, createdAt: createdAt, token: "pinned")
        XCTAssertEqual(verified.accounts.count, count)
        XCTAssertEqual(verified.reportedStarCount, 102)
        XCTAssertEqual(MockURLProtocol.requestedPaths, ["/graphql", "/graphql", historyPath, next, path])
    }

    func testAuthorTotalAndPublishedLinks() async throws {
        let client = makeClient()
        MockURLProtocol.responses = [
            "/user/11": response(["id": 11, "login": "renamed", "public_repos": 2,
                                 "blog": "example.com", "twitter_username": "profile_handle"]),
            "/users/renamed/repos?type=owner&per_page=100": response([
                ["id": 31, "owner": ["id": 11], "private": false, "stargazers_count": 7],
                ["id": 32, "owner": ["id": 11], "private": false, "stargazers_count": 5]
            ]),
            "/users/renamed/social_accounts?per_page=100": response([
                ["url": "https://www.linkedin.com/in/example"],
                ["url": "https://twitter.com/profile_handle"],
                ["url": "https://username:password@example.com"]
            ])
        ]
        let author = try await client.fetchStargazerAuthor(id: 11, token: "pinned")
        let total = try await client.fetchStarsReceived(author: author, token: "pinned")
        XCTAssertEqual(total, 12)
        let links = try await client.fetchStargazerSocialLinks(author: author, token: "pinned")
        XCTAssertEqual(StargazerProfileLink.unique(author.profileLinks + links).map(\.label), ["GitHub", "X", "Website", "LinkedIn"])
        MockURLProtocol.responses["/users/renamed/repos?type=owner&per_page=100"] = response([])
        do {
            _ = try await client.fetchStarsReceived(author: author, token: "pinned")
            XCTFail("A partial aggregation cannot produce a total.")
        } catch StargazerCheckError.inconsistent {}
    }

    @MainActor
    func testPageLoadsPublicSubtitlesWithoutLoadingEveryAuthorTotalOrSocialList() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let tracked = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        try repoStore.upsertTrackedRepo(tracked)
        let client = makeClient()
        let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { "pinned" })
        let tracking = StargazerTrackingService(store: makeStore(), client: client, repoStore: repoStore, access: access)
        MockURLProtocol.responses = [
            repo: response(repoBody(count: 3)),
            "/user": response(["id": 7, "login": "owner"]),
            repo + "/stargazers?per_page=100": response(entries(1...3)),
            "/user/1": response(["id": 1, "login": "user-1", "name": "First Author"]),
            "/user/2": response(["id": 2, "login": "user-2", "bio": "Builds small apps"])
        ]
        _ = await tracking.verify(repo: tracked, metadata: nil, token: "pinned", generation: 0, rate: nil, manual: false)
        await tracking.loadProfiles([1, 2], repoID: tracked.id)
        await tracking.loadProfiles([1, 2], repoID: tracked.id)
        XCTAssertEqual(tracking.profiles[1]?.name, "First Author")
        XCTAssertEqual(tracking.profiles[2]?.bio, "Builds small apps")
        XCTAssertNil(tracking.profiles[3])
        XCTAssertTrue(tracking.totals.isEmpty)
        XCTAssertTrue(tracking.socialLinks.isEmpty)
        XCTAssertEqual(MockURLProtocol.requestedPaths.filter { $0.hasPrefix("/user/") }, ["/user/1", "/user/2"])
    }

    @MainActor
    func testPrivateRepositoryUsesExistingPATAndShowsStargazersInItsMenu() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let tracked = TrackedRepo(owner: "owner", name: "repo", source: .manual, isPrivate: true)
        try repoStore.upsertTrackedRepo(tracked)
        let client = makeClient()
        let access = GitHubRepoAccess(client: client, patProvider: { "private-token" }, ambientProvider: { "oauth" },
                                      hasStoredPAT: { true })
        let tracking = StargazerTrackingService(store: makeStore(), client: client, repoStore: repoStore, access: access)
        let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let animation = AnimationCoordinator()
        let updater = UpdaterController()
        let polling = RepoPollingService(repoStore: repoStore, settingsStore: settings, gitHubClient: client,
            repoAccess: access, notificationService: NotificationService(), soundService: SoundService(),
            animationCoordinator: animation, stargazerTracking: tracking)
        var metadata = repoBody(count: 1)
        metadata["private"] = true
        MockURLProtocol.responses = [repo: response(metadata), "/user": response(["id": 7, "login": "owner"]),
            repo + "/releases?per_page=100": response([]), repo + "/stargazers?per_page=100": response(entries(1...1))]
        await polling.refresh(repo: tracked)
        XCTAssertEqual(tracking.entries[tracked.id]?.history?.snapshot.scope.credentialSource, "pat")
        XCTAssertEqual(tracking.entries[tracked.id]?.history?.snapshot.accounts.count, 1)
        XCTAssertEqual(repoStore.trackedRepos.first?.lastStars, 0)
        XCTAssertTrue(MockURLProtocol.requestedAuthorizations.allSatisfy { $0 == "Bearer private-token" })
        let controller = StatusItemController(repoStore: repoStore, settingsStore: settings, pollingService: polling,
                                             updaterController: updater, animationCoordinator: animation)
        let menu = StatusMenuBuilder(repoStore: repoStore, settingsStore: settings, pollingService: polling,
                                     updaterController: updater).build(target: controller)
        let stargazers = menu.items.first?.submenu?.items.first { $0.title == "Stargazers…" }
        XCTAssertEqual(stargazers?.representedObject as? UUID, tracked.id)
    }

    private func snapshot(_ index: Double, _ ids: [(Int64, String)], scope: StargazerScope? = nil) -> StargazerSnapshot {
        let start = Date(timeIntervalSince1970: index * 10)
        return StargazerSnapshot(scope: scope ?? self.scope, startedAt: start, completedAt: start.addingTimeInterval(2),
            accounts: ids.map { StargazerAccount(id: $0.0, login: $0.1, seenAt: start.addingTimeInterval(1)) })
    }

    @MainActor
    private func makeStore() -> StargazerHistoryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return StargazerHistoryStore(directory: directory)
    }

    private func makeClient() -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return GitHubClient(session: URLSession(configuration: configuration))
    }

    private func observe(_ client: GitHubClient, count: Int, directory: Bool = false) async throws -> GitHubClient.StargazerObservation {
        let metadata = GitHubHTTPResult(
            value: GitHubRepoResponse(fullName: "owner/repo", stargazersCount: count, forksCount: 0, private: false, id: 91),
            etag: nil, rateLimitState: nil, nextPagePath: nil, lastPagePath: nil
        )
        return try await client.observeStargazers(metadata: metadata, viewerID: 7, credentialSource: "oauth",
                                                 token: "pinned", verifyDirectoryAccess: { _, _ in directory })
    }

    private func response(_ body: Any, status: Int = 200, headers: [String: String] = [:]) -> MockURLProtocol.Response {
        MockURLProtocol.Response(statusCode: status, headers: headers, data: try! JSONSerialization.data(withJSONObject: body))
    }

    private func entries(_ ids: ClosedRange<Int>) -> [[String: Any]] {
        ids.map { ["user": ["id": $0, "login": "user-\($0)"], "starred_at": "2026-11-23T00:00:00Z"] }
    }

    private func repoBody(count: Int, owner: Int = 7) -> [String: Any] {
        ["id": 91, "full_name": "owner/repo", "stargazers_count": count, "forks_count": 0,
         "private": false, "owner": ["id": owner]]
    }

    private func agentSessionsMetadata(count: Int, createdAt: Date) -> [String: Any] {
        var body = repoBody(count: count)
        body["id"] = GitHubClient.agentSessionsRepositoryID
        body["full_name"] = "jazzyalex/agent-sessions"
        body["visibility"] = "public"
        body["created_at"] = ISO8601DateFormatter().string(from: createdAt)
        return body
    }

    private func agentSessionsGraph(count: Int, ids: [Int], nextCursor: String? = nil) -> [String: Any] {
        let page: [String: Any] = ["hasNextPage": nextCursor != nil, "endCursor": nextCursor as Any? ?? NSNull()]
        let stargazers: [String: Any] = ["totalCount": count, "nodes": ids.map { ["databaseId": $0] }, "pageInfo": page]
        let repository: [String: Any] = ["databaseId": GitHubClient.agentSessionsRepositoryID, "nameWithOwner": "jazzyalex/agent-sessions",
            "visibility": "PUBLIC", "viewerPermission": "ADMIN", "stargazerCount": count, "stargazers": stargazers]
        return ["data": ["viewer": ["databaseId": 7], "repository": repository]]
    }

    private func historyWeek(_ start: Int, total: Int) -> [String: Any] {
        ["week": start, "total": total, "days": [total, 0, 0, 0, 0, 0, 0]]
    }

    private func link(_ path: String) -> String {
        "<https://api.github.com\(path)>; rel=\"next\""
    }
}
