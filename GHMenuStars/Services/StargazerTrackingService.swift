import Combine
import Foundation

@MainActor
final class StargazerTrackingService: ObservableObject {
    struct CountMismatch {
        let observed: StargazerSnapshot
        let reportedCount: Int
    }

    struct Entry {
        var history: StargazerHistory?
        var countMismatch: CountMismatch?
        var issue: String?

        var displayedSnapshot: StargazerSnapshot? { countMismatch?.observed ?? history?.snapshot }
    }

    enum CheckResult {
        case skipped
        case failed
        case observed([Date])
    }

    private struct Cached<Value> {
        let value: Value
        let date = Date()
        var fresh: Value? { Date().timeIntervalSince(date) < 86_400 ? value : nil }
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    @Published private(set) var profiles: [Int64: GitHubStargazerAuthor] = [:]
    @Published private(set) var totals: [Int64: Int64] = [:]
    @Published private(set) var totalDates: [Int64: Date] = [:]
    @Published private(set) var unavailableTotals: Set<Int64> = []
    @Published private(set) var socialLinks: [Int64: [StargazerProfileLink]] = [:]
    @Published private(set) var cleanupError: String?
    @Published private(set) var checking = false

    private let store: StargazerHistoryStore
    private let client: GitHubClient
    private let repoStore: TrackedRepoStore
    private let access: GitHubRepoAccess
    private var tokens: [UUID: String] = [:]
    private var viewers: [String: Int64] = [:]
    private var deniedAt: [UUID: Date] = [:]
    private var profilesCached: [Int64: Cached<GitHubStargazerAuthor>] = [:]
    private var socialsCached: [Int64: Cached<[StargazerProfileLink]>] = [:]
    private var profileTasks: [Int64: Task<GitHubStargazerAuthor, Error>] = [:]
    private var totalsLoading: Set<Int64> = []
    private var socialsLoading: Set<Int64> = []
    private var directoryMatches: [String: Set<Int64>] = [:]

    init(store: StargazerHistoryStore, client: GitHubClient, repoStore: TrackedRepoStore, access: GitHubRepoAccess) {
        self.store = store
        self.client = client
        self.repoStore = repoStore
        self.access = access
        access.credentialsDidChange = { [weak self] in self?.credentialsChanged() }
        repoStore.onUntrack = { [weak self] id in self?.remove(id) }
    }

    func beginRefresh() {
        checking = true
        directoryMatches.removeAll()
    }

    func endRefresh() { checking = false }

