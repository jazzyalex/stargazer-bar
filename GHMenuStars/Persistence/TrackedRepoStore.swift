import Combine
import Foundation

enum TrackedRepoStoreError: Error, Equatable {
    case maximumReached(Int)
}

@MainActor
final class TrackedRepoStore: ObservableObject {
    static let maximumTrackedRepos = 5

    @Published private(set) var trackedRepos: [TrackedRepo]
    @Published private(set) var lastDelta: RepoDelta?
    @Published private(set) var rateLimitState: RateLimitState?

    private let defaults: UserDefaults
    private let reposKey = "GHMenuStars.TrackedRepos.v1"
    private let deltaKey = "GHMenuStars.LastDelta.v1"
    private let rateLimitKey = "GHMenuStars.RateLimit.v1"

    init(
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: "com.jazzyalex.GHMenuStars")
    ) {
        self.defaults = defaults
        self.trackedRepos = Self.decode([TrackedRepo].self, key: reposKey, defaults: defaults)
            ?? Self.migrate([TrackedRepo].self, key: reposKey, from: legacyDefaults, to: defaults)
            ?? []
        self.lastDelta = Self.decode(RepoDelta.self, key: deltaKey, defaults: defaults)
            ?? Self.migrate(RepoDelta.self, key: deltaKey, from: legacyDefaults, to: defaults)
        self.rateLimitState = Self.decode(RateLimitState.self, key: rateLimitKey, defaults: defaults)
            ?? Self.migrate(RateLimitState.self, key: rateLimitKey, from: legacyDefaults, to: defaults)
    }

    func setTrackedRepo(_ repo: TrackedRepo) {
        trackedRepos = [repo]
        lastDelta = nil
        rateLimitState = nil
        saveAll()
    }

    func upsertTrackedRepo(_ repo: TrackedRepo) throws {
        if let index = trackedRepos.firstIndex(where: { Self.matches($0, repo) }) {
            var existing = trackedRepos[index]
            existing.owner = repo.owner
            existing.name = repo.name
            existing.displayName = repo.displayName
            existing.source = repo.source
            existing.isPrivate = repo.isPrivate
            existing.lastStars = repo.lastStars ?? existing.lastStars
            existing.lastDownloads = repo.lastDownloads ?? existing.lastDownloads
            existing.lastForks = repo.lastForks ?? existing.lastForks
            existing.lastCheckedAt = repo.lastCheckedAt ?? existing.lastCheckedAt
            existing.lastSuccessfulCheckAt = repo.lastSuccessfulCheckAt ?? existing.lastSuccessfulCheckAt
            existing.etagRepo = repo.etagRepo ?? existing.etagRepo
            existing.etagReleases = repo.etagReleases ?? existing.etagReleases
            if !repo.trendPoints.isEmpty {
                existing.trendPoints = repo.trendPoints
                existing.trendRange = repo.trendRange
            }
            existing.maintainerRadar = repo.maintainerRadar ?? existing.maintainerRadar
            trackedRepos[index] = existing
        } else {
            guard trackedRepos.count < Self.maximumTrackedRepos else {
                throw TrackedRepoStoreError.maximumReached(Self.maximumTrackedRepos)
            }
            trackedRepos.append(repo)
        }
        rateLimitState = nil
        saveAll()
    }

    /// Called when the PAT changes. Every stored ETag was minted under the old
    /// auth identity, and a 304 against one would serve a body only that
    /// identity could see. A stale-ETag miss costs a single request; trusting a
    /// cross-identity ETag costs correctness. Conditional requests that 304
    /// don't consume rate limit, so this is close to free.
    func clearAllETags() {
        for index in trackedRepos.indices {
            trackedRepos[index].etagRepo = nil
            trackedRepos[index].etagReleases = nil
        }
        saveAll()
    }

    func removeTrackedRepo(id: UUID) {
        trackedRepos.removeAll { $0.id == id }
        saveAll()
    }

    func moveTrackedRepos(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { trackedRepos[$0] }
        var remaining = trackedRepos.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        let skippedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = max(0, min(destination - skippedBeforeDestination, remaining.count))
        remaining.insert(contentsOf: moving, at: insertionIndex)
        trackedRepos = remaining
        saveAll()
    }

    func repo(id: UUID?) -> TrackedRepo? {
        guard let id else { return trackedRepos.first }
        return trackedRepos.first { $0.id == id } ?? trackedRepos.first
    }

    func containsRepo(owner: String, name: String) -> Bool {
        trackedRepos.contains {
            $0.owner.caseInsensitiveCompare(owner) == .orderedSame
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    func apply(snapshot: RepoSnapshot, to repoID: UUID) -> RepoDelta? {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return nil }
        var repo = trackedRepos[index]
        // A visibility flip invalidates both ETags: they were minted under a
        // different auth identity, so a 304 against them would serve a body only
        // that identity could see.
        let didFlipVisibility = repo.isPrivate != snapshot.isPrivate
        repo.isPrivate = snapshot.isPrivate
        let delta = RepoDelta(
            starsDelta: max(0, snapshot.stars - (repo.lastStars ?? snapshot.stars)),
            downloadsDelta: max(0, snapshot.releaseDownloads - (repo.lastDownloads ?? snapshot.releaseDownloads)),
            forksDelta: max(0, snapshot.forks - (repo.lastForks ?? snapshot.forks))
        )
        repo.lastStars = snapshot.stars
        repo.lastDownloads = snapshot.releaseDownloads
        repo.lastForks = snapshot.forks
        repo.lastCheckedAt = snapshot.checkedAt
        repo.lastSuccessfulCheckAt = snapshot.checkedAt
        repo.lastStarsDelta = delta.starsDelta
        repo.lastDownloadsDelta = delta.downloadsDelta
        repo.lastForksDelta = delta.forksDelta
        repo.etagRepo = didFlipVisibility ? nil : (snapshot.repoETag ?? repo.etagRepo)
        repo.etagReleases = didFlipVisibility ? nil : (snapshot.releasesETag ?? repo.etagReleases)
        if let trendPoints = snapshot.trendPoints {
            repo.trendPoints = trendPoints
            repo.trendRange = snapshot.trendRange
        }
        if let maintainerRadar = snapshot.maintainerRadar {
            repo.maintainerRadar = maintainerRadar
        }
        if let latestRelease = snapshot.latestRelease {
            repo.latestRelease = latestRelease
        }
        if let recentReleases = snapshot.recentReleases {
            repo.recentReleases = recentReleases
        }
        trackedRepos[index] = repo
        lastDelta = delta
        rateLimitState = nil
        saveAll()
        return delta
    }

    func markChecked(repoID: UUID, at date: Date = Date()) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        trackedRepos[index].lastCheckedAt = date
        saveAll()
    }

    func markNotified(repoID: UUID, stars: Int?, downloads: Int?) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        if let stars {
            trackedRepos[index].lastNotifiedStars = stars
        }
        if let downloads {
            trackedRepos[index].lastNotifiedDownloads = downloads
        }
        saveAll()
    }

    func markStarAskPrompt(repoID: UUID, status: StarAskPromptStatus, at date: Date = Date()) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        trackedRepos[index].starAskPromptStatus = status
        trackedRepos[index].lastStarAskPromptedAt = date
        saveAll()
    }

    func setTrendPoints(_ points: [RepoTrendPoint], range: RepoTrendRange?, for repoID: UUID) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        trackedRepos[index].trendPoints = points
        trackedRepos[index].trendRange = range
        saveAll()
    }

    func setMaintainerRadar(_ radar: RepoMaintainerRadar?, for repoID: UUID) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        trackedRepos[index].maintainerRadar = radar
        saveAll()
    }

    func setStarSound(_ sound: StarSound, for repoID: UUID) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        trackedRepos[index].starSound = sound
        saveAll()
    }

    func setMuted(_ muted: Bool, for repoID: UUID) {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        trackedRepos[index].isMuted = muted
        saveAll()
    }

    func updateRateLimit(_ state: RateLimitState?) {
        rateLimitState = state
        saveAll()
    }

    func clearExpiredRateLimit() {
        guard let state = rateLimitState, !state.isLimited else { return }
        rateLimitState = nil
        saveAll()
    }

    private func saveAll() {
        encode(trackedRepos, key: reposKey)
        encode(lastDelta, key: deltaKey)
        encode(rateLimitState, key: rateLimitKey)
    }

    private static func matches(_ lhs: TrackedRepo, _ rhs: TrackedRepo) -> Bool {
        lhs.owner.caseInsensitiveCompare(rhs.owner) == .orderedSame
            && lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func migrate<T: Decodable>(
        _ type: T.Type,
        key: String,
        from legacyDefaults: UserDefaults?,
        to defaults: UserDefaults
    ) -> T? {
        guard let data = legacyDefaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode(type, from: data) else {
            return nil
        }
        defaults.set(data, forKey: key)
        return decoded
    }
}
