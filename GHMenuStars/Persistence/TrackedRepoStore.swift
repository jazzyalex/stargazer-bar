import Combine
import Foundation

@MainActor
final class TrackedRepoStore: ObservableObject {
    @Published private(set) var trackedRepos: [TrackedRepo]
    @Published private(set) var lastDelta: RepoDelta?
    @Published private(set) var rateLimitState: RateLimitState?

    private let defaults: UserDefaults
    private let reposKey = "GHMenuStars.TrackedRepos.v1"
    private let deltaKey = "GHMenuStars.LastDelta.v1"
    private let rateLimitKey = "GHMenuStars.RateLimit.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.trackedRepos = Self.decode([TrackedRepo].self, key: reposKey, defaults: defaults) ?? []
        self.lastDelta = Self.decode(RepoDelta.self, key: deltaKey, defaults: defaults)
        self.rateLimitState = Self.decode(RateLimitState.self, key: rateLimitKey, defaults: defaults)
    }

    func setTrackedRepo(_ repo: TrackedRepo) {
        trackedRepos = [repo]
        lastDelta = nil
        rateLimitState = nil
        saveAll()
    }

    func apply(snapshot: RepoSnapshot, to repoID: UUID) -> RepoDelta? {
        guard let index = trackedRepos.firstIndex(where: { $0.id == repoID }) else { return nil }
        var repo = trackedRepos[index]
        let delta = RepoDelta(
            starsDelta: max(0, snapshot.stars - (repo.lastStars ?? snapshot.stars)),
            downloadsDelta: max(0, snapshot.releaseDownloads - (repo.lastDownloads ?? snapshot.releaseDownloads))
        )
        repo.lastStars = snapshot.stars
        repo.lastDownloads = snapshot.releaseDownloads
        repo.lastCheckedAt = snapshot.checkedAt
        repo.lastSuccessfulCheckAt = snapshot.checkedAt
        repo.etagRepo = snapshot.repoETag ?? repo.etagRepo
        repo.etagReleases = snapshot.releasesETag ?? repo.etagReleases
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

    func updateRateLimit(_ state: RateLimitState?) {
        rateLimitState = state
        saveAll()
    }

    private func saveAll() {
        encode(trackedRepos, key: reposKey)
        encode(lastDelta, key: deltaKey)
        encode(rateLimitState, key: rateLimitKey)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