    func verify(
        repo: TrackedRepo, metadata suppliedMetadata: GitHubHTTPResult<GitHubRepoResponse>?, token: String?,
        generation: UInt64, rate: RateLimitState?, manual: Bool
    ) async -> CheckResult {
        guard active(repo.id, generation: generation) else { return .skipped }
        guard let token else {
            invalidate(repo.id, message: "Connect GitHub to see stargazers.")
            return .skipped
        }
        if !manual, let denied = deniedAt[repo.id],
           Date().timeIntervalSince(denied) < 30 * 60 { return .failed }
        do {
            if let rate, rate.isLimited { throw GitHubError.rateLimited(rate) }
            let metadata: GitHubHTTPResult<GitHubRepoResponse>
            if let supplied = suppliedMetadata {
                metadata = supplied
            } else {
                metadata = try await client.freshStargazerMetadata(owner: repo.owner, name: repo.name, token: token)
            }
            guard active(repo.id, generation: generation) else { return .skipped }
            guard let repositoryID = metadata.value.id else { throw StargazerCheckError.inconsistent }
            let visibility = metadata.value.visibility ?? (metadata.value.private ? "private" : "public")
            let source = access.credentialSource(token)
            let previous = try store.read(repo.id)
            if let prior = previous?.snapshot.scope,
               prior.repositoryID != repositoryID || prior.visibility != visibility || prior.credentialSource != source {
                invalidate(repo.id, message: "Waiting for a new baseline.")
            }
            let viewer: Int64
            if let known = viewers[token] {
                viewer = known
            } else {
                guard let id = try await client.fetchAuthenticatedUser(token: token).id, id > 0 else {
                    throw StargazerCheckError.accessUnverified
                }
                guard active(repo.id, generation: generation) else { return .skipped }
                viewers[token] = id
                viewer = id
            }
            if let prior = previous?.snapshot.scope, prior.viewerID != viewer {
                invalidate(repo.id, message: "Waiting for a new baseline.")
            }
            var bracket = metadata
            if let rate, let remaining = rate.remaining,
               remaining < (bracket.rateLimitState?.remaining ?? Int.max) {
                bracket.rateLimitState = rate
            }
            let observation = try await client.observeStargazers(metadata: bracket, viewerID: viewer,
                credentialSource: source, token: token, verifyDirectoryAccess: { repositoryID, visibility in
                    var known = self.directoryMatches[token] ?? []
                    if known.contains(repositoryID) { return true }
                    let matched = try await self.client.stargazerDirectoryContains(token: token,
                        repositoryID: repositoryID, visibility: visibility, seen: &known)
                    if self.active(repo.id, generation: generation) { self.directoryMatches[token] = known }
                    return matched
                })
            guard active(repo.id, generation: generation) else { return .skipped }
            var snapshot = observation.snapshot
            let history = previous.flatMap { record in
                record.snapshot.scope == snapshot.scope && !record.continuityBroken ? record : nil
            }
            let mismatch = snapshot.accounts.count != observation.reportedCount
            var corroborationIssue: String?
            if snapshot.scope.requiresStarHistoryCrossCheck {
                do {
                    snapshot = try await client.corroborateAgentSessionsStargazers(observation,
                        createdAt: metadata.value.createdAt, token: token)
                } catch StargazerCheckError.scopeChanged {
                    throw StargazerCheckError.scopeChanged
                } catch GitHubError.rateLimited(let state) {
                    guard active(repo.id, generation: generation) else { return .skipped }
                    repoStore.updateRateLimit(state)
                    corroborationIssue = "GitHub rate limit paused the stargazer cross-check."
                } catch {
                    corroborationIssue = "GitHub’s account lists and star history could not be reconciled."
                }
            }
            guard active(repo.id, generation: generation) else { return .skipped }
            if (mismatch && snapshot.reportedStarCount == nil) || corroborationIssue != nil {
                // A failed cross-check never replaces the saved baseline.
                tokens[repo.id] = token
                deniedAt[repo.id] = nil
                let display = mismatch ? CountMismatch(observed: observation.snapshot, reportedCount: observation.reportedCount) : nil
                entries[repo.id] = Entry(history: history, countMismatch: display, issue: corroborationIssue)
                return .failed
            }
            let record = try store.accept(snapshot, repository: observation.repository, repoID: repo.id)
            tokens[repo.id] = token
            deniedAt[repo.id] = nil
            entries[repo.id] = Entry(history: record)
            return .observed(observation.dates)
        } catch {
            guard active(repo.id, generation: generation) else { return .skipped }
            recordFailure(error, repoID: repo.id)
            return .failed
        }
    }

    func recordFailure(_ error: Error, repoID: UUID) {
        guard repoStore.trackedRepos.contains(where: { $0.id == repoID }) else { return }
        switch error {
        case GitHubError.rateLimited(let state):
            repoStore.updateRateLimit(state)
            entries[repoID, default: Entry()].issue = "GitHub rate limit active."
        case GitHubError.unauthorized, GitHubError.notFoundOrPrivate, GitHubError.server(403):
            deniedAt[repoID] = Date()
            invalidate(repoID, message: "GitHub denied stargazer access. Check the connection in Settings.")
        case StargazerCheckError.insufficientBudget:
            entries[repoID, default: Entry()].issue = "Waiting for enough GitHub API quota to check every page."
        case StargazerCheckError.accessUnverified:
            entries[repoID, default: Entry()].issue = "Stargazer access could not be verified."
        case StargazerCheckError.scopeChanged:
            invalidate(repoID, message: "Repository identity or visibility changed. Waiting for a new baseline.")
        case StargazerCheckError.inconsistent, GitHubError.decoding, GitHubError.notModified:
            entries[repoID, default: Entry()].issue = "GitHub’s stargazer responses could not be verified. The last complete check is retained."
        case is CocoaError, is StargazerHistoryError:
            entries[repoID, default: Entry()].issue = "Local stargazer history could not be read or saved."
        default:
            entries[repoID, default: Entry()].issue = "The stargazer check could not be completed."
        }
    }

    func loadProfiles(_ ids: [Int64], repoID: UUID) async {
        for id in ids {
            guard !Task.isCancelled, canFetchProfile else { return }
            await loadProfile(id, repoID: repoID)
        }
    }

