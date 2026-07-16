import AppKit
import Foundation

enum StarAskPromptTrigger: Equatable {
    case starIncrease(Int)
    case downloadIncrease(Int)

    static func trigger(for delta: RepoDelta) -> StarAskPromptTrigger? {
        if delta.starsDelta > 0 {
            return .starIncrease(delta.starsDelta)
        }
        if delta.downloadsDelta >= 20 {
            return .downloadIncrease(delta.downloadsDelta)
        }
        return nil
    }

    var summary: String {
        switch self {
        case .starIncrease(let delta):
            return "+\(NumberFormatter.menuInteger.string(from: NSNumber(value: delta)) ?? "\(delta)") star\(delta == 1 ? "" : "s") just landed."
        case .downloadIncrease(let delta):
            return "+\(NumberFormatter.menuInteger.string(from: NSNumber(value: delta)) ?? "\(delta)") release downloads since the last refresh."
        }
    }
}

@MainActor
final class RepoPollingService {
    let gitHubClient: GitHubClient
    let repoAccess: GitHubRepoAccess

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
        repoAccess: GitHubRepoAccess,
        notificationService: NotificationService,
        soundService: SoundService,
        animationCoordinator: AnimationCoordinator
    ) {
        self.repoStore = repoStore
        self.settingsStore = settingsStore
        self.gitHubClient = gitHubClient
        self.repoAccess = repoAccess
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
        repoStore.clearExpiredRateLimit()
        if let rate = repoStore.rateLimitState, rate.isLimited {
            scheduleTimer()
            return
        }

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
        repoStore.clearExpiredRateLimit()
        if let rate = repoStore.rateLimitState, rate.isLimited {
            scheduleTimer()
            return
        }

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
        timer = Timer.scheduledTimer(withTimeInterval: nextRefreshInterval(), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    private func nextRefreshInterval(now: Date = Date()) -> TimeInterval {
        if let rate = repoStore.rateLimitState,
           rate.isLimited,
           let resetAt = rate.resetAt {
            return max(5, resetAt.timeIntervalSince(now) + 1)
        }
        return settingsStore.settings.refreshInterval.timeInterval
    }

    // internal, not private: both refreshNow() entries spawn a detached Task and
    // return, so a test awaiting them would race the work and assert against
    // nothing. Tests await this directly.
    func refresh(repo: TrackedRepo) async {
        do {
            var repoETag = repo.etagRepo
            var releasesETag = repo.etagReleases
            var latestRateLimitState: RateLimitState?
            let stars: Int
            let forks: Int
            let isPrivate: Bool
            let authToken: String?
            let didFlipVisibility: Bool
            do {
                let repoETagForRequest = repo.lastForks == nil ? nil : repo.etagRepo
                let outcome = try await repoAccess.fetchRepo(
                    owner: repo.owner,
                    name: repo.name,
                    etag: repoETagForRequest,
                    knownPrivate: repo.isPrivate,
                    repoID: repo.id
                )
                switch outcome {
                case .fetched(let repoResult, let fetchedPrivate, let token):
                    isPrivate = fetchedPrivate
                    authToken = token
                    didFlipVisibility = fetchedPrivate != repo.isPrivate
                    // Private repos: nothing to count, so don't pay for it.
                    stars = fetchedPrivate ? 0 : repoResult.value.stargazersCount
                    forks = fetchedPrivate ? 0 : repoResult.value.forksCount
                    repoETag = repoResult.etag ?? repoETag
                    latestRateLimitState = repoResult.rateLimitState ?? latestRateLimitState
                case .notModified(let token):
                    // 304 has no body, so privacy can't be refreshed — keep what
                    // we stored.
                    isPrivate = repo.isPrivate
                    authToken = token
                    didFlipVisibility = false
                    stars = repo.lastStars ?? 0
                    forks = repo.lastForks ?? 0
                }
            }

            let downloads: Int
            var latestRelease: LatestReleaseSummary?
            var recentReleases: RecentReleasesSummary?
            do {
                let releasesResult = try await gitHubClient.fetchReleases(
                    owner: repo.owner,
                    name: repo.name,
                    // A flip invalidates the ETag — it was minted under the other
                    // identity — and apply(snapshot:) resets too late to protect
                    // the request going out right here.
                    etag: didFlipVisibility ? nil : repo.etagReleases,
                    optionalAuthToken: authToken
                )
                downloads = ReleaseDownloadAggregator.totalDownloads(from: releasesResult.value)
                latestRelease = LatestReleaseSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads)
                recentReleases = RecentReleasesSummaryBuilder.summary(from: releasesResult.value, totalDownloads: downloads, now: Date())
                releasesETag = releasesResult.etag ?? releasesETag
                latestRateLimitState = releasesResult.rateLimitState ?? latestRateLimitState
            } catch GitHubError.notModified {
                downloads = repo.lastDownloads ?? 0
                latestRelease = nil
                recentReleases = nil
            }

            let checkedAt = Date()
            let activityWindow = settingsStore.settings.maintainerRadarActivityWindow
            let effectiveRelease = latestRelease ?? repo.latestRelease
            // Don't let a fresh release re-enable activity counts the user turned off.
            let releaseAnchor = activityWindow == .off ? nil : effectiveRelease.flatMap {
                ReleaseDynamics.isFresh(publishedAt: $0.publishedAt, now: checkedAt) ? $0.publishedAt : nil
            }
            // Private repos: the stargazer/fork walk is the bulk of the per-poll
            // request budget, and it would be counting something never shown.
            async let trendPoints: [RepoTrendPoint]? = isPrivate
                ? nil
                : fetchTrendPointsIfNeeded(
                    for: repo,
                    stars: stars,
                    forks: forks,
                    checkedAt: checkedAt
                )
            // 30 days of commit dates, fetched once: the chart buckets them by
            // day and the menu bar counts a 7-day slice of the same data, so
            // neither surface costs an extra request.
            async let commitDates: [Date]? = gitHubClient.fetchCrossBranchCommitDates(
                owner: repo.owner,
                name: repo.name,
                since: checkedAt.addingTimeInterval(-30 * 86_400),
                now: checkedAt,
                optionalAuthToken: authToken
            )
            async let maintainerRadar = gitHubClient.fetchMaintainerRadar(
                owner: repo.owner,
                name: repo.name,
                activityWindow: activityWindow,
                releaseAnchor: releaseAnchor,
                now: checkedAt,
                // Without this the radar authenticates as OAuth, 404s on every
                // call, and the optional* wrappers render blank rows with no error.
                optionalAuthToken: authToken
            )
            let resolvedCommitDates = await commitDates
            let resolvedCommitActivity = resolvedCommitDates.map {
                CommitActivityBuilder.buckets(
                    from: $0,
                    since: checkedAt.addingTimeInterval(-30 * 86_400),
                    now: checkedAt
                )
            }
            let resolvedTrendPoints = await trendPoints
            let resolvedMaintainerRadar = await maintainerRadar
            let radarSnapshot = resolvedMaintainerRadar.hasData ? resolvedMaintainerRadar : nil
            let snapshot = RepoSnapshot(
                stars: stars,
                releaseDownloads: downloads,
                forks: forks,
                checkedAt: checkedAt,
                repoETag: repoETag,
                releasesETag: releasesETag,
                trendPoints: resolvedTrendPoints,
                trendRange: resolvedTrendPoints == nil ? nil : .all,
                maintainerRadar: radarSnapshot,
                latestRelease: latestRelease,
                recentReleases: recentReleases,
                isPrivate: isPrivate,
                commitActivity: resolvedCommitActivity
            )
            if let delta = repoStore.apply(snapshot: snapshot, to: repo.id) {
                handle(delta: delta, repoID: repo.id, stars: stars, downloads: downloads)
            }
            if let latestRateLimitState, latestRateLimitState.isLimited {
                repoStore.updateRateLimit(latestRateLimitState)
            }
        } catch GitHubError.rateLimited(let state) {
            repoStore.updateRateLimit(state)
            repoStore.markRefreshFailed(repoID: repo.id, failure: .rateLimited)
        } catch {
            // Previously every failure called markChecked, which stamps
            // lastCheckedAt — so a revoked token, a deleted repo and an offline
            // machine all looked like a fresh successful check sitting on top of
            // stale data. Record what actually happened instead.
            repoStore.markRefreshFailed(repoID: repo.id, failure: Self.classify(error, isPATDead: repoAccess.isPATDead))
        }
    }

    /// Maps a poll error onto something the user can act on. The PAT-dead latch
    /// disambiguates the one case GitHub cannot: a 404 that really means "your
    /// token died", not "this repo is gone".
    nonisolated static func classify(_ error: Error, isPATDead: Bool) -> RepoRefreshFailure {
        switch error {
        case GitHubError.notFoundOrPrivate:
            return isPATDead ? .privateTokenRejected : .notFoundOrNoAccess
        case GitHubError.unauthorized, GitHubError.missingToken:
            return .privateTokenRejected
        case GitHubError.rateLimited:
            return .rateLimited
        case GitHubError.server, GitHubError.decoding:
            return .server
        case GitHubError.transport:
            return .offline
        default:
            return .server
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
            // Incremental path: an established all-time curve only needs the
            // events added since the last successful check, which is a handful of
            // pages instead of the repo's entire stargazer/fork history.
            if !repo.trendPoints.isEmpty,
               repo.trendRange == .all,
               !isFlatTrend(repo.trendPoints),
               let since = repo.lastSuccessfulCheckAt {
                async let starDates = gitHubClient.fetchStargazerDates(owner: repo.owner, name: repo.name, since: since, maxPages: GitHubClient.trendPageLimit)
                async let forkDates = gitHubClient.fetchForkDates(owner: repo.owner, name: repo.name, since: since, maxPages: GitHubClient.trendPageLimit)
                let (newStarDates, newForkDates) = try await (starDates, forkDates)
                return RepoTrendBuilder.extend(
                    existing: repo.trendPoints,
                    newStarDates: newStarDates,
                    newForkDates: newForkDates,
                    totalStars: stars,
                    totalForks: forks,
                    now: checkedAt
                )
            }

            // Full backfill: first time, or the stored curve is empty/degenerate.
            let pageLimit = gitHubClient.trendBackfillPageLimit()
            async let starDates = gitHubClient.fetchStargazerDates(owner: repo.owner, name: repo.name, maxPages: pageLimit)
            async let forkDates = gitHubClient.fetchForkDates(owner: repo.owner, name: repo.name, maxPages: pageLimit)
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

    /// The star delta that should drive user-facing cues.
    ///
    /// Zero for a private repo: its stars are never fetched, and a collaborator
    /// starring it is not something to celebrate in a menu bar built around
    /// public reach. Suppression has to key off the *metric* like this — the
    /// sound and celebration blocks below also fire on download milestones, so
    /// gating those blocks on `isPrivate` would silently kill download cues that
    /// private repos are entitled to.
    nonisolated static func cueStarsDelta(_ delta: RepoDelta, isPrivate: Bool) -> Int {
        isPrivate ? 0 : delta.starsDelta
    }

    func handle(delta: RepoDelta, repoID: UUID, stars: Int, downloads: Int) {
        guard delta.hasCelebrationIncrease else { return }
        let settings = settingsStore.settings
        guard !settings.isMuted else { return }
        // Per-repo mute silences everything for this repo: no notification,
        // sound, celebration pulse, or star-ask prompt.
        guard repoStore.trackedRepos.first(where: { $0.id == repoID })?.isMuted != true else { return }
        let isPrivateRepo = repoStore.trackedRepos.first(where: { $0.id == repoID })?.isPrivate == true
        let cueStars = Self.cueStarsDelta(delta, isPrivate: isPrivateRepo)
        if cueStars > 0,
           settings.notifyOnStarIncrease,
           repoStore.trackedRepos.first(where: { $0.id == repoID })?.lastNotifiedStars != stars {
            notificationService.notifyStarIncrease(delta: delta.starsDelta, stars: stars)
            repoStore.markNotified(repoID: repoID, stars: stars, downloads: nil)
        }
        if settings.playSoundOnStarIncrease,
           settings.celebrationMode != .off,
           settings.starSoundThreshold.isMet(
                starsDelta: cueStars,
                downloadsDelta: delta.downloadsDelta,
                downloads: downloads
           ),
           let repo = repoStore.trackedRepos.first(where: { $0.id == repoID }) {
            soundService.play(repo.starSound)
        }
        if settings.celebrationMode != .off {
            animationCoordinator.pulse(mode: settings.celebrationMode)
        }
        presentStarAskIfNeeded(delta: delta, repoID: repoID)
    }

    private func presentStarAskIfNeeded(delta: RepoDelta, repoID: UUID) {
        // Never present a modal from a test run. This opens a real window and
        // calls NSApp.activate, so a test exercising handle() would otherwise
        // pop dialogs onto the developer's desktop — and "Don't Ask Again"
        // can't dismiss them, because each test writes that choice to a
        // throwaway UserDefaults suite. Same guard UpdaterController uses.
        guard !AppDelegate.isHostedUnitTest() else { return }
        guard let trigger = StarAskPromptTrigger.trigger(for: delta),
              let repo = repoStore.trackedRepos.first(where: { $0.id == repoID }),
              repo.starAskPromptStatus.canPrompt else {
            return
        }

        let status = StarAskPromptPresenter.present(repo: repo, trigger: trigger)
        repoStore.markStarAskPrompt(repoID: repoID, status: status)
    }
}

enum StarAskPromptPresenter {
    @MainActor
    static func present(repo: TrackedRepo, trigger: StarAskPromptTrigger) -> StarAskPromptStatus {
        let controller = StarAskPromptWindowController(repo: repo, trigger: trigger)
        NSApp.activate(ignoringOtherApps: true)
        let status = controller.showModal()
        if status == .starred {
            NSWorkspace.shared.open(AppExternalLinks.gitHubRepository)
        }
        return status
    }
}

private final class StarAskPromptWindowController: NSWindowController, NSWindowDelegate {
    private var status: StarAskPromptStatus = .later

    init(repo: TrackedRepo, trigger: StarAskPromptTrigger) {
        let contentView = StarAskPromptContentView(repo: repo, trigger: trigger)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 202),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stargazer Bar"
        window.backgroundColor = .windowBackgroundColor
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showModal() -> StarAskPromptStatus {
        guard let window else { return .later }
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return status
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    fileprivate func choose(_ status: StarAskPromptStatus) {
        self.status = status
        window?.close()
    }
}

private final class StarAskPromptContentView: NSView {
    private let repo: TrackedRepo
    private let trigger: StarAskPromptTrigger

    init(repo: TrackedRepo, trigger: StarAskPromptTrigger) {
        self.repo = repo
        self.trigger = trigger
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 202))
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func build() {
        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = textField(
            "Nice, \(repo.displayName) is growing",
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: .labelColor
        )
        let body = textField(
            "\(trigger.summary)\n\nIf Stargazer Bar helped you catch it, a star helps other maintainers find the app.",
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor
        )

        let starButton = button("Star", keyEquivalent: "\r", status: .starred)
        let laterButton = button("Later", keyEquivalent: "\u{1b}", status: .later)
        let dismissButton = button("Don't Ask Again", keyEquivalent: "", status: .dismissed)

        let rightButtons = NSStackView(views: [laterButton, starButton])
        rightButtons.orientation = .horizontal
        rightButtons.alignment = .centerY
        rightButtons.spacing = 8
        rightButtons.distribution = .fill
        rightButtons.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        addSubview(iconView)
        addSubview(stack)
        addSubview(dismissButton)
        addSubview(rightButtons)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: rightButtons.topAnchor, constant: -18),

            dismissButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            dismissButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),

            rightButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            rightButtons.bottomAnchor.constraint(equalTo: dismissButton.bottomAnchor)
        ])
    }

    private func textField(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 326
        return field
    }

    private func button(_ title: String, keyEquivalent: String, status: StarAskPromptStatus) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(choose(_:)))
        button.bezelStyle = .rounded
        button.keyEquivalent = keyEquivalent
        button.tag = tag(for: status)
        if status == .starred {
            button.keyEquivalentModifierMask = []
        }
        return button
    }

    @objc private func choose(_ sender: NSButton) {
        guard let status = status(for: sender.tag),
              let controller = window?.windowController as? StarAskPromptWindowController else {
            return
        }
        controller.choose(status)
    }

    private func tag(for status: StarAskPromptStatus) -> Int {
        switch status {
        case .notShown: return 0
        case .later: return 1
        case .starred: return 2
        case .dismissed: return 3
        }
    }

    private func status(for tag: Int) -> StarAskPromptStatus? {
        switch tag {
        case 1: return .later
        case 2: return .starred
        case 3: return .dismissed
        default: return nil
        }
    }
}
