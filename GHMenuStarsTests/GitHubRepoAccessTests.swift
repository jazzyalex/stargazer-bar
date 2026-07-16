import XCTest
@testable import GHMenuStars

@MainActor
final class GitHubRepoAccessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        // MockURLProtocol's state is static and shared across every test class.
        // Without this, a `handler` set here leaks into whichever class runs
        // next and hijacks its stubbed responses — a failure that only appears
        // in the full suite, never in isolation.
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Builds a real GitHubClient over a stubbed URLSession, so the true request
    /// path is exercised rather than a mock of it.
    private func makeAccess(pat: String?, ambient: String?) -> GitHubRepoAccess {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return GitHubRepoAccess(
            client: GitHubClient(session: URLSession(configuration: configuration)),
            patProvider: { pat },
            ambientProvider: { ambient }
        )
    }

    private func repoBody(isPrivate: Bool) -> Data {
        Data("{\"full_name\":\"o/n\",\"stargazers_count\":0,\"forks_count\":0,\"private\":\(isPrivate)}".utf8)
    }

    private var tokens: [String] {
        MockURLProtocol.requestedAuthorizations.map { $0 ?? "<none>" }
    }

    // MARK: - Resolution rule

    func testPublicRepoUsesAmbientTokenAndReportsNotPrivate() async throws {
        MockURLProtocol.responses = ["/repos/o/n": .init(data: repoBody(isPrivate: false))]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())

        guard case .fetched(_, let isPrivate, let token) = outcome else { return XCTFail("expected .fetched") }
        XCTAssertFalse(isPrivate)
        XCTAssertEqual(token, "oauth")
        XCTAssertEqual(tokens, ["Bearer oauth"], "a known-public repo must not spend a PAT call")
    }

    func testUnknownPrivateRepo404sOnAmbientThenSucceedsOnPATAndLearnsItIsPrivate() async throws {
        var calls = 0
        MockURLProtocol.handler = { [self] _ in
            calls += 1
            // GitHub 404s (not 403s) for a private repo you cannot see, by design,
            // so privacy is only knowable from a fetch that succeeds.
            return calls == 1
                ? .init(statusCode: 404, data: Data("{}".utf8))
                : .init(data: repoBody(isPrivate: true))
        }
        let access = makeAccess(pat: "pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())

        guard case .fetched(_, let isPrivate, let token) = outcome else { return XCTFail("expected .fetched") }
        XCTAssertTrue(isPrivate, "isPrivate must come from the response body, not from what was stored")
        XCTAssertEqual(token, "pat")
        XCTAssertEqual(tokens, ["Bearer oauth", "Bearer pat"])
    }

    func testKnownPrivateRepoTriesPATFirst() async throws {
        MockURLProtocol.responses = ["/repos/o/n": .init(data: repoBody(isPrivate: true))]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())

        XCTAssertEqual(tokens, ["Bearer pat"], "a known-private repo must not waste a doomed ambient call")
    }

    func testPATOnlyUserUsesPATForPublicReposRatherThanAnonymous() async throws {
        // With no OAuth token, anonymous would put public repos on the 60/hr
        // per-IP bucket, and the global rate-limit gate would then starve the
        // private repos the PAT could still serve.
        MockURLProtocol.responses = ["/repos/o/n": .init(data: repoBody(isPrivate: false))]
        let access = makeAccess(pat: "pat", ambient: nil)

        _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())

        XCTAssertEqual(tokens, ["Bearer pat"])
    }

    func testNotModifiedCarriesTheTokenAndDoesNotThrow() async throws {
        MockURLProtocol.responses = ["/repos/o/n": .init(statusCode: 304, data: Data())]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: "e", knownPrivate: true, repoID: UUID())

        guard case .notModified(let token) = outcome else { return XCTFail("expected .notModified") }
        // 304 is the normal poll steady state; the releases and radar calls that
        // follow still need the identity that just worked.
        XCTAssertEqual(token, "pat")
    }

    func testRateLimited403PropagatesWithoutRetry() async {
        MockURLProtocol.responses = [
            "/repos/o/n": .init(
                statusCode: 403,
                headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "9999999999"],
                data: Data("{}".utf8)
            )
        ]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        do {
            _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())
            XCTFail("expected rateLimited to propagate")
        } catch GitHubError.rateLimited {
            // Retrying under rate limit only deepens the hole.
            XCTAssertEqual(tokens.count, 1)
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func testBothIdentities404Throws() async {
        MockURLProtocol.responses = ["/repos/o/n": .init(statusCode: 404, data: Data("{}".utf8))]
        let access = makeAccess(pat: "pat", ambient: "oauth")

        do {
            _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: UUID())
            XCTFail("expected notFoundOrPrivate")
        } catch GitHubError.notFoundOrPrivate {
            XCTAssertEqual(tokens, ["Bearer oauth", "Bearer pat"])
        } catch {
            XCTFail("expected notFoundOrPrivate, got \(error)")
        }
    }

    // MARK: - PAT-dead latch

    func testRevokedPATLatchesDeadAndFallsBackToAmbient() async throws {
        var calls = 0
        MockURLProtocol.handler = { [self] _ in
            calls += 1
            // A revoked PAT answers 401, not 404 — so the 404 ladder alone would
            // strand a repo that flipped private->public while the PAT was dead.
            if calls == 1 { return .init(statusCode: 401, data: Data("{}".utf8)) }
            return .init(data: repoBody(isPrivate: false))
        }
        let access = makeAccess(pat: "revoked-pat", ambient: "oauth")

        let outcome = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())

        guard case .fetched(_, let isPrivate, let token) = outcome else { return XCTFail("expected .fetched") }
        XCTAssertFalse(isPrivate)
        XCTAssertEqual(token, "oauth")
        XCTAssertEqual(tokens, ["Bearer revoked-pat", "Bearer oauth"])

        // The next poll must not retry the dead PAT: one call, not two.
        MockURLProtocol.requestedAuthorizations = []
        _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())
        XCTAssertEqual(tokens, ["Bearer oauth"], "a latched PAT must not be retried every poll")
    }

    func testResetTokenStateRevivesTheLatchedPAT() async throws {
        var failNextWith401 = true
        MockURLProtocol.handler = { [self] _ in
            if failNextWith401 {
                failNextWith401 = false
                return .init(statusCode: 401, data: Data("{}".utf8))
            }
            return .init(data: repoBody(isPrivate: true))
        }
        let access = makeAccess(pat: "pat", ambient: "oauth")

        _ = try? await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())
        XCTAssertTrue(access.isPATDead)

        // The user pasted a working token; without the reset they'd have to relaunch.
        access.resetTokenState()
        XCTAssertFalse(access.isPATDead)
        MockURLProtocol.requestedAuthorizations = []
        _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: true, repoID: UUID())
        XCTAssertEqual(tokens.first, "Bearer pat")
    }

    // MARK: - Double-404 latch

    func testMissingRepoStopsCostingTwoCallsPerPoll() async {
        MockURLProtocol.responses = ["/repos/o/gone": .init(statusCode: 404, data: Data("{}".utf8))]
        let access = makeAccess(pat: "pat", ambient: "oauth")
        let repoID = UUID()

        // The first poll pays the full ladder to learn the repo is unreachable.
        do { _ = try await access.fetchRepo(owner: "o", name: "gone", etag: nil, knownPrivate: false, repoID: repoID) }
        catch {}
        XCTAssertEqual(tokens, ["Bearer oauth", "Bearer pat"])

        // Every poll after costs one call, as it did before PATs existed.
        MockURLProtocol.requestedAuthorizations = []
        do { _ = try await access.fetchRepo(owner: "o", name: "gone", etag: nil, knownPrivate: false, repoID: repoID) }
        catch {}
        XCTAssertEqual(tokens, ["Bearer oauth"], "a missing repo must not burn a PAT retry every poll")

        // A new PAT may grant access the old one lacked, so the latch clears with it.
        access.resetTokenState()
        MockURLProtocol.requestedAuthorizations = []
        do { _ = try await access.fetchRepo(owner: "o", name: "gone", etag: nil, knownPrivate: false, repoID: repoID) }
        catch {}
        XCTAssertEqual(tokens, ["Bearer oauth", "Bearer pat"])
    }

    // MARK: - Composition

    func testPollingServiceAcceptsInjectedRepoAccess() {
        // Compile-level guard: the seam is useless until it reaches the poller.
        // If this stops compiling, the wiring regressed.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { nil })
        let service = RepoPollingService(
            repoStore: TrackedRepoStore(
                defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
                legacyDefaults: nil
            ),
            settingsStore: SettingsStore(
                defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
                legacyDefaults: nil
            ),
            gitHubClient: client,
            repoAccess: access,
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )
        XCTAssertTrue(service.repoAccess === access, "the poller must use the shared instance, not its own")
    }


    // MARK: - Polling

    func testPrivateRepoPollSkipsStarFetchesAndUsesPATEverywhere() async throws {
        var radarTokens: [String?] = []
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("search") || path.contains("commits") || path.contains("runs") {
                radarTokens.append(request.value(forHTTPHeaderField: "Authorization"))
            }
            if path == "/repos/o/n" {
                return .init(data: Data(#"{"full_name":"o/n","stargazers_count":0,"forks_count":0,"private":true}"#.utf8))
            }
            if path.contains("releases") { return .init(data: Data("[]".utf8)) }
            if path.contains("runs") {
                return .init(data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8))
            }
            return .init(data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let access = GitHubRepoAccess(client: client, patProvider: { "pat" }, ambientProvider: { "oauth" })
        let repoStore = TrackedRepoStore(
            defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
            legacyDefaults: nil
        )
        try repoStore.upsertTrackedRepo(TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true))
        let service = RepoPollingService(
            repoStore: repoStore,
            settingsStore: SettingsStore(
                defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
                legacyDefaults: nil
            ),
            gitHubClient: client,
            repoAccess: access,
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )

        // refresh(repo:) directly: both refreshNow() entries spawn a detached
        // Task and return, so awaiting them would race the work and assert
        // against an empty array — passing while testing nothing.
        await service.refresh(repo: repoStore.trackedRepos[0])

        XCTAssertFalse(MockURLProtocol.requestedPaths.contains { $0.contains("stargazers") },
                       "private repos have no stars worth spending a request on")
        XCTAssertFalse(MockURLProtocol.requestedPaths.contains { $0.contains("/forks") })
        XCTAssertFalse(radarTokens.isEmpty, "the radar must actually run for a private repo")
        // The whole feature: any radar call on the ambient token 404s and the
        // optional* wrappers turn it into a blank row with no error.
        XCTAssertTrue(radarTokens.allSatisfy { $0 == "Bearer pat" },
                      "radar used the wrong identity: \(radarTokens)")
        XCTAssertEqual(repoStore.trackedRepos[0].isPrivate, true)
    }

    func testPublicRepoPollStillFetchesStars() async throws {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/o/p" {
                return .init(data: Data(#"{"full_name":"o/p","stargazers_count":42,"forks_count":7,"private":false}"#.utf8))
            }
            if path.contains("releases") { return .init(data: Data("[]".utf8)) }
            if path.contains("stargazers") || path.contains("/forks") { return .init(data: Data("[]".utf8)) }
            if path.contains("runs") { return .init(data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)) }
            return .init(data: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: configuration))
        let access = GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { nil })
        let repoStore = TrackedRepoStore(
            defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
            legacyDefaults: nil
        )
        try repoStore.upsertTrackedRepo(TrackedRepo(owner: "o", name: "p", source: .manual))
        let service = RepoPollingService(
            repoStore: repoStore,
            settingsStore: SettingsStore(
                defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
                legacyDefaults: nil
            ),
            gitHubClient: client,
            repoAccess: access,
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )

        await service.refresh(repo: repoStore.trackedRepos[0])

        // Public tracking must be untouched by any of this.
        XCTAssertEqual(repoStore.trackedRepos[0].lastStars, 42)
        XCTAssertEqual(repoStore.trackedRepos[0].lastForks, 7)
        XCTAssertFalse(repoStore.trackedRepos[0].isPrivate)
    }

    func testDeadPATOnTheRetryPathReportsNotFoundAndLatches() async {
        // The real-world shape: user is signed in with OAuth (scope public_repo,
        // so it 404s on a private repo) and their PAT has been revoked. The
        // ladder goes ambient -> 404 -> PAT -> 401. That 401 must not escape as
        // an auth error: the ambient token already proved the repo is
        // unreachable, and blaming "GitHub authorization" sends the user to
        // re-do the app's sign-in, which is not what failed.
        var calls = 0
        MockURLProtocol.handler = { _ in
            calls += 1
            return calls == 1
                ? .init(statusCode: 404, data: Data("{}".utf8))   // OAuth can't see it
                : .init(statusCode: 401, data: Data("{}".utf8))   // PAT is revoked
        }
        let access = makeAccess(pat: "revoked-pat", ambient: "oauth")
        let repoID = UUID()

        do {
            _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: repoID)
            XCTFail("expected notFoundOrPrivate")
        } catch GitHubError.notFoundOrPrivate {
            XCTAssertTrue(access.isPATDead, "a 401 on the retry must latch the PAT dead")
        } catch {
            XCTFail("expected notFoundOrPrivate, got \(error) — a raw 401 here shows generic auth copy")
        }

        // Latched: the next attempt must not spend a call on the dead token.
        MockURLProtocol.requestedAuthorizations = []
        do { _ = try await access.fetchRepo(owner: "o", name: "n", etag: nil, knownPrivate: false, repoID: repoID) }
        catch {}
        XCTAssertEqual(tokens, ["Bearer oauth"])
    }

}
