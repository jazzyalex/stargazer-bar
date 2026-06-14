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
    private var copyFeedbackWindow: NSWindow?
    private var copyFeedbackDismissal: DispatchWorkItem?

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

    @objc func copyMilestoneText(_ sender: NSMenuItem) {
        guard let share = milestoneShare(from: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MilestoneShareTextBuilder.text(for: share), forType: .string)
        showCopyFeedback("Copied \(share.metric.displayName.lowercased()) text")
    }

    @objc func copyMilestoneImage(_ sender: NSMenuItem) {
        guard let share = milestoneShare(from: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([MilestoneShareCardRenderer.image(for: share)])
        showCopyFeedback("Copied \(share.metric.displayName.lowercased()) image")
    }

    @objc func composeXPostWithMilestoneImage(_ sender: NSMenuItem) {
        guard let share = milestoneShare(from: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([MilestoneShareCardRenderer.image(for: share)])
        showCopyFeedback("Copied image for X")

        var components = URLComponents(string: "https://twitter.com/intent/tweet")
        components?.queryItems = [
            URLQueryItem(name: "text", value: MilestoneShareTextBuilder.text(for: share))
        ]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
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

#if DEBUG
    @objc func debugShowGrowthPrompt() {
        guard let repo = repoStore.repo(id: settingsStore.settings.selectedMenuBarRepoID) else { return }
        let status = StarAskPromptPresenter.present(repo: repo, trigger: .starIncrease(1))
        repoStore.markStarAskPrompt(repoID: repo.id, status: status)
    }
#endif

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

    private func showCopyFeedback(_ message: String) {
        copyFeedbackDismissal?.cancel()
        copyFeedbackWindow?.close()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 210, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = effectView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .transient]

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor)
        ])

        positionFeedbackWindow(window)
        window.orderFront(nil)
        copyFeedbackWindow = window

        let dismissal = DispatchWorkItem { [weak self, weak window] in
            window?.close()
            if self?.copyFeedbackWindow === window {
                self?.copyFeedbackWindow = nil
            }
        }
        copyFeedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35, execute: dismissal)
    }

    private func positionFeedbackWindow(_ window: NSWindow) {
        guard let button = statusItem?.button,
              let sourceWindow = button.window else {
            window.center()
            return
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = sourceWindow.convertToScreen(buttonRect)
        var frame = window.frame
        frame.origin.x = screenRect.midX - frame.width / 2
        frame.origin.y = screenRect.minY - frame.height - 8

        if let visibleFrame = sourceWindow.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX + 8), visibleFrame.maxX - frame.width - 8)
            frame.origin.y = max(frame.origin.y, visibleFrame.minY + 8)
        }
        window.setFrame(frame, display: true)
    }

    private func milestoneShare(from sender: NSMenuItem) -> RepoMilestoneShare? {
        guard let request = sender.representedObject as? MilestoneShareRequest,
              let repo = repoStore.trackedRepos.first(where: { $0.id == request.repoID }) else {
            return nil
        }
        return RepoMilestoneShare.make(repo: repo, metric: request.metric)
    }
}

struct MilestoneShareRequest: Equatable {
    var repoID: UUID
    var metric: MilestoneMetric
}
