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
        guard let repo = repoStore.trackedRepos.first else { return }
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
            do {
                let repoResult = try await gitHubClient.fetchRepo(owner: repo.owner, name: repo.name, etag: repo.etagRepo)
                guard !repoResult.value.private else { throw GitHubError.notFoundOrPrivate }
                stars = repoResult.value.stargazersCount
                repoETag = repoResult.etag ?? repoETag
                repoStore.updateRateLimit(repoResult.rateLimitState)
            } catch GitHubError.notModified {
                stars = repo.lastStars ?? 0
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

            let snapshot = RepoSnapshot(
                stars: stars,
                releaseDownloads: downloads,
                checkedAt: Date(),
                repoETag: repoETag,
                releasesETag: releasesETag
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

    private func handle(delta: RepoDelta, repoID: UUID, stars: Int, downloads: Int) {
        guard delta.hasStarIncrease else { return }
        let settings = settingsStore.settings
        guard !settings.isMuted else { return }
        if settings.notifyOnStarIncrease,
           repoStore.trackedRepos.first?.lastNotifiedStars != stars {
            notificationService.notifyStarIncrease(delta: delta.starsDelta, stars: stars)
            repoStore.markNotified(repoID: repoID, stars: stars, downloads: nil)
        }
        if settings.playSoundOnStarIncrease {
            soundService.play()
        }
        if settings.animateOnStarIncrease {
            animationCoordinator.pulse()
        }
    }
}
