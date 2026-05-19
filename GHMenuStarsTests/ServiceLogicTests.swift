import XCTest
import Security
@testable import GHMenuStars

@MainActor
final class ServiceLogicTests: XCTestCase {
    func testDeltaDetectionAndNotificationDedupeState() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = TrackedRepoStore(defaults: defaults)
        let repo = TrackedRepo(owner: "owner", name: "repo", source: .manual, lastStars: 10, lastDownloads: 20)
        store.setTrackedRepo(repo)

        let delta = store.apply(
            snapshot: RepoSnapshot(stars: 13, releaseDownloads: 30, checkedAt: Date(), repoETag: "r", releasesETag: "rel"),
            to: repo.id
        )

        XCTAssertEqual(delta, RepoDelta(starsDelta: 3, downloadsDelta: 10))
        store.markNotified(repoID: repo.id, stars: 13, downloads: nil)
        XCTAssertEqual(store.trackedRepos.first?.lastNotifiedStars, 13)
    }

    func testRefreshIntervalDurations() {
        XCTAssertEqual(RefreshInterval.tenMinutes.timeInterval, 600)
        XCTAssertEqual(RefreshInterval.sixtyMinutes.timeInterval, 3600)
        XCTAssertEqual(RefreshInterval.oneDay.timeInterval, 86_400)
    }

    func testSettingsPersistence() {
        let defaults = UserDefaults(suiteName: "GHMenuStarsTests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.update { settings in
            settings.refreshInterval = .oneDay
            settings.hideDockIcon = false
            settings.isMuted = true
        }

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.refreshInterval, .oneDay)
        XCTAssertFalse(reloaded.settings.hideDockIcon)
        XCTAssertTrue(reloaded.settings.isMuted)
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
        XCTAssertFalse(store.settings.isMuted)
        XCTAssertEqual(store.settings.gitHubOAuthClientID, "saved-client")
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
        let delta = RepoDelta(starsDelta: 2, downloadsDelta: 1)
        legacyDefaults.set(try JSONEncoder().encode([repo]), forKey: "GHMenuStars.TrackedRepos.v1")
        legacyDefaults.set(try JSONEncoder().encode(delta), forKey: "GHMenuStars.LastDelta.v1")

        let store = TrackedRepoStore(defaults: defaults, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.trackedRepos, [repo])
        XCTAssertEqual(store.lastDelta, delta)
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
