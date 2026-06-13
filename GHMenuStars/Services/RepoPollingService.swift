import Foundation

@MainActor
final class RepoPollingService {
    let gitHubClient: GitHubClient

    private let repoStore: TrackedRepoStore
    private let settingsStore: SettingsStore
    private let notificationService: NotificationService
    private let soundService: SoundService
    private let animationCoordinator: AnimationCoordinator
    private var timer: Timer?
    private var isRefreshing = false

    init(
        repoStore: TrackedRepoStore,
        settingsStore: SettingsStore,
        gitHubClient: GitHubClient,
        notificationService: NotificationService,
        soundService: SoundService,
        animationCoordinator: AnimationCoordinator
    ) {
        self.repoStore = repoStore
        self.settingsStore = settingsStore
        self.gitHubClient = gitHubClient
        self.notificationService = notificationService
        self.soundService = soundService
        self.animationCoordinator = animationCoordinator
    }

    func start() {
        scheduleTimer()
        refreshNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        let repos = repoStore.trackedRepos
        guard !repos.isEmpty else { return }
        if let rate = repoStore.rateLimitState, rate.isLimited { return }

        isRefreshing = true
        Task {
            defer {
                Task { @MainActor in
                    self.isRefreshing = false
                    self.scheduleTimer()
                }
            }
            for repo in repos {
                if let rate = self.repoStore.rateLimitState, rate.isLimited { break }
                await refresh(repo: repo)
            }
        }
    }

    func refreshNow(repoID: UUID) {
        guard !isRefreshing else { return }
        guard let repo = repoStore.trackedRepos.first(where: { $0.id == repoID }) else { return }
        if let rate = repoStore.rateLimitState, rate.isLimited { return }

        isRefreshing = true
        Task {
            defer {
                Task { @MainActor in
                    self.isRefreshing = false
                    self.scheduleTimer()
                }
            }
            await refresh(repo: repo)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settingsStore.settings.refreshInterval.timeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    private func refresh(repo: TrackedRepo) async {
        do {
            var repoETag = repo.etagRepo
            var releasesETag = repo.etagReleases
            let stars: Int
            let forks: Int
            do {
                let repoETagForRequest = repo.lastForks == nil ? nil : repo.etagRepo
                let repoResult = try await gitHubClient.fetchRepo(owner: repo.owner, name: repo.name, etag: repoETagForRequest)
                guard !repoResult.value.private else { throw GitHubError.notFoundOrPrivate }
                stars = repoResult.value.stargazersCount
                forks = repoResult.value.forksCount
                repoETag = repoResult.etag ?? repoETag
                repoStore.updateRateLimit(repoResult.rateLimitState)
            } catch GitHubError.notModified {
                stars = repo.lastStars ?? 0
                forks = repo.lastForks ?? 0
            }

            let downloads: Int
            do {
                let releasesResult = try await gitHubClient.fetchReleases(owner: repo.owner, name: repo.name, etag: repo.etagReleases)
                downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                releasesETag = releasesResult.etag ?? releasesETag
                repoStore.updateRateLimit(releasesResult.rateLimitState)
            } catch GitHubError.notModified {
                downloads = repo.lastDownloads ?? 0
            }

            let checkedAt = Date()
            let trendPoints = await fetchTrendPointsIfNeeded(
                for: repo,
                stars: stars,
                forks: forks,
                checkedAt: checkedAt
            )
            let snapshot = RepoSnapshot(
                stars: stars,
                releaseDownloads: downloads,
                forks: forks,
                checkedAt: checkedAt,
                repoETag: repoETag,
                releasesETag: releasesETag,
                trendPoints: trendPoints,
                trendRange: trendPoints == nil ? nil : .all
            )
            if let delta = repoStore.apply(snapshot: snapshot, to: repo.id) {
                handle(delta: delta, repoID: repo.id, stars: stars, downloads: downloads)
            }
        } catch GitHubError.rateLimited(let state) {
            repoStore.updateRateLimit(state)
            repoStore.markChecked(repoID: repo.id)
        } catch {
            repoStore.markChecked(repoID: repo.id)
        }
    }

    private func fetchTrendPointsIfNeeded(
        for repo: TrackedRepo,
        stars: Int,
        forks: Int,
        checkedAt: Date
    ) async -> [RepoTrendPoint]? {
        guard shouldRefreshTrend(for: repo, stars: stars, forks: forks, checkedAt: checkedAt) else {
            return nil
        }

        do {
            async let starDates = gitHubClient.fetchStargazerDates(owner: repo.owner, name: repo.name)
            async let forkDates = gitHubClient.fetchForkDates(owner: repo.owner, name: repo.name)
            let (resolvedStarDates, resolvedForkDates) = try await (starDates, forkDates)
            return RepoTrendBuilder.points(
                stars: stars,
                forks: forks,
                starDates: resolvedStarDates,
                forkDates: resolvedForkDates,
                range: .all,
                now: checkedAt
            )
        } catch {
            return nil
        }
    }

    private func shouldRefreshTrend(for repo: TrackedRepo, stars: Int, forks: Int, checkedAt: Date) -> Bool {
        if repo.trendPoints.isEmpty { return true }
        if repo.trendRange != .all { return true }
        if repo.lastStars != stars || repo.lastForks != forks { return true }
        if isFlatTrend(repo.trendPoints), stars + forks > 0 { return true }
        return false
    }

    private func isFlatTrend(_ points: [RepoTrendPoint]) -> Bool {
        guard let first = points.first else { return true }
        return points.allSatisfy { $0.stars == first.stars && $0.forks == first.forks }
    }

    private func handle(delta: RepoDelta, repoID: UUID, stars: Int, downloads: Int) {
        guard delta.hasCelebrationIncrease else { return }
        let settings = settingsStore.settings
        guard !settings.isMuted else { return }
        if delta.hasStarIncrease,
           settings.notifyOnStarIncrease,
           repoStore.trackedRepos.first(where: { $0.id == repoID })?.lastNotifiedStars != stars {
            notificationService.notifyStarIncrease(delta: delta.starsDelta, stars: stars)
            repoStore.markNotified(repoID: repoID, stars: stars, downloads: nil)
        }
        if settings.playSoundOnStarIncrease,
           settings.celebrationMode != .off,
           settings.starSoundThreshold.isMet(
                starsDelta: delta.starsDelta,
                downloadsDelta: delta.downloadsDelta,
                downloads: downloads
           ),
           let repo = repoStore.trackedRepos.first(where: { $0.id == repoID }) {
            soundService.play(repo.starSound)
        }
        if settings.celebrationMode != .off {
            animationCoordinator.pulse(mode: settings.celebrationMode)
        }
    }
}
