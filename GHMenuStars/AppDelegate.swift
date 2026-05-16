import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let repoStore = TrackedRepoStore()
    private let updaterController = UpdaterController()
    private let tokenStore = KeychainTokenStore(service: "GHMenuStars.GitHubOAuth")
    private lazy var gitHubClient = GitHubClient(tokenProvider: { [tokenStore] in
        try? tokenStore.loadToken()
    })
    private lazy var pollingService = RepoPollingService(
        repoStore: repoStore,
        settingsStore: settingsStore,
        gitHubClient: gitHubClient,
        notificationService: NotificationService(),
        soundService: SoundService(),
        animationCoordinator: animationCoordinator
    )
    private let animationCoordinator = AnimationCoordinator()
    private var statusItemController: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []

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
        applyActivationPolicy()

        settingsStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyActivationPolicy() }
            }
            .store(in: &cancellables)

        pollingService.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingService.stop()
    }

    private func applyActivationPolicy() {
        let hasMenuBarPath = statusItemController?.isAvailable == true
        NSApplication.shared.setActivationPolicy(
            ActivationPolicyDecider.policy(
                hideDockIcon: settingsStore.settings.hideDockIcon,
                hasStatusItem: hasMenuBarPath
            )
        )
    }

    static func isHostedUnitTest(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}
