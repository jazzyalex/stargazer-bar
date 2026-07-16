import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let repoStore = TrackedRepoStore()
    private let updaterController = UpdaterController()
    private lazy var gitHubClient = GitHubClient(
        tokenProvider: {
            KeychainTokenStore.loadGitHubOAuthToken()
        },
        optionalTokenProvider: {
            KeychainTokenStore.loadGitHubOAuthToken()
        }
    )
    /// One shared instance: the PAT-dead and double-404 latches are
    /// per-instance state, so a second would retry tokens this one already
    /// knows are dead.
    private lazy var repoAccess = GitHubRepoAccess(
        client: gitHubClient,
        patProvider: { KeychainTokenStore.loadGitHubPAT() },
        ambientProvider: { KeychainTokenStore.loadGitHubOAuthToken() },
        // Gates token resolution itself, not merely Settings copy: with the
        // feature off, a stored PAT must never be read or sent.
        privateAccessEnabled: { [settingsStore] in settingsStore.settings.enablePrivateRepos }
    )
    private lazy var pollingService = RepoPollingService(
        repoStore: repoStore,
        settingsStore: settingsStore,
        gitHubClient: gitHubClient,
        repoAccess: repoAccess,
        notificationService: NotificationService(),
        soundService: SoundService(),
        animationCoordinator: animationCoordinator
    )
    private let animationCoordinator = AnimationCoordinator()
    private var statusItemController: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []
    private var isDockRecentCleanupScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostedUnitTest() else { return }

        AppIconFactory.applyRuntimeIcon()

        let controller = StatusItemController(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController,
            animationCoordinator: animationCoordinator
        )
        statusItemController = controller
        controller.ensureStatusItem()
        PreferencesWindow.shared.visibilityDidChange = { [weak self] in
            DispatchQueue.main.async { self?.applyActivationPolicy() }
        }
        applyActivationPolicy()

        settingsStore.settingsDidChange
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyActivationPolicy() }
            .store(in: &cancellables)

        pollingService.start()

#if DEBUG
        if ProcessInfo.processInfo.environment["GH_MENU_STARS_SHOW_GROWTH_PROMPT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.debugShowGrowthPrompt()
            }
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingService.stop()
    }

    private func applyActivationPolicy() {
        let hasMenuBarPath = statusItemController?.isAvailable == true
        let policy = ActivationPolicyDecider.policy(
            hideDockIcon: settingsStore.settings.hideDockIcon,
            hasStatusItem: hasMenuBarPath
        )
        NSApplication.shared.setActivationPolicy(policy)
        if policy == .accessory {
            scheduleDockRecentCleanup()
        }
        PreferencesWindow.shared.keepVisibleAfterActivationPolicyChange()
    }

    private func scheduleDockRecentCleanup() {
        guard !isDockRecentCleanupScheduled else { return }
        isDockRecentCleanupScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            DockRecentAppCleaner.removeCurrentAppIfPresent()
            self?.isDockRecentCleanupScheduled = false
        }
    }

    static func isHostedUnitTest(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}
