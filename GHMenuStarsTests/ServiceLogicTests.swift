import XCTest
import Security
import AppKit
@testable import GHMenuStars

@MainActor
final class ServiceLogicTests: XCTestCase {
    func testDeltaDetectionAndNotificationDedupeState() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual, lastStars: 10, lastDownloads: 20, lastForks: 2)
        store.setTrackedRepo(repo)

        let delta = store.apply(
            snapshot: RepoSnapshot(stars: 13, releaseDownloads: 30, forks: 4, checkedAt: Date(), repoETag: "r", releasesETag: "rel"),
            to: repo.id
        )

        XCTAssertEqual(delta, RepoDelta(starsDelta: 3, downloadsDelta: 10, forksDelta: 2))
        store.markNotified(repoID: repo.id, stars: 13, downloads: nil)
        XCTAssertEqual(store.trackedRepos.first?.lastNotifiedStars, 13)
        XCTAssertEqual(store.trackedRepos.first?.lastStarsDelta, 3)
        XCTAssertEqual(store.trackedRepos.first?.lastDownloadsDelta, 10)
        XCTAssertEqual(store.trackedRepos.first?.lastForksDelta, 2)
        XCTAssertEqual(store.trackedRepos.first?.trendPoints, [])
    }

    func testTrendBuilderUsesGitHubEventDatesForLastYear() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 9))!
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -365, to: now)!)
        let points = RepoTrendBuilder.points(
            stars: 10,
            forks: 4,
            starDates: [
                calendar.date(byAdding: .day, value: 10, to: start)!,
                calendar.date(byAdding: .day, value: 300, to: start)!
            ],
            forkDates: [
                calendar.date(byAdding: .day, value: 30, to: start)!
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(points.first, RepoTrendPoint(date: start, stars: 8, forks: 3))
        XCTAssertEqual(points.last?.stars, 10)
        XCTAssertEqual(points.last?.forks, 4)
        XCTAssertEqual(points.count, 366)
    }

    func testTrendAxisTicksAdaptToRangeLength() {
        let calendar = Calendar(identifier: .gregorian)
        let longStart = calendar.date(from: DateComponents(year: 2021, month: 6, day: 13))!
        let longEnd = calendar.date(from: DateComponents(year: 2026, month: 6, day: 13))!
        let longTicks = RepoTrendAxisTickBuilder.ticks(start: longStart, end: longEnd, calendar: calendar)
        XCTAssertEqual(longTicks.map(\.label), ["2022", "2023", "2024", "2025", "2026"])

        let monthStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let monthEnd = calendar.date(from: DateComponents(year: 2026, month: 6, day: 13))!
        let monthComponents = RepoTrendAxisTickBuilder
            .ticks(start: monthStart, end: monthEnd, calendar: calendar)
            .map { calendar.component(.month, from: $0.date) }
        XCTAssertEqual(monthComponents, [2, 3, 4, 5, 6])

        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let dayEnd = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let dayComponents = RepoTrendAxisTickBuilder
            .ticks(start: dayStart, end: dayEnd, calendar: calendar)
            .map { calendar.component(.day, from: $0.date) }
        XCTAssertEqual(dayComponents, [8, 15, 22, 29])
    }

    func testStoreReplacesTrendFromSnapshotWithoutAccumulating() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual, lastStars: 10, lastForks: 1)
        store.setTrackedRepo(repo)

        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 9))!
        let trend = [
            RepoTrendPoint(date: day.addingTimeInterval(-86_400), stars: 11, forks: 2),
            RepoTrendPoint(date: day, stars: 12, forks: 3)
        ]

        _ = store.apply(
            snapshot: RepoSnapshot(
                stars: 12,
                releaseDownloads: 0,
                forks: 3,
                checkedAt: day,
                repoETag: nil,
                releasesETag: nil,
                trendPoints: trend
            ),
            to: repo.id
        )
        _ = store.apply(
            snapshot: RepoSnapshot(stars: 13, releaseDownloads: 0, forks: 4, checkedAt: day.addingTimeInterval(3600), repoETag: nil, releasesETag: nil),
            to: repo.id
        )

        XCTAssertEqual(store.trackedRepos.first?.trendPoints, trend)
    }

    func testUpsertAddsMultipleReposAndPreservesExistingIdentity() throws {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let first = TrackedRepo(
            owner: "Owner",
            name: "Repo",
            source: .manual,
            lastStars: 10,
            lastNotifiedStars: 9,
            etagRepo: "old"
        )
        let second = TrackedRepo(owner: "other", name: "repo", source: .manual, lastStars: 4)

        try store.upsertTrackedRepo(first)
        try store.upsertTrackedRepo(second)
        try store.upsertTrackedRepo(TrackedRepo(owner: "owner", name: "repo", source: .oauth, lastStars: 12, etagRepo: "new"))

        XCTAssertEqual(store.trackedRepos.count, 2)
        XCTAssertEqual(store.trackedRepos[0].id, first.id)
        XCTAssertEqual(store.trackedRepos[0].source, .oauth)
        XCTAssertEqual(store.trackedRepos[0].lastStars, 12)
        XCTAssertEqual(store.trackedRepos[0].lastNotifiedStars, 9)
        XCTAssertEqual(store.trackedRepos[0].etagRepo, "new")
        XCTAssertEqual(store.trackedRepos[0].starSound, .glass)
    }

    func testPerRepoStarSoundPersistence() throws {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)

        try store.upsertTrackedRepo(repo)
        store.setStarSound(.tinyFanfare, for: repo.id)

        let reloaded = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        XCTAssertEqual(reloaded.trackedRepos.first?.starSound, .tinyFanfare)
    }

    func testUpsertRejectsSixthRepo() throws {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)

        for index in 0..<TrackedRepoStore.maximumTrackedRepos {
            try store.upsertTrackedRepo(TrackedRepo(owner: "owner", name: "repo-\(index)", source: .manual))
        }

        XCTAssertThrowsError(try store.upsertTrackedRepo(TrackedRepo(owner: "owner", name: "repo-over", source: .manual))) { error in
            XCTAssertEqual(error as? TrackedRepoStoreError, .maximumReached(TrackedRepoStore.maximumTrackedRepos))
        }
    }

    func testMenuBarDisplayResolverUsesSelectedAndTotals() throws {
        let first = TrackedRepo(owner: "owner", name: "one", source: .manual, lastStars: 10, lastDownloads: 3)
        let second = TrackedRepo(owner: "owner", name: "two", source: .manual, lastStars: 20, lastDownloads: 7)
        var settings = AppSettings()
        settings.selectedMenuBarRepoID = second.id

        var value = MenuBarDisplayResolver.value(repos: [first, second], settings: settings)
        XCTAssertEqual(value.text, "20")
        XCTAssertEqual(value.symbolName, "star.fill")

        settings.menuBarDisplayMode = .selectedRepoDownloads
        value = MenuBarDisplayResolver.value(repos: [first, second], settings: settings)
        XCTAssertEqual(value.text, "7")
        XCTAssertEqual(value.symbolName, "arrow.down.circle.fill")

        settings.menuBarDisplayMode = .totalStars
        value = MenuBarDisplayResolver.value(repos: [first, second], settings: settings)
        XCTAssertEqual(value.text, "30")

        settings.menuBarDisplayMode = .totalDownloads
        value = MenuBarDisplayResolver.value(repos: [first, second], settings: settings)
        XCTAssertEqual(value.text, "10")
    }

    func testMenuBarDisplayResolverKeepsUnknownTotalsBlank() throws {
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        var settings = AppSettings()

        settings.menuBarDisplayMode = .totalStars
        var value = MenuBarDisplayResolver.value(repos: [repo], settings: settings)
        XCTAssertEqual(value.text, "--")
        XCTAssertEqual(value.accessibilityLabel, "Total GitHub stars not checked yet")

        settings.menuBarDisplayMode = .totalDownloads
        value = MenuBarDisplayResolver.value(repos: [repo], settings: settings)
        XCTAssertEqual(value.text, "--")
        XCTAssertEqual(value.accessibilityLabel, "Total release downloads not checked yet")
    }

    func testRefreshIntervalDurations() {
        XCTAssertEqual(RefreshInterval.tenMinutes.timeInterval, 600)
        XCTAssertEqual(RefreshInterval.sixtyMinutes.timeInterval, 3600)
        XCTAssertEqual(RefreshInterval.oneDay.timeInterval, 86_400)
    }

    func testSettingsPersistence() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults, legacyDefaults: nil)
        store.update { settings in
            settings.refreshInterval = .oneDay
            settings.hideDockIcon = false
            settings.isMuted = true
        }

        let reloaded = SettingsStore(defaults: defaults, legacyDefaults: nil)
        XCTAssertEqual(reloaded.settings.refreshInterval, .oneDay)
        XCTAssertFalse(reloaded.settings.hideDockIcon)
        XCTAssertTrue(reloaded.settings.isMuted)
        XCTAssertEqual(reloaded.settings.menuBarDisplayMode, .selectedRepoStars)
        XCTAssertEqual(reloaded.settings.starSoundThreshold, .one)
        XCTAssertEqual(reloaded.settings.celebrationMode, .subtle)
        XCTAssertEqual(reloaded.settings.repoTrendRange, .all)
    }

    func testSettingsMigrateFromLegacyBundleDefaults() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let legacyDefaults = UserDefaults(suiteName: "GHMenuStarsTests.Legacy.\(UUID().uuidString)")!
        let legacySettingsJSON = """
        {
          "refreshInterval": "oneDay",
          "hideDockIcon": false,
          "notifyOnStarIncrease": true,
          "playSoundOnStarIncrease": true,
          "animateOnStarIncrease": false,
          "isMuted": true,
          "gitHubOAuthClientID": "legacy-client"
        }
        """
        legacyDefaults.set(Data(legacySettingsJSON.utf8), forKey: "GHMenuStars.AppSettings.v1")

        let store = SettingsStore(defaults: defaults, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.settings.refreshInterval, .oneDay)
        XCTAssertFalse(store.settings.hideDockIcon)
        XCTAssertTrue(store.settings.isMuted)
        XCTAssertEqual(store.settings.gitHubOAuthClientID, "legacy-client")
        XCTAssertEqual(store.settings.celebrationMode, .off)
        XCTAssertNotNil(defaults.data(forKey: "GHMenuStars.AppSettings.v1"))
    }

    func testSettingsDecodeDefaultsMissingMute() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let legacySettingsJSON = """
        {
          "refreshInterval": "sixtyMinutes",
          "hideDockIcon": false,
          "notifyOnStarIncrease": false,
          "playSoundOnStarIncrease": true,
          "animateOnStarIncrease": false,
          "gitHubOAuthClientID": "saved-client"
        }
        """
        defaults.set(Data(legacySettingsJSON.utf8), forKey: "GHMenuStars.AppSettings.v1")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.refreshInterval, .sixtyMinutes)
        XCTAssertFalse(store.settings.hideDockIcon)
        XCTAssertFalse(store.settings.notifyOnStarIncrease)
        XCTAssertTrue(store.settings.playSoundOnStarIncrease)
        XCTAssertFalse(store.settings.animateOnStarIncrease)
        XCTAssertEqual(store.settings.celebrationMode, .off)
        XCTAssertFalse(store.settings.isMuted)
        XCTAssertEqual(store.settings.gitHubOAuthClientID, "saved-client")
        XCTAssertEqual(store.settings.menuBarDisplayMode, .selectedRepoStars)
        XCTAssertNil(store.settings.selectedMenuBarRepoID)
        XCTAssertEqual(store.settings.starSoundThreshold, .one)
        XCTAssertEqual(store.settings.repoTrendRange, .all)
    }

    func testStarSoundThresholds() {
        XCTAssertTrue(StarSoundThreshold.one.isMet(by: 1))
        XCTAssertFalse(StarSoundThreshold.ten.isMet(by: 9))
        XCTAssertTrue(StarSoundThreshold.ten.isMet(by: 10))
        XCTAssertFalse(StarSoundThreshold.hundred.isMet(by: 99))
        XCTAssertTrue(StarSoundThreshold.hundred.isMet(by: 100))

        XCTAssertFalse(StarSoundThreshold.one.isMet(starsDelta: 0, downloadsDelta: 2, downloads: 9))
        XCTAssertTrue(StarSoundThreshold.one.isMet(starsDelta: 0, downloadsDelta: 1, downloads: 10))
        XCTAssertFalse(StarSoundThreshold.ten.isMet(starsDelta: 0, downloadsDelta: 30, downloads: 90))
        XCTAssertTrue(StarSoundThreshold.ten.isMet(starsDelta: 0, downloadsDelta: 20, downloads: 100))
        XCTAssertTrue(StarSoundThreshold.hundred.isMet(starsDelta: 100, downloadsDelta: 0, downloads: 0))
    }

    func testStarAskPromptTriggerQualifiesOnlyForMeaningfulGrowth() {
        XCTAssertEqual(
            StarAskPromptTrigger.trigger(for: RepoDelta(starsDelta: 1, downloadsDelta: 0)),
            .starIncrease(1)
        )
        XCTAssertNil(StarAskPromptTrigger.trigger(for: RepoDelta(starsDelta: 0, downloadsDelta: 19)))
        XCTAssertEqual(
            StarAskPromptTrigger.trigger(for: RepoDelta(starsDelta: 0, downloadsDelta: 20)),
            .downloadIncrease(20)
        )
    }

    func testStorePersistsStarAskPromptStatusPerRepo() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        let promptedAt = Date()
        store.setTrackedRepo(repo)

        store.markStarAskPrompt(repoID: repo.id, status: .dismissed, at: promptedAt)

        XCTAssertEqual(store.trackedRepos.first?.starAskPromptStatus, .dismissed)
        XCTAssertEqual(store.trackedRepos.first?.lastStarAskPromptedAt, promptedAt)
        XCTAssertFalse(store.trackedRepos.first?.starAskPromptStatus.canPrompt ?? true)
    }

    func testMilestoneRoundingUsesPresetAndHundreds() {
        XCTAssertEqual(MilestoneRounding.displayValue(for: 3), 3)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 9), 9)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 50), 50)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 99), 50)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 605), 600)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 631), 600)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 1_250), 1_000)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 22_400), 20_000)
    }

    func testMilestoneShareKeepsRequestedMetric() {
        let smallRepo = TrackedRepo(owner: "owner", name: "small", source: .manual, lastStars: 3, lastDownloads: 50)
        let largerRepo = TrackedRepo(owner: "owner", name: "larger", source: .manual, lastStars: 631, lastDownloads: 5_000)

        let smallStars = RepoMilestoneShare.make(repo: smallRepo, metric: .stars)
        XCTAssertEqual(smallStars?.metric, .stars)
        XCTAssertEqual(smallStars?.milestoneValue, 3)

        let largerStars = RepoMilestoneShare.make(repo: largerRepo, metric: .stars)
        XCTAssertEqual(largerStars?.metric, .stars)
        XCTAssertEqual(largerStars?.milestoneValue, 600)
    }

    func testMilestoneShareTextIncludesRoundedAndCurrentCount() {
        let share = RepoMilestoneShare(
            repoDisplayName: "owner/repo",
            metric: .downloads,
            currentValue: 605,
            milestoneValue: 600
        )

        let text = MilestoneShareTextBuilder.text(for: share)

        XCTAssertTrue(text.contains("owner/repo"))
        XCTAssertTrue(text.contains("600+ downloads (605 now)"))
        XCTAssertTrue(text.contains("Stargazer Bar"))
    }

    func testRateLimitParsing() {
        let reset = Int(Date().addingTimeInterval(600).timeIntervalSince1970)
        let state = RateLimitState.from(headers: [
            "X-RateLimit-Limit": "60",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "\(reset)"
        ])
        XCTAssertEqual(state?.limit, 60)
        XCTAssertTrue(state?.isLimited == true)
    }

    func testTrackedReposMigrateFromLegacyBundleDefaults() throws {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let legacyDefaults = UserDefaults(suiteName: "GHMenuStarsTests.Legacy.\(UUID().uuidString)")!
        let repo = TrackedRepo(owner: "old", name: "repo", source: .manual, lastStars: 42, lastDownloads: 7)
        let delta = RepoDelta(starsDelta: 2, downloadsDelta: 1, forksDelta: 0)
        legacyDefaults.set(try JSONEncoder().encode([repo]), forKey: "GHMenuStars.TrackedRepos.v1")
        legacyDefaults.set(try JSONEncoder().encode(delta), forKey: "GHMenuStars.LastDelta.v1")

        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.trackedRepos, [repo])
        XCTAssertEqual(store.lastDelta, delta)
        XCTAssertEqual(store.trackedRepos.first?.starSound, .glass)
        XCTAssertNotNil(defaults.data(forKey: "GHMenuStars.TrackedRepos.v1"))
        XCTAssertNotNil(defaults.data(forKey: "GHMenuStars.LastDelta.v1"))
    }

    func testMenuTextFormatting() {
        XCTAssertEqual(RepoDeltaFormatter.metricLine(label: "★", value: 1248, delta: 3), "★ 1,248  +3")
        XCTAssertEqual(RepoDeltaFormatter.metricLine(label: "Release downloads:", value: 42918, delta: 120), "Release downloads: 42,918  +120")
    }

    func testStatusMenuKeepsSettingsOnlyActionsOutOfMenu() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual, lastStars: 3, lastDownloads: 90, lastForks: 1)
        repoStore.setTrackedRepo(repo)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.selectedMenuBarRepoID = repo.id }
        let updaterController = UpdaterController()
        let pollingService = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: GitHubClient(),
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )
        let controller = StatusItemController(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController,
            animationCoordinator: AnimationCoordinator()
        )

        let menu = StatusMenuBuilder(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController
        ).build(target: controller)
        let titles = Self.menuTitles(in: menu)

        XCTAssertFalse(titles.contains("Automatic Updates"))
        XCTAssertFalse(titles.contains("Show in Menu Bar"))
        XCTAssertFalse(titles.contains("Shown in Menu Bar"))
        XCTAssertFalse(titles.contains("Debug: Show Growth Prompt"))
        XCTAssertTrue(titles.contains("Share Selected Milestone"))
        XCTAssertTrue(titles.contains("Share Milestone"))
        XCTAssertTrue(titles.contains("Copy Stars Text"))
        XCTAssertTrue(titles.contains("Copy Stars Image"))
        XCTAssertTrue(titles.contains("Copy Downloads Text"))
        XCTAssertTrue(titles.contains("Copy Downloads Image"))
        XCTAssertTrue(titles.contains("Compose X Stars Post + Copy Image"))
        XCTAssertTrue(titles.contains("Compose X Downloads Post + Copy Image"))
        XCTAssertFalse(titles.contains("Compose X Post + Copy Image"))
        XCTAssertEqual(
            (Self.menuItem(titled: "Compose X Stars Post + Copy Image", in: menu)?.representedObject as? MilestoneShareRequest)?.metric,
            .stars
        )
        XCTAssertEqual(
            (Self.menuItem(titled: "Compose X Downloads Post + Copy Image", in: menu)?.representedObject as? MilestoneShareRequest)?.metric,
            .downloads
        )
    }

    func testStatusMenuHidesTopLevelShareWhenSelectedRepoHasNoMetrics() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        repoStore.setTrackedRepo(repo)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.selectedMenuBarRepoID = repo.id }
        let updaterController = UpdaterController()
        let pollingService = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: GitHubClient(),
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )
        let controller = StatusItemController(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController,
            animationCoordinator: AnimationCoordinator()
        )

        let menu = StatusMenuBuilder(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController
        ).build(target: controller)

        XCTAssertFalse(Self.menuTitles(in: menu).contains("Share Selected Milestone"))
    }

    func testStatusMenuShowsMaintainerRadarPerRepo() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(
            owner: "owner",
            name: "repo",
            source: .manual,
            maintainerRadar: RepoMaintainerRadar(
                openPullRequests: 2,
                unansweredIssues: 5,
                latestFailedWorkflow: RepoWorkflowFailure(name: "Tests", url: "https://github.com/owner/repo/actions/runs/1"),
                workflowChecked: true,
                checkedAt: Date()
            )
        )
        repoStore.setTrackedRepo(repo)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let updaterController = UpdaterController()
        let pollingService = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: GitHubClient(),
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )
        let controller = StatusItemController(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController,
            animationCoordinator: AnimationCoordinator()
        )

        let menu = StatusMenuBuilder(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController
        ).build(target: controller)
        let titles = Self.menuTitles(in: menu)

        XCTAssertTrue(titles.contains("Maintainer Radar: 8 items"))
        XCTAssertTrue(titles.contains("CI failing: Tests"))
        XCTAssertTrue(titles.contains("2 open PRs"))
        XCTAssertTrue(titles.contains("5 unanswered issues"))
        XCTAssertTrue(titles.contains("Discussion topics"))
        XCTAssertEqual(
            (Self.menuItem(titled: "2 open PRs", in: menu)?.representedObject as? URL)?.absoluteString,
            "https://github.com/owner/repo/pulls?q=is:pr%20is:open"
        )
    }

    func testDockActivationPolicySafety() {
        XCTAssertEqual(ActivationPolicyDecider.policy(hideDockIcon: true, hasStatusItem: true), .accessory)
        XCTAssertEqual(ActivationPolicyDecider.policy(hideDockIcon: true, hasStatusItem: false), .regular)
        XCTAssertEqual(ActivationPolicyDecider.policy(hideDockIcon: false, hasStatusItem: true), .regular)
    }

    func testAppBundleLaunchesAsMenuBarAgent() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    func testDockRecentAppCleanerRemovesOnlyCurrentApp() {
        let currentApp: [String: Any] = [
            "tile-data": [
                "bundle-identifier": "com.jazzyalex.StargazerBar",
                "file-label": "Stargazer Bar"
            ]
        ]
        let currentAppByURL: [String: Any] = [
            "tile-data": [
                "file-label": "Stargazer Bar",
                "file-data": [
                    "_CFURLString": "file:///Applications/Stargazer%20Bar.app/"
                ]
            ]
        ]
        let otherApp: [String: Any] = [
            "tile-data": [
                "bundle-identifier": "com.apple.Safari",
                "file-label": "Safari"
            ]
        ]

        let cleaned = DockRecentAppCleaner.removingApp(
            from: [otherApp, currentApp, currentAppByURL],
            bundleIdentifier: "com.jazzyalex.StargazerBar",
            bundleURL: URL(string: "file:///Applications/Stargazer%20Bar.app/")!
        )

        XCTAssertEqual(cleaned.count, 1)
        let tileData = (cleaned[0] as? [String: Any])?["tile-data"] as? [String: Any]
        XCTAssertEqual(tileData?["bundle-identifier"] as? String, "com.apple.Safari")
    }

    func testAppDelegateDetectsHostedUnitTests() {
        XCTAssertTrue(AppDelegate.isHostedUnitTest(environment: [
            "XCTestConfigurationFilePath": "/tmp/GHMenuStarsTests.xctestconfiguration"
        ]))
        XCTAssertTrue(AppDelegate.isHostedUnitTest(environment: [
            "XCTestBundlePath": "/tmp/GHMenuStarsTests.xctest"
        ]))
        XCTAssertFalse(AppDelegate.isHostedUnitTest(environment: [:]))
    }

    func testGitHubOAuthConfigurationUsesEnvironmentAndIgnoresPlaceholders() {
        var settings = AppSettings()
        settings.gitHubOAuthClientID = "$(GHMENUSTARS_GITHUB_OAUTH_CLIENT_ID)"
        XCTAssertNil(GitHubOAuthConfiguration.clientID(settings: settings, environment: [:], infoDictionaryClientID: nil))

        XCTAssertEqual(
            GitHubOAuthConfiguration.clientID(settings: settings, environment: [
                "GH_MENU_STARS_GITHUB_CLIENT_ID": "abc123"
            ], infoDictionaryClientID: nil),
            "abc123"
        )

        XCTAssertEqual(
            GitHubOAuthConfiguration.clientID(settings: settings, environment: [
                "GH_MENU_STARS_GITHUB_CLIENT_ID": "env-client"
            ], infoDictionaryClientID: "bundle-client"),
            "env-client"
        )

        XCTAssertEqual(
            GitHubOAuthConfiguration.clientID(settings: settings, environment: [:], infoDictionaryClientID: "bundle-client"),
            "bundle-client"
        )

        settings.gitHubOAuthClientID = "saved-client"
        XCTAssertEqual(
            GitHubOAuthConfiguration.clientID(settings: settings, environment: [:], infoDictionaryClientID: nil),
            "saved-client"
        )
    }

    func testKeychainTokenReadCanDisableAuthenticationUI() throws {
        var capturedQuery: [String: Any] = [:]
        let store = KeychainTokenStore(service: "test-service") { query, _ in
            capturedQuery = query as! [String: Any]
            return errSecInteractionNotAllowed
        }

        XCTAssertNil(try store.loadToken(allowUserInteraction: false))
        XCTAssertNotNil(capturedQuery[kSecUseAuthenticationContext as String])
    }

    private static func menuTitles(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            let title = item.title.isEmpty ? [] : [item.title]
            guard let submenu = item.submenu else { return title }
            return title + menuTitles(in: submenu)
        }
    }

    private static func menuItem(titled expectedTitle: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == expectedTitle {
                return item
            }
            if let submenu = item.submenu, let match = menuItem(titled: expectedTitle, in: submenu) {
                return match
            }
        }
        return nil
    }
}
