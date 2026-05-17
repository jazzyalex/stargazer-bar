import Cocoa
import Sparkle

@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var hasGentleReminder = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var autoUpdateEnabled: Bool
    @Published private(set) var isUpdateCheckingConfigured: Bool

    private var controller: SPUStandardUpdaterController?
    private var updaterObservations: [NSKeyValueObservation] = []

    override init() {
        self.autoUpdateEnabled = Self.defaultAutoUpdateEnabled
        self.isUpdateCheckingConfigured = Self.configuredFeedURL != nil
        super.init()

        guard !AppDelegate.isHostedUnitTest() else { return }
        guard isUpdateCheckingConfigured else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        observeUpdater(controller.updater)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let updater = self.updater else { return }
            do {
                try updater.start()
                syncAutoUpdateState(from: updater)
            } catch {
                print("Failed to start updater - \(error.localizedDescription)")
            }
        }
    }

    var updater: SPUUpdater? {
        controller?.updater
    }

    var canRequestUpdateCheck: Bool {
        guard isUpdateCheckingConfigured else { return true }
        return canCheckForUpdates
    }

    var canChangeAutoUpdatePreference: Bool {
        updater != nil
    }

    func setAutoUpdateEnabled(_ enabled: Bool) {
        guard let updater else { return }

        if enabled {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
        } else {
            updater.automaticallyDownloadsUpdates = false
            updater.automaticallyChecksForUpdates = false
        }

        syncAutoUpdateState(from: updater)
    }

    func toggleAutoUpdateEnabled() {
        setAutoUpdateEnabled(!autoUpdateEnabled)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isUpdateCheckingConfigured else {
            showUpdateAlert(
                title: "Updates are not configured",
                message: "This build does not include a Sparkle appcast URL, so it cannot check for app updates."
            )
            return
        }

        guard let updater else { return }
        guard updater.canCheckForUpdates else {
            showUpdateAlert(
                title: "Update check is not ready",
                message: "Sparkle is busy or still starting. Try checking again in a moment."
            )
            return
        }

        hasGentleReminder = false
        updater.checkForUpdates()
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            hasGentleReminder = !handleShowingUpdate
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            hasGentleReminder = false
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            hasGentleReminder = false
        }
    }

    nonisolated func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        true
    }

    nonisolated func updaterDidFinishCheckingForUpdates(_ updater: SPUUpdater, error: Error?) {
        if let error {
            print("Update check failed - \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        print("Update available - \(item.displayVersionString)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        print("Already up to date")
    }

    private func observeUpdater(_ updater: SPUUpdater) {
        updaterObservations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in
                    self?.syncAutoUpdateState(from: updater)
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in
                    self?.syncAutoUpdateState(from: updater)
                }
            }
        ]
    }

    private func syncAutoUpdateState(from updater: SPUUpdater) {
        autoUpdateEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    private func showUpdateAlert(title: String, message: String) {
        guard !AppDelegate.isHostedUnitTest() else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private static var defaultAutoUpdateEnabled: Bool {
        guard configuredFeedURL != nil else { return false }
        return ((Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool) ?? false) &&
            ((Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool) ?? false)
    }

    private static var configuredFeedURL: URL? {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return nil
        }
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return URL(string: trimmed)
    }
}
