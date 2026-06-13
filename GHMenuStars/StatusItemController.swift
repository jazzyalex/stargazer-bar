import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingView<StatusLabelView>?
    private let repoStore: TrackedRepoStore
    private let settingsStore: SettingsStore
    private let pollingService: RepoPollingService
    private let updaterController: UpdaterController
    private let animationCoordinator: AnimationCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var lengthUpdateScheduled = false

    var isAvailable: Bool { statusItem?.button != nil }

    init(
        repoStore: TrackedRepoStore,
        settingsStore: SettingsStore,
        pollingService: RepoPollingService,
        updaterController: UpdaterController,
        animationCoordinator: AnimationCoordinator
    ) {
        self.repoStore = repoStore
        self.settingsStore = settingsStore
        self.pollingService = pollingService
        self.updaterController = updaterController
        self.animationCoordinator = animationCoordinator
        super.init()
    }

    func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.title = ""
            button.image = nil
            let view = StatusLabelView(
                repoStore: repoStore,
                settingsStore: settingsStore,
                animationCoordinator: animationCoordinator
            )
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            self.hosting = hosting
            button.target = self
            button.action = #selector(openMenu(_:))
        }

        repoStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        settingsStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        animationCoordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        scheduleLengthUpdate()
    }

    @objc private func openMenu(_ sender: Any?) {
        guard let button = statusItem?.button, let item = statusItem else { return }
        item.menu = StatusMenuBuilder(
            repoStore: repoStore,
            settingsStore: settingsStore,
            pollingService: pollingService,
            updaterController: updaterController
        ).build(target: self)
        button.performClick(nil)
        item.menu = nil
    }

    @objc func checkNow() {
        pollingService.refreshNow()
    }

    @objc func toggleMute() {
        settingsStore.update { settings in
            settings.isMuted.toggle()
        }
    }

    @objc func openGitHub() {
        guard let repo = repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID),
              let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openProjectForStar() {
        NSWorkspace.shared.open(AppExternalLinks.gitHubRepository)
    }

    @objc func showRepoInMenuBar(_ sender: NSMenuItem) {
        guard let repoID = sender.representedObject as? UUID else { return }
        settingsStore.update { settings in
            settings.selectedMenuBarRepoID = repoID
            if !settings.menuBarDisplayMode.requiresSelectedRepo {
                settings.menuBarDisplayMode = .selectedRepoStars
            }
        }
    }

    @objc func setDisplayMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = MenuBarDisplayMode(rawValue: rawValue) else { return }
        settingsStore.update { settings in
            settings.menuBarDisplayMode = mode
            if mode.requiresSelectedRepo, settings.selectedMenuBarRepoID == nil {
                settings.selectedMenuBarRepoID = repoStore.trackedRepos.first?.id
            }
        }
    }

    @objc func openSettings() {
        PreferencesWindow.shared.show(
            repoStore: repoStore,
            settingsStore: settingsStore,
            gitHubClient: pollingService.gitHubClient,
            updaterController: updaterController
        )
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc func toggleAutomaticUpdates() {
        updaterController.toggleAutoUpdateEnabled()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    private func scheduleLengthUpdate() {
        guard !lengthUpdateScheduled else { return }
        lengthUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lengthUpdateScheduled = false
            self.updateLength()
        }
    }

    private func updateLength() {
        guard let item = statusItem, let hosting else { return }
        item.length = max(44, hosting.fittingSize.width + 2)
    }
}