    private func loadProfile(_ id: Int64, repoID: UUID) async {
        guard let token = tokenForAuthor(id, repoID: repoID) else { return }
        if let cached = profilesCached[id]?.fresh {
            if profiles[id] == nil { profiles[id] = cached }
            return
        }
        guard canFetchProfile else { return }
        let generation = access.credentialGeneration
        let task: Task<GitHubStargazerAuthor, Error>
        if let pending = profileTasks[id] {
            task = pending
        } else {
            let client = client
            task = Task { try await client.fetchStargazerAuthor(id: id, token: token) }
            profileTasks[id] = task
        }
        defer {
            if generation == access.credentialGeneration { profileTasks[id] = nil }
        }
        do {
            let profile = try await task.value
            guard active(repoID, generation: generation), tokenForAuthor(id, repoID: repoID) == token else { return }
            profilesCached[id] = Cached(value: profile)
            profiles[id] = profile
        } catch GitHubError.rateLimited(let state) {
            repoStore.updateRateLimit(state)
        } catch {}
    }

    func loadDetails(_ id: Int64, repoID: UUID, includeSocials: Bool) async {
        await loadProfile(id, repoID: repoID)
        guard let profile = profilesCached[id]?.fresh, let token = tokenForAuthor(id, repoID: repoID),
              canFetchProfile else { return }
        let generation = access.credentialGeneration
        if Date().timeIntervalSince(totalDates[id] ?? .distantPast) >= 86_400,
           totalsLoading.insert(id).inserted {
            defer { totalsLoading.remove(id) }
            do {
                let count = try await client.fetchStarsReceived(author: profile, token: token)
                guard active(repoID, generation: generation), tokenForAuthor(id, repoID: repoID) == token else { return }
                totals[id] = count
                totalDates[id] = Date()
                unavailableTotals.remove(id)
            } catch GitHubError.rateLimited(let state) {
                repoStore.updateRateLimit(state)
            } catch {
                if active(repoID, generation: generation) { unavailableTotals.insert(id) }
            }
        }
        guard includeSocials, canFetchProfile, active(repoID, generation: generation),
              tokenForAuthor(id, repoID: repoID) == token, socialsCached[id]?.fresh == nil,
              socialsLoading.insert(id).inserted else { return }
        defer { socialsLoading.remove(id) }
        do {
            let links = try await client.fetchStargazerSocialLinks(author: profile, token: token)
            guard active(repoID, generation: generation), tokenForAuthor(id, repoID: repoID) == token else { return }
            socialsCached[id] = Cached(value: links)
            socialLinks[id] = links
        } catch GitHubError.rateLimited(let state) {
            repoStore.updateRateLimit(state)
        } catch {}
    }

    private var canFetchProfile: Bool { !checking && repoStore.rateLimitState?.isLimited != true }

    private func tokenForAuthor(_ id: Int64, repoID: UUID) -> String? {
        guard entries[repoID]?.displayedSnapshot?.accounts.contains(where: { $0.id == id }) == true else { return nil }
        return tokens[repoID]
    }

    private func active(_ repoID: UUID, generation: UInt64) -> Bool {
        access.credentialGeneration == generation && repoStore.trackedRepos.contains(where: { $0.id == repoID })
    }

    private func credentialsChanged() {
        tokens.removeAll()
        viewers.removeAll()
        deniedAt.removeAll()
        entries.removeAll()
        profiles.removeAll()
        profilesCached.removeAll()
        totals.removeAll()
        totalDates.removeAll()
        unavailableTotals.removeAll()
        socialLinks.removeAll()
        socialsCached.removeAll()
        profileTasks.values.forEach { $0.cancel() }
        profileTasks.removeAll()
    }

    private func invalidate(_ repoID: UUID, message: String) {
        tokens[repoID] = nil
        entries[repoID] = Entry(issue: message)
        do {
            try store.markContinuityBreak(repoID)
        } catch {
            entries[repoID]?.issue = "Local stargazer history could not be read or saved."
        }
    }

    private func remove(_ id: UUID) {
        tokens[id] = nil
        entries[id] = nil
        deniedAt[id] = nil
        do {
            try store.remove(id)
        } catch {
            cleanupError = "Local stargazer history for the removed repository could not be deleted."
        }
    }
}
