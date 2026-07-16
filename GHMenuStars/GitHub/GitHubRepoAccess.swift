import Foundation

/// Decides which token each repo's requests carry.
///
/// GitHub answers 404 — not 403 — for a private repo you cannot see, by design,
/// so that private repos aren't enumerable. A repo's privacy is therefore only
/// knowable from a fetch that *succeeds*, which makes a try-then-retry ladder
/// unavoidable: there is no way to ask "is this private?" before having already
/// authenticated correctly for it.
///
/// `@MainActor` to match `RepoPollingService`, its only hot caller — the latches
/// below are mutable state, and MainActor isolation keeps them safe without
/// introducing a second concurrency model. `await` on the network call releases
/// the actor as normal.
@MainActor
final class GitHubRepoAccess {
    enum Outcome {
        /// 2xx. `isPrivate` is authoritative — read from the response body.
        case fetched(result: GitHubHTTPResult<GitHubRepoResponse>, isPrivate: Bool, token: String?)
        /// 304. No body, so privacy cannot be refreshed and the caller keeps the
        /// stored value. Carries the token the 304'd request used, so the repo's
        /// releases and radar calls reuse the identity that just worked.
        case notModified(token: String?)
    }

    private let client: GitHubClient
    private let patProvider: () -> String?
    private let ambientProvider: () -> String?
    private let privateAccessEnabled: () -> Bool

    /// A revoked or expired PAT is dead for every repo, not one. In-memory only:
    /// never persist auth state that can be cheaply re-derived. Cleared by
    /// `resetTokenState()` and by relaunch.
    private var patIsDead = false

    /// Repos no identity could see, and when we last proved it. Without this they
    /// burn two calls every poll forever; with a plain `Set` they could never
    /// recover if an org later approved the token or the repo was recreated.
    private var doubleFailedAt: [UUID: Date] = [:]

    /// Session cache. A tracked private repo genuinely needs the token, but
    /// re-reading the Keychain on every poll is pointless traffic — and on an
    /// unsigned/ad-hoc build each read can re-prompt. Cleared by resetTokenState().
    private var cachedPAT: String??

    /// How long a double-404 verdict stands before the ladder retries. Long
    /// enough that a dead repo isn't costing two calls a poll, short enough that
    /// a permissions change heals within an hour without a relaunch.
    static let doubleFailedRetryInterval: TimeInterval = 30 * 60

    private let now: () -> Date

    init(
        client: GitHubClient,
        patProvider: @escaping () -> String? = { KeychainTokenStore.loadGitHubPAT() },
        ambientProvider: @escaping () -> String? = { KeychainTokenStore.loadGitHubOAuthToken() },
        privateAccessEnabled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.patProvider = patProvider
        self.ambientProvider = ambientProvider
        self.privateAccessEnabled = privateAccessEnabled
        self.now = now
    }

    /// True once a PAT attempt has returned 401. Settings renders the
    /// revoked-token message from this: after the latch the ambient fallback
    /// usually 404s, which would otherwise surface as a generic "not found" and
    /// send the user off debugging the wrong problem.
    var isPATDead: Bool { patIsDead }

    /// Clears both latches. Call when the PAT is saved or removed.
    func resetTokenState() {
        patIsDead = false
        doubleFailedAt.removeAll()
        cachedPAT = nil
    }

    /// Reads the PAT from the Keychain — and *only* when a private repo is
    /// genuinely in play.
    ///
    /// This is deliberately a function, not a stored property: reading it eagerly
    /// made every public-repo poll touch the private-token Keychain item, which
    /// asks the user for their password to do something the app didn't need to
    /// do. The flag gate is part of the same contract — with the feature off,
    /// a stored token must never be consulted for any reason.
    private func loadPATIfPermitted() -> String? {
        guard privateAccessEnabled(), !patIsDead else { return nil }
        if let cachedPAT { return cachedPAT }
        let token = patProvider()
        cachedPAT = token
        return token
    }

    func fetchRepo(
        owner: String,
        name: String,
        etag: String?,
        knownPrivate: Bool,
        repoID: UUID? = nil
    ) async throws -> Outcome {
        // A repo we already know is private: the PAT is the only identity that
        // can see it, so spending the read (and a doomed ambient call) is
        // justified. This is the one branch allowed to touch the Keychain first.
        if knownPrivate, let pat = loadPATIfPermitted() {
            do {
                return try await attempt(owner: owner, name: name, etag: etag, token: pat)
            } catch GitHubError.unauthorized {
                // A revoked PAT answers 401, not 404. Fall back so a repo that
                // flipped private -> public still recovers.
                patIsDead = true
                return try await attempt(owner: owner, name: name, etag: etag, token: ambientProvider())
            }
        }

        // Public or not-yet-known: the ambient identity goes first and the PAT is
        // not read at all unless this fails in the one way a token could fix.
        do {
            return try await attempt(owner: owner, name: name, etag: etag, token: ambientProvider())
        } catch GitHubError.notFoundOrPrivate {
            guard !isDoubleFailed(repoID), let pat = loadPATIfPermitted() else {
                throw GitHubError.notFoundOrPrivate
            }
            do {
                return try await attempt(owner: owner, name: name, etag: etag, token: pat)
            } catch GitHubError.notFoundOrPrivate {
                if let repoID { doubleFailedAt[repoID] = now() }
                throw GitHubError.notFoundOrPrivate
            } catch GitHubError.unauthorized {
                // Report not-found, not a raw 401: the ambient token already
                // proved the repo unreachable, and "GitHub authorization is
                // required" blames the app's sign-in rather than the token.
                patIsDead = true
                throw GitHubError.notFoundOrPrivate
            }
        }
        // GitHubError.rateLimited matches no catch clause and propagates
        // untouched: retrying under rate limit only deepens the hole.
    }

    private func isDoubleFailed(_ repoID: UUID?) -> Bool {
        guard let repoID, let failedAt = doubleFailedAt[repoID] else { return false }
        return now().timeIntervalSince(failedAt) < Self.doubleFailedRetryInterval
    }

    private func attempt(
        owner: String,
        name: String,
        etag: String?,
        token: String?
    ) async throws -> Outcome {
        do {
            let result = try await client.fetchRepo(
                owner: owner,
                name: name,
                etag: etag,
                optionalAuthToken: token
            )
            return .fetched(result: result, isPrivate: result.value.private, token: token)
        } catch GitHubError.notModified {
            return .notModified(token: token)
        }
    }
}
