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

    func testPerRepoMutePersistsAndDefaultsToFalse() throws {
        // Missing key decodes to false (backward compatible with pre-mute data).
        let legacy = Data(#"{"id":"F7B1C0A2-0000-0000-0000-000000000001","owner":"o","name":"r","displayName":"o/r","source":"manual","starSound":"glass"}"#.utf8)
        let decoded = try JSONDecoder().decode(TrackedRepo.self, from: legacy)
        XCTAssertFalse(decoded.isMuted)

        // Round-trips when set.
        var repo = decoded
        repo.isMuted = true
        let roundTripped = try JSONDecoder().decode(TrackedRepo.self, from: JSONEncoder().encode(repo))
        XCTAssertTrue(roundTripped.isMuted)
    }

    func testStoreSetMutedUpdatesAndPersists() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        store.setTrackedRepo(repo)
        XCTAssertFalse(store.trackedRepos.first?.isMuted ?? true)

        store.setMuted(true, for: repo.id)
        XCTAssertTrue(store.trackedRepos.first?.isMuted ?? false)

        let reloaded = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        XCTAssertTrue(reloaded.trackedRepos.first?.isMuted ?? false)
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

    func testTrendExtendAppendsNewDaysPreservesHistoryAndPinsTotals() {
        let calendar = Calendar(identifier: .gregorian)
        let day0 = calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!)
        let existing = [
            RepoTrendPoint(date: day0, stars: 100, forks: 10),
            RepoTrendPoint(date: calendar.date(byAdding: .day, value: 1, to: day0)!, stars: 102, forks: 10)
        ]
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!
        let newStar = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 8))!

        let extended = RepoTrendBuilder.extend(
            existing: existing,
            newStarDates: [newStar, newStar],
            newForkDates: [newStar],
            totalStars: 104,
            totalForks: 11,
            now: now,
            calendar: calendar
        )

        // Historical prefix is preserved verbatim; one new day (Jun 3) is appended.
        XCTAssertEqual(extended.count, 3)
        XCTAssertEqual(extended[0], existing[0])
        XCTAssertEqual(extended[1], existing[1])
        XCTAssertEqual(extended.last?.date, calendar.startOfDay(for: now))
        // Final point is pinned to the true totals.
        XCTAssertEqual(extended.last?.stars, 104)
        XCTAssertEqual(extended.last?.forks, 11)
    }

    func testTrendExtendBumpsCurrentDayWithoutAddingPoints() {
        let calendar = Calendar(identifier: .gregorian)
        let day0 = calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!)
        let existing = [
            RepoTrendPoint(date: day0, stars: 100, forks: 10),
            RepoTrendPoint(date: calendar.date(byAdding: .day, value: 1, to: day0)!, stars: 102, forks: 10)
        ]
        // Same calendar day as the last point, later in the day.
        let now = calendar.date(byAdding: .hour, value: 30, to: day0)!
        let newStar = calendar.date(byAdding: .hour, value: 29, to: day0)!

        let extended = RepoTrendBuilder.extend(
            existing: existing,
            newStarDates: [newStar],
            newForkDates: [],
            totalStars: 103,
            totalForks: 10,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(extended.count, 2)
        XCTAssertEqual(extended.last?.stars, 103)
        XCTAssertEqual(extended.last?.forks, 10)
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
        XCTAssertEqual(MilestoneRounding.displayValue(for: 4_200), 4_000)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 6_500), 6_000)
        XCTAssertEqual(MilestoneRounding.displayValue(for: 9_992), 9_000)
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

        // Regression: 9,992 downloads must round to 9,000, not collapse to 5,000.
        let downloadsRepo = TrackedRepo(owner: "owner", name: "downloads", source: .manual, lastStars: 708, lastDownloads: 9_992)
        let downloads = RepoMilestoneShare.make(repo: downloadsRepo, metric: .downloads)
        XCTAssertEqual(downloads?.metric, .downloads)
        XCTAssertEqual(downloads?.milestoneValue, 9_000)
        XCTAssertEqual(downloads?.currentValue, 9_992)
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

    func testStoreClearsOnlyExpiredRateLimit() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)

        store.updateRateLimit(RateLimitState(limit: 60, remaining: 0, resetAt: Date().addingTimeInterval(60)))
        store.clearExpiredRateLimit()
        XCTAssertNotNil(store.rateLimitState)

        store.updateRateLimit(RateLimitState(limit: 60, remaining: 0, resetAt: Date().addingTimeInterval(-1)))
        store.clearExpiredRateLimit()
        XCTAssertNil(store.rateLimitState)
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
            repoAccess: GitHubRepoAccess(
                client: GitHubClient(),
                patProvider: { nil },
                ambientProvider: { nil }
            ),
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
        XCTAssertFalse(titles.contains("Open Selected on GitHub"))
        XCTAssertTrue(titles.contains("Share Selected Milestone"))
        XCTAssertTrue(titles.contains("Share Milestone"))
        // Stars-only share menu, milestone number surfaced in each title (repo has 3 stars).
        XCTAssertTrue(titles.contains("Copy Text (3+ stars)"))
        XCTAssertTrue(titles.contains("Copy Image (3+ stars)"))
        XCTAssertTrue(titles.contains("Compose X Post + Copy Image (3+ stars)"))
        XCTAssertFalse(titles.contains("Copy Stars Text"))
        XCTAssertFalse(titles.contains("Copy Downloads Text"))
        XCTAssertFalse(titles.contains("Copy Downloads Image"))
        XCTAssertFalse(titles.contains("Compose X Downloads Post + Copy Image"))
        XCTAssertEqual(
            (Self.menuItem(titled: "Copy Image (3+ stars)", in: menu)?.representedObject as? MilestoneShareRequest)?.metric,
            .stars
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
            repoAccess: GitHubRepoAccess(
                client: GitHubClient(),
                patProvider: { nil },
                ambientProvider: { nil }
            ),
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
                newPullRequests: 1,
                newIssues: 3,
                unansweredIssues: 5,
                recentCommits: 7,
                activityWindow: .oneDay,
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
            repoAccess: GitHubRepoAccess(
                client: GitHubClient(),
                patProvider: { nil },
                ambientProvider: { nil }
            ),
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

        // Redesigned dense layout: one packed activity line + one open-state row.
        XCTAssertTrue(titles.contains("CI failing: Tests"))
        XCTAssertTrue(titles.contains("Last 24h"))
        XCTAssertTrue(titles.contains("7 commits on main · 1 new PR · 3 new issues"))
        XCTAssertTrue(titles.contains("2 open PRs · 5 need first reply"))
        XCTAssertTrue(titles.contains("Open Discussions"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("updated ") })
        // The old per-metric rows are gone.
        XCTAssertFalse(titles.contains("1 new PR last 24h"))
        XCTAssertFalse(titles.contains("2 open PRs"))
        XCTAssertEqual(
            (Self.menuItem(titled: "2 open PRs · 5 need first reply", in: menu)?.representedObject as? URL)?
                .absoluteString.hasPrefix("https://github.com/owner/repo/issues"),
            true
        )
        XCTAssertEqual(
            (Self.menuItem(titled: "7 commits on main · 1 new PR · 3 new issues", in: menu)?.representedObject as? URL)?
                .absoluteString,
            "https://github.com/owner/repo/commits"
        )
    }

    func testStatusMenuKeepsZeroRadarCountsRegular() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(
            owner: "owner",
            name: "repo",
            source: .manual,
            maintainerRadar: RepoMaintainerRadar(
                openPullRequests: 0,
                newPullRequests: 0,
                newIssues: 0,
                unansweredIssues: 0,
                recentCommits: 0,
                activityWindow: .oneDay,
                latestFailedWorkflow: nil,
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
            repoAccess: GitHubRepoAccess(
                client: GitHubClient(),
                patProvider: { nil },
                ambientProvider: { nil }
            ),
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

        XCTAssertFalse(Self.menuItem(titled: "0 new PRs last 24h", in: menu)?.hasBoldPrefix("0") == true)
        XCTAssertFalse(Self.menuItem(titled: "0 new issues last 24h", in: menu)?.hasBoldPrefix("0") == true)
        XCTAssertFalse(Self.menuItem(titled: "0 commits last 24h", in: menu)?.hasBoldPrefix("0") == true)
        XCTAssertFalse(Self.menuItem(titled: "0 open PRs", in: menu)?.hasBoldPrefix("0") == true)
        XCTAssertFalse(Self.menuItem(titled: "0 issues need first reply", in: menu)?.hasBoldPrefix("0") == true)
    }

    func testRepoLineBoldsFullDownloadNumberWithZeroStarDelta() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(
            owner: "owner",
            name: "repo",
            source: .manual,
            lastStars: 3,
            lastDownloads: 101,
            lastStarsDelta: 0,
            lastDownloadsDelta: 0
        )
        repoStore.setTrackedRepo(repo)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let updaterController = UpdaterController()
        let pollingService = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: GitHubClient(),
            repoAccess: GitHubRepoAccess(
                client: GitHubClient(),
                patProvider: { nil },
                ambientProvider: { nil }
            ),
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

        let item = Self.menuItem(containing: "⤓ 101", in: menu)
        XCTAssertNotNil(item)
        // The zero star delta is omitted from the text but previously was still
        // searched for as "0", which matched the middle digit of "101" and bolded
        // only that one character. The full download number must be bold instead.
        XCTAssertTrue(item?.isFullyBold("101") == true)
        XCTAssertTrue(item?.isFullyBold("3") == true)
    }

    func testReleaseDynamicsFreshnessAndMath() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(ReleaseDynamics.isFresh(publishedAt: now.addingTimeInterval(-60 * 60 * 24 * 3), now: now))
        XCTAssertFalse(ReleaseDynamics.isFresh(publishedAt: now.addingTimeInterval(-60 * 60 * 24 * 20), now: now))
        // 1000 downloads over 5 days -> 200/day
        XCTAssertEqual(ReleaseDynamics.dailyRate(downloads: 1000, publishedAt: now.addingTimeInterval(-60 * 60 * 24 * 5), now: now), 200)
        // younger than a day -> denominator floored to 1 day
        XCTAssertEqual(ReleaseDynamics.dailyRate(downloads: 50, publishedAt: now.addingTimeInterval(-60 * 60 * 2), now: now), 50)
        XCTAssertEqual(ReleaseDynamics.sharePercent(downloads: 380, totalDownloads: 1000), 38)
        XCTAssertNil(ReleaseDynamics.sharePercent(downloads: 0, totalDownloads: 0))
    }

    func testValueAtReturnsNearestPointAtOrBeforeDate() {
        let points = [
            RepoTrendPoint(date: Date(timeIntervalSince1970: 1_000_000), stars: 600, forks: 1),
            RepoTrendPoint(date: Date(timeIntervalSince1970: 1_400_000), stars: 623, forks: 3),
            RepoTrendPoint(date: Date(timeIntervalSince1970: 1_900_000), stars: 660, forks: 5)
        ]
        XCTAssertEqual(ReleaseDynamics.value(in: points, at: Date(timeIntervalSince1970: 1_500_000), keyPath: \.stars), 623)
        XCTAssertEqual(ReleaseDynamics.value(in: points, at: Date(timeIntervalSince1970: 1_500_000), keyPath: \.forks), 3)
        XCTAssertNil(ReleaseDynamics.value(in: points, at: Date(timeIntervalSince1970: 900_000), keyPath: \.stars))
        XCTAssertEqual(ReleaseDynamics.recentWindowDays, 30)
    }

    func testStarsSinceReleaseFromTrendPoints() {
        let publish = Date(timeIntervalSince1970: 1_500_000)
        let points = [
            RepoTrendPoint(date: Date(timeIntervalSince1970: 1_000_000), stars: 600, forks: 1),
            RepoTrendPoint(date: Date(timeIntervalSince1970: 1_400_000), stars: 623, forks: 1),
            RepoTrendPoint(date: Date(timeIntervalSince1970: 1_900_000), stars: 660, forks: 2)
        ]
        // nearest point at-or-before publish is 623 -> 665 - 623 = 42
        XCTAssertEqual(ReleaseDynamics.starsSinceRelease(trendPoints: points, currentStars: 665, publishedAt: publish), 42)
        // history starts after publish -> nil
        let late = [RepoTrendPoint(date: Date(timeIntervalSince1970: 1_600_000), stars: 640, forks: 1)]
        XCTAssertNil(ReleaseDynamics.starsSinceRelease(trendPoints: late, currentStars: 665, publishedAt: publish))
    }

    func testApplySnapshotPersistsLatestRelease() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        store.setTrackedRepo(repo)
        let summary = LatestReleaseSummary(tag: "v0.3.1", name: "0.3.1",
            publishedAt: Date(timeIntervalSince1970: 2_000_000), isPrerelease: false,
            downloads: 1_230, totalDownloads: 1_330,
            assets: [LatestReleaseSummary.AssetCount(label: "arm64.dmg", count: 820)])
        let snapshot = RepoSnapshot(stars: 1, releaseDownloads: 1_330, forks: 0,
            checkedAt: Date(), repoETag: nil, releasesETag: nil,
            latestRelease: summary)
        _ = store.apply(snapshot: snapshot, to: repo.id)
        XCTAssertEqual(store.trackedRepos.first?.latestRelease?.tag, "v0.3.1")
    }

    func testApplySnapshotPersistsRecentReleases() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual)
        store.setTrackedRepo(repo)
        let recent = RecentReleasesSummary(releaseCount: 2, downloads: 500, totalDownloads: 900)
        let snapshot = RepoSnapshot(stars: 1, releaseDownloads: 900, forks: 0,
            checkedAt: Date(), repoETag: nil, releasesETag: nil, recentReleases: recent)
        _ = store.apply(snapshot: snapshot, to: repo.id)
        XCTAssertEqual(store.trackedRepos.first?.recentReleases?.releaseCount, 2)
    }

    func testReleaseLineFormatterPacksAdoption() {
        let summary = LatestReleaseSummary(tag: "v0.3.1", name: "0.3.1",
            publishedAt: Date(timeIntervalSince1970: 2_000_000 - 60 * 60 * 24 * 5),
            isPrerelease: false, downloads: 1_000, totalDownloads: 2_631,
            assets: [LatestReleaseSummary.AssetCount(label: "arm64.dmg", count: 820),
                     LatestReleaseSummary.AssetCount(label: "zip", count: 410)])
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(ReleaseLineFormatter.adoptionLine(summary, now: now), "1,000 ⤓ · ~200/day · 38% of all")
        XCTAssertEqual(ReleaseLineFormatter.assetLine(summary), "arm64.dmg 820 · zip 410")
    }

    func testRecentReleasesRowsFormatAllFour() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let day = 24.0 * 60 * 60
        let points = [
            RepoTrendPoint(date: now.addingTimeInterval(-65 * day), stars: 500, forks: 5),
            RepoTrendPoint(date: now.addingTimeInterval(-30 * day), stars: 540, forks: 7)
        ]
        let summary = RecentReleasesSummary(releaseCount: 3, downloads: 2_480, totalDownloads: 8_857)
        let rows = RecentReleasesLineFormatter.rows(summary, trendPoints: points, currentStars: 662, currentForks: 12, now: now).map(\.text)
        XCTAssertEqual(rows, [
            "3 releases · +122 ⭐ · +5 forks",
            "2,480 ⤓ · ~83/day · 28% of all",
            "↑ vs prior 30d · +40 ⭐ · +2 forks",
            "~1 release / 10 days · avg 827 ⤓/release"
        ])
    }

    func testRecentReleasesMomentumHiddenWhenPriorWindowFlat() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let day = 24.0 * 60 * 60
        let points = [
            RepoTrendPoint(date: now.addingTimeInterval(-65 * day), stars: 500, forks: 5),
            RepoTrendPoint(date: now.addingTimeInterval(-30 * day), stars: 500, forks: 5)
        ]
        let summary = RecentReleasesSummary(releaseCount: 0, downloads: 0, totalDownloads: 1_000)
        let rows = RecentReleasesLineFormatter.rows(summary, trendPoints: points, currentStars: 540, currentForks: 8, now: now).map(\.text)
        XCTAssertEqual(rows, ["+40 ⭐ · +3 forks"])
    }

    func testRecentReleasesRowsGrowthOnlyWhenNoReleasesInWindow() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let day = 24.0 * 60 * 60
        let points = [RepoTrendPoint(date: now.addingTimeInterval(-40 * day), stars: 600, forks: 3)]
        let summary = RecentReleasesSummary(releaseCount: 0, downloads: 0, totalDownloads: 5_000)
        let rows = RecentReleasesLineFormatter.rows(summary, trendPoints: points, currentStars: 640, currentForks: 4, now: now).map(\.text)
        XCTAssertEqual(rows, ["+40 ⭐ · +1 fork"])
    }

    func testMenuHidesZeroOpenRowsAndShowsReleaseBlock() {
        let radar = RepoMaintainerRadar(
            openPullRequests: 0, newPullRequests: 0, newIssues: 0, unansweredIssues: 0,
            recentCommits: 0, activityWindow: .oneDay, latestFailedWorkflow: nil,
            workflowChecked: true, checkedAt: Date())
        let release = LatestReleaseSummary(tag: "v0.3.1", name: "0.3.1",
            publishedAt: Date(timeIntervalSince1970: 2_000_000), isPrerelease: false,
            downloads: 1_000, totalDownloads: 2_631, assets: [])
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual,
            maintainerRadar: radar, latestRelease: release)
        let menu = buildMenu(for: repo)
        XCTAssertNil(Self.menuItem(titled: "0 open PRs", in: menu))
        XCTAssertNotNil(Self.menuItem(titled: "Latest release", in: menu))
        XCTAssertNotNil(Self.menuItem(containing: "nothing open", in: menu))
    }

    func testMenuLabelsActivitySinceReleaseWhenAnchored() {
        let radar = RepoMaintainerRadar(
            openPullRequests: 0, newPullRequests: 0, newIssues: 0, unansweredIssues: 0,
            recentCommits: 3, activityWindow: .oneDay,
            activityAnchoredSince: Date(timeIntervalSince1970: 1_900_000),
            latestFailedWorkflow: nil, workflowChecked: true, checkedAt: Date())
        let release = LatestReleaseSummary(tag: "v0.3.1", name: "0.3.1",
            publishedAt: Date(timeIntervalSince1970: 1_900_000), isPrerelease: false,
            downloads: 10, totalDownloads: 10, assets: [])
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual,
            maintainerRadar: radar, latestRelease: release)
        let menu = buildMenu(for: repo)
        XCTAssertNotNil(Self.menuItem(titled: "Since v0.3.1", in: menu))
    }

    func testMenuShowsLast30DaysSection() {
        let now = Date()
        let day = 24.0 * 60 * 60
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual,
            lastStars: 662, lastForks: 12,
            trendPoints: [
                RepoTrendPoint(date: now.addingTimeInterval(-65 * day), stars: 500, forks: 5),
                RepoTrendPoint(date: now.addingTimeInterval(-30 * day), stars: 540, forks: 7)
            ],
            recentReleases: RecentReleasesSummary(releaseCount: 3, downloads: 2_480, totalDownloads: 8_857))
        let menu = buildMenu(for: repo)
        XCTAssertNotNil(Self.menuItem(titled: "Last 30 days", in: menu))
        XCTAssertNotNil(Self.menuItem(containing: "⤓/release", in: menu))
    }

    private func buildMenu(for repo: TrackedRepo) -> NSMenu {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        repoStore.setTrackedRepo(repo)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let updaterController = UpdaterController()
        let pollingService = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: GitHubClient(),
            repoAccess: GitHubRepoAccess(
                client: GitHubClient(),
                patProvider: { nil },
                ambientProvider: { nil }
            ),
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
        return StatusMenuBuilder(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController
        ).build(target: controller)
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
        XCTAssertEqual(capturedQuery[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUISkip as String)
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

    private static func menuItem(containing substring: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title.contains(substring) {
                return item
            }
            if let submenu = item.submenu, let match = menuItem(containing: substring, in: submenu) {
                return match
            }
        }
        return nil
    }
    func testPATStoreUsesDistinctServiceAndAccountFromOAuth() {
        let oauth = KeychainTokenStore.gitHubOAuthStore()
        let pat = KeychainTokenStore.gitHubPATStore()

        XCTAssertEqual(oauth.service, "StargazerBar.GitHubOAuth")
        XCTAssertEqual(oauth.account, "github-oauth")
        XCTAssertEqual(pat.service, "StargazerBar.GitHubPAT")
        XCTAssertEqual(pat.account, "github-pat")
        // The (service, account) pair is the Keychain primary key; both must
        // differ so a PAT can never be read back as an OAuth token.
        XCTAssertNotEqual(oauth.service, pat.service)
        XCTAssertNotEqual(oauth.account, pat.account)
    }

    func testPATStoreReadsThroughInjectedCopyMatching() throws {
        var capturedService: String?
        var capturedAccount: String?
        let store = KeychainTokenStore(
            service: KeychainTokenStore.gitHubPATService,
            account: "github-pat"
        ) { query, _ in
            let dict = query as! [String: Any]
            capturedService = dict[kSecAttrService as String] as? String
            capturedAccount = dict[kSecAttrAccount as String] as? String
            return errSecItemNotFound
        }

        XCTAssertNil(try store.loadToken(allowUserInteraction: false))
        XCTAssertEqual(capturedService, "StargazerBar.GitHubPAT")
        XCTAssertEqual(capturedAccount, "github-pat")
    }


    func testPrivateReposFlagDefaultsOffAndSurvivesLegacyDecode() throws {
        // Fresh settings: the flag must be off, or a hotfix cut from main would
        // expose the PAT section before the menu bar has any private-repo answer.
        XCTAssertFalse(AppSettings().enablePrivateRepos)

        // Settings written by a build predating the flag must decode, not throw:
        // SettingsStore falls back to defaults on any decode error, which would
        // silently reset every setting the user has.
        // These keys are decoded non-optionally (SettingsStore.swift:158-167), so
        // omitting any of them throws keyNotFound before the flag is consulted.
        let legacy = Data("""
        {"refreshInterval":"tenMinutes","hideDockIcon":true,"notifyOnStarIncrease":true,
         "playSoundOnStarIncrease":false,"animateOnStarIncrease":true,
         "gitHubOAuthClientID":"","menuBarDisplayMode":"selectedRepoStars"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertFalse(decoded.enablePrivateRepos)

        var enabled = AppSettings()
        enabled.enablePrivateRepos = true
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(round.enablePrivateRepos)
    }


    func testTrackedRepoDecodesLegacyJSONWithoutIsPrivate() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","owner":"o","name":"n","displayName":"o/n",
         "source":"manual","starSound":"glass","isMuted":false,"trendPoints":[],
         "starAskPromptStatus":"notShown"}
        """.utf8)
        let repo = try JSONDecoder().decode(TrackedRepo.self, from: legacy)
        XCTAssertFalse(repo.isPrivate, "repos stored before private support must decode as public")
    }

    func testApplySnapshotRoundTripsIsPrivateAndResetsETagsOnFlip() throws {
        let store = TrackedRepoStore(
            defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
            legacyDefaults: nil
        )
        let repo = TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: false,
                               etagRepo: "etag-public", etagReleases: "etag-releases-public")
        try store.upsertTrackedRepo(repo)

        // A flip means the stored ETags were minted under a different auth
        // identity; a 304 against them would serve the other identity's body.
        let flipped = RepoSnapshot(stars: 0, releaseDownloads: 0, forks: 0,
                                   checkedAt: Date(), repoETag: nil, releasesETag: nil,
                                   isPrivate: true)
        _ = store.apply(snapshot: flipped, to: repo.id)

        let stored = store.repo(id: repo.id)
        XCTAssertEqual(stored?.isPrivate, true)
        XCTAssertNil(stored?.etagRepo)
        XCTAssertNil(stored?.etagReleases)
    }

    func testApplySnapshotKeepsETagsWhenVisibilityUnchanged() throws {
        let store = TrackedRepoStore(
            defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
            legacyDefaults: nil
        )
        let repo = TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: false)
        try store.upsertTrackedRepo(repo)

        // No flip: ETags must survive, or every poll pays a full body it could
        // have 304'd away.
        let same = RepoSnapshot(stars: 1, releaseDownloads: 0, forks: 0,
                                checkedAt: Date(), repoETag: "fresh", releasesETag: "fresh-r",
                                isPrivate: false)
        _ = store.apply(snapshot: same, to: repo.id)

        XCTAssertEqual(store.repo(id: repo.id)?.etagRepo, "fresh")
        XCTAssertEqual(store.repo(id: repo.id)?.etagReleases, "fresh-r")
    }

    func testUpsertPreservesIsPrivateOnReAdd() throws {
        let store = TrackedRepoStore(
            defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
            legacyDefaults: nil
        )
        try store.upsertTrackedRepo(TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true))
        // upsert copies fields member-by-member, so a field not listed there is
        // silently dropped on re-add.
        try store.upsertTrackedRepo(TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true))
        XCTAssertEqual(store.trackedRepos.first?.isPrivate, true)
    }
    func testPrivateRepoZeroesTheStarCueButLeavesDownloadsAlone() {
        // The suppression must key off the metric, not the code block: the sound
        // and celebration paths both fire on download milestones too, so gating
        // the whole block on isPrivate would silently kill download cues that
        // private repos are entitled to.
        let starDelta = RepoDelta(starsDelta: 5, downloadsDelta: 0)
        let downloadDelta = RepoDelta(starsDelta: 0, downloadsDelta: 50)

        XCTAssertEqual(RepoPollingService.cueStarsDelta(starDelta, isPrivate: false), 5)
        XCTAssertEqual(RepoPollingService.cueStarsDelta(starDelta, isPrivate: true), 0,
                       "a private repo's star delta must not drive any cue")
        XCTAssertEqual(RepoPollingService.cueStarsDelta(downloadDelta, isPrivate: true), 0)

        // Downloads still reach the sound threshold on a private repo.
        XCTAssertTrue(
            StarSoundThreshold.one.isMet(
                starsDelta: RepoPollingService.cueStarsDelta(downloadDelta, isPrivate: true),
                downloadsDelta: downloadDelta.downloadsDelta,
                downloads: 50
            ),
            "download sounds must survive for private repos"
        )
        // And the celebration pulse is a download event too.
        XCTAssertTrue(downloadDelta.hasCelebrationIncrease)
    }

    func testPrivateRepoDoesNotRecordAStarNotification() throws {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.notifyOnStarIncrease = true }
        try repoStore.upsertTrackedRepo(TrackedRepo(owner: "o", name: "n", source: .manual, isPrivate: true))
        let repoID = repoStore.trackedRepos[0].id
        let client = GitHubClient()
        let service = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: client,
            repoAccess: GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { nil }),
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )

        // markNotified is the observable trace of a star notification firing.
        service.handle(delta: RepoDelta(starsDelta: 5, downloadsDelta: 0), repoID: repoID, stars: 5, downloads: 0)
        XCTAssertNil(repoStore.trackedRepos[0].lastNotifiedStars,
                     "a private repo must not fire — or record — a star notification")
    }

    func testPublicRepoStillRecordsAStarNotification() throws {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let repoStore = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.notifyOnStarIncrease = true }
        try repoStore.upsertTrackedRepo(TrackedRepo(owner: "o", name: "p", source: .manual))
        let repoID = repoStore.trackedRepos[0].id
        let client = GitHubClient()
        let service = RepoPollingService(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: client,
            repoAccess: GitHubRepoAccess(client: client, patProvider: { nil }, ambientProvider: { nil }),
            notificationService: NotificationService(),
            soundService: SoundService(),
            animationCoordinator: AnimationCoordinator()
        )

        service.handle(delta: RepoDelta(starsDelta: 5, downloadsDelta: 0), repoID: repoID, stars: 5, downloads: 0)
        XCTAssertEqual(repoStore.trackedRepos[0].lastNotifiedStars, 5, "public behaviour must be unchanged")
    }

    func testMilestoneShareRefusesPrivateRepos() {
        // Collaborators can star a private repo, so a real value can exist here.
        // The factory is the chokepoint: canShareMilestone only gates menu
        // construction, and the action handlers re-derive the share themselves.
        var secret = TrackedRepo(owner: "o", name: "secret-thing", source: .manual, isPrivate: true)
        secret.lastStars = 100
        secret.lastDownloads = 500
        XCTAssertNil(RepoMilestoneShare.make(repo: secret, metric: .stars))
        XCTAssertNil(RepoMilestoneShare.make(repo: secret, metric: .downloads),
                     "a private repo's name must never reach a shareable image")

        var open = TrackedRepo(owner: "o", name: "n", source: .manual)
        open.lastStars = 100
        XCTAssertNotNil(RepoMilestoneShare.make(repo: open, metric: .stars),
                        "public sharing must be unchanged")
    }


    func testClearAllETagsWipesEveryRepo() throws {
        let store = TrackedRepoStore(
            defaults: UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!,
            legacyDefaults: nil
        )
        try store.upsertTrackedRepo(TrackedRepo(owner: "a", name: "1", source: .manual,
                                                etagRepo: "e1", etagReleases: "r1"))
        try store.upsertTrackedRepo(TrackedRepo(owner: "b", name: "2", source: .manual,
                                                etagRepo: "e2", etagReleases: "r2"))

        // A new PAT is a new identity, and every stored ETag was minted under the
        // old one — a 304 against them would serve the wrong body.
        store.clearAllETags()

        XCTAssertTrue(store.trackedRepos.allSatisfy { $0.etagRepo == nil && $0.etagReleases == nil })
        XCTAssertEqual(store.trackedRepos.count, 2, "clearing ETags must not drop repos")
    }


    func testNotFoundErrorCopyNoLongerClaimsPublicOnly() {
        let message = GitHubError.userMessage(for: GitHubError.notFoundOrPrivate)
        XCTAssertFalse(message.contains("V1 tracks public repositories only"),
                       "the app tracks private repos now")
        XCTAssertFalse(message.lowercased().contains("public repositories only"))
        // A 404 is indistinguishable between "doesn't exist", "no token can see
        // it", and "the PAT's resource owner is wrong" — so the copy has to point
        // somewhere actionable rather than guess.
        XCTAssertTrue(message.lowercased().contains("settings"))
    }


    func testPrivateRepoMenuLineOmitsTheStarGlyph() {
        var priv = TrackedRepo(owner: "o", name: "secret", source: .manual, isPrivate: true)
        priv.lastDownloads = 120
        var pub = TrackedRepo(owner: "o", name: "open", source: .manual)
        pub.lastStars = 9
        pub.lastDownloads = 120

        // A private repo's stars are never fetched, so a star glyph would be
        // rendering a number we never looked up.
        XCTAssertFalse(StatusMenuBuilder.repoLineText(priv).contains("☆"))
        XCTAssertTrue(StatusMenuBuilder.repoLineText(priv).contains("⤓"))
        XCTAssertTrue(StatusMenuBuilder.repoLineText(pub).contains("☆"), "public lines are unchanged")
    }

}

private extension NSMenuItem {
    func hasBoldPrefix(_ prefix: String) -> Bool {
        guard let attributedTitle,
              attributedTitle.string.hasPrefix(prefix),
              let font = attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return false
        }
        return font.fontDescriptor.symbolicTraits.contains(NSFontDescriptor.SymbolicTraits.bold)
    }

    func isFullyBold(_ substring: String) -> Bool {
        guard let attributedTitle else { return false }
        let range = (attributedTitle.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return false }
        var allBold = true
        attributedTitle.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            guard let font = value as? NSFont,
                  font.fontDescriptor.symbolicTraits.contains(NSFontDescriptor.SymbolicTraits.bold) else {
                allBold = false
                stop.pointee = true
                return
            }
        }
        return allBold
    }
}
