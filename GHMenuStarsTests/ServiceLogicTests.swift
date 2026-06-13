import XCTest
import Security
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
        XCTAssertEqual(store.trackedRepos.first?.trendPoints.count, 1)
        XCTAssertEqual(store.trackedRepos.first?.trendPoints.first?.stars, 13)
        XCTAssertEqual(store.trackedRepos.first?.trendPoints.first?.forks, 4)
    }

    func testTrendHistoryStoresOnePointPerDay() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: nil)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual, lastStars: 10, lastForks: 1)
        store.setTrackedRepo(repo)
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 9))!

        _ = store.apply(
            snapshot: RepoSnapshot(stars: 11, releaseDownloads: 0, forks: 2, checkedAt: day, repoETag: nil, releasesETag: nil),
            to: repo.id
        )
        _ = store.apply(
            snapshot: RepoSnapshot(stars: 12, releaseDownloads: 0, forks: 3, checkedAt: day.addingTimeInterval(3600), repoETag: nil, releasesETag: nil),
            to: repo.id
        )

        XCTAssertEqual(store.trackedRepos.first?.trendPoints.count, 1)
        XCTAssertEqual(store.trackedRepos.first?.trendPoints.first?.stars, 12)
        XCTAssertEqual(store.trackedRepos.first?.trendPoints.first?.forks, 3)
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
}
