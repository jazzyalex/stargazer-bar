import XCTest
@testable import GHMenuStars

@MainActor
final class GitHubRepoAccessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
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
}
