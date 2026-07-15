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

    /// A revoked or expired PAT is dead for every repo, not one. In-memory only:
    /// never persist auth state that can be cheaply re-derived. Cleared by
    /// `resetTokenState()` and by relaunch, which makes "I fixed the token,
    /// restart the app" a self-healing path rather than a support ticket.
    private var patIsDead = false

    /// Repos no identity can see — deleted upstream, or a typo tracked while the
    /// repo was public. Without this they burn two calls on every poll forever.
    private var doubleFailedRepoIDs: Set<UUID> = []

    init(
        client: GitHubClient,
        patProvider: @escaping () -> String? = { KeychainTokenStore.loadGitHubPAT() },
        ambientProvider: @escaping () -> String? = { KeychainTokenStore.loadGitHubOAuthToken() }
    ) {
        self.client = client
        self.patProvider = patProvider
        self.ambientProvider = ambientProvider
    }

    /// True once a PAT attempt has returned 401. Settings renders the
    /// revoked-token message from this: after the latch the ambient fallback
    /// usually 404s, which would otherwise surface as a generic "not found" and
    /// send the user off debugging the wrong problem.
    var isPATDead: Bool { patIsDead }

    /// Clears both latches. Call when the PAT is saved or removed.
    func resetTokenState() {
        patIsDead = false
        doubleFailedRepoIDs.removeAll()
    }

    private var livePAT: String? { patIsDead ? nil : patProvider() }

    func fetchRepo(
        owner: String,
        name: String,
        etag: String?,
        knownPrivate: Bool,
        repoID: UUID? = nil
    ) async throws -> Outcome {
        let pat = livePAT
        let ambient = ambientProvider()
        // Prefer the PAT when we know it's needed, or when there is no ambient
        // token to protect: a PAT-only user would otherwise poll public repos
        // anonymously on the 60/hr per-IP bucket, and the global rate-limit gate
        // would then starve the private repos the PAT could still serve.
        let preferPAT = pat != nil && (knownPrivate || ambient == nil)
        let firstToken = preferPAT ? pat : ambient

        do {
            return try await attempt(owner: owner, name: name, etag: etag, token: firstToken)
        } catch GitHubError.unauthorized where preferPAT {
            // Fires regardless of knownPrivate: a repo that flipped
            // private -> public while the PAT was revoked must still recover, and
            // a revoked PAT answers 401, so the 404 ladder alone would strand it.
            patIsDead = true
            return try await attempt(owner: owner, name: name, etag: etag, token: ambient)
        } catch GitHubError.notFoundOrPrivate where !preferPAT && pat != nil && !isDoubleFailed(repoID) {
            do {
                return try await attempt(owner: owner, name: name, etag: etag, token: pat)
            } catch GitHubError.notFoundOrPrivate {
                if let repoID { doubleFailedRepoIDs.insert(repoID) }
                throw GitHubError.notFoundOrPrivate
            }
        }
        // GitHubError.rateLimited matches no catch clause and propagates
        // untouched: retrying under rate limit only deepens the hole.
    }

    private func isDoubleFailed(_ repoID: UUID?) -> Bool {
        guard let repoID else { return false }
        return doubleFailedRepoIDs.contains(repoID)
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
