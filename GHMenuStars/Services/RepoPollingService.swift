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
        presentStarAskIfNeeded(delta: delta, repoID: repoID)
    }

    private func presentStarAskIfNeeded(delta: RepoDelta, repoID: UUID) {
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
